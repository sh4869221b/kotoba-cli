const std = @import("std");
const config = @import("../config.zig");
const fs = @import("../fs.zig");
const errors = @import("../errors.zig");
const models = @import("../models.zig");
const sys = @import("../sys.zig");
const xdg = @import("../xdg.zig");
const args = @import("args.zig");

pub fn run(original_allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    var invocation_arena = std.heap.ArenaAllocator.init(original_allocator);
    defer invocation_arena.deinit();
    const allocator = invocation_arena.allocator();
    if (cmd_args.len < 1) return errors.Error.InvalidArguments;
    const sub = cmd_args[0];
    if (std.mem.eql(u8, sub, "list")) {
        if (cmd_args.len != 1) return errors.Error.InvalidArguments;
        var owned_config = try loadConfigOrDefault(allocator, paths.config_file);
        defer owned_config.deinit();
        const cfg = owned_config.view();
        var list_owner = try models.loadReadOnly(allocator, paths.models_file);
        defer list_owner.deinit();
        const list = list_owner.view();
        for (list.models) |m| {
            try sys.stdoutPrint("{s}\t{s}\t{s}{s}{s}\n", .{ m.id, m.name, m.profile, if (m.recommended) "\trecommended" else "", if (std.mem.eql(u8, m.id, cfg.model_id)) "\tcurrent" else "" });
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
    try validateCommandId(cmd_args[0]);
    var list_owner = try models.loadReadOnly(allocator, paths.models_file);
    defer list_owner.deinit();
    const list = list_owner.view();
    const m = models.find(list, cmd_args[0]) orelse return errors.Error.ModelRegistryInvalid;
    try printModelInfo(allocator, m);
    return 0;
}

fn printModelInfo(allocator: std.mem.Allocator, m: models.Model) !void {
    const download_url = try models.url.displayUrl(allocator, m.download_url);
    defer allocator.free(download_url);
    const source = if (m.source_url.len > 0) m.source_url else m.download_url;
    const source_url = try models.url.displayUrl(allocator, if (models.url.isRemote(source)) source else "");
    defer allocator.free(source_url);
    try sys.stdoutPrint("id: {s}\nname: {s}\nprofile: {s}\nformat: {s}\nquantization: {s}\ncontext_length: {d}\npath: {s}\ndownload_url: {s}\nsource_url: {s}\nchecksum: {s}\nlicense: {s}\nrecommended: {}\nnotes: {s}\n", .{
        m.id,
        m.name,
        m.profile,
        m.format,
        m.quantization,
        m.context_length,
        m.path,
        download_url,
        source_url,
        m.checksum,
        m.license,
        m.recommended,
        m.notes,
    });
}

fn runImport(allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    return runImportWithStager(allocator, paths, cmd_args, models.stageLocalFile);
}

fn runImportWithStager(
    allocator: std.mem.Allocator,
    paths: xdg.Paths,
    cmd_args: []const []const u8,
    stager: *const fn (std.mem.Allocator, []const u8, []const u8, []const u8) anyerror!models.StagedModel,
) !u8 {
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
    try validateCommandId(id);
    try models.validateGgufPath(source_path);
    try models.verifyModel(.{ .path = source_path });
    const dest_path = try models.installedPath(allocator, paths.models_dir, id);
    {
        var validation_owner = try models.loadReadOnly(allocator, paths.models_file);
        defer validation_owner.deinit();
    }
    try validateConfigLoad(allocator, paths.config_file);
    const display_name = if (name.len > 0) name else id;
    const model: models.Model = .{
        .id = id,
        .name = display_name,
        .profile = "local",
        .languages_en = true,
        .languages_ja = true,
        .format = "gguf",
        .path = dest_path,
        .checksum = checksum,
        .notes = "Imported local GGUF model.",
    };
    try models.validateModel(model);
    try xdg.ensureDirs(paths);

    // Capture the source and, for a self-import, its registration while
    // other model writers are excluded. Copy and checksum outside the lock.
    var initial: ?models.OwnedList = null;
    defer if (initial) |*owner| owner.deinit();
    var expectation: InstallExpectation = .latest;
    const source = capture: {
        const writer = try models.beginRegistryWrite(paths.models_file);
        defer writer.close();
        const source = try models.InstallSource.open(source_path) orelse return errors.Error.ModelMissing;
        errdefer source.close();
        const destination = models.InstallSource.open(dest_path) catch |err| switch (err) {
            error.ModelLoadFailed => null,
            else => return err,
        };
        if (destination) |installed| {
            defer installed.close();
            if (source.sameFile(installed)) {
                initial = try models.loadReadOnly(allocator, paths.models_file);
                expectation = .{ .self_import = .{
                    .previous = models.find(initial.?.view(), id),
                    .source = source,
                    .source_path = source_path,
                } };
            }
        }
        break :capture source;
    };
    defer source.close();
    var fd_path: [64]u8 = undefined;
    var staged = try stager(allocator, source.fdPath(&fd_path), dest_path, checksum);
    defer staged.deinit();
    try commitInstall(allocator, paths, &staged, model, expectation, use_model);
    try sys.stdoutPrint("imported {s}\n", .{id});
    return 0;
}

fn runPull(allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    return runPullWithAcquirer(allocator, paths, cmd_args, models.stagePull);
}

/// `allocator` is the public adapter's invocation arena; no command graph escapes this call.
fn runPullWithAcquirer(
    allocator: std.mem.Allocator,
    paths: xdg.Paths,
    cmd_args: []const []const u8,
    acquirer: *const fn (std.mem.Allocator, models.Model, []const u8, models.AcquireOptions) anyerror!?models.StagedModel,
) !u8 {
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
    if (output_path.len > 0) {
        try models.validateGgufPath(output_path);
        output_path = try sys.absolutePathAlloc(allocator, output_path);
        try models.validateStoredPath(output_path);
    }
    var m: models.Model = .{};
    var expected: ?models.Model = null;
    var pull_owner: ?models.OwnedList = null;
    defer if (pull_owner) |*owner| owner.deinit();
    if (hf_repo.len > 0) {
        if (model_url.len > 0 or positional_id.len > 0) return errors.Error.InvalidArguments;
        const hf = try models.parseHfRepo(hf_repo);
        if (id.len == 0) id = try models.defaultIdFromHf(allocator, hf);
        try validateCommandId(id);
        if (hf_file.len > 0) try models.validateSingleHfGgufFilename(hf_file);
        {
            var validation_owner = try models.loadReadOnly(allocator, paths.models_file);
            defer validation_owner.deinit();
        }
        try validateConfigLoad(allocator, paths.config_file);
        const file = try models.resolveHfFile(allocator, hf, hf_file);
        const url = try models.hfDownloadUrl(allocator, hf.repo, file);
        if (output_path.len == 0) output_path = try models.installedPath(allocator, paths.models_dir, id);
        m = .{ .id = id, .name = id, .profile = "huggingface", .languages_en = true, .languages_ja = true, .format = "gguf", .quantization = hf.quant, .download_url = url, .checksum = checksum, .notes = "Downloaded from Hugging Face." };
    } else if (model_url.len > 0) {
        if (positional_id.len > 0 or id.len == 0) return errors.Error.InvalidArguments;
        const uri = try models.url.parseRemote(model_url);
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return errors.Error.InvalidArguments;
        if (checksum.len == 0) return errors.Error.InvalidArguments;
        try models.validateId(id);
        {
            var validation_owner = try models.loadReadOnly(allocator, paths.models_file);
            defer validation_owner.deinit();
        }
        try validateConfigLoad(allocator, paths.config_file);
        if (output_path.len == 0) output_path = try models.installedPath(allocator, paths.models_dir, id);
        m = .{ .id = id, .name = id, .profile = "url", .languages_en = true, .languages_ja = true, .format = "gguf", .download_url = model_url, .checksum = checksum, .notes = "Downloaded from direct HTTPS URL." };
    } else {
        if (positional_id.len == 0 or id.len > 0) return errors.Error.InvalidArguments;
        try validateCommandId(positional_id);
        try validateConfigLoad(allocator, paths.config_file);
        pull_owner = try models.load(allocator, paths.models_file);
        const list = pull_owner.?.view();
        m = models.find(list, positional_id) orelse return errors.Error.ModelRegistryInvalid;
        expected = m;
        if (models.url.isRemote(m.download_url)) {
            const uri = try models.url.parseRemote(m.download_url);
            if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return errors.Error.InvalidArguments;
        }
        if (models.url.reusableUrl(m.download_url).len == 0) return errors.Error.ModelSourceRequired;
        id = m.id;
        if (output_path.len == 0) output_path = if (m.path.len > 0) m.path else try models.installedPath(allocator, paths.models_dir, id);
        if (checksum.len > 0) m.checksum = checksum;
    }
    try models.validateGgufPath(output_path);
    if (!std.fs.path.isAbsolute(output_path)) output_path = try sys.absolutePathAlloc(allocator, output_path);
    m.path = output_path;
    var request_model = m;
    if (models.url.isRemote(m.download_url)) {
        request_model.download_url = try models.url.requestUrl(m.download_url);
        m.source_url = try models.url.sourceIdentity(allocator, m.download_url);
    }
    m.download_url = models.url.reusableUrl(m.download_url);
    try models.validateModel(m);
    const managed_path = try models.installedPath(allocator, paths.models_dir, id);
    defer allocator.free(managed_path);
    const managed = std.mem.eql(u8, output_path, managed_path);
    try xdg.ensureDirs(paths);
    var staged = try acquirer(allocator, request_model, output_path, .{ .managed = managed }) orelse return errors.Error.ModelSourceRequired;
    defer staged.deinit();
    try commitInstall(allocator, paths, &staged, m, if (expected) |previous| .{ .registered_pull = previous } else .latest, use_model);
    try sys.stdoutPrint("pulled {s}\n", .{id});
    return 0;
}

const InstallExpectation = union(enum) {
    latest,
    registered_pull: models.Model,
    self_import: struct {
        previous: ?models.Model,
        source: models.InstallSource,
        source_path: []const u8,
    },
};

fn commitInstall(
    allocator: std.mem.Allocator,
    paths: xdg.Paths,
    stage: *models.StagedModel,
    m: models.Model,
    expected: InstallExpectation,
    use_model: bool,
) !void {
    const writer = try models.beginRegistryWrite(paths.models_file);
    defer writer.close();
    var entries = try models.loadReadOnly(allocator, paths.models_file);
    defer entries.deinit();
    const current = models.find(entries.view(), m.id);
    switch (expected) {
        .latest => {},
        .registered_pull => |previous| try models.requireCurrent(current, previous),
        .self_import => |initial| {
            try models.requireCurrent(current, initial.previous);
            try initial.source.requireUnchanged(initial.source_path);
            try initial.source.requireUnchanged(m.path);
        },
    }

    // Recheck after staging under the same lock used for publication. An
    // unreadable configuration cannot rule out a selected-model reference.
    var cfg = try loadConfigOrDefault(allocator, paths.config_file);
    defer cfg.deinit();
    const destination = (try installEntryPath(allocator, m.path)) orelse return errors.Error.PathResolutionFailed;
    defer allocator.free(destination);
    // A linked config target can have any extension. It must remain
    // readable even when a caller chooses its name as a model output.
    if (try referencesInstallEntry(allocator, paths.config_file, destination)) return errors.Error.InvalidArguments;
    const dest_stat = sys.cwd().statFile(sys.io(), destination, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    // Replacing a link to a directory could break references to models
    // below it even if their final components differ from the output.
    if (dest_stat != null and dest_stat.?.kind == .directory) return error.IsDir;
    const replacing = dest_stat != null or (try sys.pathState(destination)) == .present;
    for (entries.view().models) |other| {
        if (!std.mem.eql(u8, other.id, m.id) and try conflictsWithInstall(allocator, other.path, destination, replacing))
            return errors.Error.ModelPathInUse;
    }

    const settings = cfg.view();
    const active_id = std.mem.eql(u8, settings.model_id, m.id);
    if (!active_id and try conflictsWithInstall(allocator, settings.model_path, destination, replacing))
        return errors.Error.ModelPathInUse;
    const update_selection = use_model or (active_id and try followsMovingRegistration(settings, current, m.path));
    if (update_selection) try cfg.selectRegisteredModel(m.id, m.path);
    try models.ensure(paths.models_file);
    try stage.publish(m.path);
    try writer.upsert(allocator, m);
    if (update_selection) try config.save(paths.config_file, cfg.view());
}

fn followsMovingRegistration(settings: config.Config, current: ?models.Model, output: []const u8) !bool {
    const selected = settings.model_path;
    if (selected.len == 0) return false;
    if (current) |registered| {
        // Identical names share the same reference even in legacy config.
        // Re-anchor selection together with registration on a name change.
        if (sameStoredPath(selected, registered.path)) return !sameStoredPath(selected, output);
    }
    if (settings.model_path_explicit) return false;

    // Older pulls could move the registration without moving the selection.
    // Even two distinct files do not establish an explicit override.
    return errors.Error.ModelReselectionRequired;
}

fn conflictsWithInstall(allocator: std.mem.Allocator, reference: []const u8, destination: []const u8, replacing: bool) !bool {
    if (reference.len == 0) return false;
    // Legacy paths have no saved working directory. The installer's current
    // working directory cannot tell us whether an existing entry is shared.
    if (!std.fs.path.isAbsolute(reference)) return replacing;
    return referencesInstallEntry(allocator, reference, destination);
}

/// Ignore spelling differences that do not traverse a different directory
/// entry. Keep symlink names and ".." because they may encode an override.
fn sameStoredPath(selected: []const u8, registered: []const u8) bool {
    if (selected.len == 0 or registered.len == 0) return false;
    if (std.fs.path.isAbsolute(selected) != std.fs.path.isAbsolute(registered)) return false;
    var left = std.mem.tokenizeScalar(u8, selected, '/');
    var right = std.mem.tokenizeScalar(u8, registered, '/');
    while (true) {
        const a = nextNamedComponent(&left) orelse return nextNamedComponent(&right) == null;
        const b = nextNamedComponent(&right) orelse return false;
        if (!std.mem.eql(u8, a, b)) return false;
    }
}

fn nextNamedComponent(parts: *std.mem.TokenIterator(u8, .scalar)) ?[]const u8 {
    while (parts.next()) |component| {
        if (!std.mem.eql(u8, component, ".")) return component;
    }
    return null;
}

/// Resolve the directory entry that rename will replace, without following
/// its final symlink.
fn installEntryPath(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const parent = sys.realPathIfExistsAlloc(allocator, std.fs.path.dirname(path) orelse ".") catch |err| switch (err) {
        error.NotDir, error.SymLinkLoop => return null,
        else => return err,
    } orelse return null;
    defer allocator.free(parent);
    return try std.fs.path.join(allocator, &.{ parent, std.fs.path.basename(path) });
}

/// Follow leaf links one at a time so a reference through the destination
/// is recognized even if it is an intermediate or dangling symlink.
fn referencesInstallEntry(allocator: std.mem.Allocator, path: []const u8, destination: []const u8) !bool {
    if (path.len == 0) return false;
    var current = try allocator.dupe(u8, path);
    defer allocator.free(current);
    const max_links = 40;
    for (0..max_links + 1) |followed| {
        const entry = (try installEntryPath(allocator, current)) orelse return false;
        defer allocator.free(entry);
        if (std.mem.eql(u8, entry, destination)) return true;
        // Linux permits 40 link hops. The terminal entry must be checked
        // after the last hop, even when no more links may be read.
        if (followed == max_links) return false;

        var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const count = sys.cwd().readLink(sys.io(), entry, &target_buffer) catch |err| switch (err) {
            error.NotLink, error.FileNotFound => return false,
            else => return err,
        };
        if (count == target_buffer.len) return error.NameTooLong;
        const target = target_buffer[0..count];
        const next = if (std.fs.path.isAbsolute(target))
            try allocator.dupe(u8, target)
        else
            try std.fs.path.join(allocator, &.{ std.fs.path.dirname(entry).?, target });
        allocator.free(current);
        current = next;
    }
    return false;
}

fn runUse(allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    if (cmd_args.len != 1) return errors.Error.InvalidArguments;
    try validateCommandId(cmd_args[0]);
    try validateConfigLoad(allocator, paths.config_file);
    var list_owner = try models.load(allocator, paths.models_file);
    defer list_owner.deinit();
    const list = list_owner.view();
    const expected = models.find(list, cmd_args[0]) orelse return errors.Error.ModelRegistryInvalid;
    var m = expected;
    if (m.path.len > 0 and !std.fs.path.isAbsolute(m.path)) m.path = try sys.absolutePathAlloc(allocator, m.path);
    try models.validateModel(m);
    try models.verifyModel(m);
    try xdg.ensureDirs(paths);
    {
        const writer = try models.beginRegistryWrite(paths.models_file);
        defer writer.close();
        try models.verifyModel(.{ .path = m.path });
        try writer.replaceIfUnchanged(allocator, expected, m);
        try selectModel(allocator, paths, m.id, m.path);
    }
    try sys.stdoutPrint("using {s}\n", .{m.id});
    return 0;
}

fn runVerify(allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    if (cmd_args.len > 1) return errors.Error.InvalidArguments;
    if (cmd_args.len == 1) try validateCommandId(cmd_args[0]);
    var owned_config = try loadConfigOrDefault(allocator, paths.config_file);
    defer owned_config.deinit();
    const cfg = owned_config.view();
    const id = if (cmd_args.len == 1) cmd_args[0] else cfg.model_id;
    if (id.len == 0) return errors.Error.ModelNotSelected;
    try validateCommandId(id);
    var list_owner = try models.loadReadOnly(allocator, paths.models_file);
    defer list_owner.deinit();
    const list = list_owner.view();
    var m = models.find(list, id) orelse return errors.Error.ModelRegistryInvalid;
    if (cmd_args.len == 0) {
        if (cfg.model_path.len == 0) return errors.Error.ModelNotSelected;
        m.path = cfg.model_path;
    }
    try models.verifyModel(m);
    try sys.stdoutPrint("verified {s}\n", .{id});
    return 0;
}

fn runRemove(allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    var filesystem = fs.FileSystem.init(sys.io(), sys.cwd(), null);
    return runRemoveWithFileSystem(allocator, paths, cmd_args, &filesystem, models.load);
}

// The filesystem and reload callback are borrowed only for this command invocation.
fn runRemoveWithFileSystem(allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8, filesystem: *fs.FileSystem, reload: *const fn (std.mem.Allocator, []const u8) anyerror!models.OwnedList) !u8 {
    if (cmd_args.len != 2 or !std.mem.eql(u8, cmd_args[1], "--yes")) return errors.Error.InvalidArguments;
    const id = cmd_args[0];
    try validateCommandId(id);
    try validateConfigLoad(allocator, paths.config_file);
    try requireRemovalTarget(allocator, paths.models_file, id);
    {
        const writer = try models.beginRegistryWrite(paths.models_file);
        defer writer.close();
        var cfg = try loadConfigOrDefault(allocator, paths.config_file);
        defer cfg.deinit();
        // Re-check after waiting. The preflight only keeps invalid requests
        // from touching the config directory's metadata.
        try requireRemovalTarget(allocator, paths.models_file, id);
        try xdg.ensureDirs(paths);
        var removed_owner = try writer.removeById(allocator, id);
        defer removed_owner.deinit();
        const removed = removed_owner.view();
        var remaining_owner = try reload(allocator, paths.models_file);
        defer remaining_owner.deinit();
        const remaining = remaining_owner.view();
        const removing_selected = std.mem.eql(u8, cfg.view().model_id, id);
        const active_path = if (removing_selected) "" else cfg.view().model_path;
        if (try canDeleteManagedModelPath(allocator, paths.models_dir, removed.path, remaining, active_path, filesystem)) {
            _ = try filesystem.removeFileIfExists(removed.path);
        }
        if (removing_selected) {
            try cfg.selectRegisteredModel("", "");
            try config.save(paths.config_file, cfg.view());
        }
    }
    try sys.stdoutPrint("removed {s}\n", .{id});
    return 0;
}

fn requireRemovalTarget(allocator: std.mem.Allocator, path: []const u8, id: []const u8) !void {
    var list = try models.load(allocator, path);
    defer list.deinit();
    _ = models.find(list.view(), id) orelse return errors.Error.ModelRegistryInvalid;
}

fn validateCommandId(id: []const u8) !void {
    if (std.mem.startsWith(u8, id, "-")) return errors.Error.InvalidArguments;
    try models.validateId(id);
}

fn canDeleteManagedModelPath(allocator: std.mem.Allocator, models_dir: []const u8, path: []const u8, remaining: models.List, active_path: []const u8, filesystem: *fs.FileSystem) !bool {
    // There is no persisted base directory for an unselected legacy path.
    if (!std.fs.path.isAbsolute(path)) return false;
    const real_models_dir = (try filesystem.realPathIfExistsAlloc(allocator, models_dir)) orelse return false;
    defer allocator.free(real_models_dir);
    const real_path = (try filesystem.realPathIfExistsAlloc(allocator, path)) orelse return false;
    defer allocator.free(real_path);
    if (real_path.len <= real_models_dir.len) return false;
    if (!std.mem.startsWith(u8, real_path, real_models_dir)) return false;
    if (real_path[real_models_dir.len] != std.fs.path.sep) return false;
    if (try referencesModel(allocator, filesystem, active_path, real_path)) return false;
    for (remaining.models) |m| {
        if (try referencesModel(allocator, filesystem, m.path, real_path)) return false;
    }
    return true;
}

fn referencesModel(allocator: std.mem.Allocator, filesystem: *fs.FileSystem, path: []const u8, real_model: []const u8) !bool {
    if (path.len == 0) return false;
    if (!std.fs.path.isAbsolute(path)) return true;
    const resolved = (try filesystem.realPathIfExistsAlloc(allocator, path)) orelse return false;
    defer allocator.free(resolved);
    return std.mem.eql(u8, real_model, resolved);
}

pub fn validateConfigLoad(allocator: std.mem.Allocator, path: []const u8) !void {
    var cfg = try loadConfigOrDefault(allocator, path);
    defer cfg.deinit();
}

pub fn loadConfigOrDefault(allocator: std.mem.Allocator, path: []const u8) !config.OwnedConfig {
    return config.load(allocator, path) catch |err| switch (err) {
        error.NotInitialized => config.OwnedConfig.clone(allocator, config.default()),
        else => return err,
    };
}

pub fn selectModel(allocator: std.mem.Allocator, paths: xdg.Paths, id: []const u8, model_path: []const u8) !void {
    var cfg = try loadConfigOrDefault(allocator, paths.config_file);
    defer cfg.deinit();
    const absolute_path = try sys.absolutePathAlloc(allocator, model_path);
    defer allocator.free(absolute_path);
    try cfg.selectRegisteredModel(id, absolute_path);
    try config.save(paths.config_file, cfg.view());
}

// Keep command output out of the Zig test runner's stdout protocol.
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

fn testPullPaths(allocator: std.mem.Allocator, root: []const u8) !xdg.Paths {
    return .{
        .config_dir = root,
        .data_dir = root,
        .cache_dir = root,
        .state_dir = root,
        .models_dir = root,
        .config_file = try std.fs.path.join(allocator, &.{ root, "config.toml" }),
        .models_file = try std.fs.path.join(allocator, &.{ root, "models.toml" }),
        .glossary_file = try std.fs.path.join(allocator, &.{ root, "glossary.toml" }),
        .memory_file = try std.fs.path.join(allocator, &.{ root, "memory.sqlite3" }),
    };
}

fn testFreshPaths(allocator: std.mem.Allocator, root: []const u8) !xdg.Paths {
    const config_dir = try std.fs.path.join(allocator, &.{ root, "config", "kotoba" });
    const data_dir = try std.fs.path.join(allocator, &.{ root, "data", "kotoba" });
    return .{
        .config_dir = config_dir,
        .data_dir = data_dir,
        .cache_dir = try std.fs.path.join(allocator, &.{ root, "cache", "kotoba" }),
        .state_dir = try std.fs.path.join(allocator, &.{ root, "state", "kotoba" }),
        .models_dir = try std.fs.path.join(allocator, &.{ data_dir, "models" }),
        .config_file = try std.fs.path.join(allocator, &.{ config_dir, "config.toml" }),
        .models_file = try std.fs.path.join(allocator, &.{ config_dir, "models.toml" }),
        .glossary_file = try std.fs.path.join(allocator, &.{ config_dir, "glossary.toml" }),
        .memory_file = try std.fs.path.join(allocator, &.{ data_dir, "memory.sqlite3" }),
    };
}

test "models list preserves a fresh XDG fixture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const paths = try testFreshPaths(allocator, root);
    const output = try tmp.dir.createFile(sys.io(), "stdout", .{ .read = true });
    defer output.close(sys.io());
    var capture = try TestStdoutCapture.start(output);
    defer capture.restore();

    try std.testing.expect(!sys.exists(paths.config_dir));
    try std.testing.expect(!sys.exists(paths.data_dir));
    try std.testing.expectError(errors.Error.InvalidArguments, run(allocator, paths, &.{ "info", "--bogus" }));
    try std.testing.expect(!sys.exists(paths.config_dir));
    try std.testing.expect(!sys.exists(paths.data_dir));
    try std.testing.expectEqual(@as(u8, 0), try run(allocator, paths, &.{"list"}));
    capture.restore();
    try std.testing.expectEqualStrings("custom\tCustom local GGUF model\tcustom\nexample-light\tExample Light Model Placeholder\tdefault\trecommended\n", try sys.readFileAlloc(allocator, try std.fs.path.join(allocator, &.{ root, "stdout" }), 1024));
    try std.testing.expect(!sys.exists(paths.config_dir));
    try std.testing.expect(!sys.exists(paths.data_dir));
}

test "secret URL pull pipeline keeps request transient" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const paths = try testPullPaths(allocator, root);
    try sys.writeFile(paths.models_file, "");
    const output = try tmp.dir.createFile(sys.io(), "stdout", .{ .read = true });
    defer output.close(sys.io());
    var capture = try TestStdoutCapture.start(output);
    defer capture.restore();
    const Fixture = struct {
        const signed = "https://models.example.invalid/repo/model%2Bname.gguf?X-Signature=KOTOBA_QUERY_SECRET_36&x=a%2Bb&x=2#KOTOBA_FRAGMENT_SECRET_36";
        const identity = "https://models.example.invalid/repo/model%2Bname.gguf";
        const bytes = "remote model bytes";
        var expected: []const u8 = undefined;
        var calls: usize = 0;
        fn download(_: std.mem.Allocator, value: []const u8, dest: []const u8) !void {
            calls += 1;
            try std.testing.expectEqualStrings(expected, value);
            try sys.writeFile(dest, bytes);
        }
        fn acquire(a: std.mem.Allocator, m: models.Model, dest: []const u8, options: models.AcquireOptions) !?models.StagedModel {
            try std.testing.expectEqualStrings(expected, m.download_url);
            try std.testing.expect(!options.skip_download);
            return @import("../models/install.zig").stageWithDownloader(a, m, dest, options, download);
        }
    };
    Fixture.calls = 0;
    const checksum = try sys.hexSha256(allocator, Fixture.bytes);
    const dest = try models.installedPath(allocator, root, "signed36");
    for ([_][]const u8{ Fixture.signed, Fixture.identity, Fixture.signed }) |source| {
        Fixture.expected = source[0 .. std.mem.indexOfScalar(u8, source, '#') orelse source.len];
        const before_calls = Fixture.calls;
        try std.testing.expectEqual(@as(u8, 0), try runPullWithAcquirer(allocator, paths, &.{ "--model-url", source, "--id", "signed36", "--checksum", checksum }, Fixture.acquire));
        try std.testing.expectEqual(before_calls + 1, Fixture.calls);
        var saved_owner = try models.load(allocator, paths.models_file);
        defer saved_owner.deinit();
        const saved = models.find(saved_owner.view(), "signed36").?;
        try std.testing.expectEqualStrings(Fixture.identity, saved.source_url);
        try std.testing.expectEqualStrings(if (std.mem.indexOfScalar(u8, source, '?') == null) Fixture.identity else "", saved.download_url);
        try std.testing.expectEqualStrings(checksum, saved.checksum);
        try std.testing.expectEqualStrings(dest, saved.path);
        try std.testing.expectEqualStrings(Fixture.bytes, try sys.readFileAlloc(allocator, dest, 1024));
        try models.verifySha256(dest, checksum);
        const registry = try sys.readFileAlloc(allocator, paths.models_file, 8192);
        try std.testing.expect(std.mem.indexOf(u8, registry, "KOTOBA_") == null);
    }
    const saved_before_failure = try sys.readFileAlloc(allocator, paths.models_file, 8192);
    const wrong_checksum = try sys.hexSha256(allocator, "different bytes");
    Fixture.expected = try models.url.requestUrl(Fixture.signed);
    try std.testing.expectError(error.ChecksumFailed, runPullWithAcquirer(allocator, paths, &.{ "--model-url", Fixture.signed, "--id", "signed36", "--checksum", wrong_checksum }, Fixture.acquire));
    try std.testing.expectEqual(@as(usize, 4), Fixture.calls);
    try std.testing.expectEqualStrings(saved_before_failure, try sys.readFileAlloc(allocator, paths.models_file, 8192));
    try std.testing.expectEqualStrings(Fixture.bytes, try sys.readFileAlloc(allocator, dest, 1024));
    try models.verifySha256(dest, checksum);
    Fixture.expected = "https://huggingface.co/example/repo/resolve/main/model.gguf";
    try std.testing.expectEqual(@as(u8, 0), try runPullWithAcquirer(allocator, paths, &.{ "--hf-repo", "example/repo", "--hf-file", "model.gguf", "--id", "hf36", "--checksum", checksum }, Fixture.acquire));
    try std.testing.expectEqual(@as(usize, 5), Fixture.calls);
    var hf_owner = try models.load(allocator, paths.models_file);
    defer hf_owner.deinit();
    const hf_saved = models.find(hf_owner.view(), "hf36").?;
    try std.testing.expectEqualStrings(Fixture.expected, hf_saved.download_url);
    try std.testing.expectEqualStrings(Fixture.expected, hf_saved.source_url);
    try models.verifySha256(hf_saved.path, checksum);
    capture.restore();
    try std.testing.expectEqualStrings("pulled signed36\npulled signed36\npulled signed36\npulled hf36\n", try sys.readFileAlloc(allocator, try std.fs.path.join(allocator, &.{ root, "stdout" }), 1024));
    var iterator = tmp.dir.iterate();
    while (try iterator.next(sys.io())) |entry| try std.testing.expect(std.mem.indexOf(u8, entry.name, ".tmp-") == null);
}

test "secret URL pull without reusable source fails before acquirer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const paths = try testPullPaths(allocator, root);
    const dest = try models.installedPath(allocator, root, "signed36");
    try sys.writeFile(dest, "installed model bytes");
    const checksum = try sys.hexSha256(allocator, "installed model bytes");
    const output = try tmp.dir.createFile(sys.io(), "stdout", .{ .read = true });
    defer output.close(sys.io());
    var capture = try TestStdoutCapture.start(output);
    defer capture.restore();
    const Fixture = struct {
        var calls: usize = 0;
        fn acquire(_: std.mem.Allocator, _: models.Model, _: []const u8, _: models.AcquireOptions) !?models.StagedModel {
            calls += 1;
            return error.UnexpectedAcquirerCall;
        }
    };
    Fixture.calls = 0;
    for ([_]struct { source: []const u8, expected: anyerror }{
        .{ .source = "", .expected = error.ModelSourceRequired },
        .{ .source = "https://models.example.invalid/a?token=KOTOBA_QUERY_SECRET_36", .expected = error.ModelSourceRequired },
        .{ .source = "https://models.example.invalid/a?", .expected = error.ModelSourceRequired },
        .{ .source = "https://KOTOBA_USER_36:KOTOBA_PASSWORD_36@models.example.invalid/a", .expected = error.InvalidArguments },
        .{ .source = "https://@models.example.invalid/a", .expected = error.InvalidArguments },
        .{ .source = "https:///a", .expected = error.InvalidArguments },
        .{ .source = "https://models.example.invalid/a#\t", .expected = error.InvalidArguments },
        .{ .source = "http://models.example.invalid/a", .expected = error.InvalidArguments },
    }) |case| {
        const registry = try std.fmt.allocPrint(allocator, "[[models]]\nid = \"signed36\"\npath = \"{s}\"\nchecksum = \"{s}\"\ndownload_url = \"{s}\"\nsource_url = \"https://models.example.invalid/never-fetch.gguf\"\n", .{ dest, checksum, case.source });
        try sys.writeFile(paths.models_file, registry);
        try std.testing.expectError(case.expected, runPullWithAcquirer(allocator, paths, &.{"signed36"}, Fixture.acquire));
        try std.testing.expectEqual(@as(usize, 0), Fixture.calls);
        try std.testing.expectEqualStrings(registry, try sys.readFileAlloc(allocator, paths.models_file, 8192));
        try std.testing.expectEqualStrings("installed model bytes", try sys.readFileAlloc(allocator, dest, 1024));
        try models.verifySha256(dest, checksum);
    }
    const oversize = try allocator.alloc(u8, models.url.max_length + 1);
    @memset(oversize, 'a');
    @memcpy(oversize[0.."https://models.example.invalid/".len], "https://models.example.invalid/");
    for ([_][]const u8{ "https://@models.example.invalid/a", "https:///a", "https://models.example.invalid/a#\t", oversize }) |source| {
        try std.testing.expectError(error.InvalidArguments, runPullWithAcquirer(allocator, paths, &.{ "--model-url", source, "--id", "signed36", "--checksum", checksum }, Fixture.acquire));
        try std.testing.expectEqual(@as(usize, 0), Fixture.calls);
        try models.verifySha256(dest, checksum);
    }
    capture.restore();
    try std.testing.expectEqualStrings("", try sys.readFileAlloc(allocator, try std.fs.path.join(allocator, &.{ root, "stdout" }), 1024));
    var iterator = tmp.dir.iterate();
    while (try iterator.next(sys.io())) |entry| try std.testing.expect(std.mem.indexOf(u8, entry.name, ".tmp-") == null);
}

