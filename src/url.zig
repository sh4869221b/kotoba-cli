const std = @import("std");

pub const max_length = 8192;

/// Includes malformed remote-looking values so they cannot become local paths.
pub fn isRemote(value: []const u8) bool {
    if (std.mem.startsWith(u8, value, "file://")) return false;
    return std.ascii.startsWithIgnoreCase(value, "https:") or
        std.ascii.startsWithIgnoreCase(value, "http:") or
        std.ascii.startsWithIgnoreCase(value, "https//") or
        std.ascii.startsWithIgnoreCase(value, "http//") or
        std.mem.startsWith(u8, value, "//") or
        std.mem.indexOf(u8, value, "://") != null;
}

/// Validate complete remote input or a redirect reference before stripping fragments.
pub fn validateReference(value: []const u8) error{InvalidArguments}!void {
    if (value.len > max_length) return error.InvalidArguments;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const c = value[i];
        if (c == '%') {
            if (i + 2 >= value.len or !std.ascii.isHex(value[i + 1]) or !std.ascii.isHex(value[i + 2])) return error.InvalidArguments;
            i += 2;
        } else if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-._~:/?#[]@!$&'()*+,;=", c) == null) {
            return error.InvalidArguments;
        }
    }
}

fn parseMetadata(value: []const u8) error{InvalidArguments}!std.Uri {
    try validateReference(value);
    const uri = std.Uri.parse(value) catch return error.InvalidArguments;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InvalidArguments;
    const host = (uri.host orelse return error.InvalidArguments).percent_encoded;
    if (host.len == 0) return error.InvalidArguments;
    if (host[0] == '[') {
        if (host[host.len - 1] != ']') return error.InvalidArguments;
        _ = std.Io.net.IpAddress.parseIp6(host[1 .. host.len - 1], 0) catch return error.InvalidArguments;
    } else {
        std.Io.net.HostName.validate(host) catch return error.InvalidArguments;
    }
    const host_end = @intFromPtr(host.ptr) - @intFromPtr(value.ptr) + host.len;
    const authority_end = std.mem.indexOfAnyPos(u8, value, uri.scheme.len + 3, "/?#") orelse value.len;
    const port_text = value[host_end..authority_end];
    if (port_text.len > 0) {
        if (port_text[0] != ':' or port_text.len == 1) return error.InvalidArguments;
        for (port_text[1..]) |c| if (!std.ascii.isDigit(c)) return error.InvalidArguments;
    }
    return uri;
}

/// Returned URI components borrow value; HTTP is allowed for low-level fixtures.
pub fn parseRemote(value: []const u8) error{InvalidArguments}!std.Uri {
    const uri = try parseMetadata(value);
    if (uri.user != null or uri.password != null) return error.InvalidArguments;
    return uri;
}

/// Borrow the original encoded request bytes, preserving the complete query.
pub fn requestUrl(value: []const u8) error{InvalidArguments}![]const u8 {
    _ = try parseRemote(value);
    return value[0 .. std.mem.indexOfScalar(u8, value, '#') orelse value.len];
}

/// Allocated safe remote identity; empty for invalid or local metadata.
pub fn sourceIdentity(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const uri = parseMetadata(value) catch return allocator.dupe(u8, "");
    const host = uri.host.?.percent_encoded;
    const host_start = @intFromPtr(host.ptr) - @intFromPtr(value.ptr);
    const end = std.mem.indexOfAny(u8, value, "?#") orelse value.len;
    return std.fmt.allocPrint(allocator, "{s}://{s}", .{ uri.scheme, value[host_start..end] });
}

/// Allocated display text, never a raw fallback for invalid remote metadata.
pub fn displayUrl(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (!isRemote(value)) return allocator.dupe(u8, value);
    _ = parseMetadata(value) catch return allocator.dupe(u8, "[redacted]");
    return sourceIdentity(allocator, value);
}

/// Borrow a reusable source only; a safe display identity is not a fetch URL.
pub fn reusableUrl(value: []const u8) []const u8 {
    if (!isRemote(value)) return value;
    const uri = parseRemote(value) catch return "";
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") or uri.query != null) return "";
    return value[0 .. std.mem.indexOfScalar(u8, value, '#') orelse value.len];
}

pub fn hasUnsafeMetadata(value: []const u8) bool {
    if (!isRemote(value)) return false;
    const uri = parseRemote(value) catch return true;
    return !std.ascii.eqlIgnoreCase(uri.scheme, "https") or uri.query != null or uri.fragment != null;
}

