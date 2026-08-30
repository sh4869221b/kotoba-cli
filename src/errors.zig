const std = @import("std");
const sys = @import("sys.zig");

pub const Code = enum {
    not_initialized,
    config_invalid,
    models_invalid,
    config_schema_unsupported,
    models_schema_unsupported,
    model_missing,
    model_load_failed,
    llama_init_failed,
    llama_decode_failed,
    model_not_selected,
    model_registry_invalid,
    model_source_required,
    split_model_unsupported,
    checksum_failed,
    timeout,
    markdown_parse_failed,
    output_exists,
    sqlite_failed,
    glossary_invalid,
    unsupported_language_pair,
    invalid_arguments,
    invalid_utf8,
    embedded_nul,
    interrupted,
    path_resolution_failed,
    io_error,

    pub fn asText(self: Code) []const u8 {
        return switch (self) {
            .not_initialized => "not_initialized",
            .config_invalid => "config_invalid",
            .models_invalid => "models_invalid",
            .config_schema_unsupported => "config_schema_unsupported",
            .models_schema_unsupported => "models_schema_unsupported",
            .model_missing => "model_missing",
            .model_load_failed => "model_load_failed",
            .llama_init_failed => "llama_init_failed",
            .llama_decode_failed => "llama_decode_failed",
            .model_not_selected => "model_not_selected",
            .model_registry_invalid => "model_registry_invalid",
            .model_source_required => "model_source_required",
            .split_model_unsupported => "split_model_unsupported",
            .checksum_failed => "checksum_failed",
            .timeout => "timeout",
            .markdown_parse_failed => "markdown_parse_failed",
            .output_exists => "output_exists",
            .sqlite_failed => "sqlite_failed",
            .glossary_invalid => "glossary_invalid",
            .unsupported_language_pair => "unsupported_language_pair",
            .invalid_arguments => "invalid_arguments",
            .invalid_utf8 => "invalid_utf8",
            .embedded_nul => "embedded_nul",
            .interrupted => "interrupted",
            .path_resolution_failed => "path_resolution_failed",
            .io_error => "io_error",
        };
    }
};

pub const Error = error{
    NotInitialized,
    ConfigInvalid,
    ModelsInvalid,
    ConfigSchemaUnsupported,
    ModelsSchemaUnsupported,
    ModelMissing,
    ModelLoadFailed,
    LlamaInitFailed,
    LlamaDecodeFailed,
    ModelNotSelected,
    ModelRegistryInvalid,
    ModelSourceRequired,
    SplitModelUnsupported,
    ChecksumFailed,
    Timeout,
    MarkdownParseFailed,
    OutputExists,
    SqliteFailed,
    GlossaryInvalid,
    UnsupportedLanguagePair,
    InvalidArguments,
    InvalidUtf8,
    EmbeddedNul,
    Interrupted,
    PathResolutionFailed,
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
        Error.ConfigInvalid => .{ .code = .config_invalid, .message = "config.toml is invalid." },
        Error.ModelsInvalid => .{ .code = .models_invalid, .message = "models.toml is invalid." },
        Error.ConfigSchemaUnsupported => .{ .code = .config_schema_unsupported, .message = "config.toml uses an unsupported schema or version." },
        Error.ModelsSchemaUnsupported => .{ .code = .models_schema_unsupported, .message = "models.toml uses an unsupported schema or version." },
        Error.ModelMissing => .{ .code = .model_missing, .message = "Configured model file does not exist." },
        Error.ModelLoadFailed => .{ .code = .model_load_failed, .message = "Could not load the configured GGUF model." },
        Error.LlamaInitFailed => .{ .code = .llama_init_failed, .message = "Could not initialize embedded llama.cpp runtime." },
        Error.LlamaDecodeFailed => .{ .code = .llama_decode_failed, .message = "Embedded llama.cpp generation failed." },
        Error.ModelNotSelected => .{ .code = .model_not_selected, .message = "No model is selected. Run `kotoba models import --use` or `kotoba models pull --use`." },
        Error.ModelRegistryInvalid => .{ .code = .model_registry_invalid, .message = "Model registry entry is invalid." },
        Error.ModelSourceRequired => .{ .code = .model_source_required, .message = "Model has no reusable download URL. Run kotoba models pull --model-url HTTPS_URL --id ID --checksum SHA256 with a fresh URL." },
        Error.SplitModelUnsupported => .{ .code = .split_model_unsupported, .message = "Split GGUF models are not supported by this command yet. Use a single-file GGUF model." },
        Error.ChecksumFailed => .{ .code = .checksum_failed, .message = "Model checksum verification failed." },
        Error.Timeout => .{ .code = .timeout, .message = "The operation timed out." },
        Error.MarkdownParseFailed => .{ .code = .markdown_parse_failed, .message = "Markdown parsing failed." },
        Error.OutputExists => .{ .code = .output_exists, .message = "Output file already exists. Use --overwrite to replace it." },
        Error.SqliteFailed => .{ .code = .sqlite_failed, .message = "SQLite translation memory operation failed." },
        Error.GlossaryInvalid => .{ .code = .glossary_invalid, .message = "glossary.toml is invalid." },
        Error.UnsupportedLanguagePair => .{ .code = .unsupported_language_pair, .message = "Only en -> ja and ja -> en are supported." },
        Error.InvalidArguments => .{ .code = .invalid_arguments, .message = "Invalid arguments." },
        Error.InvalidUtf8 => .{ .code = .invalid_utf8, .message = "Text must be valid UTF-8." },
        Error.EmbeddedNul => .{ .code = .embedded_nul, .message = "Text must not contain NUL bytes." },
        Error.Interrupted => .{ .code = .interrupted, .message = "Interrupted." },
        Error.PathResolutionFailed => .{ .code = .path_resolution_failed, .message = "Could not resolve XDG paths from absolute XDG values or HOME." },
        else => .{ .code = .io_error, .message = @errorName(err) },
    };
}

