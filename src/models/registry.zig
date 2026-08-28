const std = @import("std");
const errors = @import("../errors.zig");
const sys = @import("../sys.zig");
const strict = @import("../strict_toml.zig");
const types = @import("types.zig");
const url = @import("../url.zig");
const validation = @import("validation.zig");

pub const Model = types.Model;
pub const List = types.List;
pub const OwnedList = types.OwnedList;
pub const OwnedModel = types.OwnedModel;

pub fn defaultTemplate() []const u8 {
    return
    \\# Kotoba model candidates.
    \\# v1.0 does not embed a real model URL unless source, license, and checksum are verified.
    \\# The custom local model path flow is the reliable setup path.
    \\
    \\[[models]]
    \\id = "custom"
    \\name = "Custom local GGUF model"
    \\profile = "custom"
    \\languages = ["en", "ja"]
    \\format = "gguf"
    \\quantization = ""
    \\context_length = 4096
    \\size = ""
    \\download_url = ""
    \\checksum = ""
    \\license = ""
    \\recommended = false
    \\notes = "Set model_path during init or config."
    \\
    \\[[models]]
    \\id = "example-light"
    \\name = "Example Light Model Placeholder"
    \\profile = "default"
    \\languages = ["en", "ja"]
    \\format = "gguf"
    \\quantization = "Q4_K_M"
    \\context_length = 4096
    \\size = "small"
    \\download_url = ""
    \\checksum = ""
    \\license = ""
    \\recommended = true
    \\notes = "Placeholder only. Add a verified download_url and checksum before use."
    \\
    ;
}

pub fn ensure(path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var owner = load(arena.allocator(), path) catch |err| switch (err) {
        error.NotInitialized => {
            try sys.writeFile(path, defaultTemplate());
            return;
        },
        else => return err,
    };
    defer owner.deinit();
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) !OwnedList {
    const data = sys.readFileAlloc(allocator, path, 2 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return errors.Error.NotInitialized,
        else => return err,
    };
    defer allocator.free(data);
    return parse(allocator, data);
}

pub fn loadReadOnly(allocator: std.mem.Allocator, path: []const u8) !OwnedList {
    const data = sys.readFileAlloc(allocator, path, 2 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return parse(allocator, defaultTemplate()),
        else => return err,
    };
    defer allocator.free(data);
    return parse(allocator, data);
}

const Field = enum {
    id,
    name,
    profile,
    languages,
    format,
    quantization,
    context_length,
    size,
    path,
    download_url,
    source_url,
    checksum,
    license,
    recommended,
    notes,
};

pub fn parse(allocator: std.mem.Allocator, data: []const u8) !OwnedList {
    return parseStrict(allocator, data) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ModelsSchemaUnsupported => error.ModelsSchemaUnsupported,
        else => error.ModelsInvalid,
    };
}

fn parseStrict(allocator: std.mem.Allocator, data: []const u8) !OwnedList {
    var items = std.array_list.Managed(Model).init(allocator);
    errdefer {
        freeParsedModels(allocator, items.items);
        items.deinit();
    }
    // IDs borrow decoded model strings; the set owns only its backing storage.
    var ids = std.StringHashMap(void).init(allocator);
    defer ids.deinit();
    var current: ?OwnedModel = null;
    errdefer if (current) |*m| m.deinit();
    var seen = [_]bool{false} ** std.meta.fields(Field).len;
    var reader: strict.Reader = .{ .data = data };
    while (try reader.next()) |line| {
        const pair = switch (line) {
            .header => |header| {
                if (strict.isSchemaMarker(header.name)) return error.ModelsSchemaUnsupported;
                if (!header.array or !std.mem.eql(u8, header.name, "models")) return error.Invalid;
                try finishModel(&items, &ids, &current);
                current = try OwnedModel.clone(allocator, .{});
                @memset(&seen, false);
                continue;
            },
            .pair => |pair| pair,
        };
        if (strict.isSchemaMarker(pair.key)) return error.ModelsSchemaUnsupported;
        const model = if (current) |*m| &m.value else return error.Invalid;
        const field = std.meta.stringToEnum(Field, pair.key) orelse return error.Invalid;
        if (seen[@intFromEnum(field)]) return error.Invalid;
        seen[@intFromEnum(field)] = true;
        switch (field) {
            .languages => {
                const languages = try strict.parseLanguages(allocator, pair.value);
                model.languages_en = languages.en;
                model.languages_ja = languages.ja;
            },
            .context_length => model.context_length = try strict.parseInt(u32, pair.value),
            .recommended => model.recommended = try strict.parseBool(pair.value),
            inline else => |tag| try replaceString(allocator, &@field(model, @tagName(tag)), pair.value),
        }
    }
    try finishModel(&items, &ids, &current);
    return .{ .allocator = allocator, .value = .{ .models = try items.toOwnedSlice() } };
}

fn finishModel(items: *std.array_list.Managed(Model), ids: *std.StringHashMap(void), current: *?OwnedModel) !void {
    const owner = current.* orelse return;
    const model = owner.view();
    try validation.validateId(model.id);
    const entry = try ids.getOrPut(model.id);
    if (entry.found_existing) return error.Invalid;
    try items.append(model);
    current.* = null;
}

/// Returns a view borrowed until its list owner is mutated or deinitialized.
pub fn find(list: List, id: []const u8) ?Model {
    for (list.models) |m| {
        if (std.mem.eql(u8, m.id, id)) return m;
    }
    return null;
}

pub fn installedPath(allocator: std.mem.Allocator, models_dir: []const u8, id: []const u8) ![]const u8 {
    try validation.validateId(id);
    const filename = try std.fmt.allocPrint(allocator, "{s}.gguf", .{id});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ models_dir, filename });
}

pub fn upsert(allocator: std.mem.Allocator, registry_path: []const u8, model: Model) !void {
    try validation.validateId(model.id);
    var list = try load(allocator, registry_path);
    defer list.deinit();
    var replacement = try OwnedModel.clone(allocator, model);
    var transferred = false;
    defer if (!transferred) replacement.deinit();
    for (list.value.models) |*m| {
        if (std.mem.eql(u8, m.id, model.id)) {
            var old: OwnedModel = .{ .allocator = allocator, .value = m.* };
            m.* = replacement.value;
            transferred = true;
            old.deinit();
            break;
        }
    }
    if (!transferred) {
        var items = std.array_list.Managed(Model).init(allocator);
        defer items.deinit();
        try items.appendSlice(list.value.models);
        try items.append(replacement.value);
        const next = try items.toOwnedSlice();
        allocator.free(list.value.models);
        list.value.models = next;
        transferred = true;
    }
    try saveWithAllocator(allocator, registry_path, list.view());
}

