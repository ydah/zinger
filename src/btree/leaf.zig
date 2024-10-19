const std = @import("std");

const disk = @import("disk.zig");
const PageId = disk.PageId;
const Slotted = @import("slotted.zig").Slotted;
const bsearch = @import("bsearch.zig");
const Pair = bsearch.Pair;

pub const Header = struct {
    prev_page_id: PageId,
    next_page_id: PageId,
};

pub const Leaf = struct {
    const Self = @This();

    header: Header,
    body: Slotted,

    pub fn init(bytes: anytype) Leaf {
        return Leaf{ .header = Header{
            .prev_page_id = bytes[0..PageId.size],
            .next_page_id = bytes[PageId.size .. 2 * PageId.size],
        }, .body = Slotted.new(bytes[2 * PageId.size ..]) };
    }

    pub fn prevPageId(self: *const Self) PageId {
        return self.header.prev_page_id;
    }

    pub fn nextPageId(self: *const Self) PageId {
        return self.header.next_page_id;
    }

    pub fn numPairs(self: *const Self) usize {
        return self.body.numSlots();
    }

    pub fn cmpSlotId(self: *Self, slot_id: usize) u8 {
        return self.pairAt(slot_id).key.cmp(self.key);
    }

    pub fn searchSlotId(self: *const Self, key: []const u8) !usize {
        self.key = key;
        return bsearch.binarySearchBy(self.numPairs(), self.cmpSlotId);
    }

    pub fn searchChild(self: *const Self, key: []const u8) PageId {
        const slot_id = self.searchSlotId(key);
        return self.pairAt(slot_id);
    }

    pub fn pairAt(self: *const Self, slot_id: usize) Pair {
        return Pair.fromBytes(self.body[slot_id]);
    }

    pub fn maxPairSize(self: *const Self) usize {
        return self.body.capacity() / 2 - @sizeOf(Slotted.Pointer);
    }

    pub fn initialize(self: *Self) void {
        self.header.prev_page_id = PageId.INVALID_PAGE_ID;
        self.header.next_page_id = PageId.INVALID_PAGE_ID;
        self.body.initialize();
    }

    pub fn setPrevPageId(self: *Self, prev_page_id: PageId) void {
        self.header.prev_page_id = prev_page_id;
    }

    pub fn setNextPageId(self: *Self, next_page_id: PageId) void {
        self.header.next_page_id = next_page_id;
    }

    pub fn insert(self: *Self, slot_id: usize, key: []const u8, value: []const u8) !void {
        const pair = Pair{
            .key = key,
            .value = value,
        };
        const pair_bytes = pair.toBytes();
        std.debug.assert(pair_bytes.len <= self.maxPairSize());

        self.body.insert(slot_id, pair_bytes.len) catch return error.OutOfSpace;
        std.mem.copy(u8, self.body[slot_id], pair_bytes);
    }

    fn isHalfFull(self: *const Self) bool {
        return 2 * self.body.freeSpace() < self.body.capacity();
    }

    pub fn splitInsert(self: *Self, new_leaf: *Self, new_key: []const u8, new_value: []const u8) []u8 {
        new_leaf.body.initialize();
        while (true) {
            if (new_leaf.isHalfFull()) {
                const index = self.searchSlotId(new_key) catch |err| {
                    if (err == error.KeyNotFound) return err;
                    std.debug.panic("key must be unique");
                };
                self.insert(index, new_key, new_value) catch {
                    std.debug.panic("old branch must have space");
                };
                break;
            }
            if (std.mem.eql(u8, self.pairAt(0).key, new_key)) {
                self.transfer(new_leaf);
            } else {
                new_leaf.insert(new_leaf.numPairs(), new_key, new_value) catch {
                    std.debug.panic("new branch must have space");
                };
                while (!new_leaf.isHalfFull()) {
                    self.transfer(new_leaf);
                }
                break;
            }
        }
        return new_leaf.fillRightChild();
    }

    pub fn transfer(self: *Self, dest: *Self) void {
        const next_index = dest.numPairs();
        dest.body.insert(next_index, self.body[0].len) catch {
            std.debug.panic("no space in dest branch");
        };
        std.mem.copy(u8, dest.body[next_index], self.body[0]);
        self.body.remove(0);
    }
};
