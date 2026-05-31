const std = @import("std");
const errors = @import("../errors.zig");
const net = @import("../net.zig");
const validation = @import("validation.zig");

pub const HfSpec = struct {
    repo: []const u8,
    quant: []const u8,
};

pub fn parseHfRepo(spec: []const u8) !HfSpec {
    if (spec.len == 0 or std.mem.indexOfScalar(u8, spec, '/') == null) return errors.Error.InvalidArguments;
    if (std.mem.lastIndexOfScalar(u8, spec, ':')) |idx| {
        if (idx == 0 or idx + 1 >= spec.len) return errors.Error.InvalidArguments;
        return .{ .repo = spec[0..idx], .quant = spec[idx + 1 ..] };
    }
    return .{ .repo = spec, .quant = "Q4_K_M" };
}

pub fn defaultIdFromHf(allocator: std.mem.Allocator, hf: HfSpec) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    for (hf.repo) |ch| {
        if (std.ascii.isAlphanumeric(ch)) try out.append(std.ascii.toLower(ch)) else try out.append('-');
    }
    try out.append('-');
    for (hf.quant) |ch| {
        if (std.ascii.isAlphanumeric(ch)) try out.append(std.ascii.toLower(ch)) else try out.append('-');
    }
    return out.toOwnedSlice();
}

pub fn hfDownloadUrl(allocator: std.mem.Allocator, repo: []const u8, filename: []const u8) ![]const u8 {
    try validation.validateSingleHfGgufFilename(filename);
    return std.fmt.allocPrint(allocator, "https://huggingface.co/{s}/resolve/main/{s}", .{ repo, filename });
}

pub fn resolveHfFile(allocator: std.mem.Allocator, hf: HfSpec, explicit_file: []const u8) ![]const u8 {
    if (explicit_file.len > 0) {
        try validation.validateSingleHfGgufFilename(explicit_file);
        return allocator.dupe(u8, explicit_file);
    }
    return findHfFile(allocator, hf.repo, hf.quant);
}

fn findHfFile(allocator: std.mem.Allocator, repo: []const u8, quant: []const u8) ![]const u8 {
    const url = try std.fmt.allocPrint(allocator, "https://huggingface.co/api/models/{s}", .{repo});
    defer allocator.free(url);
    const body = net.fetchAlloc(allocator, url, 16 * 1024 * 1024) catch return errors.Error.ModelRegistryInvalid;
    defer allocator.free(body);
    if (try findFilenameInHfJson(allocator, body, quant, true)) |name| {
        errdefer allocator.free(name);
        try validation.validateSingleHfGgufFilename(name);
        return name;
    }
    return errors.Error.ModelRegistryInvalid;
}

