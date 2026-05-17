const std = @import("std");
const sys = @import("sys.zig");

pub const Code = enum {
    not_initialized,
    config_invalid,
    models_invalid,
    model_missing,
    checksum_failed,
    server_unreachable,
    server_start_failed,
    server_startup_timeout,
    server_autostart_disabled,
    server_user_managed_endpoint,
    server_bad_response,
    timeout,
    markdown_parse_failed,
    output_exists,
    sqlite_failed,
    glossary_invalid,
    unsupported_language_pair,
    server_not_local,
    invalid_arguments,
    interrupted,
    io_error,

    pub fn asText(self: Code) []const u8 {
        return switch (self) {
            .not_initialized => "not_initialized",
            .config_invalid => "config_invalid",
            .models_invalid => "models_invalid",
            .model_missing => "model_missing",
            .checksum_failed => "checksum_failed",
            .server_unreachable => "server_unreachable",
            .server_start_failed => "server_start_failed",
            .server_startup_timeout => "server_startup_timeout",
            .server_autostart_disabled => "server_autostart_disabled",
            .server_user_managed_endpoint => "server_user_managed_endpoint",
            .server_bad_response => "server_bad_response",
            .timeout => "timeout",
            .markdown_parse_failed => "markdown_parse_failed",
            .output_exists => "output_exists",
            .sqlite_failed => "sqlite_failed",
            .glossary_invalid => "glossary_invalid",
            .unsupported_language_pair => "unsupported_language_pair",
            .server_not_local => "server_not_local",
            .invalid_arguments => "invalid_arguments",
            .interrupted => "interrupted",
            .io_error => "io_error",
        };
    }
};

pub const Error = error{
    NotInitialized,
    ConfigInvalid,
    ModelsInvalid,
    ModelMissing,
    ChecksumFailed,
    ServerUnreachable,
    ServerStartFailed,
    ServerStartupTimeout,
    ServerAutostartDisabled,
    ServerUserManagedEndpoint,
    ServerBadResponse,
    Timeout,
    MarkdownParseFailed,
    OutputExists,
    SqliteFailed,
    GlossaryInvalid,
    UnsupportedLanguagePair,
    ServerNotLocal,
    InvalidArguments,
    Interrupted,
};

pub const AppError = struct {
    code: Code,
    message: []const u8,

    pub fn exitCode(self: AppError) u8 {
        return switch (self.code) {
            .invalid_arguments => 2,
            .interrupted => 130,
            else => 1,
        };
    }
};

pub fn fromError(err: anyerror) AppError {
    return switch (err) {
        Error.NotInitialized => .{ .code = .not_initialized, .message = "Kotoba is not initialized. Run `kotoba init`." },
        Error.ConfigInvalid => .{ .code = .config_invalid, .message = "config.toml is missing or invalid." },
        Error.ModelsInvalid => .{ .code = .models_invalid, .message = "models.toml is missing or invalid." },
        Error.ModelMissing => .{ .code = .model_missing, .message = "Configured model file does not exist." },
        Error.ChecksumFailed => .{ .code = .checksum_failed, .message = "Model checksum verification failed." },
        Error.ServerUnreachable => .{ .code = .server_unreachable, .message = "Could not connect to the configured llama server. Try `llama-server -m /path/to/model.gguf --host 127.0.0.1 --port 8080`, then run `kotoba doctor`." },
        Error.ServerStartFailed => .{ .code = .server_start_failed, .message = "Could not start llama-server. Check runtime, llama_server_path, model_path, and permissions." },
        Error.ServerStartupTimeout => .{ .code = .server_startup_timeout, .message = "Started llama-server but it did not become healthy before server_startup_timeout_sec elapsed." },
        Error.ServerAutostartDisabled => .{ .code = .server_autostart_disabled, .message = "server_autostart is disabled and no running llama server is reachable." },
        Error.ServerUserManagedEndpoint => .{ .code = .server_user_managed_endpoint, .message = "server_url has a base path and is treated as a user-managed endpoint; start the server manually or use a root loopback URL." },
        Error.ServerBadResponse => .{ .code = .server_bad_response, .message = "The llama server returned an unexpected response." },
        Error.Timeout => .{ .code = .timeout, .message = "The server request timed out." },
        Error.MarkdownParseFailed => .{ .code = .markdown_parse_failed, .message = "Markdown parsing failed." },
        Error.OutputExists => .{ .code = .output_exists, .message = "Output file already exists. Use --overwrite to replace it." },
        Error.SqliteFailed => .{ .code = .sqlite_failed, .message = "SQLite translation memory operation failed." },
        Error.GlossaryInvalid => .{ .code = .glossary_invalid, .message = "glossary.toml is invalid." },
        Error.UnsupportedLanguagePair => .{ .code = .unsupported_language_pair, .message = "Only en -> ja and ja -> en are supported." },
        Error.ServerNotLocal => .{ .code = .server_not_local, .message = "Translation uses local loopback server endpoints by default. Use --allow-remote-server only if you explicitly accept a remote endpoint." },
        Error.InvalidArguments => .{ .code = .invalid_arguments, .message = "Invalid arguments." },
        Error.Interrupted => .{ .code = .interrupted, .message = "Interrupted." },
        else => .{ .code = .io_error, .message = @errorName(err) },
    };
}

pub fn printHuman(app_err: AppError) void {
    sys.stderrPrint("kotoba: {s}: {s}\n", .{ app_err.code.asText(), app_err.message });
}

pub fn writeJson(app_err: AppError) void {
    sys.stdoutPrint("{{\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}\n", .{ app_err.code.asText(), app_err.message });
}
