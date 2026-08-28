const std = @import("std");

const backend = @import("backend.zig");
const cli = @import("cli.zig");
const config = @import("config.zig");
const doctor = @import("doctor.zig");
const errors = @import("errors.zig");
const file_close = @import("file_close.zig");
const staged_output = @import("staged_output.zig");
const glossary = @import("glossary.zig");
const input = @import("input.zig");
const lang = @import("lang.zig");
const llama = @import("llama.zig");
const markdown = @import("markdown.zig");
const memory = @import("memory.zig");
const models = @import("models.zig");
const net = @import("net.zig");
const output = @import("output.zig");
const ownership_test_support = @import("ownership_test_support.zig");
const prompt = @import("prompt.zig");
const fs = @import("fs.zig");
const translate = @import("translate.zig");
const translation_contract = @import("translation_contract.zig");
const xdg = @import("xdg.zig");
const sys = @import("sys.zig");
const strict_toml = @import("strict_toml.zig");
const text = @import("text.zig");
const url = @import("url.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var argv_arena = std.heap.ArenaAllocator.init(allocator);
    const exit_code = blk: {
        defer argv_arena.deinit();
        const args = try init.minimal.args.toSlice(argv_arena.allocator());
        break :blk cli.run(allocator, args) catch |err| err_blk: {
            const app_err = errors.fromError(err);
            if (cli.errorPrefersJson(args)) {
                errors.writeJson(app_err);
            } else {
                errors.printHuman(app_err);
            }
            break :err_blk app_err.exitCode();
        };
    };
    std.process.exit(exit_code);
}

test {
    std.testing.refAllDecls(backend);
    std.testing.refAllDecls(cli);
    std.testing.refAllDecls(config);
    std.testing.refAllDecls(doctor);
    std.testing.refAllDecls(errors);
    std.testing.refAllDecls(file_close);
    std.testing.refAllDecls(staged_output);
    std.testing.refAllDecls(glossary);
    std.testing.refAllDecls(input);
    std.testing.refAllDecls(lang);
    std.testing.refAllDecls(llama);
    std.testing.refAllDecls(markdown);
    std.testing.refAllDecls(memory);
    std.testing.refAllDecls(models);
    std.testing.refAllDecls(net);
    std.testing.refAllDecls(output);
    std.testing.refAllDecls(ownership_test_support);
    std.testing.refAllDecls(prompt);
    std.testing.refAllDecls(fs);
    std.testing.refAllDecls(translate);
    std.testing.refAllDecls(translation_contract);
    std.testing.refAllDecls(xdg);
    std.testing.refAllDecls(sys);
    std.testing.refAllDecls(strict_toml);
    std.testing.refAllDecls(text);
    std.testing.refAllDecls(url);
}
