const std = @import("std");
const config = @import("config.zig");
const errors = @import("errors.zig");
const lang = @import("lang.zig");

test "config round trip parse" {
    const cfg = try config.parse(std.heap.page_allocator,
        \\default_source_lang = ""
        \\default_target_lang = "ja"
        \\model_id = "local-ja"
        \\model_path = "/tmp/local-ja.gguf"
        \\context_length = 4096
        \\threads = 0
        \\max_tokens = 1024
        \\temperature = 0.2
        \\timeout_sec = 120
        \\memory_enabled = true
    );
    try std.testing.expectEqual(lang.Language.ja, cfg.default_target_lang);
    try std.testing.expectEqualStrings("local-ja", cfg.model_id);
    try std.testing.expectEqualStrings("/tmp/local-ja.gguf", cfg.model_path);
    try std.testing.expectEqual(@as(u32, 4096), cfg.context_length);
    try std.testing.expectEqual(@as(u32, 0), cfg.threads);
    try std.testing.expectEqual(@as(u32, 1024), cfg.max_tokens);
    try std.testing.expectEqual(@as(f32, 0.2), cfg.temperature);
    try std.testing.expectEqual(@as(u32, 120), cfg.timeout_sec);
    try std.testing.expect(cfg.memory_enabled);
}

test "embedded config rejects removed server keys and negative unsigned settings" {
    var cfg = config.default();
    inline for (.{
        .{ "runtime", "llama_server" },
        .{ "server_url", "http://127.0.0.1:8080" },
        .{ "server_autostart", "true" },
        .{ "llama_server_path", "llama-server" },
        .{ "server_startup_timeout_sec", "60" },
    }) |case| try std.testing.expectError(errors.Error.InvalidArguments, config.setValue(std.testing.allocator, &cfg, case[0], case[1]));
    inline for (.{ "threads", "context_length", "max_tokens", "timeout_sec" }) |key| {
        try std.testing.expectError(errors.Error.ConfigInvalid, config.parse(std.testing.allocator, key ++ " = -1\n"));
    }
}

test "config parses saves gets sets and lists signed gpu layers" {
    inline for (.{
        .{ "gpu_layers = -1\n", -1 },
        .{ "gpu_layers = 0\n", 0 },
        .{ "gpu_layers = 24\n", 24 },
    }) |case| try std.testing.expectEqual(@as(i32, case[1]), (try config.parse(std.testing.allocator, case[0])).gpu_layers);
    var cfg = config.default();
    try std.testing.expectEqual(@as(i32, -1), cfg.gpu_layers);
    inline for (.{ "model_id", "gpu_layers", "timeout_sec" }) |key| try std.testing.expect(containsKey(key));
    inline for (.{ "server_url", "runtime" }) |key| try std.testing.expect(!containsKey(key));
    try config.setValue(std.testing.allocator, &cfg, "gpu_layers", "0");
    const got = try config.getValue(std.testing.allocator, &cfg, "gpu_layers");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("0", got);
    try config.setValue(std.testing.allocator, &cfg, "gpu_layers", "-2");
    try std.testing.expectEqual(@as(i32, -2), cfg.gpu_layers);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "config.toml" });
    defer std.testing.allocator.free(path);
    try config.save(path, cfg);
    const loaded = try config.load(std.heap.page_allocator, path);
    try std.testing.expectEqual(@as(i32, -2), loaded.gpu_layers);
    inline for (.{ "auto", "all", "1.5", "\"auto\"", "\"all\"" }) |value| {
        try std.testing.expectError(errors.Error.ConfigInvalid, config.parse(std.testing.allocator, "gpu_layers = " ++ value ++ "\n"));
    }
    for ([_][]const u8{ "auto", "all", "1.5" }) |value| {
        try std.testing.expectError(errors.Error.InvalidArguments, config.setValue(std.testing.allocator, &cfg, "gpu_layers", value));
    }
}

fn containsKey(key: []const u8) bool {
    for (config.settable_keys) |candidate| {
        if (std.mem.eql(u8, candidate, key)) return true;
    }
    return false;
}

