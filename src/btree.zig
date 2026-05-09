const std = @import("std");
const storage = @import("storage.zig");

const BufferPoolManager = storage.BufferPoolManager;
const PageId = storage.PageId;
const SlottedPage = storage.SlottedPage;
const PAGE_SIZE = storage.PAGE_SIZE;

const NODE_HEADER_SIZE: usize = 32;
const KIND_OFFSET: usize = 0;
const FLAGS_OFFSET: usize = 1;
const LINK_A_OFFSET: usize = 8;
const LINK_B_OFFSET: usize = 16;

const NodeKind = enum(u8) {
    leaf = 1,
    internal = 2,
};

pub const InsertResult = enum {
    inserted,
    updated,
};

pub const Pair = struct {
    key: []const u8,
    value: []const u8,

    pub fn encodedLen(self: Pair) usize {
        return 16 + self.key.len + self.value.len;
    }

    pub fn encode(self: Pair, out: []u8) !void {
        const len = self.encodedLen();
        if (out.len < len) return error.BufferTooSmall;
        std.mem.writeInt(u64, out[0..8], @intCast(self.key.len), .little);
        std.mem.writeInt(u64, out[8..16], @intCast(self.value.len), .little);
        @memcpy(out[16..][0..self.key.len], self.key);
        @memcpy(out[16 + self.key.len ..][0..self.value.len], self.value);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !PairOwned {
        const view = try decodePairView(bytes);
        const key = try allocator.dupe(u8, view.key);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, view.value);
        return .{ .key = key, .value = value };
    }
};

pub const PairOwned = struct {
    key: []u8,
    value: []u8,

    pub fn deinit(self: *PairOwned, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
        self.* = undefined;
    }
};

const PairView = struct {
    key: []const u8,
    value: []const u8,
};

const Promotion = struct {
    separator_key: []u8,
    right_page_id: PageId,
};

const InternalRecordOwned = struct {
    key: []u8,
    child: PageId,

    fn deinit(self: *InternalRecordOwned, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        self.* = undefined;
    }
};

pub const LeafNode = struct {
    bytes: []u8,

    pub fn init(bytes: []u8) LeafNode {
        return .{ .bytes = bytes };
    }

    pub fn format(self: *LeafNode, is_root: bool) void {
        formatNode(self.bytes, .leaf, is_root);
        setLeafPrev(self.bytes, PageId.invalid());
        setLeafNext(self.bytes, PageId.invalid());
    }

    pub fn get(self: *const LeafNode, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        const index = try self.lowerBoundChecked(key);
        var slots = slotted(self.bytes);
        if (index >= slots.numSlots()) return null;
        const pair = try decodePairView(try slots.get(index));
        if (!std.mem.eql(u8, pair.key, key)) return null;
        return try allocator.dupe(u8, pair.value);
    }

    pub fn insert(self: *LeafNode, key: []const u8, value: []const u8) !InsertResult {
        const pair = Pair{ .key = key, .value = value };
        if (pair.encodedLen() > PAGE_SIZE) return error.RecordTooLarge;
        var encoded = [_]u8{0} ** PAGE_SIZE;
        try pair.encode(encoded[0..pair.encodedLen()]);

        const index = try self.lowerBoundChecked(key);
        var slots = slotted(self.bytes);
        if (index < slots.numSlots()) {
            const current = try decodePairView(try slots.get(index));
            if (std.mem.eql(u8, current.key, key)) {
                try slots.update(index, encoded[0..pair.encodedLen()]);
                return .updated;
            }
        }
        try slots.insert(index, encoded[0..pair.encodedLen()]);
        return .inserted;
    }

    pub fn delete(self: *LeafNode, key: []const u8) !bool {
        const index = try self.lowerBoundChecked(key);
        var slots = slotted(self.bytes);
        if (index >= slots.numSlots()) return false;
        const pair = try decodePairView(try slots.get(index));
        if (!std.mem.eql(u8, pair.key, key)) return false;
        try slots.remove(index);
        return true;
    }

    pub fn lowerBound(self: *const LeafNode, key: []const u8) usize {
        return self.lowerBoundChecked(key) catch unreachable;
    }

    fn lowerBoundChecked(self: *const LeafNode, key: []const u8) !usize {
        var slots = slotted(self.bytes);
        var left: usize = 0;
        var right = slots.numSlots();
        while (left < right) {
            const mid = left + (right - left) / 2;
            const pair = try decodePairView(try slots.get(mid));
            switch (std.mem.order(u8, pair.key, key)) {
                .lt => left = mid + 1,
                .eq, .gt => right = mid,
            }
        }
        return left;
    }
};

