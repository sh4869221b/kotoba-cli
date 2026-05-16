const std = @import("std");
const config = @import("config.zig");
const doctor = @import("doctor.zig");
const errors = @import("errors.zig");
const glossary = @import("glossary.zig");
const input = @import("input.zig");
const lang = @import("lang.zig");
const llama = @import("llama.zig");
const memory = @import("memory.zig");
const models = @import("models.zig");
const output = @import("output.zig");
const sys = @import("sys.zig");
const translate = @import("translate.zig");
const xdg = @import("xdg.zig");

const version = "0.0.1";

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len < 2) return errors.Error.InvalidArguments;
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "version")) {
        sys.stdoutPrint("kotoba {s}\n", .{version});
        return 0;
    }
    const paths = try xdg.paths(allocator);
    if (std.mem.eql(u8, cmd, "init")) return runInit(allocator, paths, args[2..]);
    if (std.mem.eql(u8, cmd, "translate")) return runTranslate(allocator, paths, args[2..]);
    if (std.mem.eql(u8, cmd, "doctor")) return runDoctor(allocator, paths, args[2..]);
    if (std.mem.eql(u8, cmd, "config")) return runConfig(allocator, paths, args[2..]);
    if (std.mem.eql(u8, cmd, "models")) return runModels(allocator, paths, args[2..]);
    if (std.mem.eql(u8, cmd, "memory")) return runMemory(allocator, paths, args[2..]);
    if (std.mem.eql(u8, cmd, "glossary")) return runGlossary(allocator, paths, args[2..]);
    return errors.Error.InvalidArguments;
}

pub fn errorPrefersJson(args: []const []const u8) bool {
    if (args.len >= 2 and std.mem.eql(u8, args[1], "doctor")) {
        return hasOptionValue(args[2..], "--format", "json");
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "translate")) {
        return hasOptionValue(args[2..], "--format", "json");
    }
    return false;
}

fn hasOptionValue(args: []const []const u8, option: []const u8, value: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], option) and std.mem.eql(u8, args[i + 1], value)) return true;
    }
    return false;
}

fn runInit(allocator: std.mem.Allocator, paths: xdg.Paths, args: []const []const u8) !u8 {
    var server_url: []const u8 = "http://127.0.0.1:8080";
    var model_id: []const u8 = "custom";
    var model_path: []const u8 = "";
    var skip_download = false;
    var yes = false;
    var allow_remote = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--server-url")) {
            i += 1;
            if (i >= args.len) return errors.Error.InvalidArguments;
            server_url = args[i];
        } else if (std.mem.eql(u8, args[i], "--model-id")) {
            i += 1;
            if (i >= args.len) return errors.Error.InvalidArguments;
            model_id = args[i];
        } else if (std.mem.eql(u8, args[i], "--model-path")) {
            i += 1;
            if (i >= args.len) return errors.Error.InvalidArguments;
            model_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--skip-download")) skip_download = true else if (std.mem.eql(u8, args[i], "--yes")) yes = true else if (std.mem.eql(u8, args[i], "--allow-remote-server")) allow_remote = true else return errors.Error.InvalidArguments;
    }
    if (yes and std.mem.eql(u8, model_id, "custom") and model_path.len == 0 and !skip_download) return errors.Error.InvalidArguments;
    try xdg.ensureDirs(paths);
    try models.ensure(paths.models_file);
    try glossary.ensure(paths.glossary_file);
    const list = try models.load(allocator, paths.models_file);
    if (!yes and std.mem.eql(u8, model_id, "custom") and model_path.len == 0) {
        printInitChoices(list);
        sys.stderrPrint("kotoba: init requires --model-path PATH with --model-id custom, or rerun with --yes --skip-download to configure later.\n", .{});
        return errors.Error.InvalidArguments;
    }
    if (models.find(list, model_id)) |m| {
        try models.acquire(allocator, m, model_path, skip_download);
    }
    var cfg = config.default();
    cfg.server_url = server_url;
    cfg.model_id = model_id;
    cfg.model_path = model_path;
    try config.save(paths.config_file, cfg);
    var db = try memory.open(allocator, paths.memory_file);
    db.close();
    llama.validateLocalServerUrl(server_url, allow_remote) catch |err| return err;
    _ = llama.healthCheck(allocator, server_url, cfg.timeout_sec, allow_remote) catch {
        sys.stderrPrint("warning: server is not reachable at {s}. Start llama-server and run `kotoba doctor`.\n", .{server_url});
        return 0;
    };
    const test_out = llama.translateSegment(allocator, .{
        .server_url = server_url,
        .model_id = model_id,
        .prompt = "Translate from en to ja. Return only the translation.\nText:\nHello",
        .timeout_sec = cfg.timeout_sec,
        .allow_remote_server = allow_remote,
    }) catch {
        sys.stderrPrint("warning: server health check passed, but test translation failed. Run `kotoba doctor`.\n", .{});
        return 0;
    };
    allocator.free(test_out);
    sys.stdoutPrint("initialized\n", .{});
    return 0;
}

