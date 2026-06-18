/// Swap — Virtual memory extension via disk-backed swap slots.
///
/// When physical memory is low, the kernel can swap out user pages to disk:
///   - Each swap slot holds one page (4KB)
///   - A bitmap tracks used/free slots
///   - PTE modification: swap-out sets present=0, stores swap slot in upper bits
///   - Page fault handler detects swap entry, reads page back from disk
///   - Clock/second-chance algorithm selects victim pages
///
/// PTE swap entry format (when present=0):
///   Bit 0:     present = 0
///   Bit 1:     swap marker = 1 (distinguishes from unmapped)
///   Bit 2:     preserved writable flag (from PTE bit 1)
///   Bit 3:     preserved COW flag (from PTE bit 9)
///   Bits 4-11: reserved
///   Bits 12-51: swap slot index (up to 2^40 slots = 4TB swap)
///   Bits 52-62: reserved
///   Bit 63:    NX (no-execute, preserved)
const serial = @import("../arch/x86_64/serial.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const idt = @import("../arch/x86_64/idt.zig");
const block_dev = @import("../drivers/block_dev.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const fmt = @import("../lib/fmt.zig");

const PAGE_SIZE: u64 = 4096;
const SWAP_MARKER_BIT: u64 = 0x2; // Bit 1 set = swap entry
const MAX_SWAP_SLOTS: u64 = 65536; // 256MB of swap
const SECTORS_PER_PAGE: u32 = 8; // 4KB / 512B

var swap_bitmap: [MAX_SWAP_SLOTS / 64]u64 = @splat(0); // 1024 u64 words = 8KB bitmap
var swap_lock: IrqSpinlock = .{};
var swap_dev: u8 = 0xFF; // Block device index for swap
var swap_start_lba: u64 = 0; // Starting LBA of swap area
var swap_enabled: bool = false;
var swap_used: u64 = 0;

// Clock hand for victim selection — encodes pml4_idx (0-255) as starting scan position
var clock_hand: u32 = 0;

pub fn isEnabled() bool {
    return swap_enabled;
}

pub fn getSwapUsed() u64 {
    return swap_used;
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
    serial.writeString("[swap] Enabled on device #");
    fmt.writeDecimal(dev);
    serial.writeString(" at LBA ");
    fmt.writeDecimal64(start_lba);
    serial.writeString(" capacity=");
    fmt.writeDecimal64(@min(swap_capacity_pages, MAX_SWAP_SLOTS));
    serial.writeString(" pages\n");
}

/// Allocate a swap slot. Returns slot index or null if full.
/// Uses u64 word-level scanning with @ctz for amortized O(1) allocation.
fn allocSlot() ?u64 {
    const flags = swap_lock.acquire();
    defer swap_lock.release(flags);

    for (&swap_bitmap, 0..) |*word_ptr, word_idx| {
        const word = word_ptr.*;
        if (word == ~@as(u64, 0)) continue; // all 64 bits used
        const free_bits = ~word;
        const bit: u6 = @intCast(@ctz(free_bits));
        word_ptr.* |= @as(u64, 1) << bit;
        swap_used += 1;
        return @as(u64, word_idx) * 64 + bit;
    }
    return null;
}

/// Free a swap slot.
fn freeSlot(slot: u64) void {
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
    return (pte & 1) == 0 and (pte & SWAP_MARKER_BIT) != 0;
}

/// Encode a swap slot index into a PTE swap entry.
pub fn encodeSwapEntry(slot: u64) u64 {
    return SWAP_MARKER_BIT | (slot << 12);
}

/// Extract the swap slot index from a PTE swap entry.
pub fn decodeSwapEntry(pte: u64) u64 {
    return (pte >> 12) & 0xFFFF_FFFF_F; // 40 bits
}

/// Swap out a page: write its contents to a swap slot and update PTE.
/// Returns true on success.
pub fn swapOut(pml4_phys: u64, virt_addr: u64, pte_ptr: *u64) bool {
    if (!swap_enabled) return false;
    _ = pml4_phys;

    const pte = pte_ptr.*;
    if ((pte & 1) == 0) return false; // Not present
    if (pte & (1 << 7) != 0) return false; // Don't swap huge pages

    const phys_addr = pte & 0xFFFF_FFFF_F000;

    // Allocate swap slot
    const slot = allocSlot() orelse {
        serial.writeString("[swap] No free swap slots\n");
        return false;
    };

    // Write page to disk
    const lba = swap_start_lba + slot * SECTORS_PER_PAGE;
    const page_data: [*]const u8 = @ptrFromInt(hhdm.physToVirt(phys_addr));

    const result = block_dev.writeSectors(swap_dev, lba, SECTORS_PER_PAGE, page_data);
    if (result != 0) {
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

    // Free the physical page
    pmm.freePage(phys_addr);

    // Flush TLB for this address
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (virt_addr),
    );

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
pub fn reclaimPages(pml4_phys: u64, target: u32) u32 {
    if (!swap_enabled) return 0;

    var swapped: u32 = 0;
    const pml4: [*]u64 = @ptrFromInt(hhdm.physToVirt(pml4_phys));

    // v53.11: Start from clock_hand and wrap around — ensures fair page reclaim across address space
    for (0..256) |offset| {
        if (swapped >= target) break;
        const pml4_idx = (clock_hand + @as(u32, @intCast(offset))) % 256;
        if (pml4[pml4_idx] & 1 == 0) continue;

        const pdpt_phys = pml4[pml4_idx] & 0xFFFF_FFFF_F000;
        const pdpt: [*]u64 = @ptrFromInt(hhdm.physToVirt(pdpt_phys));

        for (0..512) |pdpt_idx| {
            if (swapped >= target) break;
            if (pdpt[pdpt_idx] & 1 == 0) continue;

            const pd_phys = pdpt[pdpt_idx] & 0xFFFF_FFFF_F000;
            const pd: [*]u64 = @ptrFromInt(hhdm.physToVirt(pd_phys));

            for (0..512) |pd_idx| {
                if (swapped >= target) break;
                if (pd[pd_idx] & 1 == 0) continue;

                const pt_phys = pd[pd_idx] & 0xFFFF_FFFF_F000;
                const pt: [*]u64 = @ptrFromInt(hhdm.physToVirt(pt_phys));

                for (0..512) |pt_idx| {
                    if (swapped >= target) break;
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
                    const virt_addr = (@as(u64, pml4_idx) << 39) |
                        (@as(u64, pdpt_idx) << 30) |
                        (@as(u64, pd_idx) << 21) |
                        (@as(u64, pt_idx) << 12);

                    if (swapOut(pml4_phys, virt_addr, &pt[pt_idx])) {
                        swapped += 1;
                        // v53.11: Advance clock hand — next reclaim starts from here
                        clock_hand = (pml4_idx + 1) % 256;
                    }
                }
            }
        }
    }

    if (swapped > 0) {
        serial.writeString("[swap] Reclaimed ");
        fmt.writeDecimal(swapped);
        serial.writeString(" pages\n");
    }

    return swapped;
}
