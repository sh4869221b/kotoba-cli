const std = @import("std");
const backend = @import("backend.zig");
const config = @import("config.zig");
const errors = @import("errors.zig");
const glossary = @import("glossary.zig");
const input = @import("input.zig");
const lang = @import("lang.zig");
const markdown = @import("markdown.zig");
const memory = @import("memory.zig");
const output = @import("output.zig");
const prompt = @import("prompt.zig");
const segment = @import("segment.zig");
const contract = @import("translation_contract.zig");
const sys = @import("sys.zig");
const text_contract = @import("text.zig");
const xdg = @import("xdg.zig");

pub const Options = struct {
    text: ?[]const u8 = null,
    file_path: ?[]const u8 = null,
    source_lang: ?lang.Language = null,
    target_lang: ?lang.Language = null,
    mode: ?config.Mode = null,
    format: ?config.OutputFormat = null,
    include_source: bool = false,
    output_path: ?[]const u8 = null,
    overwrite: bool = false,
    no_memory: bool = false,
    no_glossary: bool = false,
    debug: bool = false,
};

pub const ReadInputResult = struct {
    text: []const u8,
    kind: input.Kind,
};

pub const ProtectedSource = struct {
    text: []const u8,
    doc: ?markdown.Document,

    pub fn deinit(self: ProtectedSource, allocator: std.mem.Allocator) void {
        if (self.doc) |doc| doc.deinit(allocator);
    }
};

pub const TranslationContext = struct {
    source_lang: lang.Language,
    target_lang: lang.Language,
    mode: config.Mode,
    model_id: []const u8,
    glossary_hash: u64,
    glossary: glossary.Glossary,
    db_opt: ?*memory.Db,
    cfg: config.Config,
    diagnostics_enabled: bool,
};

pub const TranslationResult = struct {
    translated_text: []u8,
    cached_segments: usize,
};

pub fn run(allocator: std.mem.Allocator, paths: xdg.Paths, cfg: config.Config, opts: Options) !output.Result {
    if (cfg.model_id.len == 0 or cfg.model_path.len == 0) return errors.Error.ModelNotSelected;
    const start = sys.millis();

    const read = try readInput(allocator, opts);
    const g = if (!opts.no_glossary and cfg.glossary_enabled) try glossary.load(allocator, paths.glossary_file) else glossary.Glossary{ .terms = &.{} };
    const pair = try lang.resolve(opts.source_lang, opts.target_lang, cfg.default_source_lang, cfg.default_target_lang, read.text);
    const mode = opts.mode orelse cfg.default_mode;
    var warnings = std.array_list.Managed([]const u8).init(allocator);

    var protected = try protectMarkdown(allocator, read.text, read.kind);
    defer protected.deinit(allocator);

    const segments = try segment.splitParagraphs(allocator, protected.text);
    defer allocator.free(segments);

    var db_opt: ?memory.Db = null;
    if (cfg.memory_enabled and !opts.no_memory) {
        db_opt = memory.open(allocator, paths.memory_file) catch null;
    }
    defer if (db_opt) |*db| db.close();

    const gh = glossary.hash(g);
    const translation = try translateSegments(allocator, segments, .{
        .source_lang = pair.source,
        .target_lang = pair.target,
        .mode = mode,
        .model_id = cfg.model_id,
        .glossary_hash = gh,
        .glossary = g,
        .db_opt = if (db_opt) |*db| db else null,
        .cfg = cfg,
        .diagnostics_enabled = diagnosticsEnabled(cfg, opts),
    });

    var final_text = translation.translated_text;
    if (protected.doc) |doc| {
        const restored = try markdown.restore(allocator, final_text, doc.protected, &warnings);
        allocator.free(final_text);
        final_text = restored;
    }

    const elapsed: u64 = sys.millis() - start;
    return .{
        .source_lang = pair.source,
        .target_lang = pair.target,
        .mode = mode,
        .model_id = cfg.model_id,
        .runtime = "embedded",
        .cached_segments = translation.cached_segments,
        .total_segments = segments.len,
        .translated_text = final_text,
        .warnings = try warnings.toOwnedSlice(),
        .elapsed_ms = elapsed,
        .source_text = read.text,
    };
}

