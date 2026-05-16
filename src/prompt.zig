const std = @import("std");
const config = @import("config.zig");
const glossary = @import("glossary.zig");
const lang = @import("lang.zig");

pub fn build(allocator: std.mem.Allocator, source: lang.Language, target: lang.Language, mode: config.Mode, g: glossary.Glossary, text: []const u8) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    try appendFmt(allocator, &buf, "Translate from {s} to {s}. Return only the translation.\n", .{ source.asText(), target.asText() });
    try buf.appendSlice("Preserve KOTOBA_PROTECT_* tokens exactly. Do not add commentary.\n");
    if (mode == .technical) {
        try buf.appendSlice("Technical mode: preserve Markdown structure, identifiers, commands, code, paths, and technical meaning.\n");
    }
    if (g.terms.len > 0) {
        try buf.appendSlice("Glossary:\n");
        for (g.terms) |t| {
            try appendFmt(allocator, &buf, "- {s} => {s} ({s})\n", .{ t.source, t.target, @tagName(t.mode) });
        }
    }
    try buf.appendSlice("\nText:\n");
    try buf.appendSlice(text);
    return buf.toOwnedSlice();
}

fn appendFmt(allocator: std.mem.Allocator, buf: *std.array_list.Managed(u8), comptime fmt: []const u8, args: anytype) !void {
    const tmp = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(tmp);
    try buf.appendSlice(tmp);
}

test "prompt includes glossary" {
    const g = try glossary.parse(std.heap.page_allocator,
        \\[[terms]]
        \\source = "CLI"
        \\target = "CLI"
        \\mode = "protect"
    );
    const p = try build(std.testing.allocator, .en, .ja, .technical, g, "Hello `CLI`");
    defer std.testing.allocator.free(p);
    try std.testing.expect(std.mem.indexOf(u8, p, "CLI") != null);
}