test "secret URL pull stdout capture restores on error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const outer = try tmp.dir.createFile(sys.io(), "outer", .{ .read = true });
    defer outer.close(sys.io());
    const inner = try tmp.dir.createFile(sys.io(), "inner", .{ .read = true });
    defer inner.close(sys.io());
    var capture = try TestStdoutCapture.start(outer);
    defer capture.restore();
    const Fixture = struct {
        fn fail(file: std.Io.File) !void {
            var nested = try TestStdoutCapture.start(file);
            defer nested.restore();
            try sys.stdoutWrite("before error\n");
            return error.ExpectedFailure;
        }
    };
    try std.testing.expectError(error.ExpectedFailure, Fixture.fail(inner));
    try sys.stdoutWrite("restored\n");
    capture.restore();
    const outer_bytes = try tmp.dir.readFileAlloc(sys.io(), "outer", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(outer_bytes);
    const inner_bytes = try tmp.dir.readFileAlloc(sys.io(), "inner", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(inner_bytes);
    try std.testing.expectEqualStrings("restored\n", outer_bytes);
    try std.testing.expectEqualStrings("before error\n", inner_bytes);
}

test "secret URL model info renders remote identities only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_]struct { download: []const u8, source: []const u8, expected: []const u8 }{
        .{ .download = "/local/model?#.gguf", .source = "", .expected = "" },
        .{ .download = "file:///local/model?#.gguf", .source = "", .expected = "" },
        .{ .download = "/local/model.gguf", .source = "file:///local/model.gguf", .expected = "" },
        .{ .download = "https://KOTOBA_USER_36@models.example.invalid/a?KOTOBA_QUERY_SECRET_36", .source = "", .expected = "https://models.example.invalid/a" },
        .{ .download = "", .source = "https://models.example.invalid/b#KOTOBA_FRAGMENT_SECRET_36", .expected = "https://models.example.invalid/b" },
        .{ .download = "https:///a", .source = "https:///b", .expected = "[redacted]" },
    }) |case| {
        const output = try tmp.dir.createFile(sys.io(), "stdout", .{ .read = true });
        defer output.close(sys.io());
        var capture = try TestStdoutCapture.start(output);
        defer capture.restore();
        try printModelInfo(allocator, .{ .download_url = case.download, .source_url = case.source });
        capture.restore();
        const bytes = try tmp.dir.readFileAlloc(sys.io(), "stdout", allocator, .limited(8192));
        try std.testing.expect(std.mem.indexOf(u8, bytes, "KOTOBA_") == null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, try std.fmt.allocPrint(allocator, "\nsource_url: {s}\n", .{case.expected})) != null);
    }
}

