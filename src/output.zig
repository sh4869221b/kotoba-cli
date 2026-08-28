const std = @import("std");
const config = @import("config.zig");
const lang = @import("lang.zig");
const sys = @import("sys.zig");
const text = @import("text.zig");

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
    try text.validate(s);
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice("\\\""),
            '\\' => try out.appendSlice("\\\\"),
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            0...8, 11...12, 14...31 => {
                const hex = "0123456789abcdef";
                try out.appendSlice(&.{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0x0f] });
            },
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

const json_text_fixture = "\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1A\x1B\x1C\x1D\x1E\x1F\"\\日本語e\u{301}😀\u{FEFF}";

fn jsonTextResult() Result {
    return .{
        .source_lang = .en,
        .target_lang = .ja,
        .mode = .technical,
        .model_id = "model",
        .runtime = "embedded",
        .cached_segments = 1,
        .total_segments = 2,
        .translated_text = "translated",
        .warnings = &.{ "first", "second", "third" },
        .elapsed_ms = 42,
        .source_text = "source",
    };
}

fn expectJsonTextRoundTrip(r: Result, include_source: bool, json: []const u8) !void {
    try std.testing.expect(std.unicode.utf8ValidateSlice(json));
    try std.testing.expectEqual(@as(u8, '\n'), json[json.len - 1]);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    for (json[0 .. json.len - 1]) |byte| try std.testing.expect(byte >= 0x20);
    const object = parsed.value.object;
    try std.testing.expectEqual(@as(usize, if (include_source) 13 else 12), object.count());
    try std.testing.expectEqualStrings(r.source_lang.asText(), object.get("source_lang").?.string);
    try std.testing.expectEqualStrings(r.target_lang.asText(), object.get("target_lang").?.string);
    try std.testing.expectEqualStrings(r.mode.asText(), object.get("mode").?.string);
    inline for (.{ "model_id", "runtime", "translated_text" }) |field| {
        try std.testing.expectEqualStrings(@field(r, field), object.get(field).?.string);
    }
    try std.testing.expectEqual(r.cached_segments == r.total_segments, object.get("cached").?.bool);
    try std.testing.expectEqualStrings(cacheStatus(r), object.get("cache_status").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(r.cached_segments)), object.get("cached_segments").?.integer);
    try std.testing.expectEqual(@as(i64, @intCast(r.total_segments)), object.get("total_segments").?.integer);
    try std.testing.expectEqual(@as(i64, @intCast(r.elapsed_ms)), object.get("elapsed_ms").?.integer);
    const warnings = object.get("warnings").?.array.items;
    try std.testing.expectEqual(r.warnings.len, warnings.len);
    for (r.warnings, warnings) |expected, actual| try std.testing.expectEqualStrings(expected, actual.string);
    if (include_source) {
        try std.testing.expectEqualStrings(r.source_text orelse "", object.get("source_text").?.string);
    } else {
        try std.testing.expect(!object.contains("source_text"));
    }
}

test "JSON text contract round trips every emitted variable field" {
    inline for (.{ "model_id", "runtime", "translated_text", "source_text" }) |field| {
        var r = jsonTextResult();
        @field(r, field) = json_text_fixture;
        const json = try renderJson(std.testing.allocator, r, true);
        defer std.testing.allocator.free(json);
        try expectJsonTextRoundTrip(r, true, json);
    }
    for (0..3) |index| {
        var warnings: [3][]const u8 = .{ "first", "second", "third" };
        warnings[index] = json_text_fixture;
        var r = jsonTextResult();
        r.warnings = &warnings;
        const json = try renderJson(std.testing.allocator, r, true);
        defer std.testing.allocator.free(json);
        try expectJsonTextRoundTrip(r, true, json);
    }
}

test "JSON text contract rejects invalid emitted fields" {
    const cases = [_]struct { bytes: []const u8, expected: anyerror }{
        .{ .bytes = "A\xFFB", .expected = error.InvalidUtf8 },
        .{ .bytes = "A\x00B", .expected = error.EmbeddedNul },
        .{ .bytes = "\x00\xFF", .expected = error.InvalidUtf8 },
        .{ .bytes = "\xE3\x81", .expected = error.InvalidUtf8 },
    };
    for (cases) |case| {
        inline for (.{ "model_id", "runtime", "translated_text", "source_text" }) |field| {
            var r = jsonTextResult();
            @field(r, field) = case.bytes;
            const rendered = renderJson(std.testing.allocator, r, true);
            defer if (rendered) |json| std.testing.allocator.free(json) else |_| {};
            try std.testing.expectError(case.expected, rendered);
        }
        for (0..3) |index| {
            var warnings: [3][]const u8 = .{ "first", "second", "third" };
            warnings[index] = case.bytes;
            var r = jsonTextResult();
            r.warnings = &warnings;
            const rendered = renderJson(std.testing.allocator, r, true);
            defer if (rendered) |json| std.testing.allocator.free(json) else |_| {};
            try std.testing.expectError(case.expected, rendered);
        }
        var omitted = jsonTextResult();
        omitted.source_text = case.bytes;
        const json = try renderJson(std.testing.allocator, omitted, false);
        defer std.testing.allocator.free(json);
        try expectJsonTextRoundTrip(omitted, false, json);
    }
    var absent = jsonTextResult();
    absent.source_text = null;
    const json = try renderJson(std.testing.allocator, absent, true);
    defer std.testing.allocator.free(json);
    try expectJsonTextRoundTrip(absent, true, json);
}

fn checkJsonTextAllocations(allocator: std.mem.Allocator) !void {
    var r = jsonTextResult();
    r.model_id = json_text_fixture;
    r.runtime = json_text_fixture;
    r.translated_text = json_text_fixture;
    r.source_text = json_text_fixture;
    r.warnings = &.{ json_text_fixture, json_text_fixture, json_text_fixture };
    const json = try renderJson(allocator, r, true);
    defer allocator.free(json);
    try expectJsonTextRoundTrip(r, true, json);
}

test "JSON text contract frees partial buffers on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkJsonTextAllocations, .{});
}
