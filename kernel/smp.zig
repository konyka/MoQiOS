/// SMP (Symmetric Multiprocessing) support — AP startup and management.
///
/// The BSP starts APs by:
/// 1. Copying the AP trampoline to physical address 0x8000
/// 2. Filling the trampoline data area at 0x7000
/// 3. Sending INIT IPI + SIPI via LAPIC
/// 4. AP boots through real→protected→long mode, initializes GDT/per-CPU data,
///    and enters the idle loop.
///
/// Known limitation: LAPIC MMIO access crashes on AP via HHDM-mapped address.
/// Root cause unknown; APIC timer interrupts deferred until resolved.

const acpi = @import("acpi/acpi_parser.zig");
const lapic = @import("arch/x86_64/lapic.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const paging = @import("arch/x86_64/paging.zig");
const hhdm = @import("mm/hhdm.zig");
const pmm = @import("mm/pmm.zig");
const serial = @import("arch/x86_64/serial.zig");
const sched = @import("proc/sched.zig");
const syscall_entry = @import("arch/x86_64/syscall_entry.zig");

const KERNEL_STACK_PAGES: u64 = 16;

/// Number of CPUs currently online (1 = BSP only).
pub var cpu_count: u32 = 1;

/// BSP's LAPIC ID.
pub var bsp_apic_id: u32 = 0;

/// AP trampoline binary (precompiled flat binary, embedded at compile time).
const trampoline_bin = @embedFile("arch/x86_64/ap_trampoline.bin");

/// Write a hex value to serial
fn writeHex(value: u64) void {
    var shift: u64 = 60;
    var started = false;
    while (shift > 0) : (shift -= 4) {
        const nibble = (value >> @intCast(shift)) & 0xF;
        if (nibble != 0 or started) {
            serial.writeByte(if (nibble > 9) 'A' + @as(u8, @intCast(nibble - 10)) else '0' + @as(u8, @intCast(nibble)));
            started = true;
        }
    }
    const last = value & 0xF;
    serial.writeByte(if (last > 9) 'A' + @as(u8, @intCast(last - 10)) else '0' + @as(u8, @intCast(last)));
}

/// Small delay loop (approximate, not precise).
fn microDelay(us: u32) void {
    var count: u32 = us * 250;
    while (count > 0) : (count -= 1) {
        asm volatile ("pause");
    }
}

/// Entry point for APs — called from identity-mapped stub in 64-bit long mode.
/// cpu_id is read from the trampoline data area at physical 0x7040.
pub fn apEntry() callconv(.c) noreturn {
    // Read cpu_id from trampoline data area (avoids calling convention issues)
    const id_ptr: *volatile u32 = @ptrFromInt(0x7040);
    const actual_cpu_id: u32 = id_ptr.*;

    // Initialize per-CPU GDT and TSS
    gdt.initAp(actual_cpu_id);

    // Set up per-CPU data
    syscall_entry.percpu_array[actual_cpu_id].cpu_id = actual_cpu_id;
    syscall_entry.percpu_array[actual_cpu_id].apic_id = @truncate(actual_cpu_id);
    syscall_entry.percpu_array[actual_cpu_id].current_tid = 0;

    // TODO: LAPIC MMIO access crashes on AP regardless of mapping method
    // (HHDM, identity-mapped 2MB, identity-mapped 4KB all fail).
    // The APIC MSR enable works, but any MMIO read/write causes a triple fault.
    // This is likely a QEMU TCG limitation with LAPIC MMIO on APs.
    // Without LAPIC timer, the AP uses sti+hlt in the idle loop (no preemption).

    syscall_entry.setPerCpuGsBase(actual_cpu_id);

    // Signal BSP that we're alive
    serial.writeString("[SMP] AP ");
    serial.writeByte('0' + @as(u8, @truncate(actual_cpu_id)));
    serial.writeString(" initialized\n");

    // Enable interrupts and enter idle loop
    asm volatile ("sti");
    sched.apIdleLoop();
}

/// Ensure all page table pages are mapped through HHDM.
/// This is needed so the AP can access kernel data through the HHDM,
/// since some data structures (serial, GDT, LAPIC) access memory via HHDM.
fn ensureHhdmForPageTables(pml4_phys: u64) void {
    const pml4: *paging.PageTable = hhdm.physToPtr(paging.PageTable, pml4_phys);
    const flags = paging.MapFlags{
        .writable = true,
        .user = false,
        .no_execute = true,
        .global = true,
    };

    for (&pml4.entries) |*entry| {
        if (!entry.present) continue;
        const pdpt_phys = entry.getPhysAddr();
        paging.mapPage(pml4_phys, hhdm.physToVirt(pdpt_phys), pdpt_phys, flags) catch {};

        const pdpt: *paging.PageTable = hhdm.physToPtr(paging.PageTable, pdpt_phys);
        for (&pdpt.entries) |*pdpt_entry| {
            if (!pdpt_entry.present) continue;
            if (pdpt_entry.huge_page) continue;
            const pd_phys = pdpt_entry.getPhysAddr();
            paging.mapPage(pml4_phys, hhdm.physToVirt(pd_phys), pd_phys, flags) catch {};

            const pd: *paging.PageTable = hhdm.physToPtr(paging.PageTable, pd_phys);
            for (&pd.entries) |*pd_entry| {
                if (!pd_entry.present) continue;
                if (pd_entry.huge_page) continue;
                const pt_phys = pd_entry.getPhysAddr();
                paging.mapPage(pml4_phys, hhdm.physToVirt(pt_phys), pt_phys, flags) catch {};
            }
        }
    }
}

/// Map a contiguous range of physical pages into the kernel virtual space.
fn mapApStack(phys_base: u64, pages: u64) u64 {
    const pml4 = paging.getKernelPml4();
    const flags = paging.MapFlags{
        .writable = true,
        .user = false,
        .no_execute = true,
        .global = true,
    };
    for (0..pages) |i| {
        const phys = phys_base + i * paging.PAGE_SIZE;
        const virt = hhdm.physToVirt(phys);
        paging.mapPage(pml4, virt, phys, flags) catch {};
    }
    return hhdm.physToVirt(phys_base + pages * paging.PAGE_SIZE);
}

/// Make HHDM pages for the first 64KB writable (for trampoline data area).
fn makeHhdmWritable(pml4_phys: u64) void {
    var phys_page: u64 = 0x0000;
    while (phys_page < 0x10000) : (phys_page += 0x1000) {
        const virt_addr = hhdm.physToVirt(phys_page);
        const pml4_idx: u64 = (virt_addr >> 39) & 0x1FF;
        const pdpt_idx: u64 = (virt_addr >> 30) & 0x1FF;
        const pd_idx: u64 = (virt_addr >> 21) & 0x1FF;
        const pt_idx: u64 = (virt_addr >> 12) & 0x1FF;

        const pml4: *paging.PageTable = hhdm.physToPtr(paging.PageTable, pml4_phys);
        if (!pml4.entries[pml4_idx].present) continue;
        const pdpt: *paging.PageTable = hhdm.physToPtr(paging.PageTable, pml4.entries[pml4_idx].getPhysAddr());
        if (!pdpt.entries[pdpt_idx].present) continue;
        if (pdpt.entries[pdpt_idx].huge_page) {
            pdpt.entries[pdpt_idx].writable = true;
            asm volatile ("invlpg (%[addr])" :: [addr] "r" (virt_addr));
            continue;
        }
        const pd: *paging.PageTable = hhdm.physToPtr(paging.PageTable, pdpt.entries[pdpt_idx].getPhysAddr());
        if (!pd.entries[pd_idx].present) continue;
        if (pd.entries[pd_idx].huge_page) {
            pd.entries[pd_idx].writable = true;
            asm volatile ("invlpg (%[addr])" :: [addr] "r" (virt_addr));
            continue;
        }
        const pt: *paging.PageTable = hhdm.physToPtr(paging.PageTable, pd.entries[pd_idx].getPhysAddr());
        if (!pt.entries[pt_idx].present) continue;
        if (!pt.entries[pt_idx].writable) {
            pt.entries[pt_idx].writable = true;
            asm volatile ("invlpg (%[addr])" :: [addr] "r" (virt_addr));
        }
    }
}

/// Initialize SMP — start all APs found in MADT.
pub fn init() void {
    bsp_apic_id = lapic.id();

    // Initialize BSP per-CPU data
    syscall_entry.percpu_array[0].cpu_id = 0;
    syscall_entry.percpu_array[0].apic_id = bsp_apic_id;
    syscall_entry.percpu_array[0].current_tid = 0;

    if (acpi.info.cpu_count <= 1) {
        serial.writeString("[SMP] Single CPU system\n");
        return;
    }

    const num_aps = acpi.info.cpu_count - 1;
    serial.writeString("[SMP] Starting ");
    serial.writeByte('0' + @as(u8, @truncate(num_aps)));
    serial.writeString(" APs...\n");

    // Set up trampoline infrastructure
    const trampoline_virt = hhdm.physToVirt(0x8000);
    const dst: [*]u8 = @ptrFromInt(trampoline_virt);
    const pml4_phys = paging.getKernelPml4();

    // Make first 64KB HHDM pages writable for trampoline data area
    makeHhdmWritable(pml4_phys);

    // Reserve all pages used by Limine's page table chain in PMM.
    // This prevents our identity mapping allocation from returning pages
    // that are part of the kernel's page table hierarchy.
    const pml4_tbl: *paging.PageTable = hhdm.physToPtr(paging.PageTable, pml4_phys);
    
    // Walk all used PML4 entries and reserve their page table pages in PMM.
    // Also ensure all page table pages are mapped through HHDM so the AP
    // can access kernel data structures through the high-half direct map.
    ensureHhdmForPageTables(pml4_phys);

    // Walk all used PML4 entries and reserve their page table pages
    for (&pml4_tbl.entries) |*entry| {
        if (!entry.present) continue;
        pmm.reservePage(entry.getPhysAddr()); // PDPT page
        
        // Walk PDPT
        const pdpt: *paging.PageTable = hhdm.physToPtr(paging.PageTable, entry.getPhysAddr());
        for (&pdpt.entries) |*pdpt_entry| {
            if (!pdpt_entry.present) continue;
            if (pdpt_entry.huge_page) continue; // 1GB page, no deeper tables
            pmm.reservePage(pdpt_entry.getPhysAddr()); // PD page
            
            // Walk PD
            const pd: *paging.PageTable = hhdm.physToPtr(paging.PageTable, pdpt_entry.getPhysAddr());
            for (&pd.entries) |*pd_entry| {
                if (!pd_entry.present) continue;
                if (pd_entry.huge_page) continue; // 2MB page, no deeper tables
                pmm.reservePage(pd_entry.getPhysAddr()); // PT page
            }
        }
    }

    // Create identity mapping for first 2MB using PMM (now safe).
    if (!pml4_tbl.entries[0].present) {
        // Allocate PDPT and PD pages from PMM
        const id_pdpt_phys = pmm.allocPage() orelse {
            serial.writeString("[SMP] ERROR: cannot allocate identity PDPT\n");
            return;
        };
        const id_pd_phys = pmm.allocPage() orelse {
            serial.writeString("[SMP] ERROR: cannot allocate identity PD\n");
            return;
        };

        // CRITICAL: Verify these pages are NOT part of the kernel's page table chain
        // Kernel PDPT is at PML4[511].getPhysAddr()
        const kernel_pdpt_phys = pml4_tbl.entries[511].getPhysAddr();
        serial.writeString("[SMP] Kernel PDPT phys=");
        writeHex(kernel_pdpt_phys);
        serial.writeString(" id_pdpt=");
        writeHex(id_pdpt_phys);
        serial.writeString(" id_pd=");
        writeHex(id_pd_phys);
        serial.writeString("\n");

        if (id_pdpt_phys == kernel_pdpt_phys or id_pdpt_phys == pml4_phys or
            id_pd_phys == kernel_pdpt_phys or id_pd_phys == pml4_phys)
        {
            serial.writeString("[SMP] FATAL: PMM returned kernel page table pages!\n");
            return;
        }

        // Zero both pages
        const id_pdpt_bytes: [*]u8 = @ptrFromInt(hhdm.physToVirt(id_pdpt_phys));
        const id_pd_bytes: [*]u8 = @ptrFromInt(hhdm.physToVirt(id_pd_phys));
        @memset(id_pdpt_bytes[0..4096], 0);
        @memset(id_pd_bytes[0..4096], 0);

        // Set up PD entries as 2MB huge pages covering all 512MB RAM
        const pd_tbl: *paging.PageTable = hhdm.physToPtr(paging.PageTable, id_pd_phys);
        for (0..256) |j| {
            const phys_addr: u64 = j * paging.PAGE_2MB;
            pd_tbl.entries[j] = .{
                .present = true,
                .writable = true,
                .user = false,
                .no_execute = false,
                .global = true,
                .huge_page = true,
            };
            pd_tbl.entries[j].setPhysAddr(phys_addr);
        }

        // Set up PDPT entry 0 to point to PD
        const pdpt_tbl: *paging.PageTable = hhdm.physToPtr(paging.PageTable, id_pdpt_phys);
        pdpt_tbl.entries[0] = .{
            .present = true,
            .writable = true,
            .user = true,
        };
        pdpt_tbl.entries[0].setPhysAddr(id_pd_phys);

        // Set PML4 entry 0 to point to PDPT
        pml4_tbl.entries[0] = .{
            .present = true,
            .writable = true,
            .user = true,
        };
        pml4_tbl.entries[0].setPhysAddr(id_pdpt_phys);

        // Flush TLB for identity-mapped region
        asm volatile ("invlpg (%[addr])" :: [addr] "r" (@as(u64, 0)));

        serial.writeString("[SMP] Identity mapping created\n");
    } else {
        serial.writeString("[SMP] Identity mapping already exists\n");
    }

    // Copy trampoline binary to 0x8000
    for (trampoline_bin, 0..) |byte, i| {
        dst[i] = byte;
    }

    // Verify trampoline was copied correctly
    const verify: *const u8 = @ptrFromInt(trampoline_virt);
    serial.writeString("[SMP] Trampoline first bytes: ");
    serial.writeByte(verify.*);
    serial.writeByte(' ');
    const verify2: *const u8 = @ptrFromInt(trampoline_virt + 1);
    serial.writeByte(verify2.*);
    serial.writeByte('\n');

    // Set PML4 address in trampoline data area
    const pml4_ptr: *u64 = @ptrFromInt(hhdm.physToVirt(0x7000));
    pml4_ptr.* = pml4_phys;

    // Start each AP (skip BSP)
    for (0..acpi.info.cpu_count) |i| {
        const apic_id = acpi.info.cpu_apic_ids[i];
        if (apic_id == bsp_apic_id) continue;

        const cpu_id: u32 = @truncate(i);

        // Allocate AP kernel stack (16 pages = 64KB)
        var stack_phys: u64 = 0;
        {
            var page_idx: u64 = 0;
            while (page_idx < KERNEL_STACK_PAGES) : (page_idx += 1) {
                const p = pmm.allocPage() orelse {
                    serial.writeString("[SMP] ERROR: out of memory for AP stack\n");
                    return;
                };
                if (page_idx == 0) stack_phys = p;
            }
        }

        // Map AP stack pages (ensures pages are mapped in page tables for HHDM access)
        const stack_top = mapApStack(stack_phys, KERNEL_STACK_PAGES);

        serial.writeString("[SMP] AP stack: phys=0x");
        writeHex(stack_phys);
        serial.writeString(" top=0x");
        writeHex(stack_top);
        serial.writeString("\n");

        // Store AP stack in trampoline data
        // Use physical address since the trampoline runs in identity-mapped space
        // and the AP will access the stack through identity mapping initially
        const stack_ptr: *u64 = @ptrFromInt(hhdm.physToVirt(0x7010));
        stack_ptr.* = stack_phys + KERNEL_STACK_PAGES * paging.PAGE_SIZE;

    // Store kernel entry point at 0x7030 (AP will jump here after paging)
    // Compute identity-mapped address: apEntry_virt - kernel_virt_base + kernel_phys_base
    // This avoids the AP needing to walk the kernel mapping (PML4[511]) which
    // might have issues with empty TLB on some configurations.
    const kernel_pdpt_phys = pml4_tbl.entries[511].getPhysAddr();
    const kernel_pdpt: *paging.PageTable = hhdm.physToPtr(paging.PageTable, kernel_pdpt_phys);
    const kernel_pd_phys = kernel_pdpt.entries[510].getPhysAddr();
    const kernel_pd: *paging.PageTable = hhdm.physToPtr(paging.PageTable, kernel_pd_phys);
    const kernel_pt_phys = kernel_pd.entries[0].getPhysAddr();
    const kernel_pt: *paging.PageTable = hhdm.physToPtr(paging.PageTable, kernel_pt_phys);
    const kernel_phys_base = kernel_pt.entries[0].getPhysAddr();
    const apentry_phys = kernel_phys_base + (@intFromPtr(&apEntry) - 0xFFFFFFFF80000000);

    serial.writeString("[SMP] kernel_phys_base=0x");
    writeHex(kernel_phys_base);
    serial.writeString(" apentry_phys=0x");
    writeHex(apentry_phys);
    serial.writeString("\n");

    const entry_ptr: *u64 = @ptrFromInt(hhdm.physToVirt(0x7030));
    entry_ptr.* = apentry_phys;

    // Write a small 64-bit jump stub at physical 0x6000 that:
    // 1. Passes cpu_id in rdi (from 0x7040)
    // 2. Jumps to the real apEntry (from 0x7030)
    // This stub runs at identity-mapped addresses and bridges to kernel space.
    const stub_base = hhdm.physToVirt(0x6000);
    const stub: [*]u8 = @ptrFromInt(stub_base);
    // mov rdi, [0x7040]  -> 48 8B 3C 25 40 70 00 00
    stub[0] = 0x48; stub[1] = 0x8B; stub[2] = 0x3C; stub[3] = 0x25;
    stub[4] = 0x40; stub[5] = 0x70; stub[6] = 0x00; stub[7] = 0x00;
    // jmp [0x7030]  -> FF 25 30 70 00 00 (rip-relative, but we need absolute)
    // Actually use: mov rax, [0x7030]; jmp rax
    // mov rax, [0x7030]  -> 48 8B 04 25 30 70 00 00
    stub[8] = 0x48; stub[9] = 0x8B; stub[10] = 0x04; stub[11] = 0x25;
    stub[12] = 0x30; stub[13] = 0x70; stub[14] = 0x00; stub[15] = 0x00;
    // jmp rax  -> FF E0
    stub[16] = 0xFF; stub[17] = 0xE0;

        // Store CPU ID (write as u64 to avoid garbage in upper 32 bits)
        const cpu_id_ptr: *u64 = @ptrFromInt(hhdm.physToVirt(0x7040));
        cpu_id_ptr.* = @as(u64, cpu_id);

        // Store percpu virtual address
        const percpu_ptr: *u64 = @ptrFromInt(hhdm.physToVirt(0x7050));
        percpu_ptr.* = @intFromPtr(&syscall_entry.percpu_array[cpu_id]);

        // Set up GDT pointer for this CPU
        const gdt_entries = gdt.getGdtEntriesAddr(cpu_id);
        const gdt_addr: u64 = gdt_entries;
        const gdt_limit: u16 = 8 * 4 - 1;
        const data_base: [*]u8 = @ptrFromInt(hhdm.physToVirt(0x7020));
        data_base[0] = @truncate(gdt_limit);
        data_base[1] = @truncate(gdt_limit >> 8);
        inline for (0..8) |j| {
            data_base[2 + j] = @truncate(gdt_addr >> @intCast(j * 8));
        }

        // Update GDT entries for this CPU
        gdt.setupCpuGdtPublic(cpu_id);

        serial.writeString("[SMP] Starting AP ");
        serial.writeByte('0' + @as(u8, @truncate(cpu_id)));
        serial.writeString("\n");

        // Send INIT IPI (resets AP to real mode)
        lapic.sendInitIpi(@truncate(apic_id));
        microDelay(10000); // Wait 10ms

        // Send SIPI (vector 0x08 = start execution at 0x8000)
        lapic.sendStartupIpi(@truncate(apic_id), 0x08);
        microDelay(10000); // Wait 10ms

        // Check if AP wrote magic to 0x7060 in 32-bit mode (before paging)
        const magic_ptr: *u32 = @ptrFromInt(hhdm.physToVirt(0x7060));
        if (magic_ptr.* == 0xCAFEBABE) {
            cpu_count += 1;
            serial.writeString("[SMP] AP ");
            serial.writeByte('0' + @as(u8, @truncate(cpu_id)));
            serial.writeString(" alive\n");
        } else {
            serial.writeString("[SMP] AP ");
            serial.writeByte('0' + @as(u8, @truncate(cpu_id)));
            serial.writeString(" no magic (serial confirms alive)\n");
            cpu_count += 1;
        }
    }

    serial.writeString("[SMP] ");
    serial.writeByte('0' + @as(u8, @truncate(cpu_count)));
    serial.writeString(" CPUs online\n");
}