const PreflightCommand = enum { init, use, remove, import_use, pull_use, list, verify, select, pull_hf };

fn testStateSnapshot(allocator: std.mem.Allocator, dir: std.Io.Dir) ![]const u8 {
    var entries = std.array_list.Managed([]const u8).init(allocator);
    var iterator = dir.iterate();
    while (try iterator.next(sys.io())) |entry| {
        if (std.mem.eql(u8, entry.name, "stdout")) continue;
        const contents = if (entry.kind == .file) try dir.readFileAlloc(sys.io(), entry.name, allocator, .limited(3 * 1024 * 1024)) else "";
        try entries.append(try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ entry.name, @tagName(entry.kind), try sys.hexSha256(allocator, contents) }));
    }
    std.mem.sort([]const u8, entries.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return std.mem.join(allocator, "\n", entries.items);
}

fn testPreflight(command: PreflightCommand, registry_failure: bool) !void {
    for ([_]enum { malformed, schema, directory, oversize }{ .malformed, .schema, .directory, .oversize }) |failure| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(sys.io(), ".", allocator);
        var paths = try testPullPaths(allocator, root);
        paths.cache_dir = try std.fs.path.join(allocator, &.{ root, "uncached" });
        paths.state_dir = try std.fs.path.join(allocator, &.{ root, "unstated" });
        const dest = try models.installedPath(allocator, root, "fixture");
        try sys.writeFile(dest, "preserve installed model bytes");
        var registry_models = [_]models.Model{.{ .id = "fixture", .path = dest, .download_url = "https://models.example.invalid/fixture.gguf" }};
        try models.save(paths.models_file, .{ .models = &registry_models });
        try config.save(paths.config_file, .{ .model_id = "fixture", .model_path = dest, .threads = 7 });
        try sys.writeFile(paths.glossary_file, "preserve glossary bytes");
        var db = try @import("../memory.zig").open(allocator, paths.memory_file);
        db.close();
        const failed_path = if (registry_failure) paths.models_file else paths.config_file;
        const expected: anyerror = switch (failure) {
            .malformed => if (registry_failure) error.ModelsInvalid else error.ConfigInvalid,
            .schema => if (registry_failure) error.ModelsSchemaUnsupported else error.ConfigSchemaUnsupported,
            .directory => error.IsDir,
            .oversize => error.StreamTooLong,
        };
        switch (failure) {
            .malformed => try sys.writeFile(failed_path, if (registry_failure) "[[models]]\nid = \"fixture\"\nid = \"duplicate\"\n" else "gpu_layers = \"auto\"\n"),
            .schema => try sys.writeFile(failed_path, "schema_version = 2\n"),
            .directory => {
                try std.Io.Dir.cwd().deleteFile(sys.io(), failed_path);
                try std.Io.Dir.cwd().createDir(sys.io(), failed_path, .default_dir);
            },
            .oversize => {
                const bytes = try allocator.alloc(u8, (if (registry_failure) @as(usize, 2) else 1) * 1024 * 1024 + 1);
                @memset(bytes, ' ');
                try sys.writeFile(failed_path, bytes);
            },
        }
        const before = try testStateSnapshot(allocator, tmp.dir);
        const output = try tmp.dir.createFile(sys.io(), "stdout", .{ .read = true });
        defer output.close(sys.io());
        var capture = try TestStdoutCapture.start(output);
        defer capture.restore();
        const Fixture = struct {
            var calls: usize = 0;
            fn acquire(_: std.mem.Allocator, _: models.Model, _: []const u8, _: models.AcquireOptions) !?models.StagedModel {
                calls += 1;
                return error.UnexpectedAcquirerCall;
            }
        };
        Fixture.calls = 0;
        const result = switch (command) {
            .init => @import("init_cmd.zig").run(allocator, paths, &.{"--yes"}),
            .use => run(allocator, paths, &.{ "use", "fixture" }),
            .remove => run(allocator, paths, &.{ "remove", "fixture", "--yes" }),
            .import_use => run(allocator, paths, &.{ "import", "--id", "new", "--path", dest, "--use" }),
            .pull_use => runPullWithAcquirer(allocator, paths, &.{ "--model-url", "https://models.example.invalid/x.gguf", "--id", "new", "--checksum", "0000000000000000000000000000000000000000000000000000000000000000", "--use" }, Fixture.acquire),
            .pull_hf => runPullWithAcquirer(allocator, paths, &.{ "--hf-repo", "example/repo", "--hf-file", "model.gguf", "--id", "new", "--use" }, Fixture.acquire),
            .list => run(allocator, paths, &.{"list"}),
            .verify => run(allocator, paths, &.{"verify"}),
            .select => blk: {
                selectModel(allocator, paths, "fixture", dest) catch |err| break :blk err;
                break :blk @as(u8, 0);
            },
        };
        try std.testing.expectError(expected, result);
        try std.testing.expectEqual(@as(usize, 0), Fixture.calls);
        capture.restore();
        try std.testing.expectEqualStrings("", try tmp.dir.readFileAlloc(sys.io(), "stdout", allocator, .limited(1024)));
        try std.testing.expectEqualStrings(before, try testStateSnapshot(allocator, tmp.dir));
    }
}

