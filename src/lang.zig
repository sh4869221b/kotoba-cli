const std = @import("std");
const errors = @import("errors.zig");
const text_contract = @import("text.zig");

pub const Language = enum {
    en,
    ja,

    pub fn parse(text: []const u8) !Language {
        if (std.mem.eql(u8, text, "en")) return .en;
        if (std.mem.eql(u8, text, "ja")) return .ja;
        return errors.Error.InvalidArguments;
    }

    pub fn asText(self: Language) []const u8 {
        return switch (self) {
            .en => "en",
            .ja => "ja",
        };
    }
};

pub fn detect(bytes: []const u8) !Language {
    try text_contract.validate(bytes);
    var view = std.unicode.Utf8View.init(bytes) catch return error.InvalidUtf8;
    var it = view.iterator();
    var latin_count: usize = 0;
    var japanese_count: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (cp <= std.math.maxInt(u8) and std.ascii.isAlphabetic(@intCast(cp))) {
            latin_count += 1;
        } else if ((cp >= 0x3040 and cp <= 0x30ff) or (cp >= 0x3400 and cp <= 0x4dbf) or (cp >= 0x4e00 and cp <= 0x9fff)) {
            japanese_count += 1;
        }
    }
    if (latin_count >= 3 and latin_count / 2 >= japanese_count) return .en;
    if (japanese_count >= 3 and japanese_count / 2 >= latin_count) return .ja;
    return error.AmbiguousLanguage;
}

pub fn resolve(explicit_source: ?Language, authoritative_source: ?Language, target_opt: ?Language, default_source: ?Language, default_target: Language, text: []const u8) !struct { source: Language, target: Language } {
    try text_contract.validate(text);
    const target = target_opt orelse default_target;
    const source = explicit_source orelse authoritative_source orelse default_source orelse try detect(text);
    if (source == target) return errors.Error.UnsupportedLanguagePair;
    if (!((source == .en and target == .ja) or (source == .ja and target == .en))) return errors.Error.UnsupportedLanguagePair;
    return .{ .source = source, .target = target };
}

test "detect requires a dominant English or Japanese script" {
    try std.testing.expectEqual(Language.en, try detect("Hello world"));
    try std.testing.expectEqual(Language.ja, try detect("こんにちは世界"));
    try std.testing.expectEqual(Language.en, try detect("We discuss 山田"));
    try std.testing.expectEqual(Language.en, try detect("abcd日本"));
    try std.testing.expectError(error.AmbiguousLanguage, detect("abc日本語"));
    try std.testing.expectError(error.AmbiguousLanguage, detect("Hi"));
    try std.testing.expectError(error.AmbiguousLanguage, detect("123 !?"));
    try std.testing.expectError(error.AmbiguousLanguage, detect(" \t\n"));
    try std.testing.expectError(error.InvalidUtf8, detect("\xE3\x81"));
    try std.testing.expectError(error.EmbeddedNul, detect("A\x00B"));
}

test "language resolution preserves explicit and configured precedence" {
    const explicit = try resolve(.en, .ja, .ja, .ja, .en, "?!");
    try std.testing.expectEqual(Language.en, explicit.source);
    try std.testing.expectEqual(Language.ja, explicit.target);
    const metadata = try resolve(null, .ja, .en, .en, .ja, "?!");
    try std.testing.expectEqual(Language.ja, metadata.source);
    try std.testing.expectEqual(Language.en, metadata.target);
    const defaulted = try resolve(null, null, .ja, .en, .en, "?!");
    try std.testing.expectEqual(Language.en, defaulted.source);
    try std.testing.expectEqual(Language.ja, defaulted.target);
    const detected = try resolve(null, null, .en, null, .ja, "こんにちは");
    try std.testing.expectEqual(Language.ja, detected.source);
    try std.testing.expectEqual(Language.en, detected.target);

    try std.testing.expectError(error.InvalidUtf8, resolve(.en, .ja, .ja, null, .ja, "\xFF"));
    try std.testing.expectError(error.EmbeddedNul, resolve(.en, .ja, .ja, null, .ja, "A\x00B"));
    try std.testing.expectError(error.InvalidUtf8, resolve(null, .ja, .en, .en, .ja, "\xFF"));
    try std.testing.expectError(error.EmbeddedNul, resolve(null, .ja, .en, .en, .ja, "A\x00B"));
    try std.testing.expectError(error.InvalidUtf8, resolve(null, null, .ja, .en, .ja, "\xFF"));
    try std.testing.expectError(error.EmbeddedNul, resolve(null, null, .ja, .en, .ja, "A\x00B"));
}

test "language resolution reports detector ambiguity" {
    try std.testing.expectError(error.AmbiguousLanguage, resolve(null, null, .ja, null, .ja, "abc日本語"));
    try std.testing.expectError(error.AmbiguousLanguage, resolve(null, null, .ja, null, .ja, "Hi"));
    try std.testing.expectError(error.AmbiguousLanguage, resolve(null, null, .ja, null, .ja, "?!"));
    try std.testing.expectError(error.AmbiguousLanguage, resolve(null, null, .ja, null, .ja, " \t\n"));
}
