const std = @import("std");
const errors = @import("errors.zig");
const lang = @import("lang.zig");
const sys = @import("sys.zig");
const fs = @import("fs.zig");
const staged_output = @import("staged_output.zig");
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

pub const OutputRenderer = enum {
    plain,
    json,
    markdown,

    pub fn parse(text: []const u8) !OutputRenderer {
        if (std.mem.eql(u8, text, "plain")) return .plain;
        if (std.mem.eql(u8, text, "json")) return .json;
        if (std.mem.eql(u8, text, "markdown")) return .markdown;
        return errors.Error.InvalidArguments;
    }

    pub fn asText(self: OutputRenderer) []const u8 {
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
    default_output: OutputRenderer = .plain,
    model_id: []const u8 = "",
    model_path: []const u8 = "",
    /// Persisted for paths chosen independently of the registry.
    model_path_explicit: bool = false,
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

    pub fn selectRegisteredModel(self: *OwnedConfig, id: []const u8, path: []const u8) !void {
        strict.validateString(id) catch return error.InvalidArguments;
        strict.validateString(path) catch return error.InvalidArguments;
        const model_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(model_id);
        const model_path = try self.allocator.dupe(u8, path);
        self.allocator.free(self.value.model_id);
        self.allocator.free(self.value.model_path);
        self.value.model_id = model_id;
        self.value.model_path = model_path;
        self.value.model_path_explicit = false;
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
        error.FileNotFound => switch (try sys.pathState(path)) {
            .not_found => return errors.Error.NotInitialized,
            .present => return err,
        },
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

test "config loader reports a dangling symlink without treating it as absent" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "config.toml" });
    defer allocator.free(path);
    try tmp.dir.symLink(io, "settings.toml", "config.toml", .{});
    try std.testing.expectError(error.FileNotFound, load(allocator, path));
    try tmp.dir.writeFile(io, .{ .sub_path = "settings.toml", .data = "model_id = 'restored'\n" });
    var loaded = try load(allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("restored", loaded.view().model_id);
}

test "explicit model paths round trip and registry selection clears the marker" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "config.toml" });
    defer allocator.free(path);
    try save(path, .{ .model_id = "old", .model_path = "/alias.gguf", .model_path_explicit = true });
    var cfg = try load(allocator, path);
    defer cfg.deinit();
    try std.testing.expect(cfg.view().model_path_explicit);
    try cfg.selectRegisteredModel("new", "/registered.gguf");
    try save(path, cfg.view());
    var loaded = try load(allocator, path);
    defer loaded.deinit();
    try std.testing.expect(!loaded.view().model_path_explicit);
    try std.testing.expectEqualStrings("/registered.gguf", loaded.view().model_path);
    try std.testing.expectError(error.ConfigInvalid, parse(allocator, "model_path_explicit=true\nmodel_path_explicit=false"));
    try std.testing.expectError(error.ConfigInvalid, parse(allocator, "model_path_explicit='true'"));
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
    var seen_explicit = false;
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
        if (std.mem.eql(u8, pair.key, "model_path_explicit")) {
            if (seen_explicit) return error.Invalid;
            seen_explicit = true;
            cfg.model_path_explicit = try strict.parseBool(pair.value);
            continue;
        }
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

/// Resolve before slow work begins. Writers subsequently read and stage
/// through the locked target directory, never through the original link.
pub const WriteTarget = struct {
    allocator: std.mem.Allocator,
    entry: []const u8,
    path: []u8,

    pub fn capture(allocator: std.mem.Allocator, entry: []const u8) !WriteTarget {
        return .{ .allocator = allocator, .entry = entry, .path = try resolveWritePath(allocator, entry) };
    }

    pub fn deinit(self: WriteTarget) void {
        self.allocator.free(self.path);
    }

    pub fn begin(self: WriteTarget) !Writer {
        return self.beginForInstall(false);
    }

    pub fn beginForInstall(self: WriteTarget, allow_read_only: bool) !Writer {
        const basename = std.fs.path.basename(self.path);
        if (std.mem.eql(u8, basename, sys.StateLock.config_name) or std.mem.eql(u8, basename, sys.StateLock.registry_name))
            return errors.Error.InvalidArguments;
        const parent = std.fs.path.dirname(self.path) orelse ".";
        const access: Writer.Access = if (sys.StateLock.acquire(parent, sys.StateLock.config_name)) |lock|
            .{ .locked = lock }
        else |err| fallback: {
            if (!allow_read_only) return err;
            switch (err) {
                error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => {},
                else => return err,
            }
            break :fallback .{ .read_only = .{ .dir = try sys.cwd().openDir(sys.io(), parent, .{}), .cause = err } };
        };
        const writer: Writer = .{ .target = self, .access = access, .basename = basename };
        errdefer writer.close();
        try writer.requireTarget();
        return writer;
    }
};

