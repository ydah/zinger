const std = @import("std");
const builtin = @import("builtin");

const page = @import("page.zig");
pub const PageId = page.PageId;
pub const PAGE_SIZE = page.PAGE_SIZE;

pub const DiskManager = struct {
    const Self = @This();

    io: std.Io,
    heap_file: ?std.Io.File,
    next_page_id: u64,

    pub fn init(heap_file: std.Io.File) !Self {
        return try Self.initWithIo(defaultIo(), heap_file);
    }

    pub fn initWithIo(io: std.Io, heap_file: std.Io.File) !Self {
        const file_info = try heap_file.stat(io);
        const heap_file_size = file_info.size;
        const next_page_id = heap_file_size / PAGE_SIZE;

        return Self{
            .io = io,
            .heap_file = heap_file,
            .next_page_id = next_page_id,
        };
    }

    pub fn open(heap_file_path: []const u8) !Self {
        return try Self.openWithIo(defaultIo(), heap_file_path);
    }

    pub fn openWithIo(io: std.Io, heap_file_path: []const u8) !Self {
        const cwd = std.Io.Dir.cwd();
        const file = cwd.openFile(io, heap_file_path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try cwd.createFile(io, heap_file_path, .{ .read = true, .truncate = false }),
            else => return err,
        };
        return try Self.initWithIo(io, file);
    }

    pub fn close(self: *Self) void {
        if (self.heap_file) |file| {
            file.close(self.io);
            self.heap_file = null;
        }
    }

    pub fn allocatePage(self: *Self) !PageId {
        const page_id = self.next_page_id;
        self.next_page_id += 1;

        return PageId.init(page_id);
    }

    pub fn pageCount(self: *const Self) u64 {
        return self.next_page_id;
    }

    pub fn readPage(self: *Self, page_id: PageId, buffer: []u8) !void {
        if (buffer.len != PAGE_SIZE) return error.InvalidPageSize;
        if (!page_id.isValid()) return error.InvalidPageId;
        const file = self.heap_file orelse return error.Closed;
        const offset = page_id.toU64() * PAGE_SIZE;
        const stat = try file.stat(self.io);
        if (offset + PAGE_SIZE > stat.size) return error.PageNotFound;
        const read_len = try file.readPositionalAll(self.io, buffer, offset);
        if (read_len != PAGE_SIZE) return error.ShortRead;
    }

    pub fn writePage(self: *Self, page_id: PageId, data: []const u8) !void {
        if (data.len != PAGE_SIZE) return error.InvalidPageSize;
        if (!page_id.isValid()) return error.InvalidPageId;
        const file = self.heap_file orelse return error.Closed;
        const offset = page_id.toU64() * PAGE_SIZE;
        try file.writePositionalAll(self.io, data, offset);
    }

    pub fn sync(self: *Self) !void {
        const file = self.heap_file orelse return error.Closed;
        try file.sync(self.io);
    }
};

fn defaultIo() std.Io {
    if (builtin.is_test) return std.testing.io;
    return std.Io.Threaded.global_single_threaded.io();
}

test "DiskManager allocates writes reads and reopens pages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(std.testing.io, "zinger.db", .{ .read = true });
    var disk = try DiskManager.init(file);
    const page_id = try disk.allocatePage();
    try std.testing.expectEqual(@as(u64, 0), page_id.toU64());

    var page_buf = [_]u8{0} ** PAGE_SIZE;
    page_buf[0] = 42;
    page_buf[PAGE_SIZE - 1] = 7;
    try disk.writePage(page_id, &page_buf);
    try disk.sync();
    disk.close();

    const reopened_file = try tmp.dir.openFile(std.testing.io, "zinger.db", .{ .mode = .read_write });
    var reopened = try DiskManager.init(reopened_file);
    defer reopened.close();

    var out = [_]u8{0} ** PAGE_SIZE;
    try reopened.readPage(page_id, &out);
    try std.testing.expectEqual(@as(u8, 42), out[0]);
    try std.testing.expectEqual(@as(u8, 7), out[PAGE_SIZE - 1]);
    try std.testing.expectError(error.InvalidPageSize, reopened.readPage(page_id, out[0..10]));
    try std.testing.expectError(error.InvalidPageSize, reopened.writePage(page_id, out[0..10]));
}
