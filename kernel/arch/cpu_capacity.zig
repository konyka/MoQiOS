const builtin = @import("builtin");

/// xAPIC and MADT type-0 entries represent APIC IDs 0..255. Other architecture
/// backends remain uniprocessor skeletons until they gain SMP bring-up support.
pub const MAX_CPUS: usize = if (builtin.cpu.arch == .x86_64) 256 else 1;
pub const CpuId = u8;
