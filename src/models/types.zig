pub const Model = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    profile: []const u8 = "custom",
    languages_en: bool = false,
    languages_ja: bool = false,
    format: []const u8 = "gguf",
    quantization: []const u8 = "",
    context_length: u32 = 0,
    size: []const u8 = "",
    path: []const u8 = "",
    download_url: []const u8 = "",
    checksum: []const u8 = "",
    license: []const u8 = "",
    recommended: bool = false,
    notes: []const u8 = "",
};

pub const List = struct {
    models: []Model,
};
