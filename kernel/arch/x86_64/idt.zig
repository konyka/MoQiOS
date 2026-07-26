/// Interrupt Descriptor Table — 256 entries with comptime-generated stubs.
/// commonStub is returnable: it saves all GPRs, calls interruptDispatch,
/// then restores and iretqs. This allows IRQ handlers (timer) to return
/// and enables context switching by modifying the frame in-place.
const serial = @import("serial.zig");
const exception = @import("exception.zig");
const fmt = @import("../../lib/fmt.zig");

const IdtEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32 = 0,
};

const IdtPtr = packed struct {
    limit: u16,
    base: u64,
};

var idt_entries: [256]IdtEntry = undefined;
var idt_ptr: IdtPtr = undefined;

/// Global tick counter — incremented by timer IRQ.
var tick_count: u64 = 0;

pub fn getTickCount() u64 {
    return tick_count;
}

pub fn incrementTick() void {
    tick_count += 1;
}

pub fn enableIrq() void {
    asm volatile ("sti");
}

pub fn disableIrq() void {
    asm volatile ("cli");
}

const exception_names = [32][]const u8{
    "Division Error",
    "Debug",
    "NMI",
    "Breakpoint",
    "Overflow",
    "Bound Range",
    "Invalid Opcode",
    "Device Not Available",
    "Double Fault",
    "Coprocessor Overrun",
    "Invalid TSS",
    "Segment Not Present",
    "Stack Fault",
    "General Protection",
    "Page Fault",
    "Reserved",
    "x87 FP Exception",
    "Alignment Check",
    "Machine Check",
    "SIMD Exception",
    "Virtualization",
    "Control Protection",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Hypervisor Injection",
    "VMM Communication",
    "Security Exception",
    "Reserved",
};

// Vectors that push an error code
fn hasErrorCode(vector: u8) bool {
    return switch (vector) {
        8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
        else => false,
    };
}

fn makeGate(handler: u64, ist: u3) IdtEntry {
    return .{
        .offset_low = @truncate(handler),
        .selector = 0x08,
        .ist = ist,
        .type_attr = 0x8E,
        .offset_mid = @truncate(handler >> 16),
        .offset_high = @truncate(handler >> 32),
    };
}

// --- Comptime stub generation ---

fn makeStub(comptime vector: u8) *const fn () callconv(.naked) void {
    return comptime &struct {
        fn stub() callconv(.naked) void {
            const vec_str = comptime blk: {
                var buf: [3]u8 = undefined;
                var v = vector;
                var len: usize = 0;
                if (v == 0) {
                    buf[0] = '0';
                    break :blk buf[0..1];
                }
                while (v > 0) {
                    buf[len] = @intCast(v % 10 + '0');
                    len += 1;
                    v /= 10;
                }
                var j: usize = 0;
                while (j < len / 2) : (j += 1) {
                    const tmp = buf[j];
                    buf[j] = buf[len - 1 - j];
                    buf[len - 1 - j] = tmp;
                }
                break :blk buf[0..len];
            };
            // Jump to commonStub via a direct RIP-relative branch. Using a
            // `"r"` input for the target would make the compiler load
            // &commonStub into a GPR (e.g. RAX) BEFORE these pushes, clobbering
            // the interrupted task's register before commonStub can save it.
            // `commonStub` has C linkage (`export fn`) so the symbol resolves.
            asm volatile ((if (!hasErrorCode(vector)) "pushq $0\n" else "") ++
                    "pushq $" ++ vec_str ++ "\n" ++
                    "jmp commonStub\n");
        }
    }.stub;
}

// Generate all 256 stubs at comptime
const stubs = blk: {
    var s: [256]*const fn () callconv(.naked) void = undefined;
    for (0..256) |i| {
        s[i] = makeStub(@intCast(i));
    }
    break :blk s;
};

