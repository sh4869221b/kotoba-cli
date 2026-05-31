const std = @import("std");
const config = @import("config.zig");
const lang = @import("lang.zig");
const sys = @import("sys.zig");

pub const Result = struct {
    source_lang: lang.Language,
    target_lang: lang.Language,
    mode: config.Mode,
    model_id: []const u8,
    runtime: []const u8,
    cached_segments: usize,
    total_segments: usize,
    translated_text: []const u8,
    warnings: []const []const u8 = &.{},
    elapsed_ms: u64,
    source_text: ?[]const u8 = null,
};

pub fn cacheStatus(r: Result) []const u8 {
    if (r.cached_segments == 0) return "none";
    if (r.cached_segments == r.total_segments) return "full";
    return "partial";
}

pub fn write(fmt: config.OutputFormat, r: Result, include_source: bool) !void {
    switch (fmt) {
        .plain, .markdown => sys.stdoutPrint("{s}\n", .{r.translated_text}),
        .json => {
            const json = try renderJson(std.heap.page_allocator, r, include_source);
            defer std.heap.page_allocator.free(json);
            sys.stdoutWrite(json);
        },
    }
}

fn renderJson(allocator: std.mem.Allocator, r: Result, include_source: bool) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    const cached_segs = try std.fmt.allocPrint(allocator, "{}", .{r.cached_segments});
    defer allocator.free(cached_segs);
    const total_segs = try std.fmt.allocPrint(allocator, "{}", .{r.total_segments});
    defer allocator.free(total_segs);
    const elapsed = try std.fmt.allocPrint(allocator, "{}", .{r.elapsed_ms});
    defer allocator.free(elapsed);

    try out.appendSlice("{\"source_lang\":\"");
    try escapeJsonString(r.source_lang.asText(), &out);
    try out.appendSlice("\",\"target_lang\":\"");
    try escapeJsonString(r.target_lang.asText(), &out);
    try out.appendSlice("\",\"mode\":\"");
    try escapeJsonString(r.mode.asText(), &out);
    try out.appendSlice("\",\"model_id\":\"");
    try escapeJsonString(r.model_id, &out);
    try out.appendSlice("\",\"runtime\":\"");
    try escapeJsonString(r.runtime, &out);
    try out.appendSlice("\",\"cached\":");
    try out.appendSlice(if (r.cached_segments == r.total_segments) "true" else "false");
    try out.appendSlice(",\"cache_status\":\"");
    try out.appendSlice(cacheStatus(r));
    try out.appendSlice("\",\"cached_segments\":");
    try out.appendSlice(cached_segs);
    try out.appendSlice(",\"total_segments\":");
    try out.appendSlice(total_segs);
    try out.appendSlice(",\"translated_text\":\"");
    try escapeJsonString(r.translated_text, &out);
    try out.appendSlice("\",\"warnings\":[");
    for (r.warnings, 0..) |warning, i| {
        if (i > 0) try out.append(',');
        try out.append('"');
        try escapeJsonString(warning, &out);
        try out.append('"');
    }
    try out.appendSlice("],\"elapsed_ms\":");
    try out.appendSlice(elapsed);
    if (include_source) {
        try out.appendSlice(",\"source_text\":\"");
        try escapeJsonString(r.source_text orelse "", &out);
        try out.append('"');
    }
    try out.append('}');
    try out.append('\n');

    return out.toOwnedSlice();
}

fn escapeJsonString(s: []const u8, out: *std.array_list.Managed(u8)) !void {
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice("\\\""),
            '\\' => try out.appendSlice("\\\\"),
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            else => try out.append(c),
        }
    }
}

test "cacheStatus reports none partial full" {
    const base: Result = .{
        .source_lang = .en,
        .target_lang = .ja,
        .mode = .default,
        .model_id = "m",
        .runtime = "embedded",
        .cached_segments = 0,
        .total_segments = 3,
        .translated_text = "こんにちは",
        .elapsed_ms = 1,
    };
    try std.testing.expectEqualStrings("none", cacheStatus(base));

    var partial = base;
    partial.cached_segments = 1;
    try std.testing.expectEqualStrings("partial", cacheStatus(partial));

    var full = base;
    full.cached_segments = 3;
    try std.testing.expectEqualStrings("full", cacheStatus(full));
}

test "renderJson escapes quotes backslashes and control characters" {
    const r: Result = .{
        .source_lang = .en,
        .target_lang = .ja,
        .mode = .default,
        .model_id = "model\"\\id",
        .runtime = "rt\n\t",
        .cached_segments = 1,
        .total_segments = 2,
        .translated_text = "line1\nline2\t\\\"",
        .warnings = &.{ "warn\"1", "back\\slash" },
        .elapsed_ms = 42,
        .source_text = "src\rtext",
    };

    const json = try renderJson(std.testing.allocator, r, true);
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings("{\"source_lang\":\"en\",\"target_lang\":\"ja\",\"mode\":\"default\",\"model_id\":\"model\\\"\\\\id\",\"runtime\":\"rt\\n\\t\",\"cached\":false,\"cache_status\":\"partial\",\"cached_segments\":1,\"total_segments\":2,\"translated_text\":\"line1\\nline2\\t\\\\\\\"\",\"warnings\":[\"warn\\\"1\",\"back\\\\slash\"],\"elapsed_ms\":42,\"source_text\":\"src\\rtext\"}\n", json);
}

test "renderJson omits source_text when include_source is false" {
    const r: Result = .{
        .source_lang = .en,
        .target_lang = .ja,
        .mode = .technical,
        .model_id = "m",
        .runtime = "embedded",
        .cached_segments = 1,
        .total_segments = 1,
        .translated_text = "translated",
        .warnings = &.{},
        .elapsed_ms = 0,
        .source_text = "should not appear",
    };

    const json = try renderJson(std.testing.allocator, r, false);
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings("{\"source_lang\":\"en\",\"target_lang\":\"ja\",\"mode\":\"technical\",\"model_id\":\"m\",\"runtime\":\"embedded\",\"cached\":true,\"cache_status\":\"full\",\"cached_segments\":1,\"total_segments\":1,\"translated_text\":\"translated\",\"warnings\":[],\"elapsed_ms\":0}\n", json);
}
