//! A pipe's buffers as Linux counts them (fs/pipe.c anon_pipe_write, pipe_read, pipe_poll): the queued bytes sit in page-sized
//! slots, one per pipe_buffer, and a pipe of `cap` bytes has cap / 4096 of them. A write first puts its remainder (its length modulo
//! the page size) into the last slot when the pipe is not empty and that fits (PIPE_BUF_FLAG_CAN_MERGE), then takes a fresh slot
//! for every page of what is left; the pipe is full (no POLLOUT, a write waits) once every slot is taken, however few bytes they
//! hold. A read frees a slot when it has taken all of its bytes. The bytes themselves stay in the pipe's ring; this only keeps
//! count of where each slot ends.
const std = @import("std");

pub const PAGE: u16 = 4096;
/// Slots of the largest pipe (vfs: 4 MiB, fcntl_policy.PIPE_HARD_MAX).
pub const MAX_SLOTS: usize = 1024;

pub const Slots = struct {
    /// Index of the oldest slot in `ends`, how many are in use, and how far the oldest one has been read.
    first: u16 = 0,
    count: u16 = 0,
    first_off: u16 = 0,
    /// Counts every buffer taken, so a write can tell whether the last buffer is still the one it took.
    pushes: u32 = 0,
    /// Where each slot's bytes end within its page (1..4096), with NOMERGE set on a slot a later write may not add to (one spliced
    /// in from another pipe: splice_pipe_to_pipe clears PIPE_BUF_FLAG_CAN_MERGE).
    ends: [MAX_SLOTS]u16 = @splat(0),

    const NOMERGE: u16 = 0x8000;

    fn at(self: *const Slots, i: usize) usize {
        return (self.first + i) % MAX_SLOTS;
    }

    fn endOf(self: *const Slots, i: usize) usize {
        return self.ends[i] & ~NOMERGE;
    }

    /// No slot left for a pipe of `max` slots (pipe_full).
    pub fn full(self: *const Slots, max: usize) bool {
        return self.count >= max;
    }

    pub fn free(self: *const Slots, max: usize) usize {
        return if (self.count >= max) 0 else max - self.count;
    }

    /// How many of a write's first `chars` bytes the last slot takes: all of them when the pipe holds something and they fit
    /// behind what that slot already has, else none.
    pub fn mergeable(self: *const Slots, chars: usize) bool {
        if (self.count == 0 or chars == 0) return false;
        const last = self.ends[self.at(self.count - 1)];
        return last & NOMERGE == 0 and @as(usize, last) + chars <= PAGE;
    }

    pub fn merge(self: *Slots, chars: usize) void {
        self.ends[self.at(self.count - 1)] += @intCast(chars);
    }

    /// A fresh slot holding `n` bytes (1..4096).
    pub fn push(self: *Slots, n: usize) void {
        self.ends[self.at(self.count)] = @intCast(n);
        self.count += 1;
        self.pushes +%= 1;
    }

    /// A read took `n` bytes from the front: every slot emptied by it is freed.
    pub fn consume(self: *Slots, n_in: usize) void {
        var n = n_in;
        while (n > 0 and self.count > 0) {
            const left: usize = self.endOf(self.first) - self.first_off;
            if (n < left) {
                self.first_off += @intCast(n);
                return;
            }
            n -= left;
            self.first = @intCast((self.first + 1) % MAX_SLOTS);
            self.count -= 1;
            self.first_off = 0;
        }
        if (self.count == 0) self.first_off = 0;
    }
};

/// splice from pipe `src` into pipe `dst` (of `dst_max` slots): up to `count` bytes, a slot at a time while `dst` has a free slot;
/// each piece takes a slot of its own in `dst`, which no later write merges into. Returns the bytes moved.
pub fn transfer(src: *Slots, dst: *Slots, dst_max: usize, count: usize) usize {
    var moved: usize = 0;
    while (moved < count and src.count > 0 and !dst.full(dst_max)) {
        const left: usize = src.endOf(src.first) - src.first_off;
        const n = @min(left, count - moved);
        dst.ends[dst.at(dst.count)] = @as(u16, @intCast(n)) | Slots.NOMERGE;
        dst.count += 1;
        dst.pushes +%= 1;
        src.consume(n);
        moved += n;
    }
    return moved;
}

/// One write() (or writev()) as anon_pipe_write sees it, carried across the pieces it reaches the pipe in and the waits between
/// them: first the remainder of the whole length (`total` modulo 4096) merges into the last buffer when it fits there, then the
/// bytes fill fresh pages from their start, each page topped up to 4096 before the next is taken.
pub const WriteState = struct {
    total: usize,
    started: bool = false,
    merge_left: usize = 0,
    /// The last buffer is a page this write took (Slots.pushes right after it), which it keeps filling.
    page_open: bool = false,
    my_push: u32 = 0,
};

