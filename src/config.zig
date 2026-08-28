const std = @import("std");
const errors = @import("errors.zig");
const lang = @import("lang.zig");
const sys = @import("sys.zig");
const toml = @import("toml.zig");
const strict = @import("strict_toml.zig");

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
    gpu_layers: i32 = -1,
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
    "gpu_layers",
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

/// String fields present in the input are caller-owned; omitted fields borrow defaults.
pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Config {
    return parseStrict(allocator, data) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ConfigSchemaUnsupported => error.ConfigSchemaUnsupported,
        else => error.ConfigInvalid,
    };
}

fn parseStrict(allocator: std.mem.Allocator, data: []const u8) !Config {
    var cfg = default();
    var seen = [_]bool{false} ** settable_keys.len;
    var owned = [_]bool{false} ** settable_keys.len;
    errdefer inline for (settable_keys, 0..) |key, index| {
        if (@TypeOf(@field(cfg, key)) == []const u8 and owned[index]) allocator.free(@field(cfg, key));
    };
    var reader: strict.Reader = .{ .data = data };
    while (try reader.next()) |line| {
        const pair = switch (line) {
            .header => |header| {
                if (strict.isSchemaMarker(header.name)) return error.ConfigSchemaUnsupported;
                return error.Invalid;
            },
            .pair => |pair| pair,
        };
        if (strict.isSchemaMarker(pair.key)) return error.ConfigSchemaUnsupported;
        var matched = false;
        inline for (settable_keys, 0..) |key, index| {
            if (std.mem.eql(u8, key, pair.key)) {
                if (seen[index]) return error.Invalid;
                seen[index] = true;
                matched = true;
                const T = @TypeOf(@field(cfg, key));
                if (T == []const u8) {
                    @field(cfg, key) = try strict.parseString(allocator, pair.value);
                    owned[index] = true;
                } else switch (@typeInfo(T)) {
                    .optional, .@"enum" => {
                        const value = try strict.parseString(allocator, pair.value);
                        defer allocator.free(value);
                        @field(cfg, key) = if (T == ?lang.Language)
                            (if (value.len == 0) null else try lang.Language.parse(value))
                        else
                            try T.parse(value);
                    },
                    .int => @field(cfg, key) = try strict.parseInt(T, pair.value),
                    .float => @field(cfg, key) = try strict.parseFloat(pair.value),
                    .bool => @field(cfg, key) = try strict.parseBool(pair.value),
                    else => unreachable,
                }
            }
        }
        if (!matched) return error.Invalid;
    }
    return cfg;
}

pub fn save(path: []const u8, cfg: Config) !void {
    var out = strict.Buffer.init(std.heap.page_allocator);
    defer out.deinit();
    appendConfig(&out, cfg) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ConfigInvalid,
    };
    try sys.writeFile(path, out.items);
}

fn appendConfig(out: *strict.Buffer, cfg: Config) !void {
    inline for (settable_keys) |key| {
        try out.appendSlice(key ++ " = ");
        const value = @field(cfg, key);
        const T = @TypeOf(value);
        if (T == []const u8) {
            try strict.appendString(out, value);
        } else switch (@typeInfo(T)) {
            .optional => try strict.appendString(out, if (value) |language| language.asText() else ""),
            .@"enum" => try strict.appendString(out, value.asText()),
            .int => try out.print("{d}", .{value}),
            .float => try strict.appendFloat(out, value),
            .bool => try out.print("{}", .{value}),
            else => unreachable,
        }
        try out.append('\n');
    }
}

pub fn setValue(allocator: std.mem.Allocator, cfg: *Config, key: []const u8, value: []const u8) !void {
    inline for (settable_keys) |candidate| {
        if (std.mem.eql(u8, key, candidate)) {
            const T = @TypeOf(@field(cfg, candidate));
            if (T == []const u8) {
                strict.validateString(value) catch return error.InvalidArguments;
                @field(cfg, candidate) = try allocator.dupe(u8, value);
            } else switch (@typeInfo(T)) {
                .optional => cfg.default_source_lang = if (value.len == 0) null else try lang.Language.parse(value),
                .@"enum" => @field(cfg, candidate) = try T.parse(value),
                .int => @field(cfg, candidate) = if (T == i32)
                    toml.signedIntValue(value) orelse return error.InvalidArguments
                else
                    std.fmt.parseInt(T, value, 10) catch return error.InvalidArguments,
                .float => {
                    const parsed = std.fmt.parseFloat(f32, value) catch return error.InvalidArguments;
                    if (!std.math.isFinite(parsed)) return error.InvalidArguments;
                    @field(cfg, candidate) = parsed;
                },
                .bool => @field(cfg, candidate) = try parseBool(value),
                else => unreachable,
            }
            return;
        }
    }
    return error.InvalidArguments;
}

pub fn getValue(allocator: std.mem.Allocator, cfg: *const Config, key: []const u8) ![]const u8 {
    if (std.mem.eql(u8, key, "model_id")) return allocator.dupe(u8, cfg.model_id);
    if (std.mem.eql(u8, key, "model_path")) return allocator.dupe(u8, cfg.model_path);
    if (std.mem.eql(u8, key, "gpu_layers")) return try std.fmt.allocPrint(allocator, "{d}", .{cfg.gpu_layers});
    if (std.mem.eql(u8, key, "context_length")) return try std.fmt.allocPrint(allocator, "{d}", .{cfg.context_length});
    if (std.mem.eql(u8, key, "threads")) return try std.fmt.allocPrint(allocator, "{d}", .{cfg.threads});
    if (std.mem.eql(u8, key, "max_tokens")) return try std.fmt.allocPrint(allocator, "{d}", .{cfg.max_tokens});
    if (std.mem.eql(u8, key, "temperature")) return try std.fmt.allocPrint(allocator, "{d}", .{cfg.temperature});
    if (std.mem.eql(u8, key, "timeout_sec")) return try std.fmt.allocPrint(allocator, "{d}", .{cfg.timeout_sec});
    if (std.mem.eql(u8, key, "default_target_lang")) return allocator.dupe(u8, cfg.default_target_lang.asText());
    if (std.mem.eql(u8, key, "default_source_lang")) return allocator.dupe(u8, if (cfg.default_source_lang) |l| l.asText() else "");
    if (std.mem.eql(u8, key, "default_mode")) return allocator.dupe(u8, cfg.default_mode.asText());
    if (std.mem.eql(u8, key, "default_output")) return allocator.dupe(u8, cfg.default_output.asText());
    if (std.mem.eql(u8, key, "memory_enabled")) return allocator.dupe(u8, if (cfg.memory_enabled) "true" else "false");
    if (std.mem.eql(u8, key, "glossary_enabled")) return allocator.dupe(u8, if (cfg.glossary_enabled) "true" else "false");
    if (std.mem.eql(u8, key, "privacy_mode")) return allocator.dupe(u8, if (cfg.privacy_mode) "true" else "false");
    if (std.mem.eql(u8, key, "log_level")) return allocator.dupe(u8, cfg.log_level);
    return errors.Error.InvalidArguments;
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return errors.Error.InvalidArguments;
}

test {
    _ = @import("config_tests.zig");
}