/// Transfers an independent clone to the caller only after save succeeds.
pub fn removeById(allocator: std.mem.Allocator, registry_path: []const u8, id: []const u8) !OwnedModel {
    try validation.validateId(id);
    var list = try load(allocator, registry_path);
    defer list.deinit();
    const found = find(list.view(), id) orelse return errors.Error.ModelRegistryInvalid;
    var removed = try OwnedModel.clone(allocator, found);
    errdefer removed.deinit();
    var items = std.array_list.Managed(Model).init(allocator);
    defer items.deinit();
    for (list.view().models) |m| {
        if (!std.mem.eql(u8, m.id, id)) try items.append(m);
    }
    try saveWithAllocator(allocator, registry_path, .{ .models = items.items });
    return removed;
}

pub fn save(path: []const u8, list: List) !void {
    return saveWithAllocator(std.heap.page_allocator, path, list);
}

fn saveWithAllocator(allocator: std.mem.Allocator, path: []const u8, list: List) !void {
    var out = strict.Buffer.init(allocator);
    defer out.deinit();
    validateModels(out.allocator, list) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ModelsInvalid,
    };
    try out.appendSlice("# Kotoba model registry.\n\n");
    for (list.models) |m| {
        try appendModel(&out, m);
    }
    try sys.writeFile(path, out.items);
}

fn validateModels(allocator: std.mem.Allocator, list: List) !void {
    var ids = std.StringHashMap(void).init(allocator);
    defer ids.deinit();
    for (list.models) |m| {
        try validation.validateId(m.id);
        const entry = try ids.getOrPut(m.id);
        if (entry.found_existing) return error.Invalid;
        inline for (std.meta.fields(Model)) |field| {
            if (field.type == []const u8) try strict.validateString(@field(m, field.name));
        }
    }
}

fn replaceString(allocator: std.mem.Allocator, field: *[]const u8, value: []const u8) !void {
    const next = try strict.parseString(allocator, value);
    allocator.free(field.*);
    field.* = next;
}

fn freeParsedModels(allocator: std.mem.Allocator, models: []Model) void {
    for (models) |m| {
        var owner: OwnedModel = .{ .allocator = allocator, .value = m };
        owner.deinit();
    }
}

fn appendModel(out: *std.array_list.Managed(u8), m: Model) !void {
    const existing_source = try url.sourceIdentity(out.allocator, m.source_url);
    defer out.allocator.free(existing_source);
    const source = if (existing_source.len > 0) existing_source else try url.sourceIdentity(out.allocator, m.download_url);
    defer if (existing_source.len == 0) out.allocator.free(source);
    try out.appendSlice("[[models]]\n");
    try appendStringField(out, "id", m.id);
    try appendStringField(out, "name", m.name);
    try appendStringField(out, "profile", m.profile);
    try out.appendSlice("languages = [");
    if (m.languages_en) try out.appendSlice("\"en\"");
    if (m.languages_en and m.languages_ja) try out.appendSlice(", ");
    if (m.languages_ja) try out.appendSlice("\"ja\"");
    try out.appendSlice("]\n");
    try appendStringField(out, "format", m.format);
    try appendStringField(out, "quantization", m.quantization);
    try appendFmt(out, "context_length = {d}\n", .{m.context_length});
    try appendStringField(out, "size", m.size);
    try appendStringField(out, "path", m.path);
    try appendStringField(out, "download_url", url.reusableUrl(m.download_url));
    try appendStringField(out, "source_url", source);
    try appendStringField(out, "checksum", m.checksum);
    try appendStringField(out, "license", m.license);
    try appendFmt(out, "recommended = {}\n", .{m.recommended});
    try appendStringField(out, "notes", m.notes);
    try out.appendSlice("\n");
}

fn appendStringField(out: *std.array_list.Managed(u8), key: []const u8, value: []const u8) !void {
    try out.appendSlice(key);
    try out.appendSlice(" = ");
    try strict.appendString(out, value);
    try out.appendSlice("\n");
}

fn appendFmt(out: *std.array_list.Managed(u8), comptime fmt: []const u8, args: anytype) !void {
    try out.print(fmt, args);
}

test "parse model list" {
    var list_owner = try parse(std.testing.allocator, defaultTemplate());
    defer list_owner.deinit();
    const list = list_owner.view();
    try std.testing.expect(list.models.len >= 1);
    try std.testing.expect(find(list, "custom") != null);
}

test "strict registry baseline preserves plain fields defaults and raw URLs" {
    const allocator = std.testing.allocator;
    var list_owner = try parse(allocator,
        \\[[models]]
        \\id = "baseline61"
        \\name = "Baseline model"
        \\profile = "technical"
        \\languages = ["en", "ja"]
        \\format = "gguf"
        \\quantization = "Q4_K_M"
        \\context_length = 8192
        \\size = "small"
        \\path = "/local/model?#.gguf"
        \\download_url = "https://models.example.invalid/model.gguf?token=synthetic"
        \\source_url = "https://origin.example.invalid/source"
        \\checksum = "abc123"
        \\license = "MIT"
        \\recommended = true
        \\notes = "Keep descriptive metadata."
        \\[[models]]
        \\id = "defaults61"
    );
    defer list_owner.deinit();
    const list = list_owner.view();
    try std.testing.expectEqual(@as(usize, 2), list.models.len);
    try std.testing.expectEqualDeep(Model{
        .id = "baseline61",
        .name = "Baseline model",
        .profile = "technical",
        .languages_en = true,
        .languages_ja = true,
        .format = "gguf",
        .quantization = "Q4_K_M",
        .context_length = 8192,
        .size = "small",
        .path = "/local/model?#.gguf",
        .download_url = "https://models.example.invalid/model.gguf?token=synthetic",
        .source_url = "https://origin.example.invalid/source",
        .checksum = "abc123",
        .license = "MIT",
        .recommended = true,
        .notes = "Keep descriptive metadata.",
    }, list.models[0]);
    try std.testing.expectEqualDeep(Model{ .id = "defaults61" }, list.models[1]);
}

test "load read only uses the default template only for missing registries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const missing_path = try std.fs.path.join(allocator, &.{ root, "missing", "models.toml" });

    var missing_owner = try loadReadOnly(allocator, missing_path);
    defer missing_owner.deinit();
    const missing = missing_owner.view();
    try std.testing.expectEqual(@as(usize, 2), missing.models.len);
    try std.testing.expect(find(missing, "custom") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "missing", .{}));

    const registry_path = try std.fs.path.join(allocator, &.{ root, "models.toml" });
    try sys.writeFile(registry_path, defaultTemplate());
    var existing_owner = try loadReadOnly(allocator, registry_path);
    defer existing_owner.deinit();
    const existing = existing_owner.view();
    try std.testing.expectEqual(@as(usize, 2), existing.models.len);
    try std.testing.expect(find(existing, "example-light") != null);

    const directory_path = try std.fs.path.join(allocator, &.{ root, "directory" });
    try sys.makePath(directory_path);
    try std.testing.expectError(error.IsDir, loadReadOnly(allocator, directory_path));
}

