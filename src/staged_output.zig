const std = @import("std");
const builtin = @import("builtin");
const fs = @import("fs.zig");
const file_close = @import("file_close.zig");

pub const PublishMode = enum { replace, no_replace };
pub const CleanupReport = struct { secondary: ?anyerror = null };

/// Borrowed, instance-local, one-shot schedules. Keep this alive until cleanup.
/// A flush fault is injected before draining; it is not a native disk error.
pub const Faults = struct {
    pub const Operation = enum { candidate, create, write, flush, sync, close, rename, cleanup };
    pub const Cause = error{ AccessDenied, NoSpaceLeft, InputOutput, OperationUnsupported, EntropyUnavailable };
    const count = @typeInfo(Operation).@"enum".fields.len;
    const Rule = struct { target: usize, cause: Cause };
    attempts: [count]usize = @splat(0),
    completed: [count]usize = @splat(0),
    rules: [count]?Rule = @splat(null),
    candidate_bytes: ?[16]u8 = null,
    candidate_sequence: []const [16]u8 = &.{},
    candidate_index: usize = 0,
    prefix_remaining: ?usize = null,
    native_prefix_bytes: usize = 0,

    pub fn arm(self: *Faults, op: Operation, ordinal: usize, cause: Cause) !void {
        if (ordinal == 0) return error.InvalidFaultOrdinal;
        self.rules[@intFromEnum(op)] = .{ .target = try std.math.add(usize, self.attemptsFor(op), ordinal), .cause = cause };
    }

    pub fn attemptsFor(self: *const Faults, op: Operation) usize {
        return self.attempts[@intFromEnum(op)];
    }

    pub fn completedFor(self: *const Faults, op: Operation) usize {
        return self.completed[@intFromEnum(op)];
    }

    pub fn disarm(self: *Faults) void {
        self.rules = @splat(null);
        self.prefix_remaining = null;
    }

    fn check(self: *Faults, op: Operation) ?Cause {
        const index = @intFromEnum(op);
        self.attempts[index] += 1;
        if (self.rules[index]) |rule| {
            if (rule.target == self.attempts[index]) {
                self.rules[index] = null;
                return rule.cause;
            }
        }
        return null;
    }
};

pub const Options = struct {
    mode: PublishMode = .replace,
    faults: ?*Faults = null,
    cleanup_report: ?*CleanupReport = null,
};

const Storage = struct {
    allocator: std.mem.Allocator,
    filesystem: fs.FileSystem,
    destination: []u8,
    name: [51]u8,
    file: ?std.Io.File,
    writer: std.Io.File.Writer,
    buffer: [8192]u8,
    permissions: ?std.Io.File.Permissions,
    faults: ?*Faults,
    report: ?*CleanupReport,
    state: enum { writing, failed, finished } = .writing,

    fn check(self: *Storage, op: Faults.Operation) !void {
        if (self.faults) |faults| if (faults.check(op)) |cause| return cause;
    }

    fn completed(self: *Storage, op: Faults.Operation) void {
        if (self.faults) |faults| faults.completed[@intFromEnum(op)] += 1;
    }

    fn close(self: *Storage) !void {
        if (self.file == null) return;
        // Even an injected late error consumes the real native descriptor first.
        const injected = if (self.faults) |faults| faults.check(.close) else null;
        try file_close.closeOwned(&self.file);
        if (injected) |cause| return cause;
        self.completed(.close);
    }

    fn fail(self: *Storage) void {
        self.state = .failed;
        self.close() catch |cause| self.recordCleanup(cause);
    }

    fn recordCleanup(self: *Storage, cause: anyerror) void {
        if (self.report) |report| if (report.secondary == null) {
            report.secondary = cause;
        };
    }

    fn flush(self: *Storage) !void {
        try self.check(.flush);
        self.writer.interface.flush() catch return self.writer.err orelse error.WriteFailed;
        self.completed(.flush);
    }

    fn destroy(self: *Storage) void {
        std.debug.assert(self.file == null);
        self.filesystem.dir.close(self.filesystem.io);
        self.allocator.free(self.destination);
        self.allocator.destroy(self);
    }
};