pub const InternalNode = struct {
    bytes: []u8,

    pub fn init(bytes: []u8) InternalNode {
        return .{ .bytes = bytes };
    }

    pub fn format(self: *InternalNode, is_root: bool) void {
        formatNode(self.bytes, .internal, is_root);
        setInternalLeftmost(self.bytes, PageId.invalid());
    }

    pub fn childForKey(self: *const InternalNode, key: []const u8) PageId {
        return self.childForKeyChecked(key) catch unreachable;
    }

    fn childForKeyChecked(self: *const InternalNode, key: []const u8) !PageId {
        var child = internalLeftmost(self.bytes);
        var slots = slotted(self.bytes);
        for (0..slots.numSlots()) |index| {
            const record = try decodeInternalRecord(try slots.get(index));
            if (std.mem.order(u8, key, record.key) == .lt) return child;
            child = record.child;
        }
        return child;
    }

    pub fn insertChild(self: *InternalNode, separator_key: []const u8, child: PageId) !void {
        var slots = slotted(self.bytes);
        var encoded = [_]u8{0} ** PAGE_SIZE;
        const encoded_len = try encodeInternalRecord(separator_key, child, &encoded);
        const index = try self.lowerBoundChecked(separator_key);
        try slots.insert(index, encoded[0..encoded_len]);
    }

    fn lowerBoundChecked(self: *const InternalNode, key: []const u8) !usize {
        var slots = slotted(self.bytes);
        var left: usize = 0;
        var right = slots.numSlots();
        while (left < right) {
            const mid = left + (right - left) / 2;
            const record = try decodeInternalRecord(try slots.get(mid));
            switch (std.mem.order(u8, record.key, key)) {
                .lt => left = mid + 1,
                .eq, .gt => right = mid,
            }
        }
        return left;
    }
};

