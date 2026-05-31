const std = @import("std");
const errors = @import("errors.zig");
const lang = @import("lang.zig");
const config = @import("config.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Key = struct {
    source_text: []const u8,
    source_lang: lang.Language,
    target_lang: lang.Language,
    mode: config.Mode,
    model_id: []const u8,
    glossary_hash: u64,
};

pub const Hit = struct {
    translated_text: []const u8,
};

pub const Stmt = struct {
    handle: *c.sqlite3_stmt,
    allocator: std.mem.Allocator,
    pub fn prepare(db: *Db, sql: []const u8) !Stmt {
        var handle: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db.handle, sql.ptr, @intCast(sql.len), &handle, null) != c.SQLITE_OK) return errors.Error.SqliteFailed;
        return .{ .handle = handle orelse return errors.Error.SqliteFailed, .allocator = db.allocator };
    }

    pub fn deinit(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    pub fn bindText(self: *Stmt, idx: c_int, text: []const u8) !void {
        if (c.sqlite3_bind_text(self.handle, idx, text.ptr, @intCast(text.len), c.SQLITE_TRANSIENT) != c.SQLITE_OK) return errors.Error.SqliteFailed;
    }

    pub fn step(self: *Stmt) !c_int {
        const rc = c.sqlite3_step(self.handle);
        return switch (rc) {
            c.SQLITE_ROW, c.SQLITE_DONE => rc,
            else => errors.Error.SqliteFailed,
        };
    }

    pub fn columnTextDup(self: *Stmt, idx: c_int) ![]u8 {
        const ptr = c.sqlite3_column_text(self.handle, idx) orelse return errors.Error.SqliteFailed;
        const text = std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
        return self.allocator.dupe(u8, text);
    }
};

