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
    diagnostics_enabled: bool = false,
};

const Backend = struct {
    pub fn init() Backend {
        c.llama_backend_init();
        return .{};
    }
    pub fn deinit(self: Backend) void {
        _ = self;
        c.llama_backend_free();
    }
};

const DiagnosticsMode = enum { default, quiet };
var diagnostics_mode: DiagnosticsMode = .default;

const DiagnosticsGuard = struct {
    previous: DiagnosticsMode,

    pub fn init(enabled: bool) DiagnosticsGuard {
        const previous = diagnostics_mode;
        configureDiagnostics(enabled);
        return .{ .previous = previous };
    }
    pub fn deinit(self: DiagnosticsGuard) void {
        applyDiagnosticsMode(self.previous);
    }
};

const Model = struct {
    ptr: *c.llama_model,

    pub fn loadFromFile(path: [*:0]const u8, params: c.llama_model_params) !Model {
        const ptr = c.llama_model_load_from_file(path, params) orelse return errors.Error.ModelLoadFailed;
        return .{ .ptr = ptr };
    }

    pub fn deinit(self: Model) void {
        c.llama_model_free(self.ptr);
    }

    pub fn getVocab(self: Model) !*const c.llama_vocab {
        return c.llama_model_get_vocab(self.ptr) orelse return errors.Error.LlamaInitFailed;
    }
};

const Context = struct {
    ptr: *c.llama_context,

    pub fn initFromModel(model: *c.llama_model, params: c.llama_context_params) !Context {
        const ptr = c.llama_init_from_model(model, params) orelse return errors.Error.LlamaInitFailed;
        return .{ .ptr = ptr };
    }

    pub fn deinit(self: Context) void {
        c.llama_free(self.ptr);
    }

    pub fn clearMemory(self: Context) void {
        c.llama_memory_clear(c.llama_get_memory(self.ptr), true);
    }
};

const Sampler = struct {
    ptr: *c.llama_sampler,

    pub fn initChainDefault() !Sampler {
        const ptr = c.llama_sampler_chain_init(c.llama_sampler_chain_default_params()) orelse return errors.Error.LlamaInitFailed;
        return .{ .ptr = ptr };
    }

    pub fn deinit(self: Sampler) void {
        c.llama_sampler_free(self.ptr);
    }

    pub fn reset(self: Sampler) void {
        c.llama_sampler_reset(self.ptr);
    }

    pub fn sample(self: Sampler, ctx: *c.llama_context, idx: i32) c.llama_token {
        return c.llama_sampler_sample(self.ptr, ctx, idx);
    }

    pub fn accept(self: Sampler, token: c.llama_token) void {
        c.llama_sampler_accept(self.ptr, token);
    }

    pub fn addGreedy(self: Sampler) void {
        c.llama_sampler_chain_add(self.ptr, c.llama_sampler_init_greedy());
    }

    pub fn addTemp(self: Sampler, t: f32) void {
        c.llama_sampler_chain_add(self.ptr, c.llama_sampler_init_temp(t));
    }

    pub fn addTopP(self: Sampler, p: f32, min_keep: usize) void {
        c.llama_sampler_chain_add(self.ptr, c.llama_sampler_init_top_p(p, min_keep));
    }

    pub fn addDist(self: Sampler, seed: u32) void {
        c.llama_sampler_chain_add(self.ptr, c.llama_sampler_init_dist(seed));
    }
};

pub const BackendGuard = Backend;
pub const ModelGuard = Model;
pub const ContextGuard = Context;
pub const SamplerGuard = Sampler;

