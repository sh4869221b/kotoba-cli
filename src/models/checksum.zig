const std = @import("std");
const errors = @import("../errors.zig");
const sys = @import("../sys.zig");
const types = @import("types.zig");

pub fn verifyModel(allocator: std.mem.Allocator, m: types.Model) !void {
    if (m.path.len == 0) return errors.Error.ModelMissing;
    if (!sys.exists(m.path)) return errors.Error.ModelMissing;
    if (m.checksum.len > 0) try verifySha256(allocator, m.path, m.checksum);
}

pub fn verifySha256(allocator: std.mem.Allocator, path: []const u8, expected_hex: []const u8) !void {
    var file = try sys.cwd().openFile(sys.io(), path, .{});
    defer file.close(sys.io());
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = file.readStreaming(sys.io(), &.{buf[0..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const actual = try hexDigest(allocator, digest);
    defer allocator.free(actual);
    if (!std.ascii.eqlIgnoreCase(expected_hex, actual)) return errors.Error.ChecksumFailed;
}

fn hexDigest(allocator: std.mem.Allocator, digest: [32]u8) ![]const u8 {
    var out = try allocator.alloc(u8, 64);
    const alphabet = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = alphabet[b >> 4];
        out[i * 2 + 1] = alphabet[b & 0x0f];
    }
    return out;
}

test "verifyModel requires existing path" {
    try std.testing.expectError(errors.Error.ModelMissing, verifyModel(std.testing.allocator, .{
        .id = "missing",
        .path = "",
    }));
    try std.testing.expectError(errors.Error.ModelMissing, verifyModel(std.testing.allocator, .{
        .id = "missing",
        .path = "/tmp/kotoba-missing-model-file.gguf",
    }));
}