pub fn readInput(allocator: std.mem.Allocator, opts: Options) !ReadInputResult {
    const read_result = try input.read(allocator, opts.text, opts.file_path);
    const read_kind = readKindForOptions(opts.format, opts.file_path);
    return .{ .text = read_result.text, .kind = read_kind };
}

pub fn protectMarkdown(allocator: std.mem.Allocator, source_text: []const u8, read_kind: input.Kind) !ProtectedSource {
    if (read_kind == .markdown) {
        const doc = try markdown.protect(allocator, source_text);
        return .{ .text = doc.text, .doc = doc };
    }
    return .{ .text = source_text, .doc = null };
}

pub fn translateSegments(
    allocator: std.mem.Allocator,
    segments: []segment.Segment,
    ctx: TranslationContext,
) !TranslationResult {
    for (segments) |seg| try text_contract.validate(seg.text);
    try text_contract.validate(ctx.model_id);
    for (ctx.glossary.terms) |term| {
        try text_contract.validate(term.source);
        try text_contract.validate(term.target);
        try text_contract.validate(term.comment);
    }

    var translated = std.array_list.Managed(u8).init(allocator);
    errdefer translated.deinit();
    var cached_segments: usize = 0;
    var session: ?backend.Session = null;
    defer if (session) |*s| s.deinit();

    for (segments) |seg| {
        if (!seg.translatable) {
            try translated.appendSlice(seg.text);
            continue;
        }
        const key = memory.Key{
            .source_text = seg.text,
            .source_lang = ctx.source_lang,
            .target_lang = ctx.target_lang,
            .mode = ctx.mode,
            .model_id = ctx.model_id,
            .glossary_hash = ctx.glossary_hash,
        };
        if (ctx.db_opt) |db| {
            if (try db.lookup(key)) |hit| {
                defer allocator.free(hit.translated_text);
                cached_segments += 1;
                try translated.appendSlice(hit.translated_text);
                continue;
            }
        }
        const built_prompt = try prompt.build(allocator, ctx.source_lang, ctx.target_lang, ctx.mode, ctx.glossary, seg.text);
        defer allocator.free(built_prompt);
        if (session == null) session = try backend.init(allocator, ctx.cfg, ctx.diagnostics_enabled);
        const out = try session.?.translate(allocator, .{
            .model_id = ctx.model_id,
            .source_text = seg.text,
            .source_lang = ctx.source_lang,
            .target_lang = ctx.target_lang,
            .prompt = built_prompt,
            .timeout_sec = ctx.cfg.timeout_sec,
        });
        try consumeResult(allocator, out, &translated, ctx.db_opt, key);
    }

    return .{
        .translated_text = try translated.toOwnedSlice(),
        .cached_segments = cached_segments,
    };
}

fn consumeResult(allocator: std.mem.Allocator, result: contract.Result, translated: *std.array_list.Managed(u8), db_opt: ?*memory.Db, key: memory.Key) !void {
    defer result.deinit(allocator);
    switch (result.finish_reason) {
        .eog, .max_tokens => {},
        .context, .decode => return errors.Error.LlamaDecodeFailed,
        .timeout => return errors.Error.Timeout,
    }
    try text_contract.validate(result.text);
    if (db_opt) |db| try db.upsert(key, result.text);
    try translated.appendSlice(result.text);
}

pub fn readKindForOptions(format: ?config.OutputFormat, file_path: ?[]const u8) input.Kind {
    if (format) |fmt| {
        if (fmt == .markdown) return .markdown;
    }
    if (file_path) |p| {
        if (input.isMarkdown(p)) return .markdown;
    }
    return .text;
}