test "strict registry loaders distinguish missing files and ensure creates defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const path = try std.fs.path.join(allocator, &.{ root, "missing", "models.toml" });
    try std.testing.expectError(error.NotInitialized, load(allocator, path));
    var defaults = try loadReadOnly(allocator, path);
    defer defaults.deinit();
    try std.testing.expectEqual(@as(usize, 2), defaults.view().models.len);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "missing", .{}));
    try std.testing.expectError(error.FileNotFound, ensure(path));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "missing", .{}));
    try tmp.dir.createDir(std.testing.io, "missing", .default_dir);
    try ensure(path);
    try std.testing.expectEqualStrings(defaultTemplate(), try sys.readFileAlloc(allocator, path, 4096));
}

test "strict registry loaders and ensure preserve directories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const marker = try std.fs.path.join(allocator, &.{ root, "keep" });
    try sys.writeFile(marker, "untouched");
    try std.testing.expectError(error.IsDir, ensure(root));
    try std.testing.expectError(error.IsDir, load(allocator, root));
    try std.testing.expectError(error.IsDir, loadReadOnly(allocator, root));
    try std.testing.expectEqualStrings("untouched", try sys.readFileAlloc(allocator, marker, 32));
    try expectOnlyEntry(tmp.dir, "keep");
}

test "strict registry loaders and ensure preserve oversized files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const path = try std.fs.path.join(allocator, &.{ root, "models.toml" });
    const data = try allocator.alloc(u8, 2097153);
    @memset(data, ' ');
    try sys.writeFile(path, data);
    try std.testing.expectError(error.StreamTooLong, ensure(path));
    try std.testing.expectError(error.StreamTooLong, load(allocator, path));
    try std.testing.expectError(error.StreamTooLong, loadReadOnly(allocator, path));
    try std.testing.expectEqualStrings(data, try sys.readFileAlloc(allocator, path, data.len + 1));
    try expectOnlyEntry(tmp.dir, "models.toml");
}

test "strict registry ensure preserves existing bytes and loaders preserve allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const path = try std.fs.path.join(allocator, &.{ root, "models.toml" });
    const data = "# keep formatting\n[[models]]\nid = \"existing\"\n";
    try sys.writeFile(path, data);
    try ensure(path);
    try std.testing.expectEqualStrings(data, try sys.readFileAlloc(allocator, path, 1024));
    var existing = try load(allocator, path);
    defer existing.deinit();
    try std.testing.expectEqualStrings("existing", existing.view().models[0].id);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, load(failing.allocator(), path));
    try std.testing.expectError(error.OutOfMemory, loadReadOnly(failing.allocator(), path));
    try expectOnlyEntry(tmp.dir, "models.toml");
}

test "strict registry loaders and ensure preserve native access denied" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    if (std.os.linux.getuid() == 0) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const path = try std.fs.path.join(allocator, &.{ root, "models.toml" });
    const data = "[[models]]\nid = \"private\"\n";
    try sys.writeFile(path, data);
    const file = try tmp.dir.openFile(std.testing.io, "models.toml", .{});
    defer file.close(std.testing.io);
    try file.setPermissions(std.testing.io, .fromMode(0));
    defer file.setPermissions(std.testing.io, .fromMode(0o600)) catch unreachable;
    try std.testing.expectError(error.AccessDenied, ensure(path));
    try std.testing.expectError(error.AccessDenied, load(allocator, path));
    try std.testing.expectError(error.AccessDenied, loadReadOnly(allocator, path));
    try file.setPermissions(std.testing.io, .fromMode(0o600));
    try std.testing.expectEqualStrings(data, try sys.readFileAlloc(allocator, path, 1024));
    try expectOnlyEntry(tmp.dir, "models.toml");
}

fn expectOnlyEntry(dir: std.Io.Dir, name: []const u8) !void {
    var entries = dir.iterate();
    const entry = (try entries.next(std.testing.io)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(name, entry.name);
    try std.testing.expect((try entries.next(std.testing.io)) == null);
}

test "registry upsert and remove round trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "registry.toml" });
    defer std.testing.allocator.free(path);
    const model_path = try std.fs.path.join(std.testing.allocator, &.{ root, "toy.gguf" });
    defer std.testing.allocator.free(model_path);
    try save(path, .{ .models = &.{} });
    try upsert(std.testing.allocator, path, .{
        .id = "toy",
        .name = "Toy",
        .profile = "local",
        .languages_en = true,
        .languages_ja = true,
        .path = model_path,
        .download_url = "https://models.example.invalid/toy.gguf?token=KOTOBA_QUERY_SECRET_36",
        .checksum = "abc",
    });
    const saved = try sys.readFileAlloc(std.testing.allocator, path, 2 * 1024 * 1024);
    defer std.testing.allocator.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "KOTOBA_QUERY_SECRET_36") == null);
    var list_owner = try load(std.testing.allocator, path);
    defer list_owner.deinit();
    const list = list_owner.view();
    const toy = find(list, "toy") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(model_path, toy.path);
    var removed_owner = try removeById(std.testing.allocator, path, "toy");
    defer removed_owner.deinit();
    const removed = removed_owner.view();
    try std.testing.expectEqualStrings("toy", removed.id);
    var after_owner = try load(std.testing.allocator, path);
    defer after_owner.deinit();
    const after = after_owner.view();
    try std.testing.expect(find(after, "toy") == null);
}

test "registry upsert replaces existing model fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "registry.toml" });
    defer std.testing.allocator.free(path);
    const first_model_path = try std.fs.path.join(std.testing.allocator, &.{ root, "toy-v1.gguf" });
    defer std.testing.allocator.free(first_model_path);
    const second_model_path = try std.fs.path.join(std.testing.allocator, &.{ root, "toy-v2.gguf" });
    defer std.testing.allocator.free(second_model_path);
    try save(path, .{ .models = &.{} });

    try upsert(std.testing.allocator, path, .{ .id = "toy", .name = "Toy", .path = first_model_path });
    try upsert(std.testing.allocator, path, .{ .id = "toy", .name = "Toy v2", .path = second_model_path });

    var list_owner = try load(std.testing.allocator, path);
    defer list_owner.deinit();
    const list = list_owner.view();
    try std.testing.expectEqual(@as(usize, 1), list.models.len);
    const toy = find(list, "toy") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("Toy v2", toy.name);
    try std.testing.expectEqualStrings(second_model_path, toy.path);
}

