const std = @import("std");
const contract = @import("translation_contract.zig");
const errors = @import("errors.zig");
const sys = @import("sys.zig");

const c = @cImport({
    @cInclude("llama.h");
});

fn llamaLength(len: usize) !c_int {
    return std.math.cast(c_int, len) orelse errors.Error.LlamaDecodeFailed;
}

fn requiredTokenCount(value: c_int) !usize {
    var count = value;
    if (count == c.INT32_MIN) return errors.Error.LlamaDecodeFailed;
    if (count < 0) count = -count;
    if (count <= 0) return errors.Error.LlamaDecodeFailed;
    return @intCast(count);
}

fn completedTokenCount(value: c_int, capacity: usize) !usize {
    const count = std.math.cast(usize, value) orelse return errors.Error.LlamaDecodeFailed;
    if (count > capacity) return errors.Error.LlamaDecodeFailed;
    return count;
}

fn requiredPieceBytes(value: c_int) !usize {
    var count = value;
    if (count == c.INT32_MIN) return errors.Error.LlamaDecodeFailed;
    if (count < 0) count = -count;
    return @intCast(count);
}

fn completedPieceBytes(value: c_int, capacity: usize) !usize {
    const count = std.math.cast(usize, value) orelse return errors.Error.LlamaDecodeFailed;
    if (count > capacity) return errors.Error.LlamaDecodeFailed;
    return count;
}

pub const Options = struct {
    model_path: []const u8,
    model_id: []const u8,
    gpu_layers: i32,
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
    released: bool = false,

    fn take(self: *Model) ?*c.llama_model {
        if (self.released) return null;
        self.released = true;
        return self.ptr;
    }

    pub fn loadFromFile(path: [*:0]const u8, params: c.llama_model_params) !Model {
        const ptr = c.llama_model_load_from_file(path, params) orelse return errors.Error.ModelLoadFailed;
        return .{ .ptr = ptr };
    }

    pub fn deinit(self: *Model) void {
        if (self.take()) |ptr| c.llama_model_free(ptr);
    }

    pub fn getVocab(self: Model) !*const c.llama_vocab {
        return c.llama_model_get_vocab(self.ptr) orelse return errors.Error.LlamaInitFailed;
    }
};

const Context = struct {
    ptr: *c.llama_context,
    released: bool = false,

    fn take(self: *Context) ?*c.llama_context {
        if (self.released) return null;
        self.released = true;
        return self.ptr;
    }

    pub fn initFromModel(model: *c.llama_model, params: c.llama_context_params) !Context {
        const ptr = c.llama_init_from_model(model, params) orelse return errors.Error.LlamaInitFailed;
        return .{ .ptr = ptr };
    }

    pub fn deinit(self: *Context) void {
        if (self.take()) |ptr| c.llama_free(ptr);
    }

    pub fn clearMemory(self: Context) void {
        c.llama_memory_clear(c.llama_get_memory(self.ptr), true);
    }
};

