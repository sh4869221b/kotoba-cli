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
const sys = @import("sys.zig");
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
    var translated = std.array_list.Managed(u8).init(allocator);
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
            .prompt = built_prompt,
            .timeout_sec = ctx.cfg.timeout_sec,
        });
        defer allocator.free(out);
        if (ctx.db_opt) |db| try db.upsert(key, out);
        try translated.appendSlice(out);
    }

    return .{
        .translated_text = try translated.toOwnedSlice(),
        .cached_segments = cached_segments,
    };
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
    const src_path = "/tmp/kotoba-translate-write-default.md";
    const out_path = "/tmp/kotoba-translate-write-default.ja.md";
    sys.deleteFile(src_path);
    sys.deleteFile(out_path);
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
    const out_path = "/tmp/kotoba-translate-write-exists.md";
    sys.deleteFile(out_path);
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
    }, .markdown, "/tmp/ignored.md", out_path, false));
}
