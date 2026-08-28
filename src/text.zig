const std = @import("std");

pub fn validate(bytes: []const u8) error{ InvalidUtf8, EmbeddedNul }!void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.EmbeddedNul;
}

test "text contract preserves valid UTF-8 bytes" {
    const fixtures = [_][]const u8{
        "",
        "Hello",
        "こんにちは",
        "😀",
        "e\u{301}",
        "\xEF\xBB\xBFtext",
    };

    for (fixtures) |bytes| {
        const before = bytes;
        try validate(bytes);
        try std.testing.expectEqualSlices(u8, before, bytes);
    }

    var controls: [31]u8 = undefined;
    for (&controls, 1..) |*byte, code| byte.* = @intCast(code);
    const before = controls;
    try validate(&controls);
    try std.testing.expectEqualSlices(u8, &before, &controls);
}

test "text contract rejects malformed UTF-8 and NUL" {
    const cases = [_]struct {
        bytes: []const u8,
        expected: anyerror,
    }{
        .{ .bytes = "\x80", .expected = error.InvalidUtf8 },
        .{ .bytes = "\xFF", .expected = error.InvalidUtf8 },
        .{ .bytes = "\xC0\xAF", .expected = error.InvalidUtf8 },
        .{ .bytes = "\xED\xA0\x80", .expected = error.InvalidUtf8 },
        .{ .bytes = "\xF4\x90\x80\x80", .expected = error.InvalidUtf8 },
        .{ .bytes = "\xE3", .expected = error.InvalidUtf8 },
        .{ .bytes = "\xE3\x81", .expected = error.InvalidUtf8 },
        .{ .bytes = "\xF0\x9F\x98", .expected = error.InvalidUtf8 },
        .{ .bytes = "\x00", .expected = error.EmbeddedNul },
        .{ .bytes = "A\x00B", .expected = error.EmbeddedNul },
        .{ .bytes = "\xFF\x00", .expected = error.InvalidUtf8 },
    };

    for (cases) |case| try std.testing.expectError(case.expected, validate(case.bytes));
}
