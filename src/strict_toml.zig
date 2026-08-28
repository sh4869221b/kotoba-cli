const std = @import("std");

pub const Error = error{ Invalid, OutOfMemory };
pub const Buffer = std.array_list.Managed(u8);
pub const Pair = struct { key: []const u8, value: []const u8 };
pub const Header = struct { name: []const u8, array: bool };
pub const Line = union(enum) { pair: Pair, header: Header };

/// Line tokens borrow the input; decoded strings returned below belong to the caller.
pub const Reader = struct {
    data: []const u8,
    offset: usize = 0,

    pub fn next(self: *Reader) Error!?Line {
        while (self.offset < self.data.len) {
            const start = self.offset;
            const end = std.mem.indexOfScalarPos(u8, self.data, start, '\n') orelse self.data.len;
            self.offset = if (end < self.data.len) end + 1 else end;
            var line = self.data[start..end];
            if (end < self.data.len and std.mem.endsWith(u8, line, "\r")) line = line[0 .. line.len - 1];
            if (start == 0 and std.mem.startsWith(u8, line, "\xef\xbb\xbf")) return error.Invalid;
            var cursor: Cursor = .{ .text = line };
            cursor.spaces();
            if (cursor.atEnd()) {
                try validateLine(line);
                continue;
            }
            if (cursor.take('[')) {
                try validateLine(line);
                const array = cursor.take('[');
                cursor.spaces();
                const name = try cursor.key();
                cursor.spaces();
                if (!cursor.take(']')) return error.Invalid;
                if (array and !cursor.take(']')) return error.Invalid;
                try cursor.finish();
                return .{ .header = .{ .name = name, .array = array } };
            }
            const key = try cursor.key();
            cursor.spaces();
            if (!cursor.take('=')) return error.Invalid;
            cursor.spaces();
            try validateLine(line[0..cursor.pos]);
            return .{ .pair = .{ .key = key, .value = line[cursor.pos..] } };
        }
        return null;
    }
};

pub fn isSchemaMarker(key: []const u8) bool {
    inline for (.{ "version", "schema", "schema_version" }) |reserved| {
        if (std.mem.eql(u8, key, reserved)) return true;
    }
    return false;
}

fn validateLine(text: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.Invalid;
    for (text) |byte| {
        if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return error.Invalid;
    }
}

/// In-memory strings may contain escaped controls, but never NUL or invalid UTF-8.
pub fn validateString(text: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.Invalid;
}

const Cursor = struct {
    text: []const u8,
    pos: usize = 0,

    fn spaces(self: *Cursor) void {
        while (self.pos < self.text.len and (self.text[self.pos] == ' ' or self.text[self.pos] == '\t')) self.pos += 1;
    }

    fn take(self: *Cursor, byte: u8) bool {
        if (self.pos == self.text.len or self.text[self.pos] != byte) return false;
        self.pos += 1;
        return true;
    }

    fn atEnd(self: Cursor) bool {
        return self.pos == self.text.len or self.text[self.pos] == '#';
    }

    fn finish(self: *Cursor) Error!void {
        self.spaces();
        if (!self.atEnd()) return error.Invalid;
    }

    fn key(self: *Cursor) Error![]const u8 {
        const start = self.pos;
        while (self.pos < self.text.len) : (self.pos += 1) {
            const c = self.text[self.pos];
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) break;
        }
        if (self.pos == start) return error.Invalid;
        return self.text[start..self.pos];
    }

    fn string(self: *Cursor, allocator: std.mem.Allocator) Error![]u8 {
        if (self.pos == self.text.len) return error.Invalid;
        const quote = self.text[self.pos];
        if (quote != '"' and quote != '\'') return error.Invalid;
        self.pos += 1;
        var out = Buffer.init(allocator);
        errdefer out.deinit();
        while (self.pos < self.text.len) {
            const byte = self.text[self.pos];
            self.pos += 1;
            if (byte == quote) return out.toOwnedSlice();
            if (quote == '\'' or byte != '\\') {
                try out.append(byte);
                continue;
            }
            if (self.pos == self.text.len) return error.Invalid;
            const escape = self.text[self.pos];
            self.pos += 1;
            switch (escape) {
                '"', '\\' => try out.append(escape),
                'b' => try out.append(0x08),
                't' => try out.append('\t'),
                'n' => try out.append('\n'),
                'f' => try out.append(0x0c),
                'r' => try out.append('\r'),
                'u', 'U' => {
                    const count: usize = if (escape == 'u') 4 else 8;
                    if (self.text.len - self.pos < count) return error.Invalid;
                    const digits = self.text[self.pos..][0..count];
                    for (digits) |digit| if (!std.ascii.isHex(digit)) return error.Invalid;
                    const scalar = std.fmt.parseInt(u32, digits, 16) catch return error.Invalid;
                    if (scalar == 0 or scalar > 0x10ffff or (scalar >= 0xd800 and scalar <= 0xdfff)) return error.Invalid;
                    var encoded: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(@intCast(scalar), &encoded) catch return error.Invalid;
                    try out.appendSlice(encoded[0..len]);
                    self.pos += count;
                },
                else => return error.Invalid,
            }
        }
        return error.Invalid;
    }
};

