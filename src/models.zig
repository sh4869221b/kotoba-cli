const std = @import("std");
const errors = @import("errors.zig");
const net = @import("net.zig");
const sys = @import("sys.zig");
const toml = @import("toml.zig");

pub const Model = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    profile: []const u8 = "custom",
    languages_en: bool = false,
    languages_ja: bool = false,
    format: []const u8 = "gguf",
    quantization: []const u8 = "",
    context_length: u32 = 0,
    size: []const u8 = "",
    path: []const u8 = "",
    download_url: []const u8 = "",
    checksum: []const u8 = "",
    license: []const u8 = "",
    recommended: bool = false,
    notes: []const u8 = "",
};

pub const List = struct {
    models: []Model,
};

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
    var current: ?Model = null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const clean = toml.trim(toml.stripComment(line));
        if (std.mem.eql(u8, clean, "[[models]]")) {
            if (current) |m| try items.append(m);
            current = .{};
            continue;
        }
        const p = toml.pair(line) orelse continue;
        if (current == null) continue;
        var m = current.?;
        const val = toml.unquote(p.value);
        if (std.mem.eql(u8, p.key, "id")) m.id = try allocator.dupe(u8, val) else if (std.mem.eql(u8, p.key, "name")) m.name = try allocator.dupe(u8, val) else if (std.mem.eql(u8, p.key, "profile")) m.profile = try allocator.dupe(u8, val) else if (std.mem.eql(u8, p.key, "languages")) {
            m.languages_en = toml.stringArrayContains(p.value, "en");
            m.languages_ja = toml.stringArrayContains(p.value, "ja");
        } else if (std.mem.eql(u8, p.key, "format")) m.format = try allocator.dupe(u8, val) else if (std.mem.eql(u8, p.key, "quantization")) m.quantization = try allocator.dupe(u8, val) else if (std.mem.eql(u8, p.key, "context_length")) m.context_length = toml.intValue(p.value) orelse 0 else if (std.mem.eql(u8, p.key, "size")) m.size = try allocator.dupe(u8, val) else if (std.mem.eql(u8, p.key, "path")) m.path = try allocator.dupe(u8, val) else if (std.mem.eql(u8, p.key, "download_url")) m.download_url = try allocator.dupe(u8, val) else if (std.mem.eql(u8, p.key, "checksum")) m.checksum = try allocator.dupe(u8, val) else if (std.mem.eql(u8, p.key, "license")) m.license = try allocator.dupe(u8, val) else if (std.mem.eql(u8, p.key, "recommended")) m.recommended = toml.boolValue(p.value) orelse false else if (std.mem.eql(u8, p.key, "notes")) m.notes = try allocator.dupe(u8, val);
        current = m;
    }
    if (current) |m| try items.append(m);
    return .{ .models = try items.toOwnedSlice() };
}

pub fn find(list: List, id: []const u8) ?Model {
    for (list.models) |m| {
        if (std.mem.eql(u8, m.id, id)) return m;
    }
    return null;
}

pub fn validateId(id: []const u8) !void {
    if (id.len == 0) return errors.Error.InvalidArguments;
    for (id) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') continue;
        return errors.Error.InvalidArguments;
    }
}

pub fn validateGgufPath(path: []const u8) !void {
    if (path.len == 0 or !std.mem.endsWith(u8, path, ".gguf")) return errors.Error.InvalidArguments;
}

pub fn validateHfRfilename(path: []const u8) !void {
    try validateGgufPath(path);
    if (path[0] == '/') return errors.Error.InvalidArguments;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return errors.Error.InvalidArguments;
    if (std.mem.indexOfAny(u8, path, "?#") != null) return errors.Error.InvalidArguments;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return errors.Error.InvalidArguments;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return errors.Error.InvalidArguments;
    }
}

pub fn validateSingleHfGgufFilename(path: []const u8) !void {
    try validateHfRfilename(path);
    if (isSplitGgufFilename(path)) return errors.Error.SplitModelUnsupported;
}