fn resolveWritePath(allocator: std.mem.Allocator, entry: []const u8) ![]u8 {
    if ((try sys.pathState(entry)) == .present) {
        const canonical = try sys.realPathAlloc(allocator, entry);
        defer allocator.free(canonical);
        return allocator.dupe(u8, canonical);
    }
    // The XDG application directory may not exist yet. Anchor its missing
    // suffix to the nearest existing directory, including any symlink prefix.
    const absolute = try sys.absolutePathAlloc(allocator, entry);
    defer allocator.free(absolute);
    var prefix = std.fs.path.dirname(absolute) orelse return error.BadPathName;
    while (true) {
        if (try sys.realPathIfExistsAlloc(allocator, prefix)) |parent| {
            defer allocator.free(parent);
            return std.fs.path.join(allocator, &.{ parent, std.mem.trimStart(u8, absolute[prefix.len..], "/") });
        }
        prefix = std.fs.path.dirname(prefix) orelse return error.FileNotFound;
    }
}

test "a future config is anchored through a linked XDG parent" {
    const allocator = std.testing.allocator;
    const io = sys.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    try tmp.dir.createDir(io, "actual", .default_dir);
    try tmp.dir.symLink(io, "actual", "alias", .{ .is_directory = true });
    const link_path = try std.fs.path.join(allocator, &.{ root, "alias/kotoba/config.toml" });
    defer allocator.free(link_path);
    const target = try WriteTarget.capture(allocator, link_path);
    defer target.deinit();
    try tmp.dir.createDirPath(io, "alias/kotoba");
    var writer = try target.begin();
    defer writer.close();
    var cfg = try writer.loadOrDefault(allocator);
    defer cfg.deinit();
    try std.testing.expectEqual(default().threads, cfg.view().threads);
}

pub const Writer = struct {
    target: WriteTarget,
    access: Access,
    basename: []const u8,
    snapshot: fs.PathState = .not_found,

    const Access = union(enum) {
        locked: sys.StateLock,
        read_only: struct { dir: std.Io.Dir, cause: anyerror },
    };

    pub fn close(self: Writer) void {
        switch (self.access) {
            .locked => |lock| lock.close(),
            .read_only => |access| access.dir.close(sys.io()),
        }
    }

    fn directory(self: Writer) std.Io.Dir {
        return switch (self.access) {
            .locked => |lock| lock.directory,
            .read_only => |access| access.dir,
        };
    }

    pub fn lockError(self: Writer) ?anyerror {
        return switch (self.access) {
            .locked => null,
            .read_only => |access| access.cause,
        };
    }

    pub fn load(self: *Writer, allocator: std.mem.Allocator) !OwnedConfig {
        const io = sys.io();
        const file = self.directory().openFile(io, self.basename, .{
            .allow_directory = false,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                self.snapshot = .not_found;
                try self.requireUnchanged();
                return errors.Error.NotInitialized;
            },
            else => return err,
        };
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file) return error.AccessDenied;
        self.snapshot = .{ .present = stat };
        var reader = file.reader(io, &.{});
        const data = reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            else => return err,
        };
        defer allocator.free(data);
        try self.requireUnchanged();
        return parse(allocator, data);
    }

    pub fn loadOrDefault(self: *Writer, allocator: std.mem.Allocator) !OwnedConfig {
        return self.load(allocator) catch |err| switch (err) {
            error.NotInitialized => OwnedConfig.clone(allocator, default()),
            else => return err,
        };
    }

    pub fn requireTarget(self: Writer) !void {
        const allocator = self.target.allocator;
        const actual = resolveWritePath(allocator, self.target.entry) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.SymLinkLoop => return errors.Error.ConfigTargetChanged,
            else => return err,
        };
        defer allocator.free(actual);
        if (!std.mem.eql(u8, self.target.path, actual)) return errors.Error.ConfigTargetChanged;
        const parent = try self.directory().realPathFileAlloc(sys.io(), ".", allocator);
        defer allocator.free(parent);
        if (!std.mem.eql(u8, std.fs.path.dirname(actual) orelse ".", parent)) return errors.Error.ConfigTargetChanged;
    }

    pub fn requireUnchanged(self: Writer) !void {
        try self.requireTarget();
        var filesystem = fs.FileSystem.init(sys.io(), self.directory(), null);
        const current = try filesystem.pathState(self.basename);
        switch (self.snapshot) {
            .not_found => if (current != .not_found) return errors.Error.ConfigTargetChanged,
            .present => |old| {
                if (current != .present) return errors.Error.ConfigTargetChanged;
                const now = current.present;
                if (now.kind != .file or old.inode != now.inode or old.size != now.size or
                    old.mtime.nanoseconds != now.mtime.nanoseconds or old.ctime.nanoseconds != now.ctime.nanoseconds)
                    return errors.Error.ConfigTargetChanged;
            },
        }
    }

    pub fn stage(self: Writer, cfg: Config, options: sys.StagedFileOptions) !staged_output.Finished {
        if (self.lockError()) |err| return err;
        try self.requireUnchanged();
        return stageConfig(self.target.allocator, self.directory(), self.basename, cfg, options);
    }
};

