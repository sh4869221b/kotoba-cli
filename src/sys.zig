const std = @import("std");
const fs = @import("fs.zig");
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("time.h");
});

pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return cwd().readFileAlloc(io(), path, allocator, .limited(limit));
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    var filesystem = fs.FileSystem.init(io(), cwd(), null);
    try filesystem.writeFile(path, data);
}

pub fn copyFile(src: []const u8, dest: []const u8) !void {
    try std.Io.Dir.copyFile(cwd(), src, cwd(), dest, io(), .{ .make_path = true, .replace = true });
}

pub fn renameFile(src: []const u8, dest: []const u8) !void {
    var filesystem = fs.FileSystem.init(io(), cwd(), null);
    try filesystem.renameFile(src, dest);
}

pub fn realPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return cwd().realPathFileAlloc(io(), path, allocator);
}

pub fn exists(path: []const u8) bool {
    cwd().access(io(), path, .{}) catch return false;
    return true;
}

pub fn makePath(path: []const u8) !void {
    try cwd().createDirPath(io(), path);
}

pub fn deleteFile(path: []const u8) void {
    var filesystem = fs.FileSystem.init(io(), cwd(), null);
    filesystem.deleteFile(path) catch {};
}

pub fn stdoutWrite(bytes: []const u8) void {
    var writer = std.Io.File.stdout().writerStreaming(io(), &.{});
    writeWriterAll(&writer.interface, bytes) catch {};
}

pub fn stderrWrite(bytes: []const u8) void {
    var writer = std.Io.File.stderr().writerStreaming(io(), &.{});
    writeWriterAll(&writer.interface, bytes) catch {};
}

pub fn stdoutPrint(comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
    defer std.heap.page_allocator.free(msg);
    stdoutWrite(msg);
}

pub fn stderrPrint(comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
    defer std.heap.page_allocator.free(msg);
    stderrWrite(msg);
}

pub fn readStdinAlloc(allocator: std.mem.Allocator, limit: usize) ![]u8 {
    var reader: PosixReader = .{};
    return readReaderAlloc(allocator, &reader.interface, limit) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => return err,
    };
}

// Keep stdin's POSIX error semantics: File.Reader retries timed-out reads and
// maps bad descriptors differently. Only the native stream interface is new.
const PosixReader = struct {
    interface: std.Io.Reader = .{
        .vtable = &.{ .stream = stream },
        .buffer = &.{},
        .seek = 0,
        .end = 0,
    },
    handle: std.posix.fd_t = std.posix.STDIN_FILENO,
    err: ?std.posix.ReadError = null,

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        if (limit == .nothing) return 0;
        const self: *PosixReader = @alignCast(@fieldParentPtr("interface", reader));
        const dest = limit.slice(try writer.writableSliceGreedy(1));
        const n = std.posix.read(self.handle, dest) catch |err| {
            self.err = err;
            return error.ReadFailed;
        };
        if (n == 0) return error.EndOfStream;
        writer.advance(n);
        return n;
    }
};

pub fn readReaderAlloc(allocator: std.mem.Allocator, reader: *std.Io.Reader, limit: usize) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var buffer: [8192]u8 = undefined;
    var data = [_][]u8{&buffer};
    while (true) {
        const n = reader.readVec(&data) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return err,
        };
        if (n > limit - out.items.len) return error.StreamTooLong;
        try out.appendSlice(buffer[0..n]);
    }
    return out.toOwnedSlice();
}

pub fn writeWriterAll(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeAll(bytes);
    try writer.flush();
}