const AbortGuard = struct {
    allocator: std.mem.Allocator,
    state: *AbortState,

    pub fn init(allocator: std.mem.Allocator) !AbortGuard {
        const state = try allocator.create(AbortState);
        state.* = .{};
        return .{ .allocator = allocator, .state = state };
    }

    pub fn deinit(self: AbortGuard) void {
        self.allocator.destroy(self.state);
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    opts: Options,
    model: Model,
    ctx: Context,
    vocab: *const c.llama_vocab,
    sampler: Sampler,
    abort_guard: AbortGuard,
    backend: Backend,
    diag_guard: DiagnosticsGuard,

    pub fn init(allocator: std.mem.Allocator, opts: Options) !Session {
        if (opts.model_path.len == 0) return errors.Error.ModelNotSelected;
        try validateOptions(opts);
        if (!sys.exists(opts.model_path)) return errors.Error.ModelMissing;

        const diag_guard = DiagnosticsGuard.init(opts.diagnostics_enabled);
        errdefer diag_guard.deinit();

        const backend_state = Backend.init();
        errdefer backend_state.deinit();

        const path_z = try allocator.dupeZ(u8, opts.model_path);
        defer allocator.free(path_z);

        var model_params = c.llama_model_default_params();
        model_params.n_gpu_layers = 0;
        if (!opts.diagnostics_enabled) {
            model_params.progress_callback = quietProgressCallback;
            model_params.progress_callback_user_data = null;
        }
        const model = try Model.loadFromFile(path_z.ptr, model_params);
        errdefer model.deinit();

        const abort_guard = try AbortGuard.init(allocator);
        errdefer abort_guard.deinit();

        var ctx_params = c.llama_context_default_params();
        ctx_params.n_ctx = opts.context_length;
        ctx_params.n_batch = @min(opts.context_length, 512);
        ctx_params.abort_callback = abortCallback;
        ctx_params.abort_callback_data = abort_guard.state;
        if (opts.threads > 0) {
            const threads: c_int = @intCast(opts.threads);
            ctx_params.n_threads = threads;
            ctx_params.n_threads_batch = threads;
        }
        const ctx = try Context.initFromModel(model.ptr, ctx_params);
        errdefer ctx.deinit();

        const vocab = try model.getVocab();

        const sampler = try Sampler.initChainDefault();
        errdefer sampler.deinit();
        if (opts.temperature <= 0) {
            sampler.addGreedy();
        } else {
            sampler.addTemp(opts.temperature);
            sampler.addTopP(0.95, 1);
            sampler.addDist(0);
        }

        return .{
            .allocator = allocator,
            .opts = opts,
            .model = model,
            .ctx = ctx,
            .vocab = vocab,
            .sampler = sampler,
            .abort_guard = abort_guard,
            .backend = backend_state,
            .diag_guard = diag_guard,
        };
    }

    pub fn deinit(self: *Session) void {
        self.sampler.deinit();
        self.ctx.deinit();
        self.model.deinit();
        self.abort_guard.deinit();
        self.backend.deinit();
        self.diag_guard.deinit();
    }

    pub fn translate(self: *Session, allocator: std.mem.Allocator, req: backend.Request) ![]const u8 {
        self.abort_guard.state.setTimeout(if (req.timeout_sec > 0) req.timeout_sec else self.opts.timeout_sec);
        defer self.abort_guard.state.clear();
        self.ctx.clearMemory();
        self.sampler.reset();

        const prompt_tokens = try tokenize(allocator, self.vocab, req.prompt);
        defer allocator.free(prompt_tokens);
        if (prompt_tokens.len == 0 or prompt_tokens.len >= self.opts.context_length) return errors.Error.LlamaDecodeFailed;

        try self.decodeTokens(prompt_tokens);

        var out = std.array_list.Managed(u8).init(allocator);
        errdefer out.deinit();
        var generated: u32 = 0;
        while (generated < self.opts.max_tokens) : (generated += 1) {
            if (self.abort_guard.state.timedOut()) return errors.Error.Timeout;
            const token = self.sampler.sample(self.ctx.ptr, -1);
            if (c.llama_vocab_is_eog(self.vocab, token)) break;
            self.sampler.accept(token);
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
            if (c.llama_decode(self.ctx.ptr, batch) != 0) return self.decodeError();
            start = end;
        }
    }

    fn decodeError(self: *Session) errors.Error {
        return if (self.abort_guard.state.timedOut()) errors.Error.Timeout else errors.Error.LlamaDecodeFailed;
    }
};

pub fn validateOptions(opts: Options) !void {
    if (opts.context_length == 0) return errors.Error.InvalidArguments;
    if (opts.max_tokens == 0) return errors.Error.InvalidArguments;
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

fn quietLogCallback(level: c.ggml_log_level, text: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = level;
    _ = text;
    _ = user_data;
}

fn quietProgressCallback(progress: f32, user_data: ?*anyopaque) callconv(.c) bool {
    _ = progress;
    _ = user_data;
    return true;
}

fn configureDiagnostics(enabled: bool) void {
    applyDiagnosticsMode(if (enabled) .default else .quiet);
}

fn resetDiagnostics() void {
    applyDiagnosticsMode(.default);
}

fn applyDiagnosticsMode(mode: DiagnosticsMode) void {
    switch (mode) {
        .default => c.llama_log_set(null, null),
        .quiet => c.llama_log_set(quietLogCallback, null),
    }
    diagnostics_mode = mode;
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
        .diagnostics_enabled = false,
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
        .diagnostics_enabled = false,
    };
    try std.testing.expectError(errors.Error.InvalidArguments, validateOptions(opts));
    opts.context_length = 4096;
    opts.threads = @as(u32, @intCast(std.math.maxInt(c_int))) + 1;
    try std.testing.expectError(errors.Error.InvalidArguments, validateOptions(opts));
    opts.threads = @intCast(std.math.maxInt(c_int));
    try validateOptions(opts);
}

test "embedded session validates generation limits" {
    var opts = Options{
        .model_path = "/tmp/kotoba-missing-model.gguf",
        .model_id = "missing",
        .context_length = 4096,
        .threads = 0,
        .max_tokens = 0,
        .temperature = 0.2,
        .timeout_sec = 1,
        .diagnostics_enabled = false,
    };
    try std.testing.expectError(errors.Error.InvalidArguments, validateOptions(opts));
    opts.max_tokens = 1;
    try validateOptions(opts);
}

test "diagnostics callbacks can be toggled without model load" {
    const quiet = DiagnosticsGuard.init(false);
    quiet.deinit();
    const enabled = DiagnosticsGuard.init(true);
    enabled.deinit();
}

test "FFI resources expose guard wrappers" {
    try std.testing.expect(@hasDecl(@This(), "ModelGuard"));
    try std.testing.expect(@hasDecl(@This(), "ContextGuard"));
    try std.testing.expect(@hasDecl(@This(), "SamplerGuard"));
    try std.testing.expect(@hasDecl(@This(), "DiagnosticsGuard"));
}