test "init preserves state on config load failures" {
    try testPreflight(.init, false);
}

test "models use preserves state on config load failures" {
    try testPreflight(.use, false);
}

test "models remove preserves state on config load failures" {
    try testPreflight(.remove, false);
}

test "models import use preserves state on config load failures" {
    try testPreflight(.import_use, false);
}

test "models direct pull use refuses config failures before acquisition" {
    try testPreflight(.pull_use, false);
}

test "models HF pull use refuses config failures before acquisition" {
    try testPreflight(.pull_hf, false);
}

test "models list verify and selection preserve config load failures" {
    try testPreflight(.list, false);
    try testPreflight(.verify, false);
    try testPreflight(.select, false);
}

test "models acquisition and mutations refuse registry load failures" {
    for ([_]PreflightCommand{ .init, .use, .remove, .import_use, .pull_use, .pull_hf, .list, .verify }) |command| try testPreflight(command, true);
}

test "model mutations retain valid and absent config semantics" {
    for ([_]bool{ false, true }) |existing_config| {
        for ([_]PreflightCommand{ .init, .use, .remove, .import_use, .pull_use, .pull_hf }) |command| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const root = try tmp.dir.realPathFileAlloc(sys.io(), ".", allocator);
            const paths = try testPullPaths(allocator, root);
            const dest = try models.installedPath(allocator, root, "fixture");
            try sys.writeFile(dest, "existing model");
            var registry_models = [_]models.Model{.{ .id = "fixture", .path = dest }};
            try models.save(paths.models_file, .{ .models = &registry_models });
            if (existing_config) try config.save(paths.config_file, .{ .model_id = "fixture", .model_path = dest, .threads = 7 });
            const output = try tmp.dir.createFile(sys.io(), "stdout", .{ .read = true });
            defer output.close(sys.io());
            var capture = try TestStdoutCapture.start(output);
            defer capture.restore();
            const Fixture = struct {
                var calls: usize = 0;
                fn acquire(a: std.mem.Allocator, m: models.Model, path: []const u8, options: models.AcquireOptions) !?models.StagedModel {
                    calls += 1;
                    var stage = try models.StagedModel.begin(a, path);
                    errdefer stage.deinit();
                    try sys.writeFile(stage.path, "downloaded fixture");
                    try stage.verify(m.checksum, options.managed);
                    return stage;
                }
            };
            Fixture.calls = 0;
            const checksum = try sys.hexSha256(allocator, "downloaded fixture");
            const result = switch (command) {
                .init => @import("init_cmd.zig").run(allocator, paths, &.{"--yes"}),
                .use => run(allocator, paths, &.{ "use", "fixture" }),
                .remove => run(allocator, paths, &.{ "remove", "fixture", "--yes" }),
                .import_use => run(allocator, paths, &.{ "import", "--id", "new", "--path", dest, "--use" }),
                .pull_use => runPullWithAcquirer(allocator, paths, &.{ "--model-url", "https://models.example.invalid/x.gguf", "--id", "new", "--checksum", checksum, "--use" }, Fixture.acquire),
                .pull_hf => runPullWithAcquirer(allocator, paths, &.{ "--hf-repo", "example/repo", "--hf-file", "model.gguf", "--id", "new", "--checksum", checksum, "--use" }, Fixture.acquire),
                else => unreachable,
            };
            try std.testing.expectEqual(@as(u8, 0), try result);
            capture.restore();
            const is_pull = command == .pull_use or command == .pull_hf;
            try std.testing.expectEqual(@as(usize, if (is_pull) 1 else 0), Fixture.calls);
            const expected_output: []const u8 = switch (command) {
                .init => "initialized\n",
                .use => "using fixture\n",
                .remove => "removed fixture\n",
                .import_use => "imported new\n",
                .pull_use, .pull_hf => "pulled new\n",
                else => unreachable,
            };
            try std.testing.expectEqualStrings(expected_output, try tmp.dir.readFileAlloc(sys.io(), "stdout", allocator, .limited(1024)));
            if (command == .remove) {
                try std.testing.expect(!sys.exists(dest));
                var absent_owner = try models.load(allocator, paths.models_file);
                defer absent_owner.deinit();
                try std.testing.expect(models.find(absent_owner.view(), "fixture") == null);
                if (!existing_config) {
                    try std.testing.expect(!sys.exists(paths.config_file));
                    continue;
                }
            }
            var cfg_owner = try config.load(allocator, paths.config_file);
            defer cfg_owner.deinit();
            const cfg = cfg_owner.view();
            try std.testing.expectEqual(@as(u32, if (existing_config) 7 else 0), cfg.threads);
            try std.testing.expectEqualStrings(if (command == .init or command == .remove) "" else if (command == .use) "fixture" else "new", cfg.model_id);
            if (command == .import_use or is_pull) try std.testing.expectEqualStrings(if (is_pull) "downloaded fixture" else "existing model", try sys.readFileAlloc(allocator, cfg.model_path, 1024));
        }
    }
}

