const std = @import("std");
const sys = @import("sys.zig");

/// Every field borrows from the allocator passed to `paths`; cli.run keeps it alive for dispatch.
pub const Paths = struct {
    config_dir: []const u8,
    data_dir: []const u8,
    cache_dir: []const u8,
    state_dir: []const u8,
    config_file: []const u8,
    models_file: []const u8,
    models_dir: []const u8,
    glossary_file: []const u8,
    memory_file: []const u8,
};

pub const Domain = enum { config, data, cache, state };

pub const Inputs = struct {
    home: ?[]const u8 = null,
    config: ?[]const u8 = null,
    data: ?[]const u8 = null,
    cache: ?[]const u8 = null,
    state: ?[]const u8 = null,
};

pub const Reason = enum {
    direct,
    fallback_unset,
    fallback_empty,
    fallback_relative,
    unresolved_home_unset,
    unresolved_home_empty,
    unresolved_home_relative,
};

pub const DomainResolution = struct {
    path: ?[]const u8,
    reason: Reason,
};

pub const Resolution = struct {
    config: DomainResolution,
    data: DomainResolution,
    cache: DomainResolution,
    state: DomainResolution,

    pub fn get(self: Resolution, domain: Domain) DomainResolution {
        return switch (domain) {
            .config => self.config,
            .data => self.data,
            .cache => self.cache,
            .state => self.state,
        };
    }

    pub fn deinit(self: Resolution, allocator: std.mem.Allocator) void {
        inline for ([_]Domain{ .config, .data, .cache, .state }) |domain| {
            if (self.get(domain).path) |path| allocator.free(path);
        }
    }

    pub fn requirePaths(self: Resolution, allocator: std.mem.Allocator) !Paths {
        const config_dir = self.config.path orelse return error.PathResolutionFailed;
        const data_dir = self.data.path orelse return error.PathResolutionFailed;
        const cache_dir = self.cache.path orelse return error.PathResolutionFailed;
        const state_dir = self.state.path orelse return error.PathResolutionFailed;

        const config_file = try std.fs.path.join(allocator, &.{ config_dir, "config.toml" });
        errdefer allocator.free(config_file);
        const models_file = try std.fs.path.join(allocator, &.{ config_dir, "models.toml" });
        errdefer allocator.free(models_file);
        const models_dir = try std.fs.path.join(allocator, &.{ data_dir, "models" });
        errdefer allocator.free(models_dir);
        const glossary_file = try std.fs.path.join(allocator, &.{ config_dir, "glossary.toml" });
        errdefer allocator.free(glossary_file);
        const memory_file = try std.fs.path.join(allocator, &.{ data_dir, "memory.sqlite3" });
        return .{
            .config_dir = config_dir,
            .data_dir = data_dir,
            .cache_dir = cache_dir,
            .state_dir = state_dir,
            .config_file = config_file,
            .models_file = models_file,
            .models_dir = models_dir,
            .glossary_file = glossary_file,
            .memory_file = memory_file,
        };
    }
};

fn isAbsoluteNonEmpty(value: ?[]const u8) bool {
    const bytes = value orelse return false;
    return bytes.len > 0 and std.fs.path.isAbsolute(bytes);
}

fn fallbackReason(xdg_value: ?[]const u8) Reason {
    const bytes = xdg_value orelse return .fallback_unset;
    return if (bytes.len == 0) .fallback_empty else .fallback_relative;
}

fn unresolvedHomeReason(home: ?[]const u8) Reason {
    const bytes = home orelse return .unresolved_home_unset;
    return if (bytes.len == 0) .unresolved_home_empty else .unresolved_home_relative;
}

fn resolveDomain(allocator: std.mem.Allocator, xdg_value: ?[]const u8, home: ?[]const u8, home_suffix: []const u8) !DomainResolution {
    if (isAbsoluteNonEmpty(xdg_value)) return .{ .path = try std.fs.path.join(allocator, &.{ xdg_value.?, "kotoba" }), .reason = .direct };

    const reason = fallbackReason(xdg_value);
    if (!isAbsoluteNonEmpty(home)) return .{ .path = null, .reason = unresolvedHomeReason(home) };
    return .{ .path = try std.fs.path.join(allocator, &.{ home.?, home_suffix, "kotoba" }), .reason = reason };
}

/// Resolves XDG bases using only injected strings. It never reads the process
/// environment or creates filesystem entries.
pub fn resolve(allocator: std.mem.Allocator, inputs: Inputs) !Resolution {
    const config = try resolveDomain(allocator, inputs.config, inputs.home, ".config");
    errdefer if (config.path) |path| allocator.free(path);
    const data = try resolveDomain(allocator, inputs.data, inputs.home, ".local/share");
    errdefer if (data.path) |path| allocator.free(path);
    const cache = try resolveDomain(allocator, inputs.cache, inputs.home, ".cache");
    errdefer if (cache.path) |path| allocator.free(path);
    const state = try resolveDomain(allocator, inputs.state, inputs.home, ".local/state");
    errdefer if (state.path) |path| allocator.free(path);
    return .{ .config = config, .data = data, .cache = cache, .state = state };
}

