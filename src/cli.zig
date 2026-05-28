const std = @import("std");
const config = @import("config.zig");
const doctor = @import("doctor.zig");
const errors = @import("errors.zig");
const glossary = @import("glossary.zig");
const lang = @import("lang.zig");
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
    var model_id: []const u8 = "";
    var model_path: []const u8 = "";
    var explicit_model_path = false;
    var yes = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--model-id")) {
            i += 1;
            if (i >= args.len) return errors.Error.InvalidArguments;
            model_id = args[i];
        } else if (std.mem.eql(u8, args[i], "--model-path")) {
            i += 1;
            if (i >= args.len) return errors.Error.InvalidArguments;
            model_path = args[i];
            explicit_model_path = true;
        } else if (std.mem.eql(u8, args[i], "--yes")) yes = true else return errors.Error.InvalidArguments;
    }
    try xdg.ensureDirs(paths);
    try models.ensure(paths.models_file);
    try glossary.ensure(paths.glossary_file);
    const list = try models.load(allocator, paths.models_file);
    if (!yes and model_id.len == 0 and model_path.len == 0) {
        printInitChoices(list);
        sys.stderrPrint("kotoba: init requires --model-id ID or --model-path PATH, or rerun with --yes to configure later.\n", .{});
        return errors.Error.InvalidArguments;
    }
    if (model_path.len > 0 and model_id.len == 0) model_id = "custom";
    var selected_registry_model: ?models.Model = null;
    if (model_path.len == 0 and model_id.len > 0) {
        if (models.find(list, model_id)) |m| {
            selected_registry_model = m;
            if (m.path.len > 0) {
                model_path = m.path;
            } else if (m.download_url.len > 0) {
                model_path = try models.installedPath(allocator, paths.models_dir, model_id);
                var pulled = m;
                pulled.path = model_path;
                try models.validateGgufPath(model_path);
                try models.acquire(allocator, pulled, model_path, false);
                try models.verifyModel(allocator, pulled);
                try models.upsert(allocator, paths.models_file, pulled);
            } else return errors.Error.ModelMissing;
        } else return errors.Error.InvalidArguments;
    }
    if (explicit_model_path) {
        try models.validateId(model_id);
        try models.validateGgufPath(model_path);
        var registry_model = selected_registry_model orelse models.find(list, model_id) orelse models.Model{
            .id = model_id,
            .name = model_id,
            .profile = "local",
            .languages_en = true,
            .languages_ja = true,
            .format = "gguf",
            .notes = "Configured during init.",
        };
        registry_model.path = model_path;
        if (registry_model.checksum.len > 0) try models.verifySha256(allocator, model_path, registry_model.checksum);
        try models.upsert(allocator, paths.models_file, registry_model);
    }
    var cfg = config.load(allocator, paths.config_file) catch config.default();
    cfg.model_id = model_id;
    cfg.model_path = model_path;
    try config.save(paths.config_file, cfg);
    var db = try memory.open(allocator, paths.memory_file);
    db.close();
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
    sys.stdoutPrint("- later: use --yes to configure model_path later\n", .{});
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
        } else if (std.mem.eql(u8, a, "--overwrite")) opts.overwrite = true else if (std.mem.eql(u8, a, "--no-memory")) opts.no_memory = true else if (std.mem.eql(u8, a, "--no-glossary")) opts.no_glossary = true else if (std.mem.eql(u8, a, "--debug")) opts.debug = true else {
            if (opts.text != null) return errors.Error.InvalidArguments;
            opts.text = a;
        }
    }
    const cfg = try config.load(allocator, paths.config_file);
    if (translate.diagnosticsEnabled(cfg, opts)) {
        sys.stderrPrint("kotoba: debug: diagnostics enabled\n", .{});
    }
    const kind = translate.readKindForOptions(opts.format, opts.file_path);
    const res = try translate.run(allocator, paths, cfg, opts);
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
    if (std.mem.eql(u8, args[0], "list")) {
        if (args.len != 1) return errors.Error.InvalidArguments;
        for (config.settable_keys) |key| sys.stdoutPrint("{s}\n", .{key});
        return 0;
    }
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
    if (std.mem.eql(u8, key, "model_id")) sys.stdoutPrint("{s}\n", .{cfg.model_id}) else if (std.mem.eql(u8, key, "model_path")) sys.stdoutPrint("{s}\n", .{cfg.model_path}) else if (std.mem.eql(u8, key, "context_length")) sys.stdoutPrint("{d}\n", .{cfg.context_length}) else if (std.mem.eql(u8, key, "threads")) sys.stdoutPrint("{d}\n", .{cfg.threads}) else if (std.mem.eql(u8, key, "max_tokens")) sys.stdoutPrint("{d}\n", .{cfg.max_tokens}) else if (std.mem.eql(u8, key, "temperature")) sys.stdoutPrint("{d}\n", .{cfg.temperature}) else if (std.mem.eql(u8, key, "timeout_sec")) sys.stdoutPrint("{d}\n", .{cfg.timeout_sec}) else if (std.mem.eql(u8, key, "default_target_lang")) sys.stdoutPrint("{s}\n", .{cfg.default_target_lang.asText()}) else if (std.mem.eql(u8, key, "default_source_lang")) sys.stdoutPrint("{s}\n", .{if (cfg.default_source_lang) |l| l.asText() else ""}) else if (std.mem.eql(u8, key, "default_mode")) sys.stdoutPrint("{s}\n", .{cfg.default_mode.asText()}) else if (std.mem.eql(u8, key, "default_output")) sys.stdoutPrint("{s}\n", .{cfg.default_output.asText()}) else if (std.mem.eql(u8, key, "memory_enabled")) sys.stdoutPrint("{}\n", .{cfg.memory_enabled}) else if (std.mem.eql(u8, key, "glossary_enabled")) sys.stdoutPrint("{}\n", .{cfg.glossary_enabled}) else if (std.mem.eql(u8, key, "privacy_mode")) sys.stdoutPrint("{}\n", .{cfg.privacy_mode}) else if (std.mem.eql(u8, key, "log_level")) sys.stdoutPrint("{s}\n", .{cfg.log_level}) else return errors.Error.InvalidArguments;
}

