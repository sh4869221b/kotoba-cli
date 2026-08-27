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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const dest = try std.fs.path.join(std.testing.allocator, &.{ root, "download.bin" });
    defer std.testing.allocator.free(dest);

    var server = try TestHttpServer.start("download bytes");
    defer server.stop();
    const url = try server.url(std.testing.allocator);
    defer std.testing.allocator.free(url);

    try downloadToFile(std.testing.allocator, url, dest);

    const downloaded = try sys.readFileAlloc(std.testing.allocator, dest, 1024);
    defer std.testing.allocator.free(downloaded);
    try std.testing.expectEqualStrings("download bytes", downloaded);
}

test "downloadToFile follows redirects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const dest = try std.fs.path.join(std.testing.allocator, &.{ root, "redirect.bin" });
    defer std.testing.allocator.free(dest);

    var target = try TestHttpServer.start("redirect target");
    defer target.stop();
    const target_url = try target.url(std.testing.allocator);
    defer std.testing.allocator.free(target_url);
    var redirect = try TestHttpServer.startRedirect(target_url);
    defer redirect.stop();
    const redirect_url = try redirect.url(std.testing.allocator);
    defer std.testing.allocator.free(redirect_url);

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
    state: ?*State,
    result: Stats = .{},

    const max_responses = 16;
    const max_response_bytes = 64 * 1024;
    const max_request_bytes = 8 * 1024;

    const Stats = struct {
        accepted: usize = 0,
        completed: usize = 0,
        unused: usize = 0,
        active: bool = false,
        joined: bool = false,
        failure: ?anyerror = null,
    };

    const State = struct {
        server: std.Io.net.Server,
        wake_read: std.Io.File,
        wake_write: std.Io.File,
        thread: std.Thread,
        responses: [][]u8,
        mutex: std.Io.Mutex = .init,
        changed: std.Io.Condition = .init,
        stopping: bool = false,
        finished: bool = false,
        active: ?std.Io.net.Stream = null,
        stats: Stats,
    };

    fn start(body: []const u8) !TestHttpServer {
        const raw = try std.fmt.allocPrint(std.testing.allocator, "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}", .{ body.len, body });
        defer std.testing.allocator.free(raw);
        return startScript(&.{raw});
    }

    fn startRedirect(location: []const u8) !TestHttpServer {
        const raw = try std.fmt.allocPrint(std.testing.allocator, "HTTP/1.1 302 Found\r\nlocation: {s}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n", .{location});
        defer std.testing.allocator.free(raw);
        return startScript(&.{raw});
    }

    fn startScript(responses: []const []const u8) !TestHttpServer {
        if (responses.len > max_responses) return error.ScriptTooLong;
        for (responses) |raw| if (raw.len > max_response_bytes) return error.ResponseTooLong;
        const allocator = std.testing.allocator;
        const owned = try allocator.alloc([]u8, responses.len);
        errdefer allocator.free(owned);
        var copied: usize = 0;
        errdefer for (owned[0..copied]) |raw| allocator.free(raw);
        for (responses, 0..) |raw, i| {
            owned[i] = try allocator.dupe(u8, raw);
            copied += 1;
        }

        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        var server = try address.listen(std.testing.io, .{});
        errdefer server.deinit(std.testing.io);
        var pipe: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&pipe) != 0) return error.WakeupPipeFailed;
        const wake_read = std.Io.File{ .handle = pipe[0], .flags = .{ .nonblocking = false } };
        errdefer wake_read.close(std.testing.io);
        const wake_write = std.Io.File{ .handle = pipe[1], .flags = .{ .nonblocking = false } };
        errdefer wake_write.close(std.testing.io);
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{
            .server = server,
            .wake_read = wake_read,
            .wake_write = wake_write,
            .thread = undefined,
            .responses = owned,
            .stats = .{ .unused = owned.len },
        };
        state.thread = try std.Thread.spawn(.{}, serve, .{state});
        return .{ .state = state };
    }

    fn stop(self: *TestHttpServer) void {
        const state = self.state orelse return;
        state.mutex.lockUncancelable(std.testing.io);
        state.stopping = true;
        // EOF on the dedicated pipe wakes poll even with no client or unused scripts.
        state.wake_write.close(std.testing.io);
        if (state.active) |stream| stream.shutdown(std.testing.io, .both) catch {};
        state.mutex.unlock(std.testing.io);
        state.thread.join();
        std.debug.assert(state.finished and state.active == null);
        state.server.deinit(std.testing.io);
        state.wake_read.close(std.testing.io);
        self.result = state.stats;
        self.result.joined = true;
        for (state.responses) |raw| std.testing.allocator.free(raw);
        std.testing.allocator.free(state.responses);
        std.testing.allocator.destroy(state);
        self.state = null;
    }

    fn url(self: *TestHttpServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/fixture", .{self.state.?.server.socket.address.getPort()});
    }

    fn waitAccepted(self: *TestHttpServer) !void {
        const state = self.state.?;
        state.mutex.lockUncancelable(std.testing.io);
        defer state.mutex.unlock(std.testing.io);
        while (state.stats.accepted == 0 and !state.finished) state.changed.waitUncancelable(std.testing.io, &state.mutex);
        try std.testing.expectEqual(@as(usize, 1), state.stats.accepted);
    }

    fn serve(state: *State) void {
        defer {
            state.mutex.lockUncancelable(std.testing.io);
            state.finished = true;
            state.changed.broadcast(std.testing.io);
            state.mutex.unlock(std.testing.io);
        }
        serveScript(state) catch |err| {
            state.mutex.lockUncancelable(std.testing.io);
            state.stats.failure = err;
            state.mutex.unlock(std.testing.io);
        };
    }

    fn serveScript(state: *State) !void {
        for (state.responses) |raw| {
            var fds = [_]std.posix.pollfd{
                .{ .fd = state.server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = state.wake_read.handle, .events = std.posix.POLL.IN, .revents = 0 },
            };
            _ = try std.posix.poll(&fds, -1);
            if (fds[1].revents != 0) return;
            if (fds[0].revents & std.posix.POLL.IN == 0) return error.ListenerFailed;
            const stream = try state.server.accept(std.testing.io);
            state.mutex.lockUncancelable(std.testing.io);
            if (state.stopping) {
                stream.close(std.testing.io);
                state.mutex.unlock(std.testing.io);
                return;
            }
            state.active = stream;
            state.stats.active = true;
            state.stats.accepted += 1;
            state.changed.broadcast(std.testing.io);
            state.mutex.unlock(std.testing.io);
            defer {
                // Shutdown and close never race on a descriptor that could be reused.
                state.mutex.lockUncancelable(std.testing.io);
                stream.close(std.testing.io);
                state.active = null;
                state.stats.active = false;
                state.mutex.unlock(std.testing.io);
            }

            try readRequestHead(stream);
            state.mutex.lockUncancelable(std.testing.io);
            state.stats.unused -= 1;
            state.mutex.unlock(std.testing.io);
            var buffer: [1024]u8 = undefined;
            var writer = stream.writer(std.testing.io, &buffer);
            try writer.interface.writeAll(raw);
            try writer.interface.flush();
            state.mutex.lockUncancelable(std.testing.io);
            state.stats.completed += 1;
            state.mutex.unlock(std.testing.io);
        }
    }

    fn readRequestHead(stream: std.Io.net.Stream) !void {
        var buffer: [1024]u8 = undefined;
        var reader = stream.reader(std.testing.io, &buffer);
        var head: [max_request_bytes]u8 = undefined;
        for (&head, 0..) |*byte, i| {
            byte.* = try reader.interface.takeByte();
            const bytes = head[0 .. i + 1];
            if (std.mem.endsWith(u8, bytes, "\r\n\r\n")) {
                if (!std.mem.startsWith(u8, bytes, "GET ")) return error.InvalidRequest;
                return;
            }
        }
        return error.RequestHeadTooLong;
    }

    fn expectStopped(self: *TestHttpServer, accepted: usize, completed: usize, unused: usize) !void {
        self.stop();
        try std.testing.expect(self.state == null);
        try std.testing.expect(self.result.joined);
        try std.testing.expect(!self.result.active);
        try std.testing.expectEqual(accepted, self.result.accepted);
        try std.testing.expectEqual(completed, self.result.completed);
        if (completed > 0) try std.testing.expectEqual(null, self.result.failure);
        try std.testing.expectEqual(unused, self.result.unused);
    }
};