/// Non-copyable owner. Methods take pointers; finish invalidates this owner.
/// After an error, only abort/deinit are valid. Never retain internal references.
pub const Pending = struct {
    storage: ?*Storage,

    pub fn writeAll(self: *Pending, bytes: []const u8) !void {
        const s = self.storage orelse return error.InvalidStageState;
        if (s.state != .writing) return error.InvalidStageState;
        errdefer s.fail();
        try s.check(.write);
        if (s.faults) |faults| if (faults.prefix_remaining) |remaining| {
            // Drain any preceding buffered bytes before the real prefix write.
            try s.flush();
            const n = @min(remaining, bytes.len);
            try s.file.?.writeStreamingAll(s.filesystem.io, bytes[0..n]);
            faults.native_prefix_bytes += n;
            faults.prefix_remaining = remaining - n;
            if (n == remaining) {
                faults.prefix_remaining = null;
                return error.NoSpaceLeft;
            }
            s.completed(.write);
            return;
        };
        s.writer.interface.writeAll(bytes) catch return s.writer.err orelse error.WriteFailed;
        s.completed(.write);
    }

    pub fn finish(self: *Pending) !Finished {
        const s = self.storage orelse return error.InvalidStageState;
        if (s.state != .writing) return error.InvalidStageState;
        errdefer s.fail();
        try s.flush();
        if (s.permissions) |permissions| try s.file.?.setPermissions(s.filesystem.io, permissions);
        try s.check(.sync);
        try s.file.?.sync(s.filesystem.io);
        s.completed(.sync);
        try s.close();
        s.state = .finished;
        self.storage = null;
        return .{ .storage = s };
    }

    /// A failed unlink retains ownership so explicit abort can be retried.
    pub fn abort(self: *Pending) !void {
        try abortStorage(&self.storage);
    }

    /// Releases all resources, even if unlink fails. Prefer abort to inspect errors.
    pub fn deinit(self: *Pending) void {
        dispose(&self.storage);
    }
};

/// Non-copyable owner of sealed bytes. Validators must close read descriptors
/// before publish. No writable open or mutation operation is exposed here.
pub const Finished = struct {
    storage: ?*Storage,

    pub const Reference = struct { dir: std.Io.Dir, basename: []const u8 };

    pub fn reference(self: *const Finished) !Reference {
        const s = self.storage orelse return error.InvalidStageState;
        if (s.state != .finished) return error.InvalidStageState;
        return .{ .dir = s.filesystem.dir, .basename = &s.name };
    }

    pub fn openReadOnly(self: *Finished) !std.Io.File {
        const s = self.storage orelse return error.InvalidStageState;
        if (s.state != .finished) return error.InvalidStageState;
        return s.filesystem.openReadOnly(&s.name);
    }

    pub fn publish(self: *Finished, mode: PublishMode) !void {
        const s = self.storage orelse return error.InvalidStageState;
        if (s.state != .finished) return error.InvalidStageState;
        try s.check(.rename);
        switch (mode) {
            .replace => try s.filesystem.renameFile(&s.name, s.destination),
            .no_replace => s.filesystem.renameFilePreserve(&s.name, s.destination) catch |err| switch (err) {
                error.PathAlreadyExists => return error.DestinationExists,
                else => return err,
            },
        }
        s.completed(.rename);
        self.storage = null;
        s.destroy();
    }

    pub fn abort(self: *Finished) !void {
        try abortStorage(&self.storage);
    }

    pub fn deinit(self: *Finished) void {
        dispose(&self.storage);
    }
};

fn abortStorage(owner: *?*Storage) !void {
    const s = owner.* orelse return;
    s.state = .failed;
    var close_error: ?anyerror = null;
    s.close() catch |cause| {
        close_error = cause;
    };
    s.check(.cleanup) catch |cause| {
        s.recordCleanup(cause);
        return close_error orelse cause;
    };
    _ = s.filesystem.removeFileIfExists(&s.name) catch |cause| {
        s.recordCleanup(cause);
        return close_error orelse cause;
    };
    s.completed(.cleanup);
    if (close_error) |cause| s.recordCleanup(cause);
    owner.* = null;
    s.destroy();
    if (close_error) |cause| return cause;
}

fn dispose(owner: *?*Storage) void {
    abortStorage(owner) catch |cause| {
        if (owner.*) |s| {
            s.recordCleanup(cause);
            owner.* = null;
            s.destroy();
        }
    };
}

