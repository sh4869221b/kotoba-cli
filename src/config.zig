const std = @import("std");
const errors = @import("errors.zig");
const lang = @import("lang.zig");
const sys = @import("sys.zig");
const toml = @import("toml.zig");

pub const Mode = enum {
    default,
    technical,

    pub fn parse(text: []const u8) !Mode {
        if (std.mem.eql(u8, text, "default")) return .default;
        if (std.mem.eql(u8, text, "technical")) return .technical;
        return errors.Error.InvalidArguments;
    }

    pub fn asText(self: Mode) []const u8 {
        return switch (self) {
            .default => "default",
            .technical => "technical",
        };
    }
};

pub const OutputFormat = enum {
    plain,
    json,
    markdown,

    pub fn parse(text: []const u8) !OutputFormat {
        if (std.mem.eql(u8, text, "plain")) return .plain;
        if (std.mem.eql(u8, text, "json")) return .json;
        if (std.mem.eql(u8, text, "markdown")) return .markdown;
        return errors.Error.InvalidArguments;
    }

    pub fn asText(self: OutputFormat) []const u8 {
        return switch (self) {
            .plain => "plain",
            .json => "json",
            .markdown => "markdown",
        };
    }
};

pub const Config = struct {
    default_source_lang: ?lang.Language = null,
    default_target_lang: lang.Language = .ja,
    default_mode: Mode = .default,
    default_output: OutputFormat = .plain,
    model_id: []const u8 = "",
    model_path: []const u8 = "",
    context_length: u32 = 4096,
    threads: u32 = 0,
    max_tokens: u32 = 1024,
    temperature: f32 = 0.2,
    timeout_sec: u32 = 120,
    memory_enabled: bool = true,
    glossary_enabled: bool = true,
    privacy_mode: bool = true,
    log_level: []const u8 = "warn",
};

pub const settable_keys = [_][]const u8{
    "default_source_lang",
    "default_target_lang",
    "default_mode",
    "default_output",
    "model_id",
    "model_path",
    "context_length",
    "threads",
    "max_tokens",
    "temperature",
    "timeout_sec",
    "memory_enabled",
    "glossary_enabled",
    "privacy_mode",
    "log_level",
};

pub fn default() Config {
    return .{};
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
    const data = sys.readFileAlloc(allocator, path, 1024 * 1024) catch return errors.Error.NotInitialized;
    defer allocator.free(data);
    return parse(allocator, data);
}

pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Config {
    var cfg = default();
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const p = toml.pair(line) orelse continue;
        const val = toml.unquote(p.value);
        if (std.mem.eql(u8, p.key, "default_source_lang")) {
            cfg.default_source_lang = if (val.len == 0) null else try lang.Language.parse(val);
        } else if (std.mem.eql(u8, p.key, "default_target_lang")) {
            cfg.default_target_lang = try lang.Language.parse(val);
        } else if (std.mem.eql(u8, p.key, "default_mode")) {
            cfg.default_mode = try Mode.parse(val);
        } else if (std.mem.eql(u8, p.key, "default_output")) {
            cfg.default_output = try OutputFormat.parse(val);
        } else if (std.mem.eql(u8, p.key, "model_id")) {
            cfg.model_id = try allocator.dupe(u8, val);
        } else if (std.mem.eql(u8, p.key, "model_path")) {
            cfg.model_path = try allocator.dupe(u8, val);
        } else if (std.mem.eql(u8, p.key, "context_length")) {
            cfg.context_length = toml.intValue(p.value) orelse return errors.Error.ConfigInvalid;
        } else if (std.mem.eql(u8, p.key, "threads")) {
            cfg.threads = toml.intValue(p.value) orelse return errors.Error.ConfigInvalid;
        } else if (std.mem.eql(u8, p.key, "max_tokens")) {
            cfg.max_tokens = toml.intValue(p.value) orelse return errors.Error.ConfigInvalid;
        } else if (std.mem.eql(u8, p.key, "temperature")) {
            cfg.temperature = std.fmt.parseFloat(f32, val) catch return errors.Error.ConfigInvalid;
        } else if (std.mem.eql(u8, p.key, "timeout_sec")) {
            cfg.timeout_sec = toml.intValue(p.value) orelse return errors.Error.ConfigInvalid;
        } else if (std.mem.eql(u8, p.key, "memory_enabled")) {
            cfg.memory_enabled = toml.boolValue(p.value) orelse return errors.Error.ConfigInvalid;
        } else if (std.mem.eql(u8, p.key, "glossary_enabled")) {
            cfg.glossary_enabled = toml.boolValue(p.value) orelse return errors.Error.ConfigInvalid;
        } else if (std.mem.eql(u8, p.key, "privacy_mode")) {
            cfg.privacy_mode = toml.boolValue(p.value) orelse return errors.Error.ConfigInvalid;
        } else if (std.mem.eql(u8, p.key, "log_level")) {
            cfg.log_level = try allocator.dupe(u8, val);
        }
    }
    return cfg;
}

