const std = @import("std");

const token_base = "KOTOBA_PROTECT_";

pub const Document = struct {
    text: []const u8,
    token_prefix: []const u8,
    protected: [][]const u8,

    pub fn deinit(self: Document, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.token_prefix);
        for (self.protected) |original| allocator.free(original);
        allocator.free(self.protected);
    }

    /// Scan the translation once so restored source bytes are never interpreted as tokens.
    pub fn restore(self: Document, allocator: std.mem.Allocator, text: []const u8, warnings: *std.array_list.Managed([]const u8)) ![]u8 {
        if (self.protected.len == 0) return allocator.dupe(u8, text);
        const seen = try allocator.alloc(bool, self.protected.len);
        defer allocator.free(seen);
        @memset(seen, false);
        var out = std.array_list.Managed(u8).init(allocator);
        errdefer out.deinit();

        var start: usize = 0;
        while (std.mem.indexOfPos(u8, text, start, self.token_prefix)) |pos| {
            const token = tokenAt(text[pos..], self.token_prefix);
            if (token != null and token.?.index < self.protected.len) {
                const entry = token.?;
                try out.appendSlice(text[start..pos]);
                try out.appendSlice(self.protected[entry.index]);
                seen[entry.index] = true;
                start = pos + entry.len;
            } else {
                const next = pos + self.token_prefix.len;
                try out.appendSlice(text[start..next]);
                start = next;
            }
        }
        try out.appendSlice(text[start..]);
        for (seen) |found| {
            if (!found) try warnings.append("protected token missing from translation");
        }
        return out.toOwnedSlice();
    }
};

pub fn tokenAt(text: []const u8, prefix: []const u8) ?struct { index: usize, len: usize } {
    if (!std.mem.startsWith(u8, text, prefix) or text.len <= prefix.len) return null;
    if (text[prefix.len] == '0') return null;
    var end = prefix.len;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    if (end == prefix.len or end == text.len or text[end] != '_') return null;
    const number = std.fmt.parseUnsigned(usize, text[prefix.len..end], 10) catch return null;
    return .{ .index = number - 1, .len = end + 1 };
}

fn tokenPrefix(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, text, token_base) == null) return allocator.dupe(u8, token_base);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..8].*, .lower);
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const prefix = try std.fmt.allocPrint(allocator, token_base ++ "{s}_{d}_", .{ &hex, attempt });
        if (std.mem.indexOf(u8, text, prefix) == null) return prefix;
        allocator.free(prefix);
    }
}

const Protection = struct {
    text: std.array_list.Managed(u8),
    originals: std.array_list.Managed([]const u8),
    token_prefix: []const u8,

    fn add(self: *Protection, original: []const u8) !void {
        if (original.len == 0) return;
        const allocator = self.originals.allocator;
        {
            const copy = try allocator.dupe(u8, original);
            errdefer allocator.free(copy);
            try self.originals.append(copy);
        }
        try self.text.print("{s}{d}_", .{ self.token_prefix, self.originals.items.len });
    }
};

pub fn protect(allocator: std.mem.Allocator, text: []const u8) !Document {
    const prefix = try tokenPrefix(allocator, text);
    errdefer allocator.free(prefix);
    var protection: Protection = .{
        .text = .init(allocator),
        .originals = .init(allocator),
        .token_prefix = prefix,
    };
    errdefer {
        protection.text.deinit();
        for (protection.originals.items) |original| allocator.free(original);
        protection.originals.deinit();
    }

    const frontmatter_end = frontMatterEnd(text);
    var fence: ?Fence = null;
    var table: ?Table = null;
    var start: usize = 0;
    while (start < text.len) {
        const line = lineAt(text, start);
        if (start < frontmatter_end) {
            try protection.add(line.body);
        } else if (fence) |open| {
            try protection.add(line.body);
            if (fenceAt(line.body)) |close| {
                if (close.marker == open.marker and close.len >= open.len and close.rest.len == 0) fence = null;
            }
        } else if (openingFence(line.body)) |open| {
            table = null;
            fence = open;
            try protection.add(line.body);
        } else if (isTableLine(text, line.body, line.next, &table)) {
            try protection.add(line.body);
        } else {
            try protectInline(&protection, line.body);
        }
        try protection.text.appendSlice(text[start + line.body.len .. line.next]);
        start = line.next;
    }
    const owned_text = try protection.text.toOwnedSlice();
    errdefer allocator.free(owned_text);
    const originals = try protection.originals.toOwnedSlice();
    return .{ .text = owned_text, .token_prefix = prefix, .protected = originals };
}

fn lineAt(text: []const u8, start: usize) struct { body: []const u8, next: usize } {
    const lf = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return .{ .body = text[start..], .next = text.len };
    const body_end = if (lf > start and text[lf - 1] == '\r') lf - 1 else lf;
    return .{ .body = text[start..body_end], .next = lf + 1 };
}

