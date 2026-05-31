const std = @import("std");
const errors = @import("errors.zig");
const xdg = @import("xdg.zig");
const args = @import("cli/args.zig");
const init_cmd = @import("cli/init_cmd.zig");
const translate_cmd = @import("cli/translate_cmd.zig");
const doctor_cmd = @import("cli/doctor_cmd.zig");
const config_cmd = @import("cli/config_cmd.zig");
const models_cmd = @import("cli/models_cmd.zig");
const memory_cmd = @import("cli/memory_cmd.zig");
const glossary_cmd = @import("cli/glossary_cmd.zig");

const version = "0.0.1";

pub fn run(allocator: std.mem.Allocator, args_slice: []const []const u8) !u8 {
    if (args_slice.len < 2) return errors.Error.InvalidArguments;
    const cmd = args_slice[1];
    if (std.mem.eql(u8, cmd, "version")) {
        const sys = @import("sys.zig");
        sys.stdoutPrint("kotoba {s}\n", .{version});
        return 0;
    }
    const paths = try xdg.paths(allocator);
    if (std.mem.eql(u8, cmd, "init")) return init_cmd.run(allocator, paths, args_slice[2..]);
    if (std.mem.eql(u8, cmd, "translate")) return translate_cmd.run(allocator, paths, args_slice[2..]);
    if (std.mem.eql(u8, cmd, "doctor")) return doctor_cmd.run(allocator, paths, args_slice[2..]);
    if (std.mem.eql(u8, cmd, "config")) return config_cmd.run(allocator, paths, args_slice[2..]);
    if (std.mem.eql(u8, cmd, "models")) return models_cmd.run(allocator, paths, args_slice[2..]);
    if (std.mem.eql(u8, cmd, "memory")) return memory_cmd.run(allocator, paths, args_slice[2..]);
    if (std.mem.eql(u8, cmd, "glossary")) return glossary_cmd.run(allocator, paths, args_slice[2..]);
    return errors.Error.InvalidArguments;
}

pub fn errorPrefersJson(args_slice: []const []const u8) bool {
    if (args_slice.len >= 2 and std.mem.eql(u8, args_slice[1], "doctor")) {
        return args.hasOptionValue(args_slice[2..], "--format", "json");
    }
    if (args_slice.len >= 2 and std.mem.eql(u8, args_slice[1], "translate")) {
        return args.hasOptionValue(args_slice[2..], "--format", "json");
    }
    return false;
}

test "version command" {
    const test_args = [_][]const u8{ "kotoba", "version" };
    _ = try run(std.testing.allocator, &test_args);
}

test "json error preference" {
    const test_args = [_][]const u8{ "kotoba", "translate", "Hello", "--format", "json" };
    try std.testing.expect(errorPrefersJson(&test_args));
}
