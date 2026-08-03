//! PCID (Process-Context Identifiers) — x86_64 glue.
//!
//! With CR4.PCIDE = 1, CR3 bits 11:0 select a process-context identifier and
//! CR3 bit 63 suppresses the TLB flush on a CR3 write. MoQiOS assigns one
//! PCID per user address space (kernel/mm/pcid_alloc.zig holds the pure
//! bookkeeping, host-tested) so that:
//!   - a syscall on the already-running space needs no CR3 write at all
//!     (prepareSyscallCpu used to flush the whole TLB on every syscall);
//!   - a context switch back to a recently-run space (A→B→A) can keep that
//!     space's TLB entries (bit 63 no-flush write).
//!
//! Safety model (correctness over performance):
//!   - PCID 0 = kernel PML4 / unregistered spaces → legacy flushing writes.
//!   - User pages are never mapped global (asserted in paging.zig), so no
//!     user translation can leak across PCIDs.
//!   - Each PCID has an invalidation generation, bumped on unregister (PCID
//!     reuse) and on every targeted TLB shootdown. The no-flush fast path is
//!     taken only when the generation recorded when this CPU left the space
//!     still matches the live one; otherwise the CR3 write flushes.
//!   - switchCr3 re-checks the generation after publishing current_cr3 to
//!     close the race with a concurrent shootdown that excluded this CPU
//!     from its IPI mask because it still saw the old current_cr3.
//!   - If the CPU lacks PCID (or pcid_enable is false), `active` stays false
//!     and every CR3 write is exactly the legacy flushing write from before.
//!
//! Build-time kill switch: set `pcid_enable` to false to compile the feature
//! off regardless of CPU support.

const serial = @import("serial.zig");
const syscall_entry = @import("syscall_entry.zig");
const core_mod = @import("../../mm/pcid_alloc.zig");
const IrqSpinlock = @import("../../sync/irq_spinlock.zig").IrqSpinlock;

pub const PcidCore = core_mod.PcidCore;
pub const composeCr3 = core_mod.composeCr3;

/// Compile-time enable. When false, init() reports "disabled" and `active`
/// never becomes true — all CR3 writes keep legacy semantics.
pub const pcid_enable: bool = true;

/// Runtime state: true after init() found CPUID PCID support and set
/// CR4.PCIDE on the BSP (APs follow in initThisCpu during SMP bring-up).
pub var active: bool = false;

/// INVPCID availability (CPUID leaf 7 EBX bit 10) — a separate feature from
/// PCID (bit 17). The generation scheme alone keeps PCID reuse safe without
/// it; INVPCID is only a local-CPU hygiene flush at unregister time.
var invpcid_supported: bool = false;

var core: PcidCore = .{};
var core_lock: IrqSpinlock = .{};

const MAX_CPUS = syscall_entry.MAX_CPUS;

/// Per-CPU context-switch state, indexed by logical CPU id. `cur_pcid` is
/// what this CPU's CR3 currently selects (0 = kernel / unregistered);
/// `prev_*` is the single-slot record of the last user space this CPU
/// switched away from, used by the A→B→A no-flush fast path.
var cur_pcid: [MAX_CPUS]u16 = [_]u16{0} ** MAX_CPUS;
var prev_pcid: [MAX_CPUS]u16 = [_]u16{0} ** MAX_CPUS;
var prev_gen: [MAX_CPUS]u64 = [_]u64{0} ** MAX_CPUS;

