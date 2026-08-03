/// x86_64 4-level paging — PML4 → PDPT → PD → PT.
/// Provides map/unmap operations for 4KB and 2MB pages.
const hhdm = @import("../../mm/hhdm.zig");
const pmm = @import("../../mm/pmm.zig");
const serial = @import("serial.zig");
const fmt = @import("../../lib/fmt.zig");
const cow_pte = @import("../../mm/cow_pte.zig");

pub const PAGE_SIZE: u64 = 4096;
pub const PAGE_2MB: u64 = 2 * 1024 * 1024;

// PTE flag constants (for raw u64 page table access)
pub const PRESENT: u64 = 1 << 0;
pub const WRITABLE: u64 = 1 << 1;
pub const USER: u64 = 1 << 2;
pub const ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000; // Physical address mask

// --- Page Table Entry ---
pub const PTE = packed struct(u64) {
    present: bool = false,
    writable: bool = false,
    user: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    huge_page: bool = false,
    global: bool = false,
    os_bits: u3 = 0,
    phys_frame: u40 = 0,
    reserved: u11 = 0,
    no_execute: bool = false,

    pub fn getPhysAddr(self: PTE) u64 {
        return @as(u64, self.phys_frame) << 12;
    }

    pub fn setPhysAddr(self: *PTE, phys: u64) void {
        self.phys_frame = @truncate(phys >> 12);
    }
};

pub const PageTable = struct {
    entries: [512]PTE,
};

pub const MapFlags = struct {
    writable: bool = false,
    user: bool = false,
    no_execute: bool = true,
    global: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
};

var kernel_pml4_phys: u64 = 0;

pub fn init() void {
    kernel_pml4_phys = readCR3();
    serial.writeString("[paging] Kernel PML4 at phys 0x");
    fmt.writeHex(kernel_pml4_phys);
    serial.writeString("\n");
}

pub fn getKernelPml4() u64 {
    return kernel_pml4_phys;
}

/// SK-40: root table currently loaded in the MMU (CR3), for the portable
/// copy_from_user facade.
pub fn currentRoot() u64 {
    return readCR3() & ADDR_MASK;
}

/// SK-40: true when `virt` is mapped user-accessible under `root_phys`.
/// Same check copy_from_user did inline: walk present, U/S bit set.
pub fn isUserAccessible(root_phys: u64, virt: u64) bool {
    const pte = getPageEntry(root_phys, virt) orelse return false;
    return pte.user;
}

/// Whether the kernel may write to this user page.
///
/// A copy-on-write page counts as writable: the store faults, and the fault
/// handler un-shares the frame and retries. A page that is neither writable nor
/// COW is genuinely read-only, and writing it takes a supervisor-mode
/// write-protect fault the kernel has no recovery path for — so callers must be
/// able to reject the destination instead.
pub fn isUserWritable(root_phys: u64, virt: u64) bool {
    const pte = getPageEntry(root_phys, virt) orelse return false;
    if (!pte.user) return false;
    if (pte.writable) return true;
    return cow_pte.isCow(@as(u64, @bitCast(pte.*)));
}

/// SK-40: bracket kernel touches of user pages. No-ops on x86 (SMAP is not
/// enabled); riscv64 toggles sstatus.SUM here.
pub fn userAccessBegin() void {}
pub fn userAccessEnd() void {}

/// Map a 4KB virtual page to a physical frame.
pub fn mapPage(pml4_phys: u64, virt: u64, phys: u64, flags: MapFlags) !void {
    try mapPageInner(pml4_phys, virt, phys, flags, true);
}

/// Map a page without TLB invalidation — for building new page tables
/// that aren't yet loaded in CR3. The caller must do reloadCR3() or
/// CR3 switch after all mappings are complete.
pub fn mapPageNoFlush(pml4_phys: u64, virt: u64, phys: u64, flags: MapFlags) !void {
    try mapPageInner(pml4_phys, virt, phys, flags, false);
}

/// PCID safety gate: user mappings must NEVER carry the global bit. Global
/// entries survive CR3 writes (legacy and PCID no-flush alike) and are
/// visible in every process context — a global user page would leak one
/// process's translation into every other address space. All in-tree user
/// mapping sites pass .global = false; halt loudly if that ever regresses.
fn assertNotGlobalUser(flags: MapFlags) void {
    if (flags.user and flags.global) {
        serial.writeString("[paging] FATAL: user page mapped with global bit (breaks PCID isolation)\n");
        asm volatile ("cli");
        while (true) asm volatile ("hlt");
    }
}

