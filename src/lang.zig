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
    while (it.nextCodepoint()) |cp| {
        if ((cp >= 0x3040 and cp <= 0x30ff) or (cp >= 0x3400 and cp <= 0x9fff)) return .ja;
    }
    return .en;
}

pub fn resolve(source_opt: ?Language, target_opt: ?Language, default_source: ?Language, default_target: Language, text: []const u8) !struct { source: Language, target: Language } {
    try text_contract.validate(text);
    const target = target_opt orelse default_target;
    const source = source_opt orelse default_source orelse try detect(text);
    if (source == target) return errors.Error.UnsupportedLanguagePair;
    if (!((source == .en and target == .ja) or (source == .ja and target == .en))) return errors.Error.UnsupportedLanguagePair;
    return .{ .source = source, .target = target };
}

test "detect Japanese text" {
    try std.testing.expectEqual(Language.ja, try detect("こんにちは"));
    try std.testing.expectEqual(Language.en, try detect("Hello"));
    try std.testing.expectError(error.InvalidUtf8, detect("\xE3\x81"));
    try std.testing.expectError(error.EmbeddedNul, detect("A\x00B"));
}

test "language resolution validates bytes with explicit and default languages" {
    const explicit = try resolve(.en, .ja, .ja, .en, "Hello😀");
    try std.testing.expectEqual(Language.en, explicit.source);
    try std.testing.expectEqual(Language.ja, explicit.target);
    const defaulted = try resolve(null, .en, .ja, .en, "Hello");
    try std.testing.expectEqual(Language.ja, defaulted.source);
    try std.testing.expectEqual(Language.en, defaulted.target);
    const detected = try resolve(null, .en, null, .ja, "こんにちは");
    try std.testing.expectEqual(Language.ja, detected.source);
    try std.testing.expectEqual(Language.en, detected.target);

    try std.testing.expectError(error.InvalidUtf8, resolve(.en, .ja, null, .ja, "\xFF"));
    try std.testing.expectError(error.EmbeddedNul, resolve(.en, .ja, null, .ja, "A\x00B"));
    try std.testing.expectError(error.InvalidUtf8, resolve(null, .ja, .en, .ja, "\xFF"));
    try std.testing.expectError(error.EmbeddedNul, resolve(null, .ja, .en, .ja, "A\x00B"));
}