fn getenvOptional(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    return sys.getenvOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
}

fn resolveFromEnvironment(allocator: std.mem.Allocator) !Resolution {
    const config = try getenvOptional(allocator, "XDG_CONFIG_HOME");
    defer if (config) |value| allocator.free(value);
    const data = try getenvOptional(allocator, "XDG_DATA_HOME");
    defer if (data) |value| allocator.free(value);
    const cache = try getenvOptional(allocator, "XDG_CACHE_HOME");
    defer if (cache) |value| allocator.free(value);
    const state = try getenvOptional(allocator, "XDG_STATE_HOME");
    defer if (state) |value| allocator.free(value);
    const home = if (isAbsoluteNonEmpty(config) and isAbsoluteNonEmpty(data) and isAbsoluteNonEmpty(cache) and isAbsoluteNonEmpty(state)) null else try getenvOptional(allocator, "HOME");
    defer if (home) |value| allocator.free(value);
    return resolve(allocator, .{
        .home = home,
        .config = config,
        .data = data,
        .cache = cache,
        .state = state,
    });
}

/// Every field borrows from the allocator passed to `paths`; cli.run keeps it alive for dispatch.
pub fn paths(allocator: std.mem.Allocator) !Paths {
    const resolution = try resolveFromEnvironment(allocator);
    errdefer resolution.deinit(allocator);
    return resolution.requirePaths(allocator);
}

pub fn ensureDirs(p: Paths) !void {
    try sys.makePath(p.config_dir);
    try sys.makePath(p.data_dir);
    try sys.makePath(p.models_dir);
    try sys.makePath(p.cache_dir);
    try sys.makePath(p.state_dir);
    if (std.fs.path.dirname(p.memory_file)) |dir| try sys.makePath(dir);
}

fn expectResolution(resolution: Resolution, domain: Domain, expected_path: ?[]const u8, expected_reason: Reason) !void {
    const actual = switch (domain) {
        .config => resolution.config,
        .data => resolution.data,
        .cache => resolution.cache,
        .state => resolution.state,
    };
    try std.testing.expectEqual(expected_reason, actual.reason);
    if (expected_path) |path| {
        try std.testing.expect(actual.path != null);
        try std.testing.expectEqualStrings(path, actual.path.?);
        try std.testing.expect(std.fs.path.isAbsolute(actual.path.?));
        try std.testing.expect(std.mem.endsWith(u8, actual.path.?, "/kotoba"));
    } else try std.testing.expect(actual.path == null);
}

fn deinitDerivedPaths(paths_value: Paths, allocator: std.mem.Allocator) void {
    allocator.free(paths_value.config_file);
    allocator.free(paths_value.models_file);
    allocator.free(paths_value.models_dir);
    allocator.free(paths_value.glossary_file);
    allocator.free(paths_value.memory_file);
}

test "xdg resolution preserves absolute XDG overrides" {
    const allocator = std.testing.allocator;
    const resolution = try resolve(allocator, .{
        .home = "/ignored/home",
        .config = "/fixture/config",
        .data = "/fixture/data",
        .cache = "/fixture/cache",
        .state = "/fixture/state",
    });
    defer resolution.deinit(allocator);
    try expectResolution(resolution, .config, "/fixture/config/kotoba", .direct);
    try expectResolution(resolution, .data, "/fixture/data/kotoba", .direct);
    try expectResolution(resolution, .cache, "/fixture/cache/kotoba", .direct);
    try expectResolution(resolution, .state, "/fixture/state/kotoba", .direct);
}

test "xdg resolution rejects empty and relative XDG values without exposing them" {
    const allocator = std.testing.allocator;
    const resolution = try resolve(allocator, .{
        .home = "/fixture/home",
        .config = "relative-config",
        .data = "",
        .cache = ".cache-relative",
        .state = "/fixture/state",
    });
    defer resolution.deinit(allocator);
    try expectResolution(resolution, .config, "/fixture/home/.config/kotoba", .fallback_relative);
    try expectResolution(resolution, .data, "/fixture/home/.local/share/kotoba", .fallback_empty);
    try expectResolution(resolution, .cache, "/fixture/home/.cache/kotoba", .fallback_relative);
    try expectResolution(resolution, .state, "/fixture/state/kotoba", .direct);
}

test "xdg resolution uses HOME only for domains needing fallback" {
    const allocator = std.testing.allocator;
    const resolution = try resolve(allocator, .{
        .home = "relative-home",
        .config = "/fixture/config",
        .data = "/fixture/data",
        .cache = "/fixture/cache",
        .state = "/fixture/state",
    });
    defer resolution.deinit(allocator);
    try expectResolution(resolution, .config, "/fixture/config/kotoba", .direct);
    try expectResolution(resolution, .data, "/fixture/data/kotoba", .direct);
    try expectResolution(resolution, .cache, "/fixture/cache/kotoba", .direct);
    try expectResolution(resolution, .state, "/fixture/state/kotoba", .direct);
}