const Sampler = struct {
    ptr: *c.llama_sampler,
    released: bool = false,

    fn take(self: *Sampler) ?*c.llama_sampler {
        if (self.released) return null;
        self.released = true;
        return self.ptr;
    }

    pub fn initChainDefault() !Sampler {
        const ptr = c.llama_sampler_chain_init(c.llama_sampler_chain_default_params()) orelse return errors.Error.LlamaInitFailed;
        return .{ .ptr = ptr };
    }

    pub fn deinit(self: *Sampler) void {
        if (self.take()) |ptr| c.llama_sampler_free(ptr);
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
        if (std.mem.indexOfScalar(u8, opts.model_path, 0) != null) return errors.Error.EmbeddedNul;
        try validateOptions(opts);
        if (!sys.exists(opts.model_path)) return errors.Error.ModelMissing;

        const diag_guard = DiagnosticsGuard.init(opts.diagnostics_enabled);
        errdefer diag_guard.deinit();

        const backend_state = Backend.init();
        errdefer backend_state.deinit();

        const path_z = try allocator.dupeZ(u8, opts.model_path);
        defer allocator.free(path_z);

        const model_params = modelParamsForOptions(opts);
        var model = try Model.loadFromFile(path_z.ptr, model_params);
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
        var ctx = try Context.initFromModel(model.ptr, ctx_params);
        errdefer ctx.deinit();

        const vocab = try model.getVocab();

        var sampler = try Sampler.initChainDefault();
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

    pub fn translate(self: *Session, allocator: std.mem.Allocator, req: contract.Request) !contract.Result {
        self.abort_guard.state.setTimeout(if (req.timeout_sec > 0) req.timeout_sec else self.opts.timeout_sec);
        defer self.abort_guard.state.clear();
        self.ctx.clearMemory();
        self.sampler.reset();

        var out = std.array_list.Managed(u8).init(allocator);
        errdefer out.deinit();
        const prompt_tokens = tokenize(allocator, self.vocab, req.prompt) catch |err| switch (err) {
            errors.Error.LlamaDecodeFailed => return .{ .text = try out.toOwnedSlice(), .finish_reason = if (self.abort_guard.state.timedOut()) .timeout else .decode },
            else => return err,
        };
        defer allocator.free(prompt_tokens);
        if (prompt_tokens.len == 0) return .{ .text = try out.toOwnedSlice(), .finish_reason = .decode };
        if (prompt_tokens.len >= self.opts.context_length) return .{ .text = try out.toOwnedSlice(), .finish_reason = .context };

        if (self.decodeTokens(prompt_tokens)) |reason| return .{ .text = try out.toOwnedSlice(), .finish_reason = reason };

        var finish_reason: contract.FinishReason = .max_tokens;
        var generated: u32 = 0;
        while (generated < self.opts.max_tokens) : (generated += 1) {
            if (self.abort_guard.state.timedOut()) {
                finish_reason = .timeout;
                break;
            }
            const token = self.sampler.sample(self.ctx.ptr, -1);
            if (c.llama_vocab_is_eog(self.vocab, token)) {
                finish_reason = .eog;
                break;
            }
            self.sampler.accept(token);
            appendTokenPiece(allocator, &out, self.vocab, token) catch |err| switch (err) {
                errors.Error.LlamaDecodeFailed => return .{ .text = try out.toOwnedSlice(), .finish_reason = if (self.abort_guard.state.timedOut()) .timeout else .decode },
                else => return err,
            };

            var next_tokens = [_]c.llama_token{token};
            if (self.decodeTokens(&next_tokens)) |reason| {
                finish_reason = reason;
                break;
            }
        }
        return .{ .text = try out.toOwnedSlice(), .finish_reason = finish_reason };
    }

    fn decodeTokens(self: *Session, tokens: []c.llama_token) ?contract.FinishReason {
        var start: usize = 0;
        const limit = batchTokenLimit(self.opts.context_length);
        while (start < tokens.len) {
            const end = @min(start + limit, tokens.len);
            const batch = c.llama_batch_get_one(tokens[start..end].ptr, @intCast(end - start));
            const status = c.llama_decode(self.ctx.ptr, batch);
            if (decodeFinishReason(status, self.abort_guard.state.timedOut())) |reason| return reason;
            start = end;
        }
        return null;
    }
};

fn decodeFinishReason(status: i32, timed_out: bool) ?contract.FinishReason {
    if (status == 0) return null;
    if (timed_out) return .timeout;
    return if (status == 1) .context else .decode;
}

pub fn validateOptions(opts: Options) !void {
    if (opts.context_length == 0) return errors.Error.InvalidArguments;
    if (opts.max_tokens == 0) return errors.Error.InvalidArguments;
    const max_c_int: u32 = @intCast(std.math.maxInt(c_int));
    if (opts.threads > max_c_int) return errors.Error.InvalidArguments;
}

fn modelParamsForOptions(opts: Options) c.llama_model_params {
    var model_params = c.llama_model_default_params();
    model_params.n_gpu_layers = opts.gpu_layers;
    if (!opts.diagnostics_enabled) {
        model_params.progress_callback = quietProgressCallback;
        model_params.progress_callback_user_data = null;
    }
    return model_params;
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
    const text_len = try llamaLength(text.len);
    const needed = try requiredTokenCount(c.llama_tokenize(vocab, text.ptr, text_len, null, 0, true, true));
    const tokens = try allocator.alloc(c.llama_token, needed);
    errdefer allocator.free(tokens);
    const actual = c.llama_tokenize(vocab, text.ptr, text_len, tokens.ptr, try llamaLength(tokens.len), true, true);
    return tokens[0..try completedTokenCount(actual, tokens.len)];
}

fn appendTokenPiece(allocator: std.mem.Allocator, out: *std.array_list.Managed(u8), vocab: *const c.llama_vocab, token: c.llama_token) !void {
    var stack_buf: [256]u8 = undefined;
    const n = c.llama_token_to_piece(vocab, token, &stack_buf, stack_buf.len, 0, false);
    if (n < 0) {
        const buf = try allocator.alloc(u8, try requiredPieceBytes(n));
        defer allocator.free(buf);
        const actual = c.llama_token_to_piece(vocab, token, buf.ptr, try llamaLength(buf.len), 0, false);
        try out.appendSlice(buf[0..try completedPieceBytes(actual, buf.len)]);
        return;
    }
    try out.appendSlice(stack_buf[0..try completedPieceBytes(n, stack_buf.len)]);
}

test "embedded session rejects missing model" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const model_path = try std.fs.path.join(std.testing.allocator, &.{ root, "missing.gguf" });
    defer std.testing.allocator.free(model_path);
    try std.testing.expectError(errors.Error.ModelMissing, Session.init(std.testing.allocator, .{
        .model_path = model_path,
        .model_id = "missing",
        .gpu_layers = -1,
        .context_length = 4096,
        .threads = 0,
        .max_tokens = 128,
        .temperature = 0.2,
        .timeout_sec = 1,
        .diagnostics_enabled = false,
    }));
}

