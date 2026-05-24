const std = @import("std");
const sys = @import("sys.zig");

pub fn fetchAlloc(allocator: std.mem.Allocator, url: []const u8, max_bytes: usize) ![]u8 {
    if (max_bytes == std.math.maxInt(usize)) return error.StreamTooLong;
    var client = std.http.Client{ .allocator = allocator, .io = sys.io() };
    defer client.deinit();

    const buffer = try allocator.alloc(u8, max_bytes + 1);
    defer allocator.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &writer,
    }) catch |err| switch (err) {
        error.WriteFailed => return error.StreamTooLong,
        else => |e| return e,
    };
    try writer.flush();
    if (result.status.class() != .success) return error.HttpRequestFailed;
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

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &writer.interface,
    });
    try writer.interface.flush();
    if (result.status.class() != .success) return error.HttpRequestFailed;
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

const TestHttpServer = struct {
    state: *State,

    const State = struct {
        server: std.Io.net.Server,
        thread: std.Thread,
        body: []const u8,
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
        writer.interface.print(
            "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}",
            .{ state.body.len, state.body },
        ) catch return;
        writer.interface.flush() catch return;
    }
};
