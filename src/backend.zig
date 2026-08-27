const std = @import("std");
const build_options = @import("build_options");
const config = @import("config.zig");
const errors = @import("errors.zig");
const llama = @import("llama.zig");
const contract = @import("translation_contract.zig");

pub const Request = contract.Request;

pub const Session = if (build_options.test_backend) TestSession else llama.Session;

pub fn init(allocator: std.mem.Allocator, cfg: config.Config, diagnostics_enabled: bool) !Session {
    if (cfg.model_id.len == 0 or cfg.model_path.len == 0) return errors.Error.ModelNotSelected;
    if (build_options.test_backend) {
        return TestSession.init(cfg);
    }
    return llama.Session.init(allocator, .{
        .model_path = cfg.model_path,
        .model_id = cfg.model_id,
        .gpu_layers = cfg.gpu_layers,
        .context_length = cfg.context_length,
        .threads = cfg.threads,
        .max_tokens = cfg.max_tokens,
        .temperature = cfg.temperature,
        .timeout_sec = cfg.timeout_sec,
        .diagnostics_enabled = diagnostics_enabled,
    });
}

pub const TestSession = struct {
    model_id: []const u8,
    fixture: ?Fixture = null,

    pub const Fixture = struct {
        text: ?[]const u8 = null,
        finish_reason: contract.FinishReason = .eog,
    };

    fn init(cfg: config.Config) TestSession {
        return .{ .model_id = cfg.model_id };
    }

    pub fn deinit(self: *TestSession) void {
        _ = self;
    }

    pub fn translate(self: *TestSession, allocator: std.mem.Allocator, req: Request) !contract.Result {
        const fixture = self.fixture orelse Fixture{};
        return .{
            .text = if (fixture.text) |text| try allocator.dupe(u8, text) else try std.fmt.allocPrint(allocator, "{s}:{s}", .{
                switch (req.target_lang) {
                    .ja => "JA",
                    .en => "EN",
                },
                req.source_text,
            }),
            .finish_reason = fixture.finish_reason,
        };
    }
};

test "test backend preserves structured text and direction independently of prompts" {
    var session = TestSession{ .model_id = "test" };
    for ([_]@import("lang.zig").Language{ .ja, .en }) |target| {
        for ([_][]const u8{ "Translate\nText:\nignored", "Entirely different template without delimiters" }) |rendered| {
            const out = try session.translate(std.testing.allocator, .{
                .model_id = "test",
                .source_text = "First\nText:\nLast",
                .source_lang = if (target == .ja) .en else .ja,
                .target_lang = target,
                .prompt = rendered,
                .timeout_sec = 1,
            });
            defer out.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings(if (target == .ja) "JA:First\nText:\nLast" else "EN:First\nText:\nLast", out.text);
            try std.testing.expectEqual(contract.FinishReason.eog, out.finish_reason);
        }
    }
}

test "test backend fixtures preserve every finish reason and arbitrary bytes" {
    const req = Request{ .model_id = "test", .source_text = "source", .source_lang = .en, .target_lang = .ja, .prompt = "ignored", .timeout_sec = 1 };
    for (std.enums.values(contract.FinishReason)) |reason| {
        for ([_][]const u8{ "partial", "\xff", "", " \n\t" }) |text| {
            var session = TestSession{ .model_id = "test", .fixture = .{ .text = text, .finish_reason = reason } };
            const out = try session.translate(std.testing.allocator, req);
            defer out.deinit(std.testing.allocator);
            try std.testing.expectEqualSlices(u8, text, out.text);
            try std.testing.expectEqual(reason, out.finish_reason);
            if (text.len > 0) try std.testing.expect(out.text.ptr != text.ptr);
        }
    }
}

test "test backend fixtures are local to interleaved sessions" {
    const req = Request{ .model_id = "test", .source_text = "source", .source_lang = .en, .target_lang = .ja, .prompt = "ignored", .timeout_sec = 1 };
    var first = TestSession{ .model_id = "test", .fixture = .{ .text = "first", .finish_reason = .timeout } };
    var second = TestSession{ .model_id = "test", .fixture = .{ .finish_reason = .max_tokens } };
    for (0..2) |_| {
        const a = try first.translate(std.testing.allocator, req);
        defer a.deinit(std.testing.allocator);
        const b = try second.translate(std.testing.allocator, req);
        defer b.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("first", a.text);
        try std.testing.expectEqual(contract.FinishReason.timeout, a.finish_reason);
        try std.testing.expectEqualStrings("JA:source", b.text);
        try std.testing.expectEqual(contract.FinishReason.max_tokens, b.finish_reason);
    }
}

test "real and test sessions return the same result payload" {
    const real_return = @typeInfo(@TypeOf(llama.Session.translate)).@"fn".return_type.?;
    const test_return = @typeInfo(@TypeOf(TestSession.translate)).@"fn".return_type.?;
    try std.testing.expect(@typeInfo(real_return).error_union.payload == contract.Result);
    try std.testing.expect(@typeInfo(test_return).error_union.payload == contract.Result);
}
