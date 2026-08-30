const std = @import("std");
const config = @import("config.zig");
const errors = @import("errors.zig");
const glossary = @import("glossary.zig");
const memory = @import("memory.zig");
const models = @import("models.zig");
const output_module = @import("output.zig");
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
    var invocation_arena = std.heap.ArenaAllocator.init(allocator);
    defer invocation_arena.deinit();
    const command_allocator = invocation_arena.allocator();
    var checks = std.array_list.Managed(Check).init(command_allocator);
    defer checks.deinit();
    return runChecks(command_allocator, paths, &checks, true, json);
}

pub fn runResolution(allocator: std.mem.Allocator, resolution: xdg.Resolution, json: bool) !u8 {
    var invocation_arena = std.heap.ArenaAllocator.init(allocator);
    defer invocation_arena.deinit();
    const command_allocator = invocation_arena.allocator();
    var checks = std.array_list.Managed(Check).init(command_allocator);
    defer checks.deinit();
    var ok = true;
    try appendPathChecks(resolution, &checks, &ok);
    if (!ok) return print(command_allocator, checks.items, false, json);
    const paths = try resolution.requirePaths(command_allocator);
    return runChecks(command_allocator, paths, &checks, true, json);
}

fn appendPathChecks(resolution: xdg.Resolution, checks: *std.array_list.Managed(Check), ok: *bool) !void {
    inline for ([_]struct { domain: xdg.Domain, name: []const u8 }{
        .{ .domain = .config, .name = "config_path" },
        .{ .domain = .data, .name = "data_path" },
        .{ .domain = .cache, .name = "cache_path" },
        .{ .domain = .state, .name = "state_path" },
    }) |entry| {
        const resolved = resolution.get(entry.domain);
        if (resolved.path) |path| {
            switch (resolved.reason) {
                .direct, .fallback_unset => try checks.append(.{ .name = entry.name, .status = .ok, .message = path }),
                .fallback_empty, .fallback_relative => try checks.append(.{ .name = entry.name, .status = .warn, .code = "xdg_path_invalid", .message = path }),
                .unresolved_home_unset, .unresolved_home_empty, .unresolved_home_relative => unreachable,
            }
        } else {
            try checks.append(.{
                .name = entry.name,
                .status = .@"error",
                .code = "path_resolution_failed",
                .message = "Could not resolve XDG paths from absolute XDG values or HOME.",
            });
            ok.* = false;
        }
    }
}