/// Opens the parent once. Parent names may move later without redirecting I/O.
pub fn begin(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, options: Options) !Pending {
    if (builtin.os.tag != .linux) return error.OperationUnsupported;
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.BadPathName;
    if (path[path.len - 1] == '/') return error.IsDir;
    const basename = std.fs.path.basename(path);
    if (std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..")) return error.IsDir;
    const parent = try dir.openDir(io, std.fs.path.dirname(path) orelse ".", .{});
    errdefer parent.close(io);
    var filesystem = fs.FileSystem.init(io, parent, null);
    const state = try filesystem.pathState(basename);
    const permissions: ?std.Io.File.Permissions = switch (state) {
        .not_found => null,
        .present => |stat| blk: {
            if (options.mode == .no_replace) return error.DestinationExists;
            if (stat.kind == .directory) return error.IsDir;
            break :blk if (stat.kind == .file) .fromMode(stat.permissions.toMode() & 0o7777) else null;
        },
    };
    const destination = try allocator.dupe(u8, basename);
    errdefer allocator.free(destination);
    const s = try allocator.create(Storage);
    errdefer allocator.destroy(s);
    s.* = .{
        .allocator = allocator,
        .filesystem = filesystem,
        .destination = destination,
        .name = undefined,
        .file = null,
        .writer = undefined,
        .buffer = undefined,
        .permissions = permissions,
        .faults = options.faults,
        .report = options.cleanup_report,
    };
    for (0..32) |_| {
        try s.check(.candidate);
        var random: [16]u8 = undefined;
        if (options.faults) |faults| {
            if (faults.candidate_index < faults.candidate_sequence.len) {
                random = faults.candidate_sequence[faults.candidate_index];
                faults.candidate_index += 1;
            } else if (faults.candidate_bytes) |bytes| random = bytes else try io.randomSecure(&random);
        } else try io.randomSecure(&random);
        _ = try std.fmt.bufPrint(&s.name, ".kotoba-output-{s}.tmp", .{std.fmt.bytesToHex(random, .lower)});
        s.completed(.candidate);
        try s.check(.create);
        s.file = filesystem.createExclusiveFile(&s.name, permissions orelse .default_file) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        s.completed(.create);
        s.writer = s.file.?.writerStreaming(io, &s.buffer);
        return .{ .storage = s };
    }
    return error.StageNameCollision;
}

pub fn atomicWriteFile(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, bytes: []const u8, options: Options) !void {
    var pending = try begin(allocator, io, dir, path, options);
    defer pending.deinit();
    try pending.writeAll(bytes);
    var finished = try pending.finish();
    defer finished.deinit();
    try finished.publish(options.mode);
}

const testing = std.testing;

fn put(dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    try dir.writeFile(testing.io, .{ .sub_path = name, .data = bytes });
}

fn expectBytes(dir: std.Io.Dir, name: []const u8, expected: []const u8) !void {
    const bytes = try dir.readFileAlloc(testing.io, name, testing.allocator, .limited(65536));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(expected, bytes);
}

fn expectEntries(dir: std.Io.Dir, expected: []const []const u8) !void {
    var iterable = try dir.openDir(testing.io, ".", .{ .iterate = true });
    defer iterable.close(testing.io);
    var iterator = iterable.iterate();
    var count: usize = 0;
    while (try iterator.next(testing.io)) |entry| {
        count += 1;
        var found = false;
        for (expected) |name| if (std.mem.eql(u8, name, entry.name)) {
            found = true;
        };
        try testing.expect(found);
    }
    try testing.expectEqual(expected.len, count);
}

fn fileMode(dir: std.Io.Dir, name: []const u8) !std.posix.mode_t {
    return (try dir.statFile(testing.io, name, .{ .follow_symlinks = false })).permissions.toMode() & 0o7777;
}

fn setup(dir: std.Io.Dir, existing: bool) !void {
    try put(dir, "sibling", "UNRELATED");
    if (existing) {
        try put(dir, "target", "OLD");
        try dir.setFilePermissions(testing.io, "target", .fromMode(0o640), .{});
    }
}

fn expectOld(dir: std.Io.Dir, existing: bool, stage: ?[]const u8) !void {
    try expectBytes(dir, "sibling", "UNRELATED");
    if (existing) {
        try expectBytes(dir, "target", "OLD");
        try testing.expectEqual(@as(std.posix.mode_t, 0o640), try fileMode(dir, "target"));
        if (stage) |name| try expectEntries(dir, &.{ "target", "sibling", name }) else try expectEntries(dir, &.{ "target", "sibling" });
    } else {
        try testing.expectError(error.FileNotFound, dir.statFile(testing.io, "target", .{}));
        if (stage) |name| try expectEntries(dir, &.{ "sibling", name }) else try expectEntries(dir, &.{"sibling"});
    }
}

fn expectClosed(fd: std.c.fd_t) !void {
    try testing.expectEqual(std.c.E.BADF, std.c.errno(std.c.close(fd)));
}

test "staged output happy sealed exact bytes and permissions with bounded writer" {
    for ([_]bool{ false, true }) |existing| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try setup(tmp.dir, existing);
        try put(tmp.dir, "default-mode", "");
        const default_mode = try fileMode(tmp.dir, "default-mode");
        try tmp.dir.deleteFile(testing.io, "default-mode");
        var faults: Faults = .{};
        var pending = try begin(testing.allocator, testing.io, tmp.dir, "target", .{ .faults = &faults });
        defer pending.deinit();
        const s = pending.storage.?;
        const fd = s.file.?.handle;
        if (existing) try testing.expectEqual(@as(std.posix.mode_t, 0), (try fileMode(tmp.dir, &s.name)) & ~@as(std.posix.mode_t, 0o640));
        try testing.expect(std.mem.startsWith(u8, &s.name, ".kotoba-output-"));
        try testing.expect(std.mem.endsWith(u8, &s.name, ".tmp"));
        for (s.name[15..47]) |byte| try testing.expect(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'));
        const bytes = "NEW-BYTES\x00\xff\n";
        try pending.writeAll(bytes);
        try testing.expectEqualStrings(bytes, s.writer.interface.buffered());
        try expectBytes(tmp.dir, &s.name, "");
        try expectOld(tmp.dir, existing, &s.name);
        var finished = try pending.finish();
        defer finished.deinit();
        try expectClosed(fd);
        try testing.expect(pending.storage == null);
        try testing.expect(s.file == null);
        const reference = try finished.reference();
        try expectBytes(reference.dir, reference.basename, bytes);
        const read = try finished.openReadOnly();
        var byte: [1]u8 = undefined;
        try testing.expectEqual(@as(isize, 1), std.c.read(read.handle, &byte, 1));
        try testing.expectEqual(std.c.E.BADF, std.c.errno(std.c.write(read.handle, "x", 1)));
        read.close(testing.io);
        try finished.publish(.replace);
        try expectBytes(tmp.dir, "target", bytes);
        try testing.expectEqual(if (existing) @as(std.posix.mode_t, 0o640) else default_mode, try fileMode(tmp.dir, "target"));
        try expectEntries(tmp.dir, &.{ "target", "sibling" });
        try testing.expectEqual(@as(usize, 1), faults.completedFor(.flush));
        try testing.expectEqual(@as(usize, 1), faults.completedFor(.sync));
        try testing.expectEqual(@as(usize, 1), faults.completedFor(.close));
        try testing.expectEqual(@as(usize, 1), faults.completedFor(.rename));
    }
}

test "staged output happy convenience streams beyond fixed buffer and no replace" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = "z" ** 20000;
    try atomicWriteFile(testing.allocator, testing.io, tmp.dir, "target", bytes, .{ .mode = .no_replace });
    try expectBytes(tmp.dir, "target", bytes);
    try expectEntries(tmp.dir, &.{"target"});
}