const http_ok = "HTTP/1.1 200 OK\r\ncontent-length: 6\r\nconnection: close\r\n\r\nabcdef";
const http_redirect = "HTTP/1.1 302 Found\r\nlocation: /next\r\ncontent-length: 0\r\nconnection: close\r\n\r\n";

fn expectFetch(server: *TestHttpServer, limit: usize, expected: []const u8) !void {
    const url = try server.url(std.testing.allocator);
    defer std.testing.allocator.free(url);
    const bytes = try fetchAlloc(std.testing.allocator, url, limit);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(expected, bytes);
}

fn expectFetchError(server: *TestHttpServer, limit: usize, expected: anyerror) !void {
    const url = try server.url(std.testing.allocator);
    defer std.testing.allocator.free(url);
    const result = fetchAlloc(std.testing.allocator, url, limit);
    defer if (result) |bytes| std.testing.allocator.free(bytes) else |_| {};
    try std.testing.expectError(expected, result);
}

test "fault http happy exact limit and interleaved independent peers" {
    var first = try TestHttpServer.startScript(&.{ http_ok, http_ok });
    defer first.stop();
    var second = try TestHttpServer.start("other");
    defer second.stop();
    try expectFetch(&first, 6, "abcdef");
    try expectFetch(&second, 5, "other");
    try expectFetch(&first, 1024, "abcdef");
    try first.expectStopped(2, 2, 0);
    try second.expectStopped(1, 1, 0);
    try std.testing.expectEqual(null, first.result.failure);
    try std.testing.expectEqual(null, second.result.failure);
}

