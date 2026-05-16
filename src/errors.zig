const std = @import("std");
const sys = @import("sys.zig");

pub const Code = enum {
    not_initialized,
    config_invalid,
    models_invalid,
    model_missing,
    checksum_failed,
    server_unreachable,
    server_bad_response,
    timeout,
    markdown_parse_failed,
    output_exists,
    sqlite_failed,
    glossary_invalid,
    unsupported_language_pair,
    server_not_local,
    invalid_arguments,
    io_error,

    pub fn asText(self: Code) []const u8 {
        return switch (self) {
            .not_initialized => "not_initialized",
            .config_invalid => "config_invalid",
            .models_invalid => "models_invalid",
            .model_missing => "model_missing",
            .checksum_failed => "checksum_failed",
            .server_unreachable => "server_unreachable",
            .server_bad_response => "server_bad_response",
            .timeout => "timeout",
            .markdown_parse_failed => "markdown_parse_failed",
            .output_exists => "output_exists",
            .sqlite_failed => "sqlite_failed",
            .glossary_invalid => "glossary_invalid",
            .unsupported_language_pair => "unsupported_language_pair",
            .server_not_local => "server_not_local",
            .invalid_arguments => "invalid_arguments",
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
    ServerBadResponse,
    Timeout,
    MarkdownParseFailed,
    OutputExists,
    SqliteFailed,
    GlossaryInvalid,
    UnsupportedLanguagePair,
    ServerNotLocal,
    InvalidArguments,
};

pub const AppError = struct {
    code: Code,
    message: []const u8,

    pub fn exitCode(self: AppError) u8 {
        return switch (self.code) {
            .invalid_arguments => 2,
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
        Error.ServerBadResponse => .{ .code = .server_bad_response, .message = "The llama server returned an unexpected response." },
        Error.Timeout => .{ .code = .timeout, .message = "The server request timed out." },
        Error.MarkdownParseFailed => .{ .code = .markdown_parse_failed, .message = "Markdown parsing failed." },
        Error.OutputExists => .{ .code = .output_exists, .message = "Output file already exists. Use --overwrite to replace it." },
        Error.SqliteFailed => .{ .code = .sqlite_failed, .message = "SQLite translation memory operation failed." },
        Error.GlossaryInvalid => .{ .code = .glossary_invalid, .message = "glossary.toml is invalid." },
        Error.UnsupportedLanguagePair => .{ .code = .unsupported_language_pair, .message = "Only en -> ja and ja -> en are supported." },
        Error.ServerNotLocal => .{ .code = .server_not_local, .message = "Translation uses local loopback server endpoints by default. Use --allow-remote-server only if you explicitly accept a remote endpoint." },
        Error.InvalidArguments => .{ .code = .invalid_arguments, .message = "Invalid arguments." },
        else => .{ .code = .io_error, .message = @errorName(err) },
    };
}

pub fn printHuman(app_err: AppError) void {
    sys.stderrPrint("kotoba: {s}: {s}\n", .{ app_err.code.asText(), app_err.message });
}

pub fn writeJson(app_err: AppError) void {
    sys.stdoutPrint("{{\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}\n", .{ app_err.code.asText(), app_err.message });
}
