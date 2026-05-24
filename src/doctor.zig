const std = @import("std");
const config = @import("config.zig");
const glossary = @import("glossary.zig");
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

    if (have_config) try checks.append(.{ .name = "llama_cpp", .status = .ok, .message = "embedded llama.cpp runtime is linked" });

    const list = models.load(allocator, paths.models_file) catch {
        try checks.append(.{ .name = "models", .status = .@"error", .code = "models_invalid", .message = "models.toml is missing or invalid" });
        ok = false;
        if (!have_config) return print(allocator, checks.items, ok, json);
        try appendModelChecks(allocator, null, cfg, &checks, &ok);
        return continueAfterModelCheck(allocator, paths, cfg, &checks, ok, json);
    };
    try checks.append(.{ .name = "models", .status = .ok, .message = "models.toml is readable" });
    if (!have_config) return print(allocator, checks.items, ok, json);
    try appendModelChecks(allocator, list, cfg, &checks, &ok);
    return continueAfterModelCheck(allocator, paths, cfg, &checks, ok, json);
}

fn appendModelChecks(allocator: std.mem.Allocator, list_opt: ?models.List, cfg: config.Config, checks: *std.array_list.Managed(Check), ok: *bool) !void {
    if (cfg.model_id.len == 0 or cfg.model_path.len == 0) {
        try checks.append(.{ .name = "selected_model", .status = .@"error", .code = "model_not_selected", .message = "no model is selected" });
        ok.* = false;
        return;
    }
    try checks.append(.{ .name = "selected_model", .status = .ok, .message = "model is selected" });
    if (!sys.exists(cfg.model_path)) {
        try checks.append(.{ .name = "model_file", .status = .@"error", .code = "model_missing", .message = "configured model_path does not exist" });
        ok.* = false;
        return;
    }
    try checks.append(.{ .name = "model_file", .status = .ok, .message = "configured model_path exists" });
    if (list_opt) |list| {
        if (models.find(list, cfg.model_id)) |m| {
            try checks.append(.{ .name = "model_registry", .status = .ok, .message = "selected model is registered" });
            if (m.checksum.len > 0) {
                models.verifySha256(allocator, cfg.model_path, m.checksum) catch {
                    try checks.append(.{ .name = "model_checksum", .status = .@"error", .code = "checksum_failed", .message = "configured model checksum does not match registry" });
                    ok.* = false;
                    return;
                };
                try checks.append(.{ .name = "model_checksum", .status = .ok, .message = "configured model checksum matches registry" });
            } else {
                try checks.append(.{ .name = "model_checksum", .status = .warn, .message = "selected model has no checksum" });
            }
        } else {
            try checks.append(.{ .name = "model_registry", .status = .@"error", .code = "model_registry_invalid", .message = "selected model is not registered" });
            ok.* = false;
        }
    }
}

fn continueAfterModelCheck(allocator: std.mem.Allocator, paths: xdg.Paths, cfg: config.Config, checks: *std.array_list.Managed(Check), ok_in: bool, json: bool) !u8 {
    var ok = ok_in;
    var db = memory.openReadOnly(allocator, paths.memory_file) catch {
        try checks.append(.{ .name = "memory", .status = .@"error", .code = "sqlite_failed", .message = "memory DB cannot be opened" });
        ok = false;
        return print(allocator, checks.items, ok, json);
    };
    defer db.close();
    _ = db.count() catch {
        try checks.append(.{ .name = "memory", .status = .@"error", .code = "sqlite_failed", .message = "memory DB cannot be read" });
        ok = false;
        return print(allocator, checks.items, ok, json);
    };
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
