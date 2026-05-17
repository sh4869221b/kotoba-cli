const std = @import("std");
const errors = @import("errors.zig");
const c = @cImport({
    @cInclude("arpa/inet.h");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("netinet/in.h");
    @cInclude("poll.h");
    @cInclude("sys/socket.h");
    @cInclude("time.h");
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

pub const LocalEndpoint = struct {
    host: []const u8,
    port: u16,
    lock_key: []const u8,
    autostartable: bool,

    pub fn deinit(self: LocalEndpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.lock_key);
    }
};

pub fn validateLocalServerUrl(server_url: []const u8, allow_remote_server: bool) !void {
    if (allow_remote_server) return;
    const p = try parseHttpUrl(server_url);
    if (isLoopbackHost(p.host)) return;
    return errors.Error.ServerNotLocal;
}

pub fn healthCheck(allocator: std.mem.Allocator, server_url: []const u8, timeout_sec: u32, allow_remote_server: bool) !HealthStatus {
    try validateLocalServerUrl(server_url, allow_remote_server);
    const response = request(allocator, "GET", server_url, "/health", null, timeout_sec) catch |err| switch (err) {
        errors.Error.Timeout => return errors.Error.Timeout,
        errors.Error.Interrupted => return errors.Error.Interrupted,
        else => return errors.Error.ServerUnreachable,
    };
    defer allocator.free(response);
    return .ok;
}

pub fn translateSegment(allocator: std.mem.Allocator, req: Request) ![]const u8 {
    try validateLocalServerUrl(req.server_url, req.allow_remote_server);
    var json = std.array_list.Managed(u8).init(allocator);
    defer json.deinit();
    try json.appendSlice("{\"model\":");
    try appendJsonString(&json, req.model_id);
    try json.appendSlice(",\"messages\":[{\"role\":\"user\",\"content\":");
    try appendJsonString(&json, req.prompt);
    try json.appendSlice("}],\"temperature\":0.2}");
    const response = request(allocator, "POST", req.server_url, "/v1/chat/completions", json.items, req.timeout_sec) catch |err| switch (err) {
        errors.Error.Timeout => return errors.Error.Timeout,
        errors.Error.Interrupted => return errors.Error.Interrupted,
        else => return errors.Error.ServerUnreachable,
    };
    defer allocator.free(response);
    return parseCompletion(allocator, response);
}

fn appendJsonString(out: *std.array_list.Managed(u8), text: []const u8) !void {
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

pub fn localEndpoint(allocator: std.mem.Allocator, server_url: []const u8) !LocalEndpoint {
    const p = try parseHttpUrl(server_url);
    if (!isLoopbackHost(p.host)) return errors.Error.ServerNotLocal;
    const host = if (std.mem.eql(u8, p.host, "localhost")) "127.0.0.1" else p.host;
    const lock_host = if (std.mem.eql(u8, host, "localhost")) "127.0.0.1" else host;
    return .{
        .host = host,
        .port = p.port,
        .lock_key = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ lock_host, p.port }),
        .autostartable = p.base_path.len == 0,
    };
}

pub fn isLoopbackUrl(server_url: []const u8) bool {
    const p = parseHttpUrl(server_url) catch return false;
    return isLoopbackHost(p.host);
}

fn isLoopbackHost(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "::1");
}

fn parseHttpUrl(url: []const u8) !ParsedUrl {
    if (!std.mem.startsWith(u8, url, "http://")) return errors.Error.ServerNotLocal;
    var rest = url["http://".len..];
    var path: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '/')) |idx| {
        path = rest[idx..];
        rest = rest[0..idx];
    }
    if (std.mem.eql(u8, path, "/")) path = "";
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

