/// Userspace driver framework v1 (L1) — kernel glue.
///
/// Lets a CAP_SYS_RAWIO task drive a PCI device entirely from userspace:
///   - dev_map_mmio(phys, size)          map a device MMIO window (BAR)
///   - dev_irq_register(gsi)             claim an IRQ line (PIC 0-15, IOAPIC 16+)
///   - dev_irq_wait(gsi, timeout_ms)     block until an interrupt edge
///   - dev_irq_unregister(gsi)           release + mask the line
///   - dev_dma_alloc(size, out_ptr)      coherent DMA buffer mapped to user
///   - dev_dma_free(va)                  release it
/// plus a read-only /dev/pci enumeration snapshot (vfs.zig).
///
/// Pure logic (request validation, RAM-overlap test, IRQ table, PCI listing
/// format) lives in userdrv_core.zig and is host-tested; this file only does
/// privilege checks, paging, PMM/pci/PIC interaction and blocking.
///
/// Safety rules:
///   - MMIO ranges overlapping PMM-known RAM are REJECTED (pmm.isRamPhys).
///   - MMIO pages are mapped user/writable/cache-disable/write-through/NX,
///     never global, and tracked as no_free mmap regions so munmap/exit can
///     never return device frames to the PMM free pool.
///   - IRQ lines owned by kernel drivers (keyboard, active NICs, the PIC
///     cascade) cannot be claimed.
///   - cleanupTask (exit/exec) releases IRQs, DMA buffers and MMIO mappings.

