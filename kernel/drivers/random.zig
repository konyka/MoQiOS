/// /dev/urandom-style high-performance PRNG using xoshiro256**.

const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

// xoshiro256** state (256 bit)
var state: [4]u64 = undefined;
var initialized: bool = false;
var rng_lock: IrqSpinlock = .{};

pub fn init() void {
    // Collect entropy seeds from rdtsc
    state[0] = readTsc() ^ 0x9E3779B97F4A7C15;
    state[1] = readTsc() ^ 0x6A09E667F3BCC908;
    state[2] = readTsc() ^ 0xBB67AE8584CAA73B;
    state[3] = readTsc() ^ 0x3C6EF372FE94F82B;

    // Warm-up: skip first 16 outputs
    for (0..16) |_| {
        _ = next();
    }
    initialized = true;
}

fn next() u64 {
    // xoshiro256** algorithm
    const val = state[1] *% 5;
    const result = ((val << 7) | (val >> 57)) *% 9;
    const t = state[1] << 17;
    state[2] ^= state[0];
    state[3] ^= state[1];
    state[1] ^= state[2];
    state[0] ^= state[3];
    state[2] ^= t;
    state[3] = (state[3] << 45) | (state[3] >> 19);
    return result;
}

fn readTsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

/// Fill a kernel buffer with random bytes.
pub fn getRandomBytes(buf: [*]u8, len: u32) void {
    const state_held = rng_lock.acquire();
    defer rng_lock.release(state_held);

    var i: u32 = 0;
    while (i < len) {
        const val = next();
        const remaining = len - i;
        const chunk = if (remaining >= 8) 8 else remaining;
        const bytes = @as(*const [8]u8, @ptrCast(&val));
        for (0..chunk) |j| {
            buf[i] = bytes[j];
            i += 1;
        }
    }
}

/// getrandom system call (#318).
/// buf  = user-space buffer pointer
/// buflen = number of bytes requested
/// flags = GRND_RANDOM / GRND_NONBLOCK (ignored)
pub fn sysGetrandom(buf: u64, buflen: u64, flags: u64) i64 {
    _ = flags; // GRND_RANDOM/GRND_NONBLOCK ignored (no blocking entropy pool)
    if (buflen > 256) return -22; // EINVAL, limit to 256 bytes per call
    if (!initialized) return -11; // EAGAIN
    if (buf == 0 or buf >= 0x0000_8000_0000_0000) return -22; // EINVAL

    const copy = @import("../mm/copy_from_user.zig");
    var kernel_buf: [256]u8 = undefined;
    const count: u32 = @intCast(buflen);
    getRandomBytes(&kernel_buf, count);

    const copied = copy.copyToUser(@ptrFromInt(buf), kernel_buf[0..count], count);
    if (copied != count) return -14; // EFAULT
    return @intCast(count);
}