pub const BTree = struct {
    bpm: *BufferPoolManager,
    root_page_id: PageId,

    pub fn init(bpm: *BufferPoolManager, root_page_id: PageId) BTree {
        return .{ .bpm = bpm, .root_page_id = root_page_id };
    }

    pub fn create(bpm: *BufferPoolManager) !BTree {
        const frame = try bpm.newPage();
        const root_page_id = frame.page_id;
        var leaf = LeafNode.init(frame.data[0..]);
        leaf.format(true);
        try bpm.unpinPage(root_page_id, true);
        return .{ .bpm = bpm, .root_page_id = root_page_id };
    }

    pub fn put(self: *BTree, key: []const u8, value: []const u8) !void {
        if ((try self.insertRecursive(self.root_page_id, key, value))) |promotion| {
            defer self.bpm.allocator.free(promotion.separator_key);

            const root_frame = try self.bpm.newPage();
            const new_root_id = root_frame.page_id;
            var root = InternalNode.init(root_frame.data[0..]);
            root.format(true);
            setInternalLeftmost(root_frame.data[0..], self.root_page_id);
            try root.insertChild(promotion.separator_key, promotion.right_page_id);
            try self.bpm.unpinPage(new_root_id, true);
            self.root_page_id = new_root_id;
        }
    }

    pub fn get(self: *BTree, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        var page_id = self.root_page_id;
        while (true) {
            const frame = try self.bpm.fetchPage(page_id);
            const kind = try nodeKind(frame.data[0..]);
            switch (kind) {
                .leaf => {
                    const leaf = LeafNode.init(frame.data[0..]);
                    const value = try leaf.get(allocator, key);
                    try self.bpm.unpinPage(page_id, false);
                    return value;
                },
                .internal => {
                    const internal = InternalNode.init(frame.data[0..]);
                    const next_page_id = try internal.childForKeyChecked(key);
                    try self.bpm.unpinPage(page_id, false);
                    page_id = next_page_id;
                },
            }
        }
    }

    pub fn delete(self: *BTree, key: []const u8) !bool {
        const leaf_page_id = try self.findLeafPage(key);
        const frame = try self.bpm.fetchPage(leaf_page_id);
        var leaf = LeafNode.init(frame.data[0..]);
        const removed = try leaf.delete(key);
        try self.bpm.unpinPage(leaf_page_id, removed);
        return removed;
    }

    pub fn scan(
        self: *BTree,
        allocator: std.mem.Allocator,
        start_key: ?[]const u8,
        end_key: ?[]const u8,
        limit: ?usize,
    ) ![]PairOwned {
        var result: std.ArrayList(PairOwned) = .empty;
        errdefer {
            for (result.items) |*pair| pair.deinit(allocator);
            result.deinit(allocator);
        }

        var page_id = if (start_key) |key| try self.findLeafPage(key) else try self.leftmostLeafPage();
        var start_filter = start_key;

        while (page_id.isValid()) {
            const frame = try self.bpm.fetchPage(page_id);
            const leaf = LeafNode.init(frame.data[0..]);
            var slots = slotted(frame.data[0..]);
            var index: usize = if (start_filter) |key| leaf.lowerBound(key) else 0;
            start_filter = null;

            while (index < slots.numSlots()) : (index += 1) {
                const view = try decodePairView(try slots.get(index));
                if (end_key) |end| {
                    if (std.mem.order(u8, view.key, end) != .lt) {
                        try self.bpm.unpinPage(page_id, false);
                        return try result.toOwnedSlice(allocator);
                    }
                }
                const owned = try Pair.decode(allocator, try slots.get(index));
                try result.append(allocator, owned);
                if (limit) |max| {
                    if (result.items.len >= max) {
                        try self.bpm.unpinPage(page_id, false);
                        return try result.toOwnedSlice(allocator);
                    }
                }
            }

            const next_page_id = leafNext(frame.data[0..]);
            try self.bpm.unpinPage(page_id, false);
            page_id = next_page_id;
        }

        return try result.toOwnedSlice(allocator);
    }

    pub fn rootPageId(self: *const BTree) PageId {
        return self.root_page_id;
    }

    fn insertRecursive(self: *BTree, page_id: PageId, key: []const u8, value: []const u8) !?Promotion {
        const frame = try self.bpm.fetchPage(page_id);
        const kind = try nodeKind(frame.data[0..]);
        switch (kind) {
            .leaf => return try self.insertIntoLeaf(page_id, frame, key, value),
            .internal => {
                const internal = InternalNode.init(frame.data[0..]);
                const child_page_id = try internal.childForKeyChecked(key);
                try self.bpm.unpinPage(page_id, false);
                if ((try self.insertRecursive(child_page_id, key, value))) |promotion| {
                    return try self.insertIntoInternal(page_id, promotion);
                }
                return null;
            },
        }
    }

    fn insertIntoLeaf(self: *BTree, page_id: PageId, frame: *storage.Buffer, key: []const u8, value: []const u8) !?Promotion {
        var leaf = LeafNode.init(frame.data[0..]);
        _ = leaf.insert(key, value) catch |err| switch (err) {
            error.OutOfSpace => return try self.splitLeaf(page_id, frame, key, value),
            else => return err,
        };
        try self.bpm.unpinPage(page_id, true);
        return null;
    }

    fn splitLeaf(self: *BTree, page_id: PageId, frame: *storage.Buffer, key: []const u8, value: []const u8) !Promotion {
        const allocator = self.bpm.allocator;
        var pairs = try collectLeafPairs(allocator, frame.data[0..]);
        defer freePairs(allocator, &pairs);

        try upsertPairOwned(allocator, &pairs, key, value);
        if (pairs.items.len < 2) return error.RecordTooLarge;

        const split_index = pairs.items.len / 2;
        const old_prev = leafPrev(frame.data[0..]);
        const old_next = leafNext(frame.data[0..]);

        const new_frame = try self.bpm.newPage();
        const new_page_id = new_frame.page_id;

        formatLeafWithLinks(frame.data[0..], false, old_prev, new_page_id);
        try appendLeafPairs(frame.data[0..], pairs.items[0..split_index]);

        formatLeafWithLinks(new_frame.data[0..], false, page_id, old_next);
        try appendLeafPairs(new_frame.data[0..], pairs.items[split_index..]);

        if (old_next.isValid()) {
            const next_frame = try self.bpm.fetchPage(old_next);
            setLeafPrev(next_frame.data[0..], new_page_id);
            try self.bpm.unpinPage(old_next, true);
        }

        const separator_key = try allocator.dupe(u8, pairs.items[split_index].key);
        try self.bpm.unpinPage(new_page_id, true);
        try self.bpm.unpinPage(page_id, true);
        return .{ .separator_key = separator_key, .right_page_id = new_page_id };
    }

    fn insertIntoInternal(self: *BTree, page_id: PageId, promotion: Promotion) !?Promotion {
        defer self.bpm.allocator.free(promotion.separator_key);

        const frame = try self.bpm.fetchPage(page_id);
        var internal = InternalNode.init(frame.data[0..]);
        internal.insertChild(promotion.separator_key, promotion.right_page_id) catch |err| switch (err) {
            error.OutOfSpace => return try self.splitInternal(page_id, frame, promotion),
            else => return err,
        };
        try self.bpm.unpinPage(page_id, true);
        return null;
    }

    fn splitInternal(self: *BTree, page_id: PageId, frame: *storage.Buffer, promotion: Promotion) !Promotion {
        const allocator = self.bpm.allocator;
        var records = try collectInternalRecords(allocator, frame.data[0..]);
        defer freeInternalRecords(allocator, &records);

        try insertInternalRecordOwned(allocator, &records, promotion.separator_key, promotion.right_page_id);
        if (records.items.len < 2) return error.RecordTooLarge;

        const old_leftmost = internalLeftmost(frame.data[0..]);
        const mid = records.items.len / 2;
        const promoted_key = try allocator.dupe(u8, records.items[mid].key);
        const right_leftmost = records.items[mid].child;

        const new_frame = try self.bpm.newPage();
        const new_page_id = new_frame.page_id;

        formatInternalWithLeftmost(frame.data[0..], false, old_leftmost);
        try appendInternalRecords(frame.data[0..], records.items[0..mid]);

        formatInternalWithLeftmost(new_frame.data[0..], false, right_leftmost);
        try appendInternalRecords(new_frame.data[0..], records.items[mid + 1 ..]);

        try self.bpm.unpinPage(new_page_id, true);
        try self.bpm.unpinPage(page_id, true);
        return .{ .separator_key = promoted_key, .right_page_id = new_page_id };
    }

    fn findLeafPage(self: *BTree, key: []const u8) !PageId {
        var page_id = self.root_page_id;
        while (true) {
            const frame = try self.bpm.fetchPage(page_id);
            const kind = try nodeKind(frame.data[0..]);
            switch (kind) {
                .leaf => {
                    try self.bpm.unpinPage(page_id, false);
                    return page_id;
                },
                .internal => {
                    const internal = InternalNode.init(frame.data[0..]);
                    const next_page_id = try internal.childForKeyChecked(key);
                    try self.bpm.unpinPage(page_id, false);
                    page_id = next_page_id;
                },
            }
        }
    }

    fn leftmostLeafPage(self: *BTree) !PageId {
        var page_id = self.root_page_id;
        while (true) {
            const frame = try self.bpm.fetchPage(page_id);
            const kind = try nodeKind(frame.data[0..]);
            switch (kind) {
                .leaf => {
                    try self.bpm.unpinPage(page_id, false);
                    return page_id;
                },
                .internal => {
                    const next_page_id = internalLeftmost(frame.data[0..]);
                    try self.bpm.unpinPage(page_id, false);
                    page_id = next_page_id;
                },
            }
        }
    }
};

