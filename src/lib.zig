const std = @import("std");

/// zinger is currently a durable ordered key-value store foundation for a
/// future pure Zig RDBMS.
pub const storage = @import("storage.zig");
pub const btree = @import("btree.zig");
pub const db = @import("db.zig");

pub const Database = db.Database;
pub const Pair = btree.PairOwned;

comptime {
    _ = storage;
    _ = btree;
    _ = db;
}

test {
    std.testing.refAllDecls(@This());
}
