const std = @import("std");

pub const Faults = struct {
    pub const Operation = enum { write, rename, delete };
    pub const Cause = error{ AccessDenied, NoSpaceLeft };
    const Rule = struct { target: usize, cause: Cause };

    attempts: [3]usize = .{ 0, 0, 0 },
    completed: [3]usize = .{ 0, 0, 0 },
    rules: [3]?Rule = .{ null, null, null },
    last_cause: ?Cause = null,

    pub fn attemptsFor(self: *const Faults, operation: Operation) usize {
        return self.attempts[@intFromEnum(operation)];
    }

    pub fn completedFor(self: *const Faults, operation: Operation) usize {
        return self.completed[@intFromEnum(operation)];
    }

    pub fn arm(self: *Faults, operation: Operation, ordinal: usize, cause: Cause) !void {
        if (ordinal == 0) return error.InvalidFaultOrdinal;
        if (operation != .write and cause != error.AccessDenied) return error.InvalidFaultCause;
        const index = @intFromEnum(operation);
        self.rules[index] = .{ .target = try std.math.add(usize, self.attempts[index], ordinal), .cause = cause };
    }

    pub fn disarm(self: *Faults) void {
        self.rules = .{ null, null, null };
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

    pub fn deleteFile(self: *FileSystem, path: []const u8) !void {
        if (self.injected(.delete)) |cause| return cause;
        try self.dir.deleteFile(self.io, path);
        self.finished(.delete);
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
