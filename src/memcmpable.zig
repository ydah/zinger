const std = @import("std");

const ESCAPE_LENGTH = 9;

fn encodedSize(len: usize) usize {
    return (std.math.divCeil(len, ESCAPE_LENGTH - 1)) * ESCAPE_LENGTH;
}

fn encode(src: []const u8, dst: *std.ArrayList(u8)) !void {
    var remaining = src;

    while (remaining.len > 0) {
        const copyLen = std.math.min(ESCAPE_LENGTH - 1, remaining.len);
        try dst.appendSlice(remaining[0..copyLen]);
        remaining = remaining[copyLen..];

        if (remaining.len == 0) {
            const padSize = ESCAPE_LENGTH - 1 - copyLen;
            if (padSize > 0) {
                try dst.ensureTotalCapacity(dst.items.len + padSize);
                dst.appendRepeat(0, padSize);
            }
            try dst.append(@intCast(copyLen));
            break;
        }
        try dst.append(@intCast(ESCAPE_LENGTH));
    }
}

fn decode(src: []const u8, dst: *std.ArrayList(u8)) !void {
    var remaining = src;

    while (remaining.len >= ESCAPE_LENGTH) {
        const extra = remaining[ESCAPE_LENGTH - 1];
        const len = std.math.min(ESCAPE_LENGTH - 1, @intCast(extra));
        try dst.appendSlice(remaining[0..len]);
        remaining = remaining[ESCAPE_LENGTH..];

        if (extra < ESCAPE_LENGTH) {
            break;
        }
    }
}
