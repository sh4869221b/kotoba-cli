const std = @import("std");
const config = @import("../config.zig");
const errors = @import("../errors.zig");
const lang = @import("../lang.zig");
const output = @import("../output.zig");
const sys = @import("../sys.zig");
const translate = @import("../translate.zig");
const xdg = @import("../xdg.zig");
const args = @import("args.zig");

pub fn run(allocator: std.mem.Allocator, paths: xdg.Paths, cmd_args: []const []const u8) !u8 {
    var cursor = args.ArgCursor.init(cmd_args);
    var opts = translate.Options{};
    while (cursor.peek()) |a| {
        if (std.mem.eql(u8, a, "--from")) {
            _ = cursor.nextValue();
            opts.source_lang = try lang.Language.parse(try cursor.requireValue());
        } else if (std.mem.eql(u8, a, "--to")) {
            _ = cursor.nextValue();
            opts.target_lang = try lang.Language.parse(try cursor.requireValue());
        } else if (std.mem.eql(u8, a, "--mode")) {
            _ = cursor.nextValue();
            opts.mode = try config.Mode.parse(try cursor.requireValue());
        } else if (std.mem.eql(u8, a, "--format")) {
            _ = cursor.nextValue();
            opts.format = try config.OutputFormat.parse(try cursor.requireValue());
        } else if (std.mem.eql(u8, a, "--include-source")) {
            _ = cursor.nextValue();
            opts.include_source = true;
        } else if (std.mem.eql(u8, a, "--file")) {
            _ = cursor.nextValue();
            opts.file_path = try cursor.requireValue();
        } else if (std.mem.eql(u8, a, "--output")) {
            _ = cursor.nextValue();
            opts.output_path = try cursor.requireValue();
        } else if (std.mem.eql(u8, a, "--overwrite")) {
            _ = cursor.nextValue();
            opts.overwrite = true;
        } else if (std.mem.eql(u8, a, "--no-memory")) {
            _ = cursor.nextValue();
            opts.no_memory = true;
        } else if (std.mem.eql(u8, a, "--no-glossary")) {
            _ = cursor.nextValue();
            opts.no_glossary = true;
        } else if (std.mem.eql(u8, a, "--debug")) {
            _ = cursor.nextValue();
            opts.debug = true;
        } else {
            if (opts.text != null) return errors.Error.InvalidArguments;
            opts.text = a;
            _ = cursor.nextValue();
        }
    }
    const cfg = try config.load(allocator, paths.config_file);
    if (translate.diagnosticsEnabled(cfg, opts)) {
        sys.stderrPrint("kotoba: debug: diagnostics enabled\n", .{});
    }
    const kind = translate.readKindForOptions(opts.format, opts.file_path);
    const res = try translate.run(allocator, paths, cfg, opts);
    if (try translate.writeOutput(allocator, res, kind, opts.file_path, opts.output_path, opts.overwrite)) return 0;
    const fmt = opts.format orelse if (kind == .markdown) config.OutputFormat.markdown else cfg.default_output;
    try output.write(fmt, res, opts.include_source);
    return 0;
}
