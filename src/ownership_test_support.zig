const std = @import("std");

/// Test-only allocator measurement with no allocations for its own accounting.
pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    live_bytes: usize = 0,
    live_allocations: usize = 0,
    peak_bytes: usize = 0,
    window_peak_bytes: usize = 0,
    requested_bytes: usize = 0,
    released_bytes: usize = 0,
    allocation_events: usize = 0,
    resize_events: usize = 0,
    remap_events: usize = 0,
    free_events: usize = 0,

    pub const Error = error{ScratchGrowth};

    pub const Metrics = struct {
        live_bytes: usize,
        live_allocations: usize,
        peak_bytes: usize,
        window_peak_bytes: usize,
        requested_bytes: usize,
        released_bytes: usize,
        allocation_events: usize,
        resize_events: usize,
        remap_events: usize,
        free_events: usize,
    };

    pub fn init(backing: std.mem.Allocator) CountingAllocator {
        return .{ .backing = backing };
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn metrics(self: *const CountingAllocator) Metrics {
        return .{
            .live_bytes = self.live_bytes,
            .live_allocations = self.live_allocations,
            .peak_bytes = self.peak_bytes,
            .window_peak_bytes = self.window_peak_bytes,
            .requested_bytes = self.requested_bytes,
            .released_bytes = self.released_bytes,
            .allocation_events = self.allocation_events,
            .resize_events = self.resize_events,
            .remap_events = self.remap_events,
            .free_events = self.free_events,
        };
    }

    pub fn resetWindow(self: *CountingAllocator) void {
        self.window_peak_bytes = self.live_bytes;
    }

    pub fn assertLiveBytesAtMost(self: *const CountingAllocator, maximum: usize) Error!void {
        if (self.live_bytes > maximum) return error.ScratchGrowth;
    }

    fn recordResize(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            const delta = new_len - old_len;
            self.live_bytes += delta;
            self.requested_bytes += delta;
        } else {
            const delta = old_len - new_len;
            self.live_bytes -= delta;
            self.released_bytes += delta;
        }
        self.observePeak();
    }

    fn observePeak(self: *CountingAllocator) void {
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
        self.window_peak_bytes = @max(self.window_peak_bytes, self.live_bytes);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const memory = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.live_bytes += len;
        self.live_allocations += 1;
        self.requested_bytes += len;
        self.allocation_events += 1;
        self.observePeak();
        return memory;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.recordResize(memory.len, new_len);
        self.resize_events += 1;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const moved = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.recordResize(memory.len, new_len);
        self.remap_events += 1;
        return moved;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
        self.live_bytes -= memory.len;
        self.live_allocations -= 1;
        self.released_bytes += memory.len;
        self.free_events += 1;
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

const ScriptedAllocator = struct {
    storage: [1024]u8 = undefined,
    next_offset: usize = 0,
    fail_alloc: bool = false,
    fail_resize: bool = false,
    fail_remap: bool = false,
    move_remap: bool = false,

    fn allocator(self: *ScriptedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = alignment;
        _ = ret_addr;
        const self: *ScriptedAllocator = @ptrCast(@alignCast(ctx));
        if (self.fail_alloc or self.next_offset + len > self.storage.len) return null;
        const start = self.next_offset;
        self.next_offset += len;
        return self.storage[start..].ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = alignment;
        _ = ret_addr;
        const self: *ScriptedAllocator = @ptrCast(@alignCast(ctx));
        if (self.fail_resize) return false;
        const start = @intFromPtr(memory.ptr) - @intFromPtr(self.storage[0..].ptr);
        if (start + memory.len != self.next_offset or start + new_len > self.storage.len) return false;
        self.next_offset = start + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ScriptedAllocator = @ptrCast(@alignCast(ctx));
        if (self.fail_remap) return null;
        if (!self.move_remap) {
            if (!resize(ctx, memory, alignment, new_len, ret_addr)) return null;
            return memory.ptr;
        }
        if (self.next_offset + new_len > self.storage.len) return null;
        const start = self.next_offset;
        self.next_offset += new_len;
        @memcpy(self.storage[start..][0..@min(memory.len, new_len)], memory[0..@min(memory.len, new_len)]);
        return self.storage[start..].ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = ret_addr;
    }
};

test "ownership/counter tracks requested-byte lifecycle" {
    var backing = ScriptedAllocator{};
    var counter = CountingAllocator.init(backing.allocator());
    const allocator = counter.allocator();

    var bytes = try allocator.alloc(u8, 64);
    try std.testing.expect(allocator.resize(bytes, 128));
    bytes = bytes.ptr[0..128];
    try std.testing.expect(allocator.resize(bytes, 32));
    bytes = bytes.ptr[0..32];
    try std.testing.expectEqual(@as(usize, 128), counter.peak_bytes);
    counter.resetWindow();
    try std.testing.expectEqual(@as(usize, 32), counter.window_peak_bytes);
    allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, 0), counter.live_bytes);
    try std.testing.expectEqual(@as(usize, 0), counter.live_allocations);
    try std.testing.expectEqual(@as(usize, 128), counter.peak_bytes);
    try std.testing.expectEqual(@as(usize, 32), counter.window_peak_bytes);
    try std.testing.expectEqual(@as(usize, 128), counter.requested_bytes);
    try std.testing.expectEqual(@as(usize, 128), counter.released_bytes);
    try std.testing.expectEqual(@as(usize, 1), counter.allocation_events);
    try std.testing.expectEqual(@as(usize, 2), counter.resize_events);
    try std.testing.expectEqual(@as(usize, 1), counter.free_events);
}