pub const Db = struct {
    handle: *c.sqlite3,
    allocator: std.mem.Allocator,

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    pub fn initSchema(self: *Db) !void {
        const sql =
            \\CREATE TABLE IF NOT EXISTS translations (
            \\source_hash TEXT NOT NULL,
            \\source_text TEXT NOT NULL,
            \\translated_text TEXT NOT NULL,
            \\source_lang TEXT NOT NULL,
            \\target_lang TEXT NOT NULL,
            \\mode TEXT NOT NULL,
            \\model_id TEXT NOT NULL,
            \\glossary_hash TEXT NOT NULL,
            \\created_at INTEGER NOT NULL,
            \\updated_at INTEGER NOT NULL,
            \\hit_count INTEGER NOT NULL DEFAULT 0,
            \\PRIMARY KEY (source_hash, source_lang, target_lang, mode, model_id, glossary_hash)
            \\);
        ;
        var stmt = try Stmt.prepare(self, sql);
        errdefer stmt.deinit();
        if (try stmt.step() != c.SQLITE_DONE) return errors.Error.SqliteFailed;
        stmt.deinit();
    }

    pub fn lookup(self: *Db, key: Key) !?Hit {
        const hash_text = try sourceHash(self.allocator, key.source_text);
        defer self.allocator.free(hash_text);
        const gh = try std.fmt.allocPrint(self.allocator, "{x}", .{key.glossary_hash});
        defer self.allocator.free(gh);

        const sql = "SELECT translated_text FROM translations WHERE source_hash=? AND source_lang=? AND target_lang=? AND mode=? AND model_id=? AND glossary_hash=?;";
        var stmt = try Stmt.prepare(self, sql);
        defer stmt.deinit();
        try bindKey(&stmt, key, hash_text, gh);

        const rc = try stmt.step();
        if (rc == c.SQLITE_ROW) {
            const text = try stmt.columnTextDup(0);
            errdefer self.allocator.free(text);
            try self.bump(key);
            return .{ .translated_text = text };
        }
        return null;
    }

    fn bump(self: *Db, key: Key) !void {
        const hash_text = try sourceHash(self.allocator, key.source_text);
        defer self.allocator.free(hash_text);
        const gh = try std.fmt.allocPrint(self.allocator, "{x}", .{key.glossary_hash});
        defer self.allocator.free(gh);

        const sql = "UPDATE translations SET hit_count=hit_count+1, updated_at=strftime('%s','now') WHERE source_hash=? AND source_lang=? AND target_lang=? AND mode=? AND model_id=? AND glossary_hash=?;";
        var stmt = try Stmt.prepare(self, sql);
        defer stmt.deinit();
        try bindKey(&stmt, key, hash_text, gh);
        if (try stmt.step() != c.SQLITE_DONE) return errors.Error.SqliteFailed;
    }

    pub fn upsert(self: *Db, key: Key, translated: []const u8) !void {
        const hash_text = try sourceHash(self.allocator, key.source_text);
        defer self.allocator.free(hash_text);
        const gh = try std.fmt.allocPrint(self.allocator, "{x}", .{key.glossary_hash});
        defer self.allocator.free(gh);

        const sql =
            \\INSERT INTO translations (source_hash, source_text, translated_text, source_lang, target_lang, mode, model_id, glossary_hash, created_at, updated_at, hit_count)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, strftime('%s','now'), strftime('%s','now'), 0)
            \\ON CONFLICT(source_hash, source_lang, target_lang, mode, model_id, glossary_hash)
            \\DO UPDATE SET translated_text=excluded.translated_text, updated_at=strftime('%s','now');
        ;
        var stmt = try Stmt.prepare(self, sql);
        defer stmt.deinit();
        try stmt.bindText(1, hash_text);
        try stmt.bindText(2, key.source_text);
        try stmt.bindText(3, translated);
        try stmt.bindText(4, key.source_lang.asText());
        try stmt.bindText(5, key.target_lang.asText());
        try stmt.bindText(6, key.mode.asText());
        try stmt.bindText(7, key.model_id);
        try stmt.bindText(8, gh);
        if (try stmt.step() != c.SQLITE_DONE) return errors.Error.SqliteFailed;
    }

    pub fn count(self: *Db) !usize {
        const sql = "SELECT COUNT(*) FROM translations;";
        var stmt = try Stmt.prepare(self, sql);
        defer stmt.deinit();
        if (try stmt.step() != c.SQLITE_ROW) return errors.Error.SqliteFailed;
        return @intCast(c.sqlite3_column_int64(stmt.handle, 0));
    }

    pub fn clear(self: *Db) !void {
        var stmt = try Stmt.prepare(self, "DELETE FROM translations;");
        defer stmt.deinit();
        if (try stmt.step() != c.SQLITE_DONE) return errors.Error.SqliteFailed;
    }
};

fn bindKey(stmt: *Stmt, key: Key, hash_text: []const u8, glossary_hash_text: []const u8) !void {
    try stmt.bindText(1, hash_text);
    try stmt.bindText(2, key.source_lang.asText());
    try stmt.bindText(3, key.target_lang.asText());
    try stmt.bindText(4, key.mode.asText());
    try stmt.bindText(5, key.model_id);
    try stmt.bindText(6, glossary_hash_text);
}

pub fn open(allocator: std.mem.Allocator, path: []const u8) !Db {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var db = Db{ .handle = try openHandle(path_z, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE), .allocator = allocator };
    errdefer db.close();
    try db.initSchema();
    return db;
}

pub fn openReadOnly(allocator: std.mem.Allocator, path: []const u8) !Db {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    return .{ .handle = try openHandle(path_z, c.SQLITE_OPEN_READONLY), .allocator = allocator };
}

fn openHandle(path: [:0]const u8, flags: c_int) !*c.sqlite3 {
    var handle: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(path.ptr, &handle, flags, null);
    if (rc != c.SQLITE_OK) {
        if (handle) |h| _ = c.sqlite3_close(h);
        return errors.Error.SqliteFailed;
    }
    return handle orelse errors.Error.SqliteFailed;
}

pub fn sourceHash(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return @import("sys.zig").hexSha256(allocator, text);
}