test "embedded session rejects NUL in model paths before filesystem and C calls" {
    try std.testing.expectError(errors.Error.EmbeddedNul, Session.init(std.testing.allocator, .{
        .model_path = "missing.gguf\x00ignored.gguf",
        .model_id = "missing",
        .gpu_layers = -1,
        .context_length = 4096,
        .threads = 0,
        .max_tokens = 128,
        .temperature = 0.2,
        .timeout_sec = 1,
        .diagnostics_enabled = false,
    }));
}

test "embedded session preserves model-load error and unwinds initialized guards" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "invalid.gguf", .data = "not a gguf" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const model_path = try std.fs.path.join(std.testing.allocator, &.{ root, "invalid.gguf" });
    defer std.testing.allocator.free(model_path);
    resetDiagnostics();

    try std.testing.expectError(errors.Error.ModelLoadFailed, Session.init(std.testing.allocator, .{
        .model_path = model_path,
        .model_id = "invalid",
        .gpu_layers = 0,
        .context_length = 512,
        .threads = 1,
        .max_tokens = 1,
        .temperature = 0,
        .timeout_sec = 1,
        .diagnostics_enabled = false,
    }));
    try std.testing.expectEqual(DiagnosticsMode.default, diagnostics_mode);
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "invalid.gguf", std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("not a gguf", bytes);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Session.init(failing.allocator(), .{
        .model_path = model_path,
        .model_id = "invalid",
        .gpu_layers = 0,
        .context_length = 512,
        .threads = 1,
        .max_tokens = 1,
        .temperature = 0,
        .timeout_sec = 1,
        .diagnostics_enabled = false,
    }));
    try std.testing.expectEqual(DiagnosticsMode.default, diagnostics_mode);
}

