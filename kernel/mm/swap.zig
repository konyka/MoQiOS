/// Swap — Virtual memory extension via disk-backed swap slots.
///
/// When physical memory is low, the kernel can swap out user pages to disk:
///   - Each swap slot holds one page (4KB)
///   - A bitmap tracks used/free slots
///   - PTE modification: swap-out sets present=0, stores swap slot in upper bits
///   - Page fault handler detects swap entry, reads page back from disk
///   - Clock/second-chance algorithm selects victim pages
///
/// PTE swap entry format (when present=0) — see mm/pte_kind.zig for the full
/// non-present-entry taxonomy:
///   Bit 0:     present = 0
///   Bit 1:     (free — the pre-§6.48 marker; it collided with the writable
///              bit a PROT_NONE reservation preserves, so the marker moved)
///   Bit 2:     preserved writable flag (from PTE bit 1)
///   Bit 3:     preserved COW flag (from PTE bit 9)
///   Bits 4-10: reserved
///   Bit 11:    swap marker = 1 (distinguishes from unmapped/PROT_NONE)
///   Bits 12-51: swap slot index (up to 2^40 slots = 4TB swap)
///   Bits 52-62: reserved
///   Bit 63:    NX (no-execute, preserved)
const serial = @import("../arch/arch.zig").serial;
const tlb = @import("../arch/arch.zig").tlb;
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const Mm = @import("../mm/mm.zig").Mm;
const idt = @import("../arch/arch.zig").interrupts;
const block_dev = @import("../drivers/block_dev.zig");
const swap_policy = @import("swap_policy.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const fmt = @import("../lib/fmt.zig");

// swap_policy is a pure (host-tested) module and must not import the driver
// layer, so its DevKind mirrors BlockDevType's ordinals; keep them in sync.
comptime {
    if (@intFromEnum(block_dev.BlockDevType.nvme) != @intFromEnum(swap_policy.DevKind.nvme) or
        @intFromEnum(block_dev.BlockDevType.ahci) != @intFromEnum(swap_policy.DevKind.ahci) or
        @intFromEnum(block_dev.BlockDevType.virtio_blk) != @intFromEnum(swap_policy.DevKind.virtio_blk))
        @compileError("swap_policy.DevKind ordinals must mirror block_dev.BlockDevType");
}

const PAGE_SIZE: u64 = 4096;
const pte_kind = @import("pte_kind.zig");
const MAX_SWAP_SLOTS: u64 = 65536; // 256MB of swap
const SECTORS_PER_PAGE: u32 = 8; // 4KB / 512B

var swap_bitmap: [MAX_SWAP_SLOTS / 64]u64 = @splat(0); // 1024 u64 words = 8KB bitmap
var swap_lock: IrqSpinlock = .{};
var swap_dev: u8 = 0xFF; // Block device index for swap
var swap_start_lba: u64 = 0; // Starting LBA of swap area
var swap_enabled: bool = false;
var swap_used: u64 = 0;
// Effective slot count: min(MAX_SWAP_SLOTS, device capacity). Allocations
// beyond the device's last page would write past the end of the disk — the
// AHCI driver reports an NCQ error and the write fails (hello96 SMP=4 RED:
// in-flight swap-out exceeded the 64MiB scratch disk's 16384 pages).
var swap_slot_limit: u64 = 0;
var slot_full_logged: bool = false;

// Clock hand for victim selection — encodes pml4_idx (0-255) as starting scan position
var clock_hand: u32 = 0;

pub fn isEnabled() bool {
    return swap_enabled;
}

pub fn getSwapUsed() u64 {
    return swap_used;
}

/// Total slot capacity while swap is enabled (min of device pages and
/// MAX_SWAP_SLOTS), 0 when disabled — backs sysinfo's totalswap/freeswap.
pub fn getSwapCapacity() u64 {
    return if (swap_enabled) swap_slot_limit else 0;
}

/// Initialize swap on a block device at a given LBA offset.
pub fn init(dev: u8, start_lba: u64) void {
    swap_dev = dev;
    swap_start_lba = start_lba;
    swap_enabled = true;
    @memset(&swap_bitmap, 0);
    swap_used = 0;
    clock_hand = 0;

    const info = block_dev.getDeviceInfo(dev) orelse {
        serial.writeString("[swap] Device info not available\n");
        swap_enabled = false;
        return;
    };

    const swap_capacity_pages = info.total_sectors / SECTORS_PER_PAGE;
    swap_slot_limit = @min(swap_capacity_pages, MAX_SWAP_SLOTS);
    serial.writeString("[swap] Enabled on device #");
    fmt.writeDecimal(dev);
    serial.writeString(" at LBA ");
    fmt.writeDecimal64(start_lba);
    serial.writeString(" capacity=");
    fmt.writeDecimal64(swap_slot_limit);
    serial.writeString(" pages\n");
}

/// Allocate a swap slot. Returns slot index or null if full.
/// Uses u64 word-level scanning with @ctz for amortized O(1) allocation.
/// Never hands out a slot at or past swap_slot_limit (the device's actual
/// page capacity) — such a slot would address sectors past the end of the disk.
fn allocSlot() ?u64 {
    const flags = swap_lock.acquire();
    defer swap_lock.release(flags);

    const limit_words = (swap_slot_limit + 63) / 64;
    for (&swap_bitmap, 0..) |*word_ptr, word_idx| {
        if (word_idx >= limit_words) break;
        var free_bits = ~word_ptr.*;
        // Mask off bits past the device capacity in the final partial word.
        if (word_idx == limit_words - 1 and swap_slot_limit % 64 != 0) {
            free_bits &= (@as(u64, 1) << @intCast(swap_slot_limit % 64)) - 1;
        }
        if (free_bits == 0) continue;
        const bit: u6 = @intCast(@ctz(free_bits));
        word_ptr.* |= @as(u64, 1) << bit;
        swap_used += 1;
        return @as(u64, word_idx) * 64 + bit;
    }
    return null;
}

/// Free a swap slot. Also called by PTE teardown (munmap/exit) for swap
/// entries that are destroyed without being swapped back in (§6.49) — a slot
/// has exactly one owning PTE (fork never copies non-present entries), so
/// teardown frees it exactly once.
pub fn freeSlot(slot: u64) void {
    const flags = swap_lock.acquire();
    defer swap_lock.release(flags);

    const word_idx = slot / 64;
    const bit: u6 = @intCast(slot % 64);
    if (word_idx < MAX_SWAP_SLOTS / 64) {
        swap_bitmap[word_idx] &= ~(@as(u64, 1) << bit);
        if (swap_used > 0) swap_used -= 1;
    }
}

/// Check if a PTE is a swap entry.
pub fn isSwapEntry(pte: u64) bool {
    return pte_kind.classify(pte) == .swap;
}

/// Encode a swap slot index into a PTE swap entry.
pub fn encodeSwapEntry(slot: u64) u64 {
    return pte_kind.encodeSwapEntry(slot);
}

/// Extract the swap slot index from a PTE swap entry.
pub fn decodeSwapEntry(pte: u64) u64 {
    return pte_kind.decodeSwapEntry(pte);
}

/// Swap out a page: write its contents to a swap slot and update PTE.
/// Returns true on success.
///
/// v53.15: two-phase writeback. The PTE is first downgraded to read-only and
/// stale writable translations are shot down (ranged invlpg) BEFORE the page
/// is copied to disk. The whole reclaim scan holds the mm's vm_lock, so
/// same-mm fault handlers cannot observe the intermediate state; a
/// concurrent plain user WRITE on a sibling CPU (which takes no lock)
/// instead faults on the read-only page, waits on vm_lock until the scan
/// completes, then swap-in restores the page and the write lands
/// (handleCowFault re-reads the PTE under the guard and retries on a
/// non-present entry). Without the downgrade, stores landing after the disk
/// copy are silently lost — hello96 RED: a swapped CLONE_VM thread stack
/// came back stale and the thread returned to RIP=0.
///
/// (A batched variant with coalesced multi-page NCQ writes was tried for TCG
/// speed and reverted: it regressed SMP=4 — see §6.45 residuals.)
fn swapOut(pml4_phys: u64, virt_addr: u64, pte_ptr: *u64) bool {
    if (!swap_enabled) return false;

    const pte = pte_ptr.*;
    if ((pte & 1) == 0) return false; // Not present
    if (pte & (1 << 7) != 0) return false; // Don't swap huge pages

    const phys_addr = pte & 0xFFFF_FFFF_F000;

    // Allocate swap slot
    const slot = allocSlot() orelse {
        // Once-only: a full swap area is a steady state under sustained
        // pressure, not a per-attempt event worth logging.
        if (!@atomicRmw(bool, &slot_full_logged, .Xchg, true, .acq_rel))
            serial.writeString("[swap] No free swap slots\n");
        return false;
    };

    // Phase 1: revoke write access before the copy. Bit 1 is the writable bit
    // for present pages (the swap marker lives at bit 11 once present=0).
    pte_ptr.* = pte & ~@as(u64, 0x2);
    tlb.shootdownRange(virt_addr, 1, pml4_phys);

    // Write page to disk
    const lba = swap_start_lba + slot * SECTORS_PER_PAGE;
    const page_data: [*]const u8 = @ptrFromInt(hhdm.physToVirt(phys_addr));

    const result = block_dev.writeSectors(swap_dev, lba, SECTORS_PER_PAGE, page_data);
    if (result != 0) {
        // Roll back the downgrade.
        pte_ptr.* = pte;
        tlb.shootdownRange(virt_addr, 1, pml4_phys);
        freeSlot(slot);
        serial.writeString("[swap] Write failed\n");
        return false;
    }

    // Update PTE: clear present bit, set swap entry
    const swap_pte = encodeSwapEntry(slot);
    // v53.3: preserve NX bit (bit 63), writable bit (bit 1), and COW bit (bit 9)
    // Store in swap entry reserved bits: writable → bit 2, COW → bit 3
    const nx_bit = pte & (1 << 63);
    const writable_bit = if ((pte & 0x02) != 0) @as(u64, 1 << 2) else @as(u64, 0);
    const cow_bit = if ((pte & (1 << 9)) != 0) @as(u64, 1 << 3) else @as(u64, 0);
    pte_ptr.* = swap_pte | nx_bit | writable_bit | cow_bit;

    // Cross-CPU shootdown BEFORE releasing the frame: tasks sharing this page
    // table (CLONE_VM) on remote CPUs would otherwise keep stale TLB entries
    // into freed memory. Mirrors the collect→shootdown→free ordering in
    // unmapRange.
    tlb.shootdownRange(virt_addr, 1, pml4_phys);

    // Free the physical page
    pmm.freePage(phys_addr);

    return true;
}

/// Swap in a page: read from swap slot into a new physical page.
/// Returns the new PTE value (with present=1).
pub fn swapIn(pte_val: u64) ?u64 {
    if (!isSwapEntry(pte_val)) return null;

    const slot = decodeSwapEntry(pte_val);

    // Allocate a new physical page
    const new_phys = pmm.allocPage() orelse {
        serial.writeString("[swap] OOM during swap-in\n");
        return null;
    };

    // Read page from disk
    const lba = swap_start_lba + slot * SECTORS_PER_PAGE;
    const page_data: [*]u8 = @ptrFromInt(hhdm.physToVirt(new_phys));

    const result = block_dev.readSectors(swap_dev, lba, SECTORS_PER_PAGE, page_data);
    if (result != 0) {
        pmm.freePage(new_phys);
        serial.writeString("[swap] Read failed\n");
        return null;
    }

    // Free the swap slot
    freeSlot(slot);

    // Reconstruct PTE: present=1, user=1, restore original writable and COW
    // v53.3: read preserved bits from swap entry reserved bits 2-3
    const nx_bit = pte_val & (1 << 63);
    const writable_bit = if ((pte_val & (1 << 2)) != 0) @as(u64, 0x02) else @as(u64, 0);
    const cow_bit = if ((pte_val & (1 << 3)) != 0) @as(u64, 1 << 9) else @as(u64, 0);
    const new_pte = new_phys | 0x05 | writable_bit | cow_bit | nx_bit; // Present + User + (restored writable/COW) + NX

    return new_pte;
}


/// Attempt to reclaim pages when memory is low.
/// Scans user page tables for candidate pages to swap out.
/// Returns the number of pages swapped out.
/// v53.11: Uses clock_hand for persistent scan position — distributes swap pressure across address space.
/// v53.14: Two-pass scan — pass 1 clears Accessed bits (second chance), pass 2 swaps
/// pages whose Accessed bits were cleared. Prevents OOM when working set is large.
///
/// The whole two-pass scan runs under `mm`'s vm_lock: the PTE writes below
/// (Accessed-clear in reclaimScanPass, swap-entry install in swapOut)
/// otherwise race sibling fault handlers and unmapRange on CLONE_VM-shared
/// page tables. The guard is non-blocking (beginReclaimCritical): contention
/// skips the scan, and the fault → swapIn → allocPage recursion proceeds
/// unguarded under the lock the current task already holds.
pub fn reclaimPages(mm: *Mm, owner: *const anyopaque, target: u32) u32 {
    if (!swap_enabled) return 0;

    var guard = Mm.beginReclaimCritical(mm, owner) orelse return 0;
    defer guard.release();

    var swapped: u32 = 0;

    var pass: u32 = 0;
    while (pass < 2 and swapped < target) : (pass += 1) {
        swapped += reclaimScanPass(mm, target - swapped);
    }

    if (swapped > 0) {
        serial.writeString("[swap] Reclaimed ");
        fmt.writeDecimal(swapped);
        serial.writeString(" pages\n");
    }

    return swapped;
}

/// Single-pass scan for reclaimable pages.
/// v53.13: MAX_PTE_SCAN limits total PTEs scanned per pass to avoid blocking allocPage caller.
/// Caller must hold `mm`'s vm_lock (via reclaimPages' beginReclaimCritical).
fn reclaimScanPass(mm: *Mm, target: u32) u32 {
    const pml4_phys = mm.page_table_phys;
    var swapped: u32 = 0;
    var pte_scanned: u32 = 0;
    const MAX_PTE_SCAN: u32 = 65536; // ~256MB of virtual address space per reclaim pass
    const pml4: [*]u64 = @ptrFromInt(hhdm.physToVirt(pml4_phys));

    // v53.11: Start from clock_hand and wrap around — ensures fair page reclaim across address space
    // v53.12: Use atomic access for SMP safety
    const hand = @atomicLoad(u32, &clock_hand, .acquire);
    for (0..256) |offset| {
        if (swapped >= target) break;
        const pml4_idx = (hand + @as(u32, @intCast(offset))) % 256;
        if (pml4[pml4_idx] & 1 == 0) continue;

        const pdpt_phys = pml4[pml4_idx] & 0xFFFF_FFFF_F000;
        const pdpt: [*]u64 = @ptrFromInt(hhdm.physToVirt(pdpt_phys));

        for (0..512) |pdpt_idx| {
            if (swapped >= target) break;
            if (pte_scanned >= MAX_PTE_SCAN) break; // v53.13: Scan limit
            if (pdpt[pdpt_idx] & 1 == 0) continue;
            if (pdpt[pdpt_idx] & (1 << 7) != 0) continue; // 1GB huge page — a data frame, not a PD

            const pd_phys = pdpt[pdpt_idx] & 0xFFFF_FFFF_F000;
            const pd: [*]u64 = @ptrFromInt(hhdm.physToVirt(pd_phys));

            for (0..512) |pd_idx| {
                if (swapped >= target) break;
                if (pte_scanned >= MAX_PTE_SCAN) break; // v53.13: Scan limit
                if (pd[pd_idx] & 1 == 0) continue;
                // I1: a 2MB huge PDE is a data frame, not a PT — descending
                // would read the block's contents as PTEs. Huge pages are
                // deliberately excluded from swap/reclaim (documented in
                // docs/kernel-subsystems.md): demoting under memory pressure
                // would need a PT allocation exactly when none is available.
                if (pd[pd_idx] & (1 << 7) != 0) continue;

                const pt_phys = pd[pd_idx] & 0xFFFF_FFFF_F000;
                const pt: [*]u64 = @ptrFromInt(hhdm.physToVirt(pt_phys));

                for (0..512) |pt_idx| {
                    if (swapped >= target) break;
                    if (pte_scanned >= MAX_PTE_SCAN) break; // v53.13: Scan limit
                    pte_scanned += 1;
                    const pte = pt[pt_idx];
                    if ((pte & 1) == 0) continue; // Not present
                    if (pte & (1 << 63) == 0) continue; // v53.6: Skip executable pages (NX=0 means code, NX=1 means data — swap data pages only)
                    // v53.11: Don't skip dirty pages — swapOut saves page content (dirty or not) to swap slot.
                    // Previously dirty pages were skipped making swap ineffective for modified anonymous pages.

                    // Second-chance: check accessed bit
                    if (pte & (1 << 5) != 0) {
                        // Accessed — clear the bit and skip
                        pt[pt_idx] = pte & ~@as(u64, 1 << 5);
                        continue;
                    }

                    // Candidate for swap-out
                    // G2: skip shared frames — COW clones and file-backed
                    // (page-cache/tmpfs) mappings hold references beyond the
                    // page table's own. Swapping one would write file content
                    // to swap and strand the other owners' references; a
                    // clean file page can simply be re-faulted from its
                    // backing store instead.
                    if (pmm.getRefCount(pte & 0xFFFF_FFFF_F000) > 1) continue;

                    const virt_addr = (@as(u64, pml4_idx) << 39) |
                        (@as(u64, pdpt_idx) << 30) |
                        (@as(u64, pd_idx) << 21) |
                        (@as(u64, pt_idx) << 12);

                    if (swapOut(pml4_phys, virt_addr, &pt[pt_idx])) {
                        swapped += 1;
                        // v53.12: Advance clock hand atomically — next reclaim starts from here
                        @atomicStore(u32, &clock_hand, (pml4_idx + 1) % 256, .release);
                    }
                }
            }
        }
    }

    return swapped;
}
