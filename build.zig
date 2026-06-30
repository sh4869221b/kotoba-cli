const std = @import("std");

pub fn build(b: *std.Build) void {
    const native_only = [_]std.Target.Query{.{}};
    const target = b.standardTargetOptions(.{ .whitelist = &native_only });
    const optimize = b.standardOptimizeOption(.{});
    const test_backend = b.option(bool, "test-backend", "Use deterministic test translation backend") orelse false;
    const cuda = b.option(bool, "cuda", "Build embedded llama.cpp with CUDA support") orelse false;
    const cuda_lib_dir = b.option([]const u8, "cuda-lib-dir", "Absolute CUDA Toolkit library directory");
    if (cuda_lib_dir) |dir| {
        if (!std.fs.path.isAbsolute(dir)) @panic("cuda-lib-dir must be an absolute path");
    }
    const llama_options = LlamaBuildOptions{
        .cuda = cuda,
        .build_dir = if (cuda) "vendor/llama.cpp/build-kotoba-cuda" else "vendor/llama.cpp/build-kotoba-cpu",
        .cuda_lib_dir = cuda_lib_dir,
    };

    const options = b.addOptions();
    options.addOption(bool, "test_backend", test_backend);
    const llama_build = addLlamaBuild(b, llama_options);
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
    linkLlama(b, exe, target, llama_options);
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
    linkLlama(b, tests, target, llama_options);
    tests.step.dependOn(llama_build);
    tests.step.dependOn(llama_probe);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const bench_cmd = b.addSystemCommand(&.{ "bash", "test/integration/bench.sh" });
    const bench_step = b.step("bench", "Run deterministic translation benchmark");
    bench_step.dependOn(&bench_cmd.step);
}

const LlamaBuildOptions = struct {
    cuda: bool,
    build_dir: []const u8,
    cuda_lib_dir: ?[]const u8,
};

fn addLlamaBuild(b: *std.Build, options: LlamaBuildOptions) *std.Build.Step {
    const cmake_cuda_option = if (options.cuda) "-DGGML_CUDA=ON" else "-DGGML_CUDA=OFF";
    const configure = b.addSystemCommand(&.{
        "cmake",
        "-S",
        "vendor/llama.cpp",
        "-B",
        options.build_dir,
        "-DBUILD_SHARED_LIBS=OFF",
        "-DGGML_STATIC=OFF",
        cmake_cuda_option,
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
        options.build_dir,
        "--config",
        "Release",
        "--parallel",
        "4",
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

fn linkLlama(b: *std.Build, artifact: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, options: LlamaBuildOptions) void {
    artifact.root_module.addIncludePath(b.path("vendor/llama.cpp/include"));
    artifact.root_module.addIncludePath(b.path("vendor/llama.cpp/ggml/include"));
    artifact.root_module.addLibraryPath(b.path(b.fmt("{s}/src", .{options.build_dir})));
    artifact.root_module.addLibraryPath(b.path(b.fmt("{s}/ggml/src", .{options.build_dir})));
    artifact.root_module.linkSystemLibrary("llama", .{});
    artifact.root_module.linkSystemLibrary("ggml", .{});
    artifact.root_module.linkSystemLibrary("ggml-base", .{});
    artifact.root_module.linkSystemLibrary("ggml-cpu", .{});
    if (options.cuda) {
        artifact.root_module.addLibraryPath(b.path(b.fmt("{s}/ggml/src/ggml-cuda", .{options.build_dir})));
        artifact.root_module.linkSystemLibrary("ggml-cuda", .{});
    }
    switch (target.result.os.tag) {
        .linux => {
            if (options.cuda) linkLinuxCudaLibraries(b, artifact, options);
            linkLinuxCxxRuntime(b, artifact, options.build_dir);
        },
        .macos => artifact.root_module.linkSystemLibrary("c++", .{}),
        else => @panic("embedded llama.cpp build currently supports Linux and macOS native hosts only"),
    }
}

fn linkLinuxCudaLibraries(b: *std.Build, artifact: *std.Build.Step.Compile, options: LlamaBuildOptions) void {
    if (options.cuda_lib_dir) |dir| {
        artifact.root_module.addLibraryPath(.{ .cwd_relative = b.dupe(dir) });
        addExistingLibraryPath(b, artifact, b.fmt("{s}/stubs", .{dir}));
    }
    const default_cuda_lib_dirs = [_][]const u8{
        "/opt/cuda/targets/x86_64-linux/lib",
        "/opt/cuda/targets/x86_64-linux/lib/stubs",
        "/opt/cuda/lib",
        "/opt/cuda/lib/stubs",
        "/usr/local/cuda/lib64",
        "/usr/local/cuda/lib64/stubs",
        "/usr/local/cuda/lib",
        "/usr/local/cuda/lib/stubs",
    };
    for (default_cuda_lib_dirs) |dir| addExistingLibraryPath(b, artifact, dir);
    artifact.root_module.linkSystemLibrary("cuda", .{});
    artifact.root_module.linkSystemLibrary("cudart", .{});
    artifact.root_module.linkSystemLibrary("cublas", .{});
    artifact.root_module.linkSystemLibrary("cublasLt", .{});
}

fn addExistingLibraryPath(b: *std.Build, artifact: *std.Build.Step.Compile, dir: []const u8) void {
    std.Io.Dir.cwd().access(b.graph.io, dir, .{}) catch return;
    artifact.root_module.addLibraryPath(.{ .cwd_relative = b.dupe(dir) });
}

fn linkLinuxCxxRuntime(b: *std.Build, artifact: *std.Build.Step.Compile, build_dir: []const u8) void {
    const compiler = cxxCompiler(b, build_dir);
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

fn cxxCompiler(b: *std.Build, build_dir: []const u8) []const u8 {
    const cache = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        b.fmt("{s}/CMakeCache.txt", .{build_dir}),
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
