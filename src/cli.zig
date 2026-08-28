const std = @import("std");
const config = @import("config.zig");
const errors = @import("errors.zig");
const glossary = @import("glossary.zig");
const memory = @import("memory.zig");
const models = @import("models.zig");
const ownership_test_support = @import("ownership_test_support.zig");
const xdg = @import("xdg.zig");
const args = @import("cli/args.zig");
const init_cmd = @import("cli/init_cmd.zig");
const translate_cmd = @import("cli/translate_cmd.zig");
const doctor_cmd = @import("cli/doctor_cmd.zig");
const config_cmd = @import("cli/config_cmd.zig");
const models_cmd = @import("cli/models_cmd.zig");
const memory_cmd = @import("cli/memory_cmd.zig");
const glossary_cmd = @import("cli/glossary_cmd.zig");

const version = "0.0.1";

pub fn run(allocator: std.mem.Allocator, args_slice: []const []const u8) !u8 {
    if (args_slice.len < 2) return errors.Error.InvalidArguments;
    const cmd = args_slice[1];
    if (std.mem.eql(u8, cmd, "version")) {
        if (args_slice.len != 2) return errors.Error.InvalidArguments;
        const sys = @import("sys.zig");
        sys.stdoutPrint("kotoba {s}\n", .{version});
        return 0;
    }
    if (!std.mem.eql(u8, cmd, "init") and
        !std.mem.eql(u8, cmd, "translate") and
        !std.mem.eql(u8, cmd, "doctor") and
        !std.mem.eql(u8, cmd, "config") and
        !std.mem.eql(u8, cmd, "models") and
        !std.mem.eql(u8, cmd, "memory") and
        !std.mem.eql(u8, cmd, "glossary")) return errors.Error.InvalidArguments;
    var dispatch_arena = std.heap.ArenaAllocator.init(allocator);
    defer dispatch_arena.deinit();
    // Paths and their environment-derived strings are borrowed by this dispatch only.
    const paths = try xdg.paths(dispatch_arena.allocator());
    if (std.mem.eql(u8, cmd, "init")) return init_cmd.run(allocator, paths, args_slice[2..]);
    if (std.mem.eql(u8, cmd, "translate")) return translate_cmd.run(allocator, paths, args_slice[2..]);
    if (std.mem.eql(u8, cmd, "doctor")) return doctor_cmd.run(allocator, paths, args_slice[2..]);
    if (std.mem.eql(u8, cmd, "config")) return config_cmd.run(allocator, paths, args_slice[2..]);
    if (std.mem.eql(u8, cmd, "models")) return models_cmd.run(allocator, paths, args_slice[2..]);
    if (std.mem.eql(u8, cmd, "memory")) return memory_cmd.run(allocator, paths, args_slice[2..]);
    if (std.mem.eql(u8, cmd, "glossary")) return glossary_cmd.run(allocator, paths, args_slice[2..]);
    return errors.Error.InvalidArguments;
}

pub fn errorPrefersJson(args_slice: []const []const u8) bool {
    if (args_slice.len >= 2 and std.mem.eql(u8, args_slice[1], "doctor")) {
        return args.hasOptionValue(args_slice[2..], "--format", "json");
    }
    if (args_slice.len >= 2 and std.mem.eql(u8, args_slice[1], "translate")) {
        return args.hasOptionValue(args_slice[2..], "--format", "json");
    }
    return false;
}

test "version command" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const captured = try tmp.dir.createFile(std.testing.io, "stdout", .{});
    defer captured.close(std.testing.io);
    const saved_stdout = std.c.dup(std.posix.STDOUT_FILENO);
    if (saved_stdout < 0) return error.StdoutDuplicateFailed;
    defer _ = std.c.close(saved_stdout);
    const test_args = [_][]const u8{ "kotoba", "version" };
    const status = result: {
        if (std.c.dup2(captured.handle, std.posix.STDOUT_FILENO) < 0) return error.StdoutCaptureFailed;
        // The standard test runner reserves stdout for its control protocol.
        defer if (std.c.dup2(saved_stdout, std.posix.STDOUT_FILENO) < 0) @panic("stdout restore failed");
        break :result try run(std.testing.allocator, &test_args);
    };
    try std.testing.expectEqual(@as(u8, 0), status);
    const output = try tmp.dir.readFileAlloc(std.testing.io, "stdout", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("kotoba " ++ version ++ "\n", output);
}

