const std = @import("std");
const storage = @import("storage.zig");
const btree = @import("btree.zig");

const PAGE_SIZE = storage.PAGE_SIZE;
const PageId = storage.PageId;
const DiskManager = storage.DiskManager;
const BufferPoolManager = storage.BufferPoolManager;

const META_PAGE_ID = PageId.init(0);
const MAGIC = "ZINGER\x00\x00";
const VERSION: u32 = 1;

pub const Database = struct {
    allocator: std.mem.Allocator,
    disk: *DiskManager,
    bpm: *BufferPoolManager,
    tree: btree.BTree,
    closed: bool = false,

    pub fn open(allocator: std.mem.Allocator, path: []const u8, pool_size: usize) !Database {
        return try Database.openWithIo(allocator, defaultIo(), path, pool_size);
    }

    pub fn openWithIo(allocator: std.mem.Allocator, io: std.Io, path: []const u8, pool_size: usize) !Database {
        if (pool_size < 2) return error.InvalidPoolSize;

        const disk_ptr = try allocator.create(DiskManager);
        errdefer allocator.destroy(disk_ptr);
        disk_ptr.* = try DiskManager.openWithIo(io, path);
        errdefer disk_ptr.close();

        const bpm_ptr = try allocator.create(BufferPoolManager);
        errdefer allocator.destroy(bpm_ptr);
        bpm_ptr.* = try BufferPoolManager.init(allocator, disk_ptr, pool_size);
        errdefer bpm_ptr.deinit();

        const tree = if (disk_ptr.pageCount() == 0) blk: {
            const meta = try bpm_ptr.newPage();
            if (!PageId.eql(meta.page_id, META_PAGE_ID)) return error.CorruptPage;
            writeMeta(meta.data[0..], PageId.invalid());
            try bpm_ptr.unpinPage(META_PAGE_ID, true);

            var created = try btree.BTree.create(bpm_ptr);
            try writeMetaPage(bpm_ptr, created.rootPageId());
            break :blk created;
        } else blk: {
            const root_page_id = try readMetaPage(bpm_ptr);
            break :blk btree.BTree.init(bpm_ptr, root_page_id);
        };

        return .{
            .allocator = allocator,
            .disk = disk_ptr,
            .bpm = bpm_ptr,
            .tree = tree,
        };
    }

    pub fn close(self: *Database) !void {
        if (self.closed) return;
        try writeMetaPage(self.bpm, self.tree.rootPageId());
        try self.bpm.flushAll();
        self.bpm.deinit();
        self.allocator.destroy(self.bpm);
        self.disk.close();
        self.allocator.destroy(self.disk);
        self.closed = true;
    }

    pub fn put(self: *Database, key: []const u8, value: []const u8) !void {
        try self.tree.put(key, value);
        try writeMetaPage(self.bpm, self.tree.rootPageId());
    }

    pub fn get(self: *Database, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        return try self.tree.get(allocator, key);
    }

    pub fn delete(self: *Database, key: []const u8) !bool {
        return try self.tree.delete(key);
    }

    pub fn scan(
        self: *Database,
        allocator: std.mem.Allocator,
        start_key: ?[]const u8,
        end_key: ?[]const u8,
        limit: ?usize,
    ) ![]btree.PairOwned {
        return try self.tree.scan(allocator, start_key, end_key, limit);
    }
};

fn defaultIo() std.Io {
    if (@import("builtin").is_test) return std.testing.io;
    return std.Io.Threaded.global_single_threaded.io();
}

fn writeMetaPage(bpm: *BufferPoolManager, root_page_id: PageId) !void {
    const frame = try bpm.fetchPage(META_PAGE_ID);
    writeMeta(frame.data[0..], root_page_id);
    try bpm.unpinPage(META_PAGE_ID, true);
}

fn readMetaPage(bpm: *BufferPoolManager) !PageId {
    const frame = try bpm.fetchPage(META_PAGE_ID);
    defer bpm.unpinPage(META_PAGE_ID, false) catch {};
    return try readMeta(frame.data[0..]);
}

fn writeMeta(bytes: []u8, root_page_id: PageId) void {
    @memset(bytes, 0);
    @memcpy(bytes[0..8], MAGIC);
    std.mem.writeInt(u32, bytes[8..12], VERSION, .little);
    std.mem.writeInt(u32, bytes[12..16], @intCast(PAGE_SIZE), .little);
    std.mem.writeInt(u64, bytes[16..24], root_page_id.toU64(), .little);
    std.mem.writeInt(u64, bytes[24..32], 0, .little);
}

fn readMeta(bytes: []const u8) !PageId {
    if (!std.mem.eql(u8, bytes[0..8], MAGIC)) return error.InvalidMagic;
    const version = std.mem.readInt(u32, bytes[8..12], .little);
    if (version != VERSION) return error.UnsupportedVersion;
    const page_size = std.mem.readInt(u32, bytes[12..16], .little);
    if (page_size != PAGE_SIZE) return error.InvalidPageSize;
    const root_page_id = PageId.init(std.mem.readInt(u64, bytes[16..24], .little));
    if (!root_page_id.isValid()) return error.InvalidRootPage;
    return root_page_id;
}

test "Database put get delete scan and reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(std.testing.io, "zinger.db", .{ .read = true });
    file.close(std.testing.io);

    const cwd_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/zinger.db", .{tmp.sub_path});
    defer std.testing.allocator.free(cwd_path);

    var first = try Database.open(std.testing.allocator, cwd_path, 32);
    try first.put("hello", "world");
    try first.put("alpha", "1");
    try first.put("omega", "9");
    const first_value = try first.get(std.testing.allocator, "hello");
    defer std.testing.allocator.free(first_value.?);
    try std.testing.expectEqualStrings("world", first_value.?);
    try std.testing.expect(try first.delete("alpha"));
    try first.close();

    var reopened = try Database.open(std.testing.allocator, cwd_path, 32);
    defer reopened.close() catch unreachable;
    const reopened_value = try reopened.get(std.testing.allocator, "hello");
    defer std.testing.allocator.free(reopened_value.?);
    try std.testing.expectEqualStrings("world", reopened_value.?);
    const missing = try reopened.get(std.testing.allocator, "alpha");
    try std.testing.expectEqual(@as(?[]u8, null), missing);

    const pairs = try reopened.scan(std.testing.allocator, null, null, null);
    defer {
        for (pairs) |*pair| pair.deinit(std.testing.allocator);
        std.testing.allocator.free(pairs);
    }
    try std.testing.expectEqual(@as(usize, 2), pairs.len);
}

test "Database rejects invalid meta magic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(std.testing.io, "bad.db", .{ .read = true });
    var page = [_]u8{0} ** PAGE_SIZE;
    @memcpy(page[0..8], "BADMAGIC");
    try file.writeStreamingAll(std.testing.io, &page);
    file.close(std.testing.io);

    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/bad.db", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    try std.testing.expectError(error.InvalidMagic, Database.open(std.testing.allocator, path, 4));
}
