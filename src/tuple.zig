const std = @import("std");
const memcmpable = @import("memcmpable.zig");

pub fn encode(elems: []const []const u8, bytes: *std.ArrayList(u8)) !void {
    for (elems) |elem| {
        const len = memcmpable.encoded_size(elem.len);
        try bytes.ensureTotalCapacity(bytes.items.len + len);
        try memcmpable.encode(elem, bytes);
    }
}

pub fn decode(bytes: []const u8, elems: *std.ArrayList([]u8)) !void {
    var rest = bytes;
    while (rest.len > 0) {
        var elem = std.ArrayList([]u8).init(std.heap.page_allocator);
        try memcmpable.decode(&rest, &elem);
        try elems.append(elem.items);
    }
}