fn request(allocator: std.mem.Allocator, method: []const u8, server_url: []const u8, path: []const u8, body: ?[]const u8, timeout_sec: u32) ![]const u8 {
    const parsed = try parseHttpUrl(server_url);
    var deadline = RequestDeadline.init(timeout_sec);
    const fd = try connectLocal(parsed, &deadline);
    defer _ = c.close(fd);

    const target = try std.fmt.allocPrint(allocator, "{s}{s}", .{ if (parsed.base_path.len == 0) "" else parsed.base_path, path });
    defer allocator.free(target);
    const host_header = if (std.mem.eql(u8, parsed.host, "::1"))
        try std.fmt.allocPrint(allocator, "[{s}]:{d}", .{ parsed.host, parsed.port })
    else
        try std.fmt.allocPrint(allocator, "{s}:{d}", .{ parsed.host, parsed.port });
    defer allocator.free(host_header);
    const request_bytes = if (body) |b|
        try std.fmt.allocPrint(allocator, "{s} {s} HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ method, target, host_header, b.len, b })
    else
        try std.fmt.allocPrint(allocator, "{s} {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ method, target, host_header });
    defer allocator.free(request_bytes);
    try sendAll(fd, request_bytes, &deadline);
    const raw = try recvAll(allocator, fd, 16 * 1024 * 1024, &deadline);
    defer allocator.free(raw);
    return parseHttpResponse(allocator, raw);
}

fn connectLocal(parsed: ParsedUrl, deadline: *RequestDeadline) !c_int {
    if (std.mem.eql(u8, parsed.host, "::1")) return connectIpv6Loopback(parsed.port, deadline);
    return connectIpv4(parsed, deadline);
}

fn connectIpv4(parsed: ParsedUrl, deadline: *RequestDeadline) !c_int {
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return errors.Error.ServerUnreachable;
    errdefer _ = c.close(fd);
    try makeNonBlocking(fd);
    var addr: c.sockaddr_in = std.mem.zeroes(c.sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = c.htons(parsed.port);
    const host = if (std.mem.eql(u8, parsed.host, "localhost")) "127.0.0.1" else parsed.host;
    var host_buf: [64:0]u8 = [_:0]u8{0} ** 64;
    if (host.len >= host_buf.len) return errors.Error.ServerUnreachable;
    @memcpy(host_buf[0..host.len], host);
    if (c.inet_pton(c.AF_INET, &host_buf, &addr.sin_addr) != 1) return errors.Error.ServerUnreachable;
    try connectWithTimeout(fd, @ptrCast(&addr), @sizeOf(c.sockaddr_in), deadline);
    return fd;
}

fn connectIpv6Loopback(port: u16, deadline: *RequestDeadline) !c_int {
    const fd = c.socket(c.AF_INET6, c.SOCK_STREAM, 0);
    if (fd < 0) return errors.Error.ServerUnreachable;
    errdefer _ = c.close(fd);
    try makeNonBlocking(fd);
    var addr: c.sockaddr_in6 = std.mem.zeroes(c.sockaddr_in6);
    addr.sin6_family = c.AF_INET6;
    addr.sin6_port = c.htons(port);
    var host_buf: [4:0]u8 = [_:0]u8{ ':', ':', '1', 0 };
    if (c.inet_pton(c.AF_INET6, &host_buf, &addr.sin6_addr) != 1) return errors.Error.ServerUnreachable;
    try connectWithTimeout(fd, @ptrCast(&addr), @sizeOf(c.sockaddr_in6), deadline);
    return fd;
}

fn makeNonBlocking(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
    if (flags < 0) return errors.Error.ServerUnreachable;
    if (c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) != 0) return errors.Error.ServerUnreachable;
}

const RequestDeadline = struct {
    deadline_ms: i64,

    fn init(timeout_sec: u32) RequestDeadline {
        const sec = if (timeout_sec == 0) 1 else timeout_sec;
        const capped = @min(sec, @as(u32, 24 * 60 * 60));
        return .{ .deadline_ms = nowMs() + @as(i64, @intCast(capped)) * 1000 };
    }

    fn remainingMs(self: RequestDeadline) !c_int {
        const remaining = self.deadline_ms - nowMs();
        if (remaining <= 0) return errors.Error.Timeout;
        return @intCast(@min(remaining, @as(i64, std.math.maxInt(c_int))));
    }

    fn nowMs() i64 {
        return @as(i64, @intCast(c.time(null))) * 1000;
    }
};

fn waitFd(fd: c_int, events: c_short, deadline: *RequestDeadline) !void {
    var pfd = c.pollfd{ .fd = fd, .events = events, .revents = 0 };
    const rc = c.poll(&pfd, 1, try deadline.remainingMs());
    if (rc == 0) return errors.Error.Timeout;
    if (rc < 0 and std.c.errno(-1) == .INTR) return errors.Error.Interrupted;
    if (rc < 0) return errors.Error.ServerUnreachable;
    if ((pfd.revents & (c.POLLERR | c.POLLNVAL)) != 0) return errors.Error.ServerUnreachable;
    if ((pfd.revents & c.POLLHUP) != 0 and (pfd.revents & events) == 0) return errors.Error.ServerUnreachable;
    if ((pfd.revents & events) == 0) return errors.Error.ServerUnreachable;
}

fn connectWithTimeout(fd: c_int, addr: [*c]const c.sockaddr, len: c.socklen_t, deadline: *RequestDeadline) !void {
    if (c.connect(fd, addr, len) == 0) return;
    const err = std.c.errno(-1);
    if (err == .INTR) return errors.Error.Interrupted;
    if (err != .INPROGRESS and err != .AGAIN) return errors.Error.ServerUnreachable;
    try waitFd(fd, c.POLLOUT, deadline);
    var sock_err: c_int = 0;
    var sock_len: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, &sock_err, &sock_len) != 0) return errors.Error.ServerUnreachable;
    if (sock_err != 0) return errors.Error.ServerUnreachable;
}

