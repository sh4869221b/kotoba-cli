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
        if (args_slice.len != 2) return errors.Error.InvalidArguments;
        const sys = @import("sys.zig");
        sys.stdoutPrint("kotoba {s}\n", .{version});
        return 0;
    }
    if (!std.mem.eql(u8, cmd, "init") and
        !std.mem.eql(u8, cmd, "translate") and
        !std.mem.eql(u8, cmd, "doctor") and
        !std.mem.eql(u8, cmd, "config") and
        !std.mem.eql(u8, cmd, "models") and
        !std.mem.eql(u8, cmd, "memory") and
        !std.mem.eql(u8, cmd, "glossary")) return errors.Error.InvalidArguments;
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const captured = try tmp.dir.createFile(std.testing.io, "stdout", .{});
    defer captured.close(std.testing.io);
    const saved_stdout = std.c.dup(std.posix.STDOUT_FILENO);
    if (saved_stdout < 0) return error.StdoutDuplicateFailed;
    defer _ = std.c.close(saved_stdout);
    const test_args = [_][]const u8{ "kotoba", "version" };
    const status = result: {
        if (std.c.dup2(captured.handle, std.posix.STDOUT_FILENO) < 0) return error.StdoutCaptureFailed;
        // The standard test runner reserves stdout for its control protocol.
        defer if (std.c.dup2(saved_stdout, std.posix.STDOUT_FILENO) < 0) @panic("stdout restore failed");
        break :result try run(std.testing.allocator, &test_args);
    };
    try std.testing.expectEqual(@as(u8, 0), status);
    const output = try tmp.dir.readFileAlloc(std.testing.io, "stdout", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("kotoba " ++ version ++ "\n", output);
}

test "version and unknown commands reject invalid arguments" {
    try std.testing.expectError(errors.Error.InvalidArguments, run(std.testing.allocator, &.{ "kotoba", "version", "extra" }));
    try std.testing.expectError(errors.Error.InvalidArguments, run(std.testing.allocator, &.{ "kotoba", "unknown" }));
}

test "json error preference" {
    const test_args = [_][]const u8{ "kotoba", "translate", "Hello", "--format", "json" };
    try std.testing.expect(errorPrefersJson(&test_args));
}
