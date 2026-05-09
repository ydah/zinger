const std = @import("std");

pub const Row = struct {
    values: [][]u8,

    pub fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        for (self.values) |value| allocator.free(value);
        allocator.free(self.values);
        self.* = undefined;
    }
};

pub fn encode(allocator: std.mem.Allocator, values: []const []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);

    try appendU32(&bytes, allocator, @intCast(values.len));
    for (values) |value| {
        try bytes.append(allocator, 1); // text
        try appendU32(&bytes, allocator, @intCast(value.len));
        try bytes.appendSlice(allocator, value);
    }

    return try bytes.toOwnedSlice(allocator);
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Row {
    var cursor = Cursor{ .bytes = bytes };
    const value_count = try cursor.readU32AsUsize();
    var values: std.ArrayList([]u8) = .empty;
    errdefer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }

    for (0..value_count) |_| {
        const tag = try cursor.readByte();
        if (tag != 1) return error.UnsupportedValueType;
        const value_len = try cursor.readU32AsUsize();
        const value = try allocator.dupe(u8, try cursor.take(value_len));
        errdefer allocator.free(value);
        try values.append(allocator, value);
    }
    if (!cursor.done()) return error.CorruptRow;

    return .{ .values = try values.toOwnedSlice(allocator) };
}

fn appendU32(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, value, .little);
    try bytes.appendSlice(allocator, &encoded);
}

const Cursor = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn readU32AsUsize(self: *Cursor) !usize {
        const raw = try self.take(4);
        return std.mem.readInt(u32, raw[0..4], .little);
    }

    fn readByte(self: *Cursor) !u8 {
        const raw = try self.take(1);
        return raw[0];
    }

    fn take(self: *Cursor, len: usize) ![]const u8 {
        if (self.offset + len > self.bytes.len) return error.CorruptRow;
        const start = self.offset;
        self.offset += len;
        return self.bytes[start..self.offset];
    }

    fn done(self: *const Cursor) bool {
        return self.offset == self.bytes.len;
    }
};

test "row encode decode" {
    const values = [_][]const u8{ "1", "Alice" };
    const encoded = try encode(std.testing.allocator, &values);
    defer std.testing.allocator.free(encoded);

    var decoded = try decode(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), decoded.values.len);
    try std.testing.expectEqualStrings("1", decoded.values[0]);
    try std.testing.expectEqualStrings("Alice", decoded.values[1]);
}
