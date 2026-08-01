//! TLB range-shootdown (Task #3 / M8-6).
//!
//! Replaces the coarse CR3-reload IPI fallback with a per-page `invlpg` flush
//! coordinated through a single global shootdown request slot. Multiple
//! concurrent callers serialise on `shootdown_lock`; readers (the IPI handler
//! on remote CPUs) consume the slot via release/acquire-ordered atomics.
//!
//! Algorithm (initiator):
//!   1. Flush the affected pages on the local CPU.
//!   2. If SMP is not online (cpu_count <= 1) return — nobody else cares.
//!   3. Acquire `shootdown_lock` (a custom lock that spins with IRQs OFF but
//!      manually services any in-flight broadcast — see `TlbLock` and
//!      `servicePendingShootdown`). This is critical both to avoid the
//!      classic cross-IPI deadlock and to stay safe in interrupt-disabled
//!      contexts (page-fault handler COW/swap paths), where an `sti` window
//!      would corrupt the interrupted frame.
//!   4. Publish (addr_start, page_count) in the global slot and seed the
//!      `completion` counter with the number of remote CPUs to acknowledge.
//!   5. Broadcast `TLB_SHOOTDOWN_VECTOR` IPI to all-but-self via the LAPIC.
//!   6. Spin (with `pause`) on `completion` until it reaches zero.
//!   7. Clear the `active` flag and release the lock.
//!
//! Algorithm (IPI handler on remote CPU):
//!   1. EOI the LAPIC.
//!   2. Read (addr_start, page_count) from the global slot.
//!   3. Flush locally (range invlpg, or CR3 reload if oversized).
//!   4. Atomically decrement `completion`.
//!
//! Threshold: a long invlpg loop is more expensive than a full CR3 reload
//! once the page count exceeds ~32 (rough TLB-fill break-even on modern
//! cores). Beyond that threshold the local flush degrades to a CR3 reload
//! which invalidates all non-global entries — user pages are never global so
//! this still produces the right semantics for shared-VM mprotect/munmap.
//!
//! IMPORTANT: the IPI handler must NOT acquire any lock that an interrupted
//! task could be holding (page table lock, scheduler lock, etc). It only
//! touches the shootdown slot via atomics, so it is reentrancy-safe.

const lapic = @import("lapic.zig");
const smp = @import("../../smp.zig");
const syscall_entry = @import("syscall_entry.zig");
const serial = @import("serial.zig");

/// Local-flush fallback threshold. More pages than this on a single
/// shootdown → just reload CR3 (flushes all non-global TLB entries).
pub const FLUSH_THRESHOLD: u16 = 32;
const SHOOTDOWN_WAIT_POLL_LIMIT: u32 = 5_000_000;

/// Global shootdown request slot. Only one shootdown can be in flight at a
/// time, serialised by `shootdown_lock`. All fields are accessed atomically.
pub const TlbShootdownReq = extern struct {
    addr_start: u64 = 0,
    page_count: u32 = 0, // u32 (not u16) keeps the slot naturally 8-byte aligned
    /// Number of remote CPUs still owing an acknowledgement. Hits zero when
    /// every targeted CPU has flushed its TLB.
    completion: u32 = 0,
    /// Non-zero while a request is in flight — read by the IPI handler to
    /// decide whether the slot is stale (best-effort; the handler is always
    /// invoked in response to our own IPI so this is mainly for diagnostics).
    active: u32 = 0,
    generation: u32 = 0,
};

pub var shootdown_req: TlbShootdownReq = .{};
var acknowledged_generation: [syscall_entry.MAX_CPUS]u32 = [_]u32{0} ** syscall_entry.MAX_CPUS;

fn failShootdown(reason: []const u8) noreturn {
    serial.writeString("[TLB] FATAL: shootdown ");
    serial.writeString(reason);
    serial.writeString("; halting to preserve mapping safety\n");
    asm volatile ("cli");
    while (true) asm volatile ("hlt");
}

