const std = @import("std");

pub const PathState = union(enum) {
    not_found,
    present: std.Io.File.Stat,
};

pub const Faults = struct {
    pub const Operation = enum { write, rename, delete, stat, realpath };
    pub const Cause = error{ AccessDenied, NoSpaceLeft, InputOutput };
    const Rule = struct { target: usize, cause: Cause };
    const operation_count = @typeInfo(Operation).@"enum".fields.len;

    attempts: [operation_count]usize = @splat(0),
    completed: [operation_count]usize = @splat(0),
    rules: [operation_count]?Rule = @splat(null),
    last_cause: ?Cause = null,

    pub fn attemptsFor(self: *const Faults, operation: Operation) usize {
        return self.attempts[@intFromEnum(operation)];
    }

    pub fn completedFor(self: *const Faults, operation: Operation) usize {
        return self.completed[@intFromEnum(operation)];
    }

    pub fn arm(self: *Faults, operation: Operation, ordinal: usize, cause: Cause) !void {
        if (ordinal == 0) return error.InvalidFaultOrdinal;
        const valid_cause = switch (operation) {
            .write => cause == error.AccessDenied or cause == error.NoSpaceLeft,
            .rename, .delete => cause == error.AccessDenied,
            .stat, .realpath => cause == error.InputOutput,
        };
        if (!valid_cause) return error.InvalidFaultCause;
        const index = @intFromEnum(operation);
        self.rules[index] = .{ .target = try std.math.add(usize, self.attempts[index], ordinal), .cause = cause };
    }

    pub fn disarm(self: *Faults) void {
        self.rules = @splat(null);
    }

    fn check(self: *Faults, operation: Operation) ?Cause {
        const index = @intFromEnum(operation);
        self.attempts[index] += 1;
        if (self.rules[index]) |rule| {
            if (self.attempts[index] == rule.target) {
                self.rules[index] = null;
                self.last_cause = rule.cause;
                return rule.cause;
            }
        }
        return null;
    }

    fn complete(self: *Faults, operation: Operation) void {
        self.completed[@intFromEnum(operation)] += 1;
    }
};

pub const FileSystem = struct {
    io: std.Io,
    dir: std.Io.Dir,
    borrowed_faults: ?*Faults = null,

    pub fn init(io: std.Io, dir: std.Io.Dir, borrowed_faults: ?*Faults) FileSystem {
        return .{ .io = io, .dir = dir, .borrowed_faults = borrowed_faults };
    }

    pub fn writeFile(self: *FileSystem, path: []const u8, data: []const u8) !void {
        if (self.injected(.write)) |cause| return cause;
        var file = try self.dir.createFile(self.io, path, .{ .truncate = true });
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, data);
        self.finished(.write);
    }

    pub fn renameFile(self: *FileSystem, source: []const u8, destination: []const u8) !void {
        if (self.injected(.rename)) |cause| return cause;
        try self.dir.rename(source, self.dir, destination, self.io);
        self.finished(.rename);
    }

    pub fn createExclusiveFile(self: *FileSystem, path: []const u8, permissions: std.Io.File.Permissions) !std.Io.File {
        return self.dir.createFile(self.io, path, .{ .exclusive = true, .truncate = false, .permissions = permissions });
    }

    pub fn renameFilePreserve(self: *FileSystem, source: []const u8, destination: []const u8) !void {
        if (self.injected(.rename)) |cause| return cause;
        try self.dir.renamePreserve(source, self.dir, destination, self.io);
        self.finished(.rename);
    }

    pub fn openReadOnly(self: *FileSystem, path: []const u8) !std.Io.File {
        return self.dir.openFile(self.io, path, .{ .mode = .read_only });
    }

    pub fn deleteFile(self: *FileSystem, path: []const u8) !void {
        if (self.injected(.delete)) |cause| return cause;
        try self.dir.deleteFile(self.io, path);
        self.finished(.delete);
    }

    pub fn pathState(self: *FileSystem, path: []const u8) !PathState {
        if (self.injected(.stat)) |cause| return cause;
        const stat = self.dir.statFile(self.io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return .not_found,
            else => |cause| return cause,
        };
        self.finished(.stat);
        return .{ .present = stat };
    }

    pub fn removeFileIfExists(self: *FileSystem, path: []const u8) !bool {
        if (self.injected(.delete)) |cause| return cause;
        self.dir.deleteFile(self.io, path) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => |cause| return cause,
        };
        self.finished(.delete);
        return true;
    }

    pub fn realPathIfExistsAlloc(self: *FileSystem, allocator: std.mem.Allocator, path: []const u8) !?[:0]u8 {
        if (self.injected(.realpath)) |cause| return cause;
        const real_path = self.dir.realPathFileAlloc(self.io, path, allocator) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => |cause| return cause,
        };
        self.finished(.realpath);
        return real_path;
    }

    fn injected(self: *FileSystem, operation: Faults.Operation) ?Faults.Cause {
        return if (self.borrowed_faults) |faults| faults.check(operation) else null;
    }

    fn finished(self: *FileSystem, operation: Faults.Operation) void {
        if (self.borrowed_faults) |faults| faults.complete(operation);
    }
};

