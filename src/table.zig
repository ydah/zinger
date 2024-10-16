const std = @import("std");

const BTree = @import("btree.zig");
const BufferPoolManager = @import("buffer.zig");
const disk = @import("disk.zig");
const PageId = disk.PageId;
const tuple = @import("tuple.zig");

pub const SimpleTable = struct {
    const Self = @This();

    meta_page_id: PageId,
    num_key_elems: usize,

    pub fn create(self: *Self, bufmgr: *BufferPoolManager) !void {
        const btree = try BTree.create(bufmgr);
        self.meta_page_id = btree.meta_page_id;
    }

    pub fn insert(self: *Self, bufmgr: *BufferPoolManager, record: []const []const u8) !void {
        var btree = BTree.new(self.meta_page_id);
        var key = std.ArrayList(u8).init(std.heap.page_allocator);
        try tuple.encode(record[0..self.num_key_elems].iter(), &key);
        var value = std.ArrayList(u8).init(std.heap.page_allocator);
        try tuple.encode(record[self.num_key_elems..].iter(), &value);
        try btree.insert(bufmgr, key.items, value.items);
    }
};

pub const Table = struct {
    const Self = @This();

    meta_page_id: PageId,
    num_key_elems: usize,
    unique_indices: std.ArrayList(UniqueIndex),

    pub fn create(self: *Self, bufmgr: *BufferPoolManager) !void {
        const btree = try BTree.create(bufmgr);
        self.meta_page_id = btree.meta_page_id;
        for (self.unique_indices.items) |unique_index| {
            try unique_index.create(bufmgr);
        }
    }

    pub fn insert(self: *Self, bufmgr: *BufferPoolManager, record: []const []const u8) !void {
        var btree = BTree.new(self.meta_page_id);
        var key = std.ArrayList(u8).init(std.heap.page_allocator);
        try tuple.encode(record[0..self.num_key_elems].iter(), &key);
        var value = std.ArrayList(u8).init(std.heap.page_allocator);
        try tuple.encode(record[self.num_key_elems..].iter(), &value);
        try btree.insert(bufmgr, key.items, value.items);
        for (self.unique_indices.items) |unique_index| {
            try unique_index.insert(bufmgr, key.items, record);
        }
    }
};

pub const UniqueIndex = struct {
    const Self = @This();

    meta_page_id: PageId,
    skey: std.ArrayList(usize),

    pub fn create(self: *Self, bufmgr: *BufferPoolManager) !void {
        const btree = try BTree.create(bufmgr);
        self.meta_page_id = btree.meta_page_id;
    }

    pub fn insert(self: *Self, bufmgr: *BufferPoolManager, pkey: []const u8, record: []const []const u8) !void {
        var btree = BTree.new(self.meta_page_id);
        var skey = std.ArrayList(u8).init(std.heap.page_allocator);
        for (self.skey.items) |index| {
            try tuple.encode(record[index], &skey);
        }
        try btree.insert(bufmgr, skey.items, pkey);
    }
};
