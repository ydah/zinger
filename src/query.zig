const std = @import("std");
const BTree = @import("btree");
const tuple = @import("tuple");
const BufferPoolManager = @import("buffer").BufferPoolManager;
const PageId = @import("disk").PageId;

pub const Tuple = std.ArrayList([]u8);
pub const TupleSlice = []const []u8;

pub const TupleSearchMode = union(enum) {
    Start,
    Key: []const []u8,

    pub fn encode(self: TupleSearchMode) BTree.SearchMode {
        return switch (self) {
            .Start => BTree.SearchMode.Start,
            .Key => {
                var key = std.ArrayList(u8).init(std.heap.page_allocator);
                defer key.deinit();
                tuple.encode(self.Key, &key);
                return BTree.SearchMode.Key(key.items);
            },
        };
    }
};

const Executor = struct {
    next: fn (executor: *Executor, bufmgr: *BufferPoolManager) ?Tuple,
};

const PlanNode = struct {
    start: fn (plan_node: *PlanNode, bufmgr: *BufferPoolManager) *Executor,
};

pub const SeqScan = struct {
    table_meta_page_id: PageId,
    search_mode: TupleSearchMode,
    while_cond: fn (TupleSlice) bool,

    pub fn start(self: *SeqScan, bufmgr: *BufferPoolManager) !*Executor {
        const btree = BTree.new(self.table_meta_page_id);
        const table_iter = try btree.search(bufmgr, self.search_mode.encode());
        return ExecSeqScan{
            .table_iter = table_iter,
            .while_cond = self.while_cond,
        };
    }
};

pub const ExecSeqScan = struct {
    table_iter: BTree.Iter,
    while_cond: fn (TupleSlice) bool,

    pub fn next(self: *ExecSeqScan, bufmgr: *BufferPoolManager) !?Tuple {
        const pair = try self.table_iter.next(bufmgr);
        if (pair == null) return null;

        var pkey = std.ArrayList([]u8).init(std.heap.page_allocator);
        defer pkey.deinit();
        tuple.decode(pair.?[0], &pkey);

        if (!self.while_cond(pkey.items)) return null;

        var full_tuple = std.ArrayList([]u8).init(std.heap.page_allocator);
        defer full_tuple.deinit();
        full_tuple.appendAll(pkey.items) catch {};
        tuple.decode(pair.?[1], &full_tuple);

        return full_tuple;
    }
};

pub const Filter = struct {
    inner_plan: *const PlanNode,
    cond: fn (TupleSlice) bool,

    pub fn start(self: *Filter, bufmgr: *BufferPoolManager) !*Executor {
        const inner_iter = try self.inner_plan.start(bufmgr);
        return ExecFilter{
            .inner_iter = inner_iter,
            .cond = self.cond,
        };
    }
};

pub const ExecFilter = struct {
    inner_iter: *Executor,
    cond: fn (TupleSlice) bool,

    pub fn next(self: *ExecFilter, bufmgr: *BufferPoolManager) !?Tuple {
        while (true) {
            const ntuple = try self.inner_iter.next(bufmgr);
            if (ntuple == null) return null;
            if (self.cond(ntuple.?)) return ntuple;
        }
    }
};
