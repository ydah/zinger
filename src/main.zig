const std = @import("std");
const zinger = @import("zinger");

const usage =
    \\Usage:
    \\  zinger --help
    \\  zinger <db-path> put <key> <value>
    \\  zinger <db-path> get <key>
    \\  zinger <db-path> delete <key>
    \\  zinger <db-path> scan [--start <key>] [--limit <n>]
    \\  zinger <db-path> sql "<SQL>"
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var arg_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer arg_iter.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    while (arg_iter.next()) |arg| try args.append(allocator, arg);

    if (args.items.len == 1 or (args.items.len == 2 and std.mem.eql(u8, args.items[1], "--help"))) {
        try printStdout(io, "{s}", .{usage});
        return;
    }

    if (args.items.len < 3) {
        try printStderr(io, "{s}", .{usage});
        std.process.exit(2);
    }

    const db_path = args.items[1];
    const command = args.items[2];

    var db = try zinger.Database.openWithIo(allocator, io, db_path, 64);
    defer db.close() catch {};

    if (std.mem.eql(u8, command, "put")) {
        if (args.items.len != 5) {
            try printStderr(io, "{s}", .{usage});
            std.process.exit(2);
        }
        try db.put(args.items[3], args.items[4]);
        return;
    }

    if (std.mem.eql(u8, command, "get")) {
        if (args.items.len != 4) {
            try printStderr(io, "{s}", .{usage});
            std.process.exit(2);
        }
        const value = try db.get(allocator, args.items[3]) orelse {
            try printStderr(io, "not found\n", .{});
            std.process.exit(1);
        };
        defer allocator.free(value);
        try printStdout(io, "{s}\n", .{value});
        return;
    }

    if (std.mem.eql(u8, command, "delete")) {
        if (args.items.len != 4) {
            try printStderr(io, "{s}", .{usage});
            std.process.exit(2);
        }
        if (!try db.delete(args.items[3])) {
            try printStderr(io, "not found\n", .{});
            std.process.exit(1);
        }
        return;
    }

    if (std.mem.eql(u8, command, "scan")) {
        var start_key: ?[]const u8 = null;
        var limit: ?usize = null;
        var index: usize = 3;
        while (index < args.items.len) {
            if (std.mem.eql(u8, args.items[index], "--start")) {
                if (index + 1 >= args.items.len) {
                    try printStderr(io, "{s}", .{usage});
                    std.process.exit(2);
                }
                start_key = args.items[index + 1];
                index += 2;
                continue;
            }
            if (std.mem.eql(u8, args.items[index], "--limit")) {
                if (index + 1 >= args.items.len) {
                    try printStderr(io, "{s}", .{usage});
                    std.process.exit(2);
                }
                limit = try std.fmt.parseInt(usize, args.items[index + 1], 10);
                index += 2;
                continue;
            }
            try printStderr(io, "{s}", .{usage});
            std.process.exit(2);
        }

        const pairs = try db.scan(allocator, start_key, null, limit);
        defer {
            for (pairs) |*pair| pair.deinit(allocator);
            allocator.free(pairs);
        }
        for (pairs) |pair| {
            try printStdout(io, "{s}\t{s}\n", .{ pair.key, pair.value });
        }
        return;
    }

    if (std.mem.eql(u8, command, "sql")) {
        if (args.items.len != 4) {
            try printStderr(io, "{s}", .{usage});
            std.process.exit(2);
        }
        const output = try zinger.executeSql(allocator, &db, args.items[3]);
        defer allocator.free(output);
        try printStdout(io, "{s}", .{output});
        return;
    }

    try printStderr(io, "{s}", .{usage});
    std.process.exit(2);
}

fn printStdout(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer_state = std.Io.File.stdout().writer(io, &buffer);
    const writer = &writer_state.interface;
    try writer.print(fmt, args);
    try writer.flush();
}

fn printStderr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer_state = std.Io.File.stderr().writer(io, &buffer);
    const writer = &writer_state.interface;
    try writer.print(fmt, args);
    try writer.flush();
}

test "usage includes commands" {
    try std.testing.expect(std.mem.indexOf(u8, usage, "put") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "scan") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "sql") != null);
}
