const std = @import("std");

pub const ColumnType = enum(u8) {
    text = 1,
};

pub const Column = struct {
    name: []u8,
    column_type: ColumnType,
    primary_key: bool,
};

pub const TableSchema = struct {
    name: []u8,
    columns: []Column,

    pub fn deinit(self: *TableSchema, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.columns) |*column| allocator.free(column.name);
        allocator.free(self.columns);
        self.* = undefined;
    }

    pub fn primaryKeyIndex(self: *const TableSchema) !usize {
        for (self.columns, 0..) |column, index| {
            if (column.primary_key) return index;
        }
        return error.MissingPrimaryKey;
    }

    pub fn columnIndex(self: *const TableSchema, name: []const u8) !usize {
        for (self.columns, 0..) |column, index| {
            if (std.mem.eql(u8, column.name, name)) return index;
        }
        return error.UnknownColumn;
    }
};

pub fn catalogKey(allocator: std.mem.Allocator, table_name: []const u8) ![]u8 {
    return try prefixedKey(allocator, "\x00catalog:", table_name, null);
}

pub fn rowKey(allocator: std.mem.Allocator, table_name: []const u8, primary_key: []const u8) ![]u8 {
    return try prefixedKey(allocator, "\x00row:", table_name, primary_key);
}

pub fn rowPrefix(allocator: std.mem.Allocator, table_name: []const u8) ![]u8 {
    return try prefixedKey(allocator, "\x00row:", table_name, "");
}

pub fn rowRangeEndKey(allocator: std.mem.Allocator, table_name: []const u8) ![]u8 {
    var key: std.ArrayList(u8) = .empty;
    errdefer key.deinit(allocator);
    try key.appendSlice(allocator, "\x00row:");
    try key.appendSlice(allocator, table_name);
    try key.append(allocator, 1);
    return try key.toOwnedSlice(allocator);
}

pub fn encodeSchema(allocator: std.mem.Allocator, schema: TableSchema) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);

    try appendU32(&bytes, allocator, @intCast(schema.name.len));
    try bytes.appendSlice(allocator, schema.name);
    try appendU32(&bytes, allocator, @intCast(schema.columns.len));
    for (schema.columns) |column| {
        try appendU32(&bytes, allocator, @intCast(column.name.len));
        try bytes.appendSlice(allocator, column.name);
        try bytes.append(allocator, @intFromEnum(column.column_type));
        try bytes.append(allocator, if (column.primary_key) 1 else 0);
    }

    return try bytes.toOwnedSlice(allocator);
}

pub fn decodeSchema(allocator: std.mem.Allocator, bytes: []const u8) !TableSchema {
    var cursor = Cursor{ .bytes = bytes };

    const table_name_len = try cursor.readU32AsUsize();
    const table_name = try allocator.dupe(u8, try cursor.take(table_name_len));
    errdefer allocator.free(table_name);

    const column_count = try cursor.readU32AsUsize();
    var columns: std.ArrayList(Column) = .empty;
    errdefer {
        for (columns.items) |*column| allocator.free(column.name);
        columns.deinit(allocator);
    }

    var primary_count: usize = 0;
    for (0..column_count) |_| {
        const name_len = try cursor.readU32AsUsize();
        const column_name = try allocator.dupe(u8, try cursor.take(name_len));
        errdefer allocator.free(column_name);
        const type_byte = try cursor.readByte();
        const column_type: ColumnType = switch (type_byte) {
            @intFromEnum(ColumnType.text) => .text,
            else => return error.UnsupportedColumnType,
        };
        const primary_key = (try cursor.readByte()) != 0;
        if (primary_key) primary_count += 1;
        try columns.append(allocator, .{
            .name = column_name,
            .column_type = column_type,
            .primary_key = primary_key,
        });
    }

    if (primary_count != 1) return error.InvalidPrimaryKey;
    if (!cursor.done()) return error.CorruptCatalog;

    return .{
        .name = table_name,
        .columns = try columns.toOwnedSlice(allocator),
    };
}

fn prefixedKey(allocator: std.mem.Allocator, prefix: []const u8, table_name: []const u8, suffix: ?[]const u8) ![]u8 {
    var key: std.ArrayList(u8) = .empty;
    errdefer key.deinit(allocator);
    try key.appendSlice(allocator, prefix);
    try key.appendSlice(allocator, table_name);
    if (suffix) |value| {
        try key.append(allocator, 0);
        try key.appendSlice(allocator, value);
    }
    return try key.toOwnedSlice(allocator);
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
        if (self.offset + len > self.bytes.len) return error.CorruptCatalog;
        const start = self.offset;
        self.offset += len;
        return self.bytes[start..self.offset];
    }

    fn done(self: *const Cursor) bool {
        return self.offset == self.bytes.len;
    }
};

test "catalog schema encode decode" {
    const allocator = std.testing.allocator;
    const table_name = try allocator.dupe(u8, "users");
    errdefer allocator.free(table_name);
    const columns = try allocator.alloc(Column, 2);
    columns[0] = .{ .name = try allocator.dupe(u8, "id"), .column_type = .text, .primary_key = true };
    columns[1] = .{ .name = try allocator.dupe(u8, "name"), .column_type = .text, .primary_key = false };
    var schema = TableSchema{ .name = table_name, .columns = columns };
    defer schema.deinit(allocator);

    const encoded = try encodeSchema(allocator, schema);
    defer allocator.free(encoded);

    var decoded = try decodeSchema(allocator, encoded);
    defer decoded.deinit(allocator);
    try std.testing.expectEqualStrings("users", decoded.name);
    try std.testing.expectEqual(@as(usize, 0), try decoded.primaryKeyIndex());
    try std.testing.expectEqual(@as(usize, 1), try decoded.columnIndex("name"));
}