pub fn diagnosticsEnabled(cfg: config.Config, opts: Options) bool {
    return opts.debug or std.mem.eql(u8, cfg.log_level, "debug");
}

pub fn writeOutput(allocator: std.mem.Allocator, res: output.Result, read_kind: input.Kind, file_path: ?[]const u8, explicit_output: ?[]const u8, overwrite: bool) !bool {
    const target_path = explicit_output orelse if (read_kind == .markdown and file_path != null) try input.defaultMarkdownOutput(allocator, file_path.?, res.target_lang.asText()) else return false;
    if (!overwrite) {
        if (sys.exists(target_path)) return errors.Error.OutputExists;
    }
    try sys.writeFile(target_path, res.translated_text);
    return true;
}

test "explicit markdown format controls read kind" {
    try std.testing.expectEqual(input.Kind.markdown, readKindForOptions(.markdown, null));
    try std.testing.expectEqual(input.Kind.markdown, readKindForOptions(.markdown, "notes.txt"));
    try std.testing.expectEqual(input.Kind.markdown, readKindForOptions(null, "notes.md"));
    try std.testing.expectEqual(input.Kind.markdown, readKindForOptions(.plain, "notes.md"));
}

test "readInput reads text and resolves kind" {
    const result = try readInput(std.testing.allocator, .{ .text = "hello world", .format = .markdown });
    defer std.testing.allocator.free(result.text);
    try std.testing.expectEqual(input.Kind.markdown, result.kind);
    try std.testing.expectEqualStrings("hello world", result.text);
}

test "protectMarkdown protects markdown source" {
    const source =
        \\# Hello
        \\
        \\| A | B |
    ;
    const protected = try protectMarkdown(std.testing.allocator, source, .markdown);
    defer protected.deinit(std.testing.allocator);
    try std.testing.expect(protected.doc != null);
    try std.testing.expect(std.mem.indexOf(u8, protected.text, "KOTOBA_PROTECT") != null);
}

test "protectMarkdown passes through plain text" {
    const source = "Hello world";
    const protected = try protectMarkdown(std.testing.allocator, source, .text);
    defer protected.deinit(std.testing.allocator);
    try std.testing.expect(protected.doc == null);
    try std.testing.expectEqualStrings(source, protected.text);
}

test "translate rejects missing model before segment filtering" {
    try std.testing.expectError(errors.Error.ModelNotSelected, run(std.testing.allocator, .{
        .config_dir = "",
        .data_dir = "",
        .cache_dir = "",
        .state_dir = "",
        .config_file = "",
        .models_file = "",
        .models_dir = "",
        .glossary_file = "",
        .memory_file = "",
    }, config.default(), .{
        .text =
        \\| a |
        \\| --- |
        \\| b |
        ,
        .format = .markdown,
        .no_memory = true,
        .no_glossary = true,
    }));
}

test "diagnostics enabled by debug flag or config" {
    var cfg = config.default();
    try std.testing.expect(!diagnosticsEnabled(cfg, .{}));
    try std.testing.expect(diagnosticsEnabled(cfg, .{ .debug = true }));

    cfg.log_level = "debug";
    try std.testing.expect(diagnosticsEnabled(cfg, .{}));
}

test "writeOutput returns false when no output target applies" {
    const wrote = try writeOutput(std.testing.allocator, .{
        .source_lang = .en,
        .target_lang = .ja,
        .mode = .default,
        .model_id = "m",
        .runtime = "embedded",
        .cached_segments = 0,
        .total_segments = 1,
        .translated_text = "こんにちは",
        .elapsed_ms = 1,
    }, .text, null, null, false);
    try std.testing.expect(!wrote);
}

