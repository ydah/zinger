pub const page = @import("storage/page.zig");
pub const disk = @import("storage/disk.zig");
pub const buffer = @import("storage/buffer.zig");
pub const slotted = @import("storage/slotted.zig");

pub const PageId = page.PageId;
pub const PAGE_SIZE = page.PAGE_SIZE;
pub const DiskManager = disk.DiskManager;
pub const Buffer = buffer.Buffer;
pub const BufferPoolManager = buffer.BufferPoolManager;
pub const SlottedPage = slotted.SlottedPage;
