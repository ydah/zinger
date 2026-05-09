const std = @import("std");
const PAGE_SIZE = @import("page.zig").PAGE_SIZE;

const HEADER_SIZE: usize = 8;
const SLOT_SIZE: usize = 4;

pub const SlottedPage = struct {
    bytes: []u8,

    pub fn init(bytes: []u8) SlottedPage {
        return .{ .bytes = bytes };
    }

    pub fn format(self: *SlottedPage) void {
        @memset(self.bytes, 0);
        self.writeU16(0, 0);
        self.writeU16(2, @intCast(HEADER_SIZE));
        self.writeU16(4, @intCast(self.bytes.len));
        self.writeU16(6, 0);
    }

    pub fn numSlots(self: *const SlottedPage) usize {
        return self.readU16(0);
    }

    pub fn freeSpace(self: *const SlottedPage) usize {
        const free_start = self.freeStart();
        const free_end = self.freeEnd();
        return if (free_end >= free_start) free_end - free_start else 0;
    }

    pub fn insert(self: *SlottedPage, index: usize, record: []const u8) !void {
        const slots = self.numSlots();
        if (index > slots) return error.IndexOutOfBounds;
        if (record.len > std.math.maxInt(u16)) return error.RecordTooLarge;
        const needed = record.len + SLOT_SIZE;
        if (self.freeSpace() < needed) self.compact();
        if (self.freeSpace() < needed) return error.OutOfSpace;

        const new_free_end = self.freeEnd() - record.len;
        @memcpy(self.bytes[new_free_end..][0..record.len], record);

        const slot_start = self.slotOffset(index);
        const old_dir_end = self.slotOffset(slots);
        const new_dir_end = self.slotOffset(slots + 1);
        if (slot_start < old_dir_end) {
            std.mem.copyBackwards(u8, self.bytes[slot_start + SLOT_SIZE .. new_dir_end], self.bytes[slot_start..old_dir_end]);
        }
        self.writeSlot(index, .{ .offset = @intCast(new_free_end), .len = @intCast(record.len) });
        self.writeU16(0, @intCast(slots + 1));
        self.writeU16(2, @intCast(new_dir_end));
        self.writeU16(4, @intCast(new_free_end));
    }

    pub fn append(self: *SlottedPage, record: []const u8) !usize {
        const index = self.numSlots();
        try self.insert(index, record);
        return index;
    }

    pub fn get(self: *const SlottedPage, index: usize) ![]const u8 {
        if (index >= self.numSlots()) return error.IndexOutOfBounds;
        const slot = self.readSlot(index);
        return self.bytes[slot.offset..][0..slot.len];
    }

    pub fn update(self: *SlottedPage, index: usize, record: []const u8) !void {
        if (index >= self.numSlots()) return error.IndexOutOfBounds;
        if (record.len > std.math.maxInt(u16)) return error.RecordTooLarge;

        const slot = self.readSlot(index);
        if (record.len <= slot.len) {
            @memcpy(self.bytes[slot.offset..][0..record.len], record);
            self.writeSlot(index, .{ .offset = slot.offset, .len = @intCast(record.len) });
            return;
        }

        self.compact();
        const compacted = self.readSlot(index);
        if (self.freeSpace() + compacted.len < record.len) return error.OutOfSpace;
        try self.remove(index);
        try self.insert(index, record);
    }

    pub fn remove(self: *SlottedPage, index: usize) !void {
        const slots = self.numSlots();
        if (index >= slots) return error.IndexOutOfBounds;
        const start = self.slotOffset(index);
        const next = start + SLOT_SIZE;
        const end = self.slotOffset(slots);
        if (next < end) {
            std.mem.copyForwards(u8, self.bytes[start .. end - SLOT_SIZE], self.bytes[next..end]);
        }
        self.writeU16(0, @intCast(slots - 1));
        self.writeU16(2, @intCast(self.slotOffset(slots - 1)));
    }

    pub fn compact(self: *SlottedPage) void {
        var temp = [_]u8{0} ** PAGE_SIZE;
        const target = temp[0..self.bytes.len];
        var write_end = self.bytes.len;
        const slots = self.numSlots();

        for (0..slots) |index| {
            const record = self.get(index) catch unreachable;
            write_end -= record.len;
            @memcpy(target[write_end..][0..record.len], record);
            writeSlotRaw(target, index, .{ .offset = @intCast(write_end), .len = @intCast(record.len) });
        }

        writeU16Raw(target, 0, @intCast(slots));
        writeU16Raw(target, 2, @intCast(HEADER_SIZE + slots * SLOT_SIZE));
        writeU16Raw(target, 4, @intCast(write_end));
        writeU16Raw(target, 6, 0);
        @memcpy(self.bytes, target);
    }

    fn freeStart(self: *const SlottedPage) usize {
        return self.readU16(2);
    }

    fn freeEnd(self: *const SlottedPage) usize {
        return self.readU16(4);
    }

    fn slotOffset(_: *const SlottedPage, index: usize) usize {
        return HEADER_SIZE + index * SLOT_SIZE;
    }

    fn readSlot(self: *const SlottedPage, index: usize) Slot {
        const offset = self.slotOffset(index);
        return .{
            .offset = self.readU16(offset),
            .len = self.readU16(offset + 2),
        };
    }

    fn writeSlot(self: *SlottedPage, index: usize, slot: Slot) void {
        writeSlotRaw(self.bytes, index, slot);
    }

    fn readU16(self: *const SlottedPage, offset: usize) u16 {
        return std.mem.readInt(u16, self.bytes[offset..][0..2], .little);
    }

    fn writeU16(self: *SlottedPage, offset: usize, value: u16) void {
        writeU16Raw(self.bytes, offset, value);
    }
};

const Slot = struct {
    offset: u16,
    len: u16,
};

fn writeSlotRaw(bytes: []u8, index: usize, slot: Slot) void {
    const offset = HEADER_SIZE + index * SLOT_SIZE;
    writeU16Raw(bytes, offset, slot.offset);
    writeU16Raw(bytes, offset + 2, slot.len);
}

fn writeU16Raw(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

test "SlottedPage inserts reads removes and preserves order" {
    var bytes = [_]u8{0} ** 128;
    var page = SlottedPage.init(&bytes);
    page.format();
    try std.testing.expectEqual(@as(usize, 0), page.numSlots());

    try page.insert(0, "two");
    try page.insert(0, "one");
    _ = try page.append("three");
    try std.testing.expectEqualStrings("one", try page.get(0));
    try std.testing.expectEqualStrings("two", try page.get(1));
    try std.testing.expectEqualStrings("three", try page.get(2));

    try page.remove(1);
    try std.testing.expectEqual(@as(usize, 2), page.numSlots());
    try std.testing.expectEqualStrings("one", try page.get(0));
    try std.testing.expectEqualStrings("three", try page.get(1));

    try page.update(1, "THREE");
    try std.testing.expectEqualStrings("THREE", try page.get(1));
}

test "SlottedPage returns OutOfSpace" {
    var bytes = [_]u8{0} ** 32;
    var page = SlottedPage.init(&bytes);
    page.format();
    try page.insert(0, "0123456789");
    try std.testing.expectError(error.OutOfSpace, page.insert(1, "01234567890123456789"));
}