/// Internal map implementation. `flush_tlb` controls whether invlpg is called.
fn mapPageInner(pml4_phys: u64, virt: u64, phys: u64, flags: MapFlags, flush_tlb: bool) !void {
    assertNotGlobalUser(flags);
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;
    const pt_idx = (virt >> 12) & 0x1FF;

    const pml4: *PageTable = hhdm.physToPtr(PageTable, pml4_phys);
    const pdpt_phys = try ensureTable(&pml4.entries[pml4_idx]);

    const pdpt: *PageTable = hhdm.physToPtr(PageTable, pdpt_phys);
    const pd_phys = try ensureTable(&pdpt.entries[pdpt_idx]);

    const pd: *PageTable = hhdm.physToPtr(PageTable, pd_phys);
    const pt_phys = try ensureTable(&pd.entries[pd_idx]);

    const pt: *PageTable = hhdm.physToPtr(PageTable, pt_phys);
    var pte = &pt.entries[pt_idx];

    pte.* = .{
        .present = true,
        .writable = flags.writable,
        .user = flags.user,
        .no_execute = flags.no_execute,
        .global = flags.global,
        .write_through = flags.write_through,
        .cache_disable = flags.cache_disable,
    };
    pte.setPhysAddr(phys);
    if (flush_tlb) invlpg(virt);
}

/// Check if a virtual address is already mapped (present in page tables).
/// Returns true if the page is mapped (either as a 4KB page or 2MB huge page).
pub fn isPageMapped(pml4_phys: u64, virt: u64) bool {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;
    const pt_idx = (virt >> 12) & 0x1FF;

    const pml4: *PageTable = hhdm.physToPtr(PageTable, pml4_phys);
    const pml4e = pml4.entries[pml4_idx];
    if (!pml4e.present) return false;

    const pdpt: *PageTable = hhdm.physToPtr(PageTable, pml4e.getPhysAddr());
    const pdpte = pdpt.entries[pdpt_idx];
    if (!pdpte.present) return false;
    if (pdpte.huge_page) return true; // 1GB page

    const pd: *PageTable = hhdm.physToPtr(PageTable, pdpte.getPhysAddr());
    const pde = pd.entries[pd_idx];
    if (!pde.present) return false;
    if (pde.huge_page) return true; // 2MB huge page

    const pt: *PageTable = hhdm.physToPtr(PageTable, pde.getPhysAddr());
    return pt.entries[pt_idx].present;
}

/// Map a 2MB huge page via PD entry (no PT needed).
pub fn mapHugePage(pml4_phys: u64, virt: u64, phys: u64, flags: MapFlags) !void {
    assertNotGlobalUser(flags);
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;

    const pml4: *PageTable = hhdm.physToPtr(PageTable, pml4_phys);
    const pdpt_phys = try ensureTable(&pml4.entries[pml4_idx]);

    const pdpt: *PageTable = hhdm.physToPtr(PageTable, pdpt_phys);
    const pd_phys = try ensureTable(&pdpt.entries[pdpt_idx]);

    const pd: *PageTable = hhdm.physToPtr(PageTable, pd_phys);
    var pde = &pd.entries[pd_idx];

    pde.* = .{
        .present = true,
        .writable = flags.writable,
        .user = flags.user,
        .no_execute = flags.no_execute,
        .global = flags.global,
        .write_through = flags.write_through,
        .cache_disable = flags.cache_disable,
        .huge_page = true,
    };
    pde.setPhysAddr(phys);
    invlpg(virt);
}

/// Unmap a virtual page. Returns the physical address of the unmapped page, or null.
pub fn unmapPage(pml4_phys: u64, virt: u64) ?u64 {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;
    const pt_idx = (virt >> 12) & 0x1FF;

    const pml4: *PageTable = hhdm.physToPtr(PageTable, pml4_phys);
    if (!pml4.entries[pml4_idx].present) return null;

    const pdpt: *PageTable = hhdm.physToPtr(PageTable, pml4.entries[pml4_idx].getPhysAddr());
    if (!pdpt.entries[pdpt_idx].present) return null;
    // A huge-page entry is a data frame, NOT a next-level page table —
    // descending would treat RAM data as a page table and free arbitrary
    // physical memory. Refuse, like isPageMapped/getPageEntry do.
    if (pdpt.entries[pdpt_idx].huge_page) return null; // 1GB page

    const pd: *PageTable = hhdm.physToPtr(PageTable, pdpt.entries[pdpt_idx].getPhysAddr());
    if (!pd.entries[pd_idx].present) return null;
    if (pd.entries[pd_idx].huge_page) return null; // 2MB page

    const pt: *PageTable = hhdm.physToPtr(PageTable, pd.entries[pd_idx].getPhysAddr());
    if (!pt.entries[pt_idx].present) return null;
    const phys = pt.entries[pt_idx].getPhysAddr();
    pt.entries[pt_idx] = .{}; // Zero = not present
    invlpg(virt);
    return phys;
}

