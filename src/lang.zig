const std = @import("std");
const errors = @import("errors.zig");

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

pub fn detect(text: []const u8) Language {
    var view = std.unicode.Utf8View.init(text) catch return .en;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if ((cp >= 0x3040 and cp <= 0x30ff) or (cp >= 0x3400 and cp <= 0x9fff)) return .ja;
    }
    return .en;
}

pub fn resolve(source_opt: ?Language, target_opt: ?Language, default_source: ?Language, default_target: Language, text: []const u8) !struct { source: Language, target: Language } {
    const target = target_opt orelse default_target;
    const source = source_opt orelse default_source orelse detect(text);
    if (source == target) return errors.Error.UnsupportedLanguagePair;
    if (!((source == .en and target == .ja) or (source == .ja and target == .en))) return errors.Error.UnsupportedLanguagePair;
    return .{ .source = source, .target = target };
}

test "detect Japanese text" {
    try std.testing.expectEqual(Language.ja, detect("こんにちは"));
    try std.testing.expectEqual(Language.en, detect("Hello"));
}
