const std = @import("std");
const errors = @import("errors.zig");
const c = @cImport({
    @cInclude("arpa/inet.h");
    @cInclude("netinet/in.h");
    @cInclude("sys/socket.h");
    @cInclude("unistd.h");
});

pub const HealthStatus = enum { ok };

pub const Request = struct {
    server_url: []const u8,
    model_id: []const u8,
    prompt: []const u8,
    timeout_sec: u32 = 120,
    allow_remote_server: bool = false,
};

const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    base_path: []const u8,
};

pub fn validateLocalServerUrl(server_url: []const u8, allow_remote_server: bool) !void {
    if (allow_remote_server) return;
    const p = try parseHttpUrl(server_url);
    if (std.mem.eql(u8, p.host, "127.0.0.1") or std.mem.eql(u8, p.host, "localhost") or std.mem.eql(u8, p.host, "::1")) return;
    return errors.Error.ServerNotLocal;
}

pub fn healthCheck(allocator: std.mem.Allocator, server_url: []const u8, timeout_sec: u32, allow_remote_server: bool) !HealthStatus {
    _ = timeout_sec;
    try validateLocalServerUrl(server_url, allow_remote_server);
    const response = request(allocator, "GET", server_url, "/health", null) catch return errors.Error.ServerUnreachable;
    defer allocator.free(response);
    return .ok;
}

pub fn translateSegment(allocator: std.mem.Allocator, req: Request) ![]const u8 {
    try validateLocalServerUrl(req.server_url, req.allow_remote_server);
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"model\":\"{s}\",\"messages\":[{{\"role\":\"user\",\"content\":",
        .{req.model_id},
    );
    defer allocator.free(body);
    var json = std.array_list.Managed(u8).init(allocator);
    defer json.deinit();
    try json.appendSlice(body);
    try appendJsonString(allocator, &json, req.prompt);
    try json.appendSlice("}],\"temperature\":0.2}");
    const response = request(allocator, "POST", req.server_url, "/v1/chat/completions", json.items) catch return errors.Error.ServerUnreachable;
    defer allocator.free(response);
    return parseCompletion(allocator, response);
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.array_list.Managed(u8), text: []const u8) !void {
    _ = allocator;
    try out.append('"');
    for (text) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice("\\\\"),
            '"' => try out.appendSlice("\\\""),
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            else => try out.append(ch),
        }
    }
    try out.append('"');
}

fn parseHttpUrl(url: []const u8) !ParsedUrl {
    if (!std.mem.startsWith(u8, url, "http://")) return errors.Error.ServerNotLocal;
    var rest = url["http://".len..];
    var path: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '/')) |idx| {
        path = rest[idx..];
        rest = rest[0..idx];
    }
    var host = rest;
    var port: u16 = 80;
    if (std.mem.startsWith(u8, rest, "[")) {
        const end = std.mem.indexOfScalar(u8, rest, ']') orelse return errors.Error.InvalidArguments;
        host = rest[1..end];
        if (end + 2 <= rest.len and rest[end + 1] == ':') port = try std.fmt.parseInt(u16, rest[end + 2 ..], 10);
    } else if (std.mem.lastIndexOfScalar(u8, rest, ':')) |idx| {
        host = rest[0..idx];
        port = try std.fmt.parseInt(u16, rest[idx + 1 ..], 10);
    }
    return .{ .host = host, .port = port, .base_path = path };
}

fn request(allocator: std.mem.Allocator, method: []const u8, server_url: []const u8, path: []const u8, body: ?[]const u8) ![]const u8 {
    const parsed = try parseHttpUrl(server_url);
    const fd = try connectLocal(parsed);
    defer _ = c.close(fd);

    const target = try std.fmt.allocPrint(allocator, "{s}{s}", .{ if (parsed.base_path.len == 0) "" else parsed.base_path, path });
    defer allocator.free(target);
    const host_header = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ parsed.host, parsed.port });
    defer allocator.free(host_header);
    const request_bytes = if (body) |b|
        try std.fmt.allocPrint(allocator, "{s} {s} HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ method, target, host_header, b.len, b })
    else
        try std.fmt.allocPrint(allocator, "{s} {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ method, target, host_header });
    defer allocator.free(request_bytes);
    try sendAll(fd, request_bytes);
    const raw = try recvAll(allocator, fd, 16 * 1024 * 1024);
    defer allocator.free(raw);
    return parseHttpResponse(allocator, raw);
}

fn connectLocal(parsed: ParsedUrl) !c_int {
    if (std.mem.eql(u8, parsed.host, "::1")) return connectIpv6Loopback(parsed.port);
    return connectIpv4(parsed);
}

fn connectIpv4(parsed: ParsedUrl) !c_int {
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return errors.Error.ServerUnreachable;
    errdefer _ = c.close(fd);
    var addr: c.sockaddr_in = std.mem.zeroes(c.sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = c.htons(parsed.port);
    const host = if (std.mem.eql(u8, parsed.host, "localhost")) "127.0.0.1" else parsed.host;
    var host_buf: [64:0]u8 = [_:0]u8{0} ** 64;
    if (host.len >= host_buf.len) return errors.Error.ServerUnreachable;
    @memcpy(host_buf[0..host.len], host);
    if (c.inet_pton(c.AF_INET, &host_buf, &addr.sin_addr) != 1) return errors.Error.ServerUnreachable;
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr_in)) != 0) return errors.Error.ServerUnreachable;
    return fd;
}

