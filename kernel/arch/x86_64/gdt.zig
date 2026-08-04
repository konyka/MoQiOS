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
///
/// MUST be `packed` (not `extern`): the hardware 64-bit TSS places RSP0 at byte
/// offset 4 (immediately after a single u32), i.e. the u64 stack pointers are
/// 4-byte — NOT 8-byte — aligned. An `extern struct` would insert 4 bytes of
/// padding after `reserved0` to 8-byte-align `rsp0`, shifting RSP0/RSP1/RSP2 and
/// all IST entries by 4 bytes. The CPU would then read a misaligned, garbage
/// (non-canonical) RSP0/IST on any user→kernel interrupt delivery and #SS →
/// #DF → triple fault. `packed` gives the exact byte layout the CPU expects.
const Tss = packed struct {
    reserved0: u32 = 0,
    /// Ring 0-2 stack pointers (RSP0 used for user→kernel transitions). Offset 4.
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved1: u64 = 0,
    /// Interrupt Stack Table pointers (IST1-7). IST1 at offset 0x24.
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved2: u64 = 0,
    reserved3: u16 = 0,
    /// I/O Map Base Address.
    iomap_base: u16 = 0,
};

/// Hardware-correct TSS size in bytes (104). @sizeOf of a packed struct may be
/// rounded up for the backing-integer alignment, so use this explicit constant
/// for the descriptor limit and IOPB base.
const TSS_HW_SIZE: u20 = 104;

/// I/O permission bitmap (IOPB) size: 1 bit per port × 65536 ports.
pub const IO_BITMAP_BYTES: usize = 8192;
/// IOPB storage appended to the TSS block, including the trailing 0xFF
/// sentinel byte the architecture requires past the bitmap end.
const IOPB_BYTES: usize = IO_BITMAP_BYTES + 1;
/// Bytes per per-CPU TSS block: 104-byte hardware TSS + IOPB, padded up so
/// every block start keeps the array's 16-byte alignment.
const TSS_BLOCK_BYTES: usize = (TSS_HW_SIZE + IOPB_BYTES + 15) & ~@as(usize, 15);

/// Per-CPU TSS + appended IOPB storage, carved manually out of a byte array.
///
/// The hardware iomap_base is a 16-bit OFFSET FROM THE TSS BASE — it can only
/// address the 64 KiB following the TSS, so a per-task bitmap allocated from
/// the PMM (HHDM) can never be referenced by pointer. Instead the IOPB lives
/// at a fixed offset (TSS_HW_SIZE) inside this block and the scheduler COPIES
/// the incoming task's bitmap into it on every context switch (loadIoBitmap),
/// mirroring Linux's tss_copy_io_bitmap. Default content is all-ones (every
/// port denied), so a task without an allocated bitmap — or any missed switch
/// hook — gets #GP on port I/O, never the previous task's permissions.
///
/// Why raw bytes: Zig packed structs cap at 65535 total bits (a TSS+8193B
/// block exceeds that), byte arrays are not allowed as packed fields, and a
/// packed Tss is not extern-compatible — no struct type can express this
/// layout, so the block is addressed by explicit offsets instead.

/// Pointer to a CPU's hardware TSS (first TSS_HW_SIZE bytes of its block).
/// The aligned stride (TSS_BLOCK_BYTES) keeps every block 16-byte aligned.
fn tssPtr(cpu_id: usize) *Tss {
    return @alignCast(@ptrCast(&tss_blocks[cpu_id]));
}

/// Byte pointer to a CPU's IOPB storage (offset TSS_HW_SIZE from TSS base).
fn iopbPtr(cpu_id: usize) [*]u8 {
    return @ptrCast(&tss_blocks[cpu_id][TSS_HW_SIZE]);
}

/// Total GDT entries: null, kcode, kdata, ucode, udata, ucode_dup, tss_low, tss_high = 8
const GDT_ENTRIES: usize = 8;
const MAX_CPUS: usize = @import("../cpu_capacity.zig").MAX_CPUS;