pub fn save(path: []const u8, cfg: Config) !void {
    const data = try std.fmt.allocPrint(std.heap.page_allocator,
        \\default_source_lang = "{s}"
        \\default_target_lang = "{s}"
        \\default_mode = "{s}"
        \\default_output = "{s}"
        \\model_id = "{s}"
        \\model_path = "{s}"
        \\context_length = {d}
        \\threads = {d}
        \\max_tokens = {d}
        \\temperature = {d}
        \\timeout_sec = {d}
        \\memory_enabled = {}
        \\glossary_enabled = {}
        \\privacy_mode = {}
        \\log_level = "{s}"
        \\
    , .{
        if (cfg.default_source_lang) |l| l.asText() else "",
        cfg.default_target_lang.asText(),
        cfg.default_mode.asText(),
        cfg.default_output.asText(),
        cfg.model_id,
        cfg.model_path,
        cfg.context_length,
        cfg.threads,
        cfg.max_tokens,
        cfg.temperature,
        cfg.timeout_sec,
        cfg.memory_enabled,
        cfg.glossary_enabled,
        cfg.privacy_mode,
        cfg.log_level,
    });
    defer std.heap.page_allocator.free(data);
    try sys.writeFile(path, data);
}

pub fn setValue(allocator: std.mem.Allocator, cfg: *Config, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "model_id")) cfg.model_id = try allocator.dupe(u8, value) else if (std.mem.eql(u8, key, "model_path")) cfg.model_path = try allocator.dupe(u8, value) else if (std.mem.eql(u8, key, "context_length")) cfg.context_length = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, key, "threads")) cfg.threads = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, key, "max_tokens")) cfg.max_tokens = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, key, "temperature")) cfg.temperature = try std.fmt.parseFloat(f32, value) else if (std.mem.eql(u8, key, "memory_enabled")) cfg.memory_enabled = try parseBool(value) else if (std.mem.eql(u8, key, "glossary_enabled")) cfg.glossary_enabled = try parseBool(value) else if (std.mem.eql(u8, key, "default_source_lang")) cfg.default_source_lang = if (value.len == 0) null else try lang.Language.parse(value) else if (std.mem.eql(u8, key, "default_target_lang")) cfg.default_target_lang = try lang.Language.parse(value) else if (std.mem.eql(u8, key, "default_mode")) cfg.default_mode = try Mode.parse(value) else if (std.mem.eql(u8, key, "default_output")) cfg.default_output = try OutputFormat.parse(value) else if (std.mem.eql(u8, key, "timeout_sec")) cfg.timeout_sec = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, key, "privacy_mode")) cfg.privacy_mode = try parseBool(value) else if (std.mem.eql(u8, key, "log_level")) cfg.log_level = try allocator.dupe(u8, value) else return errors.Error.InvalidArguments;
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return errors.Error.InvalidArguments;
}

test "config round trip parse" {
    const cfg = try parse(std.heap.page_allocator,
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

test "embedded config rejects removed server keys" {
    var cfg = default();
    try std.testing.expectError(errors.Error.InvalidArguments, setValue(std.testing.allocator, &cfg, "runtime", "llama_server"));
    try std.testing.expectError(errors.Error.InvalidArguments, setValue(std.testing.allocator, &cfg, "server_url", "http://127.0.0.1:8080"));
    try std.testing.expectError(errors.Error.InvalidArguments, setValue(std.testing.allocator, &cfg, "server_autostart", "true"));
    try std.testing.expectError(errors.Error.InvalidArguments, setValue(std.testing.allocator, &cfg, "llama_server_path", "llama-server"));
    try std.testing.expectError(errors.Error.InvalidArguments, setValue(std.testing.allocator, &cfg, "server_startup_timeout_sec", "60"));
}

test "config key list contains only supported set keys" {
    try std.testing.expect(containsKey("model_id"));
    try std.testing.expect(containsKey("timeout_sec"));
    try std.testing.expect(!containsKey("server_url"));
    try std.testing.expect(!containsKey("runtime"));
}

fn containsKey(key: []const u8) bool {
    for (settable_keys) |candidate| {
        if (std.mem.eql(u8, candidate, key)) return true;
    }
    return false;
}