fn connectIpv6Loopback(port: u16) !c_int {
    const fd = c.socket(c.AF_INET6, c.SOCK_STREAM, 0);
    if (fd < 0) return errors.Error.ServerUnreachable;
    errdefer _ = c.close(fd);
    var addr: c.sockaddr_in6 = std.mem.zeroes(c.sockaddr_in6);
    addr.sin6_family = c.AF_INET6;
    addr.sin6_port = c.htons(port);
    var host_buf: [4:0]u8 = [_:0]u8{ ':', ':', '1', 0 };
    if (c.inet_pton(c.AF_INET6, &host_buf, &addr.sin6_addr) != 1) return errors.Error.ServerUnreachable;
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr_in6)) != 0) return errors.Error.ServerUnreachable;
    return fd;
}

fn sendAll(fd: c_int, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = c.send(fd, bytes.ptr + sent, bytes.len - sent, 0);
        if (n <= 0) return errors.Error.ServerUnreachable;
        sent += @intCast(n);
    }
}

fn recvAll(allocator: std.mem.Allocator, fd: c_int, limit: usize) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.recv(fd, &buf, buf.len, 0);
        if (n < 0) return errors.Error.ServerUnreachable;
        if (n == 0) break;
        const count: usize = @intCast(n);
        if (out.items.len + count > limit) return errors.Error.ServerBadResponse;
        try out.appendSlice(buf[0..count]);
    }
    return out.toOwnedSlice();
}

fn parseHttpResponse(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, raw, "HTTP/1.1 200") and !std.mem.startsWith(u8, raw, "HTTP/1.0 200")) return errors.Error.ServerBadResponse;
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return errors.Error.ServerBadResponse;
    return allocator.dupe(u8, raw[header_end + 4 ..]);
}

pub fn parseCompletion(allocator: std.mem.Allocator, response: []const u8) ![]const u8 {
    const marker = "\"content\"";
    const idx = std.mem.indexOf(u8, response, marker) orelse return errors.Error.ServerBadResponse;
    const after = response[idx + marker.len ..];
    const colon = std.mem.indexOfScalar(u8, after, ':') orelse return errors.Error.ServerBadResponse;
    const start_rel = std.mem.indexOfScalar(u8, after[colon + 1 ..], '"') orelse return errors.Error.ServerBadResponse;
    const start = colon + 1 + start_rel + 1;
    var end = start;
    var escaped = false;
    while (end < after.len) : (end += 1) {
        if (!escaped and after[end] == '"') break;
        escaped = !escaped and after[end] == '\\';
        if (after[end] != '\\') escaped = false;
    }
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var i: usize = start;
    while (i < end) : (i += 1) {
        if (after[i] == '\\' and i + 1 < end) {
            i += 1;
            switch (after[i]) {
                'n' => try out.append('\n'),
                'r' => try out.append('\r'),
                't' => try out.append('\t'),
                '"' => try out.append('"'),
                '\\' => try out.append('\\'),
                else => {
                    try out.append('\\');
                    try out.append(after[i]);
                },
            }
        } else {
            try out.append(after[i]);
        }
    }
    return out.toOwnedSlice();
}

test "local url validation" {
    try validateLocalServerUrl("http://127.0.0.1:8080", false);
    try validateLocalServerUrl("http://localhost:8080", false);
    try validateLocalServerUrl("http://[::1]:8080", false);
    try std.testing.expectError(errors.Error.ServerNotLocal, validateLocalServerUrl("https://example.com/v1", false));
    try std.testing.expectError(errors.Error.ServerNotLocal, validateLocalServerUrl("http://192.168.1.10:8080", false));
}

test "parse completion" {
    const out = try parseCompletion(std.testing.allocator, "{\"choices\":[{\"message\":{\"content\":\"こんにちは世界\"}}]}");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("こんにちは世界", out);
}
