const std = @import("std");
const config = @import("config.zig");
const errors = @import("errors.zig");
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
    var owned_config: ?config.OwnedConfig = config.load(allocator, paths.config_file) catch |err| blk: {
        const app_err = errors.fromError(err);
        try checks.append(.{ .name = "config", .status = .@"error", .code = app_err.code.asText(), .message = app_err.message });
        ok = false;
        have_config = false;
        break :blk null;
    };
    defer if (owned_config) |*owner| owner.deinit();
    const cfg = if (owned_config) |*owner| owner.view() else config.default();
    if (have_config) try checks.append(.{ .name = "config", .status = .ok, .message = "config.toml is readable" });

    if (have_config) try checks.append(.{ .name = "llama_cpp", .status = .ok, .message = "embedded llama.cpp runtime is linked" });

    var list_owner = models.load(allocator, paths.models_file) catch |err| {
        const app_err = errors.fromError(err);
        try checks.append(.{ .name = "models", .status = .@"error", .code = app_err.code.asText(), .message = app_err.message });
        ok = false;
        if (!have_config) return print(allocator, checks.items, ok, json);
        try appendModelChecks(allocator, null, cfg, &checks, &ok);
        return continueAfterModelCheck(allocator, paths, cfg, &checks, ok, json);
    };
    defer list_owner.deinit();
    const list = list_owner.view();
    try checks.append(.{ .name = "models", .status = .ok, .message = "models.toml is readable" });
    try appendUnsafeRemoteUrlCheck(list, &checks);
    if (!have_config) return print(allocator, checks.items, ok, json);
    try appendModelChecks(allocator, list, cfg, &checks, &ok);
    return continueAfterModelCheck(allocator, paths, cfg, &checks, ok, json);
}

fn appendUnsafeRemoteUrlCheck(list: models.List, checks: *std.array_list.Managed(Check)) !void {
    for (list.models) |model| {
        if (models.url.hasUnsafeMetadata(model.download_url) or models.url.hasUnsafeMetadata(model.source_url)) {
            try checks.append(.{
                .name = "model_source_credentials",
                .status = .warn,
                .code = "model_source_credentials",
                .message = "Model registry contains unsafe remote URL metadata. Reads do not change it; the next registry write removes unsafe URL fields. Re-pull with a fresh --model-url when needed.",
            });
            return;
        }
    }
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
    var glossary_owner = glossary.load(allocator, paths.glossary_file) catch {
        try checks.append(.{ .name = "glossary", .status = .@"error", .code = "glossary_invalid", .message = "glossary.toml is invalid" });
        ok = false;
        return print(allocator, checks.items, ok, json);
    };
    defer glossary_owner.deinit();
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

const TestStdoutCapture = struct {
    const c = std.c;
    saved: c_int,

    fn start(file: std.Io.File) !TestStdoutCapture {
        const saved = c.dup(std.posix.STDOUT_FILENO);
        if (saved < 0) return error.CaptureFailed;
        errdefer _ = c.close(saved);
        if (c.dup2(file.handle, std.posix.STDOUT_FILENO) < 0) return error.CaptureFailed;
        return .{ .saved = saved };
    }

    fn restore(self: *TestStdoutCapture) void {
        if (self.saved < 0) return;
        if (c.dup2(self.saved, std.posix.STDOUT_FILENO) < 0) @panic("stdout restore failed");
        if (c.close(self.saved) != 0) @panic("stdout capture close failed");
        self.saved = -1;
    }
};

fn testDoctorPaths(allocator: std.mem.Allocator, root: []const u8) !xdg.Paths {
    return .{
        .config_dir = root,
        .data_dir = root,
        .cache_dir = root,
        .state_dir = root,
        .config_file = try std.fs.path.join(allocator, &.{ root, "config.toml" }),
        .models_file = try std.fs.path.join(allocator, &.{ root, "models.toml" }),
        .models_dir = root,
        .glossary_file = try std.fs.path.join(allocator, &.{ root, "glossary.toml" }),
        .memory_file = try std.fs.path.join(allocator, &.{ root, "memory.sqlite3" }),
    };
}

fn countText(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        count += 1;
        rest = rest[index + needle.len ..];
    }
    return count;
}