test "registry upsert preserves missing registry errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "missing-registry.toml" });
    defer std.testing.allocator.free(path);
    const model_path = try std.fs.path.join(std.testing.allocator, &.{ root, "toy.gguf" });
    defer std.testing.allocator.free(model_path);
    try std.testing.expectError(errors.Error.NotInitialized, upsert(std.testing.allocator, path, .{
        .id = "toy",
        .name = "Toy",
        .profile = "local",
        .languages_en = true,
        .languages_ja = true,
        .path = model_path,
    }));
}

test "registries with identical model IDs remain independent" {
    var left_tmp = std.testing.tmpDir(.{});
    defer left_tmp.cleanup();
    const left_root = try left_tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(left_root);
    const left_path = try std.fs.path.join(std.testing.allocator, &.{ left_root, "registry.toml" });
    defer std.testing.allocator.free(left_path);

    var right_tmp = std.testing.tmpDir(.{});
    defer right_tmp.cleanup();
    const right_root = try right_tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(right_root);
    const right_path = try std.fs.path.join(std.testing.allocator, &.{ right_root, "registry.toml" });
    defer std.testing.allocator.free(right_path);

    try save(left_path, .{ .models = &.{} });
    try save(right_path, .{ .models = &.{} });
    try upsert(std.testing.allocator, left_path, .{ .id = "same", .name = "left" });
    try upsert(std.testing.allocator, right_path, .{ .id = "same", .name = "right" });

    var left_owner = try load(std.testing.allocator, left_path);
    defer left_owner.deinit();
    const left = find(left_owner.view(), "same") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("left", left.name);
    var right_owner = try load(std.testing.allocator, right_path);
    defer right_owner.deinit();
    const right = find(right_owner.view(), "same") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("right", right.name);
}

const legacy_url_fixture =
    \\[[models]]
    \\id = "legacy"
    \\name = "Legacy model"
    \\profile = "technical"
    \\languages = ["en", "ja"]
    \\format = "gguf"
    \\quantization = "Q4_K_M"
    \\context_length = 4096
    \\size = "small"
    \\path = "/installed/model?#.gguf"
    \\download_url = "https://KOTOBA_USER_36:KOTOBA_PASSWORD_36@models.example.invalid/model%2Bname.gguf?token=KOTOBA_QUERY_SECRET_36#KOTOBA_FRAGMENT_SECRET_36"
    \\checksum = "abc123"
    \\license = "MIT"
    \\recommended = true
    \\notes = "Retain descriptive metadata."
    \\[[models]]
    \\id = "other"
    \\[[models]]
    \\id = "invalid"
    \\download_url = "https:///missing-host?KOTOBA_QUERY_SECRET_36"
    \\source_url = "https://bad host/KOTOBA_PASSWORD_36"
    \\[[models]]
    \\id = "signed"
    \\download_url = "https://models.example.invalid/signed.gguf?token=KOTOBA_QUERY_SECRET_36"
    \\source_url = "https://KOTOBA_USER_36@origin.example.invalid/source%2Bname.gguf?KOTOBA_QUERY_SECRET_36#KOTOBA_FRAGMENT_SECRET_36"
    \\[[models]]
    \\id = "fragment"
    \\download_url = "HTTPS://models.example.invalid/model.gguf#KOTOBA_FRAGMENT_SECRET_36"
    \\[[models]]
    \\id = "empty-query"
    \\download_url = "https://models.example.invalid/model.gguf?"
    \\[[models]]
    \\id = "http"
    \\download_url = "http://models.example.invalid/model.gguf"
;

test "secret URL registry writes sanitize all entries" {
    for (0..3) |operation| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        const path = try std.fs.path.join(allocator, &.{ root, "registry.toml" });
        var fixture = std.array_list.Managed(u8).init(allocator);
        try fixture.appendSlice(legacy_url_fixture ++ "\n[[models]]\nid = \"oversized\"\n");
        var oversized = [_]u8{'a'} ** (url.max_length + 1);
        @memcpy(oversized[0..8], "https://");
        try appendStringField(&fixture, "download_url", &oversized);
        try appendStringField(&fixture, "source_url", &oversized);
        try sys.writeFile(path, fixture.items);
        var before_owner = try load(allocator, path);
        defer before_owner.deinit();
        const before = before_owner.view();
        switch (operation) {
            0 => try save(path, before),
            1 => try upsert(allocator, path, .{ .id = "new", .name = "Unrelated import" }),
            2 => {
                var removed = try removeById(allocator, path, "other");
                removed.deinit();
            },
            else => unreachable,
        }
        const saved = try sys.readFileAlloc(allocator, path, 2 * 1024 * 1024);
        try std.testing.expect(std.mem.indexOf(u8, saved, "KOTOBA_") == null);
        var after_owner = try parse(allocator, saved);
        defer after_owner.deinit();
        const after = after_owner.view();
        const original = find(before, "legacy").?;
        const migrated = find(after, "legacy").?;
        try std.testing.expectEqualStrings("", migrated.download_url);
        try std.testing.expectEqualStrings("https://models.example.invalid/model%2Bname.gguf", migrated.source_url);
        inline for (std.meta.fields(Model)) |field| {
            if (comptime !std.mem.eql(u8, field.name, "source_url") and !std.mem.eql(u8, field.name, "download_url")) {
                try std.testing.expectEqualDeep(@field(original, field.name), @field(migrated, field.name));
            }
        }
        try std.testing.expect(std.mem.indexOf(u8, original.download_url, "KOTOBA_QUERY_SECRET_36") != null);
        try std.testing.expectEqualStrings("", original.source_url);
        try std.testing.expectEqualStrings("", find(after, "invalid").?.download_url);
        try std.testing.expectEqualStrings("", find(after, "invalid").?.source_url);
        try std.testing.expectEqualStrings("", find(after, "oversized").?.download_url);
        try std.testing.expectEqualStrings("", find(after, "oversized").?.source_url);
        try std.testing.expectEqualStrings("", find(after, "signed").?.download_url);
        try std.testing.expectEqualStrings("https://origin.example.invalid/source%2Bname.gguf", find(after, "signed").?.source_url);
        try std.testing.expectEqualStrings("HTTPS://models.example.invalid/model.gguf", find(after, "fragment").?.download_url);
        try std.testing.expectEqualStrings("", find(after, "empty-query").?.download_url);
        try std.testing.expectEqualStrings("", find(after, "http").?.download_url);
        try std.testing.expectEqualStrings("http://models.example.invalid/model.gguf", find(after, "http").?.source_url);
        for (before.models) |old| {
            const canonical = find(after, old.id) orelse {
                try std.testing.expect(operation == 2 and std.mem.eql(u8, old.id, "other"));
                continue;
            };
            inline for (std.meta.fields(Model)) |field| {
                if (comptime !std.mem.eql(u8, field.name, "source_url") and !std.mem.eql(u8, field.name, "download_url")) {
                    try std.testing.expectEqualDeep(@field(old, field.name), @field(canonical, field.name));
                }
            }
        }
        try save(path, after);
        try std.testing.expectEqualStrings(saved, try sys.readFileAlloc(allocator, path, 2 * 1024 * 1024));
        var entries = tmp.dir.iterate();
        try std.testing.expectEqualStrings("registry.toml", (try entries.next(std.testing.io)).?.name);
        try std.testing.expect(try entries.next(std.testing.io) == null);
    }
}

