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
        if (c.sqlite3_exec(self.handle, sql.ptr, null, null, null) != c.SQLITE_OK) return errors.Error.SqliteFailed;
    }

    pub fn lookup(self: *Db, key: Key) !?Hit {
        const hash_text = try sourceHash(self.allocator, key.source_text);
        defer self.allocator.free(hash_text);
        const sql = "SELECT translated_text FROM translations WHERE source_hash=? AND source_lang=? AND target_lang=? AND mode=? AND model_id=? AND glossary_hash=?;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) return errors.Error.SqliteFailed;
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, hash_text);
        bindText(stmt, 2, key.source_lang.asText());
        bindText(stmt, 3, key.target_lang.asText());
        bindText(stmt, 4, key.mode.asText());
        bindText(stmt, 5, key.model_id);
        const gh = try std.fmt.allocPrint(self.allocator, "{x}", .{key.glossary_hash});
        defer self.allocator.free(gh);
        bindText(stmt, 6, gh);
        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const ptr = c.sqlite3_column_text(stmt, 0) orelse return errors.Error.SqliteFailed;
            const txt = std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
            try self.bump(key);
            return .{ .translated_text = try self.allocator.dupe(u8, txt) };
        }
        return null;
    }

    fn bump(self: *Db, key: Key) !void {
        const hash_text = try sourceHash(self.allocator, key.source_text);
        defer self.allocator.free(hash_text);
        const gh = try std.fmt.allocPrint(self.allocator, "{x}", .{key.glossary_hash});
        defer self.allocator.free(gh);
        const sql = "UPDATE translations SET hit_count=hit_count+1, updated_at=strftime('%s','now') WHERE source_hash=? AND source_lang=? AND target_lang=? AND mode=? AND model_id=? AND glossary_hash=?;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) return errors.Error.SqliteFailed;
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, hash_text);
        bindText(stmt, 2, key.source_lang.asText());
        bindText(stmt, 3, key.target_lang.asText());
        bindText(stmt, 4, key.mode.asText());
        bindText(stmt, 5, key.model_id);
        bindText(stmt, 6, gh);
        _ = c.sqlite3_step(stmt);
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
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) return errors.Error.SqliteFailed;
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, hash_text);
        bindText(stmt, 2, key.source_text);
        bindText(stmt, 3, translated);
        bindText(stmt, 4, key.source_lang.asText());
        bindText(stmt, 5, key.target_lang.asText());
        bindText(stmt, 6, key.mode.asText());
        bindText(stmt, 7, key.model_id);
        bindText(stmt, 8, gh);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return errors.Error.SqliteFailed;
    }

    pub fn count(self: *Db) !usize {
        const sql = "SELECT COUNT(*) FROM translations;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) return errors.Error.SqliteFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return errors.Error.SqliteFailed;
        return @intCast(c.sqlite3_column_int64(stmt, 0));
    }

    pub fn clear(self: *Db) !void {
        const sql = "DELETE FROM translations;";
        if (c.sqlite3_exec(self.handle, sql.ptr, null, null, null) != c.SQLITE_OK) return errors.Error.SqliteFailed;
    }
};

fn bindText(stmt: ?*c.sqlite3_stmt, idx: c_int, text: []const u8) void {
    _ = c.sqlite3_bind_text(stmt, idx, text.ptr, @intCast(text.len), c.SQLITE_TRANSIENT);
}

pub fn open(allocator: std.mem.Allocator, path: []const u8) !Db {
    var handle: ?*c.sqlite3 = null;
    if (c.sqlite3_open(path.ptr, &handle) != c.SQLITE_OK) return errors.Error.SqliteFailed;
    var db = Db{ .handle = handle.?, .allocator = allocator };
    try db.initSchema();
    return db;
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
