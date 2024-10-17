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
    key: []u8,

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
        return self.pairAt(slot_id).key.cmp(self.key);
    }

    pub fn searchSlotId(self: *const Self, key: []const u8) !usize {
        self.key = key;
        return bsearch.binarySearchBy(self.numPairs(), self.cmpSlotId);
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

    pub fn initialize(self: *Self, key: []const u8, left_child: PageId, right_child: PageId) void {
        self.body.initialize();
        self.insert(0, key, left_child) catch {
            std.debug.panic("new leaf must have space");
        };
        self.header.right_child = right_child;
    }

    pub fn fillRightChild(self: *Self) []u8 {
        const last_id = self.numPairs() - 1;
        const pair = self.pairAt(last_id);
        const right_child: PageId = pair.value.into();
        const key_vec = std.mem.dupe(u8, pair.key);
        self.body.remove(last_id);
        self.header.right_child = right_child;
        return key_vec;
    }

    pub fn insert(self: *Self, slot_id: usize, key: []const u8, page_id: PageId) !void {
        const pair = Pair{
            .key = key,
            .value = page_id.asBytes(),
        };
        const pair_bytes = pair.toBytes();
        std.debug.assert(pair_bytes.len <= self.maxPairSize());

        self.body.insert(slot_id, pair_bytes.len) catch return error.OutOfSpace;
        std.mem.copy(u8, self.body[slot_id], pair_bytes);
    }

    fn isHalfFull(self: *const Self) bool {
        return 2 * self.body.freeSpace() < self.body.capacity();
    }

    pub fn splitInsert(self: *Self, new_branch: *Self, new_key: []const u8, new_page_id: PageId) []u8 {
        new_branch.body.initialize();
        while (true) {
            if (new_branch.isHalfFull()) {
                const index = self.searchSlotId(new_key) catch |err| {
                    if (err == error.KeyNotFound) return err;
                    std.debug.panic("key must be unique");
                };
                self.insert(index, new_key, new_page_id) catch {
                    std.debug.panic("old branch must have space");
                };
                break;
            }
            if (std.mem.eql(u8, self.pairAt(0).key, new_key)) {
                self.transfer(new_branch);
            } else {
                new_branch.insert(new_branch.numPairs(), new_key, new_page_id) catch {
                    std.debug.panic("new branch must have space");
                };
                while (!new_branch.isHalfFull()) {
                    self.transfer(new_branch);
                }
                break;
            }
        }
        return new_branch.fillRightChild();
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
