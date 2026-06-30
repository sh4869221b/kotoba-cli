const std = @import("std");
const config = @import("config.zig");
const errors = @import("errors.zig");
const lang = @import("lang.zig");
const sys = @import("sys.zig");

test "config round trip parse" {
    const cfg = try config.parse(std.heap.page_allocator,
        \\default_source_lang = ""
        \\default_target_lang = "ja"
        \\model_id = "local-ja"
        \\model_path = "/tmp/local-ja.gguf"
        \\context_length = 4096
        \\threads = 0
        \\max_tokens = 1024
        \\temperature = 0.2
        \\timeout_sec = 120
        \\memory_enabled = true
    );
    try std.testing.expectEqual(lang.Language.ja, cfg.default_target_lang);
    try std.testing.expectEqualStrings("local-ja", cfg.model_id);
    try std.testing.expectEqualStrings("/tmp/local-ja.gguf", cfg.model_path);
    try std.testing.expectEqual(@as(u32, 4096), cfg.context_length);
    try std.testing.expectEqual(@as(u32, 0), cfg.threads);
    try std.testing.expectEqual(@as(u32, 1024), cfg.max_tokens);
    try std.testing.expectEqual(@as(f32, 0.2), cfg.temperature);
    try std.testing.expectEqual(@as(u32, 120), cfg.timeout_sec);
    try std.testing.expect(cfg.memory_enabled);
}

test "embedded config rejects removed server keys and negative unsigned settings" {
    var cfg = config.default();
    inline for (.{
        .{ "runtime", "llama_server" },
        .{ "server_url", "http://127.0.0.1:8080" },
        .{ "server_autostart", "true" },
        .{ "llama_server_path", "llama-server" },
        .{ "server_startup_timeout_sec", "60" },
    }) |case| try std.testing.expectError(errors.Error.InvalidArguments, config.setValue(std.testing.allocator, &cfg, case[0], case[1]));
    inline for (.{ "threads", "context_length", "max_tokens", "timeout_sec" }) |key| {
        try std.testing.expectError(errors.Error.ConfigInvalid, config.parse(std.testing.allocator, key ++ " = -1\n"));
    }
}

test "config parses saves gets sets and lists signed gpu layers" {
    inline for (.{
        .{ "gpu_layers = -1\n", -1 },
        .{ "gpu_layers = 0\n", 0 },
        .{ "gpu_layers = 24\n", 24 },
    }) |case| try std.testing.expectEqual(@as(i32, case[1]), (try config.parse(std.testing.allocator, case[0])).gpu_layers);
    var cfg = config.default();
    try std.testing.expectEqual(@as(i32, -1), cfg.gpu_layers);
    inline for (.{ "model_id", "gpu_layers", "timeout_sec" }) |key| try std.testing.expect(containsKey(key));
    inline for (.{ "server_url", "runtime" }) |key| try std.testing.expect(!containsKey(key));
    try config.setValue(std.testing.allocator, &cfg, "gpu_layers", "0");
    const got = try config.getValue(std.testing.allocator, &cfg, "gpu_layers");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("0", got);
    try config.setValue(std.testing.allocator, &cfg, "gpu_layers", "-2");
    try std.testing.expectEqual(@as(i32, -2), cfg.gpu_layers);
    const path = "/tmp/kotoba-config-gpu-layers-test.toml";
    sys.deleteFile(path);
    defer sys.deleteFile(path);
    try config.save(path, cfg);
    const loaded = try config.load(std.heap.page_allocator, path);
    try std.testing.expectEqual(@as(i32, -2), loaded.gpu_layers);
    inline for (.{ "auto", "all", "1.5", "\"auto\"", "\"all\"" }) |value| {
        try std.testing.expectError(errors.Error.ConfigInvalid, config.parse(std.testing.allocator, "gpu_layers = " ++ value ++ "\n"));
    }
    for ([_][]const u8{ "auto", "all", "1.5" }) |value| {
        try std.testing.expectError(errors.Error.InvalidArguments, config.setValue(std.testing.allocator, &cfg, "gpu_layers", value));
    }
}

fn containsKey(key: []const u8) bool {
    for (config.settable_keys) |candidate| {
        if (std.mem.eql(u8, candidate, key)) return true;
    }
    return false;
}