/// Borrows source and positive short-read limits. Take interface pointers only
/// after this value is at its final address. Exhausted scripts resume normally.
pub const ScriptedReader = struct {
    interface: std.Io.Reader,
    source: []const u8,
    short_reads: []const usize,
    bytes_read: usize = 0,
    read_calls: usize = 0,
    script_index: usize = 0,
    fail_at: ?usize = null,
    last_cause: ?Cause = null,

    pub const Cause = error{InputOutput};

    pub fn init(source: []const u8, short_reads: []const usize) ScriptedReader {
        for (short_reads) |n| std.debug.assert(n > 0);
        return .{
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 },
            .source = source,
            .short_reads = short_reads,
        };
    }

    pub fn arm(self: *ScriptedReader, occurrence: usize) void {
        std.debug.assert(occurrence > 0);
        self.fail_at = self.read_calls + occurrence;
    }

    pub fn disarm(self: *ScriptedReader) void {
        self.fail_at = null;
    }

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *ScriptedReader = @alignCast(@fieldParentPtr("interface", reader));
        self.read_calls += 1;
        if (self.bytes_read == self.source.len) return error.EndOfStream;
        if (self.fail_at == self.read_calls) {
            self.disarm();
            self.last_cause = error.InputOutput;
            return error.ReadFailed;
        }
        var bytes = limit.sliceConst(self.source[self.bytes_read..]);
        if (self.script_index < self.short_reads.len) {
            bytes = bytes[0..@min(bytes.len, self.short_reads[self.script_index])];
            self.script_index += 1;
        }
        const n = try writer.write(bytes);
        self.bytes_read += n;
        return n;
    }
};

/// Borrows sink, buffering space and positive short-drain limits. Delivered
/// bytes exclude accepted bytes still buffered in interface.buffer.
pub const ScriptedWriter = struct {
    interface: std.Io.Writer,
    sink: []u8,
    short_writes: []const usize,
    bytes_written: usize = 0,
    write_calls: usize = 0,
    flush_calls: usize = 0,
    script_index: usize = 0,
    failure: ?Failure = null,
    last_cause: ?Cause = null,

    pub const Operation = enum { write, flush };
    pub const Cause = error{ BrokenPipe, NoSpaceLeft };
    const Failure = struct { operation: Operation, target: usize, cause: Cause };

    pub fn init(sink: []u8, buffer: []u8, short_writes: []const usize) ScriptedWriter {
        for (short_writes) |n| std.debug.assert(n > 0);
        return .{
            .interface = .{ .vtable = &.{ .drain = drain, .flush = flush }, .buffer = buffer },
            .sink = sink,
            .short_writes = short_writes,
        };
    }

    pub fn arm(self: *ScriptedWriter, operation: Operation, occurrence: usize, cause: Cause) void {
        std.debug.assert(occurrence > 0);
        const count = switch (operation) {
            .write => self.write_calls,
            .flush => self.flush_calls,
        };
        self.failure = .{ .operation = operation, .target = count + occurrence, .cause = cause };
    }

    pub fn disarm(self: *ScriptedWriter) void {
        self.failure = null;
    }

    fn check(self: *ScriptedWriter, operation: Operation) std.Io.Writer.Error!void {
        const count = switch (operation) {
            .write => &self.write_calls,
            .flush => &self.flush_calls,
        };
        count.* += 1;
        if (self.failure) |failure| {
            if (failure.operation == operation and failure.target == count.*) {
                self.disarm();
                self.last_cause = failure.cause;
                return error.WriteFailed;
            }
        }
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ScriptedWriter = @alignCast(@fieldParentPtr("interface", writer));
        try self.check(.write);
        var available = self.sink.len - self.bytes_written;
        if (available == 0) {
            self.last_cause = error.NoSpaceLeft;
            return error.WriteFailed;
        }
        if (self.script_index < self.short_writes.len) {
            available = @min(available, self.short_writes[self.script_index]);
            self.script_index += 1;
        }
        const buffered = @min(available, writer.end);
        self.deliver(writer.buffer[0..buffered]);
        std.mem.copyForwards(u8, writer.buffer[0 .. writer.end - buffered], writer.buffer[buffered..writer.end]);
        writer.end -= buffered;
        available -= buffered;
        var consumed: usize = 0;
        for (data, 0..) |bytes, i| {
            const repeats = if (i == data.len - 1) splat else 1;
            var repetition: usize = 0;
            while (repetition < repeats and available > 0 and bytes.len > 0) : (repetition += 1) {
                const n = @min(available, bytes.len);
                self.deliver(bytes[0..n]);
                consumed += n;
                available -= n;
            }
            if (available == 0) break;
        }
        return consumed;
    }

    fn deliver(self: *ScriptedWriter, bytes: []const u8) void {
        @memcpy(self.sink[self.bytes_written..][0..bytes.len], bytes);
        self.bytes_written += bytes.len;
    }

    fn flush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *ScriptedWriter = @alignCast(@fieldParentPtr("interface", writer));
        try self.check(.flush);
        while (writer.end > 0) _ = try drain(writer, &.{""}, 1);
    }
};

