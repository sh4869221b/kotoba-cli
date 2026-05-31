const std = @import("std");
const config = @import("../config.zig");
const errors = @import("../errors.zig");
const models = @import("../models.zig");
const sys = @import("../sys.zig");
const xdg = @import("../xdg.zig");
const args = @import("args.zig");

pub fn run(allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    if (cmd_args.len < 1) return errors.Error.InvalidArguments;
    try xdg.ensureDirs(paths);
    try models.ensure(paths.models_file);
    const cfg = config.load(allocator, paths.config_file) catch config.default();
    const sub = cmd_args[0];
    if (std.mem.eql(u8, sub, "list")) {
        if (cmd_args.len != 1) return errors.Error.InvalidArguments;
        const list = try models.load(allocator, paths.models_file);
        for (list.models) |m| {
            sys.stdoutPrint("{s}\t{s}\t{s}{s}{s}\n", .{ m.id, m.name, m.profile, if (m.recommended) "\trecommended" else "", if (std.mem.eql(u8, m.id, cfg.model_id)) "\tcurrent" else "" });
        }
        return 0;
    }
    if (std.mem.eql(u8, sub, "info")) return runInfo(allocator, paths, cmd_args[1..]);
    if (std.mem.eql(u8, sub, "import")) return runImport(allocator, paths, cmd_args[1..]);
    if (std.mem.eql(u8, sub, "pull")) return runPull(allocator, paths, cmd_args[1..]);
    if (std.mem.eql(u8, sub, "use")) return runUse(allocator, paths, cmd_args[1..]);
    if (std.mem.eql(u8, sub, "verify")) return runVerify(allocator, paths, cmd_args[1..]);
    if (std.mem.eql(u8, sub, "remove")) return runRemove(allocator, paths, cmd_args[1..]);
    return errors.Error.InvalidArguments;
}

fn runInfo(allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    if (cmd_args.len != 1) return errors.Error.InvalidArguments;
    const list = try models.load(allocator, paths.models_file);
    const m = models.find(list, cmd_args[0]) orelse return errors.Error.ModelRegistryInvalid;
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

fn runImport(allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    var cursor = args.ArgCursor.init(cmd_args);
    var id: []const u8 = "";
    var source_path: []const u8 = "";
    var name: []const u8 = "";
    var checksum: []const u8 = "";
    var use_model = false;
    while (cursor.peek()) |a| {
        if (std.mem.eql(u8, a, "--id")) {
            _ = cursor.nextValue();
            id = try cursor.requireValue();
        } else if (std.mem.eql(u8, a, "--path")) {
            _ = cursor.nextValue();
            source_path = try cursor.requireValue();
        } else if (std.mem.eql(u8, a, "--name")) {
            _ = cursor.nextValue();
            name = try cursor.requireValue();
        } else if (std.mem.eql(u8, a, "--checksum")) {
            _ = cursor.nextValue();
            checksum = try cursor.requireValue();
        } else if (std.mem.eql(u8, a, "--use")) {
            _ = cursor.nextValue();
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

fn runPull(allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    var cursor = args.ArgCursor.init(cmd_args);
    var id: []const u8 = "";
    var output_path: []const u8 = "";
    var hf_repo: []const u8 = "";
    var hf_file: []const u8 = "";
    var model_url: []const u8 = "";
    var checksum: []const u8 = "";
    var use_model = false;
    var positional_id: []const u8 = "";
    while (cursor.peek()) |a| {
        if (std.mem.eql(u8, a, "--id")) {
            _ = cursor.nextValue();
            id = try cursor.requireValue();
        } else if (std.mem.eql(u8, a, "--output")) {
            _ = cursor.nextValue();
            output_path = try cursor.requireValue();
        } else if (std.mem.eql(u8, a, "--hf-repo")) {
            _ = cursor.nextValue();
            hf_repo = try cursor.requireValue();
        } else if (std.mem.eql(u8, a, "--hf-file")) {
            _ = cursor.nextValue();
            hf_file = try cursor.requireValue();
        } else if (std.mem.eql(u8, a, "--model-url")) {
            _ = cursor.nextValue();
            model_url = try cursor.requireValue();
        } else if (std.mem.eql(u8, a, "--checksum")) {
            _ = cursor.nextValue();
            checksum = try cursor.requireValue();
        } else if (std.mem.eql(u8, a, "--use")) {
            _ = cursor.nextValue();
            use_model = true;
        } else if (positional_id.len == 0 and a.len > 0 and a[0] != '-') {
            positional_id = a;
            _ = cursor.nextValue();
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

fn runUse(allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    if (cmd_args.len != 1) return errors.Error.InvalidArguments;
    const list = try models.load(allocator, paths.models_file);
    const m = models.find(list, cmd_args[0]) orelse return errors.Error.ModelRegistryInvalid;
    try models.verifyModel(allocator, m);
    try selectModel(allocator, paths, m.id, m.path);
    sys.stdoutPrint("using {s}\n", .{m.id});
    return 0;
}

fn runVerify(allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    if (cmd_args.len > 1) return errors.Error.InvalidArguments;
    const cfg = config.load(allocator, paths.config_file) catch config.default();
    const id = if (cmd_args.len == 1) cmd_args[0] else cfg.model_id;
    if (id.len == 0) return errors.Error.ModelNotSelected;
    const list = try models.load(allocator, paths.models_file);
    var m = models.find(list, id) orelse return errors.Error.ModelRegistryInvalid;
    if (cmd_args.len == 0) {
        if (cfg.model_path.len == 0) return errors.Error.ModelNotSelected;
        m.path = cfg.model_path;
    }
    try models.verifyModel(allocator, m);
    sys.stdoutPrint("verified {s}\n", .{id});
    return 0;
}

fn runRemove(allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    if (cmd_args.len != 2 or !std.mem.eql(u8, cmd_args[1], "--yes")) return errors.Error.InvalidArguments;
    const id = cmd_args[0];
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

pub fn selectModel(allocator: std.mem.Allocator, paths: xdg.Paths, id: []const u8, model_path: []const u8) !void {
    var cfg = config.load(allocator, paths.config_file) catch config.default();
    cfg.model_id = try allocator.dupe(u8, id);
    cfg.model_path = try allocator.dupe(u8, model_path);
    try config.save(paths.config_file, cfg);
}
