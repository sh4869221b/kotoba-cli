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

pub const Pair = struct { key: []const u8, value: []const u8 };

pub fn pair(line: []const u8) ?Pair {
    const clean = trim(stripComment(line));
    if (clean.len == 0 or clean[0] == '[') return null;
    const idx = std.mem.indexOfScalar(u8, clean, '=') orelse return null;
    return .{ .key = trim(clean[0..idx]), .value = trim(clean[idx + 1 ..]) };
}