test "fault io failure prefix and broken pipe cause" {
    var sink: [6]u8 = undefined;
    var writer = ScriptedWriter.init(&sink, &.{}, &.{2});
    writer.arm(.write, 2, error.BrokenPipe);
    try std.testing.expectError(error.WriteFailed, writeWriterAll(&writer.interface, "abcdef"));
    try std.testing.expectEqualStrings("ab", sink[0..writer.bytes_written]);
    try std.testing.expectEqual(error.BrokenPipe, writer.last_cause.?);
    try std.testing.expectEqual(@as(usize, 2), writer.write_calls);
    try std.testing.expectEqual(@as(usize, 0), writer.flush_calls);
    try std.testing.expectEqual(null, writer.failure);
    try writeWriterAll(&writer.interface, "cdef");
    try std.testing.expectEqualStrings("abcdef", sink[0..writer.bytes_written]);
}

test "fault io happy short reads exact limit and stable EOF" {
    var reader = ScriptedReader.init("abcdef", &.{ 1, 2, 2, 1 });
    const bytes = try readReaderAlloc(std.testing.allocator, &reader.interface, 6);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("abcdef", bytes);
    try std.testing.expectEqual(@as(usize, 6), reader.bytes_read);
    try std.testing.expectEqual(@as(usize, 5), reader.read_calls);
    var byte: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, reader.interface.readSliceAll(&byte));
    try std.testing.expectEqual(@as(usize, 6), reader.read_calls);
    var empty = ScriptedReader.init("", &.{});
    const none = try readReaderAlloc(std.testing.allocator, &empty.interface, 0);
    defer std.testing.allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    try std.testing.expectEqual(@as(usize, 1), empty.read_calls);
}

test "fault io happy short writes and exhausted script" {
    var sink: [6]u8 = undefined;
    var writer = ScriptedWriter.init(&sink, &.{}, &.{ 1, 2 });
    try writeWriterAll(&writer.interface, "abcdef");
    try std.testing.expectEqualStrings("abcdef", sink[0..writer.bytes_written]);
    try std.testing.expectEqual(@as(usize, 3), writer.write_calls);
    try std.testing.expectEqual(@as(usize, 1), writer.flush_calls);
    try std.testing.expectEqual(null, writer.last_cause);
    var reader = ScriptedReader.init("abcdef", &.{1});
    const bytes = try readReaderAlloc(std.testing.allocator, &reader.interface, 6);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("abcdef", bytes);
    try std.testing.expectEqual(@as(usize, 3), reader.read_calls);
}

test "fault io happy short drain preserves pending buffer and splats" {
    var sink: [6]u8 = undefined;
    var buffer: [3]u8 = undefined;
    var writer = ScriptedWriter.init(&sink, &buffer, &.{ 1, 2, 1, 2 });
    try writer.interface.writeAll("abc");
    try std.testing.expectEqual(@as(usize, 0), writer.bytes_written);
    try std.testing.expectEqual(@as(usize, 0), try writer.interface.write("def"));
    try std.testing.expectEqualStrings("a", sink[0..writer.bytes_written]);
    try std.testing.expectEqualStrings("bc", writer.interface.buffered());
    try writeWriterAll(&writer.interface, "def");
    try std.testing.expectEqualStrings("abcdef", sink[0..writer.bytes_written]);
    try std.testing.expectEqual(@as(usize, 0), writer.interface.end);
    try std.testing.expectEqual(@as(usize, 4), writer.write_calls);
    var splat_sink: [6]u8 = undefined;
    var splat_writer = ScriptedWriter.init(&splat_sink, &.{}, &.{ 1, 2 });
    var slices = [_][]const u8{ "ab", "cd" };
    try splat_writer.interface.writeSplatAll(&slices, 2);
    try writeWriterAll(&splat_writer.interface, "");
    try std.testing.expectEqualStrings("abcdcd", splat_sink[0..splat_writer.bytes_written]);
}

