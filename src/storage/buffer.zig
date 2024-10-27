const std = @import("std");
const disk = @import("disk.zig");
const DiskManager = disk.DiskManager;
const PageId = disk.PageId;
const PAGE_SIZE = disk.PAGE_SIZE;

pub const BufferId = struct {
    id: usize,
};

pub const Page = [PAGE_SIZE]u8;

pub const Buffer = struct {
    const Self = @This();

    page_id: PageId,
    page: Page,
    is_dirty: bool,
    references_count: usize,

    pub fn init() Self {
        const page: [PAGE_SIZE]u8 = undefined;
        @memset(page, 0);
        return Self{
            .page_id = PageId.INVALID_PAGE_ID,
            .page = page,
            .is_dirty = false,
            .references_count = 0,
        };
    }
};

pub const Frame = struct {
    usge_count: usize,
    buffer: Buffer,
};

pub const BufferPool = struct {
    const Self = @This();

    buffers: std.ArrayList(Frame),
    next_victim: BufferId,

    pub fn init(pool_size: usize) Self {
        const buffers = std.ArrayList(Frame).init(pool_size);
        return Self{
            .buffers = buffers,
            .next_victim = BufferId{ .id = 0 },
        };
    }

    fn size(self: Self) usize {
        return self.buffers.items.len;
    }

    fn evict(self: Self) ?BufferId {
        const pool_size = self.size();
        var consecutive_pinned = 0;
        const victim_id = while (true) {
            const next_victim_id = self.next_victim.id;
            const frame = self.buffers.items[next_victim_id];
            if (frame.usge_count == 0) {}
            if (frame.buffer.references_count == 0) {
                frame.usage_count -= 1;
                consecutive_pinned = 0;
            } else {
                consecutive_pinned += 1;
                if (consecutive_pinned >= pool_size) {
                    return null;
                }
            }
            self.next_victim_id = self.increment_id(self, self.next_victim.id);
        };
        return victim_id;
    }

    fn increment_id(self: Self, buffer_id: usize) usize {
        return (buffer_id + 1) % self.size();
    }
};

const Error = error{
    NoFreeBuffer,
};

const BufferPoolManager = struct {
    const Self = @This();

    disk_manager: DiskManager,
    buffer_pool: BufferPool,
    page_table: std.HashMap(PageId, BufferId),

    pub fn init(disk_manager: DiskManager, pool: BufferPool) Self {
        const page_table = std.HashMap.init();
        return Self{
            .disk_manager = disk_manager,
            .buffer_pool = pool,
            .page_table = page_table,
        };
    }

    pub fn fetchPage(self: *Self, page_id: PageId) !Buffer {
        if (self.page_table.get(page_id)) |buffer_id| {
            var frame = &self.buffer_pool.buffers[buffer_id.id];
            frame.usage_count += 1;
            frame.buffer.references_count += 1;
            return &frame.buffer;
        }

        const buffer_id = self.buffer_pool.evict(self.buffer_pool);
        if (buffer_id == null) {
            return Error.NoFreeBuffer;
        }

        var frame = &self.buffer_pool.buffers[buffer_id];
        const evict_page_id = frame.buffer.page_id;
        {
            var buffer = &frame.buffer;
            if (buffer == null) {}
            if (buffer.is_dirty) {
                try self.disk_manager.writePage(evict_page_id, buffer.page);
            }
            buffer.page_id = page_id;
            buffer.is_dirty = false;
            try self.disk_manager.readPage(page_id, buffer.page);
            frame.usage_count = 1;
        }

        frame.buffer.references_count += 1;
        const page = frame.buffer;
        self.page_table.remove(self.page_table, evict_page_id);
        self.page_table.put(page_id, buffer_id);
        return page;
    }

    pub fn createPage(self: *Self) !Buffer {
        const buffer_id = self.buffer_pool.evict(self.buffer_pool);
        if (buffer_id == null) {
            return Error.NoFreeBuffer;
        }

        var frame = &self.buffer_pool.buffers[buffer_id];
        const evict_page_id = frame.buffer.page_id;
        const buffer = &frame.buffer;
        if (buffer.is_dirty) {
            self.disk_manager.writePage(evict_page_id, buffer.page);
        }
        const page_id = self.disk_manager.allocatePage();
        buffer = Buffer.init();
        buffer.page_id = page_id;
        buffer.is_dirty = true;
        frame.usage_count = 1;

        buffer.references_count += 1;
        self.page_table.remove(self.page_table, evict_page_id);
        self.page_table.put(page_id, buffer_id);
        return buffer;
    }

    pub fn flush(self: *Self) !void {
        const entries = self.page_table.entries();
        while (entries.next()) |entry| {
            const page_id = entry.key;
            const buffer_id = entry.value;
            const frame = &self.buffer_pool.buffers[buffer_id.id];
            const page = &frame.buffer.page;
            self.disk_manager.writePage(page_id, page);
            frame.buffer.is_dirty = false;
        }
        self.disk_manager.sync();
    }
};