/// Per-CPU GDT and TSS arrays.
var gdt_entries: [MAX_CPUS][GDT_ENTRIES]GdtEntry = undefined;
var gdt_ptr: [MAX_CPUS]GdtPtr = undefined;
var tss_blocks: [MAX_CPUS][TSS_BLOCK_BYTES]u8 align(16) = undefined;

/// Dedicated Interrupt Stack Table (IST) stacks.
///
/// Critical exceptions (#DF, #SS, #GP, NMI, #MC) are routed (via the IDT `ist`
/// field) to one of these fixed, always-mapped stacks instead of TSS RSP0.
/// This guarantees that even if RSP0 is stale/bad — e.g. a fault while the CPU
/// is loading RSP0 on a user→kernel transition — exception delivery still has a
/// valid stack and the handler can run (and dump diagnostics / kill the task)
/// instead of escalating #SS→#DF→triple-fault.
///
const IST_STACK_SIZE: usize = 16 * 1024;
const NUM_IST: usize = 3; // IST1=#DF, IST2=#SS/#GP, IST3=NMI/#MC
const IST_PAGES_PER_CPU: usize = NUM_IST * IST_STACK_SIZE / 4096;

/// BSP-only storage used before PMM is available. Final IST storage is allocated
/// once, before AP startup, and is never moved after TSS pointers are published.
var bootstrap_ist: [NUM_IST][IST_STACK_SIZE]u8 align(16) = undefined;
var final_ist_base: ?[*]u8 = null;
var final_ist_cpu_count: usize = 0;

fn istStackTop(cpu_id: usize, ist_index: usize) ?u64 {
    if (cpu_id >= MAX_CPUS or ist_index >= NUM_IST) return null;
    if (final_ist_base) |base| {
        if (cpu_id >= final_ist_cpu_count) return null;
        const offset = (cpu_id * NUM_IST + ist_index + 1) * IST_STACK_SIZE;
        return @intFromPtr(base + offset);
    }
    if (cpu_id != 0) return null;
    return @intFromPtr(&bootstrap_ist[ist_index]) + IST_STACK_SIZE;
}

/// Allocate permanent IST backing for the selected CPUs and reload the BSP TSS
/// onto it. Returns the number of CPUs that have final IST storage.
pub fn initFinalIst(requested_cpu_count: usize) usize {
    if (final_ist_base != null) return final_ist_cpu_count;
    const pmm = @import("../../mm/pmm.zig");
    const hhdm = @import("../../mm/hhdm.zig");

    var count = @min(requested_cpu_count, MAX_CPUS);
    while (count > 0) : (count -= 1) {
        const pages = count * IST_PAGES_PER_CPU;
        const phys = pmm.allocContiguous(pages) orelse continue;
        final_ist_base = @ptrFromInt(hhdm.physToVirt(phys));
        final_ist_cpu_count = count;
        setupCpuGdt(0);
        return count;
    }
    return 0;
}

pub fn hasFinalIst(cpu_id: usize) bool {
    return final_ist_base != null and cpu_id < final_ist_cpu_count;
}

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
    if (cpu_id >= MAX_CPUS) return;
    // DIAGNOSTIC: warn if a non-canonical RSP0 is ever installed — a bad RSP0
    // makes every user→kernel interrupt delivery raise #SS → #DF → triple fault.
    const hi = rsp0 >> 47;
    if (hi != 0 and hi != 0x1FFFF) {
        const serial = @import("serial.zig");
        const fmt = @import("../../lib/fmt.zig");
        serial.writeString("[gdt] WARN non-canonical RSP0 cpu=");
        fmt.writeDecimal64(cpu_id);
        serial.writeString(" rsp0=0x");
        fmt.writeHex(rsp0);
        serial.writeString("\n");
    }
    tssPtr(cpu_id).rsp0 = rsp0;
}

/// Get the TSS pointer for a given CPU.
pub fn getTssPtr(cpu_id: usize) *Tss {
    if (cpu_id >= MAX_CPUS) return tssPtr(0);
    return tssPtr(cpu_id);
}

