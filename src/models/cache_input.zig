const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const checksum = @import("checksum.zig");
const errors = @import("../errors.zig");
const sys = @import("../sys.zig");
const validation = @import("validation.zig");
const llama = @import("../llama.zig");

const snapshot_limit = 128 * 1024 * 1024;

/// The file stays open until the inference session has been destroyed.
pub const CacheInput = struct {
    file: std.Io.File,
    identity: Identity,

    pub const Identity = struct {
        kind: enum(u8) { sha256 = 0, verity_sha256 = 1 },
        digest: [32]u8,
    };

    /// Null means translation may proceed with the original path and memory disabled.
    pub fn open(model_path: []const u8, diagnostics_enabled: bool) !?CacheInput {
        if (builtin.os.tag != .linux) return null;
        if (validation.isSplitGgufFilename(model_path)) return errors.Error.SplitModelUnsupported;
        const io = sys.io();

        // Pin the resolved source before opening for reads. O_PATH also avoids
        // blocking if a concurrent replacement turns the path into a FIFO.
        const handle = sys.cwd().openFile(io, model_path, .{ .path_only = true }) catch |err| switch (err) {
            error.FileNotFound => return errors.Error.ModelMissing,
            else => return err,
        };
        defer handle.close(io);
        if ((try handle.stat(io)).kind != .file) return errors.Error.ModelLoadFailed;
        var handle_path: [64]u8 = undefined;
        const source = sys.cwd().openFile(io, fdPath(handle, &handle_path), .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => return err,
        };
        var source_transferred = false;
        defer if (!source_transferred) source.close(io);

        if (verityDigest(source)) |digest| {
            try requireSingleFile(source, diagnostics_enabled);
            source_transferred = true;
            return .{ .file = source, .identity = .{ .kind = .verity_sha256, .digest = digest } };
        }
        return fromMutableFile(source, diagnostics_enabled);
    }

    fn fromMutableFile(source: std.Io.File, diagnostics_enabled: bool) !?CacheInput {
        const io = sys.io();
        const before = try source.stat(io);
        if (before.size > snapshot_limit) return null;
        const fd = linux.memfd_create("kotoba-model", linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING);
        if (linux.errno(fd) != .SUCCESS) return null;
        const snapshot: std.Io.File = .{ .handle = @intCast(fd), .flags = .{ .nonblocking = false } };
        var transferred = false;
        defer if (!transferred) snapshot.close(io);

        var buffer: [64 * 1024]u8 = undefined;
        var offset: u64 = 0;
        while (offset < before.size) {
            const chunk = buffer[0..@min(buffer.len, before.size - offset)];
            const size = source.readPositionalAll(io, chunk, offset) catch return null;
            if (size != chunk.len) return null;
            snapshot.writePositionalAll(io, chunk, offset) catch return null;
            offset += size;
        }
        const after = try source.stat(io);
        if (after.size != before.size or after.mtime.nanoseconds != before.mtime.nanoseconds or
            after.ctime.nanoseconds != before.ctime.nanoseconds) return null;

        const seals = linux.F.SEAL_WRITE | linux.F.SEAL_GROW | linux.F.SEAL_SHRINK | linux.F.SEAL_SEAL;
        if (linux.errno(linux.fcntl(snapshot.handle, linux.F.ADD_SEALS, seals)) != .SUCCESS) return null;

        // Both the digest and llama.cpp's future open refer to these sealed bytes.
        try requireSingleFile(snapshot, diagnostics_enabled);
        const digest = try checksum.hashFileSha256(snapshot);
        transferred = true;
        return .{ .file = snapshot, .identity = .{ .kind = .sha256, .digest = digest } };
    }

    pub fn path(self: CacheInput, buffer: []u8) [:0]const u8 {
        return fdPath(self.file, buffer);
    }

    pub fn close(self: CacheInput) void {
        self.file.close(sys.io());
    }
};

fn fdPath(file: std.Io.File, buffer: []u8) [:0]const u8 {
    return std.fmt.bufPrintZ(buffer, "/proc/self/fd/{d}", .{file.handle}) catch unreachable;
}

