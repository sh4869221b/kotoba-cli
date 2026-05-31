const std = @import("std");
const doctor = @import("../doctor.zig");
const errors = @import("../errors.zig");
const xdg = @import("../xdg.zig");

pub fn run(allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    var json = false;
    if (cmd_args.len == 2 and std.mem.eql(u8, cmd_args[0], "--format") and std.mem.eql(u8, cmd_args[1], "json")) json = true else if (cmd_args.len != 0) return errors.Error.InvalidArguments;
    return doctor.run(allocator, paths, json);
}