test "secret URL registry read is nonmutating" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "registry.toml" });
    defer allocator.free(path);
    try sys.writeFile(path, legacy_url_fixture);
    var list_owner = try load(allocator, path);
    defer list_owner.deinit();
    const list = list_owner.view();
    try std.testing.expect(std.mem.indexOf(u8, find(list, "legacy").?.download_url, "KOTOBA_PASSWORD_36") != null);
    try std.testing.expect(std.mem.indexOf(u8, find(list, "signed").?.source_url, "KOTOBA_USER_36") != null);
    const after = try sys.readFileAlloc(allocator, path, 2 * 1024 * 1024);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(legacy_url_fixture, after);
    var before_hash: [32]u8 = undefined;
    var after_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(legacy_url_fixture, &before_hash, .{});
    std.crypto.hash.sha2.Sha256.hash(after, &after_hash, .{});
    try std.testing.expectEqualSlices(u8, &before_hash, &after_hash);
    var entries = tmp.dir.iterate();
    _ = try entries.next(std.testing.io);
    try std.testing.expect(try entries.next(std.testing.io) == null);
}

test "secret URL source identity is never reusable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var oversized = [_]u8{'a'} ** (url.max_length + 1);
    @memcpy(oversized[0..8], "https://");
    const cases = [_]struct { model: Model, expected_source: []const u8 }{
        .{ .model = .{ .source_url = "https://models.example.invalid/source.gguf" }, .expected_source = "https://models.example.invalid/source.gguf" },
        .{ .model = .{ .source_url = "https://KOTOBA_USER_36@models.example.invalid/model?KOTOBA_QUERY_SECRET_36#KOTOBA_FRAGMENT_SECRET_36" }, .expected_source = "https://models.example.invalid/model" },
        .{ .model = .{ .source_url = "https:///invalid", .download_url = "https://models.example.invalid/fallback?KOTOBA_QUERY_SECRET_36" }, .expected_source = "https://models.example.invalid/fallback" },
        .{ .model = .{ .source_url = "https:///invalid" }, .expected_source = "" },
        .{ .model = .{ .source_url = &oversized, .download_url = &oversized }, .expected_source = "" },
        .{ .model = .{ .source_url = "https://models.example.invalid/a\x7f", .download_url = "https://models.example.invalid/a\x01" }, .expected_source = "" },
    };
    for (cases) |case| {
        var out = std.array_list.Managed(u8).init(allocator);
        var original = case.model;
        original.id = "source";
        try appendModel(&out, original);
        var parsed = try parse(allocator, out.items);
        defer parsed.deinit();
        const model = parsed.view().models[0];
        try std.testing.expectEqualStrings(case.expected_source, model.source_url);
        try std.testing.expectEqualStrings("", model.download_url);
        var second = std.array_list.Managed(u8).init(allocator);
        try appendModel(&second, model);
        try std.testing.expectEqualStrings(out.items, second.items);
    }
}

test "secret URL registry preserves local metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_][]const u8{ "/local/model?#.gguf", "file:///local/model?#.gguf", "https://models.example.invalid/model%2Bname.gguf" }) |download| {
        for ([_][]const u8{ "", "https://origin.example.invalid/original.gguf" }) |source| {
            var out = std.array_list.Managed(u8).init(allocator);
            const original: Model = .{ .id = "local", .path = "/installed/model?#.gguf", .download_url = download, .source_url = source, .checksum = "abc123" };
            try appendModel(&out, original);
            var parsed = try parse(allocator, out.items);
            defer parsed.deinit();
            const model = parsed.view().models[0];
            try std.testing.expectEqualStrings(download, model.download_url);
            try std.testing.expectEqualStrings(if (source.len > 0) source else if (url.isRemote(download)) download else "", model.source_url);
            try std.testing.expectEqualStrings(original.id, model.id);
            try std.testing.expectEqualStrings(original.path, model.path);
            try std.testing.expectEqualStrings(original.checksum, model.checksum);
        }
    }
}

fn checkSourceOwnership(allocator: std.mem.Allocator) !void {
    const data = try allocator.dupe(u8, legacy_url_fixture ++
        "\nsource_url = \"https://origin.example.invalid/final\"\n" ++
        "[[models]]\nid = \"owned61\"\nname = \"Owned\\tname\"\n" ++
        "source_url = \"https://origin.example.invalid/owned\"\n" ++
        "notes = \"Decoded \\u65e5\\u672c\\u8a9e\"\nlanguages = [\"ja\",\"en\",]\n");
    var list_owner = parse(allocator, data) catch |err| {
        allocator.free(data);
        return err;
    };
    allocator.free(data);
    defer list_owner.deinit();
    const list = list_owner.view();
    try std.testing.expectEqualStrings("https://origin.example.invalid/final", find(list, "http").?.source_url);
    try std.testing.expectEqualStrings("", find(list, "legacy").?.source_url);
    try std.testing.expectEqualStrings("Owned\tname", find(list, "owned61").?.name);
    try std.testing.expectEqualStrings("Decoded 日本語", find(list, "owned61").?.notes);
    try std.testing.expectEqualStrings("https://origin.example.invalid/owned", find(list, "owned61").?.source_url);
    try std.testing.expect(find(list, "owned61").?.languages_en and find(list, "owned61").?.languages_ja);
}

test "secret URL registry source strings own allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkSourceOwnership, .{});
}