fn runChecks(command_allocator: std.mem.Allocator, paths: xdg.Paths, checks: *std.array_list.Managed(Check), ok_in: bool, json: bool) !u8 {
    var ok = ok_in;

    var have_config = true;
    var owned_config: ?config.OwnedConfig = config.load(command_allocator, paths.config_file) catch |err| blk: {
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

    var list_owner = models.load(command_allocator, paths.models_file) catch |err| {
        const app_err = errors.fromError(err);
        try checks.append(.{ .name = "models", .status = .@"error", .code = app_err.code.asText(), .message = app_err.message });
        ok = false;
        if (!have_config) return print(command_allocator, checks.items, ok, json);
        try appendModelChecks(command_allocator, null, cfg, checks, &ok);
        return continueAfterModelCheck(command_allocator, paths, cfg, checks, ok, json);
    };
    defer list_owner.deinit();
    const list = list_owner.view();
    try checks.append(.{ .name = "models", .status = .ok, .message = "models.toml is readable" });
    try appendUnsafeRemoteUrlCheck(list, checks);
    if (!have_config) return print(command_allocator, checks.items, ok, json);
    try appendModelChecks(command_allocator, list, cfg, checks, &ok);
    return continueAfterModelCheck(command_allocator, paths, cfg, checks, ok, json);
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
    if (json) {
        var rendered_checks = std.array_list.Managed(Check).init(allocator);
        defer rendered_checks.deinit();
        for (checks) |check| try rendered_checks.append(.{
            .name = check.name,
            .status = check.status,
            .code = check.code,
            .message = try diagnosticText(allocator, check.message),
        });
        const out = try output_module.jsonLineAlloc(allocator, .{ .ok = ok, .checks = rendered_checks.items });
        defer allocator.free(out);
        sys.stdoutWrite(out);
    } else {
        for (checks) |check| {
            sys.stdoutPrint("{s}: {s}: ", .{ @tagName(check.status), check.name });
            writeHumanOneLine(try diagnosticText(allocator, check.message));
            sys.stdoutWrite("\n");
        }
    }
    return if (ok) 0 else 1;
}

fn diagnosticText(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const hex = "0123456789abcdef";
    var escaped = std.array_list.Managed(u8).init(allocator);
    var index: usize = 0;
    while (index < value.len) {
        const byte = value[index];
        if (byte < 0x80) {
            switch (byte) {
                '\n' => try escaped.appendSlice("\\n"),
                '\r' => try escaped.appendSlice("\\r"),
                '\t' => try escaped.appendSlice("\\t"),
                0...8, 11...12, 14...31, 127 => try escaped.appendSlice(&.{ '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 0x0f] }),
                else => try escaped.append(byte),
            }
            index += 1;
            continue;
        }
        const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try escaped.appendSlice(&.{ '\\', 'x', hex[byte >> 4], hex[byte & 0x0f] });
            index += 1;
            continue;
        };
        if (index + sequence_len > value.len) {
            try escaped.appendSlice(&.{ '\\', 'x', hex[byte >> 4], hex[byte & 0x0f] });
            index += 1;
            continue;
        }
        const sequence = value[index .. index + sequence_len];
        const codepoint = std.unicode.utf8Decode(sequence) catch {
            try escaped.appendSlice(&.{ '\\', 'x', hex[byte >> 4], hex[byte & 0x0f] });
            index += 1;
            continue;
        };
        if (codepoint >= 0x80 and codepoint <= 0x9f) {
            const control: u8 = @intCast(codepoint);
            try escaped.appendSlice(&.{ '\\', 'u', '0', '0', hex[control >> 4], hex[control & 0x0f] });
        } else {
            try escaped.appendSlice(sequence);
        }
        index += sequence_len;
    }
    return escaped.toOwnedSlice();
}

fn writeHumanOneLine(value: []const u8) void {
    const hex = "0123456789abcdef";
    for (value) |byte| switch (byte) {
        '\n' => sys.stdoutWrite("\\n"),
        '\r' => sys.stdoutWrite("\\r"),
        '\t' => sys.stdoutWrite("\\t"),
        0...8, 11...12, 14...31, 127 => sys.stdoutPrint("\\u00{c}{c}", .{ hex[byte >> 4], hex[byte & 0x0f] }),
        else => sys.stdoutWrite(&.{byte}),
    };
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

test "ownership/doctor direct invocation releases checks" {
    var counter = @import("ownership_test_support.zig").CountingAllocator.init(std.testing.allocator);
    const allocator = counter.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup_arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", setup_arena.allocator());
    const paths = try testDoctorPaths(setup_arena.allocator(), root);
    const output = try tmp.dir.createFile(std.testing.io, "stdout", .{});
    defer output.close(std.testing.io);
    var capture = try TestStdoutCapture.start(output);
    defer capture.restore();

    try std.testing.expectEqual(@as(u8, 1), try run(allocator, paths, false));
    capture.restore();
    try std.testing.expectEqual(@as(usize, 0), counter.live_bytes);
    try std.testing.expectEqual(@as(usize, 0), counter.live_allocations);
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

test "doctor prepends resolved XDG path checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const resolution = try xdg.resolve(allocator, .{
        .config = root,
        .data = root,
        .cache = root,
        .state = root,
    });
    const output = try tmp.dir.createFile(sys.io(), "stdout", .{ .read = true });
    defer output.close(sys.io());
    var capture = try TestStdoutCapture.start(output);
    defer capture.restore();

    _ = try runResolution(allocator, resolution, true);
    capture.restore();
    const rendered = try sys.readFileAlloc(allocator, try std.fs.path.join(allocator, &.{ root, "stdout" }), 8192);
    const report = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer report.deinit();
    const checks = report.value.object.get("checks").?.array.items;
    try std.testing.expect(checks.len >= 4);
    try std.testing.expectEqualStrings("config_path", checks[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("data_path", checks[1].object.get("name").?.string);
    try std.testing.expectEqualStrings("cache_path", checks[2].object.get("name").?.string);
    try std.testing.expectEqualStrings("state_path", checks[3].object.get("name").?.string);
}

test "doctor path warnings preserve health and expose only resolved paths" {
    const allocator = std.testing.allocator;
    const resolution = try xdg.resolve(allocator, .{
        .home = "/fixture/home",
        .config = "rejected-config",
        .data = "",
        .cache = null,
        .state = "/fixture/state",
    });
    defer resolution.deinit(allocator);
    var checks = std.array_list.Managed(Check).init(allocator);
    defer checks.deinit();
    var ok = true;
    try appendPathChecks(resolution, &checks, &ok);

    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 4), checks.items.len);
    try std.testing.expectEqual(Status.warn, checks.items[0].status);
    try std.testing.expectEqualStrings("xdg_path_invalid", checks.items[0].code);
    try std.testing.expectEqualStrings("/fixture/home/.config/kotoba", checks.items[0].message);
    try std.testing.expectEqual(Status.warn, checks.items[1].status);
    try std.testing.expectEqualStrings("xdg_path_invalid", checks.items[1].code);
    try std.testing.expectEqual(Status.ok, checks.items[2].status);
    try std.testing.expectEqualStrings("", checks.items[2].code);
    try std.testing.expectEqual(Status.ok, checks.items[3].status);
    try std.testing.expect(std.mem.indexOf(u8, checks.items[0].message, "rejected-config") == null);
}

test "doctor unresolved resolution returns exactly four path checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const state = try std.fs.path.join(allocator, &.{ root, "state" });
    const expected_state = try std.fs.path.join(allocator, &.{ state, "kotoba" });
    const resolution = try xdg.resolve(allocator, .{
        .home = null,
        .config = "rejected-config",
        .data = "",
        .cache = "rejected-cache",
        .state = state,
    });
    const output = try tmp.dir.createFile(sys.io(), "stdout", .{ .read = true });
    defer output.close(sys.io());
    var capture = try TestStdoutCapture.start(output);
    defer capture.restore();

    const exit_code = try runResolution(allocator, resolution, true);
    capture.restore();
    const rendered = try sys.readFileAlloc(allocator, try std.fs.path.join(allocator, &.{ root, "stdout" }), 8192);
    const report = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer report.deinit();
    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expect(!report.value.object.get("ok").?.bool);
    const checks = report.value.object.get("checks").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), checks.len);
    for (checks[0..3]) |check| {
        try std.testing.expectEqualStrings("error", check.object.get("status").?.string);
        try std.testing.expectEqualStrings("path_resolution_failed", check.object.get("code").?.string);
        try std.testing.expectEqualStrings("Could not resolve XDG paths from absolute XDG values or HOME.", check.object.get("message").?.string);
    }
    try std.testing.expectEqualStrings("ok", checks[3].object.get("status").?.string);
    try std.testing.expectEqualStrings(expected_state, checks[3].object.get("message").?.string);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "rejected-config") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"name\":\"config\"") == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "state", .{}));
}