const RemoveCase = enum { normal, missing, shared, external, directory };

fn testRemoveNative(case: RemoveCase) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    var paths = try testPullPaths(allocator, root);
    paths.models_dir = try std.fs.path.join(allocator, &.{ root, "managed" });
    try xdg.ensureDirs(paths);
    const model_path = try std.fs.path.join(allocator, &.{ if (case == .external) root else paths.models_dir, "fixture.gguf" });
    if (case == .directory) {
        try sys.makePath(model_path);
    } else if (case != .missing) {
        try sys.writeFile(model_path, "model bytes");
    }
    var entries = [_]models.Model{ .{ .id = "fixture", .path = model_path }, .{ .id = "shared", .path = model_path } };
    try models.save(paths.models_file, .{ .models = entries[0..if (case == .shared) @as(usize, 2) else 1] });
    var cfg = config.default();
    cfg.model_id = "fixture";
    cfg.model_path = model_path;
    try config.save(paths.config_file, cfg);
    const output = try tmp.dir.createFile(sys.io(), "stdout", .{ .read = true });
    defer output.close(sys.io());
    var capture = try TestStdoutCapture.start(output);
    defer capture.restore();
    const result = runRemove(allocator, paths, &.{ "fixture", "--yes" });
    capture.restore();
    if (case == .directory) {
        try std.testing.expectError(error.IsDir, result);
    } else {
        try std.testing.expectEqual(@as(u8, 0), try result);
    }
    var remaining_owner = try models.load(allocator, paths.models_file);
    defer remaining_owner.deinit();
    const remaining = remaining_owner.view();
    try std.testing.expect(models.find(remaining, "fixture") == null);
    try std.testing.expectEqual(@as(usize, if (case == .shared) 1 else 0), remaining.models.len);
    var selected_owner = try config.load(allocator, paths.config_file);
    defer selected_owner.deinit();
    const selected = selected_owner.view();
    try std.testing.expectEqualStrings(if (case == .directory) "fixture" else "", selected.model_id);
    try std.testing.expectEqualStrings(if (case == .directory) model_path else "", selected.model_path);
    const stdout_path = try std.fs.path.join(allocator, &.{ root, "stdout" });
    try std.testing.expectEqualStrings(if (case == .directory) "" else "removed fixture\n", try sys.readFileAlloc(allocator, stdout_path, 1024));
    const state = try sys.pathState(model_path);
    if (case == .normal or case == .missing) {
        try std.testing.expect(state == .not_found);
    } else if (case == .directory) {
        try std.testing.expect(state == .present and state.present.kind == .directory);
    } else {
        try std.testing.expectEqualStrings("model bytes", try sys.readFileAlloc(allocator, model_path, 1024));
    }
}