pub fn parseString(allocator: std.mem.Allocator, text: []const u8) Error![]u8 {
    try validateLine(text);
    var cursor: Cursor = .{ .text = text };
    cursor.spaces();
    const value = try cursor.string(allocator);
    errdefer allocator.free(value);
    try cursor.finish();
    return value;
}

fn token(text: []const u8) Error![]const u8 {
    try validateLine(text);
    var cursor: Cursor = .{ .text = text };
    cursor.spaces();
    const start = cursor.pos;
    while (cursor.pos < text.len and text[cursor.pos] != ' ' and text[cursor.pos] != '\t' and text[cursor.pos] != '#') cursor.pos += 1;
    if (start == cursor.pos) return error.Invalid;
    const result = text[start..cursor.pos];
    try cursor.finish();
    return result;
}

fn number(text: []const u8, floating: bool) Error!void {
    var pos: usize = 0;
    if (pos < text.len and (text[pos] == '+' or text[pos] == '-')) pos += 1;
    if (pos == text.len or !std.ascii.isDigit(text[pos])) return error.Invalid;
    if (text[pos] == '0') {
        pos += 1;
    } else {
        while (pos < text.len and std.ascii.isDigit(text[pos])) pos += 1;
    }
    if (floating and pos < text.len and text[pos] == '.') {
        pos += 1;
        const start = pos;
        while (pos < text.len and std.ascii.isDigit(text[pos])) pos += 1;
        if (pos == start) return error.Invalid;
    }
    if (floating and pos < text.len and (text[pos] == 'e' or text[pos] == 'E')) {
        pos += 1;
        if (pos < text.len and (text[pos] == '+' or text[pos] == '-')) pos += 1;
        const start = pos;
        while (pos < text.len and std.ascii.isDigit(text[pos])) pos += 1;
        if (pos == start) return error.Invalid;
    }
    if (pos != text.len) return error.Invalid;
}

pub fn parseInt(comptime T: type, text: []const u8) Error!T {
    const value = try token(text);
    try number(value, false);
    if (@typeInfo(T).int.signedness == .unsigned and value[0] == '-') return error.Invalid;
    return std.fmt.parseInt(T, value, 10) catch error.Invalid;
}

pub fn parseFloat(text: []const u8) Error!f32 {
    const value = try token(text);
    try number(value, true);
    const result = std.fmt.parseFloat(f32, value) catch return error.Invalid;
    if (!std.math.isFinite(result)) return error.Invalid;
    return result;
}

pub fn parseBool(text: []const u8) Error!bool {
    const value = try token(text);
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.Invalid;
}

pub const Languages = struct { en: bool = false, ja: bool = false };

pub fn parseLanguages(allocator: std.mem.Allocator, text: []const u8) Error!Languages {
    try validateLine(text);
    var cursor: Cursor = .{ .text = text };
    cursor.spaces();
    if (!cursor.take('[')) return error.Invalid;
    cursor.spaces();
    var result: Languages = .{};
    while (!cursor.take(']')) {
        const member = try cursor.string(allocator);
        defer allocator.free(member);
        if (std.mem.eql(u8, member, "en") and !result.en) {
            result.en = true;
        } else if (std.mem.eql(u8, member, "ja") and !result.ja) {
            result.ja = true;
        } else return error.Invalid;
        cursor.spaces();
        if (cursor.take(']')) break;
        if (!cursor.take(',')) return error.Invalid;
        cursor.spaces();
    }
    try cursor.finish();
    return result;
}

