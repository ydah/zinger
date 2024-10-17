const std = @import("std");

const PageId = @import("disk.zig").PageId;
const Slotted = @import("slotted.zig").Slotted;
const bsearch = @import("bsearch.zig");
const Pair = bsearch.Pair;

const Header = struct {
    rightChild: PageId,
};

const Branch = struct {
    const Self = @This();

    header: Header,
    body: Slotted,

    pub fn init(bytes: anytype) Self {
        return Self{
            .header = Header{
                .num_slots = bytes[0..2],
                .free_space_offset = bytes[2..4],
                ._padding = 0,
            },
            .body = Slotted.init(bytes[4..]),
        };
    }

    pub fn numPairs(self: *Self) usize {
        return self.body.numSlots();
    }

    pub fn cmpSlotId(self: *Self, slot_id: usize) u8 {
        return self.pairAt(slot_id).key.cmp(key);
    }

    pub fn searchSlotId(self: *const Self, key: []const u8) !usize {
        return bsearch.binarySearchBy(self.numPairs(), self.cmpSlotId(slot));
    }

    pub fn searchChild(self: *const Self, key: []const u8) PageId {
        const child_idx = self.searchChildIdx(key);
        return self.childAt(child_idx);
    }

    pub fn searchChildIdx(self: *const Self, key: []const u8) usize {
        return switch (self.searchSlotId(key)) {
            usize => {
                self.searchSlotId(key) + 1;
            },
            error.LeftIndex => {
                self.searchSlotId(key);
            },
        };
    }

    pub fn childAt(self: *const Self, child_idx: usize) PageId {
        if (child_idx == self.numPairs()) {
            return self.header.rightChild;
        } else {
            return self.pairAt(child_idx).value.into();
        }
    }

    pub fn pairAt(self: *const Self, slot_id: usize) Pair {
        return Pair.fromBytes(self.body[slot_id]);
    }

    pub fn maxPairSize(self: *const Self) usize {
        return self.body.capacity() / 2 - @sizeOf(Slotted.Pointer);
    }
};
