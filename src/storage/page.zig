const std = @import("std");

pub const PAGE_SIZE: usize = 4096;

pub const PageId = struct {
    const Self = @This();
    pub const invalid_value: u64 = std.math.maxInt(u64);
    pub const INVALID_PAGE_ID: u64 = invalid_value;

    value: u64 = invalid_value,

    pub fn init(value: u64) Self {
        return Self{ .value = value };
    }

    pub fn invalid() Self {
        return Self{};
    }

    pub fn isValid(self: Self) bool {
        return self.value != invalid_value;
    }

    pub fn toU64(self: Self) u64 {
        return self.value;
    }

    pub fn eql(a: Self, b: Self) bool {
        return a.value == b.value;
    }

    pub fn valid(self: Self) ?Self {
        return if (self.isValid()) self else null;
    }
};

test "PageId" {
    const page_id = PageId.init(42);
    const value = page_id.toU64();
    try std.testing.expectEqual(@as(u64, 42), value);
    try std.testing.expectEqual(page_id.valid(), page_id);
    const invalid_page_id = PageId.invalid();
    try std.testing.expect(!invalid_page_id.isValid());
    try std.testing.expectEqual(@as(?PageId, null), invalid_page_id.valid());
    try std.testing.expect(PageId.eql(PageId.init(7), PageId.init(7)));
}