fn put(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = bytes, .flags = .{ .truncate = true } });
}

fn expectBytes(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    const bytes = try dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(expected, bytes);
}

fn expectEntries(dir: std.Io.Dir, expected: []const []const u8) !void {
    var iterable_dir = try dir.openDir(std.testing.io, ".", .{ .iterate = true });
    defer iterable_dir.close(std.testing.io);
    var iterator = iterable_dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        count += 1;
        var found = false;
        for (expected) |name| {
            if (std.mem.eql(u8, entry.name, name)) found = true;
        }
        try std.testing.expect(found);
    }
    try std.testing.expectEqual(expected.len, count);
}

test "fault fs happy real write rename delete sequence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var filesystem = FileSystem.init(std.testing.io, tmp.dir, null);

    try filesystem.writeFile("target", "old");
    try filesystem.writeFile("target", "new");
    try expectBytes(tmp.dir, "target", "new");
    try filesystem.renameFile("target", "renamed");
    try expectBytes(tmp.dir, "renamed", "new");
    try expectEntries(tmp.dir, &.{"renamed"});
    try filesystem.deleteFile("renamed");
    try expectEntries(tmp.dir, &.{});
}

test "fault fs happy independent defaults use real local directories" {
    var left_tmp = std.testing.tmpDir(.{});
    defer left_tmp.cleanup();
    var right_tmp = std.testing.tmpDir(.{});
    defer right_tmp.cleanup();
    var left = FileSystem.init(std.testing.io, left_tmp.dir, null);
    var right = FileSystem.init(std.testing.io, right_tmp.dir, null);

    try left.writeFile("left", "one");
    try right.writeFile("right", "two");
    try left.renameFile("left", "left-final");
    try right.deleteFile("right");
    try expectEntries(left_tmp.dir, &.{"left-final"});
    try expectEntries(right_tmp.dir, &.{});
}

test "fault fs failure injected write preserves data and entry set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try put(tmp.dir, "target", "old");

    var faults: Faults = .{};
    try faults.arm(.write, 1, error.NoSpaceLeft);
    var filesystem = FileSystem.init(std.testing.io, tmp.dir, &faults);

    try std.testing.expectError(error.NoSpaceLeft, filesystem.writeFile("target", "new"));
    try expectBytes(tmp.dir, "target", "old");
    try expectEntries(tmp.dir, &.{"target"});
    try std.testing.expectEqual(@as(usize, 1), faults.attemptsFor(.write));
    try std.testing.expectEqual(@as(usize, 0), faults.completedFor(.write));
    try std.testing.expectEqual(error.NoSpaceLeft, faults.last_cause.?);

    try filesystem.writeFile("target", "recovered");
    try expectBytes(tmp.dir, "target", "recovered");
    try std.testing.expectEqual(@as(usize, 2), faults.attemptsFor(.write));
    try std.testing.expectEqual(@as(usize, 1), faults.completedFor(.write));
}