const strict_invalid_records = [_][]const u8{
    "[[models]]",
    "[[models]]\nname = 'missing id'\n[[models]]\nid = 'next'",
    "[[models]]\nid = ''",
    "[[models]]\nid = 'bad/id'",
    "[[models]]\nid = '日本語'",
    "[[models]]\nid = 'x'\n[[models]]\nid = 'x'",
    "[[models]]\nid = 'x'\n[[models]]\nid = \"\\u0078\"",
    "[[models]]\nid = 1",
    "[[models]]\nid = 'x'\nunknown = 'value'",
    "name = 'before record'",
    "[models]",
    "[[other]]",
    "[nested.models]",
    "[[models]] tail",
    "[[models]",
    "[[models]]\nid 'missing equal'",
    "[[models]]\n'id' = 'x'",
    "[[models]]\nmodel.id = 'x'",
    "[[models]]\nid = \"unterminated",
    "[[models]]\nid = 'x'\nnotes = \"bad\\q\"",
    "[[models]]\nid = 'x'\nnotes = \"\\u0000\"",
    "[[models]]\nid = 'x'\nnotes = \"\\uD800\"",
    "[[models]]\nid = 'x'\nnotes = \"\\U00110000\"",
    "[[models]]\nid = 'x'\nnotes = \"x\" tail",
    "[[models]]\nid = 'x'\nnotes = '''multiline'''",
    "[[models]]\nid = 'x'\nnotes = 'raw\x01'",
    "[[models]]\nid = 'x'\nnotes = '\xff'",
    "[[models]]\nid = 'x'\nnotes = 'nul\x00'",
    "[[models]]\nid = 'x'\r",
    "\xef\xbb\xbf[[models]]\nid = 'x'",
    "[[models]]\nid = 'x'\nlanguages = ['en','xx']",
    "[[models]]\nid = 'x'\nlanguages = ['en','en']",
    "[[models]]\nid = 'x'\nlanguages = ['ja','ja']",
    "[[models]]\nid = 'x'\nlanguages = [true]",
    "[[models]]\nid = 'x'\nlanguages = [en]",
    "[[models]]\nid = 'x'\nlanguages = [['en']]",
    "[[models]]\nid = 'x'\nlanguages = ['en' 'ja']",
    "[[models]]\nid = 'x'\nlanguages = ['en',,]",
    "[[models]]\nid = 'x'\nlanguages = [\n'en']",
    "[[models]]\nid = 'x'\nlanguages = [] tail",
    "[[models]]\nid = 'x'\nlanguages = 'en'",
    "[[models]]\nid = 'x'\ncontext_length = '32'",
    "[[models]]\nid = 'x'\ncontext_length = -0",
    "[[models]]\nid = 'x'\ncontext_length = 4294967296",
    "[[models]]\nid = 'x'\ncontext_length = 01",
    "[[models]]\nid = 'x'\ncontext_length = 1.0",
    "[[models]]\nid = 'x'\ncontext_length = 0x10",
    "[[models]]\nid = 'x'\ncontext_length = 1_000",
    "[[models]]\nid = 'x'\nrecommended = 'false'",
    "[[models]]\nid = 'x'\nrecommended = TRUE",
    "[[models]]\nid = 'x'\nrecommended = 1",
    "[[models]]\nid = 'x'\nrecommended = false true",
    "[\"version\"]",
    "[['schema']]",
    "[schema.version]",
    "[version",
    "[schema] trailing",
};

test "strict registry rejects invalid records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (strict_invalid_records) |data| {
        try std.testing.expectError(error.ModelsInvalid, parse(arena.allocator(), data));
    }
    inline for (std.meta.fields(Model)) |field| {
        if (field.type == []const u8 and !std.mem.eql(u8, field.name, "id")) {
            try std.testing.expectError(error.ModelsInvalid, parse(arena.allocator(), "[[models]]\nid = 'x'\n" ++ field.name ++ " = true"));
        }
    }
}

test "strict registry rejects duplicate fields including source_url" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fields = .{
        .{ "id", "'x'" },            .{ "name", "'name'" },         .{ "profile", "'custom'" },
        .{ "languages", "['en']" },  .{ "format", "'gguf'" },       .{ "quantization", "'Q4'" },
        .{ "context_length", "32" }, .{ "size", "'small'" },        .{ "path", "'model.gguf'" },
        .{ "download_url", "''" },   .{ "source_url", "'source'" }, .{ "checksum", "'abc'" },
        .{ "license", "'MIT'" },     .{ "recommended", "false" },   .{ "notes", "'note'" },
    };
    inline for (fields) |field| {
        const prefix = if (comptime std.mem.eql(u8, field[0], "id")) "[[models]]\n" else "[[models]]\nid = 'x'\n";
        try std.testing.expectError(error.ModelsInvalid, parse(arena.allocator(), prefix ++ field[0] ++ " = " ++ field[1] ++ "\n" ++ field[0] ++ " = " ++ field[1]));
        try std.testing.expectError(error.ModelsInvalid, parse(arena.allocator(), prefix ++ field[0] ++ " = " ++ field[1] ++ "\n" ++ field[0] ++ " = \"bad\\q\""));
    }
}

test "strict registry schema markers and first textual error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    inline for (.{ "version", "schema", "schema_version" }) |key| {
        inline for (.{ "", "[[models]]\n", "[[models]]\nid = 'x'\n" }) |prefix| {
            try std.testing.expectError(error.ModelsSchemaUnsupported, parse(arena.allocator(), prefix ++ key ++ " = 2"));
            try std.testing.expectError(error.ModelsSchemaUnsupported, parse(arena.allocator(), prefix ++ key ++ " = \"bad\\q\""));
            try std.testing.expectError(error.ModelsSchemaUnsupported, parse(arena.allocator(), prefix ++ "[ " ++ key ++ " ]"));
            try std.testing.expectError(error.ModelsSchemaUnsupported, parse(arena.allocator(), prefix ++ "[[\t" ++ key ++ "\t]]"));
        }
    }
    try std.testing.expectError(error.ModelsInvalid, parse(arena.allocator(), "unknown = 1\nversion = 2"));
    try std.testing.expectError(error.ModelsInvalid, parse(arena.allocator(), "[[models]]\nid = 'x'\nid = '\xff'\nversion = 2"));
    try std.testing.expectError(error.ModelsInvalid, parse(arena.allocator(), "[[models]]\n[[models]]\nversion = 2"));
}

