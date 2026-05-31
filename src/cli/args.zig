const std = @import("std");
const errors = @import("../errors.zig");

pub const ArgCursor = struct {
    args: []const []const u8,
    index: usize,

    pub fn init(args: []const []const u8) ArgCursor {
        return .{ .args = args, .index = 0 };
    }

    pub fn nextValue(self: *ArgCursor) ?[]const u8 {
        if (self.index >= self.args.len) return null;
        const val = self.args[self.index];
        self.index += 1;
        return val;
    }

    pub fn requireValue(self: *ArgCursor) ![]const u8 {
        if (self.index >= self.args.len) return errors.Error.InvalidArguments;
        const val = self.args[self.index];
        self.index += 1;
        return val;
    }

    pub fn flag(self: *ArgCursor, name: []const u8) bool {
        if (self.index >= self.args.len) return false;
        if (std.mem.eql(u8, self.args[self.index], name)) {
            self.index += 1;
            return true;
        }
        return false;
    }

    pub fn peek(self: ArgCursor) ?[]const u8 {
        if (self.index >= self.args.len) return null;
        return self.args[self.index];
    }

    pub fn remaining(self: ArgCursor) []const []const u8 {
        return self.args[self.index..];
    }
};

pub fn hasOptionValue(args: []const []const u8, option: []const u8, value: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], option) and std.mem.eql(u8, args[i + 1], value)) return true;
    }
    return false;
}
