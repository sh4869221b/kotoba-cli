const std = @import("std");
const errors = @import("errors.zig");
const sys = @import("sys.zig");

pub const Kind = enum { text, markdown };

pub const ReadResult = struct {
    text: []const u8,
    kind: Kind,
    file_path: ?[]const u8 = null,
};

pub fn read(allocator: std.mem.Allocator, direct_text: ?[]const u8, file_path: ?[]const u8) !ReadResult {
    if (direct_text != null and file_path != null) return errors.Error.InvalidArguments;
    if (direct_text) |t| {
        if (t.len == 0) return errors.Error.InvalidArguments;
        return .{ .text = try allocator.dupe(u8, t), .kind = .text };
    }
    if (file_path) |p| {
        const data = try sys.readFileAlloc(allocator, p, 64 * 1024 * 1024);
        if (data.len == 0) return errors.Error.InvalidArguments;
        return .{ .text = data, .kind = if (isMarkdown(p)) .markdown else .text, .file_path = p };
    }
    const stdin = try sys.readStdinAlloc(allocator, 64 * 1024 * 1024);
    if (stdin.len == 0) {
        allocator.free(stdin);
        return errors.Error.InvalidArguments;
    }
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