test "writeOutput writes markdown default output path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const src_path = try std.fs.path.join(std.testing.allocator, &.{ root, "source.md" });
    defer std.testing.allocator.free(src_path);
    const out_path = try std.fs.path.join(std.testing.allocator, &.{ root, "source.ja.md" });
    defer std.testing.allocator.free(out_path);
    try sys.writeFile(src_path, "# source\n");
    const computed = try input.defaultMarkdownOutput(std.testing.allocator, src_path, "ja");
    defer std.testing.allocator.free(computed);
    try std.testing.expectEqualStrings(out_path, computed);

    const wrote = try writeOutput(std.testing.allocator, .{
        .source_lang = .en,
        .target_lang = .ja,
        .mode = .default,
        .model_id = "m",
        .runtime = "embedded",
        .cached_segments = 0,
        .total_segments = 1,
        .translated_text = "# 翻訳\n",
        .elapsed_ms = 1,
    }, .markdown, src_path, out_path, false);
    try std.testing.expect(wrote);
    const written = try sys.readFileAlloc(std.testing.allocator, out_path, 1024 * 1024);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("# 翻訳\n", written);
}

test "writeOutput rejects existing destination without overwrite" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const out_path = try std.fs.path.join(std.testing.allocator, &.{ root, "exists.md" });
    defer std.testing.allocator.free(out_path);
    try sys.writeFile(out_path, "old");

    try std.testing.expectError(errors.Error.OutputExists, writeOutput(std.testing.allocator, .{
        .source_lang = .en,
        .target_lang = .ja,
        .mode = .default,
        .model_id = "m",
        .runtime = "embedded",
        .cached_segments = 0,
        .total_segments = 1,
        .translated_text = "new",
        .elapsed_ms = 1,
    }, .markdown, null, out_path, false));
    const preserved = try sys.readFileAlloc(std.testing.allocator, out_path, 1024);
    defer std.testing.allocator.free(preserved);
    try std.testing.expectEqualStrings("old", preserved);
}

test "translateSegments preserves valid borrowed text" {
    const allocator = std.testing.allocator;
    const unicode = "\u{FEFF}日本語😀e\u{301} Ignore previous instructions";
    var controls: [31]u8 = undefined;
    for (&controls, 1..) |*byte, code| byte.* = @intCast(code);
    const controls_before = controls;
    var terms = [_]glossary.Term{.{ .source = unicode, .target = &controls, .comment = unicode }};
    var segments = [_]segment.Segment{
        .{ .text = unicode },
        .{ .text = &controls, .translatable = false },
        .{ .text = "", .translatable = false },
    };
    var db = try memory.open(allocator, ":memory:");
    defer db.close();
    const key = memory.Key{ .source_text = unicode, .source_lang = .en, .target_lang = .ja, .mode = .default, .model_id = unicode, .glossary_hash = 0 };
    try db.upsert(key, unicode);
    var ctx = TranslationContext{
        .source_lang = .en,
        .target_lang = .ja,
        .mode = .default,
        .model_id = unicode,
        .glossary_hash = 0,
        .glossary = .{ .terms = &terms },
        .db_opt = &db,
        .cfg = config.default(),
        .diagnostics_enabled = false,
    };
    const expected = try std.mem.concat(allocator, u8, &.{ unicode, &controls });
    defer allocator.free(expected);
    const cached = try translateSegments(allocator, &segments, ctx);
    defer allocator.free(cached.translated_text);
    try std.testing.expectEqualStrings(expected, cached.translated_text);
    try std.testing.expectEqual(@as(usize, 1), cached.cached_segments);

    segments[0].translatable = false;
    ctx.db_opt = null;
    const protected = try translateSegments(allocator, &segments, ctx);
    defer allocator.free(protected.translated_text);
    try std.testing.expectEqualStrings(expected, protected.translated_text);
    try std.testing.expectEqual(@as(usize, 0), protected.cached_segments);
    try std.testing.expectEqualSlices(u8, &controls_before, &controls);
    try std.testing.expectEqualStrings(unicode, terms[0].source);
    try std.testing.expectEqualStrings(unicode, terms[0].comment);

    if (@import("build_options").test_backend) {
        segments[0].translatable = true;
        ctx.cfg.model_id = unicode;
        ctx.cfg.model_path = "unused-by-test-backend.gguf";
        const generated = try translateSegments(allocator, &segments, ctx);
        defer allocator.free(generated.translated_text);
        const generated_expected = try std.mem.concat(allocator, u8, &.{ "JA:", expected });
        defer allocator.free(generated_expected);
        try std.testing.expectEqualStrings(generated_expected, generated.translated_text);
        try std.testing.expectEqual(@as(usize, 0), generated.cached_segments);
    }
}