test "staged output happy captured special permission bits reapplied after writing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try put(tmp.dir, "target", "OLD");
    try tmp.dir.setFilePermissions(testing.io, "target", .fromMode(0o4750), .{});
    var pending = try begin(testing.allocator, testing.io, tmp.dir, "target", .{});
    defer pending.deinit();
    try testing.expectEqual(@as(std.posix.mode_t, 0), (try fileMode(tmp.dir, &pending.storage.?.name)) & ~@as(std.posix.mode_t, 0o4750));
    try tmp.dir.setFilePermissions(testing.io, "target", .fromMode(0o600), .{});
    try pending.writeAll("NEW");
    var finished = try pending.finish();
    defer finished.deinit();
    try testing.expectEqual(@as(std.posix.mode_t, 0o4750), try fileMode(tmp.dir, (try finished.reference()).basename));
    try finished.publish(.replace);
    try testing.expectEqual(@as(std.posix.mode_t, 0o4750), try fileMode(tmp.dir, "target"));
    try expectBytes(tmp.dir, "target", "NEW");
}

test "staged output failure native prefix and pending flush are distinct" {
    for ([_]bool{ false, true }) |existing| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try setup(tmp.dir, existing);
        var faults: Faults = .{ .prefix_remaining = 4 };
        var pending = try begin(testing.allocator, testing.io, tmp.dir, "target", .{ .faults = &faults });
        defer pending.deinit();
        const s = pending.storage.?;
        const fd = s.file.?.handle;
        try testing.expectError(error.NoSpaceLeft, pending.writeAll("NEW-BYTES"));
        try testing.expectEqual(@as(usize, 4), faults.native_prefix_bytes);
        try testing.expectEqual(@as(usize, 0), faults.completedFor(.write));
        try expectBytes(tmp.dir, &s.name, "NEW-");
        try expectOld(tmp.dir, existing, &s.name);
        try expectClosed(fd);
        try testing.expectError(error.InvalidStageState, pending.writeAll("BYTES"));
        try testing.expectError(error.InvalidStageState, pending.finish());
        try pending.abort();
        try expectOld(tmp.dir, existing, null);
        std.debug.print("[component-injected/native-prefix] existing={any} native_bytes=4 stage=NEW- completed_write=0 fd=closed cleanup=removed\n", .{existing});
    }
}

