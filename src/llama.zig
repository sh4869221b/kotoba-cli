const std = @import("std");
const backend = @import("backend.zig");
const errors = @import("errors.zig");
const sys = @import("sys.zig");

const c = @cImport({
    @cInclude("llama.h");
});

pub const Options = struct {
    model_path: []const u8,
    model_id: []const u8,
    context_length: u32,
    threads: u32,
    max_tokens: u32,
    temperature: f32,
    timeout_sec: u32,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    opts: Options,
    model: *c.llama_model,
    ctx: *c.llama_context,
    vocab: *const c.llama_vocab,
    sampler: *c.llama_sampler,
    abort_state: *AbortState,

    pub fn init(allocator: std.mem.Allocator, opts: Options) !Session {
        if (opts.model_path.len == 0) return errors.Error.ModelNotSelected;
        try validateOptions(opts);
        if (!sys.exists(opts.model_path)) return errors.Error.ModelMissing;

        c.llama_backend_init();
        errdefer c.llama_backend_free();

        const path_z = try allocator.dupeZ(u8, opts.model_path);
        defer allocator.free(path_z);

        var model_params = c.llama_model_default_params();
        model_params.n_gpu_layers = 0;
        const model = c.llama_model_load_from_file(path_z.ptr, model_params) orelse return errors.Error.ModelLoadFailed;
        errdefer c.llama_model_free(model);

        var ctx_params = c.llama_context_default_params();
        ctx_params.n_ctx = opts.context_length;
        ctx_params.n_batch = @min(opts.context_length, 512);
        const abort_state = try allocator.create(AbortState);
        errdefer allocator.destroy(abort_state);
        abort_state.* = .{};
        ctx_params.abort_callback = abortCallback;
        ctx_params.abort_callback_data = abort_state;
        if (opts.threads > 0) {
            const threads: c_int = @intCast(opts.threads);
            ctx_params.n_threads = threads;
            ctx_params.n_threads_batch = threads;
        }
        const ctx = c.llama_init_from_model(model, ctx_params) orelse return errors.Error.LlamaInitFailed;
        errdefer c.llama_free(ctx);

        const vocab = c.llama_model_get_vocab(model) orelse return errors.Error.LlamaInitFailed;
        const sampler = c.llama_sampler_chain_init(c.llama_sampler_chain_default_params()) orelse return errors.Error.LlamaInitFailed;
        errdefer c.llama_sampler_free(sampler);
        if (opts.temperature <= 0) {
            c.llama_sampler_chain_add(sampler, c.llama_sampler_init_greedy());
        } else {
            c.llama_sampler_chain_add(sampler, c.llama_sampler_init_temp(opts.temperature));
            c.llama_sampler_chain_add(sampler, c.llama_sampler_init_top_p(0.95, 1));
            c.llama_sampler_chain_add(sampler, c.llama_sampler_init_dist(0));
        }

        return .{ .allocator = allocator, .opts = opts, .model = model, .ctx = ctx, .vocab = vocab, .sampler = sampler, .abort_state = abort_state };
    }

    pub fn deinit(self: *Session) void {
        c.llama_sampler_free(self.sampler);
        c.llama_free(self.ctx);
        c.llama_model_free(self.model);
        self.allocator.destroy(self.abort_state);
        c.llama_backend_free();
    }

    pub fn translate(self: *Session, allocator: std.mem.Allocator, req: backend.Request) ![]const u8 {
        self.abort_state.setTimeout(if (req.timeout_sec > 0) req.timeout_sec else self.opts.timeout_sec);
        defer self.abort_state.clear();
        c.llama_memory_clear(c.llama_get_memory(self.ctx), true);
        c.llama_sampler_reset(self.sampler);

        const prompt_tokens = try tokenize(allocator, self.vocab, req.prompt);
        defer allocator.free(prompt_tokens);
        if (prompt_tokens.len == 0 or prompt_tokens.len >= self.opts.context_length) return errors.Error.LlamaDecodeFailed;

        try self.decodeTokens(prompt_tokens);

        var out = std.array_list.Managed(u8).init(allocator);
        errdefer out.deinit();
        var generated: u32 = 0;
        while (generated < self.opts.max_tokens) : (generated += 1) {
            if (self.abort_state.timedOut()) return errors.Error.Timeout;
            const token = c.llama_sampler_sample(self.sampler, self.ctx, -1);
            if (c.llama_vocab_is_eog(self.vocab, token)) break;
            c.llama_sampler_accept(self.sampler, token);
            try appendTokenPiece(allocator, &out, self.vocab, token);

            var next_tokens = [_]c.llama_token{token};
            try self.decodeTokens(&next_tokens);
        }
        return out.toOwnedSlice();
    }

    fn decodeTokens(self: *Session, tokens: []c.llama_token) errors.Error!void {
        var start: usize = 0;
        const limit = batchTokenLimit(self.opts.context_length);
        while (start < tokens.len) {
            const end = @min(start + limit, tokens.len);
            const batch = c.llama_batch_get_one(tokens[start..end].ptr, @intCast(end - start));
            if (c.llama_decode(self.ctx, batch) != 0) return self.decodeError();
            start = end;
        }
    }

    fn decodeError(self: *Session) errors.Error {
        return if (self.abort_state.timedOut()) errors.Error.Timeout else errors.Error.LlamaDecodeFailed;
    }
};