fn frontMatterEnd(text: []const u8) usize {
    const first = lineAt(text, 0);
    if (!std.mem.eql(u8, first.body, "---")) return 0;
    var pos = first.next;
    while (pos < text.len) {
        const line = lineAt(text, pos);
        if (std.mem.eql(u8, line.body, "---") or std.mem.eql(u8, line.body, "...")) return line.next;
        pos = line.next;
    }
    return 0;
}

const Fence = struct { marker: u8, len: usize, rest: []const u8 };

fn fenceAt(line: []const u8) ?Fence {
    const trimmed = std.mem.trimStart(u8, line, " ");
    if (line.len - trimmed.len > 3 or trimmed.len == 0) return null;
    const marker = trimmed[0];
    if (marker != '`' and marker != '~') return null;
    const len = runEnd(trimmed, 0);
    if (len < 3) return null;
    return .{ .marker = marker, .len = len, .rest = std.mem.trim(u8, trimmed[len..], " \t") };
}

fn openingFence(line: []const u8) ?Fence {
    const fence = fenceAt(line) orelse return null;
    if (fence.marker == '`' and std.mem.indexOfScalar(u8, fence.rest, '`') != null) return null;
    return fence;
}

fn runEnd(line: []const u8, start: usize) usize {
    var end = start + 1;
    while (end < line.len and line[end] == line[start]) end += 1;
    return end;
}

fn codeSpanEnd(line: []const u8, start: usize, open_end: usize) ?usize {
    var pos = open_end;
    while (std.mem.indexOfScalarPos(u8, line, pos, '`')) |tick| {
        pos = runEnd(line, tick);
        if (pos - tick == open_end - start) return pos;
    }
    return null;
}

const Table = struct { depth: usize, delimiter_pending: bool = true };

const QuotedLine = struct { text: []const u8, depth: usize = 0 };

fn quotedLine(line: []const u8) QuotedLine {
    var result: QuotedLine = .{ .text = line };
    while (true) {
        const trimmed = std.mem.trimStart(u8, result.text, " ");
        if (result.text.len - trimmed.len > 3 or !std.mem.startsWith(u8, trimmed, ">")) return result;
        result.depth += 1;
        result.text = if (trimmed.len > 1 and trimmed[1] == ' ') trimmed[2..] else trimmed[1..];
    }
}

fn isTableLine(text: []const u8, body: []const u8, next: usize, table: *?Table) bool {
    const current = quotedLine(body);
    if (table.*) |*active| {
        if (active.depth == current.depth) {
            if (active.delimiter_pending) {
                active.delimiter_pending = false;
                return true;
            }
            if (!startsTableEndingBlock(current.text)) return true;
        }
        table.* = null;
    }
    if (next == text.len or startsTableEndingBlock(current.text)) return false;
    const cells = tableCells(current.text, false) orelse return false;
    const delimiter = quotedLine(lineAt(text, next).body);
    if (delimiter.depth != current.depth or tableCells(delimiter.text, true) != cells) return false;
    table.* = .{ .depth = current.depth };
    return true;
}

fn startsTableEndingBlock(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0 or openingFence(line) != null) return true;
    const first = trimmed[0];
    const rest = trimmed[1..];
    if (startsInterruptingHtmlBlock(line)) return true;
    if (first == '#') {
        const end = runEnd(trimmed, 0);
        if (end <= 6 and (end == trimmed.len or std.ascii.isWhitespace(trimmed[end]))) return true;
    }
    if (std.mem.indexOfScalar(u8, "*+-", first) != null and
        (rest.len == 0 or std.ascii.isWhitespace(rest[0]))) return true;
    if (std.mem.indexOfScalar(u8, "-_*", first) != null) {
        var markers: usize = 0;
        for (trimmed) |ch| {
            if (ch == first) markers += 1 else if (ch != ' ' and ch != '\t') break;
        } else if (markers >= 3) return true;
    }
    var digits: usize = 0;
    while (digits < trimmed.len and std.ascii.isDigit(trimmed[digits])) : (digits += 1) {}
    return digits > 0 and digits <= 9 and digits < trimmed.len and
        (trimmed[digits] == '.' or trimmed[digits] == ')') and
        (digits + 1 == trimmed.len or std.ascii.isWhitespace(trimmed[digits + 1]));
}