test "staged output failure each boundary preserves existing and absent destinations" {
    const operations = [_]Faults.Operation{ .candidate, .create, .write, .flush, .sync, .close, .rename };
    for (operations) |op| for ([_]bool{ false, true }) |existing| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try setup(tmp.dir, existing);
        var faults: Faults = .{};
        try faults.arm(op, 1, error.InputOutput);
        var report: CleanupReport = .{};
        try testing.expectError(error.InputOutput, atomicWriteFile(testing.allocator, testing.io, tmp.dir, "target", "NEW-BYTES", .{ .faults = &faults, .cleanup_report = &report }));
        try expectOld(tmp.dir, existing, null);
        try testing.expectEqual(@as(usize, 1), faults.attemptsFor(op));
        try testing.expectEqual(@as(usize, 0), faults.completedFor(op));
        try testing.expectEqual(null, report.secondary);
        if (op != .candidate and op != .create) try testing.expectEqual(@as(usize, 1), faults.attemptsFor(.close));
        if (op != .rename) try testing.expectEqual(@as(usize, 0), faults.attemptsFor(.rename));
        std.debug.print("[component-injected] op={s} existing={any} attempts=1 completed=0 destination=unchanged sibling=unchanged stage=absent\n", .{ @tagName(op), existing });
    };
}

test "staged output failure injected flush retains real buffered bytes before abort" {
    for ([_]bool{ false, true }) |existing| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try setup(tmp.dir, existing);
        var faults: Faults = .{};
        try faults.arm(.flush, 1, error.InputOutput);
        var pending = try begin(testing.allocator, testing.io, tmp.dir, "target", .{ .faults = &faults });
        defer pending.deinit();
        try pending.writeAll("NEW-BYTES");
        const s = pending.storage.?;
        const fd = s.file.?.handle;
        try testing.expectError(error.InputOutput, pending.finish());
        try testing.expectEqualStrings("NEW-BYTES", s.writer.interface.buffered());
        try testing.expectEqual(null, s.writer.err);
        try expectBytes(tmp.dir, &s.name, "");
        try expectOld(tmp.dir, existing, &s.name);
        try expectClosed(fd);
        try testing.expectEqual(@as(usize, 0), faults.attemptsFor(.sync));
        try pending.abort();
        try expectOld(tmp.dir, existing, null);
        std.debug.print("[component-injected/flush] existing={any} buffer=NEW-BYTES native_stage_bytes=0 writer_native_error=null fd=closed\n", .{existing});
    }
}

test "staged output gate validation rejection and accepted external gate rename failure" {
    for ([_]bool{ false, true }) |existing| for ([_]bool{ false, true }) |accepted| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try setup(tmp.dir, existing);
        var faults: Faults = .{};
        var pending = try begin(testing.allocator, testing.io, tmp.dir, "target", .{ .faults = &faults });
        defer pending.deinit();
        try pending.writeAll("NEW-BYTES");
        var finished = try pending.finish();
        defer finished.deinit();
        const reference = try finished.reference();
        try expectBytes(reference.dir, reference.basename, "NEW-BYTES");
        if (accepted) {
            // This marker is a caller-owned gate, never a staged-output callback.
            try put(tmp.dir, "gate-committed", "ACCEPTED");
            try faults.arm(.rename, 1, error.InputOutput);
            try testing.expectError(error.InputOutput, finished.publish(.replace));
            try expectBytes(tmp.dir, "gate-committed", "ACCEPTED");
            try tmp.dir.deleteFile(testing.io, "gate-committed");
        }
        try testing.expectEqual(@as(usize, if (accepted) 1 else 0), faults.attemptsFor(.rename));
        try finished.abort();
        try expectOld(tmp.dir, existing, null);
    };
}