/// Put up to `want` more bytes of the write into `s` (a pipe of `max` buffers): how many fit now.
pub fn step(s: *Slots, max: usize, st: *WriteState, want: usize) usize {
    if (!st.started) {
        st.started = true;
        const chars = st.total & (PAGE - 1);
        if (s.mergeable(chars)) st.merge_left = chars;
    }
    var took: usize = 0;
    while (took < want) {
        const left = want - took;
        if (st.merge_left != 0) {
            const k = @min(left, st.merge_left);
            s.merge(k);
            st.merge_left -= k;
            took += k;
            continue;
        }
        if (st.page_open and s.count != 0 and s.pushes == st.my_push) {
            const end = s.endOf(s.at(s.count - 1));
            if (end < PAGE) {
                const k = @min(left, PAGE - end);
                s.merge(k);
                took += k;
                continue;
            }
        }
        if (s.full(max)) break;
        const k = @min(left, @as(usize, PAGE));
        s.push(k);
        st.page_open = true;
        st.my_push = s.pushes;
        took += k;
    }
    return took;
}

fn write(s: *Slots, max: usize, total: usize) usize {
    var st: WriteState = .{ .total = total };
    return step(s, max, &st, total);
}

test "sixty-four 1000-byte writes fill a 16-page pipe; a read frees a slot only once it is empty (measured on Linux)" {
    var s: Slots = .{};
    var n: usize = 0;
    while (write(&s, 16, 1000) == 1000) n += 1;
    try std.testing.expectEqual(@as(usize, 64), n);
    s.consume(1000);
    try std.testing.expect(s.full(16));
    s.consume(3000);
    try std.testing.expect(!s.full(16));
    try std.testing.expectEqual(@as(usize, 1000), write(&s, 16, 1000));
    try std.testing.expectEqual(@as(usize, 100), write(&s, 16, 100));
    try std.testing.expectEqual(@as(usize, 0), write(&s, 16, 3000));
}

test "a one-page pipe is full with any byte in it; the remainder of a write merges, the rest takes whole pages" {
    var s: Slots = .{};
    try std.testing.expectEqual(@as(usize, 1000), write(&s, 1, 1000));
    try std.testing.expect(s.full(1));
    try std.testing.expectEqual(@as(usize, 3096), write(&s, 1, 3096));
    try std.testing.expectEqual(@as(usize, 0), write(&s, 1, 1));
    var t: Slots = .{};
    try std.testing.expectEqual(@as(usize, 4000), write(&t, 16, 4000));
    try std.testing.expectEqual(@as(usize, 5000), write(&t, 16, 5000));
    try std.testing.expectEqual(@as(u16, 3), t.count);
    var u: Slots = .{};
    var i: usize = 0;
    while (i < 15) : (i += 1) _ = write(&u, 16, 4096);
    try std.testing.expectEqual(@as(usize, 100), write(&u, 16, 100));
    try std.testing.expectEqual(@as(usize, 3904), write(&u, 16, 8000));
    var e: Slots = .{};
    try std.testing.expectEqual(@as(usize, 65536), write(&e, 16, 70000));
}

test "a slot spliced in from another pipe is not merged into" {
    var a: Slots = .{};
    var b: Slots = .{};
    _ = write(&a, 16, 5000);
    try std.testing.expectEqual(@as(usize, 5000), transfer(&a, &b, 16, 6000));
    try std.testing.expectEqual(@as(u16, 2), b.count);
    try std.testing.expectEqual(@as(u16, 0), a.count);
    try std.testing.expectEqual(@as(usize, 10), write(&b, 16, 10));
    try std.testing.expectEqual(@as(u16, 3), b.count);
    var c: Slots = .{};
    try std.testing.expectEqual(@as(usize, 4096), transfer(&b, &c, 1, 6000));
}

test "a write handed over in pieces is one write: the remainder merges first, then pages are filled whole" {
    var s: Slots = .{};
    var i: usize = 0;
    while (i < 15) : (i += 1) s.push(PAGE);
    s.push(100);
    // write(8000) arrives as 4096 + 3904: the remainder 3904 merges behind the 100 bytes; no buffer is left for the rest.
    var st: WriteState = .{ .total = 8000 };
    try std.testing.expectEqual(@as(usize, 3904), step(&s, 16, &st, 4096));
    var t: Slots = .{};
    t.push(100);
    // writev of three 100-byte pieces after 100 bytes: all 300 merge.
    var w: WriteState = .{ .total = 300 };
    try std.testing.expectEqual(@as(usize, 100), step(&t, 16, &w, 100));
    try std.testing.expectEqual(@as(usize, 100), step(&t, 16, &w, 100));
    try std.testing.expectEqual(@as(usize, 100), step(&t, 16, &w, 100));
    try std.testing.expectEqual(@as(u16, 1), t.count);
    // An empty pipe: three 100-byte pieces fill one fresh page.
    var u: Slots = .{};
    var x: WriteState = .{ .total = 300 };
    for (0..3) |_| _ = step(&u, 16, &x, 100);
    try std.testing.expectEqual(@as(u16, 1), u.count);
}
