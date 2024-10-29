const std = @import("std");

pub const PageId = struct {
    const Self = @This();
    pub const INVALID_PAGE_ID = std.math.maxInt(u64);

    value: u64 = INVALID_PAGE_ID,

    pub fn init(value: u64) Self {
        return Self{ .value = value };
    }

    pub fn toU64(self: Self) u64 {
        return self.value;
    }

    pub fn valid(self: Self) ?Self {
        return switch (self.value) {
            Self.INVALID_PAGE_ID => null,
            else => self,
        };
    }
};

test "PageId" {
    var page_id = PageId.init(42);
    const value = page_id.toU64();
    try std.testing.expectEqual(value, 42);
    try std.testing.expectEqual(page_id.valid(), page_id);
    var invalid_page_id = PageId{};
    try std.testing.expectEqual(invalid_page_id.valid(), null);
}