test "staged output race exclusive collisions retry only collisions and exhaust at 32" {
    for ([_]bool{ false, true }) |existing| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try setup(tmp.dir, existing);
        const collision = ".kotoba-output-00000000000000000000000000000000.tmp";
        try put(tmp.dir, collision, "COLLISION-OWNER");
        var faults: Faults = .{ .candidate_bytes = @splat(0) };
        try testing.expectError(error.StageNameCollision, begin(testing.allocator, testing.io, tmp.dir, "target", .{ .faults = &faults }));
        try testing.expectEqual(@as(usize, 32), faults.attemptsFor(.create));
        try testing.expectEqual(@as(usize, 32), faults.completedFor(.candidate));
        try testing.expectEqual(@as(usize, 0), faults.completedFor(.create));
        try expectBytes(tmp.dir, collision, "COLLISION-OWNER");
        try expectOld(tmp.dir, existing, collision);
        try tmp.dir.deleteFile(testing.io, collision);
        try faults.arm(.candidate, 1, error.EntropyUnavailable);
        try testing.expectError(error.EntropyUnavailable, begin(testing.allocator, testing.io, tmp.dir, "target", .{ .faults = &faults }));
        try testing.expectEqual(@as(usize, 32), faults.attemptsFor(.create));
        try faults.arm(.create, 1, error.AccessDenied);
        try testing.expectError(error.AccessDenied, begin(testing.allocator, testing.io, tmp.dir, "target", .{ .faults = &faults }));
        try testing.expectEqual(@as(usize, 33), faults.attemptsFor(.create));
        try expectOld(tmp.dir, existing, null);
    }
}

test "staged output race no replace competing destination and unsupported fail closed" {
    for ([_]bool{ false, true }) |unsupported| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var faults: Faults = .{};
        var pending = try begin(testing.allocator, testing.io, tmp.dir, "target", .{ .mode = .no_replace, .faults = &faults });
        defer pending.deinit();
        try pending.writeAll("NEW");
        var finished = try pending.finish();
        defer finished.deinit();
        if (unsupported) {
            try faults.arm(.rename, 1, error.OperationUnsupported);
            try testing.expectError(error.OperationUnsupported, finished.publish(.no_replace));
            try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "target", .{}));
        } else {
            try put(tmp.dir, "target", "COMPETITOR");
            try testing.expectError(error.DestinationExists, finished.publish(.no_replace));
            try expectBytes(tmp.dir, "target", "COMPETITOR");
        }
        try testing.expectEqual(@as(usize, 1), faults.attemptsFor(.rename));
        try testing.expectEqual(@as(usize, 0), faults.completedFor(.rename));
        try finished.abort();
        try expectEntries(tmp.dir, if (unsupported) &.{} else &.{"target"});
    }
}

test "staged output race collision advances to distinct exclusive candidate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const collision = ".kotoba-output-00000000000000000000000000000000.tmp";
    try put(tmp.dir, collision, "UNTOUCHED");
    const candidates = [_][16]u8{ @splat(0), @splat(1) };
    var faults: Faults = .{ .candidate_sequence = &candidates };
    try atomicWriteFile(testing.allocator, testing.io, tmp.dir, "target", "NEW", .{ .faults = &faults });
    try testing.expectEqual(@as(usize, 2), faults.attemptsFor(.create));
    try testing.expectEqual(@as(usize, 1), faults.completedFor(.create));
    try expectBytes(tmp.dir, collision, "UNTOUCHED");
    try expectBytes(tmp.dir, "target", "NEW");
    try expectEntries(tmp.dir, &.{ collision, "target" });
}

test "staged output path invalid intent and raced directory survive" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "", "bad\x00name" }) |path| try testing.expectError(error.BadPathName, begin(testing.allocator, testing.io, tmp.dir, path, .{}));
    for ([_][]const u8{ "target/", ".", "..", "/" }) |path| try testing.expectError(error.IsDir, begin(testing.allocator, testing.io, tmp.dir, path, .{}));
    try testing.expectError(error.FileNotFound, begin(testing.allocator, testing.io, tmp.dir, "missing/target", .{}));
    try expectEntries(tmp.dir, &.{});
    var pending = try begin(testing.allocator, testing.io, tmp.dir, "target", .{});
    defer pending.deinit();
    try pending.writeAll("NEW");
    var finished = try pending.finish();
    defer finished.deinit();
    try tmp.dir.createDir(testing.io, "target", .default_dir);
    try testing.expectError(error.IsDir, finished.publish(.replace));
    try finished.abort();
    try testing.expectEqual(std.Io.File.Kind.directory, (try tmp.dir.statFile(testing.io, "target", .{})).kind);
    try testing.expectError(error.IsDir, begin(testing.allocator, testing.io, tmp.dir, "target", .{}));
    try expectEntries(tmp.dir, &.{"target"});
}