fn runModels(allocator: std.mem.Allocator, paths: xdg.Paths, args: []const []const u8) !u8 {
    if (args.len < 1) return errors.Error.InvalidArguments;
    try xdg.ensureDirs(paths);
    try models.ensure(paths.models_file);
    const cfg = config.load(allocator, paths.config_file) catch config.default();
    const sub = args[0];
    if (std.mem.eql(u8, sub, "list")) {
        if (args.len != 1) return errors.Error.InvalidArguments;
        const list = try models.load(allocator, paths.models_file);
        for (list.models) |m| {
            sys.stdoutPrint("{s}\t{s}\t{s}{s}{s}\n", .{ m.id, m.name, m.profile, if (m.recommended) "\trecommended" else "", if (std.mem.eql(u8, m.id, cfg.model_id)) "\tcurrent" else "" });
        }
        return 0;
    }
    if (std.mem.eql(u8, sub, "info")) return runModelsInfo(allocator, paths, args[1..]);
    if (std.mem.eql(u8, sub, "import")) return runModelsImport(allocator, paths, args[1..]);
    if (std.mem.eql(u8, sub, "pull")) return runModelsPull(allocator, paths, args[1..]);
    if (std.mem.eql(u8, sub, "use")) return runModelsUse(allocator, paths, args[1..]);
    if (std.mem.eql(u8, sub, "verify")) return runModelsVerify(allocator, paths, args[1..]);
    if (std.mem.eql(u8, sub, "remove")) return runModelsRemove(allocator, paths, args[1..]);
    return errors.Error.InvalidArguments;
}

fn runModelsInfo(allocator: std.mem.Allocator, paths: xdg.Paths, args: []const []const u8) !u8 {
    if (args.len != 1) return errors.Error.InvalidArguments;
    const list = try models.load(allocator, paths.models_file);
    const m = models.find(list, args[0]) orelse return errors.Error.ModelRegistryInvalid;
    printModelInfo(m);
    return 0;
}

fn printModelInfo(m: models.Model) void {
    sys.stdoutPrint("id: {s}\nname: {s}\nprofile: {s}\nformat: {s}\nquantization: {s}\ncontext_length: {d}\npath: {s}\ndownload_url: {s}\nchecksum: {s}\nlicense: {s}\nrecommended: {}\nnotes: {s}\n", .{
        m.id,
        m.name,
        m.profile,
        m.format,
        m.quantization,
        m.context_length,
        m.path,
        m.download_url,
        m.checksum,
        m.license,
        m.recommended,
        m.notes,
    });
}