test "models remove strict baseline normal missing shared external" {
    for ([_]RemoveCase{ .normal, .missing, .shared, .external }) |case| try testRemoveNative(case);
}

test "models remove strict native directory deletion failure" {
    try testRemoveNative(.directory);
}

const RemoveFailure = enum { reload_injected, reload_directory, managed_root, candidate, remaining, delete };

fn testRemoveFailure(failure: RemoveFailure) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    var paths = try testPullPaths(allocator, root);
    paths.models_dir = try std.fs.path.join(allocator, &.{ root, "managed" });
    try xdg.ensureDirs(paths);
    const model_path = try std.fs.path.join(allocator, &.{ paths.models_dir, "fixture.gguf" });
    const other_path = try std.fs.path.join(allocator, &.{ paths.models_dir, "other.gguf" });
    try sys.writeFile(model_path, "model bytes");
    try sys.writeFile(other_path, "other bytes");
    var entries = [_]models.Model{ .{ .id = "fixture", .path = model_path }, .{ .id = "empty" }, .{ .id = "other", .path = other_path } };
    try models.save(paths.models_file, .{ .models = &entries });
    var cfg = config.default();
    cfg.model_id = "fixture";
    cfg.model_path = model_path;
    try config.save(paths.config_file, cfg);
    const config_before = try sys.readFileAlloc(allocator, paths.config_file, 8192);
    const output = try tmp.dir.createFile(sys.io(), "stdout", .{ .read = true });
    defer output.close(sys.io());
    var capture = try TestStdoutCapture.start(output);
    defer capture.restore();
    var faults = fs.Faults{};
    var filesystem = fs.FileSystem.init(sys.io(), sys.cwd(), &faults);
    const realpath_ordinal: usize = switch (failure) {
        .managed_root => 1,
        .candidate => 2,
        .remaining => 3,
        else => 0,
    };
    if (realpath_ordinal != 0) try faults.arm(.realpath, realpath_ordinal, error.InputOutput);
    if (failure == .delete) try faults.arm(.delete, 1, error.AccessDenied);
    const Reload = struct {
        fn injected(_: std.mem.Allocator, _: []const u8) !models.OwnedList {
            return errors.Error.ModelsInvalid;
        }
        fn directory(a: std.mem.Allocator, path: []const u8) !models.OwnedList {
            const saved = try std.fmt.allocPrint(a, "{s}.before-reload", .{path});
            try sys.renameFile(path, saved);
            try sys.makePath(path);
            return models.load(a, path);
        }
    };
    const result = runRemoveWithFileSystem(allocator, paths, &.{ "fixture", "--yes" }, &filesystem, switch (failure) {
        .reload_injected => Reload.injected,
        .reload_directory => Reload.directory,
        else => models.load,
    });
    capture.restore();
    const expected_error = switch (failure) {
        .reload_injected => errors.Error.ModelsInvalid,
        .reload_directory => error.IsDir,
        .delete => error.AccessDenied,
        else => error.InputOutput,
    };
    try std.testing.expectError(expected_error, result);
    try std.testing.expectEqual(@as(usize, if (failure == .delete) 1 else 0), faults.attemptsFor(.delete));
    try std.testing.expectEqual(@as(usize, 0), faults.completedFor(.delete));
    try std.testing.expectEqual(if (failure == .delete) @as(usize, 3) else realpath_ordinal, faults.attemptsFor(.realpath));
    const registry_path = if (failure == .reload_directory) try std.fmt.allocPrint(allocator, "{s}.before-reload", .{paths.models_file}) else paths.models_file;
    var remaining_owner = try models.load(allocator, registry_path);
    defer remaining_owner.deinit();
    const remaining = remaining_owner.view();
    try std.testing.expect(models.find(remaining, "fixture") == null);
    try std.testing.expectEqual(@as(usize, 2), remaining.models.len);
    if (failure == .reload_directory) try std.testing.expectError(error.IsDir, models.load(allocator, paths.models_file));
    try std.testing.expectEqualStrings(config_before, try sys.readFileAlloc(allocator, paths.config_file, 8192));
    try std.testing.expectEqualStrings("model bytes", try sys.readFileAlloc(allocator, model_path, 1024));
    try std.testing.expectEqualStrings("other bytes", try sys.readFileAlloc(allocator, other_path, 1024));
    const stdout_path = try std.fs.path.join(allocator, &.{ root, "stdout" });
    try std.testing.expectEqualStrings("", try sys.readFileAlloc(allocator, stdout_path, 1024));
}