/// Cross-CPU lock used to serialise shootdown initiators. Unlike
/// `IrqSpinlock`, this lock services pending shootdown broadcasts manually
/// while spinning (see `servicePendingShootdown`) instead of re-enabling
/// IRQs. This keeps the lock usable from interrupt-disabled contexts such as
/// the page-fault handler (COW/swap paths), where an `sti` window would let a
/// timer tick nest inside the fault frame and corrupt the iretq state.
pub const TlbLock = struct {
    locked: u32 = 0,

    pub fn acquire(self: *TlbLock) u64 {
        // Snapshot caller's IF state so we can restore on release.
        var rflags: u64 = undefined;
        asm volatile (
            \\pushfq
            \\pop %[f]
            : [f] "=r" (rflags),
        );

        while (true) {
            // Disable IRQs to take the lock atomically with respect to a
            // local-CPU interrupt that might recursively try to shoot down.
            asm volatile ("cli");
            if (@atomicRmw(u32, &self.locked, .Xchg, 1, .acquire) == 0) {
                return rflags;
            }
            // Failed: spin with IRQs OFF (fault-handler safe), servicing any
            // in-flight broadcast ourselves so the current owner can complete
            // without needing our IF=1.
            while (@atomicLoad(u32, &self.locked, .monotonic) != 0) {
                servicePendingShootdown();
                asm volatile ("pause");
            }
        }
    }

    pub fn release(self: *TlbLock, saved_rflags: u64) void {
        @atomicStore(u32, &self.locked, 0, .release);
        asm volatile (
            \\push %[f]
            \\popfq
            :
            : [f] "r" (saved_rflags),
        );
    }
};

pub var shootdown_lock: TlbLock = .{};

/// Invalidate a single page's TLB entry on the local CPU.
pub inline fn invlpg(addr: u64) void {
    asm volatile ("invlpg (%[a])"
        :
        : [a] "r" (addr),
        : .{ .memory = true });
}

/// Reload CR3 to flush all non-global TLB entries on the local CPU.
pub inline fn reloadCr3() void {
    asm volatile (
        \\movq %%cr3, %%rax
        \\movq %%rax, %%cr3
        ::: .{ .rax = true, .memory = true });
}

/// Flush a range on the local CPU. Uses a per-page invlpg loop up to
/// `FLUSH_THRESHOLD`, then falls back to CR3 reload.
pub fn flushLocal(addr_start: u64, page_count: u32) void {
    if (page_count == 0) return;
    if (page_count > FLUSH_THRESHOLD) {
        reloadCr3();
        return;
    }
    var i: u32 = 0;
    while (i < page_count) : (i += 1) {
        invlpg(addr_start + @as(u64, i) * 4096);
    }
}

/// Inline EOI to avoid pulling lapic helpers into the IPI fast path. The
/// LAPIC EOI register sits at offset 0xB0 from the MMIO base.
inline fn eoiInline() void {
    const base = lapic.getBase();
    if (base == 0) return; // LAPIC not yet mapped — nothing to ack
    const reg: *volatile u32 = @ptrFromInt(base + 0xB0);
    reg.* = 0;
}

/// Service an in-flight shootdown broadcast for this CPU without taking an
/// actual IPI. Used by the IPI handler and by CPUs spinning on
/// `shootdown_lock` with IRQs disabled, so the initiator never has to wait
/// for a waiter to re-enable interrupts. Idempotent per generation via
/// `acknowledged_generation`.
fn servicePendingShootdown() void {
    if (@atomicLoad(u32, &shootdown_req.active, .acquire) == 0) return;
    const generation = @atomicLoad(u32, &shootdown_req.generation, .acquire);
    const cpu_id = syscall_entry.getPerCpu().cpu_id;
    if (cpu_id >= syscall_entry.MAX_CPUS) return;
    if (@atomicRmw(u32, &acknowledged_generation[cpu_id], .Xchg, generation, .acq_rel) == generation) return;

    // The active acquire load publishes the range before this CPU flushes it.
    const addr = @atomicLoad(u64, &shootdown_req.addr_start, .acquire);
    const cnt = @atomicLoad(u32, &shootdown_req.page_count, .acquire);

    flushLocal(addr, cnt);

    // Acknowledge only an active, non-zero completion count. This prevents a
    // duplicate or stale vector from wrapping the counter to UINT_MAX.
    while (true) {
        const completion = @atomicLoad(u32, &shootdown_req.completion, .acquire);
        if (completion == 0) break;
        if (@cmpxchgWeak(u32, &shootdown_req.completion, completion, completion - 1, .acq_rel, .acquire) == null) break;
    }
}

