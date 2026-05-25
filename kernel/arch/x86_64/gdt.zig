/// Global Descriptor Table — kernel + user code/data segments + TSS.
///
/// Layout (must satisfy SYSCALL/SYSRET selector arithmetic):
///   SYSRET loads CS = STAR[48:63] + 16, SS = STAR[48:63] + 8
///   STAR[48:63] = 0x1B → SYSRET CS = 0x2B, SYSRET SS = 0x23
///
/// GDT entries:
///   0x00: null
///   0x08: kernel code (64-bit, ring0)
///   0x10: kernel data (ring0)
///   0x18: user code (64-bit, ring3) — used by iretq to user
///   0x20: user data (ring3) — used by iretq to user + SYSRET SS
///   0x28: user code (64-bit, ring3) — duplicate for SYSRET CS (0x1B+16=0x2B)
///   0x30: TSS low (uses two entries)
///   0x38: TSS high

pub const KERNEL_CS: u16 = 0x08;
pub const KERNEL_DS: u16 = 0x10;
pub const USER_CS: u16 = 0x1B; // GDT entry 3 | RPL 3 (iretq to user)
pub const USER_DS: u16 = 0x23; // GDT entry 4 | RPL 3
pub const USER_CS_SYSRET: u16 = 0x2B; // GDT entry 5 | RPL 3 (SYSRET CS = 0x1B+16)
pub const TSS_SEL: u16 = 0x30; // GDT entry 6

const GdtEntry = packed struct {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: u8,
    flags_limit_high: u8,
    base_high: u8,
};

/// 64-bit TSS descriptor uses two consecutive GDT entries.
const TssEntry = packed struct {
    low: GdtEntry,
    base_high32: u32,
    reserved: u32,
};

const GdtPtr = packed struct {
    limit: u16,
    base: u64,
};

/// Task State Segment — used for IST and kernel stack switching on syscall/interrupt.
const Tss = extern struct {
    reserved0: u32,
    /// Ring 0-2 stack pointers (RSP0 used for user→kernel transitions).
    rsp0: u64,
    rsp1: u64,
    rsp2: u64,
    reserved1: u64,
    /// Interrupt Stack Table pointers (IST1-7).
    ist: [7]u64,
    reserved2: u64,
    reserved3: u16,
    /// I/O Map Base Address.
    iomap_base: u16,
};

/// Total GDT entries: null, kcode, kdata, ucode, udata, ucode_dup, tss_low, tss_high = 8
const GDT_ENTRIES: usize = 8;
const MAX_CPUS: usize = 4;

/// Per-CPU GDT and TSS arrays.
var gdt_entries: [MAX_CPUS][GDT_ENTRIES]GdtEntry = undefined;
var gdt_ptr: [MAX_CPUS]GdtPtr = undefined;
var tss: [MAX_CPUS]Tss = undefined;

fn makeEntry(base: u32, limit: u20, access: u8, flags: u4) GdtEntry {
    return .{
        .limit_low = @truncate(limit),
        .base_low = @truncate(base),
        .base_mid = @truncate(base >> 16),
        .access = access,
        .flags_limit_high = (@as(u8, @intCast(flags)) << 4) | @as(u8, @truncate(limit >> 16)),
        .base_high = @truncate(base >> 24),
    };
}

/// Make a 64-bit TSS descriptor (occupies two GDT entries).
fn makeTssEntry(tss_addr: u64, limit: u20) [2]GdtEntry {
    const access: u8 = 0x89; // Present, DPL=0, 64-bit TSS
    return .{
        GdtEntry{
            .limit_low = @truncate(limit),
            .base_low = @truncate(tss_addr),
            .base_mid = @truncate(tss_addr >> 16),
            .access = access,
            .flags_limit_high = (@as(u8, @intCast(@as(u4, 0x0))) << 4) | @as(u8, @truncate(limit >> 16)),
            .base_high = @truncate(tss_addr >> 24),
        },
        GdtEntry{
            .limit_low = @as(u16, @truncate(tss_addr >> 32)),
            .base_low = @as(u16, @truncate(tss_addr >> 48)),
            .base_mid = 0,
            .access = 0,
            .flags_limit_high = 0,
            .base_high = 0,
        },
    };
}

