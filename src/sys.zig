const std = @import("std");
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
    var file = try cwd().createFile(io(), path, .{ .truncate = true });
    defer file.close(io());
    try file.writeStreamingAll(io(), data);
}

pub fn copyFile(src: []const u8, dest: []const u8) !void {
    try std.Io.Dir.copyFile(cwd(), src, cwd(), dest, io(), .{ .make_path = true, .replace = true });
}

pub fn renameFile(src: []const u8, dest: []const u8) !void {
    try cwd().rename(src, cwd(), dest, io());
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
    cwd().deleteFile(io(), path) catch {};
}

pub fn stdoutWrite(bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io(), bytes) catch {};
}

pub fn stderrWrite(bytes: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io(), bytes) catch {};
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
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try std.posix.read(std.posix.STDIN_FILENO, &buf);
        if (n == 0) break;
        if (out.items.len + n > limit) return error.StreamTooLong;
        try out.appendSlice(buf[0..n]);
    }
    return out.toOwnedSlice();
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
