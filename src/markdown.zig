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
    var protected = std.array_list.Managed(Protected).init(allocator);
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
            const token = try std.fmt.allocPrint(allocator, "KOTOBA_PROTECT_{d:0>6}", .{protected.items.len + 1});
            try protected.append(.{ .token = token, .original = try allocator.dupe(u8, line) });
            try out.appendSlice(token);
        } else {
            try protectInline(allocator, &out, &protected, line);
        }
        if (nl == null) break;
        try out.append('\n');
        start = end + 1;
    }
    return .{ .text = try out.toOwnedSlice(), .protected = try protected.toOwnedSlice() };
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
    try protected.append(.{ .token = token, .original = try allocator.dupe(u8, original) });
    try out.appendSlice(token);
}

pub fn restore(allocator: std.mem.Allocator, text: []const u8, protected: []Protected, warnings: *std.array_list.Managed([]const u8)) ![]u8 {
    var out = try allocator.dupe(u8, text);
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