fn testLoadErrorCategories(config_failure: bool) !void {
    const cases = [_]struct {
        text: ?[]const u8 = null,
        directory: bool = false,
        code: []const u8,
        message: []const u8,
    }{
        .{ .text = if (config_failure) "gpu_layers = \"auto\"\n" else "[[models]]\nid = \"fixture61\"\nrecommended = \"true\"\n", .code = if (config_failure) "config_invalid" else "models_invalid", .message = if (config_failure) "config.toml is invalid." else "models.toml is invalid." },
        .{ .code = "not_initialized", .message = "Kotoba is not initialized. Run `kotoba init`." },
        .{ .text = "unknown = \"KOTOBA_BODY_SECRET_61\"\n", .code = if (config_failure) "config_invalid" else "models_invalid", .message = if (config_failure) "config.toml is invalid." else "models.toml is invalid." },
        .{ .text = "schema_version = 2\n", .code = if (config_failure) "config_schema_unsupported" else "models_schema_unsupported", .message = if (config_failure) "config.toml uses an unsupported schema or version." else "models.toml uses an unsupported schema or version." },
        .{ .directory = true, .code = "io_error", .message = "IsDir" },
    };
    for (cases) |case| {
        for ([_]bool{ true, false }) |json| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            var tmp = std.testing.tmpDir(.{ .iterate = true });
            defer tmp.cleanup();
            const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
            const paths = try testDoctorPaths(allocator, root);
            const failed_path = if (config_failure) paths.config_file else paths.models_file;
            const valid_path = if (config_failure) paths.models_file else paths.config_file;
            try sys.writeFile(valid_path, "# valid untouched state\n");
            if (case.text) |text| try sys.writeFile(failed_path, text);
            if (case.directory) try tmp.dir.createDir(std.testing.io, if (config_failure) "config.toml" else "models.toml", .default_dir);
            const output = try tmp.dir.createFile(sys.io(), "stdout", .{ .read = true });
            defer output.close(sys.io());
            var capture = try TestStdoutCapture.start(output);
            defer capture.restore();
            const exit_code = try run(allocator, paths, json);
            capture.restore();
            const rendered = try sys.readFileAlloc(allocator, try std.fs.path.join(allocator, &.{ root, "stdout" }), 8192);
            try std.testing.expectEqual(@as(u8, 1), exit_code);
            const name = if (config_failure) "config" else "models";
            if (json) {
                const report = try std.json.parseFromSlice(struct { ok: bool, checks: []Check }, allocator, rendered, .{});
                defer report.deinit();
                try std.testing.expect(!report.value.ok);
                const check = report.value.checks[if (config_failure) 0 else 2];
                try std.testing.expectEqualStrings(name, check.name);
                try std.testing.expectEqual(Status.@"error", check.status);
                try std.testing.expectEqualStrings(case.code, check.code);
                try std.testing.expectEqualStrings(case.message, check.message);
                if (config_failure) try std.testing.expectEqual(@as(usize, 2), report.value.checks.len);
            } else {
                const expected = try std.fmt.allocPrint(allocator, "error: {s}: {s}\n", .{ name, case.message });
                try std.testing.expect(std.mem.startsWith(u8, rendered, if (config_failure) expected else "ok: config: config.toml is readable\nok: llama_cpp: embedded llama.cpp runtime is linked\n"));
                try std.testing.expectEqual(@as(usize, 1), countText(rendered, expected));
                if (config_failure) try std.testing.expectEqual(@as(usize, 2), countText(rendered, "\n"));
            }
            try std.testing.expect(std.mem.indexOf(u8, rendered, "KOTOBA_BODY_SECRET_61") == null);
            try std.testing.expectEqualStrings("# valid untouched state\n", try sys.readFileAlloc(allocator, valid_path, 8192));
            if (case.text) |text| {
                try std.testing.expectEqualStrings(text, try sys.readFileAlloc(allocator, failed_path, 8192));
            } else if (case.directory) {
                try std.testing.expectError(error.IsDir, sys.readFileAlloc(allocator, failed_path, 8192));
            } else {
                try std.testing.expect(!sys.exists(failed_path));
            }
            var entries = tmp.dir.iterate();
            var entry_count: usize = 0;
            while (try entries.next(std.testing.io)) |_| entry_count += 1;
            try std.testing.expectEqual(@as(usize, if (case.text != null or case.directory) 3 else 2), entry_count);
        }
    }
}

test "strict doctor config load error categories" {
    try testLoadErrorCategories(true);
}

test "strict doctor registry load error categories" {
    try testLoadErrorCategories(false);
}