test "staged output path parent rename pins validation and publication" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "parent", .default_dir);
    var pending = try begin(testing.allocator, testing.io, tmp.dir, "parent/target", .{});
    defer pending.deinit();
    try pending.writeAll("NEW");
    try tmp.dir.rename("parent", tmp.dir, "moved", testing.io);
    try tmp.dir.createDir(testing.io, "parent", .default_dir);
    try put(tmp.dir, "parent/target", "REPLACEMENT-PARENT");
    var finished = try pending.finish();
    defer finished.deinit();
    const reference = try finished.reference();
    try expectBytes(reference.dir, reference.basename, "NEW");
    try finished.publish(.replace);
    try expectBytes(tmp.dir, "moved/target", "NEW");
    try expectBytes(tmp.dir, "parent/target", "REPLACEMENT-PARENT");
    var moved = try tmp.dir.openDir(testing.io, "moved", .{});
    defer moved.close(testing.io);
    try expectEntries(moved, &.{"target"});
}

test "staged output path symlinks dangling links and hardlinks preserve referents" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try put(tmp.dir, "referent", "OLD");
    for ([_]bool{ false, true }) |dangling| {
        try tmp.dir.symLink(testing.io, if (dangling) "missing" else "referent", "link", .{});
        try testing.expectError(error.DestinationExists, begin(testing.allocator, testing.io, tmp.dir, "link", .{ .mode = .no_replace }));
        try atomicWriteFile(testing.allocator, testing.io, tmp.dir, "link", "NEW", .{});
        try expectBytes(tmp.dir, "link", "NEW");
        try expectBytes(tmp.dir, "referent", "OLD");
        try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "missing", .{}));
        try testing.expectEqual(std.Io.File.Kind.file, (try tmp.dir.statFile(testing.io, "link", .{ .follow_symlinks = false })).kind);
        try tmp.dir.deleteFile(testing.io, "link");
    }
    try testing.expectEqual(@as(c_int, 0), std.c.linkat(tmp.dir.handle, "referent", tmp.dir.handle, "hardlink", 0));
    try atomicWriteFile(testing.allocator, testing.io, tmp.dir, "hardlink", "NEW", .{});
    try expectBytes(tmp.dir, "referent", "OLD");
    try expectBytes(tmp.dir, "hardlink", "NEW");
    try expectEntries(tmp.dir, &.{ "referent", "hardlink" });
}

test "staged output cleanup secondary failure retains only owned name and retry works" {
    for ([_]bool{ false, true }) |existing| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try setup(tmp.dir, existing);
        var faults: Faults = .{ .prefix_remaining = 4 };
        try faults.arm(.cleanup, 1, error.AccessDenied);
        var report: CleanupReport = .{};
        var pending = try begin(testing.allocator, testing.io, tmp.dir, "target", .{ .faults = &faults, .cleanup_report = &report });
        defer pending.deinit();
        try testing.expectError(error.NoSpaceLeft, pending.writeAll("NEW-BYTES"));
        try testing.expectError(error.AccessDenied, pending.abort());
        try testing.expectEqual(error.AccessDenied, report.secondary.?);
        try testing.expectEqual(@as(usize, 1), faults.attemptsFor(.close));
        try expectOld(tmp.dir, existing, &pending.storage.?.name);
        try expectBytes(tmp.dir, &pending.storage.?.name, "NEW-");
        try pending.abort();
        try testing.expectEqual(@as(usize, 1), faults.attemptsFor(.close));
        try expectOld(tmp.dir, existing, null);
        try testing.expectEqual(@as(usize, 2), faults.attemptsFor(.cleanup));
    }
}

test "staged output cleanup convenience preserves primary and frees failed cleanup owner" {
    for ([_]bool{ false, true }) |existing| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try setup(tmp.dir, existing);
        var faults: Faults = .{ .prefix_remaining = 4, .candidate_bytes = @splat(0) };
        try faults.arm(.cleanup, 1, error.AccessDenied);
        var report: CleanupReport = .{};
        try testing.expectError(error.NoSpaceLeft, atomicWriteFile(testing.allocator, testing.io, tmp.dir, "target", "NEW-BYTES", .{ .faults = &faults, .cleanup_report = &report }));
        try testing.expectEqual(error.AccessDenied, report.secondary.?);
        const name = ".kotoba-output-00000000000000000000000000000000.tmp";
        try expectOld(tmp.dir, existing, name);
        try expectBytes(tmp.dir, name, "NEW-");
        try tmp.dir.deleteFile(testing.io, name);
        try expectOld(tmp.dir, existing, null);
    }
}