fn cpuid(leaf: u32, subleaf: u32) struct { eax: u32, ebx: u32, ecx: u32, edx: u32 } {
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
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

/// Set CR4.PCIDE (bit 17) on the current CPU.
fn enableOnThisCpu() void {
    asm volatile (
        \\movq %%cr4, %%rax
        \\bts $17, %%rax
        \\movq %%rax, %%cr4
        ::: .{ .rax = true, .memory = true });
}

/// Boot probe (BSP, from kernel main after paging.init). Prints the boot
/// marker and turns the feature on when the CPU supports it.
pub fn init() void {
    if (!pcid_enable) {
        serial.writeString("[PCID] disabled at build time\n");
        return;
    }
    if (cpuid(0, 0).eax >= 7) {
        const features = cpuid(7, 0).ebx;
        if ((features & (1 << 17)) != 0) {
            invpcid_supported = (features & (1 << 10)) != 0;
            enableOnThisCpu();
            active = true;
            serial.writeString("[PCID] enabled (12-bit)\n");
            return;
        }
    }
    serial.writeString("[PCID] not supported\n");
}

/// AP bring-up hook (smp.zig apMain): match the BSP's CR4.PCIDE state.
pub fn initThisCpu() void {
    if (active) enableOnThisCpu();
}

/// INVPCID type 1 (single-context invalidation): drop all TLB entries for
/// `pcid` on THIS CPU. Remote CPUs are covered by the generation bump —
/// their next switch into a space with this PCID flushes instead.
fn invpcidSingleContext(pcid: u16) void {
    const Desc = extern struct { pcid: u64, addr: u64 };
    const desc: Desc = .{ .pcid = pcid, .addr = 0 };
    asm volatile ("invpcid (%[d]), %[t]"
        :
        : [d] "r" (&desc),
          [t] "r" (@as(u64, 1)),
        : .{ .memory = true });
}

inline fn rawWriteCr3(value: u64) void {
    asm volatile ("movq %[v], %%rax\n\tmovq %%rax, %%cr3"
        :
        : [v] "r" (value),
        : .{ .rax = true, .memory = true });
}

/// Register a new user address space (user_space.createUserSpace). Failure
/// to obtain a PCID is fine: the space runs as PCID 0 / legacy flush.
pub fn registerSpace(pml4_phys: u64) void {
    if (!active) return;
    const flags = core_lock.acquire();
    _ = core.registerSpace(pml4_phys);
    core_lock.release(flags);
}

/// Drop a user address space (user_space.destroyUserSpace). Frees the PCID,
/// bumps its generation (poisons every CPU's cached no-flush record) and —
/// when the CPU has INVPCID — drops this CPU's stale entries for it.
pub fn unregisterSpace(pml4_phys: u64) void {
    if (!active) return;
    const flags = core_lock.acquire();
    const freed = core.unregisterSpace(pml4_phys);
    core_lock.release(flags);
    if (freed) |pcid| {
        if (invpcid_supported) invpcidSingleContext(pcid);
    }
}

/// TLB shootdown hook (tlb.shootdownRange, initiator side, before the IPI
/// mask is computed): bump the target space's PCID generation so CPUs that
/// are excluded from the mask (they run another CR3) cannot later re-enter
/// this space with stale entries via the no-flush fast path.
pub fn noteShootdown(target_cr3: u64) void {
    if (!active) return;
    const flags = core_lock.acquire();
    core.noteShootdown(target_cr3);
    core_lock.release(flags);
}

/// Record the space this CPU is leaving in the single-slot prev cache.
inline fn recordPrev(cpu: usize) void {
    const leaving = cur_pcid[cpu];
    if (leaving == 0) return;
    prev_pcid[cpu] = leaving;
    prev_gen[cpu] = core.generation(leaving);
}

/// The single CR3 write path for the whole kernel. Replaces the inline
/// `mov %[cr3], %%cr3` asm + noteCr3Switch pairs in the scheduler, execve
/// and prepareSyscallCpu. With PCID inactive this is byte-for-byte the old
/// behaviour (plain write, full flush).
pub fn switchCr3(pml4_phys: u64) void {
    const pc = syscall_entry.getPerCpu();

    if (!active) {
        rawWriteCr3(pml4_phys);
        pc.current_cr3 = pml4_phys;
        return;
    }

    const cpu: usize = pc.cpu_id;

    const flags = core_lock.acquire();
    const target_pcid: u16 = core.pcidFor(pml4_phys) orelse 0;
    core_lock.release(flags);

    if (target_pcid == 0) {
        // Kernel PML4 or an unregistered space: legacy semantics — a
        // flushing write selecting PCID 0.
        recordPrev(cpu);
        rawWriteCr3(composeCr3(pml4_phys, 0, false));
        cur_pcid[cpu] = 0;
        @atomicStore(u64, &pc.current_cr3, pml4_phys, .release);
        return;
    }

    const g1 = core.generation(target_pcid);
    const action = core_mod.decideSwitch(
        cur_pcid[cpu],
        pc.current_cr3,
        prev_pcid[cpu],
        prev_gen[cpu],
        pml4_phys,
        target_pcid,
        g1,
    );
    if (action == .skip) return;

    recordPrev(cpu);
    rawWriteCr3(composeCr3(pml4_phys, target_pcid, action == .no_flush));
    // Publish BEFORE the re-check below: a shootdown that bumps the
    // generation after this store either sees the new current_cr3 (and IPIs
    // us) or is caught by the generation re-read.
    @atomicStore(u64, &pc.current_cr3, pml4_phys, .release);
    cur_pcid[cpu] = target_pcid;

    // Race closure: a shootdown that bumped the generation between g1 and
    // the store above computed its IPI mask from our stale current_cr3 and
    // excluded us. Flush the entries we may have just kept.
    if (core.generation(target_pcid) != g1) {
        rawWriteCr3(composeCr3(pml4_phys, target_pcid, false));
    }
}
