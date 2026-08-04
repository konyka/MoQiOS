/// Pure-logic core for the userspace driver framework v1 (L1).
///
/// No kernel imports beyond the shared errno constants — everything here is
/// host-tested via tests/main.zig (see kernel/host_test.zig for the wiring).
/// The kernel glue in userdrv.zig wraps these primitives with paging, PMM,
/// PIC and scheduler interaction.

const errno = @import("../lib/errno.zig");

/// Maximum MMIO window a single dev_map_mmio call may cover (16 MiB).
pub const MMIO_MAX_SIZE: u64 = 16 * 1024 * 1024;
/// Maximum dev_dma_alloc request (1 MiB — matches dma.zig's scatter limit).
pub const DMA_MAX_SIZE: u64 = 1024 * 1024;

pub const PAGE: u64 = 4096;

/// A physical address range (half-open: [base, base+len)).
pub const PhysRange = struct {
    base: u64,
    len: u64,
};

/// Validate the shape of a dev_map_mmio request: non-zero, capped size,
/// page-aligned base, and no 64-bit wraparound of phys+size.
/// Returns 0 on success, -EINVAL otherwise. The RAM-overlap rejection is
/// done separately by the caller via overlapsRamRanges / pmm predicates.
pub fn validateMmioRequest(phys: u64, size: u64) i64 {
    if (size == 0 or size > MMIO_MAX_SIZE) return errno.EINVAL;
    if (phys % PAGE != 0) return errno.EINVAL;
    if (phys +% size < phys) return errno.EINVAL; // address-space wraparound
    return 0;
}

/// Validate a dev_dma_alloc size: 1 byte .. DMA_MAX_SIZE.
pub fn validateDmaSize(size: u64) i64 {
    if (size == 0 or size > DMA_MAX_SIZE) return errno.EINVAL;
    return 0;
}

/// Half-open range overlap test (wrapping-safe for end computation).
pub fn rangesOverlap(a_base: u64, a_len: u64, b_base: u64, b_len: u64) bool {
    const a_end = a_base +% a_len;
    const b_end = b_base +% b_len;
    return a_base < b_end and b_base < a_end;
}

/// True when [phys, phys+len) touches any of the given RAM ranges.
/// The kernel passes the PMM's recorded Limine RAM ranges; a hit means the
/// range must NEVER be handed to userspace as device MMIO.
pub fn overlapsRamRanges(ranges: []const PhysRange, phys: u64, len: u64) bool {
    for (ranges) |r| {
        if (rangesOverlap(phys, len, r.base, r.len)) return true;
    }
    return false;
}

// ─── IRQ table ──────────────────────────────────────────────────────────────

/// Maximum simultaneous user-owned IRQ registrations.
pub const MAX_IRQ_SLOTS: usize = 8;

pub const IrqSlot = struct {
    active: bool = false,
    gsi: u8 = 0,
    /// Task index that registered this GSI (only it may wait/unregister).
    owner_task: u32 = 0,
    /// Monotonic count of interrupt edges observed by the kernel handler.
    edge_count: u64 = 0,
};

pub const RegisterError = error{ KernelOwned, Busy, Full, Invalid };

/// GSI → waiter/edge-count table. Pure data structure; the kernel wrapper
/// serializes mutations with a spinlock and drives PIC mask/unmask.
pub const IrqTable = struct {
    slots: [MAX_IRQ_SLOTS]IrqSlot = [_]IrqSlot{.{}} ** MAX_IRQ_SLOTS,

    /// Register `gsi` for `owner`. `kernel_owned` is precomputed by the
    /// caller (keyboard line, active NIC lines, ...) — a kernel-owned GSI is
    /// always refused. `max_gsi` is the exclusive routable ceiling the caller
    /// computed from the available interrupt hardware: 16 for the legacy PIC,
    /// higher when an IOAPIC is present (see userdrv.maxRoutableGsi).
    pub fn registerIrq(self: *IrqTable, gsi: u8, owner: u32, kernel_owned: bool, max_gsi: u8) RegisterError!usize {
        if (gsi >= max_gsi) return error.Invalid;
        if (kernel_owned) return error.KernelOwned;
        for (self.slots) |s| {
            if (s.active and s.gsi == gsi) return error.Busy;
        }
        for (&self.slots, 0..) |*s, i| {
            if (!s.active) {
                s.* = .{ .active = true, .gsi = gsi, .owner_task = owner, .edge_count = 0 };
                return i;
            }
        }
        return error.Full;
    }

    /// Unregister `gsi`; only the owning task may do so.
    pub fn unregisterIrq(self: *IrqTable, gsi: u8, owner: u32) bool {
        for (&self.slots) |*s| {
            if (s.active and s.gsi == gsi) {
                if (s.owner_task != owner) return false;
                s.active = false;
                return true;
            }
        }
        return false;
    }

    pub fn find(self: *IrqTable, gsi: u8) ?*IrqSlot {
        for (&self.slots) |*s| {
            if (s.active and s.gsi == gsi) return s;
        }
        return null;
    }

    /// Record one interrupt edge (called from the kernel IRQ handler).
    /// Saturates at maxInt(u64) rather than wrapping past a waiter's snapshot.
    pub fn recordEdge(self: *IrqTable, gsi: u8) bool {
        const s = self.find(gsi) orelse return false;
        s.edge_count +|= 1;
        return true;
    }

    /// Deactivate every slot owned by `owner` (task exit). Writes the
    /// released GSIs into `out` so the caller can re-mask the PIC lines;
    /// returns how many were released.
    pub fn releaseAllForTask(self: *IrqTable, owner: u32, out: *[MAX_IRQ_SLOTS]u8) u32 {
        var n: u32 = 0;
        for (&self.slots) |*s| {
            if (s.active and s.owner_task == owner) {
                s.active = false;
                out[n] = s.gsi;
                n += 1;
            }
        }
        return n;
    }
};

