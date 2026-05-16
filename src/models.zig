const std = @import("std");
const errors = @import("errors.zig");
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
        } else if (std.mem.eql(u8, p.key, "format")) m.format = try allocator.dupe(u8, val) else if (std.mem.eql(u8, p.key, "quantization")) m.quantization = try allocator.dupe(u8, val) else if (std.mem.eql(u8, p.key, "context_length")) m.context_length = toml.intValue(p.value) orelse 0 else if (std.mem.eql(u8, p.key, "size")) m.size = try allocator.dupe(u8, val) else if (std.mem.eql(u8, p.key, "download_url")) m.download_url = try allocator.dupe(u8, val) else if (std.mem.eql(u8, p.key, "checksum")) m.checksum = try allocator.dupe(u8, val) else if (std.mem.eql(u8, p.key, "license")) m.license = try allocator.dupe(u8, val) else if (std.mem.eql(u8, p.key, "recommended")) m.recommended = toml.boolValue(p.value) orelse false else if (std.mem.eql(u8, p.key, "notes")) m.notes = try allocator.dupe(u8, val);
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

pub fn acquire(allocator: std.mem.Allocator, m: Model, dest_path: []const u8, skip_download: bool) !void {
    if (skip_download or m.download_url.len == 0) return;
    if (dest_path.len == 0) return errors.Error.InvalidArguments;
    if (std.mem.startsWith(u8, m.download_url, "http://")) return errors.Error.InvalidArguments;
    if (std.mem.startsWith(u8, m.download_url, "https://")) {
        try downloadWithCurl(allocator, m.download_url, dest_path);
    } else if (std.mem.startsWith(u8, m.download_url, "file://")) {
        try copyFile(m.download_url["file://".len..], dest_path);
    } else {
        try copyFile(m.download_url, dest_path);
    }
    if (m.checksum.len > 0) try verifySha256(allocator, dest_path, m.checksum);
}

fn copyFile(src: []const u8, dest: []const u8) !void {
    const data = try sys.readFileAlloc(std.heap.page_allocator, src, 1024 * 1024 * 1024);
    defer std.heap.page_allocator.free(data);
    try sys.writeFile(dest, data);
}

fn downloadWithCurl(allocator: std.mem.Allocator, url: []const u8, dest: []const u8) !void {
    const result = try std.process.run(allocator, sys.io(), .{ .argv = &.{ "/usr/bin/curl", "--fail", "--location", "--proto", "=https", "--tlsv1.2", "--output", dest, url }, .stdout_limit = .limited(64 * 1024), .stderr_limit = .limited(64 * 1024) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return errors.Error.ServerBadResponse,
        else => return errors.Error.ServerBadResponse,
    }
}

pub fn verifySha256(allocator: std.mem.Allocator, path: []const u8, expected_hex: []const u8) !void {
    const data = try sys.readFileAlloc(allocator, path, 1024 * 1024 * 1024);
    defer allocator.free(data);
    const actual = try sys.hexSha256(allocator, data);
    defer allocator.free(actual);
    if (!std.ascii.eqlIgnoreCase(expected_hex, actual)) return errors.Error.ChecksumFailed;
}

test "parse model list" {
    const list = try parse(std.heap.page_allocator, defaultTemplate());
    try std.testing.expect(list.models.len >= 1);
    try std.testing.expect(find(list, "custom") != null);
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
