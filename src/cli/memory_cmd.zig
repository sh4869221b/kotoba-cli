const std = @import("std");
const errors = @import("../errors.zig");
const memory = @import("../memory.zig");
const sys = @import("../sys.zig");
const xdg = @import("../xdg.zig");

pub fn run(original_allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    var invocation_arena = std.heap.ArenaAllocator.init(original_allocator);
    defer invocation_arena.deinit();
    const allocator = invocation_arena.allocator();
    if (cmd_args.len < 1) return errors.Error.InvalidArguments;
    if (std.mem.eql(u8, cmd_args[0], "status")) {
        if (cmd_args.len != 1) return errors.Error.InvalidArguments;
        const rows = rows: {
            sys.cwd().access(sys.io(), paths.memory_file, .{}) catch |err| switch (err) {
                error.FileNotFound => break :rows 0,
                else => return errors.Error.SqliteFailed,
            };
            var db = try memory.openReadOnly(allocator, paths.memory_file);
            defer db.close();
            break :rows try db.count();
        };
        try sys.stdoutPrint("path: {s}\nrows: {d}\n", .{ paths.memory_file, rows });
        return 0;
    }
    if (std.mem.eql(u8, cmd_args[0], "clear")) {
        if (cmd_args.len != 2 or !std.mem.eql(u8, cmd_args[1], "--yes")) return errors.Error.InvalidArguments;
        var db = try memory.open(allocator, paths.memory_file);
        defer db.close();
        try db.clear();
        return 0;
    }
    return errors.Error.InvalidArguments;
}

test "memory validates commands before opening a missing database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    var paths: xdg.Paths = undefined;
    paths.memory_file = try std.fs.path.join(allocator, &.{ root, "memory.sqlite3" });
    const invalid = [_][]const []const u8{ &.{}, &.{"bogus"}, &.{ "status", "extra" }, &.{"clear"}, &.{ "clear", "--yes", "extra" } };
    for (invalid) |args| {
        try std.testing.expectError(errors.Error.InvalidArguments, run(allocator, paths, args));
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "memory.sqlite3", .{}));
    }
}

test "memory status does not create missing databases or initialize existing empty files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const captured = try tmp.dir.createFile(std.testing.io, "stdout", .{});
    defer captured.close(std.testing.io);
    const saved_stdout = std.c.dup(std.posix.STDOUT_FILENO);
    if (saved_stdout < 0) return error.StdoutDuplicateFailed;
    defer _ = std.c.close(saved_stdout);
    if (std.c.dup2(captured.handle, std.posix.STDOUT_FILENO) < 0) return error.StdoutCaptureFailed;
    defer if (std.c.dup2(saved_stdout, std.posix.STDOUT_FILENO) < 0) @panic("stdout restore failed");
    var paths: xdg.Paths = undefined;
    for ([_][]const u8{ "missing/memory.sqlite3", "memory.sqlite3" }) |relative| {
        paths.memory_file = try std.fs.path.join(allocator, &.{ root, relative });
        try std.testing.expectEqual(@as(u8, 0), try run(allocator, paths, &.{"status"}));
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, relative, .{}));
    }
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "memory.sqlite3", .data = "" });
    try std.testing.expectError(errors.Error.SqliteFailed, run(allocator, paths, &.{"status"}));
    const stat = try tmp.dir.statFile(std.testing.io, "memory.sqlite3", .{});
    try std.testing.expectEqual(@as(u64, 0), stat.size);
}