test "strict config rejects unknown and duplicate keys regression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "unknown = 1\n",
        "model_id = \"first\"\nmodel_id = \"second\"\n",
    }) |data| try std.testing.expectError(error.ConfigInvalid, config.parse(arena.allocator(), data));
}

test "strict config escaped string save load regression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    const path = try std.fs.path.join(arena.allocator(), &.{ root, "config.toml" });
    var cfg = config.default();
    cfg.model_path = "C:\\Users\\日本語\\quoted\"#=model.gguf";
    try config.save(path, cfg);
    const loaded = try config.load(arena.allocator(), path);
    try std.testing.expectEqualStrings(cfg.model_path, loaded.model_path);
}

test "strict config duplicate keys regression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ConfigInvalid, config.parse(arena.allocator(), "model_id = \"first\"\nmodel_id = \"second\"\n"));
}

test "strict config escape decoding regression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try config.parse(arena.allocator(), "model_id = \"line\\n\\u65E5\"\n");
    try std.testing.expectEqualStrings("line\n日", cfg.model_id);
}

const complete_fixture =
    \\default_source_lang = "en"
    \\default_target_lang = 'en'
    \\default_mode = "technical"
    \\default_output = 'markdown'
    \\model_id = "quote\" slash\\ # = 日本語 🐈"
    \\model_path = 'C:\Users\日本語\model.gguf'
    \\gpu_layers = -2147483648
    \\context_length = +4294967295
    \\threads = 0
    \\max_tokens = 4294967295
    \\temperature = -2E-1
    \\timeout_sec = 0
    \\memory_enabled = false
    \\glossary_enabled = false
    \\privacy_mode = false
    \\log_level = "arbitrary\n\t\r\b\f\u007f"
;

// Only complete fixtures and save output allocate every arbitrary string field.
fn freeCompleteConfig(allocator: std.mem.Allocator, cfg: config.Config) void {
    allocator.free(cfg.model_id);
    allocator.free(cfg.model_path);
    allocator.free(cfg.log_level);
}

fn expectConfigEqual(expected: config.Config, actual: config.Config) !void {
    try std.testing.expectEqualDeep(expected, actual);
    try std.testing.expectEqual(@as(u32, @bitCast(expected.temperature)), @as(u32, @bitCast(actual.temperature)));
}

test "strict config typed complete input and line endings" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "", "# comment\t日本語", " \t\r\n# comment\r\n\r\n" }) |data| {
        try expectConfigEqual(config.default(), try config.parse(allocator, data));
    }
    const expected: config.Config = .{
        .default_source_lang = .en,
        .default_target_lang = .en,
        .default_mode = .technical,
        .default_output = .markdown,
        .model_id = "quote\" slash\\ # = 日本語 🐈",
        .model_path = "C:\\Users\\日本語\\model.gguf",
        .gpu_layers = std.math.minInt(i32),
        .context_length = std.math.maxInt(u32),
        .threads = 0,
        .max_tokens = std.math.maxInt(u32),
        .temperature = -0.2,
        .timeout_sec = 0,
        .memory_enabled = false,
        .glossary_enabled = false,
        .privacy_mode = false,
        .log_level = "arbitrary\n\t\r\x08\x0c\x7f",
    };
    const lf = try config.parse(allocator, complete_fixture);
    defer freeCompleteConfig(allocator, lf);
    try expectConfigEqual(expected, lf);
    const crlf = try std.mem.replaceOwned(u8, allocator, complete_fixture, "\n", "\r\n");
    defer allocator.free(crlf);
    const windows = try config.parse(allocator, crlf);
    defer freeCompleteConfig(allocator, windows);
    try expectConfigEqual(expected, windows);
}

