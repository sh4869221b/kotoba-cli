const std = @import("std");
const errors = @import("../errors.zig");
const glossary = @import("../glossary.zig");
const sys = @import("../sys.zig");
const xdg = @import("../xdg.zig");

pub fn run(original_allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    var invocation_arena = std.heap.ArenaAllocator.init(original_allocator);
    defer invocation_arena.deinit();
    const allocator = invocation_arena.allocator();
    if (cmd_args.len != 1 or !std.mem.eql(u8, cmd_args[0], "validate")) return errors.Error.InvalidArguments;
    var g_owner = try glossary.load(allocator, paths.glossary_file);
    defer g_owner.deinit();
    const g = g_owner.view();
    sys.stdoutPrint("terms: {d}\nhash: {x}\n", .{ g.terms.len, glossary.hash(g) });
    return 0;
}
