//! CR4 protection bits (SMEP, UMIP) on every CPU.
//!
//! The BSP probes CPUID once in `init` (kernel main, before the first user
//! address space); each AP mirrors the result in `initThisCpu` during SMP
//! bring-up so no CPU runs user code with weaker protection than the BSP.

const serial = @import("serial.zig");
const policy = @import("cpu_protect_policy.zig");

var cr4_bits: u64 = 0;

const Cpuid = struct { eax: u32, ebx: u32, ecx: u32 };

fn cpuid(leaf: u32, subleaf: u32) Cpuid {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
        : .{ .edx = true });
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx };
}

fn setCr4Bits(bits: u64) void {
    if (bits == 0) return;
    asm volatile (
        \\movq %%cr4, %%rax
        \\orq %[bits], %%rax
        \\movq %%rax, %%cr4
        :
        : [bits] "r" (bits),
        : .{ .rax = true, .memory = true });
}

pub fn init() void {
    const max_leaf = cpuid(0, 0).eax;
    const leaf7: Cpuid = if (max_leaf >= 7) cpuid(7, 0) else .{ .eax = 0, .ebx = 0, .ecx = 0 };
    const f = policy.features(max_leaf, leaf7.ebx, leaf7.ecx);
    cr4_bits = policy.cr4Bits(f);
    setCr4Bits(cr4_bits);
    serial.writeString(if (f.smep) "[CPU] SMEP on" else "[CPU] SMEP off");
    serial.writeString(if (f.umip) " UMIP on\n" else " UMIP off\n");
}

pub fn initThisCpu() void {
    setCr4Bits(cr4_bits);
}
