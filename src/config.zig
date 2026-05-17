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
    model_id: []const u8 = "custom",
    model_path: []const u8 = "",
    runtime: []const u8 = "llama_server",
    server_url: []const u8 = "http://127.0.0.1:8080",
    server_autostart: bool = true,
    llama_server_path: []const u8 = "llama-server",
    server_startup_timeout_sec: u32 = 60,
    timeout_sec: u32 = 120,
    memory_enabled: bool = true,
    glossary_enabled: bool = true,
    privacy_mode: bool = true,
    log_level: []const u8 = "warn",
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
        } else if (std.mem.eql(u8, p.key, "runtime")) {
            cfg.runtime = try allocator.dupe(u8, val);
        } else if (std.mem.eql(u8, p.key, "server_url")) {
            cfg.server_url = try allocator.dupe(u8, val);
        } else if (std.mem.eql(u8, p.key, "server_autostart")) {
            cfg.server_autostart = toml.boolValue(p.value) orelse return errors.Error.ConfigInvalid;
        } else if (std.mem.eql(u8, p.key, "llama_server_path")) {
            cfg.llama_server_path = try allocator.dupe(u8, val);
        } else if (std.mem.eql(u8, p.key, "server_startup_timeout_sec")) {
            cfg.server_startup_timeout_sec = toml.intValue(p.value) orelse return errors.Error.ConfigInvalid;
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
        \\runtime = "{s}"
        \\server_url = "{s}"
        \\server_autostart = {}
        \\llama_server_path = "{s}"
        \\server_startup_timeout_sec = {d}
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
        cfg.runtime,
        cfg.server_url,
        cfg.server_autostart,
        cfg.llama_server_path,
        cfg.server_startup_timeout_sec,
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
    if (std.mem.eql(u8, key, "server_url")) cfg.server_url = try allocator.dupe(u8, value) else if (std.mem.eql(u8, key, "model_id")) cfg.model_id = try allocator.dupe(u8, value) else if (std.mem.eql(u8, key, "model_path")) cfg.model_path = try allocator.dupe(u8, value) else if (std.mem.eql(u8, key, "runtime")) cfg.runtime = try allocator.dupe(u8, value) else if (std.mem.eql(u8, key, "server_autostart")) cfg.server_autostart = try parseBool(value) else if (std.mem.eql(u8, key, "llama_server_path")) cfg.llama_server_path = try allocator.dupe(u8, value) else if (std.mem.eql(u8, key, "server_startup_timeout_sec")) cfg.server_startup_timeout_sec = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, key, "memory_enabled")) cfg.memory_enabled = try parseBool(value) else if (std.mem.eql(u8, key, "glossary_enabled")) cfg.glossary_enabled = try parseBool(value) else if (std.mem.eql(u8, key, "default_source_lang")) cfg.default_source_lang = if (value.len == 0) null else try lang.Language.parse(value) else if (std.mem.eql(u8, key, "default_target_lang")) cfg.default_target_lang = try lang.Language.parse(value) else if (std.mem.eql(u8, key, "default_mode")) cfg.default_mode = try Mode.parse(value) else if (std.mem.eql(u8, key, "default_output")) cfg.default_output = try OutputFormat.parse(value) else if (std.mem.eql(u8, key, "timeout_sec")) cfg.timeout_sec = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, key, "privacy_mode")) cfg.privacy_mode = try parseBool(value) else if (std.mem.eql(u8, key, "log_level")) cfg.log_level = try allocator.dupe(u8, value) else return errors.Error.InvalidArguments;
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return errors.Error.InvalidArguments;
}

test "config round trip parse" {
    const cfg = try parse(std.testing.allocator,
        \\default_source_lang = ""
        \\default_target_lang = "ja"
        \\memory_enabled = true
        \\server_autostart = false
        \\llama_server_path = "/tmp/fake-llama-server"
        \\server_startup_timeout_sec = 3
    );
    defer std.testing.allocator.free(cfg.llama_server_path);
    try std.testing.expectEqual(lang.Language.ja, cfg.default_target_lang);
    try std.testing.expect(cfg.memory_enabled);
    try std.testing.expect(!cfg.server_autostart);
    try std.testing.expectEqualStrings("/tmp/fake-llama-server", cfg.llama_server_path);
    try std.testing.expectEqual(@as(u32, 3), cfg.server_startup_timeout_sec);
}