test "version and unknown commands reject invalid arguments" {
    try std.testing.expectError(errors.Error.InvalidArguments, run(std.testing.allocator, &.{ "kotoba", "version", "extra" }));
    try std.testing.expectError(errors.Error.InvalidArguments, run(std.testing.allocator, &.{ "kotoba", "unknown" }));
}

test "json error preference" {
    const test_args = [_][]const u8{ "kotoba", "translate", "Hello", "--format", "json" };
    try std.testing.expect(errorPrefersJson(&test_args));
}

const TestStreamCapture = struct {
    const c = std.c;
    saved_stdout: c_int,
    saved_stderr: c_int,

    fn start(stdout: std.Io.File, stderr: std.Io.File) !TestStreamCapture {
        const saved_stdout = c.dup(std.posix.STDOUT_FILENO);
        if (saved_stdout < 0) return error.StdoutDuplicateFailed;
        errdefer _ = c.close(saved_stdout);
        const saved_stderr = c.dup(std.posix.STDERR_FILENO);
        if (saved_stderr < 0) return error.StderrDuplicateFailed;
        errdefer _ = c.close(saved_stderr);
        var stdout_redirected = false;
        errdefer {
            if (stdout_redirected) _ = c.dup2(saved_stdout, std.posix.STDOUT_FILENO);
        }
        if (c.dup2(stdout.handle, std.posix.STDOUT_FILENO) < 0) return error.StdoutCaptureFailed;
        stdout_redirected = true;
        if (c.dup2(stderr.handle, std.posix.STDERR_FILENO) < 0) return error.StderrCaptureFailed;
        return .{ .saved_stdout = saved_stdout, .saved_stderr = saved_stderr };
    }

    fn restore(self: *TestStreamCapture) void {
        if (self.saved_stdout >= 0) {
            if (c.dup2(self.saved_stdout, std.posix.STDOUT_FILENO) < 0) @panic("stdout restore failed");
            if (c.close(self.saved_stdout) != 0) @panic("stdout capture close failed");
            self.saved_stdout = -1;
        }
        if (self.saved_stderr >= 0) {
            if (c.dup2(self.saved_stderr, std.posix.STDERR_FILENO) < 0) @panic("stderr restore failed");
            if (c.close(self.saved_stderr) != 0) @panic("stderr capture close failed");
            self.saved_stderr = -1;
        }
    }
};

fn testCommandPaths(allocator: std.mem.Allocator, root: []const u8) !xdg.Paths {
    return .{
        .config_dir = root,
        .data_dir = root,
        .cache_dir = root,
        .state_dir = root,
        .config_file = try std.fs.path.join(allocator, &.{ root, "config.toml" }),
        .models_file = try std.fs.path.join(allocator, &.{ root, "models.toml" }),
        .models_dir = root,
        .glossary_file = try std.fs.path.join(allocator, &.{ root, "glossary.toml" }),
        .memory_file = try std.fs.path.join(allocator, &.{ root, "memory.sqlite3" }),
    };
}

fn prepareCommandFixture(allocator: std.mem.Allocator, paths: xdg.Paths) !void {
    const sys = @import("sys.zig");
    const model_path = try std.fs.path.join(allocator, &.{ paths.models_dir, "fixture.gguf" });
    try sys.writeFile(model_path, "fixture model");
    var cfg = try config.OwnedConfig.clone(allocator, config.default());
    defer cfg.deinit();
    try cfg.setValue("model_id", "fixture");
    try cfg.setValue("model_path", model_path);
    try config.save(paths.config_file, cfg.view());
    try models.ensure(paths.models_file);
    try models.upsert(allocator, paths.models_file, .{
        .id = "fixture",
        .name = "Fixture",
        .profile = "local",
        .languages_en = true,
        .languages_ja = true,
        .format = "gguf",
        .path = model_path,
    });
    try glossary.ensure(paths.glossary_file);
    var db = try memory.open(allocator, paths.memory_file);
    db.close();
}

