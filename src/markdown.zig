const std = @import("std");

pub const Protected = struct {
    token: []const u8,
    original: []const u8,
};

pub const Document = struct {
    text: []const u8,
    protected: []Protected,

    pub fn deinit(self: Document, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        for (self.protected) |p| {
            allocator.free(p.token);
            allocator.free(p.original);
        }
        allocator.free(self.protected);
    }
};

pub fn protect(allocator: std.mem.Allocator, text: []const u8) !Document {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var protected = std.array_list.Managed(Protected).init(allocator);
    errdefer {
        for (protected.items) |p| {
            allocator.free(p.token);
            allocator.free(p.original);
        }
        protected.deinit();
    }
    var line_no: usize = 0;
    var in_fence = false;
    var frontmatter = false;
    var start: usize = 0;
    while (start <= text.len) : (line_no += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n');
        const end = nl orelse text.len;
        const line = text[start..end];
        const is_frontmatter_delim = line_no == 0 and std.mem.eql(u8, line, "---");
        if (is_frontmatter_delim) frontmatter = true;
        if (frontmatter or in_fence or std.mem.startsWith(u8, line, "```") or isTableLine(line)) {
            if (std.mem.startsWith(u8, line, "```")) in_fence = !in_fence;
            if (frontmatter and line_no > 0 and std.mem.eql(u8, line, "---")) frontmatter = false;
            try addProtected(allocator, &out, &protected, line);
        } else {
            try protectInline(allocator, &out, &protected, line);
        }
        if (nl == null) break;
        try out.append('\n');
        start = end + 1;
    }
    const owned_text = try out.toOwnedSlice();
    errdefer allocator.free(owned_text);
    const owned_protected = try protected.toOwnedSlice();
    return .{ .text = owned_text, .protected = owned_protected };
}

fn isTableLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    return trimmed.len > 0 and std.mem.indexOfScalar(u8, trimmed, '|') != null;
}

fn protectInline(allocator: std.mem.Allocator, out: *std.array_list.Managed(u8), protected: *std.array_list.Managed(Protected), line: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) {
        if (std.mem.startsWith(u8, line[i..], "![")) {
            if (findMarkdownLinkEnd(line, i)) |end| {
                try addProtected(allocator, out, protected, line[i .. end + 1]);
                i = end + 1;
            } else {
                try out.append(line[i]);
                i += 1;
            }
        } else if (line[i] == '`') {
            const end = std.mem.indexOfScalarPos(u8, line, i + 1, '`') orelse line.len - 1;
            try addProtected(allocator, out, protected, line[i .. end + 1]);
            i = end + 1;
        } else if (line[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, line, i + 1, '>') orelse line.len - 1;
            try addProtected(allocator, out, protected, line[i .. end + 1]);
            i = end + 1;
        } else if (std.mem.startsWith(u8, line[i..], "http://") or std.mem.startsWith(u8, line[i..], "https://")) {
            var end = i;
            while (end < line.len and !std.ascii.isWhitespace(line[end])) end += 1;
            try addProtected(allocator, out, protected, line[i..end]);
            i = end;
        } else {
            try out.append(line[i]);
            i += 1;
        }
    }
}

fn findMarkdownLinkEnd(line: []const u8, start: usize) ?usize {
    const close_bracket = std.mem.indexOfScalarPos(u8, line, start, ']') orelse return null;
    if (close_bracket + 1 >= line.len or line[close_bracket + 1] != '(') return null;
    return std.mem.indexOfScalarPos(u8, line, close_bracket + 2, ')');
}

fn addProtected(allocator: std.mem.Allocator, out: *std.array_list.Managed(u8), protected: *std.array_list.Managed(Protected), original: []const u8) !void {
    const token = try std.fmt.allocPrint(allocator, "KOTOBA_PROTECT_{d:0>6}", .{protected.items.len + 1});
    var token_owned = true;
    errdefer if (token_owned) allocator.free(token);
    const original_copy = try allocator.dupe(u8, original);
    var original_owned = true;
    errdefer if (original_owned) allocator.free(original_copy);
    try protected.append(.{ .token = token, .original = original_copy });
    token_owned = false;
    original_owned = false;
    try out.appendSlice(token);
}

/// Restores protected bytes into caller-owned output. Warning entries borrow static text.
/// On error, `warnings` remains valid and deinitializable, and may contain entries appended
/// before the failing allocation; warning entries are not rolled back.
pub fn restore(allocator: std.mem.Allocator, text: []const u8, protected: []Protected, warnings: *std.array_list.Managed([]const u8)) ![]u8 {
    var out = try allocator.dupe(u8, text);
    errdefer allocator.free(out);
    for (protected) |p| {
        if (std.mem.indexOf(u8, out, p.token) == null) {
            try warnings.append("protected token missing from translation");
            continue;
        }
        const replaced = try std.mem.replaceOwned(u8, allocator, out, p.token, p.original);
        allocator.free(out);
        out = replaced;
    }
    return out;
}

test "protects code and table" {
    const doc = try protect(std.testing.allocator, "# Hello\n\n| A | B |\n| - | - |\n\n`code`");
    defer doc.deinit(std.testing.allocator);
    try std.testing.expect(doc.protected.len >= 3);
}

test "protects frontmatter image html and links" {
    const doc = try protect(std.testing.allocator,
        \\---
        \\title: Hello
        \\---
        \\
        \\See [Kotoba](https://example.com/docs) and ![logo](./logo.png).
        \\Keep <kbd>Ctrl</kbd>.
    );
    defer doc.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, doc.text, "https://example.com/docs") == null);
    try std.testing.expect(std.mem.indexOf(u8, doc.text, "![logo](./logo.png)") == null);
    try std.testing.expect(std.mem.indexOf(u8, doc.text, "<kbd>") == null);
    try std.testing.expect(doc.protected.len >= 6);
}

