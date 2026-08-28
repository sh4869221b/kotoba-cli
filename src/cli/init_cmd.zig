const std = @import("std");
const config = @import("../config.zig");
const errors = @import("../errors.zig");
const glossary = @import("../glossary.zig");
const memory = @import("../memory.zig");
const models = @import("../models.zig");
const sys = @import("../sys.zig");
const xdg = @import("../xdg.zig");
const args = @import("args.zig");
const models_cmd = @import("models_cmd.zig");

pub fn run(allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    var cursor = args.ArgCursor.init(cmd_args);
    var model_id: []const u8 = "";
    var model_path: []const u8 = "";
    var explicit_model_path = false;
    var yes = false;
    while (cursor.peek()) |a| {
        if (std.mem.eql(u8, a, "--model-id")) {
            _ = cursor.nextValue();
            model_id = try cursor.requireValue();
        } else if (std.mem.eql(u8, a, "--model-path")) {
            _ = cursor.nextValue();
            model_path = try cursor.requireValue();
            explicit_model_path = true;
        } else if (std.mem.eql(u8, a, "--yes")) {
            _ = cursor.nextValue();
            yes = true;
        } else return errors.Error.InvalidArguments;
    }
    if (model_path.len > 0 and model_id.len == 0) model_id = "custom";
    if (model_id.len > 0) try models.validateId(model_id);
    if (explicit_model_path) try models.validateGgufPath(model_path);
    const list = try models.loadReadOnly(allocator, paths.models_file);
    if (!yes and model_id.len == 0 and model_path.len == 0) {
        printInitChoices(list);
        sys.stderrPrint("kotoba: init requires --model-id ID or --model-path PATH, or rerun with --yes to configure later.\n", .{});
        return errors.Error.InvalidArguments;
    }
    var selected_registry_model: ?models.Model = null;
    if (model_path.len == 0 and model_id.len > 0) {
        if (models.find(list, model_id)) |m| {
            selected_registry_model = m;
            if (m.path.len > 0 and sys.exists(m.path)) {
                model_path = m.path;
            } else {
                sys.stderrPrint("kotoba: init does not download models. Run `kotoba models pull ID --use` first, replacing ID with the model ID, or provide --model-path PATH.\n", .{});
                return errors.Error.ModelMissing;
            }
        } else return errors.Error.InvalidArguments;
    }
    if (explicit_model_path) {
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
        selected_registry_model = registry_model;
    }
    var cfg = config.load(allocator, paths.config_file) catch config.default();
    cfg.model_id = model_id;
    cfg.model_path = model_path;
    try xdg.ensureDirs(paths);
    try models.ensure(paths.models_file);
    try glossary.ensure(paths.glossary_file);
    if (selected_registry_model) |registry_model| {
        if (explicit_model_path) try models.upsert(allocator, paths.models_file, registry_model);
    }
    try config.save(paths.config_file, cfg);
    var db = try memory.open(allocator, paths.memory_file);
    db.close();
    sys.stdoutPrint("initialized\n", .{});
    return 0;
}

test "init validates selections before creating XDG state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    var paths: xdg.Paths = undefined;
    paths.config_dir = try std.fs.path.join(allocator, &.{ root, "kotoba" });
    paths.models_file = try std.fs.path.join(allocator, &.{ paths.config_dir, "models.toml" });

    try std.testing.expectError(errors.Error.InvalidArguments, run(allocator, paths, &.{ "--model-id", "../bad", "--model-path", "fixture.gguf" }));
    paths.models_file = root;
    try std.testing.expectError(errors.Error.InvalidArguments, run(allocator, paths, &.{ "--model-path", "invalid.txt" }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "kotoba", .{}));
}

fn printInitChoices(list: models.List) void {
    sys.stdoutPrint("Model choices:\n", .{});
    for (list.models) |m| {
        if (m.recommended and m.download_url.len > 0 and m.checksum.len > 0) {
            sys.stdoutPrint("- {s}: {s} (requires `models pull` first)\n", .{ m.id, m.name });
        }
    }
    sys.stdoutPrint("- custom: provide --model-path PATH\n", .{});
    sys.stdoutPrint("- later: use --yes to configure model_path later\n", .{});
}
