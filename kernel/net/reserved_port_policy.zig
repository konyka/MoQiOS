//! net.ipv4.ip_local_reserved_ports (proc_do_large_bitmap): a 65536-bit set with range-list I/O.
//! Writers parse into a private staging bitmap and commit atomically with respect to allocation readers.

const std = @import("std");

const BYTES = 65536 / 8;
var current: [BYTES]u8 = @splat(0);
var staging: [BYTES]u8 = @splat(0);
var writer_active = false;
var readers: u32 = 0;

pub fn readLock() void {
    while (true) {
        while (@atomicLoad(bool, &writer_active, .acquire)) std.atomic.spinLoopHint();
        _ = @atomicRmw(u32, &readers, .Add, 1, .acq_rel);
        if (!@atomicLoad(bool, &writer_active, .acquire)) return;
        _ = @atomicRmw(u32, &readers, .Sub, 1, .acq_rel);
    }
}

pub fn readUnlock() void {
    _ = @atomicRmw(u32, &readers, .Sub, 1, .release);
}

/// Valid while the caller holds readLock.
pub fn bytes() []const u8 {
    return current[0..];
}

fn writeLock() void {
    while (true) {
        if (@atomicRmw(bool, &writer_active, .Xchg, true, .acquire)) {
            std.atomic.spinLoopHint();
            continue;
        }
        while (@atomicLoad(u32, &readers, .acquire) != 0) std.atomic.spinLoopHint();
        return;
    }
}

fn writeUnlock() void {
    @atomicStore(bool, &writer_active, false, .release);
}

fn number(text: []const u8, pos: *usize) ?u32 {
    var i = pos.*;
    if (i >= text.len or text[i] == '-') return null;
    var base: u32 = 10;
    if (text[i] == '0') {
        if (i + 2 < text.len and (text[i + 1] == 'x' or text[i + 1] == 'X') and std.ascii.isHex(text[i + 2])) {
            base = 16;
            i += 2;
        } else base = 8;
    }
    const begin = i;
    var value: u32 = 0;
    while (i < text.len) : (i += 1) {
        const digit = std.fmt.charToDigit(text[i], 16) catch break;
        if (digit >= base) break;
        value = std.math.mul(u32, value, base) catch return null;
        value = std.math.add(u32, value, digit) catch return null;
    }
    if (i == begin) return null;
    pos.* = i;
    return value;
}

/// replace is true at offset zero; a nonzero-offset write adds to the existing set, as bitmap_or does.
/// Empty writes do nothing; a newline-only write clears in replace mode. Errors leave the old set unchanged.
pub fn write(text: []const u8, replace: bool) i64 {
    if (text.len == 0) return 0;
    writeLock();
    defer writeUnlock();
    @memset(&staging, 0);
    var pos: usize = 0;
    while (pos < text.len and text[pos] == '\n') pos += 1;
    while (pos < text.len) {
        const first = number(text, &pos) orelse return -22;
        var last = first;
        if (pos < text.len and text[pos] == '-') {
            pos += 1;
            last = number(text, &pos) orelse return -22;
        }
        if (first > 65535 or last > 65535 or first > last) return -22;
        var bit = first;
        while (bit <= last) : (bit += 1) staging[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
        if (pos < text.len and text[pos] == ',') {
            pos += 1;
            continue;
        }
        while (pos < text.len and text[pos] == '\n') pos += 1;
        if (pos < text.len) return -22;
    }
    if (replace) {
        @memcpy(&current, &staging);
    } else {
        for (&current, staging) |*dst, src| dst.* |= src;
    }
    return @intCast(text.len);
}

/// Canonical comma-separated ranges, followed by a newline. Returns the bytes that fit in out.
pub fn format(out: []u8) usize {
    readLock();
    defer readUnlock();
    var used: usize = 0;
    var port: u32 = 0;
    while (port < 65536) {
        if (current[port / 8] & (@as(u8, 1) << @intCast(port % 8)) == 0) {
            port += 1;
            continue;
        }
        const first = port;
        while (port + 1 < 65536 and current[(port + 1) / 8] & (@as(u8, 1) << @intCast((port + 1) % 8)) != 0) port += 1;
        const last = port;
        port += 1;
        const prefix = if (used == 0) "" else ",";
        const text = if (first == last)
            std.fmt.bufPrint(out[used..], "{s}{d}", .{ prefix, first }) catch break
        else
            std.fmt.bufPrint(out[used..], "{s}{d}-{d}", .{ prefix, first, last }) catch break;
        used += text.len;
    }
    if (used < out.len) {
        out[used] = '\n';
        used += 1;
    }
    return used;
}

test "reserved-port writes are transactional and formatting is canonical" {
    try std.testing.expectEqual(@as(i64, 18), write("52000,52002-52004\n", true));
    readLock();
    try std.testing.expect(bytes()[6500] & 0x01 != 0);
    try std.testing.expect(bytes()[6500] & 0x02 == 0);
    try std.testing.expect(bytes()[6500] & 0x1c == 0x1c);
    readUnlock();
    var text: [128]u8 = undefined;
    var n = format(&text);
    try std.testing.expectEqualStrings("52000,52002-52004\n", text[0..n]);
    try std.testing.expectEqual(@as(i64, -22), write("52004-52002\n", true));
    try std.testing.expectEqual(@as(i64, -22), write("65536\n", true));
    n = format(&text);
    try std.testing.expectEqualStrings("52000,52002-52004\n", text[0..n]);
    try std.testing.expectEqual(@as(i64, 1), write("\n", true));
    n = format(&text);
    try std.testing.expectEqualStrings("\n", text[0..n]);
}