fn isSplitGgufFilename(path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".gguf")) return false;
    const stem = path[0 .. path.len - ".gguf".len];
    const of_idx = std.mem.lastIndexOf(u8, stem, "-of-") orelse return false;
    const total = stem[of_idx + "-of-".len ..];
    if (total.len == 0 or !allDigits(total)) return false;
    var part_start = of_idx;
    while (part_start > 0 and std.ascii.isDigit(stem[part_start - 1])) : (part_start -= 1) {}
    if (part_start == of_idx) return false;
    if (part_start == 0 or stem[part_start - 1] != '-') return false;
    return true;
}

fn allDigits(text: []const u8) bool {
    for (text) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

pub fn installedPath(allocator: std.mem.Allocator, models_dir: []const u8, id: []const u8) ![]const u8 {
    try validateId(id);
    const filename = try std.fmt.allocPrint(allocator, "{s}.gguf", .{id});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ models_dir, filename });
}

pub fn upsert(allocator: std.mem.Allocator, registry_path: []const u8, model: Model) !void {
    try validateId(model.id);
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
        try items.appendSlice(list.models);
        try items.append(model);
        list.models = try items.toOwnedSlice();
    }
    try save(registry_path, list);
}

pub fn removeById(allocator: std.mem.Allocator, registry_path: []const u8, id: []const u8) !Model {
    try validateId(id);
    const list = try load(allocator, registry_path);
    var items = std.array_list.Managed(Model).init(allocator);
    var removed: ?Model = null;
    for (list.models) |m| {
        if (std.mem.eql(u8, m.id, id)) {
            removed = m;
        } else {
            try items.append(m);
        }
    }
    const found = removed orelse return errors.Error.ModelRegistryInvalid;
    try save(registry_path, .{ .models = try items.toOwnedSlice() });
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

pub fn verifyModel(allocator: std.mem.Allocator, m: Model) !void {
    if (m.path.len == 0) return errors.Error.ModelMissing;
    if (!sys.exists(m.path)) return errors.Error.ModelMissing;
    if (m.checksum.len > 0) try verifySha256(allocator, m.path, m.checksum);
}

pub const HfSpec = struct {
    repo: []const u8,
    quant: []const u8,
};

pub fn parseHfRepo(spec: []const u8) !HfSpec {
    if (spec.len == 0 or std.mem.indexOfScalar(u8, spec, '/') == null) return errors.Error.InvalidArguments;
    if (std.mem.lastIndexOfScalar(u8, spec, ':')) |idx| {
        if (idx == 0 or idx + 1 >= spec.len) return errors.Error.InvalidArguments;
        return .{ .repo = spec[0..idx], .quant = spec[idx + 1 ..] };
    }
    return .{ .repo = spec, .quant = "Q4_K_M" };
}

pub fn defaultIdFromHf(allocator: std.mem.Allocator, hf: HfSpec) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    for (hf.repo) |ch| {
        if (std.ascii.isAlphanumeric(ch)) try out.append(std.ascii.toLower(ch)) else try out.append('-');
    }
    try out.append('-');
    for (hf.quant) |ch| {
        if (std.ascii.isAlphanumeric(ch)) try out.append(std.ascii.toLower(ch)) else try out.append('-');
    }
    return out.toOwnedSlice();
}

pub fn hfDownloadUrl(allocator: std.mem.Allocator, repo: []const u8, filename: []const u8) ![]const u8 {
    try validateSingleHfGgufFilename(filename);
    return std.fmt.allocPrint(allocator, "https://huggingface.co/{s}/resolve/main/{s}", .{ repo, filename });
}

pub fn resolveHfFile(allocator: std.mem.Allocator, hf: HfSpec, explicit_file: []const u8) ![]const u8 {
    if (explicit_file.len > 0) {
        try validateSingleHfGgufFilename(explicit_file);
        return allocator.dupe(u8, explicit_file);
    }
    return findHfFile(allocator, hf.repo, hf.quant);
}