test "fault io happy real local file adapters and POSIX error characterization" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(io(), "stream", .{ .read = true });
    defer file.close(io());
    var buffer: [3]u8 = undefined;
    var writer = file.writerStreaming(io(), &buffer);
    try writeWriterAll(&writer.interface, "abcdef");
    var reader = file.reader(io(), &.{});
    const bytes = try readReaderAlloc(std.testing.allocator, &reader.interface, 6);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("abcdef", bytes);
    var readable_dir = try tmp.dir.openDir(io(), ".", .{ .iterate = true });
    defer readable_dir.close(io());
    const directory: std.Io.File = .{ .handle = readable_dir.handle, .flags = .{ .nonblocking = false } };
    var directory_reader = directory.readerStreaming(io(), &.{});
    try std.testing.expectError(error.ReadFailed, readReaderAlloc(std.testing.allocator, &directory_reader.interface, 6));
    try std.testing.expectEqual(error.IsDir, directory_reader.err.?);
    var byte: [1]u8 = undefined;
    try std.testing.expectError(error.IsDir, std.posix.read(readable_dir.handle, &byte));
    var posix_reader: PosixReader = .{ .handle = readable_dir.handle };
    try std.testing.expectError(error.ReadFailed, readReaderAlloc(std.testing.allocator, &posix_reader.interface, 6));
    try std.testing.expectEqual(error.IsDir, posix_reader.err.?);
    var invalid_reader: PosixReader = .{ .handle = -1 };
    try std.testing.expectError(error.ReadFailed, readReaderAlloc(std.testing.allocator, &invalid_reader.interface, 6));
    try std.testing.expectEqual(error.Unexpected, invalid_reader.err.?);
}

test "fault io failure read limit prefix independent instances and rearm" {
    var limited = ScriptedReader.init("abcdef", &.{ 1, 2 });
    try std.testing.expectError(error.StreamTooLong, readReaderAlloc(std.testing.allocator, &limited.interface, 5));
    try std.testing.expectEqual(@as(usize, 6), limited.bytes_read);
    var left = ScriptedReader.init("abcdef", &.{2});
    var right = ScriptedReader.init("right", &.{ 1, 2 });
    left.arm(2);
    try std.testing.expectError(error.ReadFailed, readReaderAlloc(std.testing.allocator, &left.interface, 6));
    try std.testing.expectEqual(@as(usize, 2), left.bytes_read);
    try std.testing.expectEqual(@as(usize, 2), left.read_calls);
    try std.testing.expectEqual(error.InputOutput, left.last_cause.?);
    try std.testing.expectEqual(null, left.fail_at);
    try std.testing.expectEqual(@as(usize, 0), right.read_calls);
    const right_bytes = try readReaderAlloc(std.testing.allocator, &right.interface, 5);
    defer std.testing.allocator.free(right_bytes);
    try std.testing.expectEqualStrings("right", right_bytes);
    try std.testing.expectEqual(null, right.last_cause);
    left.arm(1);
    try std.testing.expectError(error.ReadFailed, readReaderAlloc(std.testing.allocator, &left.interface, 6));
    try std.testing.expectEqual(@as(usize, 3), left.read_calls);
    try std.testing.expectEqual(@as(usize, 2), left.bytes_read);
    left.arm(1);
    left.disarm();
    const remaining = try readReaderAlloc(std.testing.allocator, &left.interface, 6);
    defer std.testing.allocator.free(remaining);
    try std.testing.expectEqualStrings("cdef", remaining);
    try std.testing.expectEqual(@as(usize, 5), left.read_calls);
    try std.testing.expectEqual(error.InputOutput, left.last_cause.?);
}

