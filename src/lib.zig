const std = @import("std");

/// zinger is currently a durable ordered key-value store foundation for a
/// future pure Zig RDBMS.
pub const storage = @import("storage.zig");
pub const btree = @import("btree.zig");
pub const db = @import("db.zig");
pub const catalog = @import("catalog.zig");
pub const row = @import("row.zig");
pub const sql = @import("sql.zig");

pub const Database = db.Database;
pub const Pair = btree.PairOwned;
pub const executeSql = sql.execute;

comptime {
    _ = storage;
    _ = btree;
    _ = db;
    _ = catalog;
    _ = row;
    _ = sql;
}

test {
    std.testing.refAllDecls(@This());
}
