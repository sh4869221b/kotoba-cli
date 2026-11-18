const std = @import("std");
const errors = @import("../errors.zig");
const net = @import("../net.zig");
const sys = @import("../sys.zig");
const checksum = @import("checksum.zig");
const types = @import("types.zig");
const url_policy = @import("../url.zig");
const verity = @import("verity.zig");

const Downloader = *const fn (std.mem.Allocator, []const u8, []const u8) anyerror!void;

pub const AcquireOptions = struct {
    skip_download: bool = false,
    managed: bool = false,
};

pub fn stagePull(allocator: std.mem.Allocator, m: types.Model, dest: []const u8, options: AcquireOptions) !?StagedModel {
    return stageWithDownloader(allocator, m, dest, options, downloadHttps);
}

fn acquire(allocator: std.mem.Allocator, m: types.Model, dest: []const u8, options: AcquireOptions) !void {
    try acquireWithDownloader(allocator, m, dest, options, downloadHttps);
}

fn acquireWithDownloader(
    allocator: std.mem.Allocator,
    m: types.Model,
    dest: []const u8,
    options: AcquireOptions,
    downloader: Downloader,
) !void {
    var stage = try stageWithDownloader(allocator, m, dest, options, downloader) orelse return;
    defer stage.deinit();
    try stage.publish(dest);
}

pub fn stageWithDownloader(
    allocator: std.mem.Allocator,
    m: types.Model,
    dest: []const u8,
    options: AcquireOptions,
    downloader: Downloader,
) !?StagedModel {
    if (options.skip_download or m.download_url.len == 0) return null;
    if (dest.len == 0) return errors.Error.InvalidArguments;
    const request = if (url_policy.isRemote(m.download_url)) blk: {
        const uri = try url_policy.parseRemote(m.download_url);
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return errors.Error.InvalidArguments;
        break :blk try url_policy.requestUrl(m.download_url);
    } else null;

    var stage = try StagedModel.begin(allocator, dest);
    errdefer stage.deinit();
    if (request) |remote| {
        try downloader(allocator, remote, stage.path);
    } else if (std.mem.startsWith(u8, m.download_url, "file://")) {
        try sys.copyFile(m.download_url["file://".len..], stage.path);
    } else {
        try sys.copyFile(m.download_url, stage.path);
    }
    try stage.verify(m.checksum, options.managed);
    return stage;
}

pub const StagedModel = struct {
    allocator: std.mem.Allocator,
    directory: []const u8,
    path: []const u8,
    published: bool = false,

    pub fn begin(allocator: std.mem.Allocator, dest: []const u8) !StagedModel {
        // An exclusive private directory reserves the stage for both local
        // copying and the downloader, while keeping publish on the same FS.
        const parent = std.fs.path.dirname(dest) orelse ".";
        try sys.makePath(parent);
        const io = sys.io();
        for (0..32) |_| {
            var random: [16]u8 = undefined;
            try std.Io.randomSecure(io, &random);
            const hex = std.fmt.bytesToHex(random, .lower);
            const directory = try std.fmt.allocPrint(allocator, "{s}/.kotoba-model.tmp-{s}", .{ parent, &hex });
            errdefer allocator.free(directory);
            sys.cwd().createDir(io, directory, .fromMode(0o700)) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    allocator.free(directory);
                    continue;
                },
                else => return err,
            };
            errdefer sys.cwd().deleteDir(io, directory) catch {};
            const path = try std.fs.path.join(allocator, &.{ directory, "model.gguf" });
            return .{ .allocator = allocator, .directory = directory, .path = path };
        }
        return error.PathAlreadyExists;
    }

    pub fn deinit(self: *StagedModel) void {
        if (!self.published) sys.deleteFile(self.path);
        sys.cwd().deleteDir(sys.io(), self.directory) catch {};
        self.allocator.free(self.path);
        self.allocator.free(self.directory);
        self.* = undefined;
    }

    pub fn verify(self: StagedModel, expected_checksum: []const u8, managed: bool) !void {
        if (managed) verity.prepareLargeCopy(self.path);
        try checksum.verifyModel(.{ .path = self.path, .checksum = expected_checksum });
    }

    pub fn publish(self: *StagedModel, dest: []const u8) !void {
        try sys.renameFile(self.path, dest);
        self.published = true;
    }
};