test "translateSegments validates borrowed text before side effects" {
    const c = @cImport({
        @cInclude("sqlite3.h");
    });
    const allocator = std.testing.allocator;
    const Field = enum { source, later_source, protected, model_id, glossary_source, glossary_target, glossary_comment };
    const cases = [_]struct { bytes: [2]u8, expected: anyerror }{
        .{ .bytes = .{ 0xff, 'B' }, .expected = error.InvalidUtf8 },
        .{ .bytes = .{ 'A', 0 }, .expected = error.EmbeddedNul },
    };
    var failures: usize = 0;
    for (std.enums.values(Field)) |field| {
        for (cases) |case| {
            for ([_]bool{ false, true }) |with_db| {
                var tmp = std.testing.tmpDir(.{});
                const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
                defer allocator.free(root);
                defer {
                    tmp.cleanup();
                    std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, root, .{})) catch @panic("preflight fixture leaked");
                }
                const path = try std.fs.path.join(allocator, &.{ root, "memory.sqlite3" });
                defer allocator.free(path);
                var faults = memory.Faults{};
                var db = try memory.openWithFaults(allocator, path, &faults);
                defer {
                    std.testing.expect(c.sqlite3_next_stmt(@ptrCast(db.handle), null) == null) catch @panic("preflight statement leaked");
                    std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_close(@ptrCast(db.handle))) catch @panic("preflight database did not close");
                }
                const key = memory.Key{ .source_text = "first", .source_lang = .en, .target_lang = .ja, .mode = .default, .model_id = "test", .glossary_hash = 0 };
                try db.upsert(key, "saved");
                const before = try sys.readFileAlloc(allocator, path, 1024 * 1024);
                defer allocator.free(before);
                const steps_before = faults.count(.step);

                var malformed = case.bytes;
                var terms = [_]glossary.Term{ .{ .source = "first", .target = "先頭" }, .{ .source = "second", .target = "次", .comment = "note" } };
                var segments = [_]segment.Segment{ .{ .text = "first" }, .{ .text = "second" } };
                var ctx = TranslationContext{
                    .source_lang = .en,
                    .target_lang = .ja,
                    .mode = .default,
                    .model_id = "test",
                    .glossary_hash = 0,
                    .glossary = .{ .terms = &terms },
                    .db_opt = if (with_db) &db else null,
                    .cfg = config.default(),
                    .diagnostics_enabled = false,
                };
                switch (field) {
                    .source => segments[0].text = &malformed,
                    .later_source => segments[1].text = &malformed,
                    .protected => segments[1] = .{ .text = &malformed, .translatable = false },
                    .model_id => ctx.model_id = &malformed,
                    .glossary_source => terms[1].source = &malformed,
                    .glossary_target => terms[1].target = &malformed,
                    .glossary_comment => terms[1].comment = &malformed,
                }
                var counting = std.testing.FailingAllocator.init(allocator, .{});
                const result = translateSegments(counting.allocator(), &segments, ctx);
                if (result) |out| {
                    counting.allocator().free(out.translated_text);
                    std.debug.print("preflight {s} db={}: expected {s}, got success\n", .{ @tagName(field), with_db, @errorName(case.expected) });
                    failures += 1;
                } else |err| {
                    if (err != case.expected) {
                        std.debug.print("preflight {s} db={}: expected {s}, got {s}\n", .{ @tagName(field), with_db, @errorName(case.expected), @errorName(err) });
                        failures += 1;
                    }
                }
                const after = try sys.readFileAlloc(allocator, path, 1024 * 1024);
                defer allocator.free(after);
                if (!std.mem.eql(u8, before, after) or faults.count(.step) != steps_before) {
                    std.debug.print("preflight {s} db={}: database side effect\n", .{ @tagName(field), with_db });
                    failures += 1;
                }
                if (counting.allocated_bytes != 0) failures += 1;
                try std.testing.expectEqualSlices(u8, &case.bytes, &malformed);
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "result consumer frees failed partial payloads without appending or caching them" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "memory.sqlite3" });
    defer allocator.free(path);
    var db = try memory.open(allocator, path);
    defer db.close();
    var translated = std.array_list.Managed(u8).init(allocator);
    defer translated.deinit();
    const previous = memory.Key{ .source_text = "previous", .source_lang = .en, .target_lang = .ja, .mode = .default, .model_id = "test", .glossary_hash = 0 };
    try consumeResult(allocator, .{ .text = try allocator.dupe(u8, "saved"), .finish_reason = .eog }, &translated, &db, previous);

    for ([_]contract.FinishReason{ .context, .timeout, .decode }) |reason| {
        var session = backend.TestSession{ .model_id = "test", .fixture = .{ .text = "partial", .finish_reason = reason } };
        var failed_key = previous;
        failed_key.source_text = @tagName(reason);
        const result = try session.translate(allocator, .{
            .model_id = "test",
            .source_text = failed_key.source_text,
            .source_lang = .en,
            .target_lang = .ja,
            .prompt = "ignored",
            .timeout_sec = 1,
        });
        const expected_error = if (reason == .timeout) errors.Error.Timeout else errors.Error.LlamaDecodeFailed;
        const consumed = consumeResult(allocator, result, &translated, &db, failed_key);
        try std.testing.expectError(expected_error, consumed);
        if (consumed) |_| unreachable else |err| {
            const mapped = errors.fromError(err);
            try std.testing.expectEqual(if (reason == .timeout) errors.Code.timeout else errors.Code.llama_decode_failed, mapped.code);
            try std.testing.expectEqualStrings(if (reason == .timeout) "The operation timed out." else "Embedded llama.cpp generation failed.", mapped.message);
        }
        try std.testing.expectEqualStrings("saved", translated.items);
        try std.testing.expect(try db.lookup(failed_key) == null);
        try std.testing.expectEqual(@as(usize, 1), try db.count());
        const hit = (try db.lookup(previous)).?;
        defer allocator.free(hit.translated_text);
        try std.testing.expectEqualStrings("saved", hit.translated_text);
    }
}