test "strict registry canonical model round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const path = try std.fs.path.join(allocator, &.{ root, "models.toml" });
    const text = "日本語 🐈 \"quoted\" \\ # =\n\r\t\x08\x0c\x01\x1f\x7f";
    try save(path, .{ .models = &.{} });
    var empty = try load(allocator, path);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.view().models.len);
    const empty_bytes = try sys.readFileAlloc(allocator, path, 8192);
    try save(path, empty.view());
    try std.testing.expectEqualStrings(empty_bytes, try sys.readFileAlloc(allocator, path, 8192));
    for (0..4) |flags| {
        for ([_][]const u8{ "/local/model?#.gguf", "file:///local/model?#.gguf", "https://models.example.invalid/model%2Bname.gguf" }) |download| {
            var originals = [_]Model{.{
                .id = "roundtrip61",
                .name = text,
                .profile = text,
                .languages_en = flags & 1 != 0,
                .languages_ja = flags & 2 != 0,
                .format = text,
                .quantization = text,
                .context_length = std.math.maxInt(u32),
                .size = text,
                .path = "C:\\Users\\日本語\\quoted\"#=model.gguf",
                .download_url = download,
                .source_url = "https://origin.example.invalid/source%2Bname.gguf",
                .checksum = text,
                .license = text,
                .recommended = true,
                .notes = text,
            }};
            try save(path, .{ .models = &originals });
            const bytes = try sys.readFileAlloc(allocator, path, 8192);
            var loaded_owner = try load(allocator, path);
            defer loaded_owner.deinit();
            const loaded = loaded_owner.view();
            try std.testing.expectEqualDeep(&originals, loaded.models);
            try save(path, loaded);
            try std.testing.expectEqualStrings(bytes, try sys.readFileAlloc(allocator, path, 8192));
            try expectOnlyEntry(tmp.dir, "models.toml");
        }
    }
}

test "strict registry parses literal strings whitespace defaults and empty list" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "", "# empty\r\n\t\n" }) |input| {
        var list_owner = try parse(allocator, input);
        defer list_owner.deinit();
        const list = list_owner.view();
        try std.testing.expectEqual(@as(usize, 0), list.models.len);
    }
    var list_owner = try parse(allocator, "\t[[ models ]] # record\r\nid = \"case\\u0036\\U00000031\"\r\nname = 'C:\\日本語\\#=model'\r\nlanguages = ['ja', \"\\u0065n\",]\r\ncontext_length = +0\r\nrecommended = false\r\n[[models]]\nid = 'CASE61'\nlanguages = []");
    defer list_owner.deinit();
    const list = list_owner.view();
    try std.testing.expectEqualDeep(Model{ .id = "case61", .name = "C:\\日本語\\#=model", .languages_en = true, .languages_ja = true }, list.models[0]);
    try std.testing.expectEqualDeep(Model{ .id = "CASE61" }, list.models[1]);
}

test "strict registry save rejects invalid IDs and strings before writing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const path = try std.fs.path.join(allocator, &.{ root, "models.toml" });
    const original = "# preserve existing registry\n[[models]]\nid = 'keep'\n";
    try sys.writeFile(path, original);
    for ([_][]const u8{ "", "bad/id", "日本語" }) |id| {
        var models = [_]Model{.{ .id = id }};
        try std.testing.expectError(error.ModelsInvalid, save(path, .{ .models = &models }));
        try std.testing.expectEqualStrings(original, try sys.readFileAlloc(allocator, path, 1024));
    }
    var duplicates = [_]Model{ .{ .id = "same" }, .{ .id = "same" } };
    try std.testing.expectError(error.ModelsInvalid, save(path, .{ .models = &duplicates }));
    inline for (std.meta.fields(Model)) |field| {
        if (field.type == []const u8) {
            for ([_][]const u8{ "bad\x00", "bad\xff" }) |value| {
                var models = [_]Model{ .{ .id = "first" }, .{ .id = "second" } };
                @field(models[1], field.name) = value;
                try std.testing.expectError(error.ModelsInvalid, save(path, .{ .models = &models }));
                try std.testing.expectEqualStrings(original, try sys.readFileAlloc(allocator, path, 1024));
            }
        }
    }
    try expectOnlyEntry(tmp.dir, "models.toml");
}

test "strict registry ensure rejects corrupt state without changing bytes or entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const path = try std.fs.path.join(allocator, &.{ root, "models.toml" });
    for ([_]struct { data: []const u8, expected: anyerror }{
        .{ .data = "[[models]]\nid = \"unterminated", .expected = error.ModelsInvalid },
        .{ .data = "unknown = 'preserve me'", .expected = error.ModelsInvalid },
        .{ .data = "[[models]]\nid = 'x'\nid = 'x'", .expected = error.ModelsInvalid },
        .{ .data = "[[models]]\nsource_url = 'a'\nsource_url = 'b'", .expected = error.ModelsInvalid },
        .{ .data = "[[models]]\nid = 'x'\nlanguages = ['en','xx']", .expected = error.ModelsInvalid },
        .{ .data = "schema_version = 2", .expected = error.ModelsSchemaUnsupported },
    }) |case| {
        try sys.writeFile(path, case.data);
        try std.testing.expectError(case.expected, ensure(path));
        try std.testing.expectError(case.expected, load(allocator, path));
        try std.testing.expectError(case.expected, loadReadOnly(allocator, path));
        try std.testing.expectEqualStrings(case.data, try sys.readFileAlloc(allocator, path, 1024));
        try expectOnlyEntry(tmp.dir, "models.toml");
    }
}

fn checkInvalidRegistryOwnership(allocator: std.mem.Allocator, data: []const u8, expected: anyerror) !void {
    var list_owner = parse(allocator, data) catch |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expectEqual(expected, err);
        return;
    };
    defer list_owner.deinit();
    return error.TestExpectedError;
}

test "strict registry invalid records clean every allocation failure" {
    for (strict_invalid_records) |input| {
        const prefix = if (std.mem.startsWith(u8, input, "[[models]]")) "[[models]]\nid = 'complete'\nsource_url = 'https://origin.example.invalid/complete'\n" else "";
        const data = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, input });
        defer std.testing.allocator.free(data);
        try std.testing.checkAllAllocationFailures(std.testing.allocator, checkInvalidRegistryOwnership, .{ data, error.ModelsInvalid });
    }
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkInvalidRegistryOwnership, .{ "[[models]]\nid = 'complete'\nsource_url = 'one'\nsource_url = 'two'", error.ModelsInvalid });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkInvalidRegistryOwnership, .{ "[[models]]\nid = 'complete'\n[[models]]\nid = 'current'\nnotes = 'allocated'\nversion = 2", error.ModelsSchemaUnsupported });
}

const ownership_fixture = "[[models]]\nid = 'same'\nname = 'first'\nnotes = 'owned note'\n[[models]]\nid = 'kept'\n";

