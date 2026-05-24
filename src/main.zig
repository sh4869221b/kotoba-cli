const std = @import("std");

const backend = @import("backend.zig");
const cli = @import("cli.zig");
const config = @import("config.zig");
const doctor = @import("doctor.zig");
const errors = @import("errors.zig");
const glossary = @import("glossary.zig");
const input = @import("input.zig");
const lang = @import("lang.zig");
const llama = @import("llama.zig");
const markdown = @import("markdown.zig");
const memory = @import("memory.zig");
const models = @import("models.zig");
const net = @import("net.zig");
const output = @import("output.zig");
const prompt = @import("prompt.zig");
const translate = @import("translate.zig");
const xdg = @import("xdg.zig");
const sys = @import("sys.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);

    const exit_code = cli.run(allocator, args) catch |err| blk: {
        const app_err = errors.fromError(err);
        if (cli.errorPrefersJson(args)) {
            errors.writeJson(app_err);
        } else {
            errors.printHuman(app_err);
        }
        break :blk app_err.exitCode();
    };
    std.process.exit(exit_code);
}

test {
    std.testing.refAllDecls(backend);
    std.testing.refAllDecls(cli);
    std.testing.refAllDecls(config);
    std.testing.refAllDecls(doctor);
    std.testing.refAllDecls(errors);
    std.testing.refAllDecls(glossary);
    std.testing.refAllDecls(input);
    std.testing.refAllDecls(lang);
    std.testing.refAllDecls(llama);
    std.testing.refAllDecls(markdown);
    std.testing.refAllDecls(memory);
    std.testing.refAllDecls(models);
    std.testing.refAllDecls(net);
    std.testing.refAllDecls(output);
    std.testing.refAllDecls(prompt);
    std.testing.refAllDecls(translate);
    std.testing.refAllDecls(xdg);
    std.testing.refAllDecls(sys);
}