fn runModelsImport(allocator: std.mem.Allocator, paths: xdg.Paths, args: []const []const u8) !u8 {
    var id: []const u8 = "";
    var source_path: []const u8 = "";
    var name: []const u8 = "";
    var checksum: []const u8 = "";
    var use_model = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--id")) {
            i += 1;
            if (i >= args.len) return errors.Error.InvalidArguments;
            id = args[i];
        } else if (std.mem.eql(u8, args[i], "--path")) {
            i += 1;
            if (i >= args.len) return errors.Error.InvalidArguments;
            source_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--name")) {
            i += 1;
            if (i >= args.len) return errors.Error.InvalidArguments;
            name = args[i];
        } else if (std.mem.eql(u8, args[i], "--checksum")) {
            i += 1;
            if (i >= args.len) return errors.Error.InvalidArguments;
            checksum = args[i];
        } else if (std.mem.eql(u8, args[i], "--use")) {
            use_model = true;
        } else return errors.Error.InvalidArguments;
    }
    try models.validateId(id);
    try models.validateGgufPath(source_path);
    if (!sys.exists(source_path)) return errors.Error.ModelMissing;
    const dest_path = try models.installedPath(allocator, paths.models_dir, id);
    if (std.mem.eql(u8, source_path, dest_path)) {
        if (checksum.len > 0) try models.verifySha256(allocator, dest_path, checksum);
    } else {
        try models.installLocalFile(allocator, source_path, dest_path, checksum);
    }
    const display_name = if (name.len > 0) name else id;
    try models.upsert(allocator, paths.models_file, .{
        .id = id,
        .name = display_name,
        .profile = "local",
        .languages_en = true,
        .languages_ja = true,
        .format = "gguf",
        .path = dest_path,
        .checksum = checksum,
        .notes = "Imported local GGUF model.",
    });
    if (use_model) try selectModel(allocator, paths, id, dest_path);
    sys.stdoutPrint("imported {s}\n", .{id});
    return 0;
}

fn runModelsPull(allocator: std.mem.Allocator, paths: xdg.Paths, args: []const []const u8) !u8 {
    var id: []const u8 = "";
    var output_path: []const u8 = "";
    var hf_repo: []const u8 = "";
    var hf_file: []const u8 = "";
    var model_url: []const u8 = "";
    var checksum: []const u8 = "";
    var use_model = false;
    var positional_id: []const u8 = "";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--id")) {
            i += 1;
            if (i >= args.len) return errors.Error.InvalidArguments;
            id = args[i];
        } else if (std.mem.eql(u8, args[i], "--output")) {
            i += 1;
            if (i >= args.len) return errors.Error.InvalidArguments;
            output_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--hf-repo")) {
            i += 1;
            if (i >= args.len) return errors.Error.InvalidArguments;
            hf_repo = args[i];
        } else if (std.mem.eql(u8, args[i], "--hf-file")) {
            i += 1;
            if (i >= args.len) return errors.Error.InvalidArguments;
            hf_file = args[i];
        } else if (std.mem.eql(u8, args[i], "--model-url")) {
            i += 1;
            if (i >= args.len) return errors.Error.InvalidArguments;
            model_url = args[i];
        } else if (std.mem.eql(u8, args[i], "--checksum")) {
            i += 1;
            if (i >= args.len) return errors.Error.InvalidArguments;
            checksum = args[i];
        } else if (std.mem.eql(u8, args[i], "--use")) {
            use_model = true;
        } else if (positional_id.len == 0 and args[i].len > 0 and args[i][0] != '-') {
            positional_id = args[i];
        } else return errors.Error.InvalidArguments;
    }
    var m: models.Model = .{};
    if (hf_repo.len > 0) {
        if (model_url.len > 0 or positional_id.len > 0) return errors.Error.InvalidArguments;
        const hf = try models.parseHfRepo(hf_repo);
        if (id.len == 0) id = try models.defaultIdFromHf(allocator, hf);
        try models.validateId(id);
        const file = try models.resolveHfFile(allocator, hf, hf_file);
        const url = try models.hfDownloadUrl(allocator, hf.repo, file);
        if (output_path.len == 0) output_path = try models.installedPath(allocator, paths.models_dir, id);
        m = .{ .id = id, .name = id, .profile = "huggingface", .languages_en = true, .languages_ja = true, .format = "gguf", .quantization = hf.quant, .path = output_path, .download_url = url, .checksum = checksum, .notes = "Downloaded from Hugging Face." };
    } else if (model_url.len > 0) {
        if (positional_id.len > 0 or id.len == 0) return errors.Error.InvalidArguments;
        if (!std.mem.startsWith(u8, model_url, "https://")) return errors.Error.InvalidArguments;
        if (checksum.len == 0) return errors.Error.InvalidArguments;
        try models.validateId(id);
        if (output_path.len == 0) output_path = try models.installedPath(allocator, paths.models_dir, id);
        m = .{ .id = id, .name = id, .profile = "url", .languages_en = true, .languages_ja = true, .format = "gguf", .path = output_path, .download_url = model_url, .checksum = checksum, .notes = "Downloaded from direct HTTPS URL." };
    } else {
        if (positional_id.len == 0 or id.len > 0) return errors.Error.InvalidArguments;
        const list = try models.load(allocator, paths.models_file);
        m = models.find(list, positional_id) orelse return errors.Error.ModelRegistryInvalid;
        id = m.id;
        if (output_path.len == 0) output_path = if (m.path.len > 0) m.path else try models.installedPath(allocator, paths.models_dir, id);
        m.path = output_path;
        if (checksum.len > 0) m.checksum = checksum;
    }
    try models.validateGgufPath(output_path);
    try models.acquire(allocator, m, output_path, false);
    m.path = output_path;
    try models.verifyModel(allocator, m);
    try models.upsert(allocator, paths.models_file, m);
    if (use_model) try selectModel(allocator, paths, id, output_path);
    sys.stdoutPrint("pulled {s}\n", .{id});
    return 0;
}