test "translateSegments sqlite lookup and upsert failures retain prior rows and fresh fixtures recover" {
    if (!@import("build_options").test_backend) return error.SkipZigTest;
    const c = @cImport({
        @cInclude("sqlite3.h");
    });
    const allocator = std.testing.allocator;
    for ([_]usize{ 3, 4 }) |ordinal| {
        for ([_]bool{ true, false }) |inject| {
            var tmp = std.testing.tmpDir(.{});
            const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
            defer allocator.free(root);
            defer {
                tmp.cleanup();
                std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, root, .{})) catch @panic("translation fixture leaked");
            }
            const path = try std.fs.path.join(allocator, &.{ root, "memory.sqlite3" });
            defer allocator.free(path);
            var faults = memory.Faults{};
            defer faults.disarm();
            var db = try memory.openWithFaults(allocator, path, &faults);
            defer {
                std.testing.expect(c.sqlite3_next_stmt(@ptrCast(db.handle), null) == null) catch @panic("translation statement leaked");
                std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_close(@ptrCast(db.handle))) catch @panic("translation database did not close");
            }
            try std.testing.expectEqual(@as(usize, 1), faults.count(.open));
            try std.testing.expectEqual(@as(usize, 1), faults.count(.step));
            if (inject) try faults.arm(.step, ordinal, c.SQLITE_IOERR);
            var segments = [_]segment.Segment{ .{ .text = "first" }, .{ .text = "\n\n", .translatable = false }, .{ .text = "second" } };
            var cfg = config.default();
            cfg.model_id = "test";
            cfg.model_path = "unused-by-test-backend.gguf";
            const result = translateSegments(allocator, &segments, .{
                .source_lang = .en,
                .target_lang = .ja,
                .mode = .default,
                .model_id = cfg.model_id,
                .glossary_hash = 0,
                .glossary = .{ .terms = &.{} },
                .db_opt = &db,
                .cfg = cfg,
                .diagnostics_enabled = false,
            });
            if (result) |translated| {
                defer allocator.free(translated.translated_text);
                try std.testing.expect(!inject);
                try std.testing.expectEqualStrings("JA:first\n\nJA:second", translated.translated_text);
                try std.testing.expectEqual(@as(usize, 0), translated.cached_segments);
            } else |err| {
                try std.testing.expect(inject);
                try std.testing.expectEqual(errors.Error.SqliteFailed, err);
                const mapped = errors.fromError(err);
                try std.testing.expectEqual(errors.Code.sqlite_failed, mapped.code);
                try std.testing.expectEqualStrings("SQLite translation memory operation failed.", mapped.message);
            }
            try std.testing.expectEqual(@as(usize, 1) + if (inject) ordinal else @as(usize, 4), faults.count(.step));
            try std.testing.expectEqual(if (inject) @as(?c_int, c.SQLITE_IOERR) else null, faults.last_code);
            faults.disarm();

            var observer = try memory.openReadOnly(allocator, path);
            defer observer.close();
            try std.testing.expect(observer.faults == null);
            try std.testing.expectEqual(if (inject) @as(usize, 1) else @as(usize, 2), try observer.count());
            var rows = try memory.Stmt.prepare(&observer, "SELECT source_text, translated_text, hit_count FROM translations ORDER BY source_text");
            defer rows.deinit();
            const expected_rows: usize = if (inject) 1 else 2;
            for (0..expected_rows) |index| {
                try std.testing.expectEqual(c.SQLITE_ROW, try rows.step());
                const source = try rows.columnTextDup(0);
                defer allocator.free(source);
                const translated = try rows.columnTextDup(1);
                defer allocator.free(translated);
                try std.testing.expectEqualStrings(if (index == 0) "first" else "second", source);
                try std.testing.expectEqualStrings(if (index == 0) "JA:first" else "JA:second", translated);
                try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(@ptrCast(rows.handle), 2));
            }
            try std.testing.expectEqual(c.SQLITE_DONE, try rows.step());
            try std.testing.expectEqual(@as(usize, 1), faults.count(.open));
            try std.testing.expectEqual(@as(usize, 1) + if (inject) ordinal else @as(usize, 4), faults.count(.step));
        }
    }
}

