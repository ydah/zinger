const std = @import("std");

pub const Header = struct {
    num_slots: u16,
    free_space_offset: u16,
    _padding: u32,
};

pub const Pointer = struct {
    const Self = @This();

    offset: u16,
    len: u16,

    pub fn range(self: *Self) std.range.Range {
        return std.range.Range{ .start = self.offset, .end = self.offset + self.len };
    }
};

pub const Slotted = struct {
    const Self = @This();

    header: Header,
    body: []u8,

    pub fn init(bytes: anytype) Slotted {
        if (@alignOf(@TypeOf(bytes)) % 4 != 0) {
            std.debug.panic("slotted header must be aligned");
        }

        return Self{
            .header = Header{
                .num_slots = bytes[0..2],
                .free_space_offset = bytes[2..4],
                ._padding = 0,
            },
            .body = bytes[4..],
        };
    }

    pub fn capacity(self: *Self) usize {
        return self.body.len;
    }

    pub fn numSlots(self: *Self) usize {
        return @intCast(self.header.num_slots);
    }

    pub fn freeSpace(self: *Self) usize {
        return self.header.free_space_offset - self.pointersSize();
    }

    pub fn pointersSize(self: *Self) usize {
        return self.numSlots() * @sizeOf(Pointer);
    }

    pub fn pointers(self: *Self) []Pointer {
        return self.body[0..self.pointersSize()].typeOf([]Pointer);
    }

    pub fn data(self: *Self, pointer: Pointer) []u8 {
        return self.body[pointer.range()];
    }

    pub fn initialize(self: *Self) void {
        self.header.num_slots = 0;
        self.header.free_space_offset = self.body.len;
    }

    pub fn insert(self: *Slotted, index: usize, len: usize) !void {
        if (self.freeSpace() < std.mem.sizeOf(Pointer) + len) {
            return error.OutOfSpace;
        }

        const num_slots_orig = self.numSlots();
        self.header.free_space_offset -= @intCast(len);
        self.header.num_slots += 1;

        const free_space_offset = self.header.free_space_offset;
        var ptrs = self.pointers();
        std.mem.copy(u8, ptrs[index + 1 .. num_slots_orig + 1], ptrs[index..num_slots_orig]);

        var pointer = &ptrs[index];
        pointer.offset = free_space_offset;
        pointer.len = @intCast(len);
    }

    pub fn remove(self: *Slotted, index: usize) void {
        self.resize(index, 0);
        var ptrs = self.pointersMut();
        std.mem.copy(u8, ptrs[index .. self.numSlots() - 1], ptrs[index + 1 .. self.numSlots()]);
        self.header.num_slots -= 1;
    }

    pub fn resize(self: *Slotted, index: usize, len_new: usize) !void {
        const ptrs = self.pointers();
        const len_orig = ptrs[index].len;
        const len_incr = len_new - len_orig;
        if (len_incr == 0) {
            return;
        }

        if (len_incr > self.freeSpace()) {
            return error.OutOfSpace;
        }

        const free_space_offset = self.header.free_space_offset;
        const offset_orig = ptrs[index].offset;
        const free_space_offset_new = free_space_offset - len_incr;
        self.header.free_space_offset = free_space_offset_new;
        std.mem.copy(u8, self.body[free_space_offset_new..], self.body[free_space_offset..offset_orig]);

        for (ptrs) |*ptr| {
            if (ptr.offset <= offset_orig) {
                ptr.offset = ptr.offset - len_incr;
            }
        }

        var ptr = &ptrs[index];
        ptr.len = len_new;
        if (len_new == 0) {
            ptr.offset = free_space_offset_new;
        }
    }
};