test "strict config all fields round trip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "config.toml" });
    defer allocator.free(path);
    const values = [_]f32{ 0.0, -0.0, 0.2, 1.0, -1.0, std.math.floatMax(f32), -std.math.floatMax(f32), std.math.floatMin(f32), @bitCast(@as(u32, 1)), @bitCast(@as(u32, 0x80000001)) };
    for ([_][]const u8{ "quote\" slash\\ # = 日本語 🐈", "C:\\Users\\日本語\\model.gguf", "", "\t\n\r\x08\x0c\x7f\x01\x1f" }) |string| {
        for (values) |temperature| {
            const original: config.Config = .{
                .default_source_lang = .en,
                .default_target_lang = .en,
                .default_mode = .technical,
                .default_output = .markdown,
                .model_id = string,
                .model_path = string,
                .gpu_layers = std.math.maxInt(i32),
                .context_length = 0,
                .threads = std.math.maxInt(u32),
                .max_tokens = 0,
                .temperature = temperature,
                .timeout_sec = std.math.maxInt(u32),
                .memory_enabled = false,
                .glossary_enabled = false,
                .privacy_mode = false,
                .log_level = string,
            };
            try config.save(path, original);
            const loaded = try config.load(allocator, path);
            defer freeCompleteConfig(allocator, loaded);
            try expectConfigEqual(original, loaded);
        }
    }
}

test "strict config accepts every enum and integer endpoints" {
    const allocator = std.testing.allocator;
    inline for (.{ "", "en", "ja" }) |value| {
        const cfg = try config.parse(allocator, "default_source_lang = \"" ++ value ++ "\" # source");
        try std.testing.expectEqual(if (value.len == 0) null else try lang.Language.parse(value), cfg.default_source_lang);
    }
    inline for (.{ "en", "ja" }) |value| try std.testing.expectEqual(try lang.Language.parse(value), (try config.parse(allocator, "default_target_lang='" ++ value ++ "'")).default_target_lang);
    inline for (.{ "default", "technical" }) |value| try std.testing.expectEqual(try config.Mode.parse(value), (try config.parse(allocator, "default_mode='" ++ value ++ "'")).default_mode);
    inline for (.{ "plain", "json", "markdown" }) |value| try std.testing.expectEqual(try config.OutputFormat.parse(value), (try config.parse(allocator, "default_output='" ++ value ++ "'")).default_output);
    inline for (.{ "context_length", "threads", "max_tokens", "timeout_sec" }) |key| {
        inline for (.{ "0", "+0", "4294967295" }) |value| {
            const cfg = try config.parse(allocator, key ++ " = " ++ value);
            try std.testing.expectEqual(try std.fmt.parseInt(u32, value, 10), @field(cfg, key));
        }
    }
    inline for (.{ "-2147483648", "2147483647", "-0", "+0", "+2147483647" }) |value| try std.testing.expectEqual(try std.fmt.parseInt(i32, value, 10), (try config.parse(allocator, "gpu_layers = " ++ value)).gpu_layers);
    inline for (.{ "memory_enabled", "glossary_enabled", "privacy_mode" }) |key| {
        inline for (.{ "true", "false" }) |value| try std.testing.expectEqual(std.mem.eql(u8, value, "true"), @field(try config.parse(allocator, key ++ " = " ++ value), key));
    }
    inline for (.{ "0", "+1", "-0", "1.25", "2e-1", "-2E+1" }) |value| try std.testing.expectEqual(try std.fmt.parseFloat(f32, value), (try config.parse(allocator, "temperature = " ++ value)).temperature);
}

