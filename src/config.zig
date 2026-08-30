const std = @import("std");
const errors = @import("errors.zig");
const lang = @import("lang.zig");
const sys = @import("sys.zig");
const strict = @import("strict_toml.zig");
const staged_output = @import("staged_output.zig");

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

/// Borrowed configuration. Default string literals require no deinit.
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

/// Owns all three strings; move-only by convention. Deinit invalidates its views.
pub const OwnedConfig = struct {
    allocator: std.mem.Allocator,
    value: Config,

    pub fn clone(allocator: std.mem.Allocator, cfg: Config) !OwnedConfig {
        const model_id = try allocator.dupe(u8, cfg.model_id);
        errdefer allocator.free(model_id);
        const model_path = try allocator.dupe(u8, cfg.model_path);
        errdefer allocator.free(model_path);
        const log_level = try allocator.dupe(u8, cfg.log_level);
        var value = cfg;
        value.model_id = model_id;
        value.model_path = model_path;
        value.log_level = log_level;
        return .{ .allocator = allocator, .value = value };
    }

    /// Borrowed until mutation or deinit; the caller must not free its fields.
    pub fn view(self: *const OwnedConfig) Config {
        return self.value;
    }

    pub fn deinit(self: *OwnedConfig) void {
        self.allocator.free(self.value.model_id);
        self.allocator.free(self.value.model_path);
        self.allocator.free(self.value.log_level);
        self.* = undefined;
    }

    /// Validation or allocation failure leaves every previous field valid.
    pub fn setValue(self: *OwnedConfig, key: []const u8, value: []const u8) !void {
        const allocator = self.allocator;
        const cfg = &self.value;
        inline for (settable_keys) |candidate| {
            if (std.mem.eql(u8, key, candidate)) {
                const T = @TypeOf(@field(cfg, candidate));
                if (T == []const u8) {
                    strict.validateString(value) catch return error.InvalidArguments;
                    const replacement = try allocator.dupe(u8, value);
                    allocator.free(@field(cfg, candidate));
                    @field(cfg, candidate) = replacement;
                } else switch (@typeInfo(T)) {
                    .optional => cfg.default_source_lang = if (value.len == 0) null else try lang.Language.parse(value),
                    .@"enum" => @field(cfg, candidate) = try T.parse(value),
                    .int => @field(cfg, candidate) = if (T == i32)
                        std.fmt.parseInt(i32, std.mem.trim(u8, value, " \t\r\n"), 10) catch return error.InvalidArguments
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

pub fn load(allocator: std.mem.Allocator, path: []const u8) !OwnedConfig {
    const data = sys.readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return errors.Error.NotInitialized,
        else => return err,
    };
    defer allocator.free(data);
    return parse(allocator, data);
}

test "strict config loader distinguishes missing files without creating paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const path = try std.fs.path.join(allocator, &.{ root, "missing", "config.toml" });
    try std.testing.expectError(error.NotInitialized, load(allocator, path));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "missing", .{}));
}

test "strict config loader preserves size failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const path = try std.fs.path.join(allocator, &.{ root, "config.toml" });
    const data = try allocator.alloc(u8, 1048577);
    @memset(data, ' ');
    try sys.writeFile(path, data);
    try std.testing.expectError(error.StreamTooLong, load(allocator, path));
    try std.testing.expectEqualStrings(data, try sys.readFileAlloc(allocator, path, data.len + 1));
}

test "strict config loader preserves directory failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try std.testing.expectError(error.IsDir, load(std.testing.allocator, root));
}

test "strict config loader preserves parse schema and allocation failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const path = try std.fs.path.join(allocator, &.{ root, "config.toml" });
    for ([_]struct { data: []const u8, expected: anyerror }{
        .{ .data = "gpu_layers = 'auto'\n", .expected = error.ConfigInvalid },
        .{ .data = "version = 2\n", .expected = error.ConfigSchemaUnsupported },
    }) |case| {
        try sys.writeFile(path, case.data);
        try std.testing.expectError(case.expected, load(allocator, path));
        try std.testing.expectEqualStrings(case.data, try sys.readFileAlloc(allocator, path, 1024));
    }
    const valid = "model_id = 'local'\n";
    try sys.writeFile(path, valid);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, load(failing.allocator(), path));
    var loaded = try load(allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("local", loaded.view().model_id);
    try std.testing.expectEqualStrings(valid, try sys.readFileAlloc(allocator, path, 1024));
}