/// Interrupt frame — pushed by commonStub + CPU.
/// Layout matches the stack order in commonStub.
pub const InterruptFrame = extern struct {
    // Pushed by commonStub (reverse order of push)
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,

    // Pushed by stub
    vector: u64,
    error_code: u64,

    // Pushed by CPU on interrupt
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

// --- Common stub: save registers, call dispatch, restore, iretq ---
// Stack layout after stub pushes (vector + error_code):
//   RSP+0   : rax    (pushed first, lowest address)
//   RSP+8   : rbx
//   ...
//   RSP+112 : r15
//   RSP+120 : vector    (pushed by stub)
//   RSP+128 : error_code (pushed by stub or CPU)
//   RSP+136 : RIP       (pushed by CPU on interrupt)
//   RSP+144 : CS
//   RSP+152 : RFLAGS
//   RSP+160 : RSP
//   RSP+168 : SS
//
// SwapGS / per-CPU access:
//   This stub does NOT swapgs, and does not need to. By design this kernel keeps
//   GS_BASE pointing at *this CPU's* PerCpu in ALL modes — init/apEntry set both
//   GS_BASE and KERNEL_GS_BASE to &percpu_array[cpu], and the syscall-path swapgs
//   only ever swaps percpu↔percpu (a no-op for the base value), while context
//   switches update KERNEL_GS_BASE (not GS_BASE). Therefore %%gs is valid here
//   even when interrupted from user mode, and we use it to reach this CPU's
//   context-switch anchor (PerCpu.saved_stack_anchor @ %%gs:16, M8-3). This holds
//   per-CPU on SMP because each CPU has its own GS_BASE.
//   NOTE: the BSP's GS_BASE is set early (right after idt.init in main) so that
//   even an early-boot exception finds a valid %%gs here.

/// Handler pointer with C linkage so the naked stub can call it via a
/// RIP-relative indirect call *after* all GPRs are saved. Passing it as an
/// `"r"` input instead would make the compiler materialize it into a register
/// (RAX in practice) *before* the first `pushq`, silently corrupting the
/// interrupted task's RAX (it would be saved/restored as the handler address).
export var interrupt_handler_ptr: *const fn (*InterruptFrame) callconv(.c) void = &interruptDispatch;

export fn commonStub() callconv(.naked) void {
    // CRITICAL: the very first instruction must save an interrupted register.
    // Do NOT use asm `"r"` inputs here — they are loaded before this template
    // runs and would clobber RAX/RCX of the interrupted code before we push it.
    // The handler and the stack anchor are referenced RIP-relative *after* the
    // GPR saves (same pattern as syscallEntry).
    asm volatile (
        \\pushq %%rax
        \\pushq %%rbx
        \\pushq %%rcx
        \\pushq %%rdx
        \\pushq %%rsi
        \\pushq %%rdi
        \\pushq %%rbp
        \\pushq %%r8
        \\pushq %%r9
        \\pushq %%r10
        \\pushq %%r11
        \\pushq %%r12
        \\pushq %%r13
        \\pushq %%r14
        \\pushq %%r15
        \\
        \\// Save RSP to this CPU's per-CPU anchor: PerCpu.saved_stack_anchor is at
        \\// %%gs:16 (offset guarded at comptime in sched.zig). GS_BASE points at
        \\// this CPU's PerCpu in all modes, so %%gs is valid without swapgs.
        \\movq %%rsp, %%gs:16
        \\
        \\movq %%rsp, %%rdi
        \\
        \\// Align stack to 16 bytes for ABI
        \\movq %%rsp, %%rbp
        \\andq $-16, %%rsp
        \\
        \\call *interrupt_handler_ptr(%%rip)
        \\
        \\// Restore stack from the per-CPU anchor (scheduler may have switched
        \\// stacks by rewriting %%gs:16 to a new task's frame).
        \\movq %%gs:16, %%rsp
        \\
        \\popq %%r15
        \\popq %%r14
        \\popq %%r13
        \\popq %%r12
        \\popq %%r11
        \\popq %%r10
        \\popq %%r9
        \\popq %%r8
        \\popq %%rbp
        \\popq %%rdi
        \\popq %%rsi
        \\popq %%rdx
        \\popq %%rcx
        \\popq %%rbx
        \\popq %%rax
        \\
        \\addq $16, %%rsp
        \\iretq
        ::: .{ .memory = true });
}

/// Central interrupt dispatch — called from commonStub with pointer to InterruptFrame.
/// Decides whether to handle as exception (halt) or IRQ (return).
pub fn interruptDispatch(frame: *InterruptFrame) callconv(.c) void {
    const vector: u8 = @truncate(frame.vector);

    if (vector < 32) {
        // Vector 7 (#NM, Device Not Available) drives the lazy FPU/SSE
        // restore path — NOT a fatal exception. Handle it here and let the
        // offending instruction re-execute via iretq.
        if (vector == 7) {
            const context_switch = @import("context_switch.zig");
            context_switch.handleDeviceNotAvailable();
            return;
        }
        // CPU exception — fatal for now
        handleException(frame);
        return; // unreachable (noreturn inside), but satisfies type checker
    }

    // IRQ / software interrupt
    if (vector >= 32 and vector < 48) {
        // Legacy PIC IRQ (32-47)
        handleIrq(frame, vector - 32);
    } else if (vector == 240) {
        // LAPIC timer vector
        handleLapicTimer(frame);
    } else if (vector == 241) {
        // AHCI interrupt vector
        handleAhci(frame);
    } else if (vector == YIELD_TRAP_VECTOR) {
        // Synchronous yield trap — software `int`, never an IPI.
        handleYieldTrap(frame);
    } else if (vector == 253) {
        // Reschedule IPI (lapic.RESCHEDULE_VECTOR)
        handleReschedule(frame);
    } else if (vector == 254) {
        // TLB shootdown IPI (lapic.TLB_SHOOTDOWN_VECTOR)
        handleTlbShootdown(frame);
    }
    // Other vectors: ignored for now
}

/// Vector for the synchronous yield trap raised by `sched.forceReschedule` on
/// x86. Its gate has DPL 0, so user space gets #GP rather than a free yield.
pub const YIELD_TRAP_VECTOR: u8 = 252;

/// Synchronous yield trap (vector 252) — kernel code asked to switch away right
/// here rather than at the next timer tick.
///
/// A `call` into the scheduler cannot do this from a syscall: the scheduler
/// hands the CPU over by rewriting the per-CPU stack anchor, and only an
/// interrupt return reads that anchor. The syscall path returns through
/// `sysretq` on its own stack, so it would resume the *calling* task with the
/// next task's CR3 already loaded. Taking a real interrupt gives the caller a
/// frame the scheduler can park and resume, so the handover happens here.
///
/// Unlike the reschedule IPI this is not an interrupt the LAPIC delivered, so it
/// must not send an EOI.
fn handleYieldTrap(frame: *InterruptFrame) void {
    const sched = @import("../../proc/sched.zig");
    sched.forceRescheduleFromIpi(frame);
}

/// Reschedule IPI (vector 253) — another CPU asked this CPU to re-run its
/// scheduler (e.g. a newly-ready higher-priority task, or a yielding remote
/// task). We acknowledge and drive a scheduler pass on the local CPU.
///
/// Dormant until APs participate in scheduling (M8-5); nobody sends this vector
/// in uniprocessor mode, so single-core behavior is unchanged.
fn handleReschedule(frame: *InterruptFrame) void {
    const lapic = @import("lapic.zig");
    lapic.eoi();
    const sched = @import("../../proc/sched.zig");
    sched.forceRescheduleFromIpi(frame);
}

/// TLB shootdown IPI (vector 254) — another CPU changed a shared mapping and
/// asked this CPU to invalidate its stale TLB entries.
///
/// M8-6: delegated to `tlb.handleShootdownIpi` which reads the published
/// shootdown range, performs ranged `invlpg` (or CR3 reload above the
/// threshold), then acknowledges by decrementing the global completion
/// counter. EOI happens inside the handler so the LAPIC can deliver more
/// interrupts while the flush is in progress.
fn handleTlbShootdown(frame: *InterruptFrame) void {
    _ = frame;
    const tlb = @import("tlb.zig");
    tlb.handleShootdownIpi();
}

fn handleException(frame: *InterruptFrame) void {
    const vector: u8 = @truncate(frame.vector);
    const cr2: u64 = asm volatile ("movq %%cr2, %[cr2]"
        : [cr2] "=r" (-> u64),
    );

    // Page fault (vector 14) gets special handling — non-fatal for copy_from_user
    // recovery and user-space demand paging.
    if (vector == 14) {
        handlePageFault(frame, cr2);
        return;
    }

    // Record in exception ring buffer
    exception.ring.record(vector, frame.error_code, frame.rip, frame.rflags, cr2);

    serial.writeString("\n!!! EXCEPTION #");
    fmt.writeDecimal64(vector);
    if (vector < 32) {
        serial.writeString(" (");
        serial.writeString(exception_names[vector]);
        serial.writeString(")");
    }
    serial.writeString(" !!!\n");
    serial.writeString("  error_code: 0x");
    fmt.writeHex(frame.error_code);
    serial.writeString("\n  RIP: 0x");
    fmt.writeHex(frame.rip);
    serial.writeString("\n  CS: 0x");
    fmt.writeHex(frame.cs);
    serial.writeString("\n  RSP: 0x");
    fmt.writeHex(frame.rsp);
    serial.writeString("\n  SS: 0x");
    fmt.writeHex(frame.ss);
    serial.writeString("\n  RFLAGS: 0x");
    fmt.writeHex(frame.rflags);
    if (vector == 14) {
        serial.writeString("\n  CR2 (fault address): 0x");
        fmt.writeHex(cr2);
    }
    // Diagnostics for stack-related faults: dump the TSS RSP0 the CPU would have
    // switched to, plus the current task's kernel stack bounds. A mismatch /
    // non-canonical RSP0 explains #SS-on-interrupt-delivery cascades.
    if (vector == 8 or vector == 12 or vector == 13) {
        const gdt = @import("gdt.zig");
        serial.writeString("\n  TSS.RSP0: 0x");
        fmt.writeHex(gdt.getTssPtr(0).rsp0);
        const sched = @import("../../proc/sched.zig");
        const task = @import("../../proc/task.zig");
        if (sched.currentTaskIndex()) |ci| {
            serial.writeString("\n  cur task idx: ");
            fmt.writeDecimal64(ci);
            if (task.getTask(ci)) |ct| {
                serial.writeString(" tid: ");
                fmt.writeDecimal64(ct.tid);
                serial.writeString(" kstack: 0x");
                fmt.writeHex(ct.kernel_stack);
                serial.writeString("..0x");
                fmt.writeHex(ct.kernel_stack_top);
                serial.writeString(" is_user: ");
                fmt.writeDecimal64(@intFromBool(ct.is_user));
            }
        }
    }
    // User-mode CPU exceptions (other than #DF) are not fatal to the kernel:
    // kill the offending process and let the scheduler move on, mirroring the
    // #PF segfault path. Only genuine kernel-mode faults — or a #DF, which means
    // exception delivery itself failed — halt the whole system.
    const from_user = (frame.cs & 0x3) == 0x3;
    if (from_user and vector != 8) {
        serial.writeString("\n  [user fault] killing process\n");
        const task_mod = @import("../../proc/task.zig");
        task_mod.exitTask(128 + @as(i32, @intCast(vector)));
        return;
    }

    serial.writeString("\n  system halted\n");
    while (true) {
        asm volatile ("cli");
        asm volatile ("hlt");
    }
}

/// Page fault handler (#PF, vector 14) — non-fatal recovery paths.
///
/// Error code bits:
///   bit 0 (P):  0 = page not present, 1 = protection violation
///   bit 1 (W/R): 0 = read, 1 = write
///   bit 2 (U/S): 0 = kernel mode, 1 = user mode
///   bit 3 (RSVD): reserved bit set in page table
///   bit 4 (I/D):  0 = instruction fetch, 1 = data access
///
/// Recovery paths:
///   1. copy_from_user fault: if active guard covers faulting RIP, jump to recovery
///   2. User-mode demand paging: allocate and map a page for valid user addresses
///   3. User-mode segfault: kill the offending process
///   4. Kernel-mode fault without guard: fatal (halt)
fn handlePageFault(frame: *InterruptFrame, cr2: u64) void {
    const err = frame.error_code;
    const user_mode = (err & 0x4) != 0;
    const present = (err & 0x1) != 0;
    const write = (err & 0x2) != 0;

    // Record in exception ring buffer
    exception.ring.record(14, err, frame.rip, frame.rflags, cr2);

    // Path 1: copy_from_user / copy_to_user recovery
    const copy_mod = @import("../../mm/copy_from_user.zig");
    if (copy_mod.checkFault()) |recovery_rip| {
        // Patch the saved RIP to jump to the recovery label.
        // RCX still holds the remaining count from rep movsb.
        frame.rip = recovery_rip;
        return;
    }

    // Path 2: User-mode COW fault (page present, write attempt, COW bit set)
    if (user_mode and present and write) {
        if (handleCowFault(frame, cr2)) {
            return; // Successfully handled COW
        }
        // Not a COW fault — fall through to segfault
    }

    // Kernel copy_to_user can legitimately write to a current task's COW user
    // page. Resolve it here instead of crashing on a supervisor-mode page fault.
    if (!user_mode and present and write and cr2 < 0x0000_8000_0000_0000) {
        if (handleCowFault(frame, cr2)) {
            return;
        }
    }

    // Path 3: User-mode demand paging (page not present, from user space)
    if (user_mode and !present) {
        if (handleDemandPage(frame, cr2)) {
            return; // Successfully handled
        }
        // Failed demand page — fall through to segfault
    }

    // Path 4: User-mode segfault — deliver SIGSEGV when a handler is registered,
    // otherwise terminate (default action).
    if (user_mode) {
        const task_mod = @import("../../proc/task.zig");
        const sched_mod = @import("../../proc/sched.zig");
        const sig_mod = @import("../../proc/signal.zig");

        if (sched_mod.currentTaskIndex()) |idx| {
            if (task_mod.getTask(idx)) |cur| {
                if (cur.is_user) {
                    _ = sig_mod.sendSignal(cur.tid, sig_mod.SIGSEGV);
                    if (sched_mod.deliverSignalToRunningTask(cur)) {
                        return;
                    }
                }
            }
        }

        serial.writeString("\n[SEGFAULT] User process killed\n");
        serial.writeString("  fault addr: 0x");
        fmt.writeHex(cr2);
        serial.writeString(" at RIP: 0x");
        fmt.writeHex(frame.rip);
        serial.writeString(" (");
        if (write) serial.writeString("write") else serial.writeString("read");
        if (present) serial.writeString(", protection");
        serial.writeString(")\n");

        task_mod.exitTask(139);
        return;
    }

    // Path 4: Kernel-mode fault without guard — fatal
    serial.writeString("\n!!! EXCEPTION #14 (Page Fault) !!!\n");
    {
        const sc = @import("syscall_entry.zig");
        if (sc.getPerCpuOrNull()) |pc| {
            serial.writeString("  CPU: ");
            serial.writeByte('0' + @as(u8, @truncate(pc.cpu_id)));
            serial.writeString("\n");
        }
    }
    serial.writeString("  error_code: 0x");
    fmt.writeHex(err);
    serial.writeString("\n  RIP: 0x");
    fmt.writeHex(frame.rip);
    serial.writeString("\n  CR2 (fault address): 0x");
    fmt.writeHex(cr2);
    serial.writeString("\n  ");
    if (write) serial.writeString("write") else serial.writeString("read");
    if (present) serial.writeString(", protection violation") else serial.writeString(", page not present");
    serial.writeString(" in kernel mode\n");
    // Dump the kernel stack: print return-address-looking values (kernel image
    // 0xffffffff8... or HHDM 0xffff8000...) to reconstruct the call chain.
    serial.writeString("  RSP: 0x");
    fmt.writeHex(frame.rsp);
    serial.writeString("\n  stack (candidate return addrs):\n");
    {
        const sp: [*]const u64 = @ptrFromInt(frame.rsp & ~@as(u64, 7));
        var i: usize = 0;
        var printed: usize = 0;
        while (i < 64 and printed < 16) : (i += 1) {
            const v = sp[i];
            if (v >= 0xffffffff80000000) {
                serial.writeString("    [");
                fmt.writeDecimal64(i);
                serial.writeString("] 0x");
                fmt.writeHex(v);
                serial.writeString("\n");
                printed += 1;
            }
        }
    }
    serial.writeString("  system halted\n");
    while (true) {
        asm volatile ("cli");
        asm volatile ("hlt");
    }
}

/// Demand paging — allocate and map a page for a user-space fault address.
/// Returns true if the fault was in a valid user region and was handled.
fn handleDemandPage(frame: *InterruptFrame, fault_addr: u64) bool {
    const pmm = @import("../../mm/pmm.zig");
    const hhdm = @import("../../mm/hhdm.zig");
    const paging_mod = @import("paging.zig");
    const sched = @import("../../proc/sched.zig");

    const current = sched.currentTask() orelse return false;
    if (current.page_table_phys == 0) return false; // kernel thread, no user space

    // Align fault address down to page boundary
    const page_addr = fault_addr & ~@as(u64, paging_mod.PAGE_SIZE - 1);

    // Check valid user regions
    const user_space = @import("../../mm/user_space.zig");

    // Stack: auto-growing region below USER_STACK_TOP down to USER_STACK_BOTTOM
    const in_stack_range = page_addr >= user_space.USER_STACK_BOTTOM and page_addr < user_space.USER_STACK_TOP;
    // Code:  [USER_CODE_BASE, USER_CODE_BASE + MAX_CODE_PAGES * PAGE_SIZE)
    const in_code_range = page_addr >= user_space.USER_CODE_BASE and page_addr < user_space.USER_CODE_BASE + 16 * paging_mod.PAGE_SIZE;

    if (!in_stack_range and !in_code_range) return false;

    // Check if this is a swap-in (page was swapped out)
    const swap = @import("../../mm/swap.zig");
    if (swap.isEnabled()) {
        const pte_or_null = paging_mod.getPageEntryRaw(current.page_table_phys, page_addr);
        if (pte_or_null) |pte_val| {
            if (swap.isSwapEntry(pte_val)) {
                // Swap in: read the page back from disk
                const new_pte = swap.swapIn(pte_val) orelse return false;
                // Update the PTE
                paging_mod.setPageEntryRaw(current.page_table_phys, page_addr, new_pte);
                // Flush TLB
                asm volatile ("invlpg (%[addr])"
                    :
                    : [addr] "r" (page_addr),
                );
                return true;
            }
        }
    }

    // Stack auto-growth: extend stack_limit when fault is below current limit
    if (in_stack_range and page_addr < current.stack_limit) {
        // Check we don't grow below USER_STACK_BOTTOM
        if (page_addr < user_space.USER_STACK_BOTTOM) return false;
        // Check we don't grow into the heap region (brk)
        if (page_addr < current.brk_current + 4096) return false;
        // Extend stack_limit — grow in chunks of 32 pages (128KB) for efficiency
        const new_limit = page_addr & ~@as(u64, 32 * paging_mod.PAGE_SIZE - 1);
        current.stack_limit = @max(new_limit, user_space.USER_STACK_BOTTOM);
    }

    // Allocate a physical page
    const phys = pmm.allocPage() orelse return false;
    const virt = hhdm.physToVirt(phys);
    const page: [*]u8 = @ptrFromInt(virt);
    @memset(page[0..paging_mod.PAGE_SIZE], 0); // zero-fill

    // Map into user address space
    const writable = in_stack_range; // stack is writable, code is read-only
    const flags = paging_mod.MapFlags{
        .writable = writable,
        .user = true,
        .no_execute = in_stack_range, // NX for stack, executable for code
        .global = false,
    };
    paging_mod.mapPage(current.page_table_phys, page_addr, phys, flags) catch {
        pmm.freePage(phys);
        return false;
    };

    _ = frame;
    return true;
}

/// Copy-on-Write fault handler.
/// When a user process writes to a COW-shared page (present + read-only + COW bit):
/// - If ref_count == 1: just make the page writable (sole owner optimization)
/// - If ref_count > 1: allocate new page, copy content, update PTE
/// Returns true if the fault was a COW fault and was handled.
fn handleCowFault(frame: *InterruptFrame, fault_addr: u64) bool {
    const pmm_mod = @import("../../mm/pmm.zig");
    const hhdm_mod = @import("../../mm/hhdm.zig");
    const paging_mod = @import("paging.zig");
    const sched = @import("../../proc/sched.zig");

    const COW_BIT: u64 = 1 << 9;

    const current = sched.currentTask() orelse return false;
    if (current.page_table_phys == 0) return false;

    const page_addr = fault_addr & ~@as(u64, paging_mod.PAGE_SIZE - 1);

    // Get the PTE for this page
    const pte = paging_mod.getPageEntry(current.page_table_phys, page_addr) orelse return false;
    const pte_val: u64 = @bitCast(pte.*);

    // Check COW bit is set
    if (pte_val & COW_BIT == 0) return false;

    const old_phys = pte_val & paging_mod.ADDR_MASK;

    // Check ref count: if we're the sole owner, just make writable
    const count = pmm_mod.getRefCount(old_phys);
    if (count <= 1) {
        // Sole owner — make writable, clear COW bit
        const updated: u64 = (pte_val & ~COW_BIT) | paging_mod.WRITABLE;
        paging_mod.setPageEntryRaw(current.page_table_phys, page_addr, updated);
        paging_mod.invlpg(page_addr);
        _ = frame;
        return true;
    }

    // Multiple owners: allocate a new private page and copy
    const new_phys = pmm_mod.allocPage() orelse return false;
    const src: [*]const u8 = @ptrFromInt(hhdm_mod.physToVirt(old_phys));
    const dst: [*]u8 = @ptrFromInt(hhdm_mod.physToVirt(new_phys));
    @memcpy(dst[0..paging_mod.PAGE_SIZE], src[0..paging_mod.PAGE_SIZE]);

    // Update PTE: point to new page, make writable, clear COW bit
    const updated_pte = (pte_val & ~paging_mod.ADDR_MASK & ~@as(u64, COW_BIT)) | new_phys | paging_mod.WRITABLE;
    paging_mod.setPageEntryRaw(current.page_table_phys, page_addr, updated_pte);
    paging_mod.invlpg(page_addr);

    // Release our reference to the old shared page (other owner still holds it).
    _ = pmm_mod.decRef(old_phys);

    _ = frame;
    return true;
}

/// Handle AHCI interrupt (vector 241).
fn handleAhci(frame: *InterruptFrame) void {
    _ = frame;
    const ahci = @import("../../drivers/ahci.zig");
    ahci.handleInterrupt();
    // Send EOI to LAPIC (MSI interrupts still require LAPIC EOI)
    const lapic = @import("lapic.zig");
    lapic.eoi();
}

/// Handle LAPIC timer interrupt (vector 240).
///
/// Every CPU EOIs its own LAPIC. The global tick (which drives timerfd/POSIX
/// timers and the reap interval) is advanced by the BSP only, so wall-clock time
/// does not run N× faster on an N-CPU system. timerTick is called on every CPU;
/// it internally decides what scheduling work this CPU performs (M8-5a: APs do
/// nothing; M8-5b: APs schedule their own tasks).
fn handleLapicTimer(frame: *InterruptFrame) void {
    // Import LAPIC and scheduler here to avoid circular deps at comptime
    const lapic = @import("lapic.zig");
    lapic.eoi();

    const sc = @import("syscall_entry.zig");
    if (sc.getPerCpu().cpu_id == 0) {
        incrementTick();
    }

    const sched = @import("../../proc/sched.zig");
    sched.timerTick(frame);
}

/// Handle legacy PIC IRQ (IRQ 0-15).
fn handleIrq(frame: *InterruptFrame, irq: u8) void {
    _ = frame;
    if (irq == 1) {
        const keyboard = @import("../../drivers/keyboard.zig");
        keyboard.handleInterrupt();
    }
    // e1000 NIC interrupt (typically IRQ 11 in QEMU)
    {
        const e1000 = @import("../../drivers/e1000.zig");
        if (e1000.isActive() and e1000.getIrqLine() == irq) {
            e1000.handleInterrupt();
        }
    }
    // virtio-net NIC interrupt
    {
        const vnet = @import("../../drivers/virtio_net.zig");
        if (vnet.isActive() and vnet.getIrqLine() == irq) {
            vnet.handleInterrupt();
        }
    }
    // Send EOI to both PIC chips for cascade
    const io = @import("io.zig");
    io.outb(0x20, 0x20); // EOI to master PIC
    if (irq >= 8) {
        io.outb(0xA0, 0x20); // EOI to slave PIC
    }
}

/// Load the (shared) IDT register on the calling CPU.
/// The IDT table is global; each CPU must execute its own `lidt`.
/// APs call this after `init()` has built the table on the BSP.
pub fn loadOnThisCpu() void {
    asm volatile ("lidt (%[idt_ptr])"
        :
        : [idt_ptr] "r" (&idt_ptr),
    );
}

pub fn init() void {
    @memset(@as([*]u8, @ptrCast(&idt_entries))[0..@sizeOf(@TypeOf(idt_entries))], 0);

    for (0..256) |i| {
        const vec: u8 = @intCast(i);
        // Route stack-sensitive exceptions to dedicated IST stacks so a bad/stale
        // RSP0 (e.g. fault while loading RSP0 on a user→kernel transition) cannot
        // escalate to a triple fault. See gdt.zig for the IST stack definitions.
        const ist: u3 = switch (vec) {
            8 => 1, // #DF  → IST1
            12, 13 => 2, // #SS, #GP → IST2
            2, 18 => 3, // NMI, #MC → IST3
            else => 0,
        };
        idt_entries[vec] = makeGate(@intFromPtr(stubs[vec]), ist);
    }

    idt_ptr = .{
        .limit = @sizeOf(@TypeOf(idt_entries)) - 1,
        .base = @intFromPtr(&idt_entries),
    };

    asm volatile ("lidt (%[idt_ptr])"
        :
        : [idt_ptr] "r" (&idt_ptr),
    );

    // Remap PIC: master IRQ 0-7 → vectors 32-39, slave IRQ 8-15 → vectors 40-47
    const io = @import("io.zig");
    // Mask all IRQs first
    io.outb(0xA1, 0xFF);
    io.outb(0x21, 0xFF);

    // ICW1: start initialization in cascade mode
    io.outb(0x20, 0x11);
    io.outb(0xA0, 0x11);
    // ICW2: vector offsets
    io.outb(0x21, 32); // Master: IRQ 0-7 → INT 32-39
    io.outb(0xA1, 40); // Slave:  IRQ 8-15 → INT 40-47
    // ICW3: cascade wiring
    io.outb(0x21, 0x04); // Master has slave on IRQ2
    io.outb(0xA1, 0x02); // Slave cascade identity
    // ICW4: 8086 mode
    io.outb(0x21, 0x01);
    io.outb(0xA1, 0x01);

    // Unmask IRQ1 (keyboard) only, keep rest masked
    io.outb(0x21, 0xFD); // Master: unmask IRQ1 only (bit 1 = 0)
    io.outb(0xA1, 0xFF); // Slave: all masked
}
