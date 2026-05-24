const std = @import("std");
const sys = @import("sys.zig");

pub const Code = enum {
    not_initialized,
    config_invalid,
    models_invalid,
    model_missing,
    model_load_failed,
    llama_init_failed,
    llama_decode_failed,
    model_not_selected,
    model_registry_invalid,
    split_model_unsupported,
    checksum_failed,
    timeout,
    markdown_parse_failed,
    output_exists,
    sqlite_failed,
    glossary_invalid,
    unsupported_language_pair,
    invalid_arguments,
    interrupted,
    io_error,

    pub fn asText(self: Code) []const u8 {
        return switch (self) {
            .not_initialized => "not_initialized",
            .config_invalid => "config_invalid",
            .models_invalid => "models_invalid",
            .model_missing => "model_missing",
            .model_load_failed => "model_load_failed",
            .llama_init_failed => "llama_init_failed",
            .llama_decode_failed => "llama_decode_failed",
            .model_not_selected => "model_not_selected",
            .model_registry_invalid => "model_registry_invalid",
            .split_model_unsupported => "split_model_unsupported",
            .checksum_failed => "checksum_failed",
            .timeout => "timeout",
            .markdown_parse_failed => "markdown_parse_failed",
            .output_exists => "output_exists",
            .sqlite_failed => "sqlite_failed",
            .glossary_invalid => "glossary_invalid",
            .unsupported_language_pair => "unsupported_language_pair",
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
    ModelLoadFailed,
    LlamaInitFailed,
    LlamaDecodeFailed,
    ModelNotSelected,
    ModelRegistryInvalid,
    SplitModelUnsupported,
    ChecksumFailed,
    Timeout,
    MarkdownParseFailed,
    OutputExists,
    SqliteFailed,
    GlossaryInvalid,
    UnsupportedLanguagePair,
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
        Error.ModelLoadFailed => .{ .code = .model_load_failed, .message = "Could not load the configured GGUF model." },
        Error.LlamaInitFailed => .{ .code = .llama_init_failed, .message = "Could not initialize embedded llama.cpp runtime." },
        Error.LlamaDecodeFailed => .{ .code = .llama_decode_failed, .message = "Embedded llama.cpp generation failed." },
        Error.ModelNotSelected => .{ .code = .model_not_selected, .message = "No model is selected. Run `kotoba models import --use` or `kotoba models pull --use`." },
        Error.ModelRegistryInvalid => .{ .code = .model_registry_invalid, .message = "Model registry entry is invalid." },
        Error.SplitModelUnsupported => .{ .code = .split_model_unsupported, .message = "Split GGUF models are not supported by this command yet. Use a single-file GGUF model." },
        Error.ChecksumFailed => .{ .code = .checksum_failed, .message = "Model checksum verification failed." },
        Error.Timeout => .{ .code = .timeout, .message = "The operation timed out." },
        Error.MarkdownParseFailed => .{ .code = .markdown_parse_failed, .message = "Markdown parsing failed." },
        Error.OutputExists => .{ .code = .output_exists, .message = "Output file already exists. Use --overwrite to replace it." },
        Error.SqliteFailed => .{ .code = .sqlite_failed, .message = "SQLite translation memory operation failed." },
        Error.GlossaryInvalid => .{ .code = .glossary_invalid, .message = "glossary.toml is invalid." },
        Error.UnsupportedLanguagePair => .{ .code = .unsupported_language_pair, .message = "Only en -> ja and ja -> en are supported." },
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