/// Ensure a page table exists at the given PTE, allocating if needed.
fn ensureTable(pte: *PTE) !u64 {
    if (pte.present) {
        // A present huge-page entry is a data frame, NOT a next-level page
        // table. Descending into it would treat RAM data as a page table and
        // corrupt memory (this used to crash early boot). Refuse instead so
        // callers fail loudly rather than silently corrupting the address
        // space. Splitting huge pages on demand is not supported here.
        if (pte.huge_page) return error.HugePagePresent;
        return pte.getPhysAddr();
    }
    const phys = pmm.allocPage() orelse return error.OutOfMemory;
    // Zero the new table
    const table: *PageTable = hhdm.physToPtr(PageTable, phys);
    const bytes: [*]u8 = @ptrCast(table);
    @memset(bytes[0..@sizeOf(PageTable)], 0);
    pte.* = .{ .present = true, .writable = true, .user = true };
    pte.setPhysAddr(phys);

    return phys;
}

fn readCR3() u64 {
    return asm volatile ("mov %%cr3, %[val]"
        : [val] "=r" (-> u64),
    );
}

pub fn invlpg(virt: u64) void {
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (virt),
    );
}

pub fn reloadCR3() void {
    asm volatile (
        \\mov %%cr3, %%rax
        \\mov %%rax, %%cr3
        ::: .{ .rax = true });
}

/// Get a mutable pointer to the PTE for a given virtual address.
/// Returns null if any level of the page table walk encounters a not-present entry.
pub fn getPageEntry(pml4_phys: u64, virt: u64) ?*PTE {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;
    const pt_idx = (virt >> 12) & 0x1FF;

    const pml4: *PageTable = hhdm.physToPtr(PageTable, pml4_phys);
    if (!pml4.entries[pml4_idx].present) return null;

    const pdpt: *PageTable = hhdm.physToPtr(PageTable, pml4.entries[pml4_idx].getPhysAddr());
    if (!pdpt.entries[pdpt_idx].present) return null;
    if (pdpt.entries[pdpt_idx].huge_page) return null; // 1GB page

    const pd: *PageTable = hhdm.physToPtr(PageTable, pdpt.entries[pdpt_idx].getPhysAddr());
    if (!pd.entries[pd_idx].present) return null;
    if (pd.entries[pd_idx].huge_page) return null; // 2MB page

    const pt: *PageTable = hhdm.physToPtr(PageTable, pd.entries[pd_idx].getPhysAddr());
    if (!pt.entries[pt_idx].present) return null;

    return &pt.entries[pt_idx];
}

/// Get the raw PTE value for a virtual address, even if not present.
/// Returns null if the page table structure itself doesn't exist.
pub fn getPageEntryRaw(pml4_phys: u64, virt: u64) ?u64 {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;
    const pt_idx = (virt >> 12) & 0x1FF;

    const pml4: *PageTable = hhdm.physToPtr(PageTable, pml4_phys);
    if (!pml4.entries[pml4_idx].present) return null;

    const pdpt: *PageTable = hhdm.physToPtr(PageTable, pml4.entries[pml4_idx].getPhysAddr());
    if (!pdpt.entries[pdpt_idx].present) return null;

    const pd: *PageTable = hhdm.physToPtr(PageTable, pdpt.entries[pdpt_idx].getPhysAddr());
    if (!pd.entries[pd_idx].present) return null;

    const pt: *PageTable = hhdm.physToPtr(PageTable, pd.entries[pd_idx].getPhysAddr());
    // Return the raw value even if not present
    return @bitCast(pt.entries[pt_idx]);
}

/// Set the raw PTE value for a virtual address.
pub fn setPageEntryRaw(pml4_phys: u64, virt: u64, value: u64) void {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;
    const pt_idx = (virt >> 12) & 0x1FF;

    const pml4: *PageTable = hhdm.physToPtr(PageTable, pml4_phys);
    if (!pml4.entries[pml4_idx].present) return;

    const pdpt: *PageTable = hhdm.physToPtr(PageTable, pml4.entries[pml4_idx].getPhysAddr());
    if (!pdpt.entries[pdpt_idx].present) return;

    const pd: *PageTable = hhdm.physToPtr(PageTable, pdpt.entries[pdpt_idx].getPhysAddr());
    if (!pd.entries[pd_idx].present) return;

    const pt: *PageTable = hhdm.physToPtr(PageTable, pd.entries[pd_idx].getPhysAddr());
    pt.entries[pt_idx] = @bitCast(value);
}

/// VMA region info returned by enumerateVMAs.
pub const VMAEntry = struct {
    start: u64,
    end: u64,
    flags: u8, // bit0=r, bit1=w, bit2=x
};