fn decodePairView(bytes: []const u8) !PairView {
    if (bytes.len < 16) return error.CorruptPage;
    const key_len_u64 = std.mem.readInt(u64, bytes[0..8], .little);
    const value_len_u64 = std.mem.readInt(u64, bytes[8..16], .little);
    const key_len = std.math.cast(usize, key_len_u64) orelse return error.CorruptPage;
    const value_len = std.math.cast(usize, value_len_u64) orelse return error.CorruptPage;
    if (16 + key_len > bytes.len) return error.CorruptPage;
    if (16 + key_len + value_len > bytes.len) return error.CorruptPage;
    return .{
        .key = bytes[16..][0..key_len],
        .value = bytes[16 + key_len ..][0..value_len],
    };
}

fn slotted(bytes: []u8) SlottedPage {
    return SlottedPage.init(bytes[NODE_HEADER_SIZE..]);
}

fn formatNode(bytes: []u8, kind: NodeKind, is_root: bool) void {
    @memset(bytes, 0);
    bytes[KIND_OFFSET] = @intFromEnum(kind);
    bytes[FLAGS_OFFSET] = if (is_root) 1 else 0;
    var page = slotted(bytes);
    page.format();
}

fn formatLeafWithLinks(bytes: []u8, is_root: bool, prev: PageId, next: PageId) void {
    formatNode(bytes, .leaf, is_root);
    setLeafPrev(bytes, prev);
    setLeafNext(bytes, next);
}

fn formatInternalWithLeftmost(bytes: []u8, is_root: bool, leftmost: PageId) void {
    formatNode(bytes, .internal, is_root);
    setInternalLeftmost(bytes, leftmost);
}

