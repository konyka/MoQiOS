//! Pure CR4 protection-bit selection from CPUID.(EAX=7,ECX=0).
//!
//! SMEP stops the kernel from executing user pages (ret2usr); UMIP turns
//! user-mode sgdt/sidt/sldt/smsw/str into #GP so descriptor-table addresses
//! do not leak. SMAP is detected but stays off until every user access goes
//! through stac/clac-bracketed copy routines.

pub const CPUID7_EBX_SMEP: u32 = 1 << 7;
pub const CPUID7_EBX_SMAP: u32 = 1 << 20;
pub const CPUID7_ECX_UMIP: u32 = 1 << 2;

pub const CR4_UMIP: u64 = 1 << 11;
pub const CR4_SMEP: u64 = 1 << 20;
pub const CR4_SMAP: u64 = 1 << 21;

pub const Features = struct { smep: bool, umip: bool, smap: bool };

pub fn features(max_basic_leaf: u32, leaf7_ebx: u32, leaf7_ecx: u32) Features {
    if (max_basic_leaf < 7) return .{ .smep = false, .umip = false, .smap = false };
    return .{
        .smep = leaf7_ebx & CPUID7_EBX_SMEP != 0,
        .umip = leaf7_ecx & CPUID7_ECX_UMIP != 0,
        .smap = leaf7_ebx & CPUID7_EBX_SMAP != 0,
    };
}

pub fn cr4Bits(f: Features) u64 {
    var bits: u64 = 0;
    if (f.smep) bits |= CR4_SMEP;
    if (f.umip) bits |= CR4_UMIP;
    return bits;
}