pub fn appendString(out: *Buffer, value: []const u8) Error!void {
    try validateString(value);
    try out.append('"');
    for (value) |byte| switch (byte) {
        '"' => try out.appendSlice("\\\""),
        '\\' => try out.appendSlice("\\\\"),
        '\n' => try out.appendSlice("\\n"),
        '\r' => try out.appendSlice("\\r"),
        '\t' => try out.appendSlice("\\t"),
        0x08 => try out.appendSlice("\\b"),
        0x0c => try out.appendSlice("\\f"),
        else => if (byte < 0x20 or byte == 0x7f) {
            try out.print("\\u{x:0>4}", .{@as(u16, byte)});
        } else try out.append(byte),
    };
    try out.append('"');
}

pub fn appendFloat(out: *Buffer, value: f32) Error!void {
    if (!std.math.isFinite(value)) return error.Invalid;
    var decimal_buf: [std.fmt.float.bufferSize(.decimal, f32)]u8 = undefined;
    var scientific_buf: [std.fmt.float.bufferSize(.scientific, f32)]u8 = undefined;
    const decimal = std.fmt.float.render(&decimal_buf, value, .{ .mode = .decimal }) catch unreachable;
    const scientific = std.fmt.float.render(&scientific_buf, value, .{ .mode = .scientific }) catch unreachable;
    const needs_fraction = std.mem.indexOfScalar(u8, decimal, '.') == null;
    if (decimal.len + @as(usize, if (needs_fraction) 2 else 0) <= scientific.len) {
        try out.appendSlice(decimal);
        if (needs_fraction) try out.appendSlice(".0");
    } else try out.appendSlice(scientific);
}

test "strict codec strings decode every escape and Unicode scalar boundaries" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "\"\"", .expected = "" },
        .{ .input = "'' # empty", .expected = "" },
        .{ .input = "\"quote\\\" slash\\\\ # = 日本語 🐈\" # comment", .expected = "quote\" slash\\ # = 日本語 🐈" },
        .{ .input = "'C:\\Users\\日本語\\model.gguf'", .expected = "C:\\Users\\日本語\\model.gguf" },
        .{ .input = "\"\\b\\t\\n\\f\\r\\u007F\"", .expected = "\x08\t\n\x0c\r\x7f" },
        .{ .input = "\"\\u0001\\u001f\\uD7FF\\uE000\\U0010FFFF\"", .expected = "\x01\x1f\xed\x9f\xbf\xee\x80\x80\xf4\x8f\xbf\xbf" },
        .{ .input = "\"\\u65E5\\u672c\\u8a9e \\U0001F408\"", .expected = "日本語 🐈" },
        .{ .input = "\t'raw\ttab # ='\t# comment", .expected = "raw\ttab # =" },
        .{ .input = "\"literal ' quote\"", .expected = "literal ' quote" },
    };
    for (cases) |case| {
        const result = try parseString(std.testing.allocator, case.input);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings(case.expected, result);
        var out = Buffer.init(std.testing.allocator);
        defer out.deinit();
        try appendString(&out, result);
        const reparsed = try parseString(std.testing.allocator, out.items);
        defer std.testing.allocator.free(reparsed);
        try std.testing.expectEqualStrings(result, reparsed);
    }
}

test "strict codec language arrays are typed distinct and complete" {
    const cases = [_]struct { input: []const u8, expected: Languages }{
        .{ .input = "[]", .expected = .{} },
        .{ .input = "[ 'en' ]", .expected = .{ .en = true } },
        .{ .input = "[\"ja\",] # comment", .expected = .{ .ja = true } },
        .{ .input = "[\"ja\",'en',]", .expected = .{ .en = true, .ja = true } },
        .{ .input = "[\"\\u0065n\", \"ja\"]", .expected = .{ .en = true, .ja = true } },
    };
    for (cases) |case| try std.testing.expectEqualDeep(case.expected, try parseLanguages(std.testing.allocator, case.input));
    for ([_][]const u8{
        "[en]", "[1]", "[true]", "['xx']", "['']", "['en','en']", "['ja','ja']", "['en','ja','en']", "[['en']]", "['en' 'ja']", "['en',,]", "[,]", "[", "['en'", "['en',", "[]tail", "['en'] []", "[\n'en']", "['en',# comment]", "['en','bad\\q']", "[\"\\u0000\"]",
    }) |input| try std.testing.expectError(error.Invalid, parseLanguages(std.testing.allocator, input));
}

