//! Pure kernel-message ring buffer (G4) — the storage behind /dev/kmsg.
//!
//! Deliberately free of arch dependencies and allocation so host tests can
//! exercise it directly (wired via kernel/host_test.zig) and so the kernel
//! can call it from any context while holding an IrqSpinlock.
//!
//! Model: a byte ring plus an absolute stream cursor. `total` counts every
//! byte ever appended; a reader's cursor is an absolute position in that
//! stream. Bytes older than `total - len` are gone — stale cursors clamp
//! forward to the oldest surviving byte.
//!
//! Overwrite policy keeps whole-line semantics where cheap: appending a
//! line that does not fit drops oldest *complete* lines (up to and
//! including their '\n') until it does. A single line larger than the whole
//! buffer keeps only its tail (which then necessarily starts mid-line).

pub const ReadResult = struct {
    /// Bytes copied into the caller's buffer (0 at end of data).
    n: usize,
    /// Absolute cursor one past the last byte returned.
    new_pos: u64,
};

/// Bytes a reader at absolute cursor `cursor` can still get from a stream
/// whose newest position is `total` (J3). Zero when the reader is caught up
/// (or ahead). A stale cursor — older than the oldest surviving byte —
/// reports the full absolute backlog `total - cursor`: `read()` clamps such
/// cursors forward, and the blocking-read / epoll readiness decisions this
/// feeds only need "zero vs non-zero".
pub fn bytesAvailable(total: u64, cursor: u64) u64 {
    if (cursor >= total) return 0;
    return total - cursor;
}

pub fn KmsgRing(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buf: [capacity]u8 = @splat(0),
        /// Ring index of the oldest stored byte.
        start: usize = 0,
        /// Bytes currently stored.
        len: usize = 0,
        /// Absolute stream position of the next byte to append.
        total: u64 = 0,

        /// Absolute cursor of the oldest byte still available.
        pub fn oldestPos(self: *const Self) u64 {
            return self.total - @as(u64, self.len);
        }

        /// Absolute cursor one past the newest stored byte.
        pub fn newestPos(self: *const Self) u64 {
            return self.total;
        }

        /// Append `line` (a whole line including its trailing '\n', or one
        /// piece of a line when the caller assembles lines from parts).
        /// Drops oldest complete lines until the append fits.
        pub fn appendLine(self: *Self, line_in: []const u8) void {
            var line = line_in;
            if (line.len > capacity) {
                // Larger than the whole ring: only the tail can ever fit.
                line = line[line.len - capacity ..];
            }
            while (capacity - self.len < line.len) {
                if (self.len == 0) break; // defensive; truncation above bounds line.len
                self.dropOldestLine();
            }
            var rest = line;
            while (rest.len > 0) {
                const write_idx = (self.start + self.len) % capacity;
                const chunk = @min(rest.len, capacity - write_idx);
                // AArch64 traps on compiler-rt's unaligned word-copy path
                // when klog appends an unaligned rodata string during boot.
                for (0..chunk) |i| self.buf[write_idx + i] = rest[i];
                self.len += chunk;
                self.total += chunk;
                rest = rest[chunk..];
            }
        }

        /// Drop the oldest complete line (through its '\n'). If the oldest
        /// content has no newline (a partial over-long line), drop it all.
        fn dropOldestLine(self: *Self) void {
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (self.buf[(self.start + i) % capacity] == '\n') {
                    const drop = i + 1;
                    self.start = (self.start + drop) % capacity;
                    self.len -= drop;
                    return;
                }
            }
            self.len = 0;
        }

        /// Copy up to `out.len` bytes starting at absolute cursor `read_pos`.
        /// A stale cursor (< oldest available) clamps to the oldest byte.
        /// The copy stops at the physical wrap point, so a short read is
        /// normal — callers loop on `new_pos` for more.
        pub fn read(self: *const Self, read_pos: u64, out: []u8) ReadResult {
            var pos = read_pos;
            const oldest = self.oldestPos();
            if (pos < oldest) pos = oldest;
            if (pos >= self.total or out.len == 0) return .{ .n = 0, .new_pos = pos };
            const off: usize = @intCast(pos - oldest);
            const idx = (self.start + off) % capacity;
            const n = @min(@min(out.len, self.len - off), capacity - idx);
            for (0..n) |i| out[i] = self.buf[idx + i];
            return .{ .n = n, .new_pos = pos + n };
        }
    };
}
