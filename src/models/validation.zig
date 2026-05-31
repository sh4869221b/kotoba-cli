const std = @import("std");
const errors = @import("../errors.zig");

pub fn validateId(id: []const u8) !void {
    if (id.len == 0) return errors.Error.InvalidArguments;
    for (id) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') continue;
        return errors.Error.InvalidArguments;
    }
}

pub fn validateGgufPath(path: []const u8) !void {
    if (path.len == 0 or !std.mem.endsWith(u8, path, ".gguf")) return errors.Error.InvalidArguments;
}

pub fn validateHfRfilename(path: []const u8) !void {
    try validateGgufPath(path);
    if (path[0] == '/') return errors.Error.InvalidArguments;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return errors.Error.InvalidArguments;
    if (std.mem.indexOfAny(u8, path, "?#") != null) return errors.Error.InvalidArguments;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return errors.Error.InvalidArguments;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return errors.Error.InvalidArguments;
    }
}

pub fn validateSingleHfGgufFilename(path: []const u8) !void {
    try validateHfRfilename(path);
    if (isSplitGgufFilename(path)) return errors.Error.SplitModelUnsupported;
}

pub fn isSplitGgufFilename(path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".gguf")) return false;
    const stem = path[0 .. path.len - ".gguf".len];
    const of_idx = std.mem.lastIndexOf(u8, stem, "-of-") orelse return false;
    const total = stem[of_idx + "-of-".len ..];
    if (total.len == 0 or !allDigits(total)) return false;
    var part_start = of_idx;
    while (part_start > 0 and std.ascii.isDigit(stem[part_start - 1])) : (part_start -= 1) {}
    if (part_start == of_idx) return false;
    if (part_start == 0 or stem[part_start - 1] != '-') return false;
    return true;
}

fn allDigits(text: []const u8) bool {
    for (text) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

test "model ids reject path separators" {
    try validateId("local-ja_q4.0");
    try std.testing.expectError(errors.Error.InvalidArguments, validateId("../model"));
    try std.testing.expectError(errors.Error.InvalidArguments, validateId("bad/id"));
}