fn nodeKind(bytes: []const u8) !NodeKind {
    return switch (bytes[KIND_OFFSET]) {
        @intFromEnum(NodeKind.leaf) => .leaf,
        @intFromEnum(NodeKind.internal) => .internal,
        else => error.CorruptPage,
    };
}

fn leafPrev(bytes: []const u8) PageId {
    return readPageId(bytes, LINK_A_OFFSET);
}

fn leafNext(bytes: []const u8) PageId {
    return readPageId(bytes, LINK_B_OFFSET);
}

fn setLeafPrev(bytes: []u8, page_id: PageId) void {
    writePageId(bytes, LINK_A_OFFSET, page_id);
}

fn setLeafNext(bytes: []u8, page_id: PageId) void {
    writePageId(bytes, LINK_B_OFFSET, page_id);
}

fn internalLeftmost(bytes: []const u8) PageId {
    return readPageId(bytes, LINK_A_OFFSET);
}

fn setInternalLeftmost(bytes: []u8, page_id: PageId) void {
    writePageId(bytes, LINK_A_OFFSET, page_id);
}

fn readPageId(bytes: []const u8, offset: usize) PageId {
    return PageId.init(std.mem.readInt(u64, bytes[offset..][0..8], .little));
}

fn writePageId(bytes: []u8, offset: usize, page_id: PageId) void {
    std.mem.writeInt(u64, bytes[offset..][0..8], page_id.toU64(), .little);
}

fn encodeInternalRecord(key: []const u8, child: PageId, out: []u8) !usize {
    var child_bytes = [_]u8{0} ** 8;
    std.mem.writeInt(u64, child_bytes[0..8], child.toU64(), .little);
    const pair = Pair{ .key = key, .value = &child_bytes };
    if (pair.encodedLen() > PAGE_SIZE) return error.RecordTooLarge;
    try pair.encode(out[0..pair.encodedLen()]);
    return pair.encodedLen();
}

fn decodeInternalRecord(bytes: []const u8) !struct { key: []const u8, child: PageId } {
    const pair = try decodePairView(bytes);
    if (pair.value.len != 8) return error.CorruptPage;
    return .{
        .key = pair.key,
        .child = PageId.init(std.mem.readInt(u64, pair.value[0..8], .little)),
    };
}

fn collectLeafPairs(allocator: std.mem.Allocator, bytes: []u8) !std.ArrayList(PairOwned) {
    var result: std.ArrayList(PairOwned) = .empty;
    errdefer freePairs(allocator, &result);
    var slots = slotted(bytes);
    for (0..slots.numSlots()) |index| {
        try result.append(allocator, try Pair.decode(allocator, try slots.get(index)));
    }
    return result;
}

fn freePairs(allocator: std.mem.Allocator, pairs: *std.ArrayList(PairOwned)) void {
    for (pairs.items) |*pair| pair.deinit(allocator);
    pairs.deinit(allocator);
}

fn upsertPairOwned(allocator: std.mem.Allocator, pairs: *std.ArrayList(PairOwned), key: []const u8, value: []const u8) !void {
    var index: usize = 0;
    while (index < pairs.items.len) : (index += 1) {
        switch (std.mem.order(u8, pairs.items[index].key, key)) {
            .lt => continue,
            .eq => {
                const new_value = try allocator.dupe(u8, value);
                allocator.free(pairs.items[index].value);
                pairs.items[index].value = new_value;
                return;
            },
            .gt => break,
        }
    }

    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    const owned_value = try allocator.dupe(u8, value);
    try pairs.insert(allocator, index, .{ .key = owned_key, .value = owned_value });
}

fn appendLeafPairs(bytes: []u8, pairs: []const PairOwned) !void {
    var slots = slotted(bytes);
    for (pairs) |pair| {
        var encoded = [_]u8{0} ** PAGE_SIZE;
        const borrowed = Pair{ .key = pair.key, .value = pair.value };
        try borrowed.encode(encoded[0..borrowed.encodedLen()]);
        _ = try slots.append(encoded[0..borrowed.encodedLen()]);
    }
}

fn collectInternalRecords(allocator: std.mem.Allocator, bytes: []u8) !std.ArrayList(InternalRecordOwned) {
    var result: std.ArrayList(InternalRecordOwned) = .empty;
    errdefer freeInternalRecords(allocator, &result);
    var slots = slotted(bytes);
    for (0..slots.numSlots()) |index| {
        const record = try decodeInternalRecord(try slots.get(index));
        const key = try allocator.dupe(u8, record.key);
        try result.append(allocator, .{ .key = key, .child = record.child });
    }
    return result;
}

