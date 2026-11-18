const std = @import("std");
const errors = @import("errors.zig");
const sys = @import("sys.zig");
const strict = @import("strict_toml.zig");
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
    const next = try decodeValue(allocator, value);
    allocator.free(field.*);
    field.* = next;
}

fn decodeValue(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const trimmed = toml.trim(value);
    if (trimmed.len > 0 and (trimmed[0] == '"' or trimmed[0] == '\'')) {
        return strict.parseString(allocator, trimmed) catch |err| switch (err) {
            error.Invalid => errors.Error.GlossaryInvalid,
            error.OutOfMemory => err,
        };
    }
    return allocator.dupe(u8, toml.trim(toml.stripComment(trimmed)));
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
    const data = sys.readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => switch (try sys.pathState(path)) {
            .not_found => return .{ .allocator = allocator, .value = .{ .terms = &.{} } },
            .present => return err,
        },
        else => return err,
    };
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
    var reader: strict.Reader = .{ .data = data };
    while (reader.next() catch return errors.Error.GlossaryInvalid) |line| {
        const p = switch (line) {
            .header => |header| {
                if (!header.array or !std.mem.eql(u8, header.name, "terms")) return errors.Error.GlossaryInvalid;
                if (current) |t| {
                    try terms.append(t);
                    current = null;
                }
                current = try termDefaults(allocator);
                continue;
            },
            .pair => |pair| pair,
        };
        if (current == null) return errors.Error.GlossaryInvalid;
        const t = &current.?;
        if (std.mem.eql(u8, p.key, "source")) try replaceString(allocator, &t.source, p.value) else if (std.mem.eql(u8, p.key, "target")) try replaceString(allocator, &t.target, p.value) else if (std.mem.eql(u8, p.key, "mode")) {
            const val = try decodeValue(allocator, p.value);
            defer allocator.free(val);
            if (std.mem.eql(u8, val, "prefer")) t.mode = .prefer else if (std.mem.eql(u8, val, "protect")) t.mode = .protect else return errors.Error.GlossaryInvalid;
        } else if (std.mem.eql(u8, p.key, "comment")) try replaceString(allocator, &t.comment, p.value);
    }
    if (current) |t| {
        try terms.append(t);
        current = null;
    }
    return .{ .allocator = allocator, .value = .{ .terms = try terms.toOwnedSlice() } };
}

/// Fingerprint the fields in the order they are sent to the model.
pub fn fingerprint(g: Glossary) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("kotoba-glossary-v1\x00");
    for (g.terms) |t| {
        hashField(&hasher, t.source);
        hashField(&hasher, t.target);
        hashField(&hasher, @tagName(t.mode));
    }
    return hasher.finalResult();
}

fn hashField(hasher: *std.crypto.hash.sha2.Sha256, field: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, field.len, .big);
    hasher.update(&length);
    hasher.update(field);
}

test "glossary fingerprint distinguishes field boundaries and prompt semantics" {
    var terms = [_]Term{.{ .source = "ab", .target = "c" }};
    const g = Glossary{ .terms = &terms };
    const first = fingerprint(g);
    terms[0].comment = "not in the prompt";
    try std.testing.expectEqual(first, fingerprint(g));
    terms[0] = .{ .source = "a", .target = "bc" };
    const second = fingerprint(g);
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
    terms[0].mode = .protect;
    try std.testing.expect(!std.mem.eql(u8, &second, &fingerprint(g)));
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
    try std.testing.expectEqual(fingerprint(.{ .terms = &literal_terms }), fingerprint(owner.view()));
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

test "glossary load allows absence and propagates read errors" {
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
    try std.testing.expectError(error.IsDir, load(a, root));
    const oversized = try a.alloc(u8, 1024 * 1024 + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    try sys.writeFile(path, oversized);
    try std.testing.expectError(error.StreamTooLong, load(a, path));
    try sys.writeFile(path, ownership_fixture);
    var loaded = try load(a, path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("new", loaded.view().terms[0].source);
    const file = try tmp.dir.openFile(std.testing.io, "glossary.toml", .{});
    defer file.close(std.testing.io);
    try file.setPermissions(std.testing.io, .fromMode(0));
    defer file.setPermissions(std.testing.io, .fromMode(0o600)) catch unreachable;
    // Privileged test runners may still be able to open a mode-000 file.
    if (sys.cwd().access(sys.io(), path, .{ .read = true })) |_| {} else |err| {
        try std.testing.expectError(err, load(a, path));
    }
}

test "glossary validates array headers and allows spacing and comments" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "[[terms]", "[terms]", "[[term]]", "[[terms]] stray", "terms]]" }) |header| {
        const malformed = try std.fmt.allocPrint(allocator, "{s}\nsource = 'CLI'\n", .{header});
        defer allocator.free(malformed);
        try std.testing.expectError(errors.Error.GlossaryInvalid, parse(allocator, malformed));
    }
    var glossary = try parse(allocator, " [[ terms ]] # term\r\nsource = \"CLI\" # kept\r\n");
    defer glossary.deinit();
    try std.testing.expectEqualStrings("CLI", glossary.view().terms[0].source);
}

test "glossary requires quoted values to end and keeps quoted comment characters" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "\"CLI", "'CLI", "\"CLI\" extra", "\"trailing\\\"" }) |value| {
        const document = try std.fmt.allocPrint(allocator, "[[terms]]\nsource={s}\ntarget=\"tool\"\n", .{value});
        defer allocator.free(document);
        try std.testing.expectError(error.GlossaryInvalid, parse(allocator, document));
    }
    var owner = try parse(allocator, "[[terms]]\nsource=\"C\\\"LI#\" # comment\ntarget='tool#'\nmode=prefer\n");
    defer owner.deinit();
    const term = owner.view().terms[0];
    try std.testing.expectEqualStrings("C\"LI#", term.source);
    try std.testing.expectEqualStrings("tool#", term.target);
    try std.testing.expectEqual(TermMode.prefer, term.mode);
}
