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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const src = try std.fs.path.join(std.testing.allocator, &.{ root, "source.gguf" });
    defer std.testing.allocator.free(src);
    const dest = try std.fs.path.join(std.testing.allocator, &.{ root, "destination.gguf" });
    defer std.testing.allocator.free(dest);
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const src = try std.fs.path.join(std.testing.allocator, &.{ root, "bad-source.gguf" });
    defer std.testing.allocator.free(src);
    const dest = try std.fs.path.join(std.testing.allocator, &.{ root, "bad-destination.gguf" });
    defer std.testing.allocator.free(dest);
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const dest = try std.fs.path.join(std.testing.allocator, &.{ root, "https-destination.gguf" });
    defer std.testing.allocator.free(dest);
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const dest = try std.fs.path.join(std.testing.allocator, &.{ root, "https-failure.gguf" });
    defer std.testing.allocator.free(dest);
    try std.testing.expectError(errors.Error.ModelRegistryInvalid, acquireWithDownloader(std.testing.allocator, .{
        .id = "remote",
        .download_url = "https://example.invalid/model.gguf",
    }, dest, false, failingDownloader));
    try std.testing.expect(!sys.exists(dest));
}

test "acquire skip download does not require destination" {
    try acquire(std.testing.allocator, .{ .id = "local", .download_url = "does-not-matter" }, "", true);
}

fn partialDownloader(_: std.mem.Allocator, _: []const u8, dest: []const u8) !void {
    try sys.writeFile(dest, "partial");
    return errors.Error.ModelRegistryInvalid;
}

fn expectNoTempEntries(path: []const u8) !void {
    var dir = try sys.cwd().openDir(sys.io(), path, .{ .iterate = true });
    defer dir.close(sys.io());
    var iterator = dir.iterate();
    while (try iterator.next(sys.io())) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.name, ".tmp-") == null);
    }
}

test "fault install happy matching checksum installs exact remote bytes in independent directories" {
    var first_tmp = std.testing.tmpDir(.{});
    defer first_tmp.cleanup();
    var second_tmp = std.testing.tmpDir(.{});
    defer second_tmp.cleanup();
    const first_root = try first_tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(first_root);
    const second_root = try second_tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(second_root);
    const first_dest = try std.fs.path.join(std.testing.allocator, &.{ first_root, "first.gguf" });
    defer std.testing.allocator.free(first_dest);
    const second_dest = try std.fs.path.join(std.testing.allocator, &.{ second_root, "second.gguf" });
    defer std.testing.allocator.free(second_dest);
    const expected_checksum = try sys.hexSha256(std.testing.allocator, "remote bytes");
    defer std.testing.allocator.free(expected_checksum);
    const model: types.Model = .{
        .id = "remote",
        .download_url = "https://example.invalid/model.gguf",
        .checksum = expected_checksum,
    };

    try acquireWithDownloader(std.testing.allocator, model, first_dest, false, fakeDownloader);
    try acquireWithDownloader(std.testing.allocator, model, second_dest, false, fakeDownloader);

    const first_data = try sys.readFileAlloc(std.testing.allocator, first_dest, 1024);
    defer std.testing.allocator.free(first_data);
    const second_data = try sys.readFileAlloc(std.testing.allocator, second_dest, 1024);
    defer std.testing.allocator.free(second_data);
    try std.testing.expectEqualStrings("remote bytes", first_data);
    try std.testing.expectEqualStrings("remote bytes", second_data);
    try expectNoTempEntries(first_root);
    try expectNoTempEntries(second_root);
}

test "fault install failure mismatch and partial downloader preserve destinations and clean temporary files" {
    var mismatch_tmp = std.testing.tmpDir(.{});
    defer mismatch_tmp.cleanup();
    var partial_tmp = std.testing.tmpDir(.{});
    defer partial_tmp.cleanup();
    const mismatch_root = try mismatch_tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(mismatch_root);
    const partial_root = try partial_tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(partial_root);
    const mismatch_dest = try std.fs.path.join(std.testing.allocator, &.{ mismatch_root, "existing.gguf" });
    defer std.testing.allocator.free(mismatch_dest);
    const partial_existing_dest = try std.fs.path.join(std.testing.allocator, &.{ partial_root, "partial-existing.gguf" });
    defer std.testing.allocator.free(partial_existing_dest);
    const partial_absent_dest = try std.fs.path.join(std.testing.allocator, &.{ partial_root, "partial-absent.gguf" });
    defer std.testing.allocator.free(partial_absent_dest);
    try sys.writeFile(mismatch_dest, "old model");
    try sys.writeFile(partial_existing_dest, "old model");
    const wrong_checksum = try sys.hexSha256(std.testing.allocator, "different bytes");
    defer std.testing.allocator.free(wrong_checksum);

    try std.testing.expectError(errors.Error.ChecksumFailed, acquireWithDownloader(std.testing.allocator, .{
        .id = "remote",
        .download_url = "https://example.invalid/model.gguf",
        .checksum = wrong_checksum,
    }, mismatch_dest, false, fakeDownloader));
    const preserved = try sys.readFileAlloc(std.testing.allocator, mismatch_dest, 1024);
    defer std.testing.allocator.free(preserved);
    try std.testing.expectEqualStrings("old model", preserved);
    try expectNoTempEntries(mismatch_root);

    try std.testing.expectError(errors.Error.ModelRegistryInvalid, acquireWithDownloader(std.testing.allocator, .{
        .id = "remote",
        .download_url = "https://example.invalid/model.gguf",
    }, partial_existing_dest, false, partialDownloader));
    const partial_preserved = try sys.readFileAlloc(std.testing.allocator, partial_existing_dest, 1024);
    defer std.testing.allocator.free(partial_preserved);
    try std.testing.expectEqualStrings("old model", partial_preserved);

    try std.testing.expectError(errors.Error.ModelRegistryInvalid, acquireWithDownloader(std.testing.allocator, .{
        .id = "remote",
        .download_url = "https://example.invalid/model.gguf",
    }, partial_absent_dest, false, partialDownloader));
    try std.testing.expect(!sys.exists(partial_absent_dest));
    try expectNoTempEntries(partial_root);
}