test "staged output cleanup deinit records late close even after successful unlink" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var faults: Faults = .{};
    try faults.arm(.close, 1, error.InputOutput);
    var report: CleanupReport = .{};
    var pending = try begin(testing.allocator, testing.io, tmp.dir, "target", .{ .faults = &faults, .cleanup_report = &report });
    const fd = pending.storage.?.file.?.handle;
    pending.deinit();
    try testing.expectEqual(error.InputOutput, report.secondary.?);
    try testing.expect(pending.storage == null);
    try expectClosed(fd);
    try expectEntries(tmp.dir, &.{});
}

test "staged output cleanup failed finished abort forbids publication and permits retry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var faults: Faults = .{};
    try faults.arm(.cleanup, 1, error.AccessDenied);
    var pending = try begin(testing.allocator, testing.io, tmp.dir, "target", .{ .faults = &faults });
    defer pending.deinit();
    try pending.writeAll("NEW");
    var finished = try pending.finish();
    defer finished.deinit();
    try testing.expectError(error.AccessDenied, finished.abort());
    try testing.expectError(error.InvalidStageState, finished.publish(.replace));
    try testing.expectError(error.InvalidStageState, finished.reference());
    try testing.expectError(error.InvalidStageState, finished.openReadOnly());
    try testing.expectEqual(@as(usize, 0), faults.attemptsFor(.rename));
    try finished.abort();
    try expectEntries(tmp.dir, &.{});
}

test "staged output cleanup consumed owners and close failure never close reused descriptor" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var faults: Faults = .{};
    try faults.arm(.close, 1, error.InputOutput);
    var pending = try begin(testing.allocator, testing.io, tmp.dir, "target", .{ .faults = &faults });
    defer pending.deinit();
    const fd = pending.storage.?.file.?.handle;
    try pending.writeAll("NEW");
    try testing.expectError(error.InputOutput, pending.finish());
    try expectClosed(fd);
    const sentinel = try tmp.dir.createFile(testing.io, "sentinel", .{ .read = true });
    defer sentinel.close(testing.io);
    try testing.expectEqual(fd, sentinel.handle);
    try testing.expectError(error.InvalidStageState, pending.finish());
    try testing.expectError(error.InvalidStageState, pending.writeAll("illegal"));
    try pending.abort();
    try pending.abort();
    try sentinel.writeStreamingAll(testing.io, "ALIVE");
    try expectBytes(tmp.dir, "sentinel", "ALIVE");
    try testing.expectEqual(@as(usize, 1), faults.attemptsFor(.close));
    var next = try begin(testing.allocator, testing.io, tmp.dir, "target", .{});
    defer next.deinit();
    try next.writeAll("NEW");
    var finished = try next.finish();
    defer finished.deinit();
    try testing.expectError(error.InvalidStageState, next.finish());
    try testing.expectError(error.InvalidStageState, next.writeAll("illegal"));
    try next.abort();
    try finished.publish(.replace);
    try testing.expectError(error.InvalidStageState, finished.publish(.replace));
    try testing.expectError(error.InvalidStageState, finished.openReadOnly());
    try testing.expectError(error.InvalidStageState, finished.reference());
    try finished.abort();
    try finished.abort();
    try expectBytes(tmp.dir, "target", "NEW");
}

fn allocationScenario(allocator: std.mem.Allocator, dir: std.Io.Dir) !void {
    var pending = try begin(allocator, testing.io, dir, "target", .{});
    defer pending.deinit();
    try pending.writeAll("NEW");
    var finished = try pending.finish();
    defer finished.deinit();
    try finished.abort();
}

fn fdCount() !usize {
    var dir = try std.Io.Dir.cwd().openDir(testing.io, "/proc/self/fd", .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(testing.io)) |_| count += 1;
    return count;
}

test "staged output cleanup allocation sweep and repeated failure have no FD leaks" {
    for ([_]bool{ false, true }) |existing| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try setup(tmp.dir, existing);
        const before = try fdCount();
        try testing.checkAllAllocationFailures(testing.allocator, allocationScenario, .{tmp.dir});
        try expectOld(tmp.dir, existing, null);
        const operations = [_]Faults.Operation{ .candidate, .create, .write, .flush, .sync, .close, .rename };
        for (0..8) |_| for (operations) |op| {
            var faults: Faults = .{};
            try faults.arm(op, 1, error.InputOutput);
            try testing.expectError(error.InputOutput, atomicWriteFile(testing.allocator, testing.io, tmp.dir, "target", "NEW", .{ .faults = &faults }));
        };
        try testing.expectEqual(before, try fdCount());
        try expectOld(tmp.dir, existing, null);
        std.debug.print("[component-real-files+injected] existing={any} allocation_sites=2 OOM_sweep=pass FD_before={d} FD_after={d} failure_iterations=56\n", .{ existing, before, try fdCount() });
    }
}