test "fault fs failure rename preserves existing and absent destinations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try put(tmp.dir, "source", "source bytes");
    try put(tmp.dir, "destination", "destination bytes");

    var faults: Faults = .{};
    try faults.arm(.rename, 1, error.AccessDenied);
    var filesystem = FileSystem.init(std.testing.io, tmp.dir, &faults);
    try std.testing.expectError(error.AccessDenied, filesystem.renameFile("source", "destination"));
    try expectBytes(tmp.dir, "source", "source bytes");
    try expectBytes(tmp.dir, "destination", "destination bytes");
    try expectEntries(tmp.dir, &.{ "source", "destination" });
    try std.testing.expectEqual(@as(usize, 1), faults.attemptsFor(.rename));
    try std.testing.expectEqual(@as(usize, 0), faults.completedFor(.rename));

    try faults.arm(.rename, 1, error.AccessDenied);
    try tmp.dir.deleteFile(std.testing.io, "destination");
    try std.testing.expectError(error.AccessDenied, filesystem.renameFile("source", "destination"));
    try expectBytes(tmp.dir, "source", "source bytes");
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "destination", .{}));
    try expectEntries(tmp.dir, &.{"source"});
    try std.testing.expectEqual(@as(usize, 2), faults.attemptsFor(.rename));
    try std.testing.expectEqual(@as(usize, 0), faults.completedFor(.rename));
}

test "fault fs failure delete retains file and explicit disarm recovers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try put(tmp.dir, "victim", "keep");
    var faults: Faults = .{};
    try faults.arm(.delete, 1, error.AccessDenied);
    var filesystem = FileSystem.init(std.testing.io, tmp.dir, &faults);

    try std.testing.expectError(error.AccessDenied, filesystem.deleteFile("victim"));
    try expectBytes(tmp.dir, "victim", "keep");
    try expectEntries(tmp.dir, &.{"victim"});
    try std.testing.expectEqual(@as(usize, 1), faults.attemptsFor(.delete));
    try std.testing.expectEqual(@as(usize, 0), faults.completedFor(.delete));

    try faults.arm(.delete, 1, error.AccessDenied);
    faults.disarm();
    try filesystem.deleteFile("victim");
    try expectEntries(tmp.dir, &.{});
    try std.testing.expectEqual(@as(usize, 2), faults.attemptsFor(.delete));
    try std.testing.expectEqual(@as(usize, 1), faults.completedFor(.delete));
}

test "fault fs failure second matching call ignores unrelated operations and controllers" {
    var left_tmp = std.testing.tmpDir(.{});
    defer left_tmp.cleanup();
    var right_tmp = std.testing.tmpDir(.{});
    defer right_tmp.cleanup();
    try put(left_tmp.dir, "first", "first");
    try put(left_tmp.dir, "second", "old second");
    try put(right_tmp.dir, "source", "right");

    var left_faults: Faults = .{};
    var right_faults: Faults = .{};
    try left_faults.arm(.write, 2, error.AccessDenied);
    try right_faults.arm(.rename, 1, error.AccessDenied);
    var left = FileSystem.init(std.testing.io, left_tmp.dir, &left_faults);
    var right = FileSystem.init(std.testing.io, right_tmp.dir, &right_faults);

    try left.writeFile("first", "updated first");
    try left.renameFile("first", "renamed");
    try std.testing.expectError(error.AccessDenied, left.writeFile("second", "new second"));
    try expectBytes(left_tmp.dir, "second", "old second");
    try left.writeFile("second", "recovered second");
    try expectBytes(left_tmp.dir, "second", "recovered second");
    try std.testing.expectEqual(@as(usize, 3), left_faults.attemptsFor(.write));
    try std.testing.expectEqual(@as(usize, 2), left_faults.completedFor(.write));
    try std.testing.expectEqual(@as(usize, 1), left_faults.attemptsFor(.rename));
    try std.testing.expectEqual(@as(usize, 1), left_faults.completedFor(.rename));

    try std.testing.expectError(error.AccessDenied, right.renameFile("source", "destination"));
    try expectBytes(right_tmp.dir, "source", "right");
    try std.testing.expectError(error.FileNotFound, right_tmp.dir.access(std.testing.io, "destination", .{}));
    try std.testing.expectEqual(@as(usize, 1), right_faults.attemptsFor(.rename));
    try std.testing.expectEqual(@as(usize, 0), right_faults.completedFor(.rename));
}

