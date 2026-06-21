//! RISC-V 64 backend for the kernel-wide arch abstraction layer.
//!
//! At Milestone 4 of the cross-ISA port most subsystems are still stubs:
//! they expose the same public surface as the x86_64 backend so that
//! shared kernel code compiles for both targets, but the actual hardware
//! bring-up (stvec, Sv39, SBI timer, sret to U-mode, …) lands in later
//! milestones (see docs/cross-arch-port-plan.md).
//!
//! Wherever a stub exists, the body is intentionally minimal — we prefer
//! "obviously a TODO" over a clever-but-wrong placeholder.

pub const serial = struct {
    /// Nothing to configure: SBI legacy console is always available.
    pub fn init() void {}

    pub fn writeByte(byte: u8) void {
        sbiPutchar(byte);
    }

    pub fn writeString(s: []const u8) void {
        for (s) |c| sbiPutchar(c);
    }

    /// SBI legacy console putchar (EID 0x01).
    fn sbiPutchar(c: u8) void {
        asm volatile ("ecall"
            :
            : [eid] "{a7}" (@as(usize, 0x01)),
              [a0] "{a0}" (@as(usize, c)),
            : .{ .memory = true });
    }
};

pub const interrupts = struct {
    /// TODO(M5): install `stvec` trap vector, set up `sscratch`, and route
    /// supervisor-software / supervisor-timer / supervisor-external IRQs.
    pub fn init() void {}

    /// Enable supervisor interrupts (sstatus.SIE).
    pub fn enableIrq() void {
        asm volatile ("csrsi sstatus, 2");
    }

    /// Disable supervisor interrupts (sstatus.SIE).
    pub fn disableIrq() void {
        asm volatile ("csrci sstatus, 2");
    }
};

pub const paging = struct {
    /// TODO(M6): allocate root Sv39 PT, populate kernel half, write `satp`.
    pub fn init() void {}
};

pub const timer = struct {
    /// TODO(M7): arm initial deadline via SBI Timer (EID 0x54494D45) or the
    /// `stimecmp` CSR on Sstc-capable cores.
    pub fn init(_: u64) void {}
};

pub const context_switch = struct {
    /// Per-CPU lazy-FPU / saved-anchor setup. No-op on riscv64 today.
    pub fn initCpu() void {}

    /// Hook invoked from the scheduler when switching tasks. `old` is the
    /// outgoing task pointer (kept generic to mirror x86_64 callsites).
    pub fn onContextSwitch(old: anytype) void {
        _ = old;
    }
};

pub const cpu = struct {
    /// Park the current hart in low-power wait forever.
    pub fn halt() noreturn {
        while (true) asm volatile ("wfi");
    }

    /// Spin-wait hint. RISC-V Zihintpause is optional; a plain `nop` is the
    /// safest portable encoding for now.
    pub fn pause() void {
        asm volatile ("nop");
    }

    /// TODO(M5): once we own the trap path, stash the kernel-relative CPU id
    /// in `tp` (per the SBI HSM convention) and read it here.
    pub fn getCpuId() u8 {
        return 0;
    }
};