test "text encoding error mapping" {
    const cases = [_]struct {
        err: anyerror,
        code: []const u8,
        message: []const u8,
    }{
        .{ .err = Error.InvalidUtf8, .code = "invalid_utf8", .message = "Text must be valid UTF-8." },
        .{ .err = Error.EmbeddedNul, .code = "embedded_nul", .message = "Text must not contain NUL bytes." },
    };

    for (cases) |case| {
        const app_err = fromError(case.err);
        try std.testing.expectEqualStrings(case.code, app_err.code.asText());
        try std.testing.expectEqualStrings(case.message, app_err.message);
        try std.testing.expectEqual(@as(u8, 1), app_err.exitCode());
    }
}

pub fn printHuman(app_err: AppError) void {
    sys.stderrPrint("kotoba: {s}: {s}\n", .{ app_err.code.asText(), app_err.message });
}

pub fn writeJson(app_err: AppError) void {
    sys.stdoutPrint("{{\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}\n", .{ app_err.code.asText(), app_err.message });
}

test "secret URL missing source and invalid arguments error mapping" {
    const missing = fromError(Error.ModelSourceRequired);
    try std.testing.expectEqualStrings("model_source_required", missing.code.asText());
    try std.testing.expectEqual(@as(u8, 1), missing.exitCode());
    try std.testing.expectEqualStrings("Model has no reusable download URL. Run kotoba models pull --model-url HTTPS_URL --id ID --checksum SHA256 with a fresh URL.", missing.message);
    const invalid = fromError(Error.InvalidArguments);
    try std.testing.expectEqualStrings("invalid_arguments", invalid.code.asText());
    try std.testing.expectEqual(@as(u8, 2), invalid.exitCode());
    try std.testing.expectEqualStrings("Invalid arguments.", invalid.message);
}

test "path resolution failure has stable public mapping" {
    const failure = fromError(error.PathResolutionFailed);
    try std.testing.expectEqualStrings("path_resolution_failed", failure.code.asText());
    try std.testing.expectEqualStrings("Could not resolve XDG paths from absolute XDG values or HOME.", failure.message);
    try std.testing.expectEqual(@as(u8, 1), failure.exitCode());
}

test "strict persistence error categories have exact safe messages" {
    const cases = [_]struct { err: anyerror, code: []const u8, message: []const u8 }{
        .{ .err = error.NotInitialized, .code = "not_initialized", .message = "Kotoba is not initialized. Run `kotoba init`." },
        .{ .err = error.ConfigInvalid, .code = "config_invalid", .message = "config.toml is invalid." },
        .{ .err = error.ModelsInvalid, .code = "models_invalid", .message = "models.toml is invalid." },
        .{ .err = error.ConfigSchemaUnsupported, .code = "config_schema_unsupported", .message = "config.toml uses an unsupported schema or version." },
        .{ .err = error.ModelsSchemaUnsupported, .code = "models_schema_unsupported", .message = "models.toml uses an unsupported schema or version." },
        .{ .err = error.AccessDenied, .code = "io_error", .message = "AccessDenied" },
        .{ .err = error.IsDir, .code = "io_error", .message = "IsDir" },
        .{ .err = error.StreamTooLong, .code = "io_error", .message = "StreamTooLong" },
        .{ .err = error.InputOutput, .code = "io_error", .message = "InputOutput" },
        .{ .err = error.OutOfMemory, .code = "io_error", .message = "OutOfMemory" },
    };
    var failures: usize = 0;
    for (cases) |case| {
        const actual = fromError(case.err);
        std.testing.expectEqualStrings(case.code, actual.code.asText()) catch {
            failures += 1;
        };
        std.testing.expectEqualStrings(case.message, actual.message) catch {
            failures += 1;
        };
        std.testing.expectEqual(@as(u8, 1), actual.exitCode()) catch {
            failures += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "filesystem errors map to io error with native names" {
    const filesystem_errors = [_]anyerror{
        error.AccessDenied,
        error.InputOutput,
        error.NoSpaceLeft,
        error.DiskQuota,
        error.FileTooBig,
        error.InvalidFileDescriptor,
        error.OperationUnsupported,
        error.StageNameCollision,
    };
    for (filesystem_errors) |err| {
        const app_err = fromError(err);
        try std.testing.expectEqual(Code.io_error, app_err.code);
        try std.testing.expectEqual(@as(u8, 1), app_err.exitCode());
        try std.testing.expectEqualStrings(@errorName(err), app_err.message);
    }
    const output_exists = fromError(Error.OutputExists);
    try std.testing.expectEqual(Code.output_exists, output_exists.code);
    try std.testing.expectEqualStrings("Output file already exists. Use --overwrite to replace it.", output_exists.message);
}