fn freeInternalRecords(allocator: std.mem.Allocator, records: *std.ArrayList(InternalRecordOwned)) void {
    for (records.items) |*record| record.deinit(allocator);
    records.deinit(allocator);
}

fn insertInternalRecordOwned(
    allocator: std.mem.Allocator,
    records: *std.ArrayList(InternalRecordOwned),
    key: []const u8,
    child: PageId,
) !void {
    var index: usize = 0;
    while (index < records.items.len and std.mem.order(u8, records.items[index].key, key) == .lt) : (index += 1) {}
    const owned_key = try allocator.dupe(u8, key);
    try records.insert(allocator, index, .{ .key = owned_key, .child = child });
}

fn appendInternalRecords(bytes: []u8, records: []const InternalRecordOwned) !void {
    var slots = slotted(bytes);
    for (records) |record| {
        var encoded = [_]u8{0} ** PAGE_SIZE;
        const len = try encodeInternalRecord(record.key, record.child, &encoded);
        _ = try slots.append(encoded[0..len]);
    }
}

test "Pair encode decode roundtrip" {
    const pair = Pair{ .key = "hello", .value = "world" };
    var bytes = [_]u8{0} ** 64;
    try pair.encode(bytes[0..pair.encodedLen()]);
    var decoded = try Pair.decode(std.testing.allocator, bytes[0..pair.encodedLen()]);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", decoded.key);
    try std.testing.expectEqualStrings("world", decoded.value);
}

test "LeafNode insert get update delete" {
    var bytes = [_]u8{0} ** PAGE_SIZE;
    var leaf = LeafNode.init(&bytes);
    leaf.format(true);
    _ = try leaf.insert("b", "2");
    _ = try leaf.insert("a", "1");
    _ = try leaf.insert("b", "22");
    try std.testing.expectEqual(@as(usize, 0), leaf.lowerBound("a"));
    const got = try leaf.get(std.testing.allocator, "b");
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqualStrings("22", got.?);
    try std.testing.expect(try leaf.delete("a"));
    try std.testing.expect(!(try leaf.delete("missing")));
}

test "InternalNode child lookup" {
    var bytes = [_]u8{0} ** PAGE_SIZE;
    var internal = InternalNode.init(&bytes);
    internal.format(true);
    setInternalLeftmost(&bytes, PageId.init(1));
    try internal.insertChild("m", PageId.init(2));
    try internal.insertChild("t", PageId.init(3));
    try std.testing.expectEqual(@as(u64, 1), internal.childForKey("a").toU64());
    try std.testing.expectEqual(@as(u64, 2), internal.childForKey("m").toU64());
    try std.testing.expectEqual(@as(u64, 3), internal.childForKey("z").toU64());
}

test "BTree put get scan delete and split" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(std.testing.io, "tree.db", .{ .read = true });
    var disk_manager = try storage.DiskManager.init(file);
    defer disk_manager.close();

    var bpm = try BufferPoolManager.init(std.testing.allocator, &disk_manager, 16);
    defer bpm.deinit();

    var tree = try BTree.create(&bpm);
    for (0..1000) |i| {
        const key = [_]u8{ @intCast(i / 256), @intCast(i % 256) };
        const value = [_]u8{ @intCast(i % 256), @intCast(i / 256) };
        try tree.put(&key, &value);
    }

    for (0..1000) |i| {
        const key = [_]u8{ @intCast(i / 256), @intCast(i % 256) };
        const value = try tree.get(std.testing.allocator, &key);
        defer std.testing.allocator.free(value.?);
        try std.testing.expectEqual(@as(u8, @intCast(i % 256)), value.?[0]);
    }

    const start = [_]u8{ 0, 10 };
    const pairs = try tree.scan(std.testing.allocator, &start, null, 5);
    defer {
        for (pairs) |*pair| pair.deinit(std.testing.allocator);
        std.testing.allocator.free(pairs);
    }
    try std.testing.expectEqual(@as(usize, 5), pairs.len);
    try std.testing.expectEqual(@as(u8, 10), pairs[0].key[1]);

    const delete_key = [_]u8{ 0, 42 };
    try std.testing.expect(try tree.delete(&delete_key));
    const missing = try tree.get(std.testing.allocator, &delete_key);
    try std.testing.expectEqual(@as(?[]u8, null), missing);
}