test "result consumer accepts valid completed and token-limited text" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "memory.sqlite3" });
    defer allocator.free(path);
    var db = try memory.open(allocator, path);
    defer db.close();
    var translated = std.array_list.Managed(u8).init(allocator);
    defer translated.deinit();
    for ([_]contract.FinishReason{ .eog, .max_tokens }) |reason| {
        for ([_][]const u8{ "partial", "日本😀e\u{301}\u{feff}\x01\x1f", "", " \n\t" }, 0..) |bytes, index| {
            const source = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ @tagName(reason), index });
            defer allocator.free(source);
            const key = memory.Key{ .source_text = source, .source_lang = .en, .target_lang = .ja, .mode = .default, .model_id = "test", .glossary_hash = 0 };
            var session = backend.TestSession{ .model_id = "test", .fixture = .{ .text = bytes, .finish_reason = reason } };
            defer session.deinit();
            const result = try session.translate(allocator, .{ .model_id = "test", .source_text = source, .source_lang = .en, .target_lang = .ja, .prompt = "ignored", .timeout_sec = 1 });
            translated.clearRetainingCapacity();
            try consumeResult(allocator, result, &translated, &db, key);
            try std.testing.expectEqualSlices(u8, bytes, translated.items);
            const hit = (try db.lookup(key)).?;
            defer allocator.free(hit.translated_text);
            try std.testing.expectEqualSlices(u8, bytes, hit.translated_text);
            const uncached_result = try session.translate(allocator, .{ .model_id = "test", .source_text = source, .source_lang = .en, .target_lang = .ja, .prompt = "ignored", .timeout_sec = 1 });
            translated.clearRetainingCapacity();
            try consumeResult(allocator, uncached_result, &translated, null, key);
            try std.testing.expectEqualSlices(u8, bytes, translated.items);
        }
    }
    try std.testing.expectEqual(@as(usize, 8), try db.count());
}