test "xdg resolution leaves only fallback domains unresolved for unusable HOME" {
    const allocator = std.testing.allocator;
    const resolution = try resolve(allocator, .{
        .home = null,
        .config = null,
        .data = "/fixture/data",
        .cache = "/fixture/cache",
        .state = "/fixture/state",
    });
    defer resolution.deinit(allocator);
    try expectResolution(resolution, .config, null, .unresolved_home_unset);
    try expectResolution(resolution, .data, "/fixture/data/kotoba", .direct);
    try expectResolution(resolution, .cache, "/fixture/cache/kotoba", .direct);
    try expectResolution(resolution, .state, "/fixture/state/kotoba", .direct);
}

test "xdg resolution rejects empty and relative HOME only for fallback domains" {
    const allocator = std.testing.allocator;
    for ([_]struct { home: ?[]const u8, reason: Reason }{
        .{ .home = "", .reason = .unresolved_home_empty },
        .{ .home = ".relative-home", .reason = .unresolved_home_relative },
    }) |case| {
        const resolution = try resolve(allocator, .{
            .home = case.home,
            .config = null,
            .data = "/fixture/data",
            .cache = "/fixture/cache",
            .state = "/fixture/state",
        });
        defer resolution.deinit(allocator);
        try expectResolution(resolution, .config, null, case.reason);
        try expectResolution(resolution, .data, "/fixture/data/kotoba", .direct);
        try expectResolution(resolution, .cache, "/fixture/cache/kotoba", .direct);
        try expectResolution(resolution, .state, "/fixture/state/kotoba", .direct);
    }
}

test "xdg resolution accepts all absolute XDG values without usable HOME" {
    const allocator = std.testing.allocator;
    for ([_]?[]const u8{ null, "", "relative-home" }) |home| {
        const resolution = try resolve(allocator, .{
            .home = home,
            .config = "/fixture/config",
            .data = "/fixture/data",
            .cache = "/fixture/cache",
            .state = "/fixture/state",
        });
        defer resolution.deinit(allocator);
        try expectResolution(resolution, .config, "/fixture/config/kotoba", .direct);
        try expectResolution(resolution, .data, "/fixture/data/kotoba", .direct);
        try expectResolution(resolution, .cache, "/fixture/cache/kotoba", .direct);
        try expectResolution(resolution, .state, "/fixture/state/kotoba", .direct);
    }
}

test "xdg resolution preserves special characters in accepted absolute paths" {
    const allocator = std.testing.allocator;
    const base = "/fixture/space 😀 '\"\\ accepted";
    const resolution = try resolve(allocator, .{
        .home = "/unused",
        .config = base,
        .data = base,
        .cache = base,
        .state = base,
    });
    defer resolution.deinit(allocator);
    const expected = base ++ "/kotoba";
    inline for ([_]Domain{ .config, .data, .cache, .state }) |domain| try expectResolution(resolution, domain, expected, .direct);
}

test "xdg Resolution requirePaths produces absolute derived paths only when complete" {
    const allocator = std.testing.allocator;
    const complete = try resolve(allocator, .{ .home = "/fixture/home" });
    defer complete.deinit(allocator);
    const complete_paths = try complete.requirePaths(allocator);
    defer deinitDerivedPaths(complete_paths, allocator);
    inline for ([_][]const u8{
        complete_paths.config_dir,
        complete_paths.data_dir,
        complete_paths.cache_dir,
        complete_paths.state_dir,
        complete_paths.config_file,
        complete_paths.models_file,
        complete_paths.models_dir,
        complete_paths.glossary_file,
        complete_paths.memory_file,
    }) |path| try std.testing.expect(std.fs.path.isAbsolute(path));
    try std.testing.expectEqualStrings("/fixture/home/.config/kotoba/config.toml", complete_paths.config_file);
    try std.testing.expectEqualStrings("/fixture/home/.local/share/kotoba/memory.sqlite3", complete_paths.memory_file);

    const partial = try resolve(allocator, .{ .home = null, .config = null, .data = "/fixture/data", .cache = "/fixture/cache", .state = "/fixture/state" });
    defer partial.deinit(allocator);
    try std.testing.expectError(error.PathResolutionFailed, partial.requirePaths(allocator));
}

test "xdg resolution is side-effect-free" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const resolution = try resolve(allocator, .{ .home = root });
    defer resolution.deinit(allocator);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, ".config", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, ".local", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, ".cache", .{}));
}

fn exerciseResolutionAllocationFailures(allocator: std.mem.Allocator) !void {
    const resolution = try resolve(allocator, .{
        .home = "/fixture/home",
        .config = "/fixture/config",
        .data = "/fixture/data",
        .cache = "/fixture/cache",
        .state = "/fixture/state",
    });
    defer resolution.deinit(allocator);
    const resolved_paths = try resolution.requirePaths(allocator);
    defer deinitDerivedPaths(resolved_paths, allocator);
}

test "xdg resolution frees partial allocations on OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseResolutionAllocationFailures, .{});
}
