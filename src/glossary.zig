const std = @import("std");
const errors = @import("errors.zig");
const sys = @import("sys.zig");
const toml = @import("toml.zig");

pub const TermMode = enum { prefer, protect };

pub const Term = struct {
    source: []const u8 = "",
    target: []const u8 = "",
    mode: TermMode = .prefer,
    comment: []const u8 = "",
};

pub const Glossary = struct {
    terms: []Term,
};

pub fn defaultTemplate() []const u8 {
    return
    \\# Kotoba glossary.
    \\# [[terms]]
    \\# source = "CLI"
    \\# target = "CLI"
    \\# mode = "protect"
    \\# comment = "Do not translate this token."
    \\
    ;
}

pub fn ensure(path: []const u8) !void {
    if (!sys.exists(path)) try sys.writeFile(path, defaultTemplate());
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) !Glossary {
    const data = sys.readFileAlloc(allocator, path, 1024 * 1024) catch return .{ .terms = &.{} };
    defer allocator.free(data);
    return parse(allocator, data);
}

pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Glossary {
    var terms = std.array_list.Managed(Term).init(allocator);
    var current: ?Term = null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const clean = toml.trim(toml.stripComment(line));
        if (std.mem.eql(u8, clean, "[[terms]]")) {
            if (current) |t| try terms.append(t);
            current = .{};
            continue;
        }
        const p = toml.pair(line) orelse continue;
        if (current == null) continue;
        var t = current.?;
        const val = toml.unquote(p.value);
        if (std.mem.eql(u8, p.key, "source")) t.source = try allocator.dupe(u8, val) else if (std.mem.eql(u8, p.key, "target")) t.target = try allocator.dupe(u8, val) else if (std.mem.eql(u8, p.key, "mode")) {
            if (std.mem.eql(u8, val, "prefer")) t.mode = .prefer else if (std.mem.eql(u8, val, "protect")) t.mode = .protect else return errors.Error.GlossaryInvalid;
        } else if (std.mem.eql(u8, p.key, "comment")) t.comment = try allocator.dupe(u8, val);
        current = t;
    }
    if (current) |t| try terms.append(t);
    return .{ .terms = try terms.toOwnedSlice() };
}

pub fn hash(g: Glossary) u64 {
    var h = std.hash.Wyhash.init(0);
    for (g.terms) |t| {
        h.update(t.source);
        h.update(t.target);
        h.update(@tagName(t.mode));
    }
    return h.final();
}

test "glossary hash changes" {
    const g = try parse(std.heap.page_allocator,
        \\[[terms]]
        \\source = "CLI"
        \\target = "CLI"
        \\mode = "protect"
    );
    try std.testing.expect(hash(g) != 0);
}
