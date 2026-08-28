const std = @import("std");
const errors = @import("../errors.zig");
const sys = @import("../sys.zig");
const toml = @import("../toml.zig");
const types = @import("types.zig");
const url = @import("../url.zig");
const validation = @import("validation.zig");

pub const Model = types.Model;
pub const List = types.List;

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
    if (!sys.exists(path)) try sys.writeFile(path, defaultTemplate());
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) !List {
    const data = sys.readFileAlloc(allocator, path, 2 * 1024 * 1024) catch return errors.Error.ModelsInvalid;
    defer allocator.free(data);
    return parse(allocator, data);
}

pub fn loadReadOnly(allocator: std.mem.Allocator, path: []const u8) !List {
    const data = sys.readFileAlloc(allocator, path, 2 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return parse(allocator, defaultTemplate()),
        else => return errors.Error.ModelsInvalid,
    };
    defer allocator.free(data);
    return parse(allocator, data);
}

pub fn parse(allocator: std.mem.Allocator, data: []const u8) !List {
    var items = std.array_list.Managed(Model).init(allocator);
    errdefer {
        for (items.items) |m| freeParsedModel(allocator, m);
        items.deinit();
    }

    var current: ?Model = null;
    errdefer if (current) |m| freeParsedModel(allocator, m);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const clean = toml.trim(toml.stripComment(line));
        if (std.mem.eql(u8, clean, "[[models]]")) {
            if (current) |m| {
                try items.append(m);
                current = null;
            }
            current = try parsedModelDefaults(allocator);
            continue;
        }
        const p = toml.pair(line) orelse continue;
        if (current == null) continue;
        var m = current.?;
        const val = toml.unquote(p.value);
        if (std.mem.eql(u8, p.key, "source_url")) {
            try replaceString(allocator, &m.source_url, val);
            current = m;
            continue;
        }
        if (std.mem.eql(u8, p.key, "id")) try replaceString(allocator, &m.id, val) else if (std.mem.eql(u8, p.key, "name")) try replaceString(allocator, &m.name, val) else if (std.mem.eql(u8, p.key, "profile")) try replaceString(allocator, &m.profile, val) else if (std.mem.eql(u8, p.key, "languages")) {
            m.languages_en = toml.stringArrayContains(p.value, "en");
            m.languages_ja = toml.stringArrayContains(p.value, "ja");
        } else if (std.mem.eql(u8, p.key, "format")) try replaceString(allocator, &m.format, val) else if (std.mem.eql(u8, p.key, "quantization")) try replaceString(allocator, &m.quantization, val) else if (std.mem.eql(u8, p.key, "context_length")) m.context_length = toml.intValue(p.value) orelse 0 else if (std.mem.eql(u8, p.key, "size")) try replaceString(allocator, &m.size, val) else if (std.mem.eql(u8, p.key, "path")) try replaceString(allocator, &m.path, val) else if (std.mem.eql(u8, p.key, "download_url")) try replaceString(allocator, &m.download_url, val) else if (std.mem.eql(u8, p.key, "checksum")) try replaceString(allocator, &m.checksum, val) else if (std.mem.eql(u8, p.key, "license")) try replaceString(allocator, &m.license, val) else if (std.mem.eql(u8, p.key, "recommended")) m.recommended = toml.boolValue(p.value) orelse false else if (std.mem.eql(u8, p.key, "notes")) try replaceString(allocator, &m.notes, val);
        current = m;
    }
    if (current) |m| {
        try items.append(m);
        current = null;
    }
    return .{ .models = try items.toOwnedSlice() };
}

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
    var replaced = false;
    for (list.models) |*m| {
        if (std.mem.eql(u8, m.id, model.id)) {
            m.* = model;
            replaced = true;
            break;
        }
    }
    if (!replaced) {
        var items = std.array_list.Managed(Model).init(allocator);
        errdefer items.deinit();
        try items.appendSlice(list.models);
        try items.append(model);
        list.models = try items.toOwnedSlice();
    }
    try save(registry_path, list);
}