test "doctor JSON keeps non-UTF-8 path diagnostics as strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const invalid_base = try std.mem.concat(allocator, u8, &.{ root, "/non-utf8-", &.{0xff} });
    const resolution = try xdg.resolve(allocator, .{
        .config = invalid_base,
        .data = invalid_base,
        .cache = invalid_base,
        .state = invalid_base,
    });
    const output = try tmp.dir.createFile(sys.io(), "json", .{ .read = true });
    defer output.close(sys.io());
    var capture = try TestStdoutCapture.start(output);
    const exit_code = try runResolution(allocator, resolution, true);
    capture.restore();
    const rendered = try sys.readFileAlloc(allocator, try std.fs.path.join(allocator, &.{ root, "json" }), 8192);
    const report = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer report.deinit();
    try std.testing.expectEqual(@as(u8, 1), exit_code);
    const checks = report.value.object.get("checks").?.array.items;
    try std.testing.expect(checks.len > 4);
    for (checks) |check| {
        const message = check.object.get("message").?;
        try std.testing.expect(message == .string);
    }
    for (checks[0..4]) |check| {
        const message = check.object.get("message").?;
        switch (message) {
            .string => |text| try std.testing.expect(std.mem.indexOf(u8, text, "\\xff") != null),
            else => unreachable,
        }
    }
}

test "doctor diagnostic text escapes Unicode C0 and C1 controls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const actual = try diagnosticText(arena.allocator(), "quote\" back\\slash 日本語\n\t\x01\u{009b}\u{009d}");
    try std.testing.expectEqualStrings("quote\" back\\slash 日本語\\n\\t\\u0001\\u009b\\u009d", actual);
}

test "doctor diagnostic text preserves valid UTF-8 around invalid bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const actual = try diagnosticText(arena.allocator(), "日本語\xff quote\" back\\slash");
    try std.testing.expectEqualStrings("日本語\\xff quote\" back\\slash", actual);
}

test "doctor JSON decodes special paths and human output stays one line per check" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const special = try std.mem.concat(allocator, u8, &.{ root, "/quote\" back\\slash\nline\ttab", &.{1} });
    const resolution = try xdg.resolve(allocator, .{
        .config = special,
        .data = special,
        .cache = special,
        .state = special,
    });
    const expected_diagnostic = try std.mem.concat(allocator, u8, &.{ root, "/quote\" back\\slash\\nline\\ttab\\u0001/kotoba" });

    const json_output = try tmp.dir.createFile(sys.io(), "json", .{ .read = true });
    defer json_output.close(sys.io());
    var json_capture = try TestStdoutCapture.start(json_output);
    const json_exit = try runResolution(allocator, resolution, true);
    json_capture.restore();
    const rendered_json = try sys.readFileAlloc(allocator, try std.fs.path.join(allocator, &.{ root, "json" }), 8192);
    const report = try std.json.parseFromSlice(std.json.Value, allocator, rendered_json, .{});
    defer report.deinit();
    try std.testing.expectEqual(@as(u8, 1), json_exit);
    const json_checks = report.value.object.get("checks").?.array.items;
    try std.testing.expect(json_checks.len > 4);
    for (json_checks[0..4]) |check| try std.testing.expectEqualStrings(expected_diagnostic, check.object.get("message").?.string);
    for (rendered_json[0 .. rendered_json.len - 1]) |byte| try std.testing.expect(byte >= 0x20);

    const human_output = try tmp.dir.createFile(sys.io(), "human", .{ .read = true });
    defer human_output.close(sys.io());
    var human_capture = try TestStdoutCapture.start(human_output);
    _ = try runResolution(allocator, resolution, false);
    human_capture.restore();
    const rendered_human = try sys.readFileAlloc(allocator, try std.fs.path.join(allocator, &.{ root, "human" }), 8192);
    try std.testing.expect(std.mem.indexOf(u8, rendered_human, "quote\" back\\slash\\nline\\ttab\\u0001/kotoba\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered_human, "back\\slash\nline") == null);
}