test "fault http happy relative redirect and real file download" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const dest = try std.fs.path.join(std.testing.allocator, &.{ root, "raw-download.bin" });
    defer std.testing.allocator.free(dest);
    var server = try TestHttpServer.startScript(&.{ http_redirect, http_ok });
    defer server.stop();
    const url = try server.url(std.testing.allocator);
    defer std.testing.allocator.free(url);
    try downloadToFile(std.testing.allocator, url, dest);
    const bytes = try sys.readFileAlloc(std.testing.allocator, dest, 100);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("abcdef", bytes);
    try server.expectStopped(2, 2, 0);
    try std.testing.expectEqual(null, server.result.failure);
}

test "fault http failure scripted status uses real HTTP parser" {
    for ([_][]const u8{
        "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
        "HTTP/1.1 503 Unavailable\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
    }) |raw| {
        var server = try TestHttpServer.startScript(&.{ raw, http_ok });
        defer server.stop();
        try expectFetchError(&server, 100, error.HttpRequestFailed);
        try server.expectStopped(1, 1, 1);
    }
}

test "fault http failure missing Location and redirect limit leave unused responses" {
    var missing = try TestHttpServer.startScript(&.{ "HTTP/1.1 302 Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n", http_ok });
    defer missing.stop();
    try expectFetchError(&missing, 100, error.HttpRedirectLocationMissing);
    try missing.expectStopped(1, 1, 1);
    var looping = try TestHttpServer.startScript(&.{ http_redirect, http_redirect, http_redirect, http_redirect, http_ok });
    defer looping.stop();
    try expectFetchError(&looping, 100, error.TooManyHttpRedirects);
    try looping.expectStopped(4, 4, 1);
}

