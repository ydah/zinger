const std = @import("std");

const PageId = @import("page.zig").PageId;
const PAGE_SIZE = 4096;

pub const DiskManager = struct {
    const Self = @This();

    heap_file: std.fs.File,
    next_page_id: u64,

    pub fn init(heap_file: std.fs.File) !Self {
        const file_info = try heap_file.stat();
        const heap_file_size = file_info.size;
        const next_page_id = heap_file_size / PAGE_SIZE;

        return Self{
            .heap_file = heap_file,
            .next_page_id = next_page_id,
        };
    }

    pub fn open(heap_file_path: []const u8) !Self {
        const fs = std.fs;
        const file = try fs.cwd().openFile(heap_file_path, fs.File.OpenFlags{
            .read = true,
            .write = true,
            .create = true,
        });

        return try Self.init(file);
    }

    pub fn allocatePage(self: *Self) !PageId {
        const page_id = self.next_page_id;
        self.next_page_id += 1;

        return PageId.init(page_id);
    }

    pub fn readPage(self: *Self, page_id: PageId, buffer: []u8) !void {
        const offset = page_id.toUint64() * PAGE_SIZE;
        try std.fs.File.seekTo(self.heap_file, offset);
        std.fs.File.read(self.heap_file, buffer);
    }

    pub fn writePage(self: *Self, page_id: PageId, data: []const u8) !void {
        const offset = page_id.toUint64() * PAGE_SIZE;
        try std.fs.File.seekTo(self.heap_file, offset);
        std.fs.File.write(self.heap_file, data);
    }

    pub fn sync(self: *Self) !void {
        try std.fs.File.sync(self.heap_file);
    }
};