test "models remove strict injected reload failure" {
    try testRemoveFailure(.reload_injected);
}

test "models remove strict native registry directory before reload" {
    try testRemoveFailure(.reload_directory);
}

test "models remove strict managed root realpath failure" {
    try testRemoveFailure(.managed_root);
}

test "models remove strict candidate realpath failure" {
    try testRemoveFailure(.candidate);
}

test "models remove strict remaining reference realpath failure" {
    try testRemoveFailure(.remaining);
}

test "models remove strict injected deletion failure" {
    try testRemoveFailure(.delete);
}

test "a positional pull cannot publish after the model is removed during preparation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(sys.io(), ".", allocator);
    const paths = try testPullPaths(allocator, root);
    const dest = try models.installedPath(allocator, root, "same");
    const old_checksum = try sys.hexSha256(allocator, "old file");
    const new_checksum = try sys.hexSha256(allocator, "staged file");
    try sys.writeFile(dest, "old file");
    var entries = [_]models.Model{.{
        .id = "same",
        .path = dest,
        .download_url = "https://example.invalid/same.gguf",
        .checksum = old_checksum,
    }};
    try models.save(paths.models_file, .{ .models = &entries });
    try config.save(paths.config_file, .{ .model_id = "same", .model_path = dest });
    const output = try tmp.dir.createFile(sys.io(), "stdout", .{});
    defer output.close(sys.io());
    var capture = try TestStdoutCapture.start(output);
    defer capture.restore();

    const Fixture = struct {
        var state: xdg.Paths = undefined;
        fn acquire(a: std.mem.Allocator, m: models.Model, path: []const u8, options: models.AcquireOptions) !?models.StagedModel {
            var stage = try models.StagedModel.begin(a, path);
            errdefer stage.deinit();
            try sys.writeFile(stage.path, "staged file");
            try stage.verify(m.checksum, options.managed);
            try std.testing.expectEqualStrings("old file", try sys.readFileAlloc(a, path, 1024));
            try std.testing.expectEqual(@as(u8, 0), try runRemove(a, state, &.{ "same", "--yes" }));
            return stage;
        }
    };
    Fixture.state = paths;
    try std.testing.expectError(error.ModelSelectionChanged, runPullWithAcquirer(allocator, paths, &.{ "same", "--checksum", new_checksum, "--use" }, Fixture.acquire));
    try std.testing.expect(!sys.exists(dest));
    var registry = try models.load(allocator, paths.models_file);
    defer registry.deinit();
    try std.testing.expect(models.find(registry.view(), "same") == null);
    var cfg = try config.load(allocator, paths.config_file);
    defer cfg.deinit();
    try std.testing.expectEqualStrings("", cfg.view().model_id);
    try std.testing.expectEqualStrings("", cfg.view().model_path);
}

