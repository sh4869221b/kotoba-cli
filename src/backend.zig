const std = @import("std");
const build_options = @import("build_options");
const config = @import("config.zig");
const errors = @import("errors.zig");
const llama = @import("llama.zig");

pub const Request = struct {
    model_id: []const u8,
    prompt: []const u8,
    timeout_sec: u32,
};

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

    fn init(cfg: config.Config) TestSession {
        return .{ .model_id = cfg.model_id };
    }

    pub fn deinit(self: *TestSession) void {
        _ = self;
    }

    pub fn translate(self: *TestSession, allocator: std.mem.Allocator, req: Request) ![]const u8 {
        _ = self;
        const text = promptText(req.prompt);
        return std.fmt.allocPrint(allocator, "JA:{s}", .{text});
    }
};

fn promptText(prompt: []const u8) []const u8 {
    const marker = "Text:\n";
    if (std.mem.lastIndexOf(u8, prompt, marker)) |idx| return prompt[idx + marker.len ..];
    return prompt;
}

test "test backend translates prompt text deterministically" {
    var session = TestSession{ .model_id = "test" };
    const out = try session.translate(std.testing.allocator, .{ .model_id = "test", .prompt = "Translate\nText:\nHello", .timeout_sec = 1 });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("JA:Hello", out);
}
