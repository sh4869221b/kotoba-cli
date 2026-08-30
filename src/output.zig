const std = @import("std");
const config = @import("config.zig");
const lang = @import("lang.zig");
const sys = @import("sys.zig");

/// Borrowed serializer view; its slices remain valid only while their owner lives.
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

/// Independent result graph. Move-only by convention; deinit invalidates all views.
pub const OwnedResult = struct {
    allocator: std.mem.Allocator,
    result: Result,

    pub fn clone(allocator: std.mem.Allocator, borrowed: Result) !OwnedResult {
        const translated = try allocator.dupe(u8, borrowed.translated_text);
        errdefer allocator.free(translated);
        const source = if (borrowed.source_text) |s| try allocator.dupe(u8, s) else null;
        errdefer if (source) |s| allocator.free(s);
        const model = try allocator.dupe(u8, borrowed.model_id);
        errdefer allocator.free(model);
        const runtime = try allocator.dupe(u8, borrowed.runtime);
        errdefer allocator.free(runtime);
        const warnings = try allocator.alloc([]const u8, borrowed.warnings.len);
        errdefer allocator.free(warnings);
        var initialized: usize = 0;
        errdefer for (warnings[0..initialized]) |warning| allocator.free(warning);
        for (borrowed.warnings, 0..) |warning, i| {
            warnings[i] = try allocator.dupe(u8, warning);
            initialized += 1;
        }
        var result = borrowed;
        result.translated_text = translated;
        result.source_text = source;
        result.model_id = model;
        result.runtime = runtime;
        result.warnings = warnings;
        return .{ .allocator = allocator, .result = result };
    }

    pub fn view(self: *const OwnedResult) Result {
        return self.result;
    }

    pub fn deinit(self: *OwnedResult) void {
        self.allocator.free(self.result.translated_text);
        if (self.result.source_text) |source| self.allocator.free(source);
        self.allocator.free(self.result.model_id);
        self.allocator.free(self.result.runtime);
        for (self.result.warnings) |warning| self.allocator.free(warning);
        self.allocator.free(self.result.warnings);
        self.* = undefined;
    }
};

pub fn cacheStatus(r: Result) []const u8 {
    if (r.cached_segments == 0) return "none";
    if (r.cached_segments == r.total_segments) return "full";
    return "partial";
}

pub fn write(fmt: config.OutputFormat, r: Result, include_source: bool) !void {
    switch (fmt) {
        .plain, .markdown => try sys.stdoutPrint("{s}\n", .{r.translated_text}),
        .json => {
            const json = try renderJson(std.heap.page_allocator, r, include_source);
            defer std.heap.page_allocator.free(json);
            try sys.stdoutWrite(json);
        },
    }
}

fn renderJson(allocator: std.mem.Allocator, r: Result, include_source: bool) ![]u8 {
    try validateResultText(r, include_source);
    if (include_source) {
        return jsonLineAlloc(allocator, .{
            .source_lang = r.source_lang.asText(),
            .target_lang = r.target_lang.asText(),
            .mode = r.mode.asText(),
            .model_id = r.model_id,
            .runtime = r.runtime,
            .cached = r.cached_segments == r.total_segments,
            .cache_status = cacheStatus(r),
            .cached_segments = r.cached_segments,
            .total_segments = r.total_segments,
            .translated_text = r.translated_text,
            .warnings = r.warnings,
            .elapsed_ms = r.elapsed_ms,
            .source_text = r.source_text orelse "",
        });
    }
    return jsonLineAlloc(allocator, .{
        .source_lang = r.source_lang.asText(),
        .target_lang = r.target_lang.asText(),
        .mode = r.mode.asText(),
        .model_id = r.model_id,
        .runtime = r.runtime,
        .cached = r.cached_segments == r.total_segments,
        .cache_status = cacheStatus(r),
        .cached_segments = r.cached_segments,
        .total_segments = r.total_segments,
        .translated_text = r.translated_text,
        .warnings = r.warnings,
        .elapsed_ms = r.elapsed_ms,
    });
}

pub fn jsonLineAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    stringify.write(value) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn validateResultText(r: Result, include_source: bool) !void {
    try validateJsonString(r.model_id);
    try validateJsonString(r.runtime);
    try validateJsonString(r.translated_text);
    for (r.warnings) |warning| try validateJsonString(warning);
    if (include_source) try validateJsonString(r.source_text orelse "");
}

pub fn validateJsonString(value: []const u8) error{InvalidUtf8}!void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
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

const json_text_fixture = "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1A\x1B\x1C\x1D\x1E\x1F\"\\日本語e\u{301}😀\u{FEFF}";

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

const ownership_fixture: Result = .{
    .source_lang = .en,
    .target_lang = .ja,
    .mode = .technical,
    .model_id = "owned-model",
    .runtime = "synthetic-runtime",
    .cached_segments = 1,
    .total_segments = 2,
    .translated_text = "translated",
    .source_text = "Hello",
    .warnings = &.{ "first warning", "second warning" },
    .elapsed_ms = 7,
};

test "ownership/result lifetime and serialization" {
    const a = std.testing.allocator;
    var owner: OwnedResult = undefined;
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var borrowed = ownership_fixture;
        borrowed.model_id = try arena.allocator().dupe(u8, borrowed.model_id);
        borrowed.runtime = try arena.allocator().dupe(u8, borrowed.runtime);
        borrowed.translated_text = try arena.allocator().dupe(u8, borrowed.translated_text);
        borrowed.source_text = try arena.allocator().dupe(u8, borrowed.source_text.?);
        const warnings = try arena.allocator().alloc([]const u8, 2);
        for (borrowed.warnings, 0..) |w, i| warnings[i] = try arena.allocator().dupe(u8, w);
        borrowed.warnings = warnings;
        owner = try OwnedResult.clone(a, borrowed);
        try std.testing.expect(arena.reset(.retain_capacity));
        @memset(try arena.allocator().alloc(u8, 2048), 'x');
    }
    defer owner.deinit();
    const expected = try renderJson(a, ownership_fixture, true);
    defer a.free(expected);
    const actual = try renderJson(a, owner.view(), true);
    defer a.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqualStrings("first warning", ownership_fixture.warnings[0]);
    std.debug.print("ownership/result lifetime reset=reused+destroyed fields=text,source,model,runtime,2warnings serialized=equal\n", .{});
}

fn exerciseResultClone(a: std.mem.Allocator, source: ?[]const u8, populated: bool, runs: *usize) !void {
    runs.* += 1;
    var borrowed = ownership_fixture;
    borrowed.source_text = source;
    if (!populated) {
        borrowed.translated_text = "";
        borrowed.model_id = "";
        borrowed.runtime = "";
        borrowed.warnings = &.{};
    }
    var owner = try OwnedResult.clone(a, borrowed);
    defer owner.deinit();
    try std.testing.expectEqualStrings(borrowed.translated_text, owner.view().translated_text);
    try std.testing.expectEqual(source == null, owner.view().source_text == null);
}

test "ownership/result oom" {
    var runs: usize = 0;
    for ([_]?[]const u8{ null, "", "Hello" }) |source| {
        for ([_]bool{ false, true }) |populated| {
            try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseResultClone, .{ source, populated, &runs });
        }
    }
    std.debug.print("ownership/result OOM exercise_invocations={d} optional=null,empty,populated warnings=0,2\n", .{runs});
}