pub fn removeById(allocator: std.mem.Allocator, registry_path: []const u8, id: []const u8) !Model {
    try validation.validateId(id);
    const list = try load(allocator, registry_path);
    var items = std.array_list.Managed(Model).init(allocator);
    errdefer items.deinit();
    var removed: ?Model = null;
    for (list.models) |m| {
        if (std.mem.eql(u8, m.id, id)) {
            removed = m;
        } else {
            try items.append(m);
        }
    }
    const found = removed orelse return errors.Error.ModelRegistryInvalid;
    const kept = try items.toOwnedSlice();
    errdefer allocator.free(kept);
    try save(registry_path, .{ .models = kept });
    return found;
}

pub fn save(path: []const u8, list: List) !void {
    var out = std.array_list.Managed(u8).init(std.heap.page_allocator);
    defer out.deinit();
    try out.appendSlice("# Kotoba model registry.\n\n");
    for (list.models) |m| {
        try appendModel(&out, m);
    }
    try sys.writeFile(path, out.items);
}

fn parsedModelDefaults(allocator: std.mem.Allocator) !Model {
    var model: Model = .{};
    errdefer freeParsedModel(allocator, model);
    model.id = try allocator.dupe(u8, "");
    model.name = try allocator.dupe(u8, "");
    model.profile = try allocator.dupe(u8, "custom");
    model.format = try allocator.dupe(u8, "gguf");
    model.quantization = try allocator.dupe(u8, "");
    model.size = try allocator.dupe(u8, "");
    model.path = try allocator.dupe(u8, "");
    model.download_url = try allocator.dupe(u8, "");
    model.source_url = try allocator.dupe(u8, "");
    model.checksum = try allocator.dupe(u8, "");
    model.license = try allocator.dupe(u8, "");
    model.notes = try allocator.dupe(u8, "");
    return model;
}

fn replaceString(allocator: std.mem.Allocator, field: *[]const u8, value: []const u8) !void {
    const next = try allocator.dupe(u8, value);
    allocator.free(field.*);
    field.* = next;
}

fn freeParsedModels(allocator: std.mem.Allocator, models: []Model) void {
    for (models) |m| freeParsedModel(allocator, m);
}

fn freeParsedModel(allocator: std.mem.Allocator, m: Model) void {
    freeOwnedString(allocator, m.id);
    freeOwnedString(allocator, m.name);
    freeOwnedString(allocator, m.profile);
    freeOwnedString(allocator, m.format);
    freeOwnedString(allocator, m.quantization);
    freeOwnedString(allocator, m.size);
    freeOwnedString(allocator, m.path);
    freeOwnedString(allocator, m.download_url);
    freeOwnedString(allocator, m.source_url);
    freeOwnedString(allocator, m.checksum);
    freeOwnedString(allocator, m.license);
    freeOwnedString(allocator, m.notes);
}

fn freeOwnedString(allocator: std.mem.Allocator, value: []const u8) void {
    if (value.len == 0 and value.ptr == "".ptr) return;
    if (std.mem.eql(u8, value, "custom") and value.ptr == "custom".ptr) return;
    if (std.mem.eql(u8, value, "gguf") and value.ptr == "gguf".ptr) return;
    allocator.free(value);
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
    try appendQuoted(out, value);
    try out.appendSlice("\n");
}

fn appendQuoted(out: *std.array_list.Managed(u8), value: []const u8) !void {
    try out.append('"');
    for (value) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice("\\\\"),
            '"' => try out.appendSlice("\\\""),
            '\n' => try out.appendSlice("\\n"),
            else => try out.append(ch),
        }
    }
    try out.append('"');
}

fn appendFmt(out: *std.array_list.Managed(u8), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(std.heap.page_allocator, fmt, args);
    defer std.heap.page_allocator.free(text);
    try out.appendSlice(text);
}

test "parse model list" {
    const list = try parse(std.heap.page_allocator, defaultTemplate());
    try std.testing.expect(list.models.len >= 1);
    try std.testing.expect(find(list, "custom") != null);
}

