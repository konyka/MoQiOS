//! AArch64 generic timer for the skeleton (Milestone 9-4/9-5).
//!
//! Programs the virtual timer (CNTV_*_EL0). M9-4 polls ISTATUS; M9-5 delivers
//! firings via GICv3 PPI 27 + EL1 IRQ.

const uart = @import("uart.zig");

var interval_ticks: u64 = 0;
var firings: u64 = 0;
var irq_firings: u64 = 0;

fn putDec(v: u64) void {
    if (v == 0) {
        uart.writeByte('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (x > 0) : (n += 1) {
        buf[n] = @intCast('0' + (x % 10));
        x /= 10;
    }
    while (n > 0) {
        n -= 1;
        uart.writeByte(buf[n]);
    }
}

fn readCntfrq() u64 {
    return asm volatile ("mrs %[r], cntfrq_el0"
        : [r] "=r" (-> u64),
    );
}

fn writeCntvTval(v: u64) void {
    asm volatile ("msr cntv_tval_el0, %[v]"
        :
        : [v] "r" (v),
    );
}

fn writeCntvCtl(v: u64) void {
    asm volatile ("msr cntv_ctl_el0, %[v]"
        :
        : [v] "r" (v),
    );
}

fn readCntvCtl() u64 {
    return asm volatile ("mrs %[r], cntv_ctl_el0"
        : [r] "=r" (-> u64),
    );
}

/// `interval_ns` is approximate; converted via CNTFRQ. Pass 0 for ~10 ms default.
pub fn init(interval_ns: u64) void {
    const frq = readCntfrq();
    if (frq == 0) {
        interval_ticks = 1_000_000;
    } else if (interval_ns == 0) {
        interval_ticks = frq / 100; // ~10 ms
        if (interval_ticks == 0) interval_ticks = 1;
    } else {
        interval_ticks = (frq *% (interval_ns / 1000)) / 1_000_000;
        if (interval_ticks == 0) interval_ticks = 1;
    }
    writeCntvCtl(0);
    writeCntvTval(interval_ticks);
    writeCntvCtl(1); // ENABLE, IMASK=0
}

pub fn freqHz() u64 {
    return readCntfrq();
}

pub fn getFirings() u64 {
    return firings;
}

pub fn getIrqFirings() u64 {
    return irq_firings;
}

fn rearm() void {
    writeCntvTval(interval_ticks);
    writeCntvCtl(1);
}

/// Called from GIC IRQ path (PPI 27).
pub fn onInterrupt() void {
    irq_firings +%= 1;
    firings +%= 1;
    rearm();
}

/// Spin until ISTATUS, then rearm. Returns false on timeout.
pub fn waitFire(max_spins: u64) bool {
    var spins: u64 = 0;
    while ((readCntvCtl() & (1 << 2)) == 0) {
        spins += 1;
        if (spins > max_spins) return false;
        asm volatile ("yield");
    }
    firings +%= 1;
    rearm();
    return true;
}

/// M9-4 self-test: observe three timer firings via ISTATUS poll.
pub fn selfTest() bool {
    uart.writeString("MoQiOS aarch64: M9-4 (generic timer)\n");
    uart.writeString("  cntfrq=");
    putDec(freqHz());
    uart.writeString(" Hz\n");

    // Mask IRQs during poll test so GIC path does not double-count.
    @import("gic.zig").disableCpuIrq();
    firings = 0;
    init(0);
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        if (!waitFire(2_000_000_000)) {
            uart.writeString("  M9-4 FAILED: timer timeout\n");
            return false;
        }
    }
    uart.writeString("  timer firings=");
    putDec(firings);
    uart.writeString(" OK\n");
    uart.writeString("[aarch64] M9-4 complete\n");
    return true;
}

/// M9-5 self-test: three firings delivered via GICv3 IRQ (yield-polled timeout).
pub fn irqSelfTest() bool {
    const gic = @import("gic.zig");
    uart.writeString("MoQiOS aarch64: M9-5 (GIC + timer IRQ)\n");

    if (!gic.init()) {
        uart.writeString("  M9-5 FAILED: gic init\n");
        return false;
    }
    uart.writeString("  gicd_iidr=");
    putDec(gic.distributorIidr());
    uart.writeString("\n");

    irq_firings = 0;
    firings = 0;
    init(0);
    gic.enableCpuIrq();

    // Do not WFI forever — if the IRQ path is broken, WFI never returns.
    var spins: u64 = 0;
    while (irq_firings < 3) {
        asm volatile ("yield");
        spins += 1;
        if (spins > 2_000_000_000) {
            uart.writeString("  M9-5 FAILED: IRQ timeout (irq_firings=");
            putDec(irq_firings);
            uart.writeString(")\n");
            gic.disableCpuIrq();
            return false;
        }
    }
    gic.disableCpuIrq();
    uart.writeString("  timer IRQ firings=");
    putDec(irq_firings);
    uart.writeString(" OK\n");
    uart.writeString("[aarch64] M9-5 complete\n");
    return true;
}
