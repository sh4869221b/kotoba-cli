const std = @import("std");
const config = @import("../config.zig");
const fs = @import("../fs.zig");
const errors = @import("../errors.zig");
const models = @import("../models.zig");
const sys = @import("../sys.zig");
const xdg = @import("../xdg.zig");
const args = @import("args.zig");

pub fn run(allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    if (cmd_args.len < 1) return errors.Error.InvalidArguments;
    const sub = cmd_args[0];
    if (std.mem.eql(u8, sub, "list")) {
        if (cmd_args.len != 1) return errors.Error.InvalidArguments;
        const cfg = try loadConfigOrDefault(allocator, paths.config_file);
        const list = try models.loadReadOnly(allocator, paths.models_file);
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
    try validateCommandId(cmd_args[0]);
    const list = try models.loadReadOnly(allocator, paths.models_file);
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
    sys.stdoutPrint("id: {s}\nname: {s}\nprofile: {s}\nformat: {s}\nquantization: {s}\ncontext_length: {d}\npath: {s}\ndownload_url: {s}\nsource_url: {s}\nchecksum: {s}\nlicense: {s}\nrecommended: {}\nnotes: {s}\n", .{
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
    if (!sys.exists(source_path)) return errors.Error.ModelMissing;
    if (checksum.len > 0) try models.verifySha256(allocator, source_path, checksum);
    const dest_path = try models.installedPath(allocator, paths.models_dir, id);
    _ = try models.loadReadOnly(allocator, paths.models_file);
    if (use_model) _ = try loadConfigOrDefault(allocator, paths.config_file);
    try xdg.ensureDirs(paths);
    try models.ensure(paths.models_file);
    if (!std.mem.eql(u8, source_path, dest_path)) {
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
    return runPullWithAcquirer(allocator, paths, cmd_args, models.acquire);
}

fn runPullWithAcquirer(
    allocator: std.mem.Allocator,
    paths: xdg.Paths,
    cmd_args: []const []const u8,
    acquirer: *const fn (std.mem.Allocator, models.Model, []const u8, bool) anyerror!void,
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
    if (output_path.len > 0) try models.validateGgufPath(output_path);
    var m: models.Model = .{};
    if (hf_repo.len > 0) {
        if (model_url.len > 0 or positional_id.len > 0) return errors.Error.InvalidArguments;
        const hf = try models.parseHfRepo(hf_repo);
        if (id.len == 0) id = try models.defaultIdFromHf(allocator, hf);
        try validateCommandId(id);
        if (hf_file.len > 0) try models.validateSingleHfGgufFilename(hf_file);
        _ = try models.loadReadOnly(allocator, paths.models_file);
        if (use_model) _ = try loadConfigOrDefault(allocator, paths.config_file);
        const file = try models.resolveHfFile(allocator, hf, hf_file);
        const url = try models.hfDownloadUrl(allocator, hf.repo, file);
        if (output_path.len == 0) output_path = try models.installedPath(allocator, paths.models_dir, id);
        m = .{ .id = id, .name = id, .profile = "huggingface", .languages_en = true, .languages_ja = true, .format = "gguf", .quantization = hf.quant, .path = output_path, .download_url = url, .checksum = checksum, .notes = "Downloaded from Hugging Face." };
    } else if (model_url.len > 0) {
        if (positional_id.len > 0 or id.len == 0) return errors.Error.InvalidArguments;
        const uri = try models.url.parseRemote(model_url);
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return errors.Error.InvalidArguments;
        if (checksum.len == 0) return errors.Error.InvalidArguments;
        try models.validateId(id);
        _ = try models.loadReadOnly(allocator, paths.models_file);
        if (use_model) _ = try loadConfigOrDefault(allocator, paths.config_file);
        if (output_path.len == 0) output_path = try models.installedPath(allocator, paths.models_dir, id);
        m = .{ .id = id, .name = id, .profile = "url", .languages_en = true, .languages_ja = true, .format = "gguf", .path = output_path, .download_url = model_url, .checksum = checksum, .notes = "Downloaded from direct HTTPS URL." };
    } else {
        if (positional_id.len == 0 or id.len > 0) return errors.Error.InvalidArguments;
        try validateCommandId(positional_id);
        if (use_model) _ = try loadConfigOrDefault(allocator, paths.config_file);
        const list = try models.load(allocator, paths.models_file);
        m = models.find(list, positional_id) orelse return errors.Error.ModelRegistryInvalid;
        if (models.url.isRemote(m.download_url)) {
            const uri = try models.url.parseRemote(m.download_url);
            if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return errors.Error.InvalidArguments;
        }
        if (models.url.reusableUrl(m.download_url).len == 0) return errors.Error.ModelSourceRequired;
        id = m.id;
        if (output_path.len == 0) output_path = if (m.path.len > 0) m.path else try models.installedPath(allocator, paths.models_dir, id);
        m.path = output_path;
        if (checksum.len > 0) m.checksum = checksum;
    }
    try models.validateGgufPath(output_path);
    var request_model = m;
    if (models.url.isRemote(m.download_url)) {
        request_model.download_url = try models.url.requestUrl(m.download_url);
        m.source_url = try models.url.sourceIdentity(allocator, m.download_url);
    }
    m.download_url = models.url.reusableUrl(m.download_url);
    try xdg.ensureDirs(paths);
    try models.ensure(paths.models_file);
    try acquirer(allocator, request_model, output_path, false);
    m.path = output_path;
    try models.verifyModel(allocator, m);
    try models.upsert(allocator, paths.models_file, m);
    if (use_model) try selectModel(allocator, paths, id, output_path);
    sys.stdoutPrint("pulled {s}\n", .{id});
    return 0;
}

fn runUse(allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    if (cmd_args.len != 1) return errors.Error.InvalidArguments;
    try validateCommandId(cmd_args[0]);
    _ = try loadConfigOrDefault(allocator, paths.config_file);
    const list = try models.load(allocator, paths.models_file);
    const m = models.find(list, cmd_args[0]) orelse return errors.Error.ModelRegistryInvalid;
    try models.verifyModel(allocator, m);
    try xdg.ensureDirs(paths);
    try selectModel(allocator, paths, m.id, m.path);
    sys.stdoutPrint("using {s}\n", .{m.id});
    return 0;
}

fn runVerify(allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    if (cmd_args.len > 1) return errors.Error.InvalidArguments;
    if (cmd_args.len == 1) try validateCommandId(cmd_args[0]);
    const cfg = try loadConfigOrDefault(allocator, paths.config_file);
    const id = if (cmd_args.len == 1) cmd_args[0] else cfg.model_id;
    if (id.len == 0) return errors.Error.ModelNotSelected;
    try validateCommandId(id);
    const list = try models.loadReadOnly(allocator, paths.models_file);
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
    var filesystem = fs.FileSystem.init(sys.io(), sys.cwd(), null);
    return runRemoveWithFileSystem(allocator, paths, cmd_args, &filesystem, models.load);
}

// The filesystem and reload callback are borrowed only for this command invocation.
fn runRemoveWithFileSystem(allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8, filesystem: *fs.FileSystem, reload: *const fn (std.mem.Allocator, []const u8) anyerror!models.List) !u8 {
    if (cmd_args.len != 2 or !std.mem.eql(u8, cmd_args[1], "--yes")) return errors.Error.InvalidArguments;
    const id = cmd_args[0];
    try validateCommandId(id);
    var cfg = try loadConfigOrDefault(allocator, paths.config_file);
    const list = try models.load(allocator, paths.models_file);
    _ = models.find(list, id) orelse return errors.Error.ModelRegistryInvalid;
    try xdg.ensureDirs(paths);
    const removed = try models.removeById(allocator, paths.models_file, id);
    const remaining = try reload(allocator, paths.models_file);
    if (try canDeleteManagedModelPath(allocator, paths.models_dir, removed.path, remaining, filesystem)) {
        _ = try filesystem.removeFileIfExists(removed.path);
    }
    if (std.mem.eql(u8, cfg.model_id, id)) {
        cfg.model_id = "";
        cfg.model_path = "";
        try config.save(paths.config_file, cfg);
    }
    sys.stdoutPrint("removed {s}\n", .{id});
    return 0;
}

fn validateCommandId(id: []const u8) !void {
    if (std.mem.startsWith(u8, id, "-")) return errors.Error.InvalidArguments;
    try models.validateId(id);
}

fn canDeleteManagedModelPath(allocator: std.mem.Allocator, models_dir: []const u8, path: []const u8, remaining: models.List, filesystem: *fs.FileSystem) !bool {
    const real_models_dir = (try filesystem.realPathIfExistsAlloc(allocator, models_dir)) orelse return false;
    defer allocator.free(real_models_dir);
    const real_path = (try filesystem.realPathIfExistsAlloc(allocator, path)) orelse return false;
    defer allocator.free(real_path);
    if (real_path.len <= real_models_dir.len) return false;
    if (!std.mem.startsWith(u8, real_path, real_models_dir)) return false;
    if (real_path[real_models_dir.len] != std.fs.path.sep) return false;
    for (remaining.models) |m| {
        if (m.path.len == 0) continue;
        const other_real_path = (try filesystem.realPathIfExistsAlloc(allocator, m.path)) orelse continue;
        defer allocator.free(other_real_path);
        if (std.mem.eql(u8, real_path, other_real_path)) return false;
    }
    return true;
}

fn loadConfigOrDefault(allocator: std.mem.Allocator, path: []const u8) !config.Config {
    return config.load(allocator, path) catch |err| switch (err) {
        error.NotInitialized => config.default(),
        else => return err,
    };
}

pub fn selectModel(allocator: std.mem.Allocator, paths: xdg.Paths, id: []const u8, model_path: []const u8) !void {
    var cfg = try loadConfigOrDefault(allocator, paths.config_file);
    cfg.model_id = try allocator.dupe(u8, id);
    cfg.model_path = try allocator.dupe(u8, model_path);
    try config.save(paths.config_file, cfg);
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
        fn acquire(a: std.mem.Allocator, m: models.Model, dest: []const u8, skip: bool) !void {
            try std.testing.expectEqualStrings(expected, m.download_url);
            try std.testing.expect(!skip);
            try @import("../models/install.zig").acquireWithDownloader(a, m, dest, skip, download);
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
        const saved = models.find(try models.load(allocator, paths.models_file), "signed36").?;
        try std.testing.expectEqualStrings(Fixture.identity, saved.source_url);
        try std.testing.expectEqualStrings(if (std.mem.indexOfScalar(u8, source, '?') == null) Fixture.identity else "", saved.download_url);
        try std.testing.expectEqualStrings(checksum, saved.checksum);
        try std.testing.expectEqualStrings(dest, saved.path);
        try std.testing.expectEqualStrings(Fixture.bytes, try sys.readFileAlloc(allocator, dest, 1024));
        try models.verifySha256(allocator, dest, checksum);
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
    try models.verifySha256(allocator, dest, checksum);
    Fixture.expected = "https://huggingface.co/example/repo/resolve/main/model.gguf";
    try std.testing.expectEqual(@as(u8, 0), try runPullWithAcquirer(allocator, paths, &.{ "--hf-repo", "example/repo", "--hf-file", "model.gguf", "--id", "hf36", "--checksum", checksum }, Fixture.acquire));
    try std.testing.expectEqual(@as(usize, 5), Fixture.calls);
    const hf_saved = models.find(try models.load(allocator, paths.models_file), "hf36").?;
    try std.testing.expectEqualStrings(Fixture.expected, hf_saved.download_url);
    try std.testing.expectEqualStrings(Fixture.expected, hf_saved.source_url);
    try models.verifySha256(allocator, hf_saved.path, checksum);
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
        fn acquire(_: std.mem.Allocator, _: models.Model, _: []const u8, _: bool) !void {
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
        try models.verifySha256(allocator, dest, checksum);
    }
    const oversize = try allocator.alloc(u8, models.url.max_length + 1);
    @memset(oversize, 'a');
    @memcpy(oversize[0.."https://models.example.invalid/".len], "https://models.example.invalid/");
    for ([_][]const u8{ "https://@models.example.invalid/a", "https:///a", "https://models.example.invalid/a#\t", oversize }) |source| {
        try std.testing.expectError(error.InvalidArguments, runPullWithAcquirer(allocator, paths, &.{ "--model-url", source, "--id", "signed36", "--checksum", checksum }, Fixture.acquire));
        try std.testing.expectEqual(@as(usize, 0), Fixture.calls);
        try models.verifySha256(allocator, dest, checksum);
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
            sys.stdoutWrite("before error\n");
            return error.ExpectedFailure;
        }
    };
    try std.testing.expectError(error.ExpectedFailure, Fixture.fail(inner));
    sys.stdoutWrite("restored\n");
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
            fn acquire(_: std.mem.Allocator, _: models.Model, _: []const u8, _: bool) !void {
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
                fn acquire(_: std.mem.Allocator, _: models.Model, path: []const u8, _: bool) !void {
                    calls += 1;
                    try sys.writeFile(path, "downloaded fixture");
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
                try std.testing.expect(models.find(try models.load(allocator, paths.models_file), "fixture") == null);
                if (!existing_config) {
                    try std.testing.expect(!sys.exists(paths.config_file));
                    continue;
                }
            }
            const cfg = try config.load(allocator, paths.config_file);
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
    const remaining = try models.load(allocator, paths.models_file);
    try std.testing.expect(models.find(remaining, "fixture") == null);
    try std.testing.expectEqual(@as(usize, if (case == .shared) 1 else 0), remaining.models.len);
    const selected = try config.load(allocator, paths.config_file);
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
        fn injected(_: std.mem.Allocator, _: []const u8) !models.List {
            return errors.Error.ModelsInvalid;
        }
        fn directory(a: std.mem.Allocator, path: []const u8) !models.List {
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
    const remaining = try models.load(allocator, registry_path);
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