/// IPI handler for `TLB_SHOOTDOWN_VECTOR`. Runs on every remote CPU after
/// the initiator broadcasts. Must not acquire locks — only atomics.
pub fn handleShootdownIpi() void {
    // EOI first so the LAPIC can deliver further interrupts while we flush.
    eoiInline();
    servicePendingShootdown();
}

/// Initiator-side: flush `[addr_start, addr_start + page_count * 4K)` on the
/// local CPU and every other online CPU. Safe to call on uniprocessor (skips
/// the IPI step). `page_count == 0` is a no-op.
pub fn shootdownRange(addr_start: u64, page_count: u32) void {
    if (page_count == 0) return;

    // Local flush first — synchronous, doesn't need the lock.
    flushLocal(addr_start, page_count);

    const configured = @atomicLoad(u32, &smp.configured_cpu_count, .acquire);
    const current_cpu = syscall_entry.getPerCpu().cpu_id;
    var remote: u32 = 0;
    var cpu: u32 = 0;
    while (cpu < configured) : (cpu += 1) {
        if (cpu == current_cpu) continue;
        if (smp.isCpuOnline(@intCast(cpu))) remote += 1;
    }
    if (remote == 0) return;

    // Serialise with other initiators. The IPI handler does NOT take this
    // lock so it can still service shootdowns broadcast by whoever holds it.
    const saved = shootdown_lock.acquire();
    defer shootdown_lock.release(saved);

    // Publish the request. Order: store data, then store completion, then
    // store active — readers acquire-load the data after seeing `completion`
    // non-zero via the IPI.
    @atomicStore(u64, &shootdown_req.addr_start, addr_start, .release);
    @atomicStore(u32, &shootdown_req.page_count, page_count, .release);
    const generation = @atomicLoad(u32, &shootdown_req.generation, .monotonic) +% 1;
    @atomicStore(u32, &shootdown_req.generation, if (generation == 0) 1 else generation, .release);
    @atomicStore(u32, &shootdown_req.completion, remote, .release);
    @atomicStore(u32, &shootdown_req.active, 1, .release);

    cpu = 0;
    while (cpu < configured) : (cpu += 1) {
        if (cpu == current_cpu) continue;
        const logical_id: u8 = @intCast(cpu);
        if (!smp.isCpuOnline(logical_id)) continue;
        const apic_id: u8 = @intCast(syscall_entry.percpu_array[logical_id].apic_id);
        if (!lapic.sendIpi(apic_id, lapic.TLB_SHOOTDOWN_VECTOR)) failShootdown("IPI delivery timed out");
    }

    // Wait with the caller's IF state untouched. Do NOT `sti` here: callers
    // include the page-fault handler (COW/swap), where an interrupt window
    // would let a timer tick nest inside the fault frame and corrupt iretq
    // state. Waiters parked in `TlbLock.acquire` service this broadcast
    // manually via `servicePendingShootdown`, so IRQ-off waiting cannot
    // deadlock the protocol.
    var polls: u32 = 0;
    while (@atomicLoad(u32, &shootdown_req.completion, .acquire) != 0) : (polls += 1) {
        if (polls == SHOOTDOWN_WAIT_POLL_LIMIT) failShootdown("completion timed out");
        asm volatile ("pause");
    }

    @atomicStore(u32, &shootdown_req.active, 0, .release);
}