test "load read only uses the default template only for missing registries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const missing_path = try std.fs.path.join(allocator, &.{ root, "missing", "models.toml" });

    const missing = try loadReadOnly(allocator, missing_path);
    try std.testing.expectEqual(@as(usize, 2), missing.models.len);
    try std.testing.expect(find(missing, "custom") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "missing", .{}));

    const registry_path = try std.fs.path.join(allocator, &.{ root, "models.toml" });
    try sys.writeFile(registry_path, defaultTemplate());
    const existing = try loadReadOnly(allocator, registry_path);
    try std.testing.expectEqual(@as(usize, 2), existing.models.len);
    try std.testing.expect(find(existing, "example-light") != null);

    const directory_path = try std.fs.path.join(allocator, &.{ root, "directory" });
    try sys.makePath(directory_path);
    try std.testing.expectError(errors.Error.ModelsInvalid, loadReadOnly(allocator, directory_path));
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
    try upsert(std.heap.page_allocator, path, .{
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
    const list = try load(std.heap.page_allocator, path);
    const toy = find(list, "toy") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(model_path, toy.path);
    const removed = try removeById(std.heap.page_allocator, path, "toy");
    try std.testing.expectEqualStrings("toy", removed.id);
    const after = try load(std.heap.page_allocator, path);
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

    try upsert(std.heap.page_allocator, path, .{ .id = "toy", .name = "Toy", .path = first_model_path });
    try upsert(std.heap.page_allocator, path, .{ .id = "toy", .name = "Toy v2", .path = second_model_path });

    const list = try load(std.heap.page_allocator, path);
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
    try std.testing.expectError(errors.Error.ModelsInvalid, upsert(std.heap.page_allocator, path, .{
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
    try upsert(std.heap.page_allocator, left_path, .{ .id = "same", .name = "left" });
    try upsert(std.heap.page_allocator, right_path, .{ .id = "same", .name = "right" });

    const left = find(try load(std.heap.page_allocator, left_path), "same") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("left", left.name);
    const right = find(try load(std.heap.page_allocator, right_path), "same") orelse return error.TestExpectedEqual;
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
        const before = try load(allocator, path);
        switch (operation) {
            0 => try save(path, before),
            1 => try upsert(allocator, path, .{ .id = "new", .name = "Unrelated import" }),
            2 => _ = try removeById(allocator, path, "other"),
            else => unreachable,
        }
        const saved = try sys.readFileAlloc(allocator, path, 2 * 1024 * 1024);
        try std.testing.expect(std.mem.indexOf(u8, saved, "KOTOBA_") == null);
        const after = try parse(allocator, saved);
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
    const list = try load(allocator, path);
    defer allocator.free(list.models);
    defer freeParsedModels(allocator, list.models);
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
        try appendModel(&out, case.model);
        const model = (try parse(allocator, out.items)).models[0];
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
            const model = (try parse(allocator, out.items)).models[0];
            try std.testing.expectEqualStrings(download, model.download_url);
            try std.testing.expectEqualStrings(if (source.len > 0) source else if (url.isRemote(download)) download else "", model.source_url);
            try std.testing.expectEqualStrings(original.id, model.id);
            try std.testing.expectEqualStrings(original.path, model.path);
            try std.testing.expectEqualStrings(original.checksum, model.checksum);
        }
    }
}

fn checkSourceOwnership(allocator: std.mem.Allocator) !void {
    const data = try allocator.dupe(u8, legacy_url_fixture ++ "\nsource_url = \"https://origin.example.invalid/replaced\"\nsource_url = \"https://origin.example.invalid/final\"\n");
    const list = parse(allocator, data) catch |err| {
        allocator.free(data);
        return err;
    };
    allocator.free(data);
    defer allocator.free(list.models);
    defer freeParsedModels(allocator, list.models);
    try std.testing.expectEqualStrings("https://origin.example.invalid/final", find(list, "http").?.source_url);
    try std.testing.expectEqualStrings("", find(list, "legacy").?.source_url);
}

test "secret URL registry source strings own allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkSourceOwnership, .{});
}
