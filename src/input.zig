const std = @import("std");
const errors = @import("errors.zig");
const sys = @import("sys.zig");
const text = @import("text.zig");

pub const Kind = enum { text, markdown };

pub const ReadResult = struct {
    text: []const u8,
    kind: Kind,
    file_path: ?[]const u8 = null,
};

pub fn read(allocator: std.mem.Allocator, direct_text: ?[]const u8, file_path: ?[]const u8) !ReadResult {
    if (direct_text != null and file_path != null) return errors.Error.InvalidArguments;
    if (direct_text) |t| {
        try text.validate(t);
        if (t.len == 0) return errors.Error.InvalidArguments;
        return .{ .text = try allocator.dupe(u8, t), .kind = .text };
    }
    if (file_path) |p| {
        const data = try sys.readFileAlloc(allocator, p, 64 * 1024 * 1024);
        errdefer allocator.free(data);
        try text.validate(data);
        if (data.len == 0) return errors.Error.InvalidArguments;
        return .{ .text = data, .kind = if (isMarkdown(p)) .markdown else .text, .file_path = p };
    }
    const stdin = try sys.readStdinAlloc(allocator, 64 * 1024 * 1024);
    errdefer allocator.free(stdin);
    try text.validate(stdin);
    if (stdin.len == 0) return errors.Error.InvalidArguments;
    return .{ .text = stdin, .kind = .text };
}

pub fn isMarkdown(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".markdown");
}

pub fn defaultMarkdownOutput(allocator: std.mem.Allocator, path: []const u8, target: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, path, ".md")) {
        return std.fmt.allocPrint(allocator, "{s}.{s}.md", .{ path[0 .. path.len - 3], target });
    }
    return std.fmt.allocPrint(allocator, "{s}.{s}.md", .{ path, target });
}

test "input text contract preserves direct and file bytes" {
    const allocator = std.testing.allocator;

    const direct = try read(allocator, "こんにちは😀", null);
    defer allocator.free(direct.text);
    try std.testing.expectEqual(Kind.text, direct.kind);
    try std.testing.expectEqualStrings("こんにちは😀", direct.text);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "source.md" });
    defer allocator.free(path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.md", .data = "e\u{301}" });

    const file = try read(allocator, null, path);
    defer allocator.free(file.text);
    try std.testing.expectEqual(Kind.markdown, file.kind);
    try std.testing.expectEqualStrings("e\u{301}", file.text);
    try std.testing.expectEqualStrings(path, file.file_path.?);
}

test "input text contract rejects invalid direct and file bytes" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidUtf8, read(allocator, "\xE3\x81", null));
    try std.testing.expectError(error.EmbeddedNul, read(allocator, "A\x00B", null));
    try std.testing.expectError(errors.Error.InvalidArguments, read(allocator, "", null));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const malformed_path = try std.fs.path.join(allocator, &.{ root, "malformed.md" });
    defer allocator.free(malformed_path);
    const nul_path = try std.fs.path.join(allocator, &.{ root, "nul.txt" });
    defer allocator.free(nul_path);
    const empty_path = try std.fs.path.join(allocator, &.{ root, "empty.txt" });
    defer allocator.free(empty_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "malformed.md", .data = "\xE3\x81" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "nul.txt", .data = "A\x00B" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "empty.txt", .data = "" });

    try std.testing.expectError(error.InvalidUtf8, read(allocator, null, malformed_path));
    try std.testing.expectError(error.EmbeddedNul, read(allocator, null, nul_path));
    try std.testing.expectError(errors.Error.InvalidArguments, read(allocator, null, empty_path));
}
