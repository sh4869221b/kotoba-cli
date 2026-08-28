const std = @import("std");
const config = @import("../config.zig");
const errors = @import("../errors.zig");
const sys = @import("../sys.zig");
const xdg = @import("../xdg.zig");

pub fn run(original_allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    var invocation_arena = std.heap.ArenaAllocator.init(original_allocator);
    defer invocation_arena.deinit();
    const allocator = invocation_arena.allocator();
    if (cmd_args.len < 1) return errors.Error.InvalidArguments;
    if (std.mem.eql(u8, cmd_args[0], "list")) {
        if (cmd_args.len != 1) return errors.Error.InvalidArguments;
        for (config.settable_keys) |key| sys.stdoutPrint("{s}\n", .{key});
        return 0;
    }
    if (std.mem.eql(u8, cmd_args[0], "get")) {
        if (cmd_args.len != 2) return errors.Error.InvalidArguments;
        try validateConfigKey(cmd_args[1]);
        var cfg = try config.load(allocator, paths.config_file);
        defer cfg.deinit();
        try printConfigValue(cfg.view(), cmd_args[1]);
        return 0;
    }
    if (std.mem.eql(u8, cmd_args[0], "set")) {
        if (cmd_args.len != 3) return errors.Error.InvalidArguments;
        try validateConfigSet(allocator, cmd_args[1], cmd_args[2]);
        var cfg = try config.load(allocator, paths.config_file);
        defer cfg.deinit();
        try cfg.setValue(cmd_args[1], cmd_args[2]);
        try config.save(paths.config_file, cfg.view());
        return 0;
    }
    return errors.Error.InvalidArguments;
}

fn validateConfigKey(key: []const u8) !void {
    for (config.settable_keys) |candidate| {
        if (std.mem.eql(u8, candidate, key)) return;
    }
    return errors.Error.InvalidArguments;
}

fn validateConfigSet(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    try validateConfigKey(key);
    var cfg = try config.OwnedConfig.clone(allocator, config.default());
    defer cfg.deinit();
    try cfg.setValue(key, value);
}

fn printConfigValue(cfg: config.Config, key: []const u8) !void {
    if (std.mem.eql(u8, key, "model_id")) sys.stdoutPrint("{s}\n", .{cfg.model_id}) else if (std.mem.eql(u8, key, "model_path")) sys.stdoutPrint("{s}\n", .{cfg.model_path}) else if (std.mem.eql(u8, key, "gpu_layers")) sys.stdoutPrint("{d}\n", .{cfg.gpu_layers}) else if (std.mem.eql(u8, key, "context_length")) sys.stdoutPrint("{d}\n", .{cfg.context_length}) else if (std.mem.eql(u8, key, "threads")) sys.stdoutPrint("{d}\n", .{cfg.threads}) else if (std.mem.eql(u8, key, "max_tokens")) sys.stdoutPrint("{d}\n", .{cfg.max_tokens}) else if (std.mem.eql(u8, key, "temperature")) sys.stdoutPrint("{d}\n", .{cfg.temperature}) else if (std.mem.eql(u8, key, "timeout_sec")) sys.stdoutPrint("{d}\n", .{cfg.timeout_sec}) else if (std.mem.eql(u8, key, "default_target_lang")) sys.stdoutPrint("{s}\n", .{cfg.default_target_lang.asText()}) else if (std.mem.eql(u8, key, "default_source_lang")) sys.stdoutPrint("{s}\n", .{if (cfg.default_source_lang) |l| l.asText() else ""}) else if (std.mem.eql(u8, key, "default_mode")) sys.stdoutPrint("{s}\n", .{cfg.default_mode.asText()}) else if (std.mem.eql(u8, key, "default_output")) sys.stdoutPrint("{s}\n", .{cfg.default_output.asText()}) else if (std.mem.eql(u8, key, "memory_enabled")) sys.stdoutPrint("{}\n", .{cfg.memory_enabled}) else if (std.mem.eql(u8, key, "glossary_enabled")) sys.stdoutPrint("{}\n", .{cfg.glossary_enabled}) else if (std.mem.eql(u8, key, "privacy_mode")) sys.stdoutPrint("{}\n", .{cfg.privacy_mode}) else if (std.mem.eql(u8, key, "log_level")) sys.stdoutPrint("{s}\n", .{cfg.log_level}) else return errors.Error.InvalidArguments;
}

test "config validates invalid commands before loading configuration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const missing = try std.fs.path.join(std.testing.allocator, &.{ root, "missing", "config.toml" });
    defer std.testing.allocator.free(missing);
    var paths: xdg.Paths = undefined;
    paths.config_file = missing;

    for ([_][]const []const u8{ &.{"bogus"}, &.{ "get", "unknown" }, &.{ "set", "unknown", "value" }, &.{ "set", "gpu_layers", "nope" } }) |cmd_args| {
        try std.testing.expectError(errors.Error.InvalidArguments, run(std.testing.allocator, paths, cmd_args));
    }
    try std.testing.expectError(errors.Error.NotInitialized, run(std.testing.allocator, paths, &.{ "set", "model_id", "test" }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "missing", .{}));
}