/// Pins the source inode for copying and for comparison at publish time.
pub const InstallSource = struct {
    file: std.Io.File,
    stat: std.os.linux.Statx,

    pub fn open(path: []const u8) !?InstallSource {
        const io = sys.io();
        const file = sys.cwd().openFile(io, path, .{ .path_only = true }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        errdefer file.close(io);
        const linux = std.os.linux;
        var stat = std.mem.zeroes(linux.Statx);
        const result = linux.statx(file.handle, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &stat);
        const status = linux.errno(result);
        if (status != .SUCCESS) return std.posix.unexpectedErrno(status);
        if (!stat.mask.TYPE or !stat.mask.INO or !stat.mask.SIZE or !stat.mask.MTIME or !stat.mask.CTIME)
            return error.OperationUnsupported;
        if (stat.mode & linux.S.IFMT != linux.S.IFREG) return errors.Error.ModelLoadFailed;
        return .{ .file = file, .stat = stat };
    }

    pub fn close(self: InstallSource) void {
        self.file.close(sys.io());
    }

    pub fn fdPath(self: InstallSource, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "/proc/self/fd/{d}", .{self.file.handle}) catch unreachable;
    }

    pub fn sameFile(self: InstallSource, other: InstallSource) bool {
        return self.stat.ino == other.stat.ino and
            self.stat.dev_major == other.stat.dev_major and self.stat.dev_minor == other.stat.dev_minor;
    }

    pub fn requireUnchanged(self: InstallSource, name: []const u8) !void {
        const current = (open(name) catch |err| switch (err) {
            error.ModelLoadFailed => return errors.Error.ModelSelectionChanged,
            else => return err,
        }) orelse return errors.Error.ModelSelectionChanged;
        defer current.close();
        if (!self.sameFile(current) or self.stat.size != current.stat.size or
            !std.meta.eql(self.stat.mtime, current.stat.mtime) or
            !std.meta.eql(self.stat.ctime, current.stat.ctime)) return errors.Error.ModelSelectionChanged;
    }
};

pub fn stageLocalFile(allocator: std.mem.Allocator, src: []const u8, dest: []const u8, expected_checksum: []const u8) !StagedModel {
    var stage = try StagedModel.begin(allocator, dest);
    errdefer stage.deinit();
    try sys.copyFile(src, stage.path);
    try stage.verify(expected_checksum, true);
    return stage;
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
    try acquire(std.testing.allocator, .{ .id = "local", .download_url = download_url, .checksum = expected_checksum }, dest, .{});
    const copied = try sys.readFileAlloc(std.testing.allocator, dest, 1024);
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("model bytes", copied);
}

test "a large managed import protects only the staged copy when verity is supported" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = sys.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const source = try std.fs.path.join(allocator, &.{ root, "source.gguf" });
    defer allocator.free(source);
    const probe = try std.fs.path.join(allocator, &.{ root, "probe.gguf" });
    defer allocator.free(probe);
    const dest = try std.fs.path.join(allocator, &.{ root, "installed.gguf" });
    defer allocator.free(dest);

    const header = "GGUF\x03\x00\x00\x00" ++ "\x00" ** 24;
    for ([_][]const u8{ source, probe }) |path| {
        const file = try sys.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writePositionalAll(io, header, 0);
        try file.setLength(io, verity.mutable_snapshot_limit + 1);
    }
    verity.prepareLargeCopy(probe);
    const probe_file = try sys.cwd().openFile(io, probe, .{});
    defer probe_file.close(io);
    const expected = verity.measure(probe_file);
    var stage = try stageLocalFile(allocator, source, dest, "");
    defer stage.deinit();
    try stage.publish(dest);
    const source_file = try sys.cwd().openFile(io, source, .{ .mode = .read_write });
    defer source_file.close(io);
    try std.testing.expectEqual(@as(?[32]u8, null), verity.measure(source_file));

    const cache_input = try @import("cache_input.zig").CacheInput.open(dest, false);
    if (expected) |digest| {
        const input = cache_input orelse return error.TestUnexpectedResult;
        defer input.close();
        try std.testing.expectEqual(.verity_sha256, input.identity.kind);
        try std.testing.expectEqual(digest, input.identity.digest);
    } else {
        try std.testing.expect(cache_input == null);
    }
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
    try std.testing.expectError(errors.Error.ChecksumFailed, acquire(std.testing.allocator, .{ .id = "local", .download_url = download_url, .checksum = "deadbeef" }, dest, .{}));
}

fn fakeDownloader(_: std.mem.Allocator, _: []const u8, dest: []const u8) !void {
    try sys.writeFile(dest, "remote bytes");
}

fn failingDownloader(_: std.mem.Allocator, _: []const u8, _: []const u8) !void {
    return errors.Error.ModelRegistryInvalid;
}