test "strict config rejects malformed and future schema" {
    const invalid = [_][]const u8{
        "unknown = 1",                                                      "runtime = 'llama_server'",   "[other]",                  "[[models]]",                 "[version",                 "[[schema]",                  "[schema] trailing",           "[\"version\"]",                       "[schema.version]",
        "model_id",                                                         "= 1",                        "model.id = 'x'",           "\"model_id\" = 'x'",         "model id = 'x'",           "model_id =",                 "model_id = bare",             "model_id = {}",                       "model_id = []",
        "model_id = \"unterminated",                                        "model_id = 'unterminated",   "model_id = \"x\" tail",    "model_id = 'x' 'y'",         "model_id = \"\"\"x\"\"\"", "model_id = '''x'''",         "model_id = \"bad\\q\"",       "model_id = \"bad\\",                  "model_id = \"\\u123\"",
        "model_id = \"\\uZZZZ\"",                                           "model_id = \"\\U00110000\"", "model_id = \"\\uD800\"",   "model_id = \"\\uDFFF\"",     "model_id = \"\\u0000\"",   "model_id = \"\\U00000000\"", "model_id = \"raw\nnewline\"", "model_id = \"raw\rreturn\"",          "model_id = \"raw\x00nul\"",
        "model_id = \"\xff\"",                                              "model_id = \"\xc0\x80\"",    "model_id = '\x7f'",        "# \x01",                     "# \x00",                   "# \xff",                     "\xef\xbb\xbf# BOM",           "\r",                                  "# bare\r",
        "threads = \"2\"",                                                  "threads = '2'",              "threads = true",           "threads = -0",               "threads = -1",             "threads = 4294967296",       "threads = 01",                "threads = 1_000",                     "threads = 0x10",
        "threads = 1.0",                                                    "threads = 1e0",              "threads = 1 2",            "threads = +",                "threads = 1=2",            "gpu_layers = -2147483649",   "gpu_layers = 2147483648",     "gpu_layers = -01",                    "gpu_layers = \"1\"",
        "gpu_layers = 2026-08-29",                                          "temperature = nan",          "temperature = inf",        "temperature = -inf",         "temperature = +nan",       "temperature = 1e100",        "temperature = \"0.2\"",       "temperature = 01.2",                  "temperature = .2",
        "temperature = 2.",                                                 "temperature = 1e",           "temperature = 1e+",        "temperature = 1_0",          "temperature = true",       "memory_enabled = \"true\"",  "glossary_enabled = 1",        "privacy_mode = True",                 "privacy_mode = FALSE",
        "privacy_mode = false tail",                                        "default_source_lang = 'xx'", "default_target_lang = ''", "default_target_lang = 'EN'", "default_mode = 'other'",   "default_output = 'other'",   "default_mode = false",        "model_id = 'allocated'\nunknown = 2", "model_id = 'allocated'\nmodel_path = '\xff'",
        "model_id = 'allocated'\nlog_level = 'ok'\ndefault_mode = 'other'",
    };
    for (invalid) |data| try std.testing.expectError(error.ConfigInvalid, config.parse(std.testing.allocator, data));
    inline for (.{ "version", "schema", "schema_version" }) |marker| {
        inline for (.{ marker ++ " = 2", marker ++ " = \"unterminated", "[" ++ marker ++ "]", "[[" ++ marker ++ "]]", "[ \t" ++ marker ++ " \t] # marker", "[[ " ++ marker ++ " ]]" }) |data| {
            try std.testing.expectError(error.ConfigSchemaUnsupported, config.parse(std.testing.allocator, data));
        }
        try std.testing.expectError(error.ConfigSchemaUnsupported, config.parse(std.testing.allocator, "model_id='owned'\n" ++ marker ++ "=2\n"));
    }
    try std.testing.expectError(error.ConfigInvalid, config.parse(std.testing.allocator, "unknown=1\nversion=2"));
    try std.testing.expectError(error.ConfigSchemaUnsupported, config.parse(std.testing.allocator, "version=2\nmodel_id='\xff'"));
}

test "strict config rejects duplicate of every key before decoding" {
    var lines = std.mem.splitScalar(u8, complete_fixture, '\n');
    while (lines.next()) |line| {
        const duplicate = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\n", .{ line, line });
        defer std.testing.allocator.free(duplicate);
        try std.testing.expectError(error.ConfigInvalid, config.parse(std.testing.allocator, duplicate));
    }
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.ConfigInvalid, config.parse(failing.allocator(), "threads=1\nthreads=\"requires allocation\""));
    try std.testing.expectError(error.ConfigInvalid, config.parse(std.testing.allocator, "model_id='first'\nmodel_id=\"\\q\""));
}

fn checkConfigOwnership(allocator: std.mem.Allocator) !void {
    const input = try allocator.dupe(u8, complete_fixture);
    const cfg = config.parse(allocator, input) catch |err| {
        allocator.free(input);
        return err;
    };
    allocator.free(input);
    defer freeCompleteConfig(allocator, cfg);
    try std.testing.expectEqualStrings("quote\" slash\\ # = 日本語 🐈", cfg.model_id);
    try std.testing.expectEqualStrings("C:\\Users\\日本語\\model.gguf", cfg.model_path);
    try std.testing.expectEqualStrings("arbitrary\n\t\r\x08\x0c\x7f", cfg.log_level);
}

