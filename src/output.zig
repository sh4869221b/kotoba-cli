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
            var out = std.array_list.Managed(u8).init(std.heap.page_allocator);
            defer out.deinit();
            try appendFmt(
                &out,
                "{{\"source_lang\":\"{s}\",\"target_lang\":\"{s}\",\"mode\":\"{s}\",\"model_id\":",
                .{ r.source_lang.asText(), r.target_lang.asText(), r.mode.asText() },
            );
            try appendJsonString(&out, r.model_id);
            try out.appendSlice(",\"runtime\":");
            try appendJsonString(&out, r.runtime);
            try appendFmt(&out, ",\"cached\":{},\"cache_status\":\"{s}\",\"cached_segments\":{d},\"total_segments\":{d},\"translated_text\":", .{ r.cached_segments == r.total_segments, cacheStatus(r), r.cached_segments, r.total_segments });
            try appendJsonString(&out, r.translated_text);
            try out.appendSlice(",\"warnings\":[");
            for (r.warnings, 0..) |warning, i| {
                if (i > 0) try out.append(',');
                try appendJsonString(&out, warning);
            }
            try appendFmt(&out, "],\"elapsed_ms\":{d}", .{r.elapsed_ms});
            if (include_source) {
                try out.appendSlice(",\"source_text\":");
                try appendJsonString(&out, r.source_text orelse "");
            }
            try out.appendSlice("}\n");
            sys.stdoutWrite(out.items);
        },
    }
}

fn appendFmt(out: *std.array_list.Managed(u8), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(out.allocator, fmt, args);
    defer out.allocator.free(text);
    try out.appendSlice(text);
}

fn appendJsonString(out: *std.array_list.Managed(u8), text: []const u8) !void {
    try out.append('"');
    for (text) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice("\\\\"),
            '"' => try out.appendSlice("\\\""),
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            else => try out.append(ch),
        }
    }
    try out.append('"');
}