fn findHfFile(allocator: std.mem.Allocator, repo: []const u8, quant: []const u8) ![]const u8 {
    const url = try std.fmt.allocPrint(allocator, "https://huggingface.co/api/models/{s}", .{repo});
    defer allocator.free(url);
    const body = net.fetchAlloc(allocator, url, 16 * 1024 * 1024) catch return errors.Error.ModelRegistryInvalid;
    defer allocator.free(body);
    if (try findFilenameInHfJson(allocator, body, quant, true)) |name| {
        errdefer allocator.free(name);
        try validateSingleHfGgufFilename(name);
        return name;
    }
    return errors.Error.ModelRegistryInvalid;
}

fn findFilenameInHfJson(allocator: std.mem.Allocator, json: []const u8, quant: []const u8, require_quant: bool) !?[]const u8 {
    var found_split = false;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, json, start, "\"rfilename\"")) |key_idx| {
        const colon = std.mem.indexOfScalarPos(u8, json, key_idx, ':') orelse return null;
        const quote = std.mem.indexOfScalarPos(u8, json, colon + 1, '"') orelse return null;
        const end = std.mem.indexOfScalarPos(u8, json, quote + 1, '"') orelse return null;
        const name = json[quote + 1 .. end];
        start = end + 1;
        if (!std.mem.endsWith(u8, name, ".gguf")) continue;
        if (require_quant and !containsIgnoreCase(name, quant)) continue;
        if (isSplitGgufFilename(name)) {
            found_split = true;
            continue;
        }
        return try allocator.dupe(u8, name);
    }
    if (found_split) return errors.Error.SplitModelUnsupported;
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub fn acquire(allocator: std.mem.Allocator, m: Model, dest_path: []const u8, skip_download: bool) !void {
    if (skip_download or m.download_url.len == 0) return;
    if (dest_path.len == 0) return errors.Error.InvalidArguments;
    const temp_path = try tempPath(allocator, dest_path);
    defer allocator.free(temp_path);
    defer sys.deleteFile(temp_path);
    if (std.fs.path.dirname(temp_path)) |dir| try sys.makePath(dir);
    if (std.mem.startsWith(u8, m.download_url, "http://")) return errors.Error.InvalidArguments;
    if (std.mem.startsWith(u8, m.download_url, "https://")) {
        try downloadWithCurl(allocator, m.download_url, temp_path);
    } else if (std.mem.startsWith(u8, m.download_url, "file://")) {
        try copyFile(m.download_url["file://".len..], temp_path);
    } else {
        try copyFile(m.download_url, temp_path);
    }
    if (m.checksum.len > 0) try verifySha256(allocator, temp_path, m.checksum);
    try sys.renameFile(temp_path, dest_path);
}

pub fn installLocalFile(allocator: std.mem.Allocator, src: []const u8, dest: []const u8, checksum: []const u8) !void {
    const temp_path = try tempPath(allocator, dest);
    defer allocator.free(temp_path);
    defer sys.deleteFile(temp_path);
    try sys.copyFile(src, temp_path);
    if (checksum.len > 0) try verifySha256(allocator, temp_path, checksum);
    try sys.renameFile(temp_path, dest);
}

fn copyFile(src: []const u8, dest: []const u8) !void {
    try sys.copyFile(src, dest);
}

fn tempPath(allocator: std.mem.Allocator, dest_path: []const u8) ![]const u8 {
    var bytes: [8]u8 = undefined;
    const nonce = if (std.Io.randomSecure(sys.io(), &bytes)) |_| std.mem.readInt(u64, &bytes, .little) else |_| sys.millis();
    return std.fmt.allocPrint(allocator, "{s}.tmp-{x}", .{ dest_path, nonce });
}

