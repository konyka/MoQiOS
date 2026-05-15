/// TSC (Time Stamp Counter) — frequency detection and timestamp utilities.
/// Detects TSC frequency via CPUID 0x15 (Intel) or falls back to QEMU default.

const serial = @import("serial.zig");
const klog = @import("../../klog.zig");

/// TSC frequency in MHz.
pub var tsc_freq_mhz: u64 = 0;

pub fn init() void {
    // Check if CPUID leaf 0x15 is supported (Intel TSC frequency info)
    const max_leaf = cpuid(0, 0).eax;
    if (max_leaf >= 0x15) {
        const result = cpuid(0x15, 0);
        const denominator = result.eax;
        const numerator = result.ebx;
        const core_freq = result.ecx;

        if (denominator != 0 and numerator != 0) {
            if (core_freq != 0) {
                // Known core crystal frequency
                tsc_freq_mhz = (@as(u64, numerator) * core_freq) / (@as(u64, denominator) * 1000000);
            } else {
                // ECX == 0: use 100 MHz default (common for QEMU/KVM)
                tsc_freq_mhz = 100;
            }
        }
    }

    // Fallback: assume 1000 MHz (QEMU default TSC)
    if (tsc_freq_mhz == 0) {
        tsc_freq_mhz = 1000;
        serial.writeString("[tsc] CPUID 0x15 not available, using 1000 MHz default\n");
    }

    serial.writeString("[tsc] Frequency: ");
    var buf: [20]u8 = undefined;
    serial.writeString(formatInt(&buf, tsc_freq_mhz));
    serial.writeString(" MHz\n");

    klog.log(.info, "TSC initialized");
}

/// Read the 64-bit TSC value.
pub fn read() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [low] "={eax}" (low), [high] "={edx}" (high),
    );
    return (@as(u64, high) << 32) | @as(u64, low);
}

/// Get approximate nanoseconds since boot.
pub fn nanos() u64 {
    if (tsc_freq_mhz == 0) return 0;
    return read() * 1000 / tsc_freq_mhz;
}

fn cpuid(leaf: u32, subleaf: u32) struct { eax: u32, ebx: u32, ecx: u32, edx: u32 } {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax), [ebx] "={ebx}" (ebx), [ecx] "={ecx}" (ecx), [edx] "={edx}" (edx)
        : [leaf] "{eax}" (leaf), [subleaf] "{ecx}" (subleaf),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

fn formatInt(buf: []u8, value: u64) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var i: usize = 0;
    var v = value;
    while (v > 0) : (v /= 10) {
        buf[i] = @intCast(v % 10 + '0');
        i += 1;
    }
    var j: usize = 0;
    while (j < i / 2) : (j += 1) {
        const tmp = buf[j];
        buf[j] = buf[i - 1 - j];
        buf[i - 1 - j] = tmp;
    }
    return buf[0..i];
}
