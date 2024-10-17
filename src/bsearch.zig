const std = @import("std");

const Ordering = enum {
    Less,
    Greater,
    Equal,
};

pub fn binarySearchBy(size: usize, cmp_fn: fn (usize) Ordering) !usize {
    var left: usize = 0;
    var right: usize = size;

    while (left < right) {
        const mid = left + size / 2;
        const cmp = cmp_fn(mid);

        switch (cmp) {
            Ordering.Less => {
                left = mid + 1;
            },
            Ordering.Greater => {
                right = mid;
            },
            Ordering.Equal => return mid,
        }

        size = right - left;
    }

    return error.LeftIndex;
}