fn checkInvalidConfigOwnership(allocator: std.mem.Allocator, suffix: []const u8, expected: anyerror) !void {
    const input = try std.mem.concat(allocator, u8, &.{ complete_fixture, "\n", suffix });
    defer allocator.free(input);
    if (config.parse(allocator, input)) |cfg| {
        freeCompleteConfig(allocator, cfg);
        return error.TestUnexpectedResult;
    } else |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expectEqual(expected, err);
    }
}

test "strict config owns strings and cleans all allocation failure paths" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkConfigOwnership, .{});
    inline for (.{ .{ "unknown=1", error.ConfigInvalid }, .{ "model_id='duplicate'", error.ConfigInvalid }, .{ "schema=2", error.ConfigSchemaUnsupported } }) |case| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, checkInvalidConfigOwnership, .{ case[0], case[1] });
    }
}

test "strict config save validates before touching sentinel destination" {
    const allocator = std.testing.allocator;
    const sys = @import("sys.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "config.toml" });
    defer allocator.free(path);
    const absent = try std.fs.path.join(allocator, &.{ root, "must-not-exist.toml" });
    defer allocator.free(absent);
    try sys.writeFile(path, "sentinel bytes\n");
    inline for (.{ "model_id", "model_path", "log_level" }) |key| {
        for ([_][]const u8{ "bad\x00", "\xff", "\xed\xa0\x80" }) |value| {
            var cfg = config.default();
            @field(cfg, key) = value;
            try std.testing.expectError(error.ConfigInvalid, config.save(path, cfg));
            try std.testing.expectError(error.ConfigInvalid, config.save(absent, cfg));
            const bytes = try sys.readFileAlloc(allocator, path, 100);
            defer allocator.free(bytes);
            try std.testing.expectEqualStrings("sentinel bytes\n", bytes);
            try std.testing.expect(!sys.exists(absent));
        }
    }
    for ([_]f32{ std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32) }) |value| {
        var cfg = config.default();
        cfg.temperature = value;
        try std.testing.expectError(error.ConfigInvalid, config.save(path, cfg));
        try std.testing.expectError(error.ConfigInvalid, config.save(absent, cfg));
        const bytes = try sys.readFileAlloc(allocator, path, 100);
        defer allocator.free(bytes);
        try std.testing.expectEqualStrings("sentinel bytes\n", bytes);
        try std.testing.expect(!sys.exists(absent));
    }
}

test "strict config set preserves raw strings and rejects before mutation" {
    var cfg = config.default();
    const allocator = std.testing.allocator;
    inline for (.{ "model_id", "model_path", "log_level" }) |key| {
        const raw = "C:\\日本語\\quote\"#=\n\t\x7f";
        try config.setValue(allocator, &cfg, key, raw);
        defer {
            allocator.free(@field(cfg, key));
            @field(cfg, key) = @field(config.default(), key);
        }
        try std.testing.expectEqualStrings(raw, @field(cfg, key));
        const before = cfg;
        for ([_][]const u8{ "bad\x00", "\xff" }) |value| {
            try std.testing.expectError(error.InvalidArguments, config.setValue(allocator, &cfg, key, value));
            try expectConfigEqual(before, cfg);
        }
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        try std.testing.expectError(error.OutOfMemory, config.setValue(failing.allocator(), &cfg, key, "new"));
        try expectConfigEqual(before, cfg);
    }
    const before = cfg;
    inline for (.{ "nan", "inf", "-inf", "1e100", "not-number" }) |value| {
        try std.testing.expectError(error.InvalidArguments, config.setValue(allocator, &cfg, "temperature", value));
        try expectConfigEqual(before, cfg);
    }
    inline for (.{ "context_length", "threads", "max_tokens", "timeout_sec" }) |key| {
        try std.testing.expectError(error.InvalidArguments, config.setValue(allocator, &cfg, key, "-1"));
        try expectConfigEqual(before, cfg);
    }
}