test "ownership/registry lifecycle 2048 literal upserts and independent removal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "models.toml" });
    defer a.free(path);
    try sys.writeFile(path, "");
    for (0..2048) |i| {
        const literal: Model = .{ .id = "same", .name = if (i == 2047) "last" else "first", .context_length = @intCast(i) };
        try upsert(a, path, literal);
        try std.testing.expectEqualStrings("custom", literal.profile);
    }
    {
        var list = try load(a, path);
        defer list.deinit();
        try std.testing.expectEqual(@as(usize, 1), list.view().models.len);
        const last = find(list.view(), "same").?;
        try std.testing.expectEqualStrings("last", last.name);
        try std.testing.expectEqual(@as(u32, 2047), last.context_length);
    }
    var removed = try removeById(a, path, "same");
    defer removed.deinit();
    try std.testing.expectEqualStrings("last", removed.view().name);
    try std.testing.expectEqualStrings("custom", removed.view().profile);
    try std.testing.expectEqualStrings("gguf", removed.view().format);
    var empty = try load(a, path);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.view().models.len);
    try std.testing.expectError(error.ModelRegistryInvalid, removeById(a, path, "same"));
    std.debug.print("registry pid={d} same-process upserts=2048 final_count=1 final_context=2047 removed=last\n", .{std.os.linux.getpid()});
}

test "ownership/registry lifecycle input and list destruction before removal use" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "models.toml" });
    defer a.free(path);
    try sys.writeFile(path, "");
    {
        const input = try a.dupe(u8, ownership_fixture);
        defer a.free(input);
        var list = try parse(a, input);
        defer list.deinit();
        try upsert(a, path, find(list.view(), "same").?);
    }
    var removed = try removeById(a, path, "same");
    defer removed.deinit();
    try std.testing.expectEqualStrings("first", removed.view().name);
    try std.testing.expectEqualStrings("owned note", removed.view().notes);
}

fn exerciseRegistryParse(backing: std.mem.Allocator, data: []const u8, invalid: bool, runs: *usize) !void {
    runs.* += 1;
    var no_resize = std.testing.FailingAllocator.init(backing, .{ .resize_fail_index = 0 });
    var owner = parse(no_resize.allocator(), data) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (!invalid) return err;
        try std.testing.expectEqual(error.ModelsInvalid, err);
        return;
    };
    defer owner.deinit();
    try std.testing.expect(!invalid);
}

fn exerciseModelClone(allocator: std.mem.Allocator, runs: *usize) !void {
    runs.* += 1;
    const literal: Model = .{ .id = "literal", .name = "name", .size = "small", .quantization = "Q4", .path = "local.gguf", .download_url = "file:///model.gguf", .source_url = "source", .checksum = "abc", .license = "MIT", .notes = "note" };
    var owner = try OwnedModel.clone(allocator, literal);
    defer owner.deinit();
    try std.testing.expectEqualDeep(literal, owner.view());
}

const MutationCase = enum { append, replace, remove, missing, save_upsert, save_remove };

fn exerciseRegistryMutation(backing: std.mem.Allocator, scenario: MutationCase, runs: *usize) !void {
    runs.* += 1;
    var no_resize = std.testing.FailingAllocator.init(backing, .{ .resize_fail_index = 0 });
    const allocator = no_resize.allocator();
    // Fixture setup uses the test allocator so every injected index reaches the operation.
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "models.toml" });
    defer a.free(path);
    try sys.writeFile(path, ownership_fixture);
    const file = try tmp.dir.openFile(std.testing.io, "models.toml", .{});
    defer file.close(std.testing.io);
    const save_error = scenario == .save_upsert or scenario == .save_remove;
    if (save_error) try file.setPermissions(std.testing.io, .fromMode(0o400));
    defer if (save_error) file.setPermissions(std.testing.io, .fromMode(0o600)) catch unreachable;
    switch (scenario) {
        .append, .replace, .save_upsert => {
            upsert(allocator, path, .{ .id = if (scenario == .append) "new" else "same", .name = "replacement" }) catch |err| {
                if (err == error.OutOfMemory) return err;
                if (!save_error) return err;
                try std.testing.expectEqual(error.AccessDenied, err);
                return;
            };
            try std.testing.expect(!save_error);
        },
        .remove, .missing, .save_remove => {
            var removed = removeById(allocator, path, if (scenario == .missing) "absent" else "same") catch |err| {
                if (err == error.OutOfMemory) return err;
                const expected: anyerror = if (scenario == .missing) error.ModelRegistryInvalid else if (save_error) error.AccessDenied else return err;
                try std.testing.expectEqual(expected, err);
                return;
            };
            defer removed.deinit();
            try std.testing.expectEqualStrings("first", removed.view().name);
            try std.testing.expect(!save_error and scenario != .missing);
        },
    }
    var reloaded = try load(a, path);
    defer reloaded.deinit();
    if (scenario == .remove) {
        try std.testing.expect(find(reloaded.view(), "same") == null);
        try std.testing.expect(find(reloaded.view(), "kept") != null);
    } else {
        try std.testing.expectEqualStrings("replacement", find(reloaded.view(), if (scenario == .append) "new" else "same").?.name);
    }
    try expectOnlyEntry(tmp.dir, "models.toml");
}

test "ownership/registry failure exhaustive defaults clone parse and mutations" {
    var runs: usize = 0;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseModelClone, .{&runs});
    for ([_][]const u8{ "", "[[models]]\nid = 'defaults'", ownership_fixture, "[[models]]\nid = '1'\n[[models]]\nid = '2'\n[[models]]\nid = '3'\n[[models]]\nid = '4'\n[[models]]\nid = '5'\n[[models]]\nid = '6'\n[[models]]\nid = '7'\n[[models]]\nid = '8'\n[[models]]\nid = '9'", ownership_fixture ++ "[[models]]\nid = 'partial'\nnotes = 'one'\nnotes = 'duplicate'" }) |data| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseRegistryParse, .{ data, std.mem.endsWith(u8, data, "'duplicate'"), &runs });
    }
    inline for (std.meta.tags(MutationCase)) |scenario| {
        const before = runs;
        try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseRegistryMutation, .{ scenario, &runs });
        std.debug.print("registry OOM scenario={s} exercise_invocations={d} failed_alloc_indices=0..{d} resize_remap=denied\n", .{ @tagName(scenario), runs - before, runs - before - 2 });
    }
    try std.testing.expect(runs > 100);
    std.debug.print("registry exhaustive exercise invocations={d}\n", .{runs});
}

test "ownership/registry failure replacement preserves previous value" {
    const a = std.testing.allocator;
    var previous: []const u8 = try a.dupe(u8, "previous");
    defer a.free(previous);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, replaceString(failing.allocator(), &previous, "'next'"));
    try std.testing.expectEqualStrings("previous", previous);
}
