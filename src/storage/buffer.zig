const std = @import("std");
const page = @import("page.zig");
const disk = @import("disk.zig");

pub const PageId = page.PageId;
pub const PAGE_SIZE = page.PAGE_SIZE;
pub const DiskManager = disk.DiskManager;

pub const Buffer = struct {
    page_id: PageId = PageId.invalid(),
    data: [PAGE_SIZE]u8 = [_]u8{0} ** PAGE_SIZE,
    is_dirty: bool = false,
    pin_count: usize = 0,
    usage_count: u8 = 0,

    fn reset(self: *Buffer, page_id: PageId) void {
        self.page_id = page_id;
        @memset(&self.data, 0);
        self.is_dirty = false;
        self.pin_count = 0;
        self.usage_count = 0;
    }
};

pub const BufferPoolManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    disk: *DiskManager,
    frames: []Buffer,
    page_table: std.AutoHashMap(u64, usize),
    clock_hand: usize = 0,

    pub fn init(allocator: std.mem.Allocator, disk_manager: *DiskManager, pool_size: usize) !Self {
        if (pool_size == 0) return error.InvalidPoolSize;
        const frames = try allocator.alloc(Buffer, pool_size);
        for (frames) |*frame| frame.* = Buffer{};
        return Self{
            .allocator = allocator,
            .disk = disk_manager,
            .frames = frames,
            .page_table = std.AutoHashMap(u64, usize).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.page_table.deinit();
        self.allocator.free(self.frames);
        self.* = undefined;
    }

    pub fn newPage(self: *Self) !*Buffer {
        const frame_index = try self.victimFrame();
        var frame = &self.frames[frame_index];
        try self.evictFrame(frame);

        const page_id = try self.disk.allocatePage();
        frame.reset(page_id);
        frame.is_dirty = true;
        frame.pin_count = 1;
        frame.usage_count = 1;
        try self.page_table.put(page_id.toU64(), frame_index);
        return frame;
    }

    pub fn fetchPage(self: *Self, page_id: PageId) !*Buffer {
        if (!page_id.isValid()) return error.InvalidPageId;
        if (self.page_table.get(page_id.toU64())) |frame_index| {
            var frame = &self.frames[frame_index];
            frame.pin_count += 1;
            frame.usage_count = 1;
            return frame;
        }

        const frame_index = try self.victimFrame();
        var frame = &self.frames[frame_index];
        try self.evictFrame(frame);
        frame.reset(page_id);
        try self.disk.readPage(page_id, &frame.data);
        frame.pin_count = 1;
        frame.usage_count = 1;
        try self.page_table.put(page_id.toU64(), frame_index);
        return frame;
    }

    pub fn unpinPage(self: *Self, page_id: PageId, is_dirty: bool) !void {
        const frame_index = self.page_table.get(page_id.toU64()) orelse return error.PageNotInPool;
        var frame = &self.frames[frame_index];
        if (frame.pin_count == 0) return error.PageNotPinned;
        frame.pin_count -= 1;
        frame.is_dirty = frame.is_dirty or is_dirty;
    }

    pub fn flushPage(self: *Self, page_id: PageId) !void {
        const frame_index = self.page_table.get(page_id.toU64()) orelse return error.PageNotInPool;
        var frame = &self.frames[frame_index];
        if (!frame.page_id.isValid()) return;
        if (frame.is_dirty) {
            try self.disk.writePage(frame.page_id, &frame.data);
            frame.is_dirty = false;
        }
    }

    pub fn flushAll(self: *Self) !void {
        for (self.frames) |*frame| {
            if (frame.page_id.isValid() and frame.is_dirty) {
                try self.disk.writePage(frame.page_id, &frame.data);
                frame.is_dirty = false;
            }
        }
        try self.disk.sync();
    }

    fn victimFrame(self: *Self) !usize {
        for (self.frames, 0..) |*frame, index| {
            if (!frame.page_id.isValid()) {
                self.clock_hand = (index + 1) % self.frames.len;
                return index;
            }
        }

        var scanned: usize = 0;
        while (scanned < self.frames.len * 2) : (scanned += 1) {
            const index = self.clock_hand;
            self.clock_hand = (self.clock_hand + 1) % self.frames.len;
            var frame = &self.frames[index];
            if (frame.pin_count != 0) continue;
            if (frame.usage_count == 0) return index;
            frame.usage_count = 0;
        }
        return error.NoFreeFrame;
    }

    fn evictFrame(self: *Self, frame: *Buffer) !void {
        if (!frame.page_id.isValid()) return;
        if (frame.pin_count != 0) return error.PagePinned;
        if (frame.is_dirty) {
            try self.disk.writePage(frame.page_id, &frame.data);
            frame.is_dirty = false;
        }
        _ = self.page_table.remove(frame.page_id.toU64());
    }
};

test "BufferPoolManager creates fetches flushes and evicts pages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(std.testing.io, "buffer.db", .{ .read = true });
    var disk_manager = try DiskManager.init(file);
    defer disk_manager.close();

    var bpm = try BufferPoolManager.init(std.testing.allocator, &disk_manager, 2);
    defer bpm.deinit();

    const first_id = blk: {
        const page1 = try bpm.newPage();
        page1.data[0] = 11;
        const id = page1.page_id;
        try bpm.unpinPage(id, true);
        break :blk id;
    };

    const second_id = blk: {
        const page2 = try bpm.newPage();
        page2.data[0] = 22;
        const id = page2.page_id;
        try bpm.unpinPage(id, true);
        break :blk id;
    };

    const third_id = blk: {
        const page3 = try bpm.newPage();
        page3.data[0] = 33;
        const id = page3.page_id;
        try bpm.unpinPage(id, true);
        break :blk id;
    };

    try bpm.flushAll();

    const fetched = try bpm.fetchPage(first_id);
    try std.testing.expectEqual(@as(u8, 11), fetched.data[0]);
    try bpm.unpinPage(first_id, false);

    const fetched3 = try bpm.fetchPage(third_id);
    try std.testing.expectEqual(@as(u8, 33), fetched3.data[0]);
    try bpm.unpinPage(third_id, false);

    _ = second_id;
}

test "BufferPoolManager reports all pinned frames" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(std.testing.io, "pinned.db", .{ .read = true });
    var disk_manager = try DiskManager.init(file);
    defer disk_manager.close();

    var bpm = try BufferPoolManager.init(std.testing.allocator, &disk_manager, 1);
    defer bpm.deinit();

    _ = try bpm.newPage();
    try std.testing.expectError(error.NoFreeFrame, bpm.newPage());
}