test "embedded session validates context length and threads" {
    var opts = Options{
        .model_path = "not-accessed.gguf",
        .model_id = "missing",
        .gpu_layers = -1,
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
        .model_path = "not-accessed.gguf",
        .model_id = "missing",
        .gpu_layers = -1,
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

test "model params preserve signed gpu layer offload values" {
    for ([_]i32{ -2, -1, 0, 1 }) |layers| {
        const opts = Options{
            .model_path = "not-accessed.gguf",
            .model_id = "missing",
            .gpu_layers = layers,
            .context_length = 4096,
            .threads = 0,
            .max_tokens = 128,
            .temperature = 0.2,
            .timeout_sec = 1,
            .diagnostics_enabled = false,
        };
        try validateOptions(opts);
        try std.testing.expectEqual(layers, modelParamsForOptions(opts).n_gpu_layers);
    }
}

// llama/log global-state tests run serially within each process; see docs/test-harness.md.
test "diagnostics callbacks can be toggled without model load" {
    const quiet = DiagnosticsGuard.init(false);
    quiet.deinit();
    const enabled = DiagnosticsGuard.init(true);
    enabled.deinit();
}

test "decode status classification preserves timeout precedence" {
    try std.testing.expectEqual(@as(?contract.FinishReason, null), decodeFinishReason(0, false));
    try std.testing.expectEqual(@as(?contract.FinishReason, null), decodeFinishReason(0, true));
    try std.testing.expectEqual(contract.FinishReason.context, decodeFinishReason(1, false).?);
    for ([_]i32{ 2, -1, -2 }) |status| {
        try std.testing.expectEqual(contract.FinishReason.decode, decodeFinishReason(status, false).?);
    }
    for ([_]i32{ 1, 2, -1, -2 }) |status| {
        try std.testing.expectEqual(contract.FinishReason.timeout, decodeFinishReason(status, true).?);
    }
}

test "tokenization rejects text lengths beyond c int before the C call" {
    const vocab: *const c.llama_vocab = @ptrFromInt(4096);
    const text_ptr: [*]const u8 = "text\x00".ptr;
    const too_long = text_ptr[0 .. @as(usize, @intCast(std.math.maxInt(c_int))) + 1];
    try std.testing.expectError(errors.Error.LlamaDecodeFailed, tokenize(std.testing.allocator, vocab, too_long));
}

test "tokenization rejects C counts beyond the allocated token capacity" {
    try std.testing.expectError(errors.Error.LlamaDecodeFailed, requiredTokenCount(c.INT32_MIN));
    try std.testing.expectError(errors.Error.LlamaDecodeFailed, requiredTokenCount(0));
    try std.testing.expectEqual(@as(usize, 3), try requiredTokenCount(-3));
    try std.testing.expectError(errors.Error.LlamaDecodeFailed, completedTokenCount(2, 1));
    try std.testing.expectError(errors.Error.LlamaDecodeFailed, completedTokenCount(-1, 1));
}

test "token pieces reject C counts beyond the allocated byte capacity" {
    try std.testing.expectError(errors.Error.LlamaDecodeFailed, completedPieceBytes(257, 256));
    try std.testing.expectError(errors.Error.LlamaDecodeFailed, completedPieceBytes(-1, 256));
}

test "token pieces reject the minimum C sentinel without negation overflow" {
    try std.testing.expectError(errors.Error.LlamaDecodeFailed, requiredPieceBytes(c.INT32_MIN));
    try std.testing.expectEqual(@as(usize, 3), try requiredPieceBytes(-3));
    try std.testing.expectEqual(@as(usize, 0), try requiredPieceBytes(0));
}

test "model context and sampler handles are consumed once" {
    var model = Model{ .ptr = @ptrFromInt(4096) };
    try std.testing.expect(model.take() != null);
    try std.testing.expect(model.take() == null);
    var context = Context{ .ptr = @ptrFromInt(8192) };
    try std.testing.expect(context.take() != null);
    try std.testing.expect(context.take() == null);
    var sampler = Sampler{ .ptr = @ptrFromInt(12288) };
    try std.testing.expect(sampler.take() != null);
    try std.testing.expect(sampler.take() == null);
}
