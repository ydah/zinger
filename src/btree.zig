const std = @import("std");
const buffer = @import("buffer.zig");
const disk = @import("disk.zig");
const Leaf = @import("btree/leaf.zig").Leaf;

const PageId = disk.PageId;
const Buffer = buffer.Buffer;
const BufferPoolManager = buffer.BufferPoolManager;

const Pair = struct {
    const Self = @This();
    key: []u8,
    value: []u8,

    pub fn toBytes(self: *Self, allocator: *std.mem.Allocator) ![]u8 {
        var bytes = try allocator.alloc(u8, self.key.len + self.value.len + 8);
        var writer = std.io.fixedBufferStream(bytes[0..]).writer();
        try writer.writeIntLittle(u64, self.key.len);
        try writer.writeAll(self.key);
        try writer.writeIntLittle(u64, self.value.len);
        try writer.writeAll(self.value);
        return bytes;
    }

    pub fn fromBytes(bytes: []const u8, allocator: *std.mem.Allocator) !Pair {
        var reader = std.io.fixedBufferStream(bytes).reader();
        const key_len = try reader.readIntLittle(u64);
        const key = try allocator.alloc(u8, key_len);
        try reader.readAll(key);
        const value_len = try reader.readIntLittle(u64);
        const value = try allocator.alloc(u8, value_len);
        try reader.readAll(value);
        return Pair{ .key = key, .value = value };
    }
};

const SearchMode = union(enum) {
    Start: void,
    Key: []const u8,

    pub fn childPageId(self: SearchMode, branch: *Branch) usize {
        return switch (self) {
            SearchMode.Start => branch.childAt(0),
            SearchMode.Key => |key| branch.searchChild(key),
        };
    }

    pub fn tupleSlotId(self: SearchMode, leaf: *Leaf) std.math.Error!usize {
        return switch (self) {
            SearchMode.Start => std.math.Error(0),
            SearchMode.Key => |key| leaf.searchSlotId(key),
        };
    }
};
