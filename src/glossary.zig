const std = @import("std");
const errors = @import("errors.zig");
const sys = @import("sys.zig");
const toml = @import("toml.zig");
const text = @import("text.zig");

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
    try text.validate(data);
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

test "glossary text contract preserves Unicode fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer _ = arena.deinit();

    const data =
        "# comment with 日本語😀 and e\u{301}\n" ++
        "[[terms]]\n" ++
        "source = \"CLI\"\n" ++
        "target = \"用語😀\"\n" ++
        "mode = \"protect\"\n" ++
        "comment = \"e\u{301}\"\n";
    const g = try parse(arena.allocator(), data);

    try std.testing.expectEqual(@as(usize, 1), g.terms.len);
    try std.testing.expectEqualStrings("CLI", g.terms[0].source);
    try std.testing.expectEqualStrings("用語😀", g.terms[0].target);
    try std.testing.expectEqual(TermMode.protect, g.terms[0].mode);
    try std.testing.expectEqualStrings("e\u{301}", g.terms[0].comment);
    try std.testing.expectEqual(@as(u64, 0xe9bd77e300dcdb49), hash(g));
}

test "glossary text contract rejects invalid documents before allocation" {
    const cases = [_]struct {
        name: []const u8,
        data: []const u8,
        expected: anyerror,
    }{
        .{
            .name = "source",
            .data = "[[terms]]\nsource = \"CLI\xFF\"\ntarget = \"用語\"\ncomment = \"注釈\"\n",
            .expected = error.InvalidUtf8,
        },
        .{
            .name = "target",
            .data = "[[terms]]\nsource = \"CLI\"\ntarget = \"用語\xFF\"\ncomment = \"注釈\"\n",
            .expected = error.InvalidUtf8,
        },
        .{
            .name = "comment",
            .data = "[[terms]]\nsource = \"CLI\"\ntarget = \"用語\"\ncomment = \"注釈\xFF\"\n",
            .expected = error.InvalidUtf8,
        },
        .{
            .name = "document comment",
            .data = "# コメント\xFF\n[[terms]]\nsource = \"CLI\"\ntarget = \"用語\"\n",
            .expected = error.InvalidUtf8,
        },
        .{
            .name = "source NUL",
            .data = "[[terms]]\nsource = \"CLI\x00\"\ntarget = \"用語\"\ncomment = \"注釈\"\n",
            .expected = error.EmbeddedNul,
        },
        .{
            .name = "target NUL",
            .data = "[[terms]]\nsource = \"CLI\"\ntarget = \"用語\x00\"\ncomment = \"注釈\"\n",
            .expected = error.EmbeddedNul,
        },
        .{
            .name = "comment NUL",
            .data = "[[terms]]\nsource = \"CLI\"\ntarget = \"用語\"\ncomment = \"注釈\x00\"\n",
            .expected = error.EmbeddedNul,
        },
        .{
            .name = "document comment NUL",
            .data = "# コメント\x00\n[[terms]]\nsource = \"CLI\"\ntarget = \"用語\"\n",
            .expected = error.EmbeddedNul,
        },
    };

    for (cases) |case| {
        _ = case.name;
        try std.testing.expectError(case.expected, parse(std.testing.allocator, case.data));
    }
}

test "glossary parser preserves invalid mode errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer _ = arena.deinit();

    try std.testing.expectError(errors.Error.GlossaryInvalid, parse(
        arena.allocator(),
        "[[terms]]\nsource = \"CLI\"\ntarget = \"用語\"\nmode = \"unknown\"\n",
    ));
}
