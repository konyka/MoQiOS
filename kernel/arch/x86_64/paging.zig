/// x86_64 4-level paging — PML4 → PDPT → PD → PT.
/// Provides map/unmap operations for 4KB and 2MB pages.

const hhdm = @import("../../mm/hhdm.zig");
const pmm = @import("../../mm/pmm.zig");
const serial = @import("serial.zig");

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
    writeHex(kernel_pml4_phys);
    serial.writeString("\n");
}

pub fn getKernelPml4() u64 {
    return kernel_pml4_phys;
}

/// Map a 4KB virtual page to a physical frame.
pub fn mapPage(pml4_phys: u64, virt: u64, phys: u64, flags: MapFlags) !void {
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
    invlpg(virt);
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

/// Unmap a virtual page.
pub fn unmapPage(pml4_phys: u64, virt: u64) void {
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
    pt.entries[pt_idx] = .{}; // Zero = not present
    invlpg(virt);
}

/// Ensure a page table exists at the given PTE, allocating if needed.
fn ensureTable(pte: *PTE) !u64 {
    if (pte.present) {
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