test "secret URL doctor ignores sanitized source and local metadata" {
    var checks = std.array_list.Managed(Check).init(std.testing.allocator);
    defer checks.deinit();
    var safe_models = [_]models.Model{
        .{ .id = "sanitized36", .source_url = "https://models.example.invalid/sanitized.gguf" },
        .{ .id = "local36", .path = "/local/model?#.gguf" },
    };
    const list = models.List{ .models = &safe_models };
    try appendUnsafeRemoteUrlCheck(list, &checks);
    try std.testing.expectEqual(@as(usize, 0), checks.items.len);
}

test "secret URL doctor scans all legacy entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const paths = try testDoctorPaths(allocator, root);
    const model_path = try std.fs.path.join(allocator, &.{ root, "safe.gguf" });
    try sys.writeFile(model_path, "safe model");
    const config_text = try std.fmt.allocPrint(allocator, "model_id = \"safe36\"\nmodel_path = \"{s}\"\n", .{model_path});
    defer allocator.free(config_text);
    try sys.writeFile(paths.config_file, config_text);
    const registry_text = try std.fmt.allocPrint(allocator, "[[models]]\nid = \"safe36\"\npath = \"{s}\"\nsource_url = \"https://models.example.invalid/safe.gguf\"\n\n" ++
        "[[models]]\nid = \"signed36\"\ndownload_url = \"https://models.example.invalid/signed.gguf?token=KOTOBA_QUERY_SECRET_36\"\nsource_url = \"https://models.example.invalid/signed.gguf\"\n\n" ++
        "[[models]]\nid = \"userinfo36\"\ndownload_url = \"https://KOTOBA_USER_36:KOTOBA_PASSWORD_36@models.example.invalid/userinfo.gguf\"\n\n" ++
        "[[models]]\nid = \"sanitized36\"\nsource_url = \"https://models.example.invalid/sanitized.gguf\"\n\n" ++
        "[[models]]\nid = \"local36\"\npath = \"/local/model?#.gguf\"\n", .{model_path});
    defer allocator.free(registry_text);
    try sys.writeFile(paths.models_file, registry_text);
    var db = try memory.open(allocator, paths.memory_file);
    db.close();
    try sys.writeFile(paths.glossary_file, glossary.defaultTemplate());

    const output = try tmp.dir.createFile(sys.io(), "stdout", .{ .read = true });
    defer output.close(sys.io());
    var capture = try TestStdoutCapture.start(output);
    defer capture.restore();
    const exit_code = try run(allocator, paths, false);
    capture.restore();
    const rendered = try sys.readFileAlloc(allocator, try std.fs.path.join(allocator, &.{ root, "stdout" }), 8192);
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings(config_text, try sys.readFileAlloc(allocator, paths.config_file, 8192));
    try std.testing.expectEqualStrings(registry_text, try sys.readFileAlloc(allocator, paths.models_file, 8192));
    try std.testing.expectEqual(@as(usize, 1), countText(rendered, "warn: model_source_credentials: "));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "KOTOBA_QUERY_SECRET_36") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "KOTOBA_USER_36") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "local36") == null);
}

test "secret URL doctor warning uses only static text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const paths = try testDoctorPaths(allocator, root);
    const registry = "[[models]]\nid = \"legacy36\"\ndownload_url = \"https://KOTOBA_USER_36:KOTOBA_PASSWORD_36@models.example.invalid/legacy.gguf?token=KOTOBA_QUERY_SECRET_36#KOTOBA_FRAGMENT_SECRET_36\"\n";
    try sys.writeFile(paths.models_file, registry);
    const before = try sys.readFileAlloc(allocator, paths.models_file, 8192);
    const output = try tmp.dir.createFile(sys.io(), "stdout", .{ .read = true });
    defer output.close(sys.io());
    var capture = try TestStdoutCapture.start(output);
    defer capture.restore();
    const exit_code = try run(allocator, paths, true);
    capture.restore();
    const rendered = try sys.readFileAlloc(allocator, try std.fs.path.join(allocator, &.{ root, "stdout" }), 8192);
    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqualStrings(before, try sys.readFileAlloc(allocator, paths.models_file, 8192));
    try std.testing.expectEqual(@as(usize, 1), countText(rendered, "\"name\":\"model_source_credentials\""));
    try std.testing.expectEqual(@as(usize, 1), countText(rendered, "\"code\":\"model_source_credentials\""));
    try std.testing.expectEqual(@as(usize, 1), countText(rendered, "Model registry contains unsafe remote URL metadata. Reads do not change it; the next registry write removes unsafe URL fields. Re-pull with a fresh --model-url when needed."));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "KOTOBA_") == null);
}