test "strict config loader preserves native access denied" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    if (std.os.linux.getuid() == 0) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const path = try std.fs.path.join(allocator, &.{ root, "config.toml" });
    const data = "model_id = 'private'\n";
    try sys.writeFile(path, data);
    const file = try tmp.dir.openFile(std.testing.io, "config.toml", .{});
    defer file.close(std.testing.io);
    try file.setPermissions(std.testing.io, .fromMode(0));
    defer file.setPermissions(std.testing.io, .fromMode(0o600)) catch unreachable;
    try std.testing.expectError(error.AccessDenied, load(allocator, path));
    try file.setPermissions(std.testing.io, .fromMode(0o600));
    try std.testing.expectEqualStrings(data, try sys.readFileAlloc(allocator, path, 1024));
}

/// Returns independent owned strings, including omitted defaults; caller deinits.
pub fn parse(allocator: std.mem.Allocator, data: []const u8) !OwnedConfig {
    return parseStrict(allocator, data) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ConfigSchemaUnsupported => error.ConfigSchemaUnsupported,
        else => error.ConfigInvalid,
    };
}

fn parseStrict(allocator: std.mem.Allocator, data: []const u8) !OwnedConfig {
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
    inline for (settable_keys, 0..) |key, index| {
        if (@TypeOf(@field(cfg, key)) == []const u8 and !owned[index]) {
            @field(cfg, key) = try allocator.dupe(u8, @field(cfg, key));
            owned[index] = true;
        }
    }
    return .{ .allocator = allocator, .value = cfg };
}

pub fn save(path: []const u8, cfg: Config) !void {
    return saveWithOptions(path, cfg, .{});
}

fn saveWithOptions(path: []const u8, cfg: Config, options: sys.StagedFileOptions) !void {
    var out = strict.Buffer.init(std.heap.page_allocator);
    defer out.deinit();
    appendConfig(&out, cfg) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ConfigInvalid,
    };
    try sys.atomicWriteFile(std.heap.page_allocator, path, out.items, options);
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

/// Returns caller-owned bytes allocated with allocator.
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

fn testExpectOnlyConfigEntries(dir: std.Io.Dir, existing: bool) !void {
    var iterator_dir = try dir.openDir(std.testing.io, ".", .{ .iterate = true });
    defer iterator_dir.close(std.testing.io);
    var iterator = iterator_dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        count += 1;
        if (std.mem.eql(u8, entry.name, "sibling") or std.mem.eql(u8, entry.name, "config.toml")) continue;
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, if (existing) 2 else 1), count);
}

test "atomic config save preserves destination through every publication boundary" {
    const operations = [_]staged_output.Faults.Operation{ .candidate, .create, .write, .flush, .sync, .close, .rename };
    for (operations) |operation| for ([_]bool{ false, true }) |existing| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        const path = try std.fs.path.join(std.testing.allocator, &.{ root, "config.toml" });
        defer std.testing.allocator.free(path);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sibling", .data = "unrelated" });
        if (existing) {
            try sys.writeFile(path, "old config bytes\n");
            try tmp.dir.setFilePermissions(std.testing.io, "config.toml", .fromMode(0o600), .{});
        }
        var faults: staged_output.Faults = .{};
        try faults.arm(operation, 1, error.InputOutput);
        var report: staged_output.CleanupReport = .{};
        try std.testing.expectError(error.InputOutput, saveWithOptions(path, .{ .model_id = "new-config" }, .{ .faults = &faults, .cleanup_report = &report }));
        if (existing) {
            const bytes = try tmp.dir.readFileAlloc(std.testing.io, "config.toml", std.testing.allocator, .limited(128));
            defer std.testing.allocator.free(bytes);
            try std.testing.expectEqualStrings("old config bytes\n", bytes);
            try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), (try tmp.dir.statFile(std.testing.io, "config.toml", .{})).permissions.toMode() & 0o7777);
        } else try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "config.toml", .{}));
        try std.testing.expectEqual(null, report.secondary);
        try testExpectOnlyConfigEntries(tmp.dir, existing);
    };
}

test {
    _ = @import("config_tests.zig");
}