pub fn findFilenameInHfJson(allocator: std.mem.Allocator, json: []const u8, quant: []const u8, require_quant: bool) !?[]const u8 {
    var found_split = false;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, json, start, "\"rfilename\"")) |key_idx| {
        const colon = std.mem.indexOfScalarPos(u8, json, key_idx, ':') orelse return null;
        const quote = std.mem.indexOfScalarPos(u8, json, colon + 1, '"') orelse return null;
        const end = std.mem.indexOfScalarPos(u8, json, quote + 1, '"') orelse return null;
        const name = json[quote + 1 .. end];
        start = end + 1;
        if (!std.mem.endsWith(u8, name, ".gguf")) continue;
        if (require_quant and !containsIgnoreCase(name, quant)) continue;
        if (validation.isSplitGgufFilename(name)) {
            found_split = true;
            continue;
        }
        return try allocator.dupe(u8, name);
    }
    if (found_split) return errors.Error.SplitModelUnsupported;
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "hugging face spec and url helpers" {
    const hf = try parseHfRepo("ggml-org/Example-GGUF:Q4_K_M");
    try std.testing.expectEqualStrings("ggml-org/Example-GGUF", hf.repo);
    try std.testing.expectEqualStrings("Q4_K_M", hf.quant);
    const id = try defaultIdFromHf(std.testing.allocator, hf);
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("ggml-org-example-gguf-q4-k-m", id);
    const url = try hfDownloadUrl(std.testing.allocator, hf.repo, "Example-Q4_K_M.gguf");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://huggingface.co/ggml-org/Example-GGUF/resolve/main/Example-Q4_K_M.gguf", url);
    const nested_url = try hfDownloadUrl(std.testing.allocator, hf.repo, "gguf/Example-Q4_K_M.gguf");
    defer std.testing.allocator.free(nested_url);
    try std.testing.expectEqualStrings("https://huggingface.co/ggml-org/Example-GGUF/resolve/main/gguf/Example-Q4_K_M.gguf", nested_url);
    try std.testing.expectError(errors.Error.InvalidArguments, hfDownloadUrl(std.testing.allocator, hf.repo, "../Example-Q4_K_M.gguf"));
    try std.testing.expectError(errors.Error.InvalidArguments, hfDownloadUrl(std.testing.allocator, hf.repo, "/Example-Q4_K_M.gguf"));
    try std.testing.expectError(errors.Error.InvalidArguments, hfDownloadUrl(std.testing.allocator, hf.repo, "gguf//Example-Q4_K_M.gguf"));
    try std.testing.expectError(errors.Error.InvalidArguments, hfDownloadUrl(std.testing.allocator, hf.repo, "gguf/Example-Q4_K_M.gguf?download=1"));
    try std.testing.expectError(errors.Error.SplitModelUnsupported, hfDownloadUrl(std.testing.allocator, hf.repo, "Example-Q4_K_M-00001-of-00002.gguf"));
}

test "parseHfRepo uses default quant when omitted" {
    const hf = try parseHfRepo("owner/repo");
    try std.testing.expectEqualStrings("owner/repo", hf.repo);
    try std.testing.expectEqualStrings("Q4_K_M", hf.quant);
}

test "resolveHfFile returns explicit file without metadata lookup" {
    const hf = try parseHfRepo("owner/repo:Q4_K_M");
    const file = try resolveHfFile(std.testing.allocator, hf, "nested/model-Q4_K_M.gguf");
    defer std.testing.allocator.free(file);
    try std.testing.expectEqualStrings("nested/model-Q4_K_M.gguf", file);
}

test "hugging face json selects quantized gguf" {
    const json =
        \\{"siblings":[{"rfilename":"README.md"},{"rfilename":"Model-F16.gguf"},{"rfilename":"Model-Q4_K_M.gguf"}]}
    ;
    const name = (try findFilenameInHfJson(std.testing.allocator, json, "Q4_K_M", true)) orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("Model-Q4_K_M.gguf", name);
}

test "hugging face json selects quantized gguf case-insensitively" {
    const json =
        \\{"siblings":[{"rfilename":"README.md"},{"rfilename":"Model-q4_k_m.gguf"}]}
    ;
    const name = (try findFilenameInHfJson(std.testing.allocator, json, "Q4_K_M", true)) orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("Model-q4_k_m.gguf", name);
}

test "hugging face json skips split gguf when a single-file match exists" {
    const json =
        \\{"siblings":[{"rfilename":"Model-Q4_K_M-00001-of-00002.gguf"},{"rfilename":"Model-Q4_K_M.gguf"}]}
    ;
    const name = (try findFilenameInHfJson(std.testing.allocator, json, "Q4_K_M", true)) orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("Model-Q4_K_M.gguf", name);
}

test "hugging face json reports split gguf when it is the only match" {
    const json =
        \\{"siblings":[{"rfilename":"Model-Q4_K_M-00001-of-00002.gguf"},{"rfilename":"Model-Q8_0.gguf"}]}
    ;
    try std.testing.expectError(errors.Error.SplitModelUnsupported, findFilenameInHfJson(std.testing.allocator, json, "Q4_K_M", true));
}

test "hugging face json does not fall back to the wrong quantization" {
    const json =
        \\{"siblings":[{"rfilename":"README.md"},{"rfilename":"Model-F16.gguf"}]}
    ;
    try std.testing.expect((try findFilenameInHfJson(std.testing.allocator, json, "Q4_K_M", true)) == null);
}