test "secret URL policy bounds and safe metadata" {
    const allocator = std.testing.allocator;
    const signed = "https://models.example.invalid/repo/model%2Bname.gguf?X-Signature=KOTOBA_QUERY_SECRET_36&x=a%2Bb&x=2#KOTOBA_FRAGMENT_SECRET_36";
    const identity = try sourceIdentity(allocator, signed);
    defer allocator.free(identity);
    try std.testing.expectEqualStrings("https://models.example.invalid/repo/model%2Bname.gguf", identity);
    try std.testing.expectEqualStrings("", reusableUrl(signed));
    try std.testing.expect(hasUnsafeMetadata(signed));
    const cases = [_]struct { input: []const u8, reusable: []const u8, unsafe: bool }{
        .{ .input = "HTTPS://models.example.invalid/a%2Bb", .reusable = "HTTPS://models.example.invalid/a%2Bb", .unsafe = false },
        .{ .input = "hTtP://127.0.0.1/model", .reusable = "", .unsafe = true },
        .{ .input = "https://[::1]:443/model", .reusable = "https://[::1]:443/model", .unsafe = false },
        .{ .input = "https://models.example.invalid?", .reusable = "", .unsafe = true },
        .{ .input = "https://models.example.invalid#fragment", .reusable = "https://models.example.invalid", .unsafe = true },
        .{ .input = "https://models.example.invalid#?not-a-query", .reusable = "https://models.example.invalid", .unsafe = true },
        .{ .input = "https://models.example.invalid?token=synthetic", .reusable = "", .unsafe = true },
    };
    for (cases) |case| {
        _ = try parseRemote(case.input);
        try std.testing.expectEqualStrings(case.reusable, reusableUrl(case.input));
        try std.testing.expectEqual(case.unsafe, hasUnsafeMetadata(case.input));
    }
    for ([_][]const u8{
        "https://user:password@models.example.invalid/a%2Bb?synthetic#fragment",
        "https://user@models.example.invalid/a%2Bb",
        "https://@models.example.invalid/a%2Bb",
        "https://user%40name@models.example.invalid/a%2Bb",
    }) |value| {
        try std.testing.expectError(error.InvalidArguments, requestUrl(value));
        const display = try displayUrl(allocator, value);
        defer allocator.free(display);
        try std.testing.expectEqualStrings("https://models.example.invalid/a%2Bb", display);
        try std.testing.expectEqualStrings("", reusableUrl(value));
    }
    for ([_][]const u8{
        "https:///model",     "https://",             "https:/model",          "https//model",        "http:/model",
        "https://host:bad/a", "https://host:99999/a", "https://[::1]suffix/a", "https://[invalid]/a", "https://user@@host/a",
        "https://host/a%2",   "https://host/a%zz",    "https://bad host/a",    "https://host/a\\b",   "ftp://host/a",
        "//host/a",
    }) |value| {
        try std.testing.expect(isRemote(value));
        try std.testing.expectError(error.InvalidArguments, requestUrl(value));
        const display = try displayUrl(allocator, value);
        defer allocator.free(display);
        const source = try sourceIdentity(allocator, value);
        defer allocator.free(source);
        try std.testing.expectEqualStrings("[redacted]", display);
        try std.testing.expectEqualStrings("", source);
        try std.testing.expectEqualStrings("", reusableUrl(value));
        try std.testing.expect(hasUnsafeMetadata(value));
    }
    var bounded = [_]u8{'a'} ** (max_length + 1);
    const prefix = "https://models.example.invalid/";
    @memcpy(bounded[0..prefix.len], prefix);
    _ = try requestUrl(bounded[0..max_length]);
    try std.testing.expectError(error.InvalidArguments, requestUrl(&bounded));
    const oversize_display = try displayUrl(allocator, &bounded);
    defer allocator.free(oversize_display);
    try std.testing.expectEqualStrings("[redacted]", oversize_display);
    for (0..128) |c| {
        if (c > 31 and c != 127) continue;
        var controlled = "https://models.example.invalid/model#x".*;
        controlled[controlled.len - 1] = @intCast(c);
        try std.testing.expectError(error.InvalidArguments, requestUrl(&controlled));
        const display = try displayUrl(allocator, &controlled);
        defer allocator.free(display);
        try std.testing.expectEqualStrings("[redacted]", display);
    }
}