const builtin = @import("builtin");
const core = @import("userdrv_core.zig");
const errno = @import("../lib/errno.zig");
const task_mod = @import("../proc/task.zig");
const cap_check = @import("../proc/cap_check.zig");
const pmm = @import("../mm/pmm.zig");
const mmap_mod = @import("../mm/mmap.zig");
const dma = @import("../mm/dma.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const serial = @import("../arch/arch.zig").serial;
const fmt = @import("../lib/fmt.zig");

const is_x86 = builtin.cpu.arch == .x86_64;

/// Syscall numbers (dispatched from arch/x86_64/syscall_entry.zig).
pub const SYS_DEV_MAP_MMIO: u64 = 477;
pub const SYS_DEV_IRQ_REGISTER: u64 = 478;
pub const SYS_DEV_IRQ_WAIT: u64 = 479;
pub const SYS_DEV_IRQ_UNREGISTER: u64 = 480;
pub const SYS_DEV_DMA_ALLOC: u64 = 481;
pub const SYS_DEV_DMA_FREE: u64 = 482;

const paging = @import("../arch/arch.zig").paging;

// ─── IRQ table (kernel side) ────────────────────────────────────────────────

var irq_table: core.IrqTable = .{};
var irq_lock: IrqSpinlock = .{};

// ─── Per-task DMA allocations ───────────────────────────────────────────────

pub const MAX_DMA_ALLOCS: usize = 8;

const DmaAlloc = struct {
    active: bool = false,
    user_va: u64 = 0,
    phys: u64 = 0,
    pages: u32 = 0,
};

/// Result struct written to userspace by dev_dma_alloc.
pub const DmaAllocInfo = extern struct {
    user_va: u64,
    phys: u64,
};

var dma_allocs: [task_mod.MAX_TASKS][MAX_DMA_ALLOCS]DmaAlloc =
    [_][MAX_DMA_ALLOCS]DmaAlloc{[_]DmaAlloc{.{}} ** MAX_DMA_ALLOCS} ** task_mod.MAX_TASKS;
var dma_lock: IrqSpinlock = .{};

// ─── Helpers ────────────────────────────────────────────────────────────────

fn currentTask() ?*task_mod.Task {
    const sched = @import("../proc/sched.zig");
    const idx = sched.currentTaskIndex() orelse return null;
    return task_mod.getTask(idx);
}

/// Kernel-owned IRQ lines a user driver may never claim: the keyboard (1),
/// the PIC cascade (2), and the IRQ lines of NICs the kernel already drives.
fn isKernelOwnedGsi(gsi: u8) bool {
    if (gsi == 1 or gsi == 2) return true;
    const e1000 = @import("e1000.zig");
    if (e1000.isActive() and e1000.getIrqLine() == gsi) return true;
    const vnet = @import("virtio_net.zig");
    if (vnet.isActive() and vnet.getIrqLine() == gsi) return true;
    return false;
}

/// Mask or unmask a legacy PIC line (GSI 0-15, vectors 32-47). GSIs >= 16 go
/// through the IOAPIC instead — see setGsiMask.
fn picSetMask(gsi: u8, masked: bool) void {
    if (comptime !is_x86) return;
    if (gsi >= 16) return;
    const io = @import("../arch/x86_64/io.zig");
    const port: u16 = if (gsi < 8) 0x21 else 0xA1;
    const bit: u8 = @as(u8, 1) << @intCast(gsi & 7);
    const cur = io.inb(port);
    io.outb(port, if (masked) cur | bit else cur & ~bit);
}

// ─── IOAPIC routing (GSI >= 16) ─────────────────────────────────────────────

/// First IDT vector handed to user-owned IOAPIC lines. The IDT dispatch
/// (idt.zig) routes vectors 100..127 to userdrv.handleUserIrq; the LAPIC
/// vectors (240+), NVMe MSI-X (242-245) and the yield trap (252) stay clear.
pub const USER_IRQ_VECTOR_BASE: u8 = 100;
pub const USER_IRQ_VECTOR_COUNT: u8 = 28; // vectors 100..127 → GSIs 16..43

/// Exclusive ceiling of routable GSIs: 16 when no IOAPIC was found (legacy
/// PIC behavior, byte-identical to v1), otherwise the smaller of the IOAPIC's
/// redirection-entry span and the user vector window.
fn maxRoutableGsi() u8 {
    if (comptime !is_x86) return 16;
    const ioapic = @import("../arch/x86_64/ioapic.zig");
    if (!ioapic.isAvailable()) return 16;
    const hw_ceiling: u32 = ioapic.gsiBase() + ioapic.maxRedirectionEntries();
    const vec_ceiling: u32 = 16 + USER_IRQ_VECTOR_COUNT;
    return @intCast(@min(hw_ceiling, vec_ceiling));
}

/// IDT vector a user-owned GSI >= 16 is routed to (inverse of the idt.zig
/// dispatch decode).
pub fn userIrqVector(gsi: u8) u8 {
    return USER_IRQ_VECTOR_BASE + (gsi - 16);
}

/// Program the hardware route for a freshly registered GSI. GSI < 16 keeps
/// the PIC path (byte-identical); >= 16 is programmed into the IOAPIC aimed
/// at the BSP LAPIC.
fn routeRegisteredGsi(gsi: u8) void {
    if (comptime !is_x86) return;
    if (gsi < 16) {
        picSetMask(gsi, false);
        return;
    }
    const ioapic = @import("../arch/x86_64/ioapic.zig");
    const acpi = @import("../acpi/acpi_parser.zig");
    const lapic = @import("../arch/x86_64/lapic.zig");
    const dest: u8 = if (acpi.info.cpu_count > 0)
        @truncate(acpi.info.cpu_apic_ids[0])
    else
        lapic.id();
    _ = ioapic.routeGsi(gsi, userIrqVector(gsi), dest);
}

/// Mask or unmask a released GSI at its interrupt controller.
fn setGsiMask(gsi: u8, masked: bool) void {
    if (comptime !is_x86) return;
    if (gsi < 16) {
        picSetMask(gsi, masked);
    } else {
        const ioapic = @import("../arch/x86_64/ioapic.zig");
        if (masked) ioapic.maskGsi(gsi) else ioapic.unmaskGsi(gsi);
    }
}

/// Unmap `pages` pages starting at `base` WITHOUT freeing their frames.
fn unmapNoFree(pml4: u64, base: u64, pages: u64) void {
    for (0..pages) |i| {
        _ = paging.unmapPage(pml4, base + i * 4096);
    }
}

// ─── dev_map_mmio ───────────────────────────────────────────────────────────

pub fn syscallDevMapMmio(phys: u64, size: u64) i64 {
    if (comptime !is_x86) return errno.ENOSYS;
    const cur = currentTask() orelse return errno.ESRCH;
    if (cap_check.requireCap(cur, "cap_sys_rawio") != 0) return errno.EPERM;

    const shape = core.validateMmioRequest(phys, size);
    if (shape != 0) return shape;

    const pages = (size + 4095) / 4096;
    // Reject anything the PMM knows as RAM: a user mapping of real memory
    // would both leak kernel data and corrupt the frame allocator on unmap.
    for (0..pages) |i| {
        if (pmm.isRamPhys(phys + i * 4096)) return errno.EACCES;
    }

    const base = mmap_mod.findFreeRangePub(cur, pages) orelse return errno.ENOMEM;
    if (!mmap_mod.canTrackRegionPub(cur, base, pages)) return errno.ENOMEM;

    const flags = paging.MapFlags{
        .writable = true,
        .user = true,
        .no_execute = true,
        .global = false,
        .write_through = true,
        .cache_disable = true,
    };
    var mapped: u64 = 0;
    while (mapped < pages) : (mapped += 1) {
        paging.mapPage(cur.page_table_phys, base + mapped * 4096, phys + mapped * 4096, flags) catch {
            unmapNoFree(cur.page_table_phys, base, mapped);
            return errno.ENOMEM;
        };
    }
    if (!mmap_mod.trackNoFreeRegion(cur, base, pages)) {
        unmapNoFree(cur.page_table_phys, base, pages);
        return errno.ENOMEM;
    }

    serial.writeString("[userdrv] mmio phys=0x");
    fmt.writeHex(phys);
    serial.writeString(" size=0x");
    fmt.writeHex(size);
    serial.writeString(" -> user 0x");
    fmt.writeHex(base);
    serial.writeString("\n");
    return @bitCast(base);
}

// ─── dev_irq_register / wait / unregister ───────────────────────────────────

pub fn syscallDevIrqRegister(gsi_u: u64) i64 {
    if (comptime !is_x86) return errno.ENOSYS;
    const cur = currentTask() orelse return errno.ESRCH;
    if (cap_check.requireCap(cur, "cap_sys_rawio") != 0) return errno.EPERM;
    if (gsi_u > 255) return errno.EINVAL;
    const gsi: u8 = @intCast(gsi_u);

    const flags = irq_lock.acquire();
    const result = irq_table.registerIrq(gsi, cur.self_idx, isKernelOwnedGsi(gsi), maxRoutableGsi());
    irq_lock.release(flags);

    _ = result catch |err| return switch (err) {
        error.Invalid => errno.ENODEV, // beyond PIC range and no IOAPIC route
        error.KernelOwned => errno.EBUSY,
        error.Busy => errno.EBUSY,
        error.Full => errno.EAGAIN,
    };

    routeRegisteredGsi(gsi);
    serial.writeString("[userdrv] irq gsi=");
    fmt.writeDecimal(gsi);
    serial.writeString(" registered\n");
    return 0;
}

pub fn syscallDevIrqWait(gsi_u: u64, timeout_ms: u64) i64 {
    if (comptime !is_x86) return errno.ENOSYS;
    const sig_mod = @import("../proc/signal.zig");
    const tsc = @import("../arch/x86_64/tsc.zig");
    const cur = currentTask() orelse return errno.ESRCH;
    if (cap_check.requireCap(cur, "cap_sys_rawio") != 0) return errno.EPERM;
    if (gsi_u > 255) return errno.EINVAL;
    const gsi: u8 = @intCast(gsi_u);

    var flags = irq_lock.acquire();
    const slot = irq_table.find(gsi) orelse {
        irq_lock.release(flags);
        return errno.EINVAL;
    };
    if (slot.owner_task != cur.self_idx) {
        irq_lock.release(flags);
        return errno.EINVAL;
    }
    const snapshot = slot.edge_count;
    irq_lock.release(flags);

    // Absolute TSC-ns deadline; timeout_ms == 0 polls once. The cap keeps the
    // ns multiply clear of u64 overflow.
    const capped_ms = @min(timeout_ms, 0xFFFF_FFFF);
    const deadline = tsc.nanos() + capped_ms * 1_000_000;

    while (true) {
        flags = irq_lock.acquire();
        const s = irq_table.find(gsi);
        const new_count: u64 = if (s) |sp| sp.edge_count else snapshot;
        irq_lock.release(flags);
        if (s == null) return errno.EINVAL; // unregistered while waiting
        if (new_count != snapshot) {
            const delta = new_count - snapshot;
            return @intCast(@min(delta, @as(u64, 0x7FFF_FFFF_FFFF_FFFF)));
        }

        // Signal protocol (mirrors proc/waitpid.zig): die on a fatal signal,
        // EINTR so a handler runs on return.
        if (sig_mod.pendingFatal(cur)) |sig| task_mod.exitTask(128 + @as(i32, @intCast(sig)));
        if (sig_mod.pendingActionable(cur)) return errno.EINTR;

        if (tsc.nanos() >= deadline) return errno.ETIMEDOUT;

        // Idle until the next interrupt (the IRQ edge itself, or the timer
        // tick that bounds the deadline). The task stays .running: the
        // scheduler may switch away at the tick and back — no wait queue.
        asm volatile ("sti");
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}

pub fn syscallDevIrqUnregister(gsi_u: u64) i64 {
    if (comptime !is_x86) return errno.ENOSYS;
    const cur = currentTask() orelse return errno.ESRCH;
    if (cap_check.requireCap(cur, "cap_sys_rawio") != 0) return errno.EPERM;
    if (gsi_u > 255) return errno.EINVAL;
    const gsi: u8 = @intCast(gsi_u);

    const flags = irq_lock.acquire();
    const ok = irq_table.unregisterIrq(gsi, cur.self_idx);
    irq_lock.release(flags);
    if (!ok) return errno.EINVAL;

    setGsiMask(gsi, true);
    serial.writeString("[userdrv] irq gsi=");
    fmt.writeDecimal(gsi);
    serial.writeString(" unregistered\n");
    return 0;
}

/// Interrupt-context hook called from idt.handleIrq BEFORE any kernel driver
/// handler. Returns true when the line is user-owned: the edge was counted
/// and the caller must EOI and skip the normal handlers.
pub fn handleUserIrq(irq: u8) bool {
    if (comptime !is_x86) return false;
    const flags = irq_lock.acquire();
    defer irq_lock.release(flags);
    return irq_table.recordEdge(irq);
}

// ─── dev_dma_alloc / dev_dma_free ───────────────────────────────────────────

fn freeDmaEntry(entry: *DmaAlloc) void {
    dma.freeCoherent(.{
        .virt_addr = 0, // unused by freeCoherent
        .phys_addr = entry.phys,
        .size = @as(usize, entry.pages) * 4096,
        .pages = entry.pages,
    });
    entry.active = false;
}

pub fn syscallDevDmaAlloc(size: u64, out_ptr: u64) i64 {
    if (comptime !is_x86) return errno.ENOSYS;
    const copy = @import("../mm/copy_from_user.zig");
    const cur = currentTask() orelse return errno.ESRCH;
    if (cap_check.requireCap(cur, "cap_sys_rawio") != 0) return errno.EPERM;

    const shape = core.validateDmaSize(size);
    if (shape != 0) return shape;
    if (!copy.validateUserBufferWritable(out_ptr, @sizeOf(DmaAllocInfo))) return errno.EFAULT;

    const pages: u32 = @intCast((size + 4095) / 4096);
    const buf = dma.allocCoherent(size) orelse return errno.ENOMEM;

    const base = mmap_mod.findFreeRangePub(cur, pages) orelse {
        dma.freeCoherent(buf);
        return errno.ENOMEM;
    };
    if (!mmap_mod.canTrackRegionPub(cur, base, pages)) {
        dma.freeCoherent(buf);
        return errno.ENOMEM;
    }

    // Reserve a per-task slot before mapping so every rollback path is simple.
    const dflags = dma_lock.acquire();
    var slot: ?*DmaAlloc = null;
    for (&dma_allocs[cur.self_idx]) |*e| {
        if (!e.active) {
            slot = e;
            break;
        }
    }
    if (slot == null) {
        dma_lock.release(dflags);
        dma.freeCoherent(buf);
        return errno.EAGAIN;
    }
    slot.?.* = .{ .active = true, .user_va = base, .phys = buf.phys_addr, .pages = pages };
    dma_lock.release(dflags);

    const flags = paging.MapFlags{
        .writable = true,
        .user = true,
        .no_execute = true,
        .global = false,
    };
    var mapped: u64 = 0;
    while (mapped < pages) : (mapped += 1) {
        paging.mapPage(cur.page_table_phys, base + mapped * 4096, buf.phys_addr + mapped * 4096, flags) catch {
            unmapNoFree(cur.page_table_phys, base, mapped);
            const f2 = dma_lock.acquire();
            slot.?.active = false;
            dma_lock.release(f2);
            dma.freeCoherent(buf);
            return errno.ENOMEM;
        };
    }
    if (!mmap_mod.trackNoFreeRegion(cur, base, pages)) {
        unmapNoFree(cur.page_table_phys, base, pages);
        const f2 = dma_lock.acquire();
        slot.?.active = false;
        dma_lock.release(f2);
        dma.freeCoherent(buf);
        return errno.ENOMEM;
    }

    const info = DmaAllocInfo{ .user_va = base, .phys = buf.phys_addr };
    const src: [*]const u8 = @ptrCast(&info);
    if (copy.copyToUser(@ptrFromInt(out_ptr), src[0..@sizeOf(DmaAllocInfo)], @sizeOf(DmaAllocInfo)) != @sizeOf(DmaAllocInfo)) {
        // Roll the whole allocation back — a half-written result is useless.
        unmapNoFree(cur.page_table_phys, base, pages);
        mmap_mod.untrackRangePub(cur, base, pages);
        const f3 = dma_lock.acquire();
        slot.?.active = false;
        dma_lock.release(f3);
        dma.freeCoherent(buf);
        return errno.EFAULT;
    }

    serial.writeString("[userdrv] dma size=0x");
    fmt.writeHex(size);
    serial.writeString(" phys=0x");
    fmt.writeHex(buf.phys_addr);
    serial.writeString(" -> user 0x");
    fmt.writeHex(base);
    serial.writeString("\n");
    return 0;
}

pub fn syscallDevDmaFree(va: u64) i64 {
    if (comptime !is_x86) return errno.ENOSYS;
    const cur = currentTask() orelse return errno.ESRCH;
    if (cap_check.requireCap(cur, "cap_sys_rawio") != 0) return errno.EPERM;

    const flags = dma_lock.acquire();
    var entry: ?*DmaAlloc = null;
    for (&dma_allocs[cur.self_idx]) |*e| {
        if (e.active and e.user_va == va) {
            entry = e;
            break;
        }
    }
    if (entry == null) {
        dma_lock.release(flags);
        return errno.EINVAL;
    }
    const e = entry.?.*;
    dma_lock.release(flags);

    // Unmap without freeing through the PMM path, drop the region bookkeeping,
    // then return the frames via the DMA allocator's own accounting.
    unmapNoFree(cur.page_table_phys, e.user_va, e.pages);
    mmap_mod.untrackRangePub(cur, e.user_va, e.pages);

    const f2 = dma_lock.acquire();
    for (&dma_allocs[cur.self_idx]) |*slot| {
        if (slot.active and slot.user_va == va) freeDmaEntry(slot);
    }
    dma_lock.release(f2);
    return 0;
}

// ─── /dev/pci snapshot ─────────────────────────────────────────────────────

/// Generate the /dev/pci listing into `out` (vfs read path).
pub fn pciGenerate(out: []u8) usize {
    const pci = @import("pci.zig");
    var infos: [pci.MAX_PCI_DEVICES]core.PciInfo = undefined;
    const n = pci.getDeviceCount();
    for (0..n) |i| {
        const d = pci.getDevice(@intCast(i)) orelse continue;
        infos[i] = .{
            .bus = d.bus,
            .device = d.device,
            .function = d.function,
            .vendor_id = d.vendor_id,
            .device_id = d.device_id,
            .class_code = d.class_code,
            .subclass = d.subclass,
            .irq_line = d.irq_line,
            .bars = d.bars,
            .bar_sizes = d.bar_sizes,
        };
    }
    return core.genPciListing(infos[0..n], out);
}

// ─── Task teardown ──────────────────────────────────────────────────────────

/// Release every user-driver resource owned by `t`: IRQ registrations (lines
/// re-masked), DMA buffers (frames returned via dma.freeCoherent), and MMIO
/// mappings (pages unmapped from `space_pml4` — their frames are device
/// registers, never PMM memory). Called by the reap/exec paths right before
/// destroyUserSpace; idempotent.
pub fn cleanupTask(t: *task_mod.Task, space_pml4: u64) void {
    if (comptime !is_x86) return;

    // IRQ registrations.
    var released: [core.MAX_IRQ_SLOTS]u8 = @splat(0);
    const flags = irq_lock.acquire();
    const n = irq_table.releaseAllForTask(t.self_idx, &released);
    irq_lock.release(flags);
    for (released[0..n]) |gsi| setGsiMask(gsi, true);

    // DMA buffers (unmap first if the address space is still there).
    const dflags = dma_lock.acquire();
    for (&dma_allocs[t.self_idx]) |*e| {
        if (!e.active) continue;
        if (space_pml4 != 0) unmapNoFree(space_pml4, e.user_va, e.pages);
        freeDmaEntry(e);
    }
    dma_lock.release(dflags);

    // MMIO (and any leftover no_free bookkeeping): unmap the pages so the
    // destroyUserSpace walk never sees — let alone frees — device frames.
    if (space_pml4 != 0) {
        for (&t.mmap_regions) |*r| {
            if (!r.active or !r.no_free) continue;
            unmapNoFree(space_pml4, r.base, r.num_pages);
            r.active = false;
        }
    }
}
