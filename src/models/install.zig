const std = @import("std");
const errors = @import("../errors.zig");
const net = @import("../net.zig");
const sys = @import("../sys.zig");
const checksum = @import("checksum.zig");
const types = @import("types.zig");

const Downloader = *const fn (std.mem.Allocator, []const u8, []const u8) anyerror!void;

pub fn acquire(allocator: std.mem.Allocator, m: types.Model, dest_path: []const u8, skip_download: bool) !void {
    return acquireWithDownloader(allocator, m, dest_path, skip_download, downloadHttps);
}

pub fn acquireWithDownloader(
    allocator: std.mem.Allocator,
    m: types.Model,
    dest_path: []const u8,
    skip_download: bool,
    downloader: Downloader,
) !void {
    if (skip_download or m.download_url.len == 0) return;
    if (dest_path.len == 0) return errors.Error.InvalidArguments;
    const temp_path = try tempPath(allocator, dest_path);
    defer allocator.free(temp_path);
    errdefer sys.deleteFile(temp_path);
    if (std.fs.path.dirname(temp_path)) |dir| try sys.makePath(dir);
    if (std.mem.startsWith(u8, m.download_url, "http://")) return errors.Error.InvalidArguments;
    if (std.mem.startsWith(u8, m.download_url, "https://")) {
        try downloader(allocator, m.download_url, temp_path);
    } else if (std.mem.startsWith(u8, m.download_url, "file://")) {
        try copyFile(m.download_url["file://".len..], temp_path);
    } else {
        try copyFile(m.download_url, temp_path);
    }
    if (m.checksum.len > 0) try checksum.verifySha256(allocator, temp_path, m.checksum);
    try sys.renameFile(temp_path, dest_path);
}

pub fn installLocalFile(allocator: std.mem.Allocator, src: []const u8, dest: []const u8, expected_checksum: []const u8) !void {
    const temp_path = try tempPath(allocator, dest);
    defer allocator.free(temp_path);
    errdefer sys.deleteFile(temp_path);
    try sys.copyFile(src, temp_path);
    if (expected_checksum.len > 0) try checksum.verifySha256(allocator, temp_path, expected_checksum);
    try sys.renameFile(temp_path, dest);
}

fn copyFile(src: []const u8, dest: []const u8) !void {
    try sys.copyFile(src, dest);
}

pub fn installedPath(allocator: std.mem.Allocator, models_dir: []const u8, id: []const u8) ![]const u8 {
    const filename = try std.fmt.allocPrint(allocator, "{s}.gguf", .{id});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ models_dir, filename });
}

fn tempPath(allocator: std.mem.Allocator, dest_path: []const u8) ![]const u8 {
    var bytes: [8]u8 = undefined;
    const nonce = if (std.Io.randomSecure(sys.io(), &bytes)) |_| std.mem.readInt(u64, &bytes, .little) else |_| sys.millis();
    return std.fmt.allocPrint(allocator, "{s}.tmp-{x}", .{ dest_path, nonce });
}

fn downloadHttps(allocator: std.mem.Allocator, url: []const u8, dest: []const u8) !void {
    net.downloadToFile(allocator, url, dest) catch return errors.Error.ModelRegistryInvalid;
}

test "acquire local file verifies checksum" {
    const src = "/tmp/kotoba-model-acquire-src.gguf";
    const dest = "/tmp/kotoba-model-acquire-dest.gguf";
    sys.deleteFile(src);
    sys.deleteFile(dest);
    try sys.writeFile(src, "model bytes");
    const data = try sys.readFileAlloc(std.testing.allocator, src, 1024);
    defer std.testing.allocator.free(data);
    const expected_checksum = try sys.hexSha256(std.testing.allocator, data);
    defer std.testing.allocator.free(expected_checksum);
    const download_url = try std.fmt.allocPrint(std.testing.allocator, "file://{s}", .{src});
    defer std.testing.allocator.free(download_url);
    try acquire(std.testing.allocator, .{ .id = "local", .download_url = download_url, .checksum = expected_checksum }, dest, false);
    const copied = try sys.readFileAlloc(std.testing.allocator, dest, 1024);
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("model bytes", copied);
}

test "acquire local file rejects checksum mismatch" {
    const src = "/tmp/kotoba-model-acquire-bad-src.gguf";
    const dest = "/tmp/kotoba-model-acquire-bad-dest.gguf";
    sys.deleteFile(src);
    sys.deleteFile(dest);
    try sys.writeFile(src, "model bytes");
    const download_url = try std.fmt.allocPrint(std.testing.allocator, "file://{s}", .{src});
    defer std.testing.allocator.free(download_url);
    try std.testing.expectError(errors.Error.ChecksumFailed, acquire(std.testing.allocator, .{ .id = "local", .download_url = download_url, .checksum = "deadbeef" }, dest, false));
}

fn fakeDownloader(_: std.mem.Allocator, _: []const u8, dest: []const u8) !void {
    try sys.writeFile(dest, "remote bytes");
}

fn failingDownloader(_: std.mem.Allocator, _: []const u8, _: []const u8) !void {
    return errors.Error.ModelRegistryInvalid;
}

test "acquire https streams through downloader and verifies checksum" {
    const dest = "/tmp/kotoba-model-acquire-https-dest.gguf";
    sys.deleteFile(dest);
    const expected_checksum = try sys.hexSha256(std.testing.allocator, "remote bytes");
    defer std.testing.allocator.free(expected_checksum);
    try acquireWithDownloader(std.testing.allocator, .{
        .id = "remote",
        .download_url = "https://example.invalid/model.gguf",
        .checksum = expected_checksum,
    }, dest, false, fakeDownloader);
    const copied = try sys.readFileAlloc(std.testing.allocator, dest, 1024);
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("remote bytes", copied);
}

test "acquire https failure does not leave final file" {
    const dest = "/tmp/kotoba-model-acquire-https-fail.gguf";
    sys.deleteFile(dest);
    try std.testing.expectError(errors.Error.ModelRegistryInvalid, acquireWithDownloader(std.testing.allocator, .{
        .id = "remote",
        .download_url = "https://example.invalid/model.gguf",
    }, dest, false, failingDownloader));
    try std.testing.expect(!sys.exists(dest));
}

test "acquire skip download does not require destination" {
    try acquire(std.testing.allocator, .{ .id = "local", .download_url = "/tmp/does-not-matter" }, "", true);
}
