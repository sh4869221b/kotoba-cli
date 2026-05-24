const std = @import("std");
const sys = @import("sys.zig");

pub fn fetchAlloc(allocator: std.mem.Allocator, url: []const u8, max_bytes: usize) ![]u8 {
    if (max_bytes == std.math.maxInt(usize)) return error.StreamTooLong;
    var client = std.http.Client{ .allocator = allocator, .io = sys.io() };
    defer client.deinit();

    const buffer = try allocator.alloc(u8, max_bytes + 1);
    defer allocator.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);

    const status = getToWriter(allocator, &client, url, &writer) catch |err| switch (err) {
        error.WriteFailed => return error.StreamTooLong,
        else => |e| return e,
    };
    try writer.flush();
    if (status.class() != .success) return error.HttpRequestFailed;
    const bytes = writer.buffered();
    if (bytes.len > max_bytes) return error.StreamTooLong;
    return allocator.dupe(u8, bytes);
}

pub fn downloadToFile(allocator: std.mem.Allocator, url: []const u8, dest: []const u8) !void {
    var client = std.http.Client{ .allocator = allocator, .io = sys.io() };
    defer client.deinit();

    var file = try sys.cwd().createFile(sys.io(), dest, .{ .truncate = true });
    defer file.close(sys.io());
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writerStreaming(sys.io(), &buffer);

    const result = try getToWriter(allocator, &client, url, &writer.interface);
    try writer.interface.flush();
    if (result.class() != .success) return error.HttpRequestFailed;
}

fn getToWriter(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    response_writer: *std.Io.Writer,
) !std.http.Status {
    var current_url = try allocator.dupe(u8, url);
    defer allocator.free(current_url);

    var redirects_remaining: u8 = 3;
    while (true) {
        const uri = try std.Uri.parse(current_url);
        var req = try client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
        });
        defer req.deinit();
        try req.sendBodiless();
        var response = try req.receiveHead(&.{});
        const status = response.head.status;
        if (status.class() == .redirect) {
            if (redirects_remaining == 0) return error.TooManyHttpRedirects;
            redirects_remaining -= 1;
            const location = response.head.location orelse return error.HttpRedirectLocationMissing;
            const next_url = try resolveRedirectUrl(allocator, uri, location);

            const reader = response.reader(&.{});
            _ = reader.discardRemaining() catch |err| switch (err) {
                error.ReadFailed => return response.bodyErr().?,
                else => |e| return e,
            };

            allocator.free(current_url);
            current_url = next_url;
            continue;
        }

        if (status.class() != .success) return status;

        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer if (response.head.content_encoding != .identity) allocator.free(decompress_buffer);

        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        _ = reader.streamRemaining(response_writer) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };
        return status;
    }
}

fn resolveRedirectUrl(allocator: std.mem.Allocator, base: std.Uri, location: []const u8) ![]u8 {
    if (location.len > 8 * 1024) return error.HttpRedirectLocationOversize;
    var redirect_buffer: [16 * 1024]u8 = undefined;
    @memcpy(redirect_buffer[0..location.len], location);
    var remaining: []u8 = redirect_buffer[0..];
    const resolved = try base.resolveInPlace(location.len, &remaining);
    if (std.ascii.eqlIgnoreCase(base.scheme, "https") and
        !std.ascii.eqlIgnoreCase(resolved.scheme, "https"))
    {
        return error.InsecureRedirect;
    }
    return std.fmt.allocPrint(allocator, "{f}", .{resolved.fmt(.all)});
}

test "http helpers reject invalid URL syntax" {
    try std.testing.expectError(error.InvalidFormat, fetchAlloc(std.testing.allocator, "not a url", 1024));
}

test "fetchAlloc enforces max bytes without unbounded growth" {
    var server = try TestHttpServer.start("abcdef");
    defer server.stop();
    const url = try server.url(std.testing.allocator);
    defer std.testing.allocator.free(url);
    try std.testing.expectError(error.StreamTooLong, fetchAlloc(std.testing.allocator, url, 5));
}