test "result consumer rejects invalid accepted text before persistence" {
    for ([_]contract.FinishReason{ .eog, .max_tokens }) |reason| {
        try testRejectedResultBytes(reason);
    }
}

test "result consumer preserves finish error precedence for malformed bytes" {
    for ([_]contract.FinishReason{ .timeout, .context, .decode }) |reason| {
        try testRejectedResultBytes(reason);
    }
}

fn testRejectedResultBytes(reason: contract.FinishReason) !void {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |with_db| {
        var db = try memory.open(allocator, ":memory:");
        defer {
            const c = @cImport({
                @cInclude("sqlite3.h");
            });
            std.testing.expect(c.sqlite3_next_stmt(@ptrCast(db.handle), null) == null) catch @panic("consumer statement leaked");
            std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_close(@ptrCast(db.handle))) catch @panic("consumer database did not close");
        }
        const key = memory.Key{ .source_text = "previous", .source_lang = .en, .target_lang = .ja, .mode = .default, .model_id = "test", .glossary_hash = 0 };
        try db.upsert(key, "saved");
        const fixed_state = "UPDATE translations SET created_at=123, updated_at=456, hit_count=7";
        var update = try memory.Stmt.prepare(&db, fixed_state);
        defer update.deinit();
        _ = try update.step();
        var translated = std.array_list.Managed(u8).init(allocator);
        defer translated.deinit();
        try translated.appendSlice("prefix");
        for ([_][]const u8{ "\xff", "A\x00B", "\xe3\x81", "\xf0\x9f\x98" }) |bytes| {
            var session = backend.TestSession{ .model_id = "test", .fixture = .{ .text = bytes, .finish_reason = reason } };
            defer session.deinit();
            const result = try session.translate(allocator, .{ .model_id = "test", .source_text = key.source_text, .source_lang = .en, .target_lang = .ja, .prompt = "ignored", .timeout_sec = 1 });
            const expected: anyerror = switch (reason) {
                .timeout => error.Timeout,
                .context, .decode => error.LlamaDecodeFailed,
                .eog, .max_tokens => if (std.mem.indexOfScalar(u8, bytes, 0) != null) error.EmbeddedNul else error.InvalidUtf8,
            };
            try std.testing.expectError(expected, consumeResult(allocator, result, &translated, if (with_db) &db else null, key));
            try std.testing.expectEqualStrings("prefix", translated.items);
            try std.testing.expectEqual(@as(usize, 1), try db.count());
            var row = try memory.Stmt.prepare(&db, "SELECT source_text, translated_text, created_at, updated_at, hit_count FROM translations");
            defer row.deinit();
            _ = try row.step();
            for ([_][]const u8{ "previous", "saved", "123", "456", "7" }, 0..) |expected_field, index| {
                const field = try row.columnTextDup(@intCast(index));
                defer allocator.free(field);
                try std.testing.expectEqualStrings(expected_field, field);
            }
        }
    }
}
