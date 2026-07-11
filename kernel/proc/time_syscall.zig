/// kernel/proc/time_syscall.zig — Time-related syscall implementations
///
/// Extracted from syscall_entry.zig (v19.1).
const copy = @import("../mm/copy_from_user.zig");
const tsc = @import("../arch/arch.zig").tsc;
const bo = @import("../lib/byte_order.zig");

/// Wall-clock offset from boot time (set by clock_settime).
/// wall_time_ns = tsc.nanos() + wall_clock_offset
var wall_clock_offset: i64 = 0;

/// Set wall-clock offset so that clock_gettime returns the desired time.
pub fn setWallClockOffset(offset_ns: i64) void {
    wall_clock_offset = offset_ns;
}

/// Get current wall-clock nanoseconds (boot time + offset).
pub fn wallClockNanos() u64 {
    const boot_ns: i64 = @intCast(tsc.nanos());
    const adjusted = boot_ns + wall_clock_offset;
    return @intCast(@max(adjusted, 0));
}

/// gettimeofday(tv_ptr) → 0 or -1
pub fn gettimeofday(tv_ptr: u64) i64 {
    if (tv_ptr == 0 or tv_ptr >= 0x0000_8000_0000_0000) return -1;

    const ns = wallClockNanos();
    const sec = ns / 1_000_000_000;
    const usec = (ns % 1_000_000_000) / 1000;

    var tv_bytes: [16]u8 = undefined;
    bo.writeU64Le(tv_bytes[0..8], sec);
    const usec_i64: i64 = @intCast(usec);
    bo.writeI64Le(tv_bytes[8..16], usec_i64);

    _ = copy.copyToUser(@ptrFromInt(tv_ptr), tv_bytes[0..16], 16);
    return 0;
}

/// clock_gettime(tp_ptr) → 0 or -1
pub fn clock_gettime(tp_ptr: u64) i64 {
    if (tp_ptr == 0 or tp_ptr >= 0x0000_8000_0000_0000) return -1;

    const ns = wallClockNanos();
    const sec = ns / 1_000_000_000;
    const nsec = ns % 1_000_000_000;

    var ts_bytes: [16]u8 = undefined;
    bo.writeU64Le(ts_bytes[0..8], sec);
    const nsec_i64: i64 = @intCast(nsec);
    bo.writeI64Le(ts_bytes[8..16], nsec_i64);

    _ = copy.copyToUser(@ptrFromInt(tp_ptr), ts_bytes[0..16], 16);
    return 0;
}
