/// /dev/urandom-style high-performance PRNG using xoshiro256**.
/// Entropy seed via `arch.tsc.read` (SK-34) — portable across x86/riscv/aarch64.

const arch = @import("../arch/arch.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

// xoshiro256** state (256 bit)
var state: [4]u64 = undefined;
var initialized: bool = false;
var rng_lock: IrqSpinlock = .{};

pub fn init() void {
    // Idempotent: subsystem_boot / main / SK-34 may all call this.
    if (initialized) return;

    // Collect entropy seeds from the arch monotonic counter.
    state[0] = arch.tsc.read() ^ 0x9E3779B97F4A7C15;
    state[1] = arch.tsc.read() ^ 0x6A09E667F3BCC908;
    state[2] = arch.tsc.read() ^ 0xBB67AE8584CAA73B;
    state[3] = arch.tsc.read() ^ 0x3C6EF372FE94F82B;

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
/// flags = GRND_NONBLOCK / GRND_RANDOM / GRND_INSECURE; the generator is always ready and never blocks, so the three behave alike.
/// Argument rules (flags, zero length, pointer errors, per-call cap) are in random_policy.zig.
pub fn sysGetrandom(buf: u64, buflen: u64, flags: u64) i64 {
    const policy = @import("random_policy.zig");
    const len = switch (policy.check(buflen, flags)) {
        .ok => |n| n,
        .err => |e| return e,
    };
    if (!initialized) return -11; // EAGAIN
    if (len == 0) return 0;
    const copy = @import("../mm/copy_from_user.zig");
    const valid = buf != 0 and buf < 0x0000_8000_0000_0000 and copy.validateUserBufferWritable(buf, len);
    const ptr_rc = policy.pointerErrno(len, valid);
    if (ptr_rc != 0) return ptr_rc;

    // Fill the user buffer in kernel-stack chunks so a large request does not need a large kernel buffer.
    var kernel_buf: [256]u8 = undefined;
    var done: u64 = 0;
    while (done < len) {
        const chunk: u32 = @intCast(@min(len - done, kernel_buf.len));
        getRandomBytes(&kernel_buf, chunk);
        const copied = copy.copyToUser(@ptrFromInt(buf + done), kernel_buf[0..chunk], chunk);
        if (copied != chunk) return if (done > 0) @as(i64, @intCast(done)) else -14; // a short count once something was written
        done += chunk;
    }
    return @intCast(done);
}
