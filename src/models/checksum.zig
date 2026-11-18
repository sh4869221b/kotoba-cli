const std = @import("std");
const errors = @import("../errors.zig");
const sys = @import("../sys.zig");
const types = @import("types.zig");

fn openModel(path: []const u8) !std.Io.File {
    if (path.len == 0) return errors.Error.ModelMissing;
    const stat = sys.cwd().statFile(sys.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return errors.Error.ModelMissing,
        else => return err,
    };
    if (stat.kind != .file) return errors.Error.ModelLoadFailed;
    return sys.cwd().openFile(sys.io(), path, .{ .allow_directory = false }) catch |err| switch (err) {
        error.FileNotFound => return errors.Error.ModelMissing,
        else => return err,
    };
}

pub fn verifyModel(m: types.Model) !void {
    if (m.checksum.len > 0) return verifySha256(m.path, m.checksum);
    const file = try openModel(m.path);
    file.close(sys.io());
}

pub fn verifySha256(path: []const u8, expected_hex: []const u8) !void {
    const actual = std.fmt.bytesToHex(try contentSha256(path), .lower);
    if (!std.ascii.eqlIgnoreCase(expected_hex, &actual)) return errors.Error.ChecksumFailed;
}

pub fn contentSha256(path: []const u8) ![32]u8 {
    var file = try openModel(path);
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
    return hasher.finalResult();
}

test "verifyModel requires existing path" {
    try std.testing.expectError(errors.Error.ModelMissing, verifyModel(.{
        .id = "missing",
        .path = "",
    }));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const missing_path = try std.fs.path.join(std.testing.allocator, &.{ root, "missing-model.gguf" });
    defer std.testing.allocator.free(missing_path);
    try std.testing.expectError(errors.Error.ModelMissing, verifyModel(.{
        .id = "missing",
        .path = missing_path,
    }));
}