/// Walk the user-space page table and collect VMA ranges (up to max_vmas).
/// Returns number of VMAs found.
pub fn enumerateVMAs(pml4_phys: u64, out: []VMAEntry) u32 {
    const hhdm_mod = hhdm;
    const pml4: *PageTable = hhdm_mod.physToPtr(PageTable, pml4_phys);
    var count: u32 = 0;
    var cur_start: u64 = 0;
    var cur_end: u64 = 0; // exclusive end of the open range
    var cur_flags: u8 = 0;
    var in_range = false;

    // Only scan user-space: PML4 entries 0..255 (0x0000_0000_0000_0000 .. 0x0000_7FFF_FFFF_FFFF)
    for (0..256) |pml4_i| {
        if (!pml4.entries[pml4_i].present) {
            if (in_range and count < out.len) {
                out[count] = .{ .start = cur_start, .end = @as(u64, pml4_i) << 39, .flags = cur_flags };
                count += 1;
                in_range = false;
            }
            continue;
        }
        const pdpt: *PageTable = hhdm_mod.physToPtr(PageTable, pml4.entries[pml4_i].getPhysAddr());
        for (0..512) |pdpt_i| {
            if (!pdpt.entries[pdpt_i].present) {
                if (in_range and count < out.len) {
                    const addr = (@as(u64, pml4_i) << 39) | (@as(u64, pdpt_i) << 30);
                    out[count] = .{ .start = cur_start, .end = addr, .flags = cur_flags };
                    count += 1;
                    in_range = false;
                }
                continue;
            }
            if (pdpt.entries[pdpt_i].huge_page) continue; // skip 1GB pages
            const pd: *PageTable = hhdm_mod.physToPtr(PageTable, pdpt.entries[pdpt_i].getPhysAddr());
            for (0..512) |pd_i| {
                if (!pd.entries[pd_i].present) {
                    if (in_range and count < out.len) {
                        const addr = (@as(u64, pml4_i) << 39) | (@as(u64, pdpt_i) << 30) | (@as(u64, pd_i) << 21);
                        out[count] = .{ .start = cur_start, .end = addr, .flags = cur_flags };
                        count += 1;
                        in_range = false;
                    }
                    continue;
                }
                if (pd.entries[pd_i].huge_page) {
                    // 2MB huge page
                    const addr = (@as(u64, pml4_i) << 39) | (@as(u64, pdpt_i) << 30) | (@as(u64, pd_i) << 21);
                    var f: u8 = 1; // readable
                    if (pd.entries[pd_i].writable) f |= 2;
                    if (!pd.entries[pd_i].no_execute) f |= 4;
                    if (in_range and f == cur_flags and addr == cur_end) {
                        cur_end = addr + 0x20_0000; // extend range by the 2MB page
                    } else {
                        if (in_range and count < out.len) {
                            out[count] = .{ .start = cur_start, .end = addr, .flags = cur_flags };
                            count += 1;
                        }
                        cur_start = addr;
                        cur_end = addr + 0x20_0000;
                        cur_flags = f;
                        in_range = true;
                    }
                    continue;
                }
                const pt: *PageTable = hhdm_mod.physToPtr(PageTable, pd.entries[pd_i].getPhysAddr());
                for (0..512) |pt_i| {
                    if (!pt.entries[pt_i].present) {
                        if (in_range and count < out.len) {
                            const addr = (@as(u64, pml4_i) << 39) | (@as(u64, pdpt_i) << 30) | (@as(u64, pd_i) << 21) | (@as(u64, pt_i) << 12);
                            out[count] = .{ .start = cur_start, .end = addr, .flags = cur_flags };
                            count += 1;
                            in_range = false;
                        }
                        continue;
                    }
                    const addr = (@as(u64, pml4_i) << 39) | (@as(u64, pdpt_i) << 30) | (@as(u64, pd_i) << 21) | (@as(u64, pt_i) << 12);
                    var f: u8 = 1; // readable
                    if (pt.entries[pt_i].writable) f |= 2;
                    if (!pt.entries[pt_i].no_execute) f |= 4;
                    if (in_range and f == cur_flags and addr == cur_end) {
                        cur_end = addr + 0x1000; // merge adjacent pages with same flags
                    } else {
                        if (in_range and count < out.len) {
                            out[count] = .{ .start = cur_start, .end = addr, .flags = cur_flags };
                            count += 1;
                        }
                        cur_start = addr;
                        cur_end = addr + 0x1000;
                        cur_flags = f;
                        in_range = true;
                    }
                }
            }
        }
    }
    // Close final range
    if (in_range and count < out.len) {
        out[count] = .{ .start = cur_start, .end = cur_end, .flags = cur_flags };
        count += 1;
    }
    return count;
}