test "strict codec reader preserves borrowed keys and exact header grammar" {
    var reader: Reader = .{ .data = "\t# comment\r\n\r\nmodel_id = 'a=#b' # tail\r\n[[ models ]] # header\n[schema_version]" };
    const pair = (try reader.next()).?.pair;
    try std.testing.expectEqualStrings("model_id", pair.key);
    try std.testing.expectEqualStrings("'a=#b' # tail", pair.value);
    try std.testing.expectEqualDeep(Header{ .name = "models", .array = true }, (try reader.next()).?.header);
    const header = (try reader.next()).?.header;
    try std.testing.expectEqualDeep(Header{ .name = "schema_version", .array = false }, header);
    try std.testing.expect(isSchemaMarker(header.name));
    try std.testing.expectEqual(null, try reader.next());
    for ([_][]const u8{ "[\"version\"]", "['schema']", "[schema.version]", "[ schema version ]", "[[models]", "[[models]]tail", "[[[models]]]", "[]", "[[]]", "# bad\r", "\xef\xbb\xbf", "# \xff" }) |input| {
        var invalid: Reader = .{ .data = input };
        try std.testing.expectError(error.Invalid, invalid.next());
    }
}

test "strict codec finite float writer round trips exact bits" {
    var bits: u32 = 0;
    for (0..2048) |_| {
        bits = bits *% 1664525 +% 1013904223;
        const value: f32 = @bitCast(bits);
        if (!std.math.isFinite(value)) continue;
        var out = Buffer.init(std.testing.allocator);
        defer out.deinit();
        try appendFloat(&out, value);
        try std.testing.expectEqual(bits, @as(u32, @bitCast(try parseFloat(out.items))));
    }
    inline for (.{ .{ @as(f32, 0.0), "0.0" }, .{ @as(f32, -0.0), "-0.0" }, .{ @as(f32, 1.0), "1.0" }, .{ @as(f32, 0.2), "0.2" } }) |case| {
        var out = Buffer.init(std.testing.allocator);
        defer out.deinit();
        try appendFloat(&out, case[0]);
        try std.testing.expectEqualStrings(case[1], out.items);
        try std.testing.expectEqual(@as(u32, @bitCast(case[0])), @as(u32, @bitCast(try parseFloat(out.items))));
    }
}

fn checkCodecAllocations(allocator: std.mem.Allocator) !void {
    var out = Buffer.init(allocator);
    defer out.deinit();
    try appendString(&out, "quote\" slash\\ # = 日本語 🐈\n\x01\x7f");
    const value = try parseString(allocator, out.items);
    defer allocator.free(value);
    try std.testing.expectEqualStrings("quote\" slash\\ # = 日本語 🐈\n\x01\x7f", value);
    out.clearRetainingCapacity();
    try appendFloat(&out, @bitCast(@as(u32, 1)));
    try std.testing.expectEqual(@as(u32, 1), @as(u32, @bitCast(try parseFloat(out.items))));
    try std.testing.expectEqualDeep(Languages{ .en = true, .ja = true }, try parseLanguages(allocator, "['en',\"ja\"]"));
}

fn checkInvalidCodecAllocations(allocator: std.mem.Allocator, input: []const u8, array: bool) !void {
    if (array) {
        _ = parseLanguages(allocator, input) catch |err| {
            if (err == error.OutOfMemory) return err;
            try std.testing.expectEqual(error.Invalid, err);
            return;
        };
    } else {
        const value = parseString(allocator, input) catch |err| {
            if (err == error.OutOfMemory) return err;
            try std.testing.expectEqual(error.Invalid, err);
            return;
        };
        allocator.free(value);
    }
    return error.TestUnexpectedResult;
}

test "strict codec allocation failures and partial decoding cleanup" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkCodecAllocations, .{});
    for ([_][]const u8{ "\"allocated\\q\"", "\"allocated\" tail", "\"allocated\\uD800\"", "\"allocated\\UFFFFFFFF\"", "\"allocated" }) |input| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, checkInvalidCodecAllocations, .{ input, false });
    }
    for ([_][]const u8{ "['en','en']", "['en',\"allocated\\q\"]", "['en','ja'] tail" }) |input| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, checkInvalidCodecAllocations, .{ input, true });
    }
}