fn downloadWithCurl(allocator: std.mem.Allocator, url: []const u8, dest: []const u8) !void {
    const result = try std.process.run(allocator, sys.io(), .{ .argv = &.{ "curl", "--fail", "--location", "--proto", "=https", "--tlsv1.2", "--output", dest, url }, .stdout_limit = .limited(64 * 1024), .stderr_limit = .limited(64 * 1024) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return errors.Error.ModelRegistryInvalid,
        else => return errors.Error.ModelRegistryInvalid,
    }
}

pub fn verifySha256(allocator: std.mem.Allocator, path: []const u8, expected_hex: []const u8) !void {
    var file = try sys.cwd().openFile(sys.io(), path, .{});
    defer file.close(sys.io());
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = file.readStreaming(sys.io(), &.{buf[0..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const actual = try hexDigest(allocator, digest);
    defer allocator.free(actual);
    if (!std.ascii.eqlIgnoreCase(expected_hex, actual)) return errors.Error.ChecksumFailed;
}

fn hexDigest(allocator: std.mem.Allocator, digest: [32]u8) ![]const u8 {
    var out = try allocator.alloc(u8, 64);
    const alphabet = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = alphabet[b >> 4];
        out[i * 2 + 1] = alphabet[b & 0x0f];
    }
    return out;
}

test "parse model list" {
    const list = try parse(std.heap.page_allocator, defaultTemplate());
    try std.testing.expect(list.models.len >= 1);
    try std.testing.expect(find(list, "custom") != null);
}

test "model ids reject path separators" {
    try validateId("local-ja_q4.0");
    try std.testing.expectError(errors.Error.InvalidArguments, validateId("../model"));
    try std.testing.expectError(errors.Error.InvalidArguments, validateId("bad/id"));
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

test "hugging face spec and url helpers" {
    const hf = try parseHfRepo("ggml-org/Example-GGUF:Q4_K_M");
    try std.testing.expectEqualStrings("ggml-org/Example-GGUF", hf.repo);
    try std.testing.expectEqualStrings("Q4_K_M", hf.quant);
    const id = try defaultIdFromHf(std.testing.allocator, hf);
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("ggml-org-example-gguf-q4-k-m", id);
    const url = try hfDownloadUrl(std.testing.allocator, hf.repo, "Example-Q4_K_M.gguf");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://huggingface.co/ggml-org/Example-GGUF/resolve/main/Example-Q4_K_M.gguf", url);
    const nested_url = try hfDownloadUrl(std.testing.allocator, hf.repo, "gguf/Example-Q4_K_M.gguf");
    defer std.testing.allocator.free(nested_url);
    try std.testing.expectEqualStrings("https://huggingface.co/ggml-org/Example-GGUF/resolve/main/gguf/Example-Q4_K_M.gguf", nested_url);
    try std.testing.expectError(errors.Error.InvalidArguments, hfDownloadUrl(std.testing.allocator, hf.repo, "../Example-Q4_K_M.gguf"));
    try std.testing.expectError(errors.Error.InvalidArguments, hfDownloadUrl(std.testing.allocator, hf.repo, "/Example-Q4_K_M.gguf"));
    try std.testing.expectError(errors.Error.InvalidArguments, hfDownloadUrl(std.testing.allocator, hf.repo, "gguf//Example-Q4_K_M.gguf"));
    try std.testing.expectError(errors.Error.InvalidArguments, hfDownloadUrl(std.testing.allocator, hf.repo, "gguf/Example-Q4_K_M.gguf?download=1"));
    try std.testing.expectError(errors.Error.SplitModelUnsupported, hfDownloadUrl(std.testing.allocator, hf.repo, "Example-Q4_K_M-00001-of-00002.gguf"));
}

test "resolveHfFile returns explicit file without metadata lookup" {
    const hf = try parseHfRepo("owner/repo:Q4_K_M");
    const file = try resolveHfFile(std.testing.allocator, hf, "nested/model-Q4_K_M.gguf");
    defer std.testing.allocator.free(file);
    try std.testing.expectEqualStrings("nested/model-Q4_K_M.gguf", file);
}

test "hugging face json selects quantized gguf" {
    const json =
        \\{"siblings":[{"rfilename":"README.md"},{"rfilename":"Model-F16.gguf"},{"rfilename":"Model-Q4_K_M.gguf"}]}
    ;
    const name = (try findFilenameInHfJson(std.testing.allocator, json, "Q4_K_M", true)) orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("Model-Q4_K_M.gguf", name);
}

test "hugging face json selects quantized gguf case-insensitively" {
    const json =
        \\{"siblings":[{"rfilename":"README.md"},{"rfilename":"Model-q4_k_m.gguf"}]}
    ;
    const name = (try findFilenameInHfJson(std.testing.allocator, json, "Q4_K_M", true)) orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("Model-q4_k_m.gguf", name);
}

test "hugging face json skips split gguf when a single-file match exists" {
    const json =
        \\{"siblings":[{"rfilename":"Model-Q4_K_M-00001-of-00002.gguf"},{"rfilename":"Model-Q4_K_M.gguf"}]}
    ;
    const name = (try findFilenameInHfJson(std.testing.allocator, json, "Q4_K_M", true)) orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("Model-Q4_K_M.gguf", name);
}

test "hugging face json reports split gguf when it is the only match" {
    const json =
        \\{"siblings":[{"rfilename":"Model-Q4_K_M-00001-of-00002.gguf"},{"rfilename":"Model-Q8_0.gguf"}]}
    ;
    try std.testing.expectError(errors.Error.SplitModelUnsupported, findFilenameInHfJson(std.testing.allocator, json, "Q4_K_M", true));
}

test "hugging face json does not fall back to the wrong quantization" {
    const json =
        \\{"siblings":[{"rfilename":"README.md"},{"rfilename":"Model-F16.gguf"}]}
    ;
    try std.testing.expect((try findFilenameInHfJson(std.testing.allocator, json, "Q4_K_M", true)) == null);
}

test "acquire local file verifies checksum" {
    const src = "/tmp/kotoba-model-acquire-src.gguf";
    const dest = "/tmp/kotoba-model-acquire-dest.gguf";
    sys.deleteFile(src);
    sys.deleteFile(dest);
    try sys.writeFile(src, "model bytes");
    const data = try sys.readFileAlloc(std.testing.allocator, src, 1024);
    defer std.testing.allocator.free(data);
    const checksum = try sys.hexSha256(std.testing.allocator, data);
    defer std.testing.allocator.free(checksum);
    const download_url = try std.fmt.allocPrint(std.testing.allocator, "file://{s}", .{src});
    defer std.testing.allocator.free(download_url);
    try acquire(std.testing.allocator, .{ .id = "local", .download_url = download_url, .checksum = checksum }, dest, false);
    const copied = try sys.readFileAlloc(std.testing.allocator, dest, 1024);
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("model bytes", copied);
}

test "acquire local file rejects checksum mismatch" {
    const src = "/tmp/kotoba-model-acquire-bad-src.gguf";
    const dest = "/tmp/kotoba-model-acquire-bad-dest.gguf";
    sys.deleteFile(src);
    sys.deleteFile(dest);
    try sys.writeFile(src, "model bytes");
    const download_url = try std.fmt.allocPrint(std.testing.allocator, "file://{s}", .{src});
    defer std.testing.allocator.free(download_url);
    try std.testing.expectError(errors.Error.ChecksumFailed, acquire(std.testing.allocator, .{ .id = "local", .download_url = download_url, .checksum = "deadbeef" }, dest, false));
}

test "acquire skip download does not require destination" {
    try acquire(std.testing.allocator, .{ .id = "local", .download_url = "/tmp/does-not-matter" }, "", true);
}
