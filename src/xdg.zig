const std = @import("std");
const sys = @import("sys.zig");

pub const Paths = struct {
    config_dir: []const u8,
    data_dir: []const u8,
    cache_dir: []const u8,
    state_dir: []const u8,
    config_file: []const u8,
    models_file: []const u8,
    glossary_file: []const u8,
    memory_file: []const u8,
};

fn envOrHome(allocator: std.mem.Allocator, env_name: []const u8, home_suffix: []const u8) ![]const u8 {
    if (sys.getenvOwned(allocator, env_name)) |value| {
        return value;
    } else |_| {
        const home = try sys.getenvOwned(allocator, "HOME");
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, home_suffix });
    }
}

pub fn paths(allocator: std.mem.Allocator) !Paths {
    const base_config = try envOrHome(allocator, "XDG_CONFIG_HOME", ".config");
    const base_data = try envOrHome(allocator, "XDG_DATA_HOME", ".local/share");
    const base_cache = try envOrHome(allocator, "XDG_CACHE_HOME", ".cache");
    const base_state = try envOrHome(allocator, "XDG_STATE_HOME", ".local/state");
    const config_dir = try std.fs.path.join(allocator, &.{ base_config, "kotoba" });
    const data_dir = try std.fs.path.join(allocator, &.{ base_data, "kotoba" });
    const cache_dir = try std.fs.path.join(allocator, &.{ base_cache, "kotoba" });
    const state_dir = try std.fs.path.join(allocator, &.{ base_state, "kotoba" });
    return .{
        .config_dir = config_dir,
        .data_dir = data_dir,
        .cache_dir = cache_dir,
        .state_dir = state_dir,
        .config_file = try std.fs.path.join(allocator, &.{ config_dir, "config.toml" }),
        .models_file = try std.fs.path.join(allocator, &.{ config_dir, "models.toml" }),
        .glossary_file = try std.fs.path.join(allocator, &.{ config_dir, "glossary.toml" }),
        .memory_file = try std.fs.path.join(allocator, &.{ data_dir, "memory.sqlite3" }),
    };
}

pub fn ensureDirs(p: Paths) !void {
    try sys.makePath(p.config_dir);
    try sys.makePath(p.data_dir);
    try sys.makePath(p.cache_dir);
    try sys.makePath(p.state_dir);
    if (std.fs.path.dirname(p.memory_file)) |dir| try sys.makePath(dir);
}