fn runModelsUse(allocator: std.mem.Allocator, paths: xdg.Paths, args: []const []const u8) !u8 {
    if (args.len != 1) return errors.Error.InvalidArguments;
    const list = try models.load(allocator, paths.models_file);
    const m = models.find(list, args[0]) orelse return errors.Error.ModelRegistryInvalid;
    try models.verifyModel(allocator, m);
    try selectModel(allocator, paths, m.id, m.path);
    sys.stdoutPrint("using {s}\n", .{m.id});
    return 0;
}

fn runModelsVerify(allocator: std.mem.Allocator, paths: xdg.Paths, args: []const []const u8) !u8 {
    if (args.len > 1) return errors.Error.InvalidArguments;
    const cfg = config.load(allocator, paths.config_file) catch config.default();
    const id = if (args.len == 1) args[0] else cfg.model_id;
    if (id.len == 0) return errors.Error.ModelNotSelected;
    const list = try models.load(allocator, paths.models_file);
    var m = models.find(list, id) orelse return errors.Error.ModelRegistryInvalid;
    if (args.len == 0) {
        if (cfg.model_path.len == 0) return errors.Error.ModelNotSelected;
        m.path = cfg.model_path;
    }
    try models.verifyModel(allocator, m);
    sys.stdoutPrint("verified {s}\n", .{id});
    return 0;
}

fn runModelsRemove(allocator: std.mem.Allocator, paths: xdg.Paths, args: []const []const u8) !u8 {
    if (args.len != 2 or !std.mem.eql(u8, args[1], "--yes")) return errors.Error.InvalidArguments;
    const id = args[0];
    const removed = try models.removeById(allocator, paths.models_file, id);
    if (models.load(allocator, paths.models_file)) |remaining| {
        if (canDeleteManagedModelPath(allocator, paths.models_dir, removed.path, remaining)) sys.deleteFile(removed.path);
    } else |_| {}
    var cfg = config.load(allocator, paths.config_file) catch config.default();
    if (std.mem.eql(u8, cfg.model_id, id)) {
        cfg.model_id = "";
        cfg.model_path = "";
        try config.save(paths.config_file, cfg);
    }
    sys.stdoutPrint("removed {s}\n", .{id});
    return 0;
}

fn canDeleteManagedModelPath(allocator: std.mem.Allocator, models_dir: []const u8, path: []const u8, remaining: models.List) bool {
    const real_models_dir = sys.realPathAlloc(allocator, models_dir) catch return false;
    defer allocator.free(real_models_dir);
    const real_path = sys.realPathAlloc(allocator, path) catch return false;
    defer allocator.free(real_path);
    if (real_path.len <= real_models_dir.len) return false;
    if (!std.mem.startsWith(u8, real_path, real_models_dir)) return false;
    if (real_path[real_models_dir.len] != std.fs.path.sep) return false;
    for (remaining.models) |m| {
        if (m.path.len == 0) continue;
        const other_real_path = sys.realPathAlloc(allocator, m.path) catch continue;
        defer allocator.free(other_real_path);
        if (std.mem.eql(u8, real_path, other_real_path)) return false;
    }
    return true;
}

fn selectModel(allocator: std.mem.Allocator, paths: xdg.Paths, id: []const u8, model_path: []const u8) !void {
    var cfg = config.load(allocator, paths.config_file) catch config.default();
    cfg.model_id = try allocator.dupe(u8, id);
    cfg.model_path = try allocator.dupe(u8, model_path);
    try config.save(paths.config_file, cfg);
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