/// GFM HTML block types 1–6 can interrupt a table. A generic inline tag
/// followed by text is not an HTML block start.
fn startsInterruptingHtmlBlock(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " ");
    if (line.len - trimmed.len > 3 or !std.mem.startsWith(u8, trimmed, "<")) return false;
    if (std.mem.startsWith(u8, trimmed, "<!--") or std.mem.startsWith(u8, trimmed, "<?") or
        std.mem.startsWith(u8, trimmed, "<![CDATA[")) return true;
    if (trimmed.len > 2 and trimmed[1] == '!' and std.ascii.isUpper(trimmed[2])) return true;

    const closing = trimmed.len > 1 and trimmed[1] == '/';
    const start: usize = if (closing) 2 else 1;
    var end = start;
    while (end < trimmed.len and (std.ascii.isAlphanumeric(trimmed[end]) or trimmed[end] == '-')) end += 1;
    if (start == end) return false;
    const tag = trimmed[start..end];
    const tail = trimmed[end..];
    const standard_end = tail.len == 0 or std.ascii.isWhitespace(tail[0]) or tail[0] == '>';
    if (standard_end and !closing and
        (std.ascii.eqlIgnoreCase(tag, "script") or std.ascii.eqlIgnoreCase(tag, "pre") or
            std.ascii.eqlIgnoreCase(tag, "style"))) return true;
    if (!standard_end and !std.mem.startsWith(u8, tail, "/>")) return false;

    var block_tags = std.mem.splitScalar(
        u8,
        "address article aside base basefont blockquote body caption center col colgroup dd details dialog dir div dl dt " ++
            "fieldset figcaption figure footer form frame frameset h1 h2 h3 h4 h5 h6 head header hr html iframe legend li link " ++
            "main menu menuitem nav noframes ol optgroup option p param section source summary table tbody td tfoot th thead title tr track ul",
        ' ',
    );
    while (block_tags.next()) |name| {
        if (std.ascii.eqlIgnoreCase(name, tag)) return true;
    }
    return false;
}

/// Count cells separated by unescaped pipes outside matched inline code.
fn tableCells(line: []const u8, delimiter: bool) ?usize {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    var saw_pipe = trimmed[0] == '|';
    var start: usize = @intFromBool(saw_pipe);
    var cells: usize = 0;
    var pos = start;
    while (pos < trimmed.len) {
        switch (trimmed[pos]) {
            '\\' => pos += @min(2, trimmed.len - pos),
            '`' => {
                const open_end = runEnd(trimmed, pos);
                pos = codeSpanEnd(trimmed, pos, open_end) orelse open_end;
            },
            '|' => {
                if (delimiter and !isDelimiterCell(trimmed[start..pos])) return null;
                saw_pipe = true;
                cells += 1;
                pos += 1;
                start = pos;
            },
            else => pos += 1,
        }
    }
    if (start < trimmed.len) {
        if (delimiter and !isDelimiterCell(trimmed[start..])) return null;
        cells += 1;
    }
    // A delimiter can omit its outer pipes for a one-column header.
    return if ((saw_pipe or delimiter) and cells > 0) cells else null;
}

fn isDelimiterCell(text: []const u8) bool {
    var cell = std.mem.trim(u8, text, " \t");
    if (std.mem.startsWith(u8, cell, ":")) cell = cell[1..];
    if (std.mem.endsWith(u8, cell, ":")) cell = cell[0 .. cell.len - 1];
    if (cell.len == 0) return false;
    for (cell) |ch| {
        if (ch != '-') return false;
    }
    return true;
}

fn protectInline(protection: *Protection, line: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) {
        if (std.mem.startsWith(u8, line[i..], "![")) {
            if (findMarkdownLinkEnd(line, i)) |end| {
                try protection.add(line[i .. end + 1]);
                i = end + 1;
            } else {
                try protection.text.append(line[i]);
                i += 1;
            }
        } else if (line[i] == '`') {
            const end = codeSpanEnd(line, i, runEnd(line, i)) orelse line.len;
            try protection.add(line[i..end]);
            i = end;
        } else if (line[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, line, i + 1, '>') orelse line.len - 1;
            try protection.add(line[i .. end + 1]);
            i = end + 1;
        } else if (std.mem.startsWith(u8, line[i..], "http://") or std.mem.startsWith(u8, line[i..], "https://")) {
            var end = i;
            while (end < line.len and !std.ascii.isWhitespace(line[end])) end += 1;
            try protection.add(line[i..end]);
            i = end;
        } else {
            try protection.text.append(line[i]);
            i += 1;
        }
    }
}

fn findMarkdownLinkEnd(line: []const u8, start: usize) ?usize {
    const close_bracket = std.mem.indexOfScalarPos(u8, line, start, ']') orelse return null;
    if (close_bracket + 1 >= line.len or line[close_bracket + 1] != '(') return null;
    return std.mem.indexOfScalarPos(u8, line, close_bracket + 2, ')');
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
    const restored = try doc.restore(std.testing.allocator, doc.text, &warnings);
    defer std.testing.allocator.free(restored);

    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
    try std.testing.expectEqualStrings(source, restored);
}

