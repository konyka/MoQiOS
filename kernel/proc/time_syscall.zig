/// kernel/proc/time_syscall.zig — Time-related syscall implementations
///
/// Extracted from syscall_entry.zig (v19.1).
const copy = @import("../mm/copy_from_user.zig");
const tsc = @import("../arch/x86_64/tsc.zig");
const bo = @import("../lib/byte_order.zig");

/// gettimeofday(tv_ptr) → 0 or -1
pub fn gettimeofday(tv_ptr: u64) i64 {
    if (tv_ptr == 0 or tv_ptr >= 0x0000_8000_0000_0000) return -1;

    const ns = tsc.nanos();
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

    const ns = tsc.nanos();
    const sec = ns / 1_000_000_000;
    const nsec = ns % 1_000_000_000;

    var ts_bytes: [16]u8 = undefined;
    bo.writeU64Le(ts_bytes[0..8], sec);
    const nsec_i64: i64 = @intCast(nsec);
    bo.writeI64Le(ts_bytes[8..16], nsec_i64);

    _ = copy.copyToUser(@ptrFromInt(tp_ptr), ts_bytes[0..16], 16);
    return 0;
}
