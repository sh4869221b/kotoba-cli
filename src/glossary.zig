const std = @import("std");
const errors = @import("errors.zig");
const sys = @import("sys.zig");
const toml = @import("toml.zig");
const text = @import("text.zig");

pub const TermMode = enum { prefer, protect };

/// Borrowed fields; literals are valid and must not be freed as owners.
pub const Term = struct {
    source: []const u8 = "",
    target: []const u8 = "",
    mode: TermMode = .prefer,
    comment: []const u8 = "",
};

pub const Glossary = struct {
    terms: []Term,
};

/// Owns every term string and the array; move-only by convention.
pub const OwnedGlossary = struct {
    allocator: std.mem.Allocator,
    value: Glossary,

    /// Borrowed until deinit; callers must not free the view's fields.
    pub fn view(self: *const OwnedGlossary) Glossary {
        return self.value;
    }

    pub fn deinit(self: *OwnedGlossary) void {
        for (self.value.terms) |term| freeTerm(self.allocator, term);
        self.allocator.free(self.value.terms);
        self.* = undefined;
    }
};

fn termDefaults(allocator: std.mem.Allocator) !Term {
    const source = try allocator.dupe(u8, "");
    errdefer allocator.free(source);
    const target = try allocator.dupe(u8, "");
    errdefer allocator.free(target);
    const comment = try allocator.dupe(u8, "");
    return .{ .source = source, .target = target, .comment = comment };
}

fn freeTerm(allocator: std.mem.Allocator, term: Term) void {
    allocator.free(term.source);
    allocator.free(term.target);
    allocator.free(term.comment);
}

fn replaceString(allocator: std.mem.Allocator, field: *[]const u8, value: []const u8) !void {
    const next = try allocator.dupe(u8, value);
    allocator.free(field.*);
    field.* = next;
}

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

pub fn load(allocator: std.mem.Allocator, path: []const u8) !OwnedGlossary {
    const data = sys.readFileAlloc(allocator, path, 1024 * 1024) catch return .{ .allocator = allocator, .value = .{ .terms = &.{} } };
    defer allocator.free(data);
    return parse(allocator, data);
}

pub fn parse(allocator: std.mem.Allocator, data: []const u8) !OwnedGlossary {
    try text.validate(data);
    var terms = std.array_list.Managed(Term).init(allocator);
    errdefer {
        for (terms.items) |term| freeTerm(allocator, term);
        terms.deinit();
    }
    var current: ?Term = null;
    errdefer if (current) |term| freeTerm(allocator, term);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const clean = toml.trim(toml.stripComment(line));
        if (std.mem.eql(u8, clean, "[[terms]]")) {
            if (current) |t| {
                try terms.append(t);
                current = null;
            }
            current = try termDefaults(allocator);
            continue;
        }
        const p = toml.pair(line) orelse continue;
        if (current == null) continue;
        const t = &current.?;
        const val = toml.unquote(p.value);
        if (std.mem.eql(u8, p.key, "source")) try replaceString(allocator, &t.source, val) else if (std.mem.eql(u8, p.key, "target")) try replaceString(allocator, &t.target, val) else if (std.mem.eql(u8, p.key, "mode")) {
            if (std.mem.eql(u8, val, "prefer")) t.mode = .prefer else if (std.mem.eql(u8, val, "protect")) t.mode = .protect else return errors.Error.GlossaryInvalid;
        } else if (std.mem.eql(u8, p.key, "comment")) try replaceString(allocator, &t.comment, val);
    }
    if (current) |t| {
        try terms.append(t);
        current = null;
    }
    return .{ .allocator = allocator, .value = .{ .terms = try terms.toOwnedSlice() } };
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
    var owner = try parse(std.testing.allocator,
        \\[[terms]]
        \\source = "CLI"
        \\target = "CLI"
        \\mode = "protect"
    );
    defer owner.deinit();
    const g = owner.view();
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
    var owner = try parse(arena.allocator(), data);
    defer owner.deinit();
    const g = owner.view();

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

const ownership_fixture = "[[terms]]\nsource = \"old\"\nsource = \"new\"\ntarget = \"target\"\ncomment = \"comment\"\n";

test "ownership/glossary lifecycle repeated fields and source lifetime" {
    const a = std.testing.allocator;
    const data = try a.dupe(u8, ownership_fixture);
    var owner = parse(a, data) catch |err| {
        a.free(data);
        return err;
    };
    a.free(data);
    defer owner.deinit();
    try std.testing.expectEqualStrings("new", owner.view().terms[0].source);
    try std.testing.expectEqualStrings("target", owner.view().terms[0].target);
    try std.testing.expectEqualStrings("comment", owner.view().terms[0].comment);
    var literal_terms = [_]Term{.{ .source = "new", .target = "target", .comment = "comment" }};
    try std.testing.expectEqual(hash(.{ .terms = &literal_terms }), hash(owner.view()));
}

fn exerciseGlossary(backing: std.mem.Allocator, data: []const u8, invalid: bool, runs: *usize) !void {
    runs.* += 1;
    var no_resize = std.testing.FailingAllocator.init(backing, .{ .resize_fail_index = 0 });
    var owner = parse(no_resize.allocator(), data) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (!invalid) return err;
        try std.testing.expectEqual(error.GlossaryInvalid, err);
        return;
    };
    defer owner.deinit();
    try std.testing.expect(!invalid);
}

test "ownership/glossary oom defaults repeated values append and partial graph" {
    var runs: usize = 0;
    for ([_][]const u8{ "", "[[terms]]", ownership_fixture ** 9, ownership_fixture ++ "target = \"next target\"\ncomment = \"next comment\"\n" ++ ownership_fixture, ownership_fixture ++ "[[terms]]\nsource = \"second\"\ntarget = \"target\"\nmode = \"invalid\"" }) |data| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseGlossary, .{ data, std.mem.endsWith(u8, data, "\"invalid\""), &runs });
    }
    try std.testing.expect(runs > 10);
    std.debug.print("glossary exhaustive exercise invocations={d}\n", .{runs});
}

test "ownership/glossary oom replacement preserves old field" {
    const a = std.testing.allocator;
    var previous: []const u8 = try a.dupe(u8, "previous");
    defer a.free(previous);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, replaceString(failing.allocator(), &previous, "next"));
    try std.testing.expectEqualStrings("previous", previous);
}

test "ownership/glossary lifecycle load preserves broad read failure fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "glossary.toml" });
    defer a.free(path);
    var missing = try load(a, path);
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.view().terms.len);
    var directory = try load(a, root);
    defer directory.deinit();
    try std.testing.expectEqual(@as(usize, 0), directory.view().terms.len);
    try sys.writeFile(path, ownership_fixture);
    var loaded = try load(a, path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("new", loaded.view().terms[0].source);
    const file = try tmp.dir.openFile(std.testing.io, "glossary.toml", .{});
    defer file.close(std.testing.io);
    try file.setPermissions(std.testing.io, .fromMode(0));
    defer file.setPermissions(std.testing.io, .fromMode(0o600)) catch unreachable;
    var denied = try load(a, path);
    defer denied.deinit();
    try std.testing.expectEqual(@as(usize, 0), denied.view().terms.len);
}
