const std = @import("std");

pub const PageId = struct {
    const Self = @This();

    value: u64,

    pub const INVALID_PAGE_ID: Self = Self{ .value = std.math.maxU64(u64) };

    pub fn init(value: u64) Self {
        return Self{ .value = value };
    }

    pub fn toU64(self: Self) u64 {
        return self.value;
    }

    pub fn valid(self: Self) ?Self {
        return switch (self) {
            Self.INVALID_PAGE_ID => null,
            else => self,
        };
    }

    pub fn fromOptional(page_id: ?Self) Self {
        return switch (page_id) {
            null => Self.INVALID_PAGE_ID,
            else => page_id.?,
        };
    }

    pub fn fromBytes(bytes: []const u8) !Self {
        if (bytes.len != @sizeOf(u64)) {
            return error.InvalidByteSize;
        }
        const value = std.mem.bytesAsValue(u64, bytes);
        return Self.init(value);
    }
};
