const std = @import("std");
const errors = @import("../errors.zig");
const memory = @import("../memory.zig");
const sys = @import("../sys.zig");
const xdg = @import("../xdg.zig");

pub fn run(allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    if (cmd_args.len < 1) return errors.Error.InvalidArguments;
    var db = try memory.open(allocator, paths.memory_file);
    defer db.close();
    if (std.mem.eql(u8, cmd_args[0], "status")) {
        sys.stdoutPrint("path: {s}\nrows: {d}\n", .{ paths.memory_file, try db.count() });
        return 0;
    }
    if (std.mem.eql(u8, cmd_args[0], "clear")) {
        if (cmd_args.len != 2 or !std.mem.eql(u8, cmd_args[1], "--yes")) return errors.Error.InvalidArguments;
        try db.clear();
        return 0;
    }
    return errors.Error.InvalidArguments;
}