fn forbiddenDownloader(_: std.mem.Allocator, _: []const u8, _: []const u8) !void {
    return error.DownloaderInvoked;
}

test "secret URL acquire rejects userinfo before downloader" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const dest = try std.fs.path.join(std.testing.allocator, &.{ root, "existing.gguf" });
    defer std.testing.allocator.free(dest);
    try sys.writeFile(dest, "old model");
    try std.testing.expectError(errors.Error.InvalidArguments, acquireWithDownloader(std.testing.allocator, .{
        .id = "remote",
        .download_url = "https://KOTOBA_USER_36:KOTOBA_PASSWORD_36@models.example.invalid/model.gguf",
    }, dest, .{}, forbiddenDownloader));
    const preserved = try sys.readFileAlloc(std.testing.allocator, dest, 1024);
    defer std.testing.allocator.free(preserved);
    try std.testing.expectEqualStrings("old model", preserved);
    try expectNoTempEntries(root);
}

test "secret URL acquire preserves signed query and excludes fragment" {
    const Recorder = struct {
        var calls: usize = 0;
        fn download(_: std.mem.Allocator, request: []const u8, dest: []const u8) !void {
            calls += 1;
            try std.testing.expectEqualStrings("https://models.example.invalid/repo/model%2Bname.gguf?X-Signature=KOTOBA_QUERY_SECRET_36&x=a%2Bb&x=2", request);
            try sys.writeFile(dest, "remote bytes");
        }
    };
    Recorder.calls = 0;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const dest = try std.fs.path.join(std.testing.allocator, &.{ root, "signed.gguf" });
    defer std.testing.allocator.free(dest);
    const expected_checksum = try sys.hexSha256(std.testing.allocator, "remote bytes");
    defer std.testing.allocator.free(expected_checksum);
    try acquireWithDownloader(std.testing.allocator, .{
        .id = "signed36",
        .download_url = "https://models.example.invalid/repo/model%2Bname.gguf?X-Signature=KOTOBA_QUERY_SECRET_36&x=a%2Bb&x=2#KOTOBA_FRAGMENT_SECRET_36",
        .checksum = expected_checksum,
    }, dest, .{}, Recorder.download);
    try std.testing.expectEqual(@as(usize, 1), Recorder.calls);
    const installed = try sys.readFileAlloc(std.testing.allocator, dest, 1024);
    defer std.testing.allocator.free(installed);
    try std.testing.expectEqualStrings("remote bytes", installed);
    try checksum.verifySha256(dest, expected_checksum);
    try expectNoTempEntries(root);
}

test "secret URL invalid acquisition preserves filesystem before downloader" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const existing = try std.fs.path.join(std.testing.allocator, &.{ root, "existing.gguf" });
    defer std.testing.allocator.free(existing);
    const missing_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "not-created" });
    defer std.testing.allocator.free(missing_dir);
    const missing = try std.fs.path.join(std.testing.allocator, &.{ missing_dir, "model.gguf" });
    defer std.testing.allocator.free(missing);
    try sys.writeFile(existing, "old model");
    for ([_][]const u8{
        "https://user@models.example.invalid/a",          "https://@models.example.invalid/a",
        "https://user:password@models.example.invalid/a", "HTTPS://user@models.example.invalid/a",
        "hTtP://models.example.invalid/a",                "https:///a",
        "https:/a",                                       "https//a",
        "https://host:bad/a",                             "https://host/a%zz",
        "https://host/a#bad\n",                           "//host/a",
    }) |value| {
        for ([_][]const u8{ existing, missing }) |dest| {
            try std.testing.expectError(errors.Error.InvalidArguments, acquireWithDownloader(std.testing.allocator, .{
                .id = "remote",
                .download_url = value,
            }, dest, .{}, forbiddenDownloader));
        }
    }
    for (0..128) |c| {
        if (c > 31 and c != 127) continue;
        var value = "https://models.example.invalid/a#x".*;
        value[value.len - 1] = @intCast(c);
        try std.testing.expectError(errors.Error.InvalidArguments, acquireWithDownloader(std.testing.allocator, .{
            .id = "remote",
            .download_url = &value,
        }, missing, .{}, forbiddenDownloader));
    }
    var oversize = [_]u8{'a'} ** (url_policy.max_length + 1);
    const prefix = "https://models.example.invalid/";
    @memcpy(oversize[0..prefix.len], prefix);
    try std.testing.expectError(errors.Error.InvalidArguments, acquireWithDownloader(std.testing.allocator, .{
        .id = "remote",
        .download_url = &oversize,
    }, missing, .{}, forbiddenDownloader));
    try std.testing.expect(!sys.exists(missing_dir));
    const preserved = try sys.readFileAlloc(std.testing.allocator, existing, 1024);
    defer std.testing.allocator.free(preserved);
    try std.testing.expectEqualStrings("old model", preserved);
    try expectNoTempEntries(root);

    try acquireWithDownloader(std.testing.allocator, .{
        .id = "remote",
        .download_url = "HTTPS://models.example.invalid/a#fragment",
    }, existing, .{}, fakeDownloader);
    try acquireWithDownloader(std.testing.allocator, .{
        .id = "remote",
        .download_url = oversize[0..url_policy.max_length],
    }, existing, .{}, fakeDownloader);
    try expectNoTempEntries(root);
}

