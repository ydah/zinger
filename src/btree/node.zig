const Leaf = @import("leaf.zig");
const Branch = @import("branch.zig");

pub const NODE_TYPE_LEAF = "LEAF    ";
pub const NODE_TYPE_BRANCH = "BRANCH  ";

pub const Header = struct {
    node_type: [8]u8,
};

pub const Node = struct {
    const Self = @This();

    header: Header,
    body: []u8,

    pub fn init(bytes: anytype) Self {
        return Self{
            .header = Header{ .node_type = bytes[0..Header.size] },
            .body = bytes[Header.size..],
        };
    }

    pub fn initialize_as_leaf(self: *Self) void {
        self.header.node_type = NODE_TYPE_LEAF;
    }

    pub fn initialize_as_branch(self: *Self) void {
        self.header.node_type = NODE_TYPE_BRANCH;
    }
};

pub const Body = union {
    const Self = @This();

    leaf: Leaf,
    branch: Branch,

    pub fn init(node_type: [8]u8, bytes: anytype) Body {
        return switch (node_type) {
            NODE_TYPE_LEAF => Body{ .leaf = Leaf.init(bytes) },
            NODE_TYPE_BRANCH => Body{ .branch = Branch.init(bytes) },
            else => unreachable,
        };
    }
};
