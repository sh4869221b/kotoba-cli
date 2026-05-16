const std = @import("std");
const config = @import("config.zig");
const glossary = @import("glossary.zig");
const llama = @import("llama.zig");
const memory = @import("memory.zig");
const models = @import("models.zig");
const sys = @import("sys.zig");
const xdg = @import("xdg.zig");

pub const Status = enum { ok, warn, @"error" };

pub const Check = struct {
    name: []const u8,
    status: Status,
    code: []const u8 = "",
    message: []const u8,
};

pub fn run(allocator: std.mem.Allocator, paths: xdg.Paths, json: bool) !u8 {
    var checks = std.array_list.Managed(Check).init(allocator);
    var ok = true;

    var have_config = true;
    const cfg = config.load(allocator, paths.config_file) catch blk: {
        try checks.append(.{ .name = "config", .status = .@"error", .code = "not_initialized", .message = "config.toml is missing or invalid" });
        ok = false;
        have_config = false;
        break :blk config.default();
    };
    if (have_config) try checks.append(.{ .name = "config", .status = .ok, .message = "config.toml is readable" });
    _ = models.load(allocator, paths.models_file) catch {
        try checks.append(.{ .name = "models", .status = .@"error", .code = "models_invalid", .message = "models.toml is missing or invalid" });
        ok = false;
        return print(allocator, checks.items, ok, json);
    };
    try checks.append(.{ .name = "models", .status = .ok, .message = "models.toml is readable" });
    if (!have_config) return print(allocator, checks.items, ok, json);
    if (cfg.model_path.len > 0) {
        if (!sys.exists(cfg.model_path)) {
            try checks.append(.{ .name = "model", .status = .@"error", .code = "model_missing", .message = "configured model_path does not exist" });
            ok = false;
        } else {
            try checks.append(.{ .name = "model", .status = .ok, .message = "configured model_path exists" });
        }
    }
    llama.validateLocalServerUrl(cfg.server_url, false) catch {
        try checks.append(.{ .name = "server_url", .status = .@"error", .code = "server_not_local", .message = "server_url is not local loopback" });
        ok = false;
    };
    _ = llama.healthCheck(allocator, cfg.server_url, cfg.timeout_sec, false) catch {
        try checks.append(.{ .name = "server", .status = .warn, .code = "server_unreachable", .message = "server is not reachable; start llama-server or update server_url" });
        return continueAfterServerCheck(allocator, paths, cfg, &checks, ok, json);
    };
    try checks.append(.{ .name = "server", .status = .ok, .message = "server health check passed" });
    return continueAfterServerCheck(allocator, paths, cfg, &checks, ok, json);
}

fn continueAfterServerCheck(allocator: std.mem.Allocator, paths: xdg.Paths, cfg: config.Config, checks: *std.array_list.Managed(Check), ok_in: bool, json: bool) !u8 {
    var ok = ok_in;
    var db = memory.open(allocator, paths.memory_file) catch {
        try checks.append(.{ .name = "memory", .status = .@"error", .code = "sqlite_failed", .message = "memory DB cannot be opened" });
        ok = false;
        return print(allocator, checks.items, ok, json);
    };
    db.close();
    try checks.append(.{ .name = "memory", .status = .ok, .message = "memory DB is readable" });
    _ = glossary.load(allocator, paths.glossary_file) catch {
        try checks.append(.{ .name = "glossary", .status = .@"error", .code = "glossary_invalid", .message = "glossary.toml is invalid" });
        ok = false;
        return print(allocator, checks.items, ok, json);
    };
    try checks.append(.{ .name = "glossary", .status = .ok, .message = "glossary.toml is readable" });
    if (!cfg.privacy_mode) try checks.append(.{ .name = "privacy", .status = .warn, .message = "privacy_mode is disabled" }) else try checks.append(.{ .name = "privacy", .status = .ok, .message = "privacy_mode is enabled" });
    return print(allocator, checks.items, ok, json);
}

fn print(allocator: std.mem.Allocator, checks: []Check, ok: bool, json: bool) !u8 {
    _ = allocator;
    if (json) {
        sys.stdoutPrint("{{\"ok\":{},\"checks\":[", .{ok});
        for (checks, 0..) |check, i| {
            if (i > 0) sys.stdoutPrint(",", .{});
            sys.stdoutPrint("{{\"name\":\"{s}\",\"status\":\"{s}\",\"code\":\"{s}\",\"message\":\"{s}\"}}", .{ check.name, @tagName(check.status), check.code, check.message });
        }
        sys.stdoutPrint("]}}\n", .{});
    } else {
        for (checks) |check| sys.stdoutPrint("{s}: {s}: {s}\n", .{ @tagName(check.status), check.name, check.message });
    }
    return if (ok) 0 else 1;
}
