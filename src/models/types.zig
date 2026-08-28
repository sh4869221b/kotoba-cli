const std = @import("std");

/// Borrowed model fields; literal inputs never require deinit.
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
    source_url: []const u8 = "",
    checksum: []const u8 = "",
    license: []const u8 = "",
    recommended: bool = false,
    notes: []const u8 = "",
};

pub const List = struct {
    models: []Model,
};

/// Owns every model string, including defaults; move-only by convention.
pub const OwnedModel = struct {
    allocator: std.mem.Allocator,
    value: Model,

    pub fn clone(allocator: std.mem.Allocator, model: Model) !OwnedModel {
        var value = model;
        var initialized: usize = 0;
        errdefer inline for (std.meta.fields(Model), 0..) |field, i| {
            if (field.type == []const u8 and i < initialized) allocator.free(@field(value, field.name));
        };
        inline for (std.meta.fields(Model), 0..) |field, i| {
            if (field.type == []const u8) @field(value, field.name) = try allocator.dupe(u8, @field(model, field.name));
            initialized = i + 1;
        }
        return .{ .allocator = allocator, .value = value };
    }

    /// Borrowed until mutation or deinit.
    pub fn view(self: *const OwnedModel) Model {
        return self.value;
    }

    pub fn deinit(self: *OwnedModel) void {
        inline for (std.meta.fields(Model)) |field| {
            if (field.type == []const u8) self.allocator.free(@field(self.value, field.name));
        }
        self.* = undefined;
    }
};

/// Owns its array and every model graph; move-only by convention.
pub const OwnedList = struct {
    allocator: std.mem.Allocator,
    value: List,

    /// Borrowed until mutation or deinit, including all find results.
    pub fn view(self: *const OwnedList) List {
        return self.value;
    }

    pub fn deinit(self: *OwnedList) void {
        for (self.value.models) |model| {
            var owner: OwnedModel = .{ .allocator = self.allocator, .value = model };
            owner.deinit();
        }
        self.allocator.free(self.value.models);
        self.* = undefined;
    }
};
