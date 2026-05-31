const std = @import("std");
const errors = @import("../errors.zig");
const sys = @import("../sys.zig");
const toml = @import("../toml.zig");
const types = @import("types.zig");
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
    try appendStringField(out, "download_url", m.download_url);
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

test "registry upsert and remove round trip" {
    const path = "/tmp/kotoba-model-registry-test.toml";
    sys.deleteFile(path);
    try save(path, .{ .models = &.{} });
    try upsert(std.heap.page_allocator, path, .{
        .id = "toy",
        .name = "Toy",
        .profile = "local",
        .languages_en = true,
        .languages_ja = true,
        .path = "/tmp/toy.gguf",
        .checksum = "abc",
    });
    const list = try load(std.heap.page_allocator, path);
    const toy = find(list, "toy") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("/tmp/toy.gguf", toy.path);
    const removed = try removeById(std.heap.page_allocator, path, "toy");
    try std.testing.expectEqualStrings("toy", removed.id);
    const after = try load(std.heap.page_allocator, path);
    try std.testing.expect(find(after, "toy") == null);
}

test "registry upsert replaces existing model fields" {
    const path = "/tmp/kotoba-model-registry-replace-test.toml";
    sys.deleteFile(path);
    try save(path, .{ .models = &.{} });

    try upsert(std.heap.page_allocator, path, .{ .id = "toy", .name = "Toy", .path = "/tmp/toy-v1.gguf" });
    try upsert(std.heap.page_allocator, path, .{ .id = "toy", .name = "Toy v2", .path = "/tmp/toy-v2.gguf" });

    const list = try load(std.heap.page_allocator, path);
    try std.testing.expectEqual(@as(usize, 1), list.models.len);
    const toy = find(list, "toy") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("Toy v2", toy.name);
    try std.testing.expectEqualStrings("/tmp/toy-v2.gguf", toy.path);
}

test "registry upsert preserves missing registry errors" {
    const path = "/tmp/kotoba-model-registry-missing-test.toml";
    sys.deleteFile(path);
    try std.testing.expectError(errors.Error.ModelsInvalid, upsert(std.heap.page_allocator, path, .{
        .id = "toy",
        .name = "Toy",
        .profile = "local",
        .languages_en = true,
        .languages_ja = true,
        .path = "/tmp/toy.gguf",
    }));
}