test "strict fs happy distinguishes missing entries and removes regular files" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var filesystem = FileSystem.init(std.testing.io, tmp.dir, null);

    try std.testing.expectEqual(PathState.not_found, try filesystem.pathState("missing"));
    try put(tmp.dir, "target", "target bytes");
    try tmp.dir.symLink(std.testing.io, "missing-target", "dangling", .{});
    try put(tmp.dir, "unrelated", "keep");

    switch (try filesystem.pathState("target")) {
        .not_found => return error.TestUnexpectedResult,
        .present => |stat| try std.testing.expectEqual(std.Io.File.Kind.file, stat.kind),
    }
    switch (try filesystem.pathState("dangling")) {
        .not_found => return error.TestUnexpectedResult,
        .present => |stat| try std.testing.expectEqual(std.Io.File.Kind.sym_link, stat.kind),
    }
    try std.testing.expect(try filesystem.removeFileIfExists("target"));
    try std.testing.expect(!(try filesystem.removeFileIfExists("target")));
    try expectBytes(tmp.dir, "unrelated", "keep");
    try expectEntries(tmp.dir, &.{ "dangling", "unrelated" });
}

test "strict fs failure propagates native and injected errors" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "directory", .default_dir);
    try tmp.dir.createDir(std.testing.io, "locked", .default_dir);
    try put(tmp.dir, "locked/victim", "keep");

    var faults: Faults = .{};
    try std.testing.expectError(error.InvalidFaultOrdinal, faults.arm(.stat, 0, error.InputOutput));
    try std.testing.expectError(error.InvalidFaultCause, faults.arm(.stat, 1, error.AccessDenied));
    try std.testing.expectError(error.InvalidFaultCause, faults.arm(.delete, 1, error.InputOutput));
    try faults.arm(.stat, 1, error.InputOutput);
    var filesystem = FileSystem.init(std.testing.io, tmp.dir, &faults);

    try std.testing.expectError(error.InputOutput, filesystem.pathState("directory"));
    try std.testing.expectEqual(@as(usize, 1), faults.attemptsFor(.stat));
    try std.testing.expectEqual(@as(usize, 0), faults.completedFor(.stat));
    switch (try filesystem.pathState("directory")) {
        .not_found => return error.TestUnexpectedResult,
        .present => |stat| try std.testing.expectEqual(std.Io.File.Kind.directory, stat.kind),
    }
    try std.testing.expectEqual(@as(usize, 2), faults.attemptsFor(.stat));
    try std.testing.expectEqual(@as(usize, 1), faults.completedFor(.stat));
    try std.testing.expectError(error.IsDir, filesystem.removeFileIfExists("directory"));
    try faults.arm(.realpath, 1, error.InputOutput);
    try std.testing.expectError(error.InputOutput, filesystem.realPathIfExistsAlloc(std.testing.allocator, "directory"));
    try std.testing.expectEqual(@as(usize, 1), faults.attemptsFor(.realpath));
    try std.testing.expectEqual(@as(usize, 0), faults.completedFor(.realpath));
    const real_directory = (try filesystem.realPathIfExistsAlloc(std.testing.allocator, "directory")) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(real_directory);
    try std.testing.expectEqual(@as(usize, 2), faults.attemptsFor(.realpath));
    try std.testing.expectEqual(@as(usize, 1), faults.completedFor(.realpath));

    var locked = try tmp.dir.openDir(std.testing.io, "locked", .{ .iterate = true });
    defer locked.close(std.testing.io);
    defer locked.setPermissions(std.testing.io, .default_dir) catch unreachable;
    try locked.setPermissions(std.testing.io, .fromMode(0));
    try std.testing.expectError(error.AccessDenied, filesystem.pathState("locked/victim"));
    try std.testing.expectError(error.AccessDenied, filesystem.removeFileIfExists("locked/victim"));
}