test "ownership/counter records remap same-address and moved success" {
    var backing = ScriptedAllocator{};
    var counter = CountingAllocator.init(backing.allocator());
    const allocator = counter.allocator();

    var bytes = try allocator.alloc(u8, 64);
    var expected: [96]u8 = undefined;
    for (&expected, 0..) |*byte, index| byte.* = @intCast(index);
    @memcpy(bytes, expected[0..64]);
    const same = allocator.rawRemap(bytes, .of(u8), 96, @returnAddress()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@intFromPtr(bytes.ptr), @intFromPtr(same));
    bytes = same[0..96];
    @memcpy(bytes, expected[0..]);
    backing.move_remap = true;
    const moved = allocator.rawRemap(bytes, .of(u8), 128, @returnAddress()) orelse return error.TestUnexpectedResult;
    try std.testing.expect(@intFromPtr(bytes.ptr) != @intFromPtr(moved));
    const moved_bytes: []u8 = moved[0..128];
    try std.testing.expectEqualSlices(u8, expected[0..], moved_bytes[0..96]);
    allocator.free(moved_bytes);

    try std.testing.expectEqual(@as(usize, 0), counter.live_bytes);
    try std.testing.expectEqual(@as(usize, 2), counter.remap_events);
    try std.testing.expectEqual(@as(usize, 128), counter.peak_bytes);
}

test "ownership/counter leaves metrics unchanged when allocation operations fail" {
    var backing = ScriptedAllocator{ .fail_alloc = true };
    var counter = CountingAllocator.init(backing.allocator());
    const allocator = counter.allocator();
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 64));
    try std.testing.expectEqualDeep(CountingAllocator.Metrics{
        .live_bytes = 0,
        .live_allocations = 0,
        .peak_bytes = 0,
        .window_peak_bytes = 0,
        .requested_bytes = 0,
        .released_bytes = 0,
        .allocation_events = 0,
        .resize_events = 0,
        .remap_events = 0,
        .free_events = 0,
    }, counter.metrics());

    backing.fail_alloc = false;
    const bytes = try allocator.alloc(u8, 64);
    const before = counter.metrics();
    backing.fail_resize = true;
    try std.testing.expect(!allocator.resize(bytes, 128));
    try std.testing.expectEqualDeep(before, counter.metrics());
    backing.fail_remap = true;
    try std.testing.expect(allocator.rawRemap(bytes, .of(u8), 128, @returnAddress()) == null);
    try std.testing.expectEqualDeep(before, counter.metrics());
    allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), counter.live_bytes);
}

test "ownership/counter detects retained scratch" {
    var backing = ScriptedAllocator{};
    var counter = CountingAllocator.init(backing.allocator());
    const allocator = counter.allocator();
    const first = try allocator.alloc(u8, 64);
    const second = try allocator.alloc(u8, 64);
    try std.testing.expectError(error.ScratchGrowth, counter.assertLiveBytesAtMost(64));
    allocator.free(second);
    allocator.free(first);
    try std.testing.expectEqual(@as(usize, 0), counter.live_bytes);
    try std.testing.expectEqual(@as(usize, 0), counter.live_allocations);
}