fn expectCommandReleased(counter: *const ownership_test_support.CountingAllocator) !void {
    try std.testing.expectEqual(@as(usize, 0), counter.live_bytes);
    try std.testing.expectEqual(@as(usize, 0), counter.live_allocations);
}

fn exerciseCommandArenaOom(
    allocator: std.mem.Allocator,
    paths: xdg.Paths,
    stdout: std.Io.File,
    stderr: std.Io.File,
    runs: *usize,
) !void {
    runs.* += 1;
    var capture = try TestStreamCapture.start(stdout, stderr);
    defer capture.restore();
    const status = try config_cmd.run(allocator, paths, &.{ "get", "model_id" });
    capture.restore();
    try std.testing.expectEqual(@as(u8, 0), status);
}

test "ownership/commands invocation arena OOM" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup_arena.deinit();
    const setup_allocator = setup_arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", setup_allocator);
    const paths = try testCommandPaths(setup_allocator, root);
    try prepareCommandFixture(setup_allocator, paths);
    const stdout = try tmp.dir.createFile(std.testing.io, "stdout", .{});
    defer stdout.close(std.testing.io);
    const stderr = try tmp.dir.createFile(std.testing.io, "stderr", .{});
    defer stderr.close(std.testing.io);
    var runs: usize = 0;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseCommandArenaOom, .{ paths, stdout, stderr, &runs });
    try std.testing.expect(runs > 1);
    std.debug.print("ownership/commands OOM exercise_invocations={d} command=config-get streams=restored\n", .{runs});
}

