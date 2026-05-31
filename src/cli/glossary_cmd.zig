const std = @import("std");
const errors = @import("../errors.zig");
const glossary = @import("../glossary.zig");
const sys = @import("../sys.zig");
const xdg = @import("../xdg.zig");

pub fn run(allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    if (cmd_args.len != 1 or !std.mem.eql(u8, cmd_args[0], "validate")) return errors.Error.InvalidArguments;
    const g = try glossary.load(allocator, paths.glossary_file);
    sys.stdoutPrint("terms: {d}\nhash: {x}\n", .{ g.terms.len, glossary.hash(g) });
    return 0;
}
