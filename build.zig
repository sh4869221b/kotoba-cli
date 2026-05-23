const std = @import("std");

pub fn build(b: *std.Build) void {
    const native_only = [_]std.Target.Query{.{}};
    const target = b.standardTargetOptions(.{ .whitelist = &native_only });
    const optimize = b.standardOptimizeOption(.{});
    const test_backend = b.option(bool, "test-backend", "Use deterministic test translation backend") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "test_backend", test_backend);
    const llama_build = addLlamaBuild(b);
    const llama_probe = addLlamaApiProbe(b);

    const exe = b.addExecutable(.{
        .name = "kotoba",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    exe.root_module.linkSystemLibrary("sqlite3", .{});
    linkLlama(b, exe, target);
    exe.step.dependOn(llama_build);
    exe.step.dependOn(llama_probe);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run kotoba");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .test_runner = .{
            .path = .{ .cwd_relative = "/usr/lib/zig/compiler/test_runner.zig" },
            .mode = .simple,
        },
    });
    tests.root_module.addOptions("build_options", options);
    tests.root_module.linkSystemLibrary("sqlite3", .{});
    linkLlama(b, tests, target);
    tests.step.dependOn(llama_build);
    tests.step.dependOn(llama_probe);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

fn addLlamaBuild(b: *std.Build) *std.Build.Step {
    const configure = b.addSystemCommand(&.{
        "cmake",
        "-S",
        "vendor/llama.cpp",
        "-B",
        "vendor/llama.cpp/build-kotoba",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DLLAMA_BUILD_COMMON=OFF",
        "-DLLAMA_BUILD_TESTS=OFF",
        "-DLLAMA_BUILD_TOOLS=OFF",
        "-DLLAMA_BUILD_EXAMPLES=OFF",
        "-DLLAMA_BUILD_SERVER=OFF",
        "-DLLAMA_BUILD_APP=OFF",
        "-DGGML_OPENMP=OFF",
        "-DLLAMA_BUILD_COMMIT=9c92e96a64fe0f03f5f3e5ab720a151941da1de5",
        "-DGGML_BUILD_COMMIT=9c92e96a64fe0f03f5f3e5ab720a151941da1de5",
    });
    const build_cmd = b.addSystemCommand(&.{
        "cmake",
        "--build",
        "vendor/llama.cpp/build-kotoba",
        "--config",
        "Release",
    });
    build_cmd.step.dependOn(&configure.step);
    return &build_cmd.step;
}

fn addLlamaApiProbe(b: *std.Build) *std.Build.Step {
    const probe = b.addSystemCommand(&.{
        "cc",
        "-fsyntax-only",
        "-Ivendor/llama.cpp/include",
        "-Ivendor/llama.cpp/ggml/include",
        "src/llama_api_probe.c",
    });
    return &probe.step;
}

fn linkLlama(b: *std.Build, artifact: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    artifact.root_module.addIncludePath(b.path("vendor/llama.cpp/include"));
    artifact.root_module.addIncludePath(b.path("vendor/llama.cpp/ggml/include"));
    artifact.root_module.addLibraryPath(b.path("vendor/llama.cpp/build-kotoba/src"));
    artifact.root_module.addLibraryPath(b.path("vendor/llama.cpp/build-kotoba/ggml/src"));
    artifact.root_module.linkSystemLibrary("llama", .{});
    artifact.root_module.linkSystemLibrary("ggml", .{});
    artifact.root_module.linkSystemLibrary("ggml-base", .{});
    artifact.root_module.linkSystemLibrary("ggml-cpu", .{});
    switch (target.result.os.tag) {
        .linux => linkLinuxCxxRuntime(b, artifact),
        .macos => artifact.root_module.linkSystemLibrary("c++", .{}),
        else => @panic("embedded llama.cpp build currently supports Linux and macOS native hosts only"),
    }
}

fn linkLinuxCxxRuntime(b: *std.Build, artifact: *std.Build.Step.Compile) void {
    const compiler = cxxCompiler(b);
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ compiler, "-###", "-x", "c++", "/dev/null", "-o", "/dev/null" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch @panic("failed to inspect C++ compiler runtime");
    if (result.term != .exited or result.term.exited != 0) @panic("failed to inspect C++ compiler runtime");
    const trace = result.stderr;
    var linked = false;
    if (traceHasLinkLibrary(b, trace, "stdc++")) {
        addCompilerRuntimeLibrary(b, artifact, compiler, "libstdc++.so");
        linked = true;
    }
    if (traceHasLinkLibrary(b, trace, "c++")) {
        addCompilerRuntimeLibrary(b, artifact, compiler, "libc++.so");
        linked = true;
    }
    if (traceHasLinkLibrary(b, trace, "c++abi")) addCompilerRuntimeLibrary(b, artifact, compiler, "libc++abi.so");
    if (traceHasLinkLibrary(b, trace, "gcc_s")) addCompilerRuntimeLibrary(b, artifact, compiler, "libgcc_s.so.1");
    if (!linked) @panic("failed to detect C++ standard library from compiler driver");
}

fn cxxCompiler(b: *std.Build) []const u8 {
    const cache = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        "vendor/llama.cpp/build-kotoba/CMakeCache.txt",
        b.allocator,
        .limited(1024 * 1024),
    ) catch return b.graph.environ_map.get("CXX") orelse "c++";
    if (cmakeCacheValue(cache, "CMAKE_CXX_COMPILER:FILEPATH=")) |value| return b.dupe(value);
    if (cmakeCacheValue(cache, "CMAKE_CXX_COMPILER:STRING=")) |value| return b.dupe(value);
    return b.graph.environ_map.get("CXX") orelse "c++";
}

fn cmakeCacheValue(cache: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, cache, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, key)) return line[key.len..];
    }
    return null;
}

fn traceHasLinkLibrary(b: *std.Build, trace: []const u8, name: []const u8) bool {
    const quoted = b.fmt("\"-l{s}\"", .{name});
    if (std.mem.indexOf(u8, trace, quoted) != null) return true;
    const spaced = b.fmt(" -l{s} ", .{name});
    if (std.mem.indexOf(u8, trace, spaced) != null) return true;
    const newline = b.fmt(" -l{s}\n", .{name});
    if (std.mem.indexOf(u8, trace, newline) != null) return true;
    return false;
}

fn addCompilerRuntimeLibrary(b: *std.Build, artifact: *std.Build.Step.Compile, compiler: []const u8, name: []const u8) void {
    const flag = b.fmt("-print-file-name={s}", .{name});
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ compiler, flag },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch @panic("failed to locate compiler runtime library");
    if (result.term != .exited or result.term.exited != 0) @panic("failed to locate compiler runtime library");
    const path = std.mem.trim(u8, result.stdout, " \r\n\t");
    if (path.len == 0 or std.mem.eql(u8, path, name)) @panic("compiler runtime library was not found");
    artifact.root_module.addObjectFile(.{ .cwd_relative = b.dupe(path) });
}
