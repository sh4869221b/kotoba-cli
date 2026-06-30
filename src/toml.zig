const std = @import("std");

pub fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r\n");
}

pub fn stripComment(line: []const u8) []const u8 {
    var in_string = false;
    for (line, 0..) |c, i| {
        if (c == '"') in_string = !in_string;
        if (!in_string and c == '#') return line[0..i];
    }
    return line;
}

pub fn unquote(value: []const u8) []const u8 {
    const v = trim(value);
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') return v[1 .. v.len - 1];
    return v;
}

pub fn boolValue(value: []const u8) ?bool {
    const v = trim(value);
    if (std.mem.eql(u8, v, "true")) return true;
    if (std.mem.eql(u8, v, "false")) return false;
    return null;
}

pub fn intValue(value: []const u8) ?u32 {
    return std.fmt.parseInt(u32, trim(value), 10) catch null;
}

pub fn signedIntValue(value: []const u8) ?i32 {
    return std.fmt.parseInt(i32, trim(value), 10) catch null;
}

pub const Pair = struct { key: []const u8, value: []const u8 };

pub fn pair(line: []const u8) ?Pair {
    const clean = trim(stripComment(line));
    if (clean.len == 0 or clean[0] == '[') return null;
    const idx = std.mem.indexOfScalar(u8, clean, '=') orelse return null;
    return .{ .key = trim(clean[0..idx]), .value = trim(clean[idx + 1 ..]) };
}

pub fn stringArrayContains(value: []const u8, needle: []const u8) bool {
    const v = trim(value);
    if (v.len < 2 or v[0] != '[') return false;
    var inner = v[1 .. v.len - 1];
    while (inner.len > 0) {
        inner = trim(inner);
        const comma = std.mem.indexOfScalar(u8, inner, ',') orelse inner.len;
        const item = unquote(trim(inner[0..comma]));
        if (std.mem.eql(u8, item, needle)) return true;
        if (comma == inner.len) break;
        inner = inner[comma + 1 ..];
    }
    return false;
}