test "ownership/commands repeated calls" {
    if (!@import("build_options").test_backend) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup_arena.deinit();
    const setup_allocator = setup_arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", setup_allocator);
    const paths = try testCommandPaths(setup_allocator, root);
    try prepareCommandFixture(setup_allocator, paths);
    const missing_paths = try testCommandPaths(setup_allocator, try std.fs.path.join(setup_allocator, &.{ root, "missing" }));
    const invalid_paths = try testCommandPaths(setup_allocator, try std.fs.path.join(setup_allocator, &.{ root, "invalid" }));
    const sys = @import("sys.zig");
    try sys.makePath(invalid_paths.config_dir);
    try sys.writeFile(invalid_paths.config_file, "gpu_layers = \"auto\"\n");
    const config_before = try sys.readFileAlloc(setup_allocator, paths.config_file, 1024);
    const models_before = try sys.readFileAlloc(setup_allocator, paths.models_file, 4096);
    const glossary_before = try sys.readFileAlloc(setup_allocator, paths.glossary_file, 1024);

    const stdout = try tmp.dir.createFile(std.testing.io, "stdout", .{});
    defer stdout.close(std.testing.io);
    const stderr = try tmp.dir.createFile(std.testing.io, "stderr", .{});
    defer stderr.close(std.testing.io);
    var capture = try TestStreamCapture.start(stdout, stderr);
    defer capture.restore();

    var counter = ownership_test_support.CountingAllocator.init(std.testing.allocator);
    const allocator = counter.allocator();
    var cycles: usize = 0;
    while (cycles < 2048) : (cycles += 1) {
        try std.testing.expectEqual(@as(u8, 0), try config_cmd.run(allocator, paths, &.{"list"}));
        try expectCommandReleased(&counter);
        try std.testing.expectEqual(@as(u8, 0), try config_cmd.run(allocator, paths, &.{ "get", "model_id" }));
        try expectCommandReleased(&counter);
        try std.testing.expectEqual(@as(u8, 0), try glossary_cmd.run(allocator, paths, &.{"validate"}));
        try expectCommandReleased(&counter);
        try std.testing.expectEqual(@as(u8, 0), try models_cmd.run(allocator, paths, &.{"list"}));
        try expectCommandReleased(&counter);
        try std.testing.expectEqual(@as(u8, 0), try models_cmd.run(allocator, paths, &.{ "info", "fixture" }));
        try expectCommandReleased(&counter);
        try std.testing.expectEqual(@as(u8, 0), try memory_cmd.run(allocator, paths, &.{"status"}));
        try expectCommandReleased(&counter);
        try std.testing.expectEqual(@as(u8, 0), try doctor_cmd.run(allocator, paths, &.{}));
        try expectCommandReleased(&counter);
        try std.testing.expectEqual(@as(u8, 0), try translate_cmd.run(allocator, paths, &.{ "Hello", "--no-memory", "--no-glossary" }));
        try expectCommandReleased(&counter);

        try std.testing.expectError(errors.Error.NotInitialized, config_cmd.run(allocator, missing_paths, &.{ "get", "model_id" }));
        try expectCommandReleased(&counter);
        try std.testing.expectError(errors.Error.ConfigInvalid, config_cmd.run(allocator, invalid_paths, &.{ "get", "model_id" }));
        try expectCommandReleased(&counter);
        try std.testing.expectError(errors.Error.InvalidArguments, translate_cmd.run(allocator, paths, &.{"--bogus"}));
        try expectCommandReleased(&counter);
    }
    capture.restore();
    const output = try tmp.dir.readFileAlloc(std.testing.io, "stdout", std.testing.allocator, .limited(16 * 1024 * 1024));
    defer std.testing.allocator.free(output);
    const expected_config_list = "default_source_lang\ndefault_target_lang\ndefault_mode\ndefault_output\nmodel_id\nmodel_path\ngpu_layers\ncontext_length\nthreads\nmax_tokens\ntemperature\ntimeout_sec\nmemory_enabled\nglossary_enabled\nprivacy_mode\nlog_level\n";
    try std.testing.expectEqual(@as(usize, 2048), countText(output, expected_config_list));
    try std.testing.expectEqual(@as(usize, 2048), countText(output, "fixture\nterms: 0\n"));
    try std.testing.expectEqual(@as(usize, 2048), countText(output, "terms: 0\nhash: "));
    try std.testing.expectEqual(@as(usize, 2048), countText(output, "fixture\tFixture\tlocal\tcurrent\n"));
    try std.testing.expectEqual(@as(usize, 2048), countText(output, "id: fixture\nname: Fixture\n"));
    const expected_memory = try std.fmt.allocPrint(std.testing.allocator, "path: {s}\nrows: 0\n", .{paths.memory_file});
    defer std.testing.allocator.free(expected_memory);
    try std.testing.expectEqual(@as(usize, 2048), countText(output, expected_memory));
    try std.testing.expectEqual(@as(usize, 2048), countText(output, "ok: config: config.toml is readable\n"));
    try std.testing.expectEqual(@as(usize, 2048), countText(output, "JA:Hello\n"));
    try std.testing.expectEqual(@as(usize, 0), (try tmp.dir.statFile(std.testing.io, "stderr", .{})).size);
    const invalid_after = try sys.readFileAlloc(std.testing.allocator, invalid_paths.config_file, 1024);
    defer std.testing.allocator.free(invalid_after);
    try std.testing.expectEqualStrings("gpu_layers = \"auto\"\n", invalid_after);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, missing_paths.config_dir, .{}));
    const config_after = try sys.readFileAlloc(std.testing.allocator, paths.config_file, 1024);
    defer std.testing.allocator.free(config_after);
    const models_after = try sys.readFileAlloc(std.testing.allocator, paths.models_file, 4096);
    defer std.testing.allocator.free(models_after);
    const glossary_after = try sys.readFileAlloc(std.testing.allocator, paths.glossary_file, 1024);
    defer std.testing.allocator.free(glossary_after);
    try std.testing.expectEqualStrings(config_before, config_after);
    try std.testing.expectEqualStrings(models_before, models_after);
    try std.testing.expectEqualStrings(glossary_before, glossary_after);
    try expectCommandReleased(&counter);
    std.debug.print("ownership/commands pid={d} cycles={d} successful_calls={d} error_calls={d} adapters=8 streams=restored command_live=0 command_allocations=0\n", .{ std.posix.system.getpid(), cycles, cycles * 8, cycles * 3 });
}

fn countText(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        count += 1;
        rest = rest[index + needle.len ..];
    }
    return count;
}