fn sendAll(fd: c_int, bytes: []const u8, deadline: *RequestDeadline) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        _ = try deadline.remainingMs();
        const n = c.send(fd, bytes.ptr + sent, bytes.len - sent, 0);
        if (n < 0) {
            const err = std.c.errno(-1);
            if (err == .AGAIN) {
                try waitFd(fd, c.POLLOUT, deadline);
                continue;
            }
            if (err == .INTR) return errors.Error.Interrupted;
            return errors.Error.ServerUnreachable;
        }
        if (n == 0) return errors.Error.ServerUnreachable;
        sent += @intCast(n);
    }
}

fn recvAll(allocator: std.mem.Allocator, fd: c_int, limit: usize, deadline: *RequestDeadline) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var buf: [8192]u8 = undefined;
    while (true) {
        _ = try deadline.remainingMs();
        const n = c.recv(fd, &buf, buf.len, 0);
        if (n < 0) {
            const err = std.c.errno(-1);
            if (err == .AGAIN) {
                try waitFd(fd, c.POLLIN, deadline);
                continue;
            }
            if (err == .INTR) return errors.Error.Interrupted;
            return errors.Error.ServerUnreachable;
        }
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

test "local endpoint extraction" {
    const a = std.testing.allocator;
    const ep = try localEndpoint(a, "http://127.0.0.1:8080");
    defer ep.deinit(a);
    try std.testing.expectEqualStrings("127.0.0.1", ep.host);
    try std.testing.expectEqual(@as(u16, 8080), ep.port);
    try std.testing.expect(ep.autostartable);

    const localhost = try localEndpoint(a, "http://localhost:18080");
    defer localhost.deinit(a);
    try std.testing.expectEqualStrings("127.0.0.1", localhost.host);
    try std.testing.expectEqualStrings("127.0.0.1-18080", localhost.lock_key);

    const ipv4 = try localEndpoint(a, "http://127.0.0.1:18080");
    defer ipv4.deinit(a);
    try std.testing.expectEqualStrings(ipv4.lock_key, localhost.lock_key);

    const ipv6 = try localEndpoint(a, "http://[::1]:18080");
    defer ipv6.deinit(a);
    try std.testing.expectEqualStrings("::1", ipv6.host);
    try std.testing.expect(!std.mem.eql(u8, ipv6.lock_key, localhost.lock_key));

    const base = try localEndpoint(a, "http://127.0.0.1:8080/v1");
    defer base.deinit(a);
    try std.testing.expect(!base.autostartable);

    const root_slash = try localEndpoint(a, "http://127.0.0.1:8080/");
    defer root_slash.deinit(a);
    try std.testing.expect(root_slash.autostartable);

    try std.testing.expectError(errors.Error.ServerNotLocal, localEndpoint(a, "https://example.com/v1"));
    try std.testing.expectError(errors.Error.ServerNotLocal, localEndpoint(a, "http://192.168.1.10:8080"));
}

test "parse completion" {
    const out = try parseCompletion(std.testing.allocator, "{\"choices\":[{\"message\":{\"content\":\"こんにちは世界\"}}]}");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("こんにちは世界", out);
}

test "json string escaping" {
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try appendJsonString(&out, "model\"id\\name\n");
    try std.testing.expectEqualStrings("\"model\\\"id\\\\name\\n\"", out.items);
}