pub fn validateOptions(opts: Options) !void {
    if (opts.context_length == 0) return errors.Error.InvalidArguments;
    const max_c_int: u32 = @intCast(std.math.maxInt(c_int));
    if (opts.threads > max_c_int) return errors.Error.InvalidArguments;
}

fn batchTokenLimit(context_length: u32) usize {
    return @max(1, @as(usize, @intCast(@min(context_length, 512))));
}

const AbortState = struct {
    deadline_ms: u64 = 0,

    fn setTimeout(self: *AbortState, timeout_sec: u32) void {
        self.deadline_ms = if (timeout_sec == 0) 0 else sys.millis() + @as(u64, timeout_sec) * 1000;
    }

    fn clear(self: *AbortState) void {
        self.deadline_ms = 0;
    }

    fn timedOut(self: *const AbortState) bool {
        return self.deadline_ms != 0 and sys.millis() >= self.deadline_ms;
    }
};

fn abortCallback(data: ?*anyopaque) callconv(.c) bool {
    const ptr = data orelse return false;
    const state: *AbortState = @ptrCast(@alignCast(ptr));
    return state.timedOut();
}

fn tokenize(allocator: std.mem.Allocator, vocab: *const c.llama_vocab, text: []const u8) ![]c.llama_token {
    const text_len: c_int = @intCast(text.len);
    var needed = c.llama_tokenize(vocab, text.ptr, text_len, null, 0, true, true);
    if (needed == c.INT32_MIN) return errors.Error.LlamaDecodeFailed;
    if (needed < 0) needed = -needed;
    if (needed <= 0) return errors.Error.LlamaDecodeFailed;
    const tokens = try allocator.alloc(c.llama_token, @intCast(needed));
    errdefer allocator.free(tokens);
    const actual = c.llama_tokenize(vocab, text.ptr, text_len, tokens.ptr, needed, true, true);
    if (actual < 0) return errors.Error.LlamaDecodeFailed;
    return tokens[0..@intCast(actual)];
}

fn appendTokenPiece(allocator: std.mem.Allocator, out: *std.array_list.Managed(u8), vocab: *const c.llama_vocab, token: c.llama_token) !void {
    var stack_buf: [256]u8 = undefined;
    var n = c.llama_token_to_piece(vocab, token, &stack_buf, stack_buf.len, 0, false);
    if (n < 0) {
        n = -n;
        const buf = try allocator.alloc(u8, @intCast(n));
        defer allocator.free(buf);
        const actual = c.llama_token_to_piece(vocab, token, buf.ptr, n, 0, false);
        if (actual < 0) return errors.Error.LlamaDecodeFailed;
        try out.appendSlice(buf[0..@intCast(actual)]);
        return;
    }
    try out.appendSlice(stack_buf[0..@intCast(n)]);
}

test "embedded session rejects missing model" {
    try std.testing.expectError(errors.Error.ModelMissing, Session.init(std.testing.allocator, .{
        .model_path = "/tmp/kotoba-missing-model.gguf",
        .model_id = "missing",
        .context_length = 4096,
        .threads = 0,
        .max_tokens = 128,
        .temperature = 0.2,
        .timeout_sec = 1,
    }));
}

test "embedded session validates context length and threads" {
    var opts = Options{
        .model_path = "/tmp/kotoba-missing-model.gguf",
        .model_id = "missing",
        .context_length = 0,
        .threads = 0,
        .max_tokens = 128,
        .temperature = 0.2,
        .timeout_sec = 1,
    };
    try std.testing.expectError(errors.Error.InvalidArguments, validateOptions(opts));
    opts.context_length = 4096;
    opts.threads = @as(u32, @intCast(std.math.maxInt(c_int))) + 1;
    try std.testing.expectError(errors.Error.InvalidArguments, validateOptions(opts));
    opts.threads = @intCast(std.math.maxInt(c_int));
    try validateOptions(opts);
}