test "restore appends warning when token missing" {
    const doc = try protect(std.testing.allocator, "`code` and https://example.com");
    defer doc.deinit(std.testing.allocator);

    var warnings = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer warnings.deinit();
    const restored = try doc.restore(std.testing.allocator, "translation without protected tokens", &warnings);
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
    const restored = try doc.restore(std.testing.allocator, doc.text, &warnings);
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
    const restored = try doc.restore(allocator, translation, &warnings);
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
    const doc = try protect(allocator, "`expanded protected bytes with enough length to grow output`");
    defer doc.deinit(allocator);
    const translated = "KOTOBA_PROTECT_1_ " ** 12;
    var warnings = std.array_list.Managed([]const u8).init(allocator);
    defer warnings.deinit();
    const restored = try doc.restore(allocator, translated, &warnings);
    defer allocator.free(restored);
    try std.testing.expect(restored.len > translated.len);
    try std.testing.expect(std.mem.indexOf(u8, restored, doc.token_prefix) == null);
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

test "source placeholder strings survive Markdown protection and restoration" {
    const allocator = std.testing.allocator;
    const source = "KOTOBA_PROTECT_000001 `code KOTOBA_PROTECT_2_` and `more` KOTOBA_PROTECT_1_";
    const doc = try protect(allocator, source);
    defer doc.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), doc.protected.len);
    try std.testing.expect(std.mem.indexOf(u8, source, doc.token_prefix) == null);

    var warnings = std.array_list.Managed([]const u8).init(allocator);
    defer warnings.deinit();
    const restored = try doc.restore(allocator, doc.text, &warnings);
    defer allocator.free(restored);
    try std.testing.expectEqualStrings(source, restored);
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
}

test "Markdown block recognition preserves CRLF and matches code fence markers and lengths" {
    const allocator = std.testing.allocator;
    const source = "---\r\ntitle: Example\r\n---\r\n\r\n" ++
        "   ~~~~sh\r\n~~~\r\n```\r\nstill fenced\r\n ~~ ~\r\n~~~~~ \r\n\r\n" ++
        "Prose with A \\| B.\r\n";
    const doc = try protect(allocator, source);
    defer doc.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 9), doc.protected.len);
    try std.testing.expectEqualStrings("still fenced", doc.protected[6]);
    try std.testing.expect(std.mem.endsWith(u8, doc.text, "\r\n\r\nProse with A \\| B.\r\n"));

    var warnings = std.array_list.Managed([]const u8).init(allocator);
    defer warnings.deinit();
    const restored = try doc.restore(allocator, doc.text, &warnings);
    defer allocator.free(restored);
    try std.testing.expectEqualStrings(source, restored);
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
}

test "Markdown tables require a header and an aligned delimiter row" {
    const allocator = std.testing.allocator;
    const source = "Use A | B in prose.\nUse A \\| B.\nUse `A | B` inline.\n\n" ++
        "Header \\| A | `B | C`\n:--- | ---:\nSome \\| text | value\n\n" ++
        "| One |\n---\n| Body |\n";
    const doc = try protect(allocator, source);
    defer doc.deinit(allocator);
    try std.testing.expect(std.mem.startsWith(u8, doc.text, "Use A | B in prose.\nUse A \\| B.\nUse "));
    const expected = [_][]const u8{
        "`A | B`", "Header \\| A | `B | C`", ":--- | ---:", "Some \\| text | value", "| One |", "---", "| Body |",
    };
    try std.testing.expectEqual(expected.len, doc.protected.len);
    for (expected, doc.protected) |original, actual| try std.testing.expectEqualStrings(original, actual);
}

test "quoted tables keep single-cell rows and stop at a new block or quote depth" {
    const allocator = std.testing.allocator;
    const source = "> > | One | Two |\r\n> > | --- | --- |\r\n> > Cell\r\n> > # Heading\r\n> Outside\r\n";
    const doc = try protect(allocator, source);
    defer doc.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), doc.protected.len);
    try std.testing.expectEqualStrings("> > Cell", doc.protected[2]);
    try std.testing.expect(std.mem.endsWith(u8, doc.text, "\r\n> > # Heading\r\n> Outside\r\n"));
}

test "inline HTML at the start of a table row keeps the whole row protected" {
    const allocator = std.testing.allocator;
    const source = "| Key | Action |\n| - | - |\n<kbd>Esc</kbd> | Cancel\n| Enter | Run |\n<DIV>Block</DIV>\nProse";
    const doc = try protect(allocator, source);
    defer doc.deinit(allocator);
    try std.testing.expectEqualStrings("<kbd>Esc</kbd> | Cancel", doc.protected[2]);
    try std.testing.expectEqualStrings("| Enter | Run |", doc.protected[3]);
    try std.testing.expectEqualStrings("<DIV>", doc.protected[4]);
}