test "sqlite memory stores hit" {
    const path = "/tmp/kotoba-memory-test.sqlite3";
    @import("sys.zig").deleteFile(path);
    var db = try open(std.testing.allocator, path);
    defer db.close();
    const key = Key{ .source_text = "Hello", .source_lang = .en, .target_lang = .ja, .mode = .default, .model_id = "m", .glossary_hash = 0 };
    try std.testing.expect(try db.lookup(key) == null);
    try db.upsert(key, "こんにちは");
    const hit = (try db.lookup(key)).?;
    defer std.testing.allocator.free(hit.translated_text);
    try std.testing.expectEqualStrings("こんにちは", hit.translated_text);
}

test "sqlite statement wrapper binds and duplicates text" {
    const path = "/tmp/kotoba-memory-stmt-test.sqlite3";
    @import("sys.zig").deleteFile(path);
    var db = try open(std.testing.allocator, path);
    defer db.close();

    var insert = try Stmt.prepare(&db, "INSERT INTO translations (source_hash, source_text, translated_text, source_lang, target_lang, mode, model_id, glossary_hash, created_at, updated_at, hit_count) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 0);");
    defer insert.deinit();
    try insert.bindText(1, "hash");
    try insert.bindText(2, "source");
    try insert.bindText(3, "translated");
    try insert.bindText(4, "en");
    try insert.bindText(5, "ja");
    try insert.bindText(6, "default");
    try insert.bindText(7, "model");
    try insert.bindText(8, "0");
    try std.testing.expectEqual(c.SQLITE_DONE, try insert.step());

    var select = try Stmt.prepare(&db, "SELECT translated_text FROM translations WHERE source_hash=?;");
    defer select.deinit();
    try select.bindText(1, "hash");
    try std.testing.expectEqual(c.SQLITE_ROW, try select.step());
    const translated = try select.columnTextDup(0);
    defer std.testing.allocator.free(translated);
    try std.testing.expectEqualStrings("translated", translated);
}

fn hitCount(db: *Db, key: Key) !usize {
    const hash_text = try sourceHash(std.testing.allocator, key.source_text);
    defer std.testing.allocator.free(hash_text);
    const gh = try std.fmt.allocPrint(std.testing.allocator, "{x}", .{key.glossary_hash});
    defer std.testing.allocator.free(gh);

    const sql = "SELECT hit_count FROM translations WHERE source_hash=? AND source_lang=? AND target_lang=? AND mode=? AND model_id=? AND glossary_hash=?;";
    var stmt = try Stmt.prepare(db, sql);
    defer stmt.deinit();
    try bindKey(&stmt, key, hash_text, gh);

    if (try stmt.step() != c.SQLITE_ROW) return 0;
    return @intCast(c.sqlite3_column_int64(stmt.handle, 0));
}

test "sqlite upsert updates existing translation without duplicating rows" {
    const path = "/tmp/kotoba-memory-upsert-test.sqlite3";
    @import("sys.zig").deleteFile(path);
    var db = try open(std.testing.allocator, path);
    defer db.close();

    const key = Key{ .source_text = "Hello", .source_lang = .en, .target_lang = .ja, .mode = .default, .model_id = "m", .glossary_hash = 0 };
    try db.upsert(key, "こんにちは");
    try db.upsert(key, "やあ");

    try std.testing.expectEqual(@as(usize, 1), try db.count());
    const hit = (try db.lookup(key)).?;
    defer std.testing.allocator.free(hit.translated_text);
    try std.testing.expectEqualStrings("やあ", hit.translated_text);
}

test "sqlite lookup bumps hit_count" {
    const path = "/tmp/kotoba-memory-bump-test.sqlite3";
    @import("sys.zig").deleteFile(path);
    var db = try open(std.testing.allocator, path);
    defer db.close();

    const key = Key{ .source_text = "Hello", .source_lang = .en, .target_lang = .ja, .mode = .default, .model_id = "m", .glossary_hash = 99 };
    try db.upsert(key, "こんにちは");
    try std.testing.expectEqual(@as(usize, 0), try hitCount(&db, key));

    const first = (try db.lookup(key)).?;
    defer std.testing.allocator.free(first.translated_text);
    try std.testing.expectEqual(@as(usize, 1), try hitCount(&db, key));

    const second = (try db.lookup(key)).?;
    defer std.testing.allocator.free(second.translated_text);
    try std.testing.expectEqual(@as(usize, 2), try hitCount(&db, key));
}
