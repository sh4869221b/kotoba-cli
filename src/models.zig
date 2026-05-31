const std = @import("std");

const checksum_module = @import("models/checksum.zig");
const huggingface = @import("models/huggingface.zig");
const install = @import("models/install.zig");
const registry = @import("models/registry.zig");
const types = @import("models/types.zig");
const validation = @import("models/validation.zig");

pub const Model = types.Model;
pub const List = types.List;
pub const HfSpec = huggingface.HfSpec;

pub const defaultTemplate = registry.defaultTemplate;
pub const ensure = registry.ensure;
pub const load = registry.load;
pub const parse = registry.parse;
pub const find = registry.find;
pub const installedPath = registry.installedPath;
pub const upsert = registry.upsert;
pub const removeById = registry.removeById;
pub const save = registry.save;

pub const validateId = validation.validateId;
pub const validateGgufPath = validation.validateGgufPath;
pub const validateHfRfilename = validation.validateHfRfilename;
pub const validateSingleHfGgufFilename = validation.validateSingleHfGgufFilename;

pub const verifyModel = checksum_module.verifyModel;
pub const acquire = install.acquire;
pub const installLocalFile = install.installLocalFile;

pub const parseHfRepo = huggingface.parseHfRepo;
pub const defaultIdFromHf = huggingface.defaultIdFromHf;
pub const hfDownloadUrl = huggingface.hfDownloadUrl;
pub const resolveHfFile = huggingface.resolveHfFile;

pub const verifySha256 = checksum_module.verifySha256;

test {
    _ = checksum_module;
    _ = huggingface;
    _ = install;
    _ = registry;
    _ = types;
    _ = validation;
}
