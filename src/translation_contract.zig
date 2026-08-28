const std = @import("std");
const lang = @import("lang.zig");

/// All slices are borrowed for the duration of the translation call.
/// Source and prompt text obey the core UTF-8/no-NUL policy.
pub const Request = struct {
    model_id: []const u8,
    source_text: []const u8,
    source_lang: lang.Language,
    target_lang: lang.Language,
    prompt: []const u8,
    timeout_sec: u32,
};

pub const FinishReason = enum { eog, max_tokens, context, timeout, decode };

pub const Result = struct {
    /// Owned by the caller, including empty and unsuccessful result payloads.
    /// Raw bytes require complete-text validation after finish-reason acceptance,
    /// before output or persistence; always deinit even when validation fails.
    text: []const u8,
    finish_reason: FinishReason,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};