// ─── /dev/pci listing ───────────────────────────────────────────────────────

/// Arch-independent PCI device snapshot (mirrors pci.zig's PciDevice).
pub const PciInfo = struct {
    bus: u8,
    device: u8,
    function: u8,
    vendor_id: u16,
    device_id: u16,
    class_code: u8,
    subclass: u8,
    irq_line: u8,
    bars: [6]u64,
    bar_sizes: [6]u64,
};

fn appendByte(out: []u8, w: *usize, b: u8) void {
    if (w.* < out.len) {
        out[w.*] = b;
    }
    w.* += 1;
}

fn appendStr(out: []u8, w: *usize, s: []const u8) void {
    for (s) |b| appendByte(out, w, b);
}

fn appendHex(out: []u8, w: *usize, value: u64, digits: usize) void {
    var shift: usize = digits * 4;
    while (shift > 0) {
        shift -= 4;
        const nib: u8 = @truncate((value >> @intCast(shift)) & 0xF);
        appendByte(out, w, if (nib < 10) '0' + nib else 'a' + (nib - 10));
    }
}

fn appendDec(out: []u8, w: *usize, value: u64) void {
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    var v = value;
    if (v == 0) {
        appendByte(out, w, '0');
        return;
    }
    while (v != 0) {
        tmp[n] = '0' + @as(u8, @truncate(v % 10));
        n += 1;
        v /= 10;
    }
    while (n > 0) {
        n -= 1;
        appendByte(out, w, tmp[n]);
    }
}

/// Generate the /dev/pci snapshot text. One line per device:
///   "00:03.0 8086:100e class=02:00 irq=11 bar0=febc0000+00020000\n"
/// BARs are listed as <hex phys>+<hex size>; zero BARs are omitted (an I/O
/// BAR is printed raw — pci.zig does not record the space type per BAR).
/// Returns the number of bytes that would have been written; callers compare
/// against the buffer length to detect truncation. Output never overruns.
pub fn genPciListing(devs: []const PciInfo, out: []u8) usize {
    var w: usize = 0;
    for (devs) |d| {
        appendHex(out, &w, d.bus, 2);
        appendByte(out, &w, ':');
        appendHex(out, &w, d.device, 2);
        appendByte(out, &w, '.');
        appendHex(out, &w, d.function, 1);
        appendByte(out, &w, ' ');
        appendHex(out, &w, d.vendor_id, 4);
        appendByte(out, &w, ':');
        appendHex(out, &w, d.device_id, 4);
        appendStr(out, &w, " class=");
        appendHex(out, &w, d.class_code, 2);
        appendByte(out, &w, ':');
        appendHex(out, &w, d.subclass, 2);
        appendStr(out, &w, " irq=");
        appendDec(out, &w, d.irq_line);
        for (0..6) |i| {
            if (d.bars[i] == 0) continue;
            appendStr(out, &w, " bar");
            appendByte(out, &w, '0' + @as(u8, @intCast(i)));
            appendByte(out, &w, '=');
            appendHex(out, &w, d.bars[i], 8);
            appendByte(out, &w, '+');
            appendHex(out, &w, d.bar_sizes[i], 8);
        }
        appendByte(out, &w, '\n');
    }
    return @min(w, out.len);
}
