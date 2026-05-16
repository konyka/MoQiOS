/// Interrupt Descriptor Table — 256 entries with comptime-generated stubs.
/// commonStub is returnable: it saves all GPRs, calls interruptDispatch,
/// then restores and iretqs. This allows IRQ handlers (timer) to return
/// and enables context switching by modifying the frame in-place.

const serial = @import("serial.zig");
const exception = @import("exception.zig");

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
            asm volatile (
                (if (!hasErrorCode(vector)) "pushq $0\n" else "") ++
                    "pushq $" ++ vec_str ++ "\n" ++
                    "jmp *%[stub]\n"
                :
                : [stub] "r" (&commonStub),
            );
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
// IMPORTANT SwapGS CONSTRAINT:
//   This stub does NOT do swapgs. GSBase state on entry:
//     - Interrupt from kernel mode (CS=0x08): GSBase = &bsp_percpu (correct)
//     - Interrupt from user mode (CS=0x1B): GSBase = 0 (user GSBase)
//   Therefore: DO NOT access %%gs: in this stub or any function it calls
//   (interruptDispatch, handleLapicTimer, timerTick, etc.).
//   Per-CPU data must be accessed via kernel virtual addresses (not %%gs:).
//   Only syscallEntry/sysretq use swapgs and %%gs: access.

export fn commonStub() callconv(.naked) void {
    const handler = &interruptDispatch;
    const anchor_addr = @intFromPtr(&@import("../../proc/sched.zig").saved_stack_anchor);
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
        \\// Now load anchor address into R12 (original R12 already saved on stack)
        \\movq %[anchor_addr_reg], %%r12
        \\
        \\// Save stack pointer to anchor
        \\movq %%rsp, (%%r12)
        \\
        \\movq %%rsp, %%rdi
        \\
        \\// Align stack to 16 bytes for ABI
        \\movq %%rsp, %%rbp
        \\andq $-16, %%rsp
        \\
        \\call *%[handler]
        \\
        \\// Restore stack from anchor (scheduler may have switched stacks)
        \\movq (%%r12), %%rsp
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
    :
    : [handler] "r" (handler),
      [anchor_addr_reg] "r" (anchor_addr),
    : .{ .memory = true }
    );
}

/// Central interrupt dispatch — called from commonStub with pointer to InterruptFrame.
/// Decides whether to handle as exception (halt) or IRQ (return).
pub fn interruptDispatch(frame: *InterruptFrame) callconv(.c) void {
    const vector: u8 = @truncate(frame.vector);

    if (vector < 32) {
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
    }
    // Other vectors: ignored for now
}

fn handleException(frame: *InterruptFrame) void {
    const vector: u8 = @truncate(frame.vector);
    const cr2: u64 = asm volatile ("movq %%cr2, %[cr2]" : [cr2] "=r" (-> u64));

    // Page fault (vector 14) gets special handling — non-fatal for copy_from_user
    // recovery and user-space demand paging.
    if (vector == 14) {
        handlePageFault(frame, cr2);
        return;
    }

    // Record in exception ring buffer
    exception.ring.record(vector, frame.error_code, frame.rip, frame.rflags, cr2);

    serial.writeString("\n!!! EXCEPTION #");
    writeDecimal(vector);
    if (vector < 32) {
        serial.writeString(" (");
        serial.writeString(exception_names[vector]);
        serial.writeString(")");
    }
    serial.writeString(" !!!\n");
    serial.writeString("  error_code: 0x");
    writeHex(frame.error_code);
    serial.writeString("\n  RIP: 0x");
    writeHex(frame.rip);
    serial.writeString("\n  CS: 0x");
    writeHex(frame.cs);
    serial.writeString("\n  RSP: 0x");
    writeHex(frame.rsp);
    serial.writeString("\n  SS: 0x");
    writeHex(frame.ss);
    serial.writeString("\n  RFLAGS: 0x");
    writeHex(frame.rflags);
    if (vector == 14) {
        serial.writeString("\n  CR2 (fault address): 0x");
        writeHex(cr2);
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

    // Path 2: User-mode demand paging (page not present, from user space)
    if (user_mode and !present) {
        if (handleDemandPage(frame, cr2)) {
            return; // Successfully handled
        }
        // Failed demand page — fall through to segfault
    }

    // Path 3: User-mode segfault — kill the process
    if (user_mode) {
        serial.writeString("\n[SEGFAULT] User process killed\n");
        serial.writeString("  fault addr: 0x");
        writeHex(cr2);
        serial.writeString(" at RIP: 0x");
        writeHex(frame.rip);
        serial.writeString(" (");
        if (write) serial.writeString("write") else serial.writeString("read");
        if (present) serial.writeString(", protection");
        serial.writeString(")\n");

        const task_mod = @import("../../proc/task.zig");
        task_mod.exitTask(139); // SIGSEGV-like exit code
        return; // unreachable (exitTask doesn't return)
    }

    // Path 4: Kernel-mode fault without guard — fatal
    serial.writeString("\n!!! EXCEPTION #14 (Page Fault) !!!\n");
    serial.writeString("  error_code: 0x");
    writeHex(err);
    serial.writeString("\n  RIP: 0x");
    writeHex(frame.rip);
    serial.writeString("\n  CR2 (fault address): 0x");
    writeHex(cr2);
    serial.writeString("\n  ");
    if (write) serial.writeString("write") else serial.writeString("read");
    if (present) serial.writeString(", protection violation") else serial.writeString(", page not present");
    serial.writeString(" in kernel mode\n  system halted\n");
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

    // Only handle faults in valid user regions:
    //   Stack: growable region below USER_STACK_TOP
    //   Code:  [USER_CODE_BASE, USER_CODE_BASE + MAX_CODE_PAGES * PAGE_SIZE)
    const user_space = @import("../../mm/user_space.zig");
    const in_stack_range = page_addr >= (user_space.USER_STACK_TOP - 64 * paging_mod.PAGE_SIZE) and page_addr < user_space.USER_STACK_TOP;
    const in_code_range = page_addr >= user_space.USER_CODE_BASE and page_addr < user_space.USER_CODE_BASE + 16 * paging_mod.PAGE_SIZE;

    if (!in_stack_range and !in_code_range) return false;

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

/// Handle LAPIC timer interrupt (vector 240).
fn handleLapicTimer(frame: *InterruptFrame) void {
    incrementTick();
    // Import LAPIC and scheduler here to avoid circular deps at comptime
    const lapic = @import("lapic.zig");
    lapic.eoi();

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
    // Send EOI to both PIC chips for cascade
    const io = @import("io.zig");
    io.outb(0x20, 0x20); // EOI to master PIC
    if (irq >= 8) {
        io.outb(0xA0, 0x20); // EOI to slave PIC
    }
}

fn writeHex(value: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = value;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@as(usize, @intCast(v & 0xf))];
        v >>= 4;
    }
    serial.writeString(&buf);
}

fn writeDecimal(value: u64) void {
    var buf: [20]u8 = undefined;
    if (value == 0) {
        serial.writeString("0");
        return;
    }
    var v = value;
    var i: usize = 0;
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
    serial.writeString(buf[0..i]);
}

pub fn init() void {
    @memset(@as([*]u8, @ptrCast(&idt_entries))[0..@sizeOf(@TypeOf(idt_entries))], 0);

    for (0..256) |i| {
        const vec: u8 = @intCast(i);
        const ist: u3 = if (vec == 8) 1 else 0; // Double Fault uses IST1
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