pub fn save(path: []const u8, cfg: Config) !void {
    return saveWithOptions(path, cfg, .{});
}

fn saveWithOptions(path: []const u8, cfg: Config, options: sys.StagedFileOptions) !void {
    const allocator = std.heap.page_allocator;
    const destination = try resolveWritePath(allocator, path);
    defer allocator.free(destination);
    var finished = try stageConfig(allocator, sys.cwd(), destination, cfg, options);
    defer finished.deinit();
    try finished.publish(options.mode);
}

fn stageConfig(allocator: std.mem.Allocator, dir: std.Io.Dir, path: []const u8, cfg: Config, options: sys.StagedFileOptions) !staged_output.Finished {
    var out = strict.Buffer.init(allocator);
    defer out.deinit();
    appendConfig(&out, cfg) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ConfigInvalid,
    };
    var pending = try staged_output.begin(allocator, sys.io(), dir, path, options);
    defer pending.deinit();
    try pending.writeAll(out.items);
    return pending.finish();
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
    if (cfg.model_path_explicit) try out.appendSlice("model_path_explicit = true\n");
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

test "atomic config save follows an existing link and preserves its entries" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "config.toml" });
    defer allocator.free(path);
    try tmp.dir.createDir(io, "shared", .default_dir);
    const original = "threads = 3\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "shared/settings.toml", .data = original });
    try tmp.dir.setFilePermissions(io, "shared/settings.toml", .fromMode(0o640), .{});
    try tmp.dir.symLink(io, "shared/settings.toml", "target.toml", .{});
    try tmp.dir.symLink(io, "target.toml", "config.toml", .{});

    var faults: staged_output.Faults = .{};
    try faults.arm(.rename, 1, error.InputOutput);
    try std.testing.expectError(error.InputOutput, saveWithOptions(path, .{ .threads = 7 }, .{ .faults = &faults }));
    const unchanged = try tmp.dir.readFileAlloc(io, "shared/settings.toml", allocator, .limited(128));
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings(original, unchanged);

    try save(path, .{ .threads = 7 });
    var loaded = try load(allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u32, 7), loaded.view().threads);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o640), (try tmp.dir.statFile(io, "shared/settings.toml", .{})).permissions.toMode() & 0o777);
    try tmp.dir.deleteFile(io, "shared/settings.toml");
    try std.testing.expectError(error.FileNotFound, save(path, .{ .threads = 9 }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "shared/settings.toml", .{}));

    var link: [64]u8 = undefined;
    try std.testing.expectEqualStrings("target.toml", link[0..try tmp.dir.readLink(io, "config.toml", &link)]);
    try std.testing.expectEqualStrings("shared/settings.toml", link[0..try tmp.dir.readLink(io, "target.toml", &link)]);
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