fn verityDigest(file: std.Io.File) ?[32]u8 {
    // linux/fsverity.h's FS_IOC_MEASURE_VERITY encodes only the fixed header size.
    const Header = extern struct { algorithm: u16 = 0, size: u16 = 64 };
    const Digest = extern struct { header: Header = .{}, bytes: [64]u8 = undefined };
    const request = linux.IOCTL.IOWR('f', 134, Header);
    var data: Digest = .{};
    if (linux.ioctl(file.handle, request, @intFromPtr(&data)) != 0) return null;
    if (data.header.algorithm != 1 or data.header.size != 32) return null; // FS_VERITY_HASH_ALG_SHA256
    return data.bytes[0..32].*;
}

fn requireSingleFile(file: std.Io.File, diagnostics_enabled: bool) !void {
    if (@import("build_options").test_backend) {
        var magic: [4]u8 = undefined;
        if (try file.readPositionalAll(sys.io(), &magic, 0) != magic.len or
            !std.mem.eql(u8, &magic, "GGUF")) return;
    }
    var path_buffer: [64]u8 = undefined;
    try llama.requireSingleFile(fdPath(file, &path_buffer), diagnostics_enabled);
}

const empty_gguf_header = "GGUF\x03\x00\x00\x00" ++ "\x00" ** 16;

test "a cache input keeps exactly the sealed bytes across symlink and inode updates" {
    if (builtin.os.tag != .linux) return;
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = empty_gguf_header ++ "\x00" ** 8 ++ "model A";
    const b = empty_gguf_header ++ "\x00" ** 8 ++ "model B";
    try tmp.dir.writeFile(io, .{ .sub_path = "a.gguf", .data = a });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.gguf", .data = b });
    try tmp.dir.symLink(io, "a.gguf", "selected.gguf", .{});
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const selected = try std.fs.path.join(allocator, &.{ root, "selected.gguf" });
    defer allocator.free(selected);

    const snapshot = (try CacheInput.open(selected, false)) orelse return error.TestUnexpectedResult;
    defer snapshot.close();
    try std.testing.expectEqual(CacheInput.Identity{ .kind = .sha256, .digest = digestForTest(a) }, snapshot.identity);

    // Simulate both operations another process can perform during inference.
    try tmp.dir.symLink(io, "b.gguf", "next.gguf", .{});
    try tmp.dir.rename("next.gguf", tmp.dir, "selected.gguf", io);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.gguf", .data = b });

    var buffer: [64]u8 = undefined;
    const reopen = try sys.cwd().openFile(io, snapshot.path(&buffer), .{});
    defer reopen.close(io);
    var bytes: [a.len]u8 = undefined;
    try std.testing.expectEqual(bytes.len, try reopen.readPositionalAll(io, &bytes, 0));
    try std.testing.expectEqualStrings(a, &bytes);
    const seals: usize = linux.F.SEAL_WRITE | linux.F.SEAL_GROW | linux.F.SEAL_SHRINK;
    try std.testing.expectEqual(seals, linux.fcntl(snapshot.file.handle, linux.F.GET_SEALS, 0) & seals);

    const updated = (try CacheInput.open(selected, false)) orelse return error.TestUnexpectedResult;
    defer updated.close();
    try std.testing.expectEqual(CacheInput.Identity{ .kind = .sha256, .digest = digestForTest(b) }, updated.identity);
}

test "split metadata rejects even under an ordinary .gguf name" {
    if (builtin.os.tag != .linux) return;
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const split = "GGUF\x03\x00\x00\x00" ++ "\x00" ** 8 ++ "\x01" ++ "\x00" ** 7 ++
        "\x0b" ++ "\x00" ** 7 ++ "split.count" ++ "\x02\x00\x00\x00\x02\x00" ++ "\x00" ** 15;
    try tmp.dir.writeFile(io, .{ .sub_path = "renamed.gguf", .data = split });
    const path = try tmp.dir.realPathFileAlloc(io, "renamed.gguf", allocator);
    defer allocator.free(path);
    try std.testing.expectError(error.SplitModelUnsupported, CacheInput.open(path, false));
    try std.testing.expectError(error.SplitModelUnsupported, CacheInput.open("model-00001-of-00002.gguf", false));
}

fn digestForTest(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}
