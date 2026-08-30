const std = @import("std");
const doctor = @import("../doctor.zig");
const errors = @import("../errors.zig");
const xdg = @import("../xdg.zig");

pub const Options = struct { json: bool };

pub fn parse(cmd_args: []const []const u8) !Options {
    if (cmd_args.len == 0) return .{ .json = false };
    if (cmd_args.len == 2 and std.mem.eql(u8, cmd_args[0], "--format") and std.mem.eql(u8, cmd_args[1], "json")) return .{ .json = true };
    return errors.Error.InvalidArguments;
}

pub fn run(original_allocator: std.mem.Allocator, resolution: xdg.Resolution, options: Options) !u8 {
    return doctor.runResolution(original_allocator, resolution, options.json);
}

pub fn runWithPaths(original_allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    const options = try parse(cmd_args);
    return doctor.run(original_allocator, paths, options.json);
}

test "doctor arguments accept only no args or exact JSON format" {
    try std.testing.expect(!(try parse(&.{})).json);
    try std.testing.expect((try parse(&.{ "--format", "json" })).json);
    try std.testing.expectError(errors.Error.InvalidArguments, parse(&.{"extra"}));
    try std.testing.expectError(errors.Error.InvalidArguments, parse(&.{ "--format", "json", "extra" }));
    try std.testing.expectError(errors.Error.InvalidArguments, parse(&.{ "--format", "human" }));
}
