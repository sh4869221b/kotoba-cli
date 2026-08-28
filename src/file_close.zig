const std = @import("std");

const CloseCall = *const fn (context: ?*anyopaque, fd: std.c.fd_t) std.c.E;

/// Closes an owned file descriptor exactly once and reports the native close error.
///
/// The optional is cleared before the native call because Linux may release the
/// descriptor even when `close` reports an error. Callers must not retry or use
/// the consumed descriptor after this function returns.
pub fn closeOwned(file: *?std.Io.File) !void {
    return closeOwnedWith(file, null, nativeClose);
}

fn closeOwnedWith(file: *?std.Io.File, context: ?*anyopaque, close_call: CloseCall) !void {
    const owned = file.* orelse return;
    file.* = null;
    try mapErrno(close_call(context, owned.handle));
}

fn nativeClose(_: ?*anyopaque, fd: std.c.fd_t) std.c.E {
    return std.c.errno(std.c.close(fd));
}

fn mapErrno(errno: std.c.E) !void {
    switch (errno) {
        .SUCCESS => {},
        .IO, .INTR => return error.InputOutput,
        .NOSPC => return error.NoSpaceLeft,
        .DQUOT => return error.DiskQuota,
        .BADF => return error.InvalidFileDescriptor,
        else => return error.Unexpected,
    }
}

fn expectClosed(fd: std.c.fd_t) !void {
    try std.testing.expectEqual(std.c.E.BADF, std.c.errno(std.c.close(fd)));
}

const LateClose = struct {
    calls: usize = 0,
    injected: std.c.E,

    fn call(context: ?*anyopaque, fd: std.c.fd_t) std.c.E {
        const self: *LateClose = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        const native_errno = std.c.errno(std.c.close(fd));
        if (native_errno != .SUCCESS) return native_errno;
        return self.injected;
    }
};

test "checked close happy consumes a real owned descriptor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var owned: ?std.Io.File = try tmp.dir.createFile(std.testing.io, "owned", .{ .read = true });
    const fd = owned.?.handle;
    try closeOwned(&owned);
    try std.testing.expect(owned == null);
    try expectClosed(fd);

    try closeOwned(&owned);
    try std.testing.expect(owned == null);
}

test "checked close failure maps late native errors after releasing the descriptor" {
    const Case = struct { injected: std.c.E, expected: anyerror };
    const cases = [_]Case{
        .{ .injected = .IO, .expected = error.InputOutput },
        .{ .injected = .INTR, .expected = error.InputOutput },
        .{ .injected = .NOSPC, .expected = error.NoSpaceLeft },
        .{ .injected = .DQUOT, .expected = error.DiskQuota },
        .{ .injected = .BADF, .expected = error.InvalidFileDescriptor },
        .{ .injected = .ACCES, .expected = error.Unexpected },
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for (cases, 0..) |case, index| {
        var name: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, "owned-{d}", .{index});
        var owned: ?std.Io.File = try tmp.dir.createFile(std.testing.io, path, .{ .read = true });
        const fd = owned.?.handle;
        var late_close = LateClose{ .injected = case.injected };

        try std.testing.expectError(case.expected, closeOwnedWith(&owned, &late_close, LateClose.call));
        try std.testing.expect(owned == null);
        try std.testing.expectEqual(@as(usize, 1), late_close.calls);
        try expectClosed(fd);

        try closeOwned(&owned);
        try std.testing.expectEqual(@as(usize, 1), late_close.calls);
    }
}

test "checked close reuse leaves a reused descriptor open after EINTR" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var owned: ?std.Io.File = try tmp.dir.createFile(std.testing.io, "owned", .{ .read = true });
    const consumed_fd = owned.?.handle;
    var late_close = LateClose{ .injected = .INTR };
    try std.testing.expectError(error.InputOutput, closeOwnedWith(&owned, &late_close, LateClose.call));
    try std.testing.expect(owned == null);
    try std.testing.expectEqual(@as(usize, 1), late_close.calls);

    var blocker: ?std.Io.File = try tmp.dir.createFile(std.testing.io, "blocker", .{ .read = true });
    defer if (blocker) |file| file.close(std.testing.io);
    try std.testing.expectEqual(consumed_fd, blocker.?.handle);

    const sentinel = try tmp.dir.createFile(std.testing.io, "sentinel", .{ .read = true });
    const sentinel_fd = sentinel.handle;
    var sentinel_open = true;
    defer {
        if (sentinel_open) _ = std.c.close(sentinel_fd);
    }
    try std.testing.expect(sentinel_fd != consumed_fd);

    // dup2 closes blocker at consumed_fd. Relinquish its high-level owner first
    // so only the native dup2 call consumes that descriptor.
    blocker = null;
    const duplicated_fd = std.c.dup2(sentinel_fd, consumed_fd);
    if (duplicated_fd == -1) {
        _ = std.c.close(consumed_fd);
        return error.TestUnexpectedResult;
    }
    var reused_fd_open = true;
    defer {
        if (reused_fd_open) _ = std.c.close(consumed_fd);
    }
    try std.testing.expectEqual(consumed_fd, duplicated_fd);

    try closeOwned(&owned);
    try std.testing.expectEqual(@as(usize, 1), late_close.calls);
    const sentinel_bytes = "still open";
    try std.testing.expectEqual(@as(isize, sentinel_bytes.len), std.c.write(consumed_fd, sentinel_bytes.ptr, sentinel_bytes.len));
    try std.testing.expectEqual(@as(std.c.off_t, 0), std.c.lseek(consumed_fd, 0, std.c.SEEK.SET));
    var observed: [sentinel_bytes.len]u8 = undefined;
    try std.testing.expectEqual(@as(isize, observed.len), std.c.read(consumed_fd, &observed, observed.len));
    try std.testing.expectEqualStrings(sentinel_bytes, &observed);
    reused_fd_open = false;
    try std.testing.expectEqual(std.c.E.SUCCESS, std.c.errno(std.c.close(consumed_fd)));
    sentinel_open = false;
    try std.testing.expectEqual(std.c.E.SUCCESS, std.c.errno(std.c.close(sentinel_fd)));
}