test "fault http failure Content-Length truncation characterization" {
    var server = try TestHttpServer.startScript(&.{"HTTP/1.1 200 OK\r\ncontent-length: 6\r\nconnection: close\r\n\r\nabc"});
    defer server.stop();
    // Preserve the current streamRemaining behavior: raw EOF accepts this prefix.
    try expectFetch(&server, 6, "abc");
    try server.expectStopped(1, 1, 0);
}

test "fault http failure chunked truncation is a parser error" {
    var server = try TestHttpServer.startScript(&.{"HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n5\r\nabc"});
    defer server.stop();
    try expectFetchError(&server, 100, error.HttpChunkTruncated);
    try server.expectStopped(1, 1, 0);
}

test "fault http failure byte limits and rejection before connection" {
    for ([_]usize{ 5, 2 }) |limit| {
        var server = try TestHttpServer.startScript(&.{ http_ok, http_ok });
        defer server.stop();
        try expectFetchError(&server, limit, error.StreamTooLong);
        try server.expectStopped(1, 1, 1);
    }
    var no_client = try TestHttpServer.startScript(&.{http_ok});
    defer no_client.stop();
    try expectFetchError(&no_client, std.math.maxInt(usize), error.StreamTooLong);
    try no_client.expectStopped(0, 0, 1);
}

test "fault http failure stop with no client empty script and partial request" {
    var empty = try TestHttpServer.startScript(&.{});
    defer empty.stop();
    try empty.expectStopped(0, 0, 0);
    var idle = try TestHttpServer.startScript(&.{ http_ok, http_ok });
    defer idle.stop();
    try idle.expectStopped(0, 0, 2);
    var partial = try TestHttpServer.startScript(&.{ http_ok, http_ok });
    defer partial.stop();
    const client = try partial.state.?.server.socket.address.connect(std.testing.io, .{ .mode = .stream });
    defer client.close(std.testing.io);
    var writer = client.writer(std.testing.io, &.{});
    try writer.interface.writeAll("GET /unfinished");
    try partial.waitAccepted();
    try partial.expectStopped(1, 0, 2);
    try std.testing.expect(partial.result.failure != null);
}

test "fault http failure aborted client closes active stream" {
    var server = try TestHttpServer.startScript(&.{ http_ok, http_ok });
    defer server.stop();
    const client = try server.state.?.server.socket.address.connect(std.testing.io, .{ .mode = .stream });
    var closed = false;
    defer if (!closed) client.close(std.testing.io);
    try server.waitAccepted();
    client.close(std.testing.io);
    closed = true;
    try server.expectStopped(1, 0, 2);
}

test "fault http failure request and script bounds" {
    const too_many = [_][]const u8{http_ok} ** (TestHttpServer.max_responses + 1);
    try std.testing.expectError(error.ScriptTooLong, TestHttpServer.startScript(&too_many));
    const too_large = [_]u8{'x'} ** (TestHttpServer.max_response_bytes + 1);
    try std.testing.expectError(error.ResponseTooLong, TestHttpServer.startScript(&.{&too_large}));
    var server = try TestHttpServer.startScript(&.{http_ok});
    defer server.stop();
    const client = try server.state.?.server.socket.address.connect(std.testing.io, .{ .mode = .stream });
    defer client.close(std.testing.io);
    var writer = client.writer(std.testing.io, &.{});
    const oversized_head = [_]u8{'x'} ** TestHttpServer.max_request_bytes;
    try writer.interface.writeAll(&oversized_head);
    var read_buffer: [1]u8 = undefined;
    var reader = client.reader(std.testing.io, &read_buffer);
    try std.testing.expectError(error.EndOfStream, reader.interface.takeByte());
    try server.expectStopped(1, 0, 1);
    try std.testing.expectEqual(error.RequestHeadTooLong, server.result.failure.?);
}
