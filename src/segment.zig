const std = @import("std");

pub const Segment = struct {
    text: []const u8,
    translatable: bool = true,
};

pub fn splitParagraphs(allocator: std.mem.Allocator, text: []const u8) ![]Segment {
    var list = std.array_list.Managed(Segment).init(allocator);
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (i + 1 < text.len and text[i] == '\n' and text[i + 1] == '\n') {
            if (i > start) try appendSegment(&list, text[start..i]);
            try list.append(.{ .text = text[i .. i + 2], .translatable = false });
            i += 1;
            start = i + 1;
        }
    }
    if (start < text.len) try appendSegment(&list, text[start..]);
    if (list.items.len == 0) try list.append(.{ .text = text });
    return list.toOwnedSlice();
}

fn appendSegment(list: *std.array_list.Managed(Segment), text: []const u8) !void {
    try list.append(.{ .text = text, .translatable = !isProtectedOnly(text) });
}

fn isProtectedOnly(text: []const u8) bool {
    var i: usize = 0;
    var saw_token = false;
    while (i < text.len) {
        if (std.ascii.isWhitespace(text[i])) {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, text[i..], "KOTOBA_PROTECT_") and i + "KOTOBA_PROTECT_000000".len <= text.len) {
            const token_end = i + "KOTOBA_PROTECT_000000".len;
            for (text[i + "KOTOBA_PROTECT_".len .. token_end]) |ch| {
                if (!std.ascii.isDigit(ch)) return false;
            }
            saw_token = true;
            i = token_end;
            continue;
        }
        return false;
    }
    return saw_token;
}

test "paragraph split preserves blank" {
    const s = try splitParagraphs(std.testing.allocator, "a\n\nb");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqual(@as(usize, 3), s.len);
}

test "protected-only segments are not translatable" {
    const s = try splitParagraphs(std.testing.allocator, "KOTOBA_PROTECT_000001\nKOTOBA_PROTECT_000002");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqual(@as(usize, 1), s.len);
    try std.testing.expect(!s[0].translatable);
}
