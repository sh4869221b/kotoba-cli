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
};

pub fn run(allocator: std.mem.Allocator, paths: xdg.Paths, cfg: config.Config, opts: Options) !output.Result {
    if (cfg.model_id.len == 0 or cfg.model_path.len == 0) return errors.Error.ModelNotSelected;
    const start = sys.millis();
    const read_result = try input.read(allocator, opts.text, opts.file_path);
    const read_kind = readKindForOptions(opts.format, opts.file_path);
    const g = if (!opts.no_glossary and cfg.glossary_enabled) try glossary.load(allocator, paths.glossary_file) else glossary.Glossary{ .terms = &.{} };
    const pair = try lang.resolve(opts.source_lang, opts.target_lang, cfg.default_source_lang, cfg.default_target_lang, read_result.text);
    const mode = opts.mode orelse cfg.default_mode;
    var warnings = std.array_list.Managed([]const u8).init(allocator);

    var protected_doc: ?markdown.Document = null;
    const source_for_segments = if (read_kind == .markdown) blk: {
        protected_doc = try markdown.protect(allocator, read_result.text);
        break :blk protected_doc.?.text;
    } else read_result.text;

    const segments = try segment.splitParagraphs(allocator, source_for_segments);
    var db_opt: ?memory.Db = null;
    if (cfg.memory_enabled and !opts.no_memory) {
        db_opt = memory.open(allocator, paths.memory_file) catch null;
    }
    defer if (db_opt) |*db| db.close();

    var translated = std.array_list.Managed(u8).init(allocator);
    var cached_segments: usize = 0;
    const gh = glossary.hash(g);
    var session: ?backend.Session = null;
    defer if (session) |*s| s.deinit();
    for (segments) |seg| {
        if (!seg.translatable) {
            try translated.appendSlice(seg.text);
            continue;
        }
        const key = memory.Key{ .source_text = seg.text, .source_lang = pair.source, .target_lang = pair.target, .mode = mode, .model_id = cfg.model_id, .glossary_hash = gh };
        if (db_opt) |*db| {
            if (try db.lookup(key)) |hit| {
                defer allocator.free(hit.translated_text);
                cached_segments += 1;
                try translated.appendSlice(hit.translated_text);
                continue;
            }
        }
        const built_prompt = try prompt.build(allocator, pair.source, pair.target, mode, g, seg.text);
        defer allocator.free(built_prompt);
        if (session == null) session = try backend.init(allocator, cfg);
        const out = try session.?.translate(allocator, .{
            .model_id = cfg.model_id,
            .prompt = built_prompt,
            .timeout_sec = cfg.timeout_sec,
        });
        defer allocator.free(out);
        if (db_opt) |*db| try db.upsert(key, out);
        try translated.appendSlice(out);
    }
    var final_text = try translated.toOwnedSlice();
    if (protected_doc) |doc| {
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
        .cached_segments = cached_segments,
        .total_segments = segments.len,
        .translated_text = final_text,
        .warnings = try warnings.toOwnedSlice(),
        .elapsed_ms = elapsed,
        .source_text = read_result.text,
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

pub fn writeFileIfNeeded(allocator: std.mem.Allocator, res: output.Result, read_kind: input.Kind, file_path: ?[]const u8, explicit_output: ?[]const u8, overwrite: bool) !bool {
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