test "import of its own installed path publishes the verified stage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = sys.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    const paths = try testPullPaths(allocator, root);
    const dest = try models.installedPath(allocator, root, "same");
    try sys.writeFile(dest, "installed bytes");
    const checksum = try sys.hexSha256(allocator, "installed bytes");
    const previous = try sys.cwd().openFile(io, dest, .{});
    defer previous.close(io);
    const output = try tmp.dir.createFile(io, "stdout", .{});
    defer output.close(io);
    var capture = try TestStdoutCapture.start(output);
    defer capture.restore();

    try std.testing.expectEqual(@as(u8, 0), try runImport(allocator, paths, &.{ "--id", "same", "--path", dest, "--checksum", checksum, "--use" }));
    const current = try sys.cwd().statFile(io, dest, .{});
    try std.testing.expect(current.inode != (try previous.stat(io)).inode);
    try models.verifySha256(dest, checksum);
    var registry = try models.load(allocator, paths.models_file);
    defer registry.deinit();
    try std.testing.expectEqualStrings(checksum, models.find(registry.view(), "same").?.checksum);
    var cfg = try config.load(allocator, paths.config_file);
    defer cfg.deinit();
    try std.testing.expectEqualStrings(dest, cfg.view().model_path);
}

test "self import refuses a staged copy after registry or source changes" {
    const io = sys.io();
    const Fixture = struct {
        var paths: xdg.Paths = undefined;
        var replacement: []const u8 = undefined;
        var change: enum { replace, remove, metadata, rewrite } = undefined;

        fn stage(a: std.mem.Allocator, src: []const u8, dest: []const u8, checksum: []const u8) !models.StagedModel {
            var staged = try models.stageLocalFile(a, src, dest, checksum);
            errdefer staged.deinit();
            switch (change) {
                .replace => try std.testing.expectEqual(@as(u8, 0), try runImport(a, paths, &.{ "--id", "same", "--path", replacement })),
                .remove => try std.testing.expectEqual(@as(u8, 0), try runRemove(a, paths, &.{ "same", "--yes" })),
                .metadata => {
                    var entries = try models.load(a, paths.models_file);
                    defer entries.deinit();
                    var changed = models.find(entries.view(), "same").?;
                    changed.notes = "edited during staging";
                    try models.upsert(a, paths.models_file, changed);
                },
                .rewrite => try sys.writeFile(dest, "mid"),
            }
            return staged;
        }
    };

    for ([_]@TypeOf(Fixture.change){ .replace, .remove, .metadata, .rewrite }) |change| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        const paths = try testPullPaths(allocator, root);
        const dest = try models.installedPath(allocator, root, "same");
        const original = try std.fs.path.join(allocator, &.{ root, "original.gguf" });
        const replacement = try std.fs.path.join(allocator, &.{ root, "replacement.gguf" });
        // Match registry fields and size for .replace to exercise inode identity.
        try sys.writeFile(original, "old");
        try sys.writeFile(replacement, "new");
        const output = try tmp.dir.createFile(io, "stdout", .{});
        defer output.close(io);
        var capture = try TestStdoutCapture.start(output);
        defer capture.restore();
        try std.testing.expectEqual(@as(u8, 0), try runImport(allocator, paths, &.{ "--id", "same", "--path", original, "--use" }));
        // Use an alternate path for the same installed inode.
        try tmp.dir.symLink(io, "same.gguf", "alias.gguf", .{});
        const alias = try std.fs.path.join(allocator, &.{ root, "alias.gguf" });
        Fixture.paths = paths;
        Fixture.replacement = replacement;
        Fixture.change = change;
        try std.testing.expectError(error.ModelSelectionChanged, runImportWithStager(
            allocator,
            paths,
            &.{ "--id", "same", "--path", alias, "--use" },
            Fixture.stage,
        ));
        const expected = switch (change) {
            .replace => "new",
            .remove => null,
            .metadata => "old",
            .rewrite => "mid",
        };
        var registry = try models.load(allocator, paths.models_file);
        defer registry.deinit();
        if (expected) |bytes| {
            try std.testing.expectEqualStrings(bytes, try sys.readFileAlloc(allocator, dest, 1024));
            if (change == .metadata)
                try std.testing.expectEqualStrings("edited during staging", models.find(registry.view(), "same").?.notes);
        } else {
            try std.testing.expect(!sys.exists(dest));
            try std.testing.expect(models.find(registry.view(), "same") == null);
            var cfg = try config.load(allocator, paths.config_file);
            defer cfg.deinit();
            try std.testing.expectEqualStrings("", cfg.view().model_path);
        }
    }
}

test "pull rechecks invalid or dangling config after staging even without use" {
    const io = sys.io();
    const Fixture = struct {
        var path: []const u8 = undefined;
        var lost_target: bool = false;
        const invalid = "unknown_key = true\n";
        const bytes = "incoming bytes";

        fn acquire(a: std.mem.Allocator, m: models.Model, dest: []const u8, options: models.AcquireOptions) !?models.StagedModel {
            var staged = try models.StagedModel.begin(a, dest);
            errdefer staged.deinit();
            try sys.writeFile(staged.path, bytes);
            try staged.verify(m.checksum, options.managed);
            if (lost_target) {
                try sys.cwd().deleteFile(sys.io(), path);
            } else {
                try sys.writeFile(path, invalid);
            }
            return staged;
        }
    };

    for ([_]bool{ false, true }) |lost_target| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        const paths = try testPullPaths(allocator, root);
        const selected = try std.fs.path.join(allocator, &.{ root, "selected.gguf" });
        const target = if (lost_target) try std.fs.path.join(allocator, &.{ root, "settings.toml" }) else paths.config_file;
        try sys.writeFile(selected, "selected model");
        try config.save(target, .{ .model_id = "selected", .model_path = selected });
        if (lost_target) try tmp.dir.symLink(io, "settings.toml", "config.toml", .{});
        try models.ensure(paths.models_file);

        Fixture.path = target;
        Fixture.lost_target = lost_target;
        const checksum = try sys.hexSha256(allocator, Fixture.bytes);
        try std.testing.expectError(if (lost_target) error.FileNotFound else error.ConfigInvalid, runPullWithAcquirer(
            allocator,
            paths,
            &.{ "--model-url", "https://example.invalid/incoming.gguf", "--id", "incoming", "--checksum", checksum, "--output", selected },
            Fixture.acquire,
        ));
        try std.testing.expectEqualStrings("selected model", try sys.readFileAlloc(allocator, selected, 1024));
        if (lost_target) {
            var link: [64]u8 = undefined;
            const len = try tmp.dir.readLink(io, "config.toml", &link);
            try std.testing.expectEqualStrings("settings.toml", link[0..len]);
        } else {
            try std.testing.expectEqualStrings(Fixture.invalid, try sys.readFileAlloc(allocator, paths.config_file, 1024));
        }
        var registry = try models.load(allocator, paths.models_file);
        defer registry.deinit();
        try std.testing.expect(models.find(registry.view(), "incoming") == null);
    }
}

test "stored-path spelling retains distinct symlink and parent components" {
    try std.testing.expect(sameStoredPath("/X/current.gguf", "/X/./current.gguf"));
    try std.testing.expect(sameStoredPath("/X//current.gguf", "/./X/current.gguf"));
    try std.testing.expect(!sameStoredPath("/X/link/current.gguf", "/X/current.gguf"));
    try std.testing.expect(!sameStoredPath("/X/link/../current.gguf", "/X/current.gguf"));
    try std.testing.expect(sameStoredPath("current.gguf", "./current.gguf"));
    try std.testing.expect(!sameStoredPath("current.gguf", "/current.gguf"));
}