test "fault io failure deferred flush independent counters disarm and rearm" {
    var sink: [8]u8 = undefined;
    var buffer: [3]u8 = undefined;
    var left = ScriptedWriter.init(&sink, &buffer, &.{1});
    var right_sink: [5]u8 = undefined;
    var right = ScriptedWriter.init(&right_sink, &.{}, &.{2});
    left.arm(.flush, 1, error.BrokenPipe);
    try left.interface.writeAll("abc");
    try std.testing.expectEqual(@as(usize, 0), left.write_calls);
    try std.testing.expectEqual(@as(usize, 0), left.bytes_written);
    try std.testing.expectError(error.WriteFailed, writeWriterAll(&left.interface, ""));
    try std.testing.expectEqualStrings("abc", left.interface.buffered());
    try std.testing.expectEqual(@as(usize, 0), left.bytes_written);
    try std.testing.expectEqual(@as(usize, 1), left.flush_calls);
    try std.testing.expectEqual(error.BrokenPipe, left.last_cause.?);
    try std.testing.expectEqual(@as(usize, 0), right.flush_calls);
    try writeWriterAll(&right.interface, "right");
    try std.testing.expectEqualStrings("right", right_sink[0..right.bytes_written]);
    try std.testing.expectEqual(null, right.last_cause);
    left.arm(.flush, 2, error.NoSpaceLeft);
    try writeWriterAll(&left.interface, "d");
    try std.testing.expectEqualStrings("abcd", sink[0..left.bytes_written]);
    try std.testing.expectEqual(@as(usize, 2), left.flush_calls);
    try std.testing.expect(left.write_calls > 1);
    try std.testing.expectError(error.WriteFailed, writeWriterAll(&left.interface, "e"));
    try std.testing.expectEqualStrings("abcd", sink[0..left.bytes_written]);
    try std.testing.expectEqualStrings("e", left.interface.buffered());
    try std.testing.expectEqual(error.NoSpaceLeft, left.last_cause.?);
    left.arm(.flush, 1, error.BrokenPipe);
    left.disarm();
    try writeWriterAll(&left.interface, "");
    try std.testing.expectEqualStrings("abcde", sink[0..left.bytes_written]);
    try std.testing.expectEqual(@as(usize, 4), left.flush_calls);
    try std.testing.expectEqual(error.NoSpaceLeft, left.last_cause.?);
}

test "fault io failure full caller owned sink is bounded" {
    var sink: [2]u8 = undefined;
    var writer = ScriptedWriter.init(&sink, &.{}, &.{});
    try std.testing.expectError(error.WriteFailed, writeWriterAll(&writer.interface, "abc"));
    try std.testing.expectEqualStrings("ab", &sink);
    try std.testing.expectEqual(@as(usize, 2), writer.bytes_written);
    try std.testing.expectEqual(error.NoSpaceLeft, writer.last_cause.?);
}

test "fault boundary happy default file system writes renames and deletes real files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const source = try std.fs.path.join(std.testing.allocator, &.{ root, "source" });
    defer std.testing.allocator.free(source);
    const destination = try std.fs.path.join(std.testing.allocator, &.{ root, "destination" });
    defer std.testing.allocator.free(destination);

    try writeFile(source, "old");
    try writeFile(source, "new");
    try renameFile(source, destination);
    const bytes = try readFileAlloc(std.testing.allocator, destination, 64);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("new", bytes);
    deleteFile(destination);
    try std.testing.expect(!exists(destination));
}

test "fault boundary failure default errors propagate while missing delete is swallowed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const source = try std.fs.path.join(std.testing.allocator, &.{ root, "source" });
    defer std.testing.allocator.free(source);
    const missing = try std.fs.path.join(std.testing.allocator, &.{ root, "missing" });
    defer std.testing.allocator.free(missing);
    const missing_parent_destination = try std.fs.path.join(std.testing.allocator, &.{ root, "missing-parent", "destination" });
    defer std.testing.allocator.free(missing_parent_destination);

    try std.testing.expectError(error.IsDir, writeFile(root, "cannot write a directory"));
    try writeFile(source, "source bytes");
    try std.testing.expectError(error.FileNotFound, renameFile(source, missing_parent_destination));
    const bytes = try readFileAlloc(std.testing.allocator, source, 64);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("source bytes", bytes);
    deleteFile(missing);
    try std.testing.expect(!exists(missing));
}

pub fn getenvOwned(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var name_buf = try allocator.allocSentinel(u8, name.len, 0);
    defer allocator.free(name_buf);
    @memcpy(name_buf[0..name.len], name);
    const ptr = c.getenv(name_buf.ptr) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

pub fn millis() u64 {
    return @as(u64, @intCast(c.time(null))) * 1000;
}

pub fn hexSha256(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    var out = try allocator.alloc(u8, 64);
    const alphabet = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = alphabet[b >> 4];
        out[i * 2 + 1] = alphabet[b & 0x0f];
    }
    return out;
}