/// Set the RSP0 value in the TSS for a given CPU.
pub fn setRsp0(cpu_id: usize, rsp0: u64) void {
    tss[cpu_id].rsp0 = rsp0;
}

/// Get the TSS pointer for a given CPU.
pub fn getTssPtr(cpu_id: usize) *Tss {
    return &tss[cpu_id];
}

/// Legacy compat: set RSP0 for CPU 0 (BSP).
pub fn setRsp0Bsp(rsp0: u64) void {
    setRsp0(0, rsp0);
}

/// Initialize GDT/TSS data for a specific CPU (without loading).
fn initCpuGdtData(cpu_id: usize) void {
    // Initialize TSS
    @memset(@as([*]u8, @ptrCast(&tss[cpu_id]))[0..@sizeOf(Tss)], 0);
    tss[cpu_id].iomap_base = @sizeOf(Tss);

    // Build GDT entries
    gdt_entries[cpu_id][0] = makeEntry(0, 0, 0, 0); // null
    gdt_entries[cpu_id][1] = makeEntry(0, 0xFFFFF, 0x9A, 0xA); // kernel code
    gdt_entries[cpu_id][2] = makeEntry(0, 0xFFFFF, 0x92, 0xC); // kernel data
    gdt_entries[cpu_id][3] = makeEntry(0, 0xFFFFF, 0xFA, 0xA); // user code
    gdt_entries[cpu_id][4] = makeEntry(0, 0xFFFFF, 0xF2, 0xC); // user data
    gdt_entries[cpu_id][5] = makeEntry(0, 0xFFFFF, 0xFA, 0xA); // user code dup (SYSRET)

    // TSS descriptor (two entries)
    const tss_entries = makeTssEntry(@intFromPtr(&tss[cpu_id]), @as(u20, @intCast(@sizeOf(Tss) - 1)));
    gdt_entries[cpu_id][6] = tss_entries[0];
    gdt_entries[cpu_id][7] = tss_entries[1];

    gdt_ptr[cpu_id] = .{
        .limit = @sizeOf(@TypeOf(gdt_entries[cpu_id])) - 1,
        .base = @intFromPtr(&gdt_entries[cpu_id]),
    };
}

/// Load GDT and TSS for the calling CPU.
fn loadCpuGdt(cpu_id: usize) void {
    // Load GDT
    asm volatile (
        \\lgdt (%[gdt_ptr])
        \\pushq $0x08
        \\leaq 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        \\movw $0x10, %%ax
        \\movw %%ax, %%ds
        \\movw %%ax, %%es
        \\movw %%ax, %%fs
        \\movw %%ax, %%gs
        \\movw %%ax, %%ss
        :
        : [gdt_ptr] "r" (&gdt_ptr[cpu_id]),
    );

    // Load TSS
    asm volatile (
        \\ltr %[sel]
        :
        : [sel] "r" (TSS_SEL),
    );
}

/// Set up GDT and TSS for a specific CPU (init data + load).
fn setupCpuGdt(cpu_id: usize) void {
    initCpuGdtData(cpu_id);
    loadCpuGdt(cpu_id);
}

/// Initialize GDT/TSS for BSP (CPU 0).
pub fn init() void {
    setupCpuGdt(0);
}

/// Initialize GDT/TSS for an AP.
pub fn initAp(cpu_id: usize) void {
    setupCpuGdt(cpu_id);
}

/// Public wrapper for per-CPU GDT DATA initialization (used by SMP module).
/// Only initializes the GDT entries, TSS, and GDT pointer — does NOT load them.
/// The AP will load them itself via the trampoline.
pub fn setupCpuGdtPublic(cpu_id: u32) void {
    initCpuGdtData(cpu_id);
}

/// Get the virtual address of a CPU's GDT entries (for trampoline setup).
pub fn getGdtEntriesAddr(cpu_id: usize) u64 {
    return @intFromPtr(&gdt_entries[cpu_id]);
}