fn printInitChoices(list: models.List) void {
    sys.stdoutPrint("Model choices:\n", .{});
    for (list.models) |m| {
        if (m.recommended and m.download_url.len > 0 and m.checksum.len > 0) {
            sys.stdoutPrint("- {s}: {s} (downloadable recommended)\n", .{ m.id, m.name });
        }
    }
    sys.stdoutPrint("- custom: provide --model-path PATH\n", .{});
    sys.stdoutPrint("- later: use --yes --skip-download to configure model_path later\n", .{});
}

fn runTranslate(allocator: std.mem.Allocator, paths: xdg.Paths, args: []const []const u8) !u8 {
    var opts = translate.Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--from")) {
            i += 1;
            if (i >= args.len) return errors.Error.InvalidArguments;
            opts.source_lang = try lang.Language.parse(args[i]);
        } else if (std.mem.eql(u8, a, "--to")) {
            i += 1;
            if (i >= args.len) return errors.Error.InvalidArguments;
            opts.target_lang = try lang.Language.parse(args[i]);
        } else if (std.mem.eql(u8, a, "--mode")) {
            i += 1;
            if (i >= args.len) return errors.Error.InvalidArguments;
            opts.mode = try config.Mode.parse(args[i]);
        } else if (std.mem.eql(u8, a, "--format")) {
            i += 1;
            if (i >= args.len) return errors.Error.InvalidArguments;
            opts.format = try config.OutputFormat.parse(args[i]);
        } else if (std.mem.eql(u8, a, "--include-source")) opts.include_source = true else if (std.mem.eql(u8, a, "--file")) {
            i += 1;
            if (i >= args.len) return errors.Error.InvalidArguments;
            opts.file_path = args[i];
        } else if (std.mem.eql(u8, a, "--output")) {
            i += 1;
            if (i >= args.len) return errors.Error.InvalidArguments;
            opts.output_path = args[i];
        } else if (std.mem.eql(u8, a, "--overwrite")) opts.overwrite = true else if (std.mem.eql(u8, a, "--no-memory")) opts.no_memory = true else if (std.mem.eql(u8, a, "--no-glossary")) opts.no_glossary = true else if (std.mem.eql(u8, a, "--allow-remote-server")) opts.allow_remote_server = true else {
            if (opts.text != null) return errors.Error.InvalidArguments;
            opts.text = a;
        }
    }
    const cfg = try config.load(allocator, paths.config_file);
    const kind = if (opts.file_path) |p| if (input.isMarkdown(p)) input.Kind.markdown else input.Kind.text else input.Kind.text;
    const res = try translate.run(allocator, cfg, paths.memory_file, paths.glossary_file, opts);
    if (try translate.writeFileIfNeeded(allocator, res, kind, opts.file_path, opts.output_path, opts.overwrite)) return 0;
    const fmt = opts.format orelse if (kind == .markdown) config.OutputFormat.markdown else cfg.default_output;
    try output.write(fmt, res, opts.include_source);
    return 0;
}

fn runDoctor(allocator: std.mem.Allocator, paths: xdg.Paths, args: []const []const u8) !u8 {
    var json = false;
    if (args.len == 2 and std.mem.eql(u8, args[0], "--format") and std.mem.eql(u8, args[1], "json")) json = true else if (args.len != 0) return errors.Error.InvalidArguments;
    return doctor.run(allocator, paths, json);
}