test "downloadToFile streams response body to destination" {
    var server = try TestHttpServer.start("download bytes");
    defer server.stop();
    const url = try server.url(std.testing.allocator);
    defer std.testing.allocator.free(url);
    const dest = "/tmp/kotoba-net-download-to-file-test.bin";
    sys.deleteFile(dest);
    defer sys.deleteFile(dest);

    try downloadToFile(std.testing.allocator, url, dest);

    const downloaded = try sys.readFileAlloc(std.testing.allocator, dest, 1024);
    defer std.testing.allocator.free(downloaded);
    try std.testing.expectEqualStrings("download bytes", downloaded);
}

test "downloadToFile follows redirects" {
    var target = try TestHttpServer.start("redirect target");
    defer target.stop();
    const target_url = try target.url(std.testing.allocator);
    defer std.testing.allocator.free(target_url);
    var redirect = try TestHttpServer.startRedirect(target_url);
    defer redirect.stop();
    const redirect_url = try redirect.url(std.testing.allocator);
    defer std.testing.allocator.free(redirect_url);
    const dest = "/tmp/kotoba-net-download-redirect-test.bin";
    sys.deleteFile(dest);
    defer sys.deleteFile(dest);

    try downloadToFile(std.testing.allocator, redirect_url, dest);

    const downloaded = try sys.readFileAlloc(std.testing.allocator, dest, 1024);
    defer std.testing.allocator.free(downloaded);
    try std.testing.expectEqualStrings("redirect target", downloaded);
}

test "https redirects to http are rejected" {
    const base = try std.Uri.parse("https://example.invalid/model.gguf");
    try std.testing.expectError(
        error.InsecureRedirect,
        resolveRedirectUrl(std.testing.allocator, base, "http://example.invalid/model.gguf"),
    );
}

const TestHttpServer = struct {
    state: *State,

    const State = struct {
        server: std.Io.net.Server,
        thread: std.Thread,
        body: []const u8,
        redirect_url: ?[]const u8,
    };

    fn start(body: []const u8) !TestHttpServer {
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        const server = try address.listen(sys.io(), .{});
        const state = try std.testing.allocator.create(State);
        errdefer std.testing.allocator.destroy(state);
        state.* = .{
            .server = server,
            .thread = undefined,
            .body = body,
            .redirect_url = null,
        };
        state.thread = try std.Thread.spawn(.{}, serve, .{state});
        return .{ .state = state };
    }

    fn startRedirect(location: []const u8) !TestHttpServer {
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        const server = try address.listen(sys.io(), .{});
        const state = try std.testing.allocator.create(State);
        errdefer std.testing.allocator.destroy(state);
        state.* = .{
            .server = server,
            .thread = undefined,
            .body = "",
            .redirect_url = location,
        };
        state.thread = try std.Thread.spawn(.{}, serve, .{state});
        return .{ .state = state };
    }

    fn stop(self: *TestHttpServer) void {
        self.state.server.deinit(sys.io());
        self.state.thread.join();
        std.testing.allocator.destroy(self.state);
    }

    fn url(self: *TestHttpServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/fixture", .{self.state.server.socket.address.getPort()});
    }

    fn serve(state: *State) void {
        var stream = state.server.accept(sys.io()) catch return;
        defer stream.close(sys.io());
        var buffer: [1024]u8 = undefined;
        var writer = stream.writer(sys.io(), &buffer);
        if (state.redirect_url) |location| {
            writer.interface.print(
                "HTTP/1.1 302 Found\r\nlocation: {s}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
                .{location},
            ) catch return;
        } else {
            writer.interface.print(
                "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}",
                .{ state.body.len, state.body },
            ) catch return;
        }
        writer.interface.flush() catch return;
    }
};
