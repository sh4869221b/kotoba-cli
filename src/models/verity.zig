const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const sys = @import("../sys.zig");

pub const mutable_snapshot_limit = 128 * 1024 * 1024;
const sha256_algorithm = 1;

const Enable = extern struct {
    version: u32 = 1,
    hash_algorithm: u32 = sha256_algorithm,
    block_size: u32 = 4096,
    salt_size: u32 = 0,
    salt_ptr: u64 = 0,
    sig_size: u32 = 0,
    reserved1: u32 = 0,
    sig_ptr: u64 = 0,
    reserved2: [11]u64 = @splat(0),
};

/// Try only on a newly acquired managed copy. Kernel/filesystem support is
/// optional; cache lookup independently measures the descriptor it opens.
pub fn prepareLargeCopy(path: []const u8) void {
    if (builtin.os.tag != .linux) return;
    const io = sys.io();
    const file = sys.cwd().openFile(io, path, .{ .allow_directory = false, .follow_symlinks = false }) catch return;
    defer file.close(io);
    const stat = file.stat(io) catch return;
    if (stat.kind != .file or stat.size <= mutable_snapshot_limit) return;
    const args: Enable = .{};
    _ = linux.ioctl(file.handle, linux.IOCTL.IOW('f', 133, Enable), @intFromPtr(&args));
}

pub fn measure(file: std.Io.File) ?[32]u8 {
    // FS_IOC_MEASURE_VERITY encodes the fixed header size only.
    const Header = extern struct { algorithm: u16 = 0, size: u16 = 64 };
    const Digest = extern struct { header: Header = .{}, bytes: [64]u8 = undefined };
    var data: Digest = .{};
    if (linux.ioctl(file.handle, linux.IOCTL.IOWR('f', 134, Header), @intFromPtr(&data)) != 0) return null;
    if (data.header.algorithm != sha256_algorithm or data.header.size != 32) return null;
    return data.bytes[0..32].*;
}