fn runConfig(allocator: std.mem.Allocator, paths: xdg.Paths, args: []const []const u8) !u8 {
    if (args.len < 1) return errors.Error.InvalidArguments;
    var cfg = try config.load(allocator, paths.config_file);
    if (std.mem.eql(u8, args[0], "get")) {
        if (args.len != 2) return errors.Error.InvalidArguments;
        try printConfigValue(cfg, args[1]);
        return 0;
    }
    if (std.mem.eql(u8, args[0], "set")) {
        if (args.len != 3) return errors.Error.InvalidArguments;
        try config.setValue(allocator, &cfg, args[1], args[2]);
        try config.save(paths.config_file, cfg);
        return 0;
    }
    return errors.Error.InvalidArguments;
}

fn printConfigValue(cfg: config.Config, key: []const u8) !void {
    if (std.mem.eql(u8, key, "server_url")) sys.stdoutPrint("{s}\n", .{cfg.server_url}) else if (std.mem.eql(u8, key, "model_id")) sys.stdoutPrint("{s}\n", .{cfg.model_id}) else if (std.mem.eql(u8, key, "model_path")) sys.stdoutPrint("{s}\n", .{cfg.model_path}) else if (std.mem.eql(u8, key, "default_target_lang")) sys.stdoutPrint("{s}\n", .{cfg.default_target_lang.asText()}) else if (std.mem.eql(u8, key, "default_source_lang")) sys.stdoutPrint("{s}\n", .{if (cfg.default_source_lang) |l| l.asText() else ""}) else if (std.mem.eql(u8, key, "memory_enabled")) sys.stdoutPrint("{}\n", .{cfg.memory_enabled}) else if (std.mem.eql(u8, key, "glossary_enabled")) sys.stdoutPrint("{}\n", .{cfg.glossary_enabled}) else if (std.mem.eql(u8, key, "privacy_mode")) sys.stdoutPrint("{}\n", .{cfg.privacy_mode}) else return errors.Error.InvalidArguments;
}

fn runModels(allocator: std.mem.Allocator, paths: xdg.Paths, args: []const []const u8) !u8 {
    if (args.len != 1 or !std.mem.eql(u8, args[0], "list")) return errors.Error.InvalidArguments;
    const cfg = config.load(allocator, paths.config_file) catch config.default();
    const list = try models.load(allocator, paths.models_file);
    for (list.models) |m| {
        sys.stdoutPrint("{s}\t{s}\t{s}{s}{s}\n", .{ m.id, m.name, m.profile, if (m.recommended) "\trecommended" else "", if (std.mem.eql(u8, m.id, cfg.model_id)) "\tcurrent" else "" });
    }
    return 0;
}

fn runMemory(allocator: std.mem.Allocator, paths: xdg.Paths, args: []const []const u8) !u8 {
    if (args.len < 1) return errors.Error.InvalidArguments;
    var db = try memory.open(allocator, paths.memory_file);
    defer db.close();
    if (std.mem.eql(u8, args[0], "status")) {
        sys.stdoutPrint("path: {s}\nrows: {d}\n", .{ paths.memory_file, try db.count() });
        return 0;
    }
    if (std.mem.eql(u8, args[0], "clear")) {
        if (args.len != 2 or !std.mem.eql(u8, args[1], "--yes")) return errors.Error.InvalidArguments;
        try db.clear();
        return 0;
    }
    return errors.Error.InvalidArguments;
}

fn runGlossary(allocator: std.mem.Allocator, paths: xdg.Paths, args: []const []const u8) !u8 {
    if (args.len != 1 or !std.mem.eql(u8, args[0], "validate")) return errors.Error.InvalidArguments;
    const g = try glossary.load(allocator, paths.glossary_file);
    sys.stdoutPrint("terms: {d}\nhash: {x}\n", .{ g.terms.len, glossary.hash(g) });
    return 0;
}

test "version command" {
    const args = [_][]const u8{ "kotoba", "version" };
    _ = try run(std.testing.allocator, &args);
}

test "json error preference" {
    const args = [_][]const u8{ "kotoba", "translate", "Hello", "--format", "json" };
    try std.testing.expect(errorPrefersJson(&args));
}
