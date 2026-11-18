const std = @import("std");
const markdown = @import("markdown.zig");

pub const Segment = struct {
    text: []const u8,
    translatable: bool = true,
};

pub fn splitParagraphs(allocator: std.mem.Allocator, text: []const u8, token_prefix: ?[]const u8) ![]Segment {
    var list = std.array_list.Managed(Segment).init(allocator);
    errdefer list.deinit();
    var start: usize = 0;
    var i: usize = 0;
    var protected_line = if (token_prefix) |prefix| isProtectedLine(text, prefix) else false;
    while (i < text.len) {
        const first = newlineLength(text[i..]);
        if (first == 0) {
            i += 1;
            continue;
        }
        var end = i + first;
        while (true) {
            const next = newlineLength(text[end..]);
            if (next == 0) break;
            end += next;
        }
        const next_protected_line = if (token_prefix) |prefix| isProtectedLine(text[end..], prefix) else false;
        const blank_line = end > i + first;
        // Protected Markdown lines can touch prose without a blank separator.
        const block_boundary = end < text.len and protected_line != next_protected_line;
        if (blank_line or block_boundary) {
            if (i > start) try appendSegment(&list, text[start..i], token_prefix);
            try list.append(.{ .text = text[i..end], .translatable = false });
            start = end;
        }
        protected_line = next_protected_line;
        i = end;
    }
    if (start < text.len) try appendSegment(&list, text[start..], token_prefix);
    if (list.items.len == 0) try list.append(.{ .text = text });
    return list.toOwnedSlice();
}

fn newlineLength(text: []const u8) usize {
    if (text.len > 0 and text[0] == '\n') return 1;
    if (std.mem.startsWith(u8, text, "\r\n")) return 2;
    return 0;
}

fn appendSegment(list: *std.array_list.Managed(Segment), text: []const u8, token_prefix: ?[]const u8) !void {
    try list.append(.{ .text = text, .translatable = if (token_prefix) |prefix| !isProtectedOnly(text, prefix) else true });
}

fn isProtectedLine(text: []const u8, prefix: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return isProtectedOnly(text[0..end], prefix);
}

fn isProtectedOnly(text: []const u8, prefix: []const u8) bool {
    var i: usize = 0;
    var saw_token = false;
    while (i < text.len) {
        if (std.ascii.isWhitespace(text[i])) {
            i += 1;
            continue;
        }
        const token = markdown.tokenAt(text[i..], prefix) orelse return false;
        saw_token = true;
        i += token.len;
    }
    return saw_token;
}

test "paragraph split preserves LF CRLF and mixed separators" {
    for ([_][]const u8{ "\n\n", "\r\n\r\n", "\r\n\n\r\n" }) |separator| {
        const text = try std.fmt.allocPrint(std.testing.allocator, "a{s}b", .{separator});
        defer std.testing.allocator.free(text);
        const segments = try splitParagraphs(std.testing.allocator, text, null);
        defer std.testing.allocator.free(segments);
        try std.testing.expectEqual(@as(usize, 3), segments.len);
        try std.testing.expectEqualStrings("a", segments[0].text);
        try std.testing.expectEqualStrings(separator, segments[1].text);
        try std.testing.expect(!segments[1].translatable);
        try std.testing.expectEqualStrings("b", segments[2].text);
    }
}

test "only tokens in the active Markdown namespace skip translation" {
    const text = "KOTOBA_PROTECT_1_\nKOTOBA_PROTECT_2_";
    for ([_]?[]const u8{ null, "KOTOBA_PROTECT_alternate_", "KOTOBA_PROTECT_" }, [_]bool{ true, true, false }) |prefix, translatable| {
        const segments = try splitParagraphs(std.testing.allocator, text, prefix);
        defer std.testing.allocator.free(segments);
        try std.testing.expectEqual(@as(usize, 1), segments.len);
        try std.testing.expectEqual(translatable, segments[0].translatable);
    }
}