test "secret URL local paths preserve question and hash characters" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const source = try std.fs.path.join(std.testing.allocator, &.{ root, "source?#.gguf" });
    defer std.testing.allocator.free(source);
    const dest = try std.fs.path.join(std.testing.allocator, &.{ root, "destination?#.gguf" });
    defer std.testing.allocator.free(dest);
    const file_url = try std.fmt.allocPrint(std.testing.allocator, "file://{s}", .{source});
    defer std.testing.allocator.free(file_url);
    try sys.writeFile(source, "local bytes");
    const expected_checksum = try sys.hexSha256(std.testing.allocator, "local bytes");
    defer std.testing.allocator.free(expected_checksum);
    for ([_][]const u8{ source, file_url }) |value| {
        try acquireWithDownloader(std.testing.allocator, .{
            .id = "local",
            .download_url = value,
            .checksum = expected_checksum,
        }, dest, .{}, forbiddenDownloader);
        const installed = try sys.readFileAlloc(std.testing.allocator, dest, 1024);
        defer std.testing.allocator.free(installed);
        try std.testing.expectEqualStrings("local bytes", installed);
        try std.testing.expectEqualStrings(value, url_policy.reusableUrl(value));
        const display = try url_policy.displayUrl(std.testing.allocator, value);
        defer std.testing.allocator.free(display);
        try std.testing.expectEqualStrings(value, display);
        try std.testing.expect(!url_policy.hasUnsafeMetadata(value));
        const identity = try url_policy.sourceIdentity(std.testing.allocator, value);
        defer std.testing.allocator.free(identity);
        try std.testing.expectEqualStrings("", identity);
        try checksum.verifySha256(dest, expected_checksum);
        try expectNoTempEntries(root);
    }
    try acquireWithDownloader(std.testing.allocator, .{
        .id = "skip",
        .download_url = "https://user@invalid/a#bad\n",
    }, "", .{ .skip_download = true }, forbiddenDownloader);
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
    }, dest, .{}, fakeDownloader);
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
    }, dest, .{}, failingDownloader));
    try std.testing.expect(!sys.exists(dest));
}

test "acquire skip download does not require destination" {
    try acquire(std.testing.allocator, .{ .id = "local", .download_url = "does-not-matter" }, "", .{ .skip_download = true });
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

    try acquireWithDownloader(std.testing.allocator, model, first_dest, .{}, fakeDownloader);
    try acquireWithDownloader(std.testing.allocator, model, second_dest, .{}, fakeDownloader);

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
    }, mismatch_dest, .{}, fakeDownloader));
    const preserved = try sys.readFileAlloc(std.testing.allocator, mismatch_dest, 1024);
    defer std.testing.allocator.free(preserved);
    try std.testing.expectEqualStrings("old model", preserved);
    try expectNoTempEntries(mismatch_root);

    try std.testing.expectError(errors.Error.ModelRegistryInvalid, acquireWithDownloader(std.testing.allocator, .{
        .id = "remote",
        .download_url = "https://example.invalid/model.gguf",
    }, partial_existing_dest, .{}, partialDownloader));
    const partial_preserved = try sys.readFileAlloc(std.testing.allocator, partial_existing_dest, 1024);
    defer std.testing.allocator.free(partial_preserved);
    try std.testing.expectEqualStrings("old model", partial_preserved);

    try std.testing.expectError(errors.Error.ModelRegistryInvalid, acquireWithDownloader(std.testing.allocator, .{
        .id = "remote",
        .download_url = "https://example.invalid/model.gguf",
    }, partial_absent_dest, .{}, partialDownloader));
    try std.testing.expect(!sys.exists(partial_absent_dest));
    try expectNoTempEntries(partial_root);
}
