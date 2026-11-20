/// The kernel's random generator (/dev/random, /dev/urandom, getrandom, and the network's ids and secrets): ChaCha8 with fast key
/// erasure (std.Random.ChaCha, the construction Linux's crng uses with ChaCha20), so earlier output cannot be recovered from the
/// state and output cannot be predicted without the key.
///
/// Seeding: 256 timer samples with the jitter between them hashed through BLAKE2s, plus RDSEED / RDRAND words on an x86 CPU that has
/// them (random_seed_policy decides which instructions CPUID allows). Writes to /dev/random mix into the key (addEntropy).

const std = @import("std");
const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;

var rng: std.Random.ChaCha = undefined;
var initialized: bool = false;
var rng_lock: IrqSpinlock = .{};

/// One 64-bit word from RDSEED (preferred) or RDRAND, or null when the CPU has neither or it ran dry.
fn hwWord() ?u64 {
    if (comptime builtin.cpu.arch != .x86_64) return null;
    const policy = @import("random_seed_policy.zig");
    const leaf1 = cpuid(1, 0);
    const leaf7 = cpuid(7, 0);
    const src = policy.hwSource(leaf1.ecx, leaf7.ebx);
    var tries: u32 = 0;
    while (tries < 10) : (tries += 1) {
        var v: u64 = 0;
        var ok: u8 = 0;
        switch (src) {
            .none => return null,
            .rdseed => asm volatile ("rdseed %[v]; setc %[ok]"
                : [v] "=r" (v),
                  [ok] "=r" (ok),
                :
                : .{ .cc = true }),
            .rdrand => asm volatile ("rdrand %[v]; setc %[ok]"
                : [v] "=r" (v),
                  [ok] "=r" (ok),
                :
                : .{ .cc = true }),
        }
        if (ok != 0) return v;
    }
    return null;
}

fn cpuid(leaf: u32, subleaf: u32) struct { ecx: u32, ebx: u32 } {
    if (comptime builtin.cpu.arch != .x86_64) return .{ .ecx = 0, .ebx = 0 };
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );
    return .{ .ecx = ecx, .ebx = ebx };
}

var init_lock: IrqSpinlock = .{};

pub fn init() void {
    // Idempotent: subsystem_boot / main / SK-34 may all call this, and a first getRandomBytes on another CPU may race it.
    if (@atomicLoad(bool, &initialized, .acquire)) return;
    const held = init_lock.acquire();
    defer init_lock.release(held);
    if (initialized) return;
    var h = std.crypto.hash.blake2.Blake2s256.init(.{});
    // Timer samples: the low bits of back-to-back reads vary with caches, interrupts and the host, which is what gives a seed here.
    var prev: u64 = arch.tsc.read();
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        var spin: u32 = 0;
        while (spin < (prev & 63)) : (spin += 1) std.mem.doNotOptimizeAway(spin);
        const now = arch.tsc.read();
        const sample = [2]u64{ now, now -% prev };
        h.update(std.mem.asBytes(&sample));
        prev = now;
    }
    var k: u32 = 0;
    while (k < 8) : (k += 1) if (hwWord()) |w| h.update(std.mem.asBytes(&w));
    var seed: [std.Random.ChaCha.secret_seed_length]u8 = undefined;
    h.final(&seed);
    rng = std.Random.ChaCha.init(seed);
    @memset(&seed, 0);
    @atomicStore(bool, &initialized, true, .release);
}

/// Fill a kernel buffer with random bytes.
pub fn getRandomBytes(buf: [*]u8, len: u32) void {
    if (!@atomicLoad(bool, &initialized, .acquire)) init();
    const state_held = rng_lock.acquire();
    defer rng_lock.release(state_held);
    rng.fill(buf[0..len]);
}

/// Mix caller-supplied bytes into the generator (a write to /dev/random or /dev/urandom: Linux mix_pool_bytes). The key is replaced
/// by itself XOR ChaCha of the bytes and the buffer refilled, so the stream after the write depends on what was written.
pub fn mixBytes(bytes: []const u8) void {
    const state_held = rng_lock.acquire();
    defer rng_lock.release(state_held);
    if (initialized) rng.addEntropy(bytes);
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