/// Copy a task's I/O permission bitmap into this CPU's TSS block
/// (`src == null` restores the deny-all default). The copy is mandatory on
/// every user-task context switch: iomap_base can only address memory within
/// 64 KiB of the TSS base, so the IOPB must physically live in the TSS block
/// and be refreshed per task. Every call site of setRsp0 that installs a
/// user task must be paired with this (proc/ioperm.zig loadForTask does
/// both), otherwise the previous task's port permissions would leak.
pub fn loadIoBitmap(cpu_id: usize, src: ?*const [IO_BITMAP_BYTES]u8) void {
    if (cpu_id >= MAX_CPUS) return;
    if (src) |s| {
        @memcpy(iopbPtr(cpu_id)[0..IO_BITMAP_BYTES], s);
    } else {
        @memset(iopbPtr(cpu_id)[0..IO_BITMAP_BYTES], 0xFF);
    }
}

/// Legacy compat: set RSP0 for CPU 0 (BSP).
pub fn setRsp0Bsp(rsp0: u64) void {
    setRsp0(0, rsp0);
}

/// Initialize GDT/TSS data for a specific CPU (without loading).
fn initCpuGdtData(cpu_id: usize) void {
    // Initialize TSS + appended IOPB: every port denied until a task with an
    // allocated bitmap is switched in (loadIoBitmap). iomap_base points at
    // the IOPB right past the 104-byte hardware TSS.
    @memset(&tss_blocks[cpu_id], 0);
    tssPtr(cpu_id).iomap_base = TSS_HW_SIZE;
    @memset(iopbPtr(cpu_id)[0..IOPB_BYTES], 0xFF);

    // Point IST1..IST3 at their dedicated stacks (stacks grow downward, so the
    // pointer is the TOP of each region). The IDT routes #DF→IST1, #SS/#GP→IST2,
    // NMI/#MC→IST3.
    tssPtr(cpu_id).ist1 = istStackTop(cpu_id, 0) orelse return;
    tssPtr(cpu_id).ist2 = istStackTop(cpu_id, 1) orelse return;
    tssPtr(cpu_id).ist3 = istStackTop(cpu_id, 2) orelse return;

    // Build GDT entries
    gdt_entries[cpu_id][0] = makeEntry(0, 0, 0, 0); // null
    gdt_entries[cpu_id][1] = makeEntry(0, 0xFFFFF, 0x9A, 0xA); // kernel code
    gdt_entries[cpu_id][2] = makeEntry(0, 0xFFFFF, 0x92, 0xC); // kernel data
    gdt_entries[cpu_id][3] = makeEntry(0, 0xFFFFF, 0xFA, 0xA); // user code
    gdt_entries[cpu_id][4] = makeEntry(0, 0xFFFFF, 0xF2, 0xC); // user data
    gdt_entries[cpu_id][5] = makeEntry(0, 0xFFFFF, 0xFA, 0xA); // user code dup (SYSRET)

    // TSS descriptor (two entries). Limit MUST be the hardware TSS size, not
    // @sizeOf(Tss) (which may be padded for the packed backing integer). The
    // limit spans the appended IOPB so port I/O is checked against the bitmap
    // instead of faulting on the descriptor limit.
    const tss_entries = makeTssEntry(@intFromPtr(tssPtr(cpu_id)), TSS_HW_SIZE + IOPB_BYTES - 1);
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
    if (cpu_id >= MAX_CPUS) return;
    setupCpuGdt(cpu_id);
}

/// Public wrapper for per-CPU GDT DATA initialization (used by SMP module).
/// Only initializes the GDT entries, TSS, and GDT pointer — does NOT load them.
/// The AP will load them itself via the trampoline.
pub fn setupCpuGdtPublic(cpu_id: u32) void {
    if (cpu_id >= MAX_CPUS) return;
    initCpuGdtData(cpu_id);
}

/// Get the virtual address of a CPU's GDT entries (for trampoline setup).
pub fn getGdtEntriesAddr(cpu_id: usize) u64 {
    if (cpu_id >= MAX_CPUS) return @intFromPtr(&gdt_entries[0]);
    return @intFromPtr(&gdt_entries[cpu_id]);
}