test "protect and restore round trip preserves protected edge tokens" {
    const source =
        \\---
        \\title: Doc
        \\---
        \\
        \\Use `inline and https://example.com/path?q=1 plus <kbd>Ctrl</kbd> and ![img](./img.png)
    ;
    const doc = try protect(std.testing.allocator, source);
    defer doc.deinit(std.testing.allocator);

    var warnings = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer warnings.deinit();
    const restored = try restore(std.testing.allocator, doc.text, doc.protected, &warnings);
    defer std.testing.allocator.free(restored);

    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
    try std.testing.expectEqualStrings(source, restored);
}

test "restore appends warning when token missing" {
    const doc = try protect(std.testing.allocator, "`code` and https://example.com");
    defer doc.deinit(std.testing.allocator);

    var warnings = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer warnings.deinit();
    const restored = try restore(std.testing.allocator, "translation without protected tokens", doc.protected, &warnings);
    defer std.testing.allocator.free(restored);

    try std.testing.expect(warnings.items.len >= 1);
    try std.testing.expectEqualStrings("protected token missing from translation", warnings.items[0]);
    try std.testing.expectEqualStrings("translation without protected tokens", restored);
}

test "protect handles empty input" {
    const doc = try protect(std.testing.allocator, "");
    defer doc.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", doc.text);
    try std.testing.expectEqual(@as(usize, 0), doc.protected.len);
}

test "protect handles unmatched backtick gracefully" {
    const doc = try protect(std.testing.allocator, "`unclosed");
    defer doc.deinit(std.testing.allocator);
    try std.testing.expect(doc.protected.len >= 1);
}

test "protect handles unmatched html tag gracefully" {
    const doc = try protect(std.testing.allocator, "<unclosed");
    defer doc.deinit(std.testing.allocator);
    try std.testing.expect(doc.protected.len >= 1);
}

test "protect handles unmatched link gracefully" {
    const doc = try protect(std.testing.allocator, "![unclosed");
    defer doc.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), doc.protected.len);
}

test "protect and restore preserves nested markdown" {
    const source =
        \\# Title
        \\
        \\`code with [link](https://example.com)`
        \\
        \\| Table | Col |
        \\|-------|-----|
        \\| A     | B   |
    ;
    const doc = try protect(std.testing.allocator, source);
    defer doc.deinit(std.testing.allocator);

    var warnings = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer warnings.deinit();
    const restored = try restore(std.testing.allocator, doc.text, doc.protected, &warnings);
    defer std.testing.allocator.free(restored);

    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
    try std.testing.expectEqualStrings(source, restored);
}

fn checkProtectAllocationFailures(allocator: std.mem.Allocator, source: []const u8) !void {
    const doc = try protect(allocator, source);
    doc.deinit(allocator);
}

fn checkRestoreAllocationFailures(allocator: std.mem.Allocator, source: []const u8, missing: bool) !void {
    const doc = try protect(allocator, source);
    defer doc.deinit(allocator);
    var warnings = std.array_list.Managed([]const u8).init(allocator);
    defer warnings.deinit();
    const translation = if (missing) "translated" else doc.text;
    const restored = try restore(allocator, translation, doc.protected, &warnings);
    defer allocator.free(restored);
    if (missing) {
        try std.testing.expectEqualStrings("translated", restored);
        try std.testing.expect(warnings.items.len > 0);
        try std.testing.expectEqualStrings("protected token missing from translation", warnings.items[0]);
    } else {
        try std.testing.expectEqualStrings(source, restored);
        try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
    }
}

fn checkRepeatedTokenRestoreAllocationFailures(allocator: std.mem.Allocator) !void {
    var protected = [_]Protected{.{
        .token = "TOKEN",
        .original = "expanded protected bytes with enough length to grow output",
    }};
    const translated = "TOKEN TOKEN TOKEN TOKEN TOKEN TOKEN TOKEN TOKEN TOKEN TOKEN TOKEN TOKEN";
    var warnings = std.array_list.Managed([]const u8).init(allocator);
    defer warnings.deinit();
    const restored = try restore(allocator, translated, protected[0..], &warnings);
    defer allocator.free(restored);
    try std.testing.expect(restored.len > translated.len);
    try std.testing.expect(std.mem.indexOf(u8, restored, "TOKEN") == null);
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
}

test "ownership/markdown allocation failures clean partial ownership transfers" {
    inline for (.{
        "",
        "---\ntitle: Hello\n---\nbody",
        "| A | B |\n| - | - |\n| one | two |",
        "`code` and <kbd>Ctrl</kbd>",
        "See [site](https://example.test/a?q=1) and ![logo](./logo.png)",
        "`one` and `two` and https://example.com/path and ![logo](./logo.png) and <kbd>x</kbd>",
    }) |source| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, checkProtectAllocationFailures, .{source});
    }
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkRestoreAllocationFailures, .{
        "`one` and `two` and https://example.com/path and ![logo](./logo.png)",
        false,
    });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkRestoreAllocationFailures, .{
        "`one` `two` `three` `four` `five` `six` `seven` `eight` `nine` `ten` `eleven` `twelve` `thirteen` `fourteen` `fifteen` `sixteen`",
        true,
    });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkRepeatedTokenRestoreAllocationFailures, .{});
}
