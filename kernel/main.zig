/// MoQiOS kernel entry point — M1 + M2 + M3 + M4 + M5 milestones
/// Booted via Limine protocol. Initializes: GDT, IDT, HHDM, klog,
/// TSC, symbol table, PMM, paging, ACPI, slab allocator, DMA stubs,
/// LAPIC timer, scheduler, IPC engine, user-space support.
const limine = @import("limine.zig");
const arch = @import("arch/arch.zig");
// Progressive arch migration (SK-1): serial / interrupts / paging / timer /
// context_switch / gdt / tsc / syscall go through arch.zig.
const serial = arch.serial;
const idt = arch.interrupts;
const paging = arch.paging;
const lapic = arch.timer;
const context_switch = arch.context_switch;
const hhdm = @import("mm/hhdm.zig");
const klog = @import("klog.zig");
const acpi = @import("acpi/acpi_parser.zig");
const pmm = @import("mm/pmm.zig");
const task = @import("proc/task.zig");
const sched = @import("proc/sched.zig");
const loader = @import("proc/loader.zig");
const fmt = @import("lib/fmt.zig");
const subsystem_boot = @import("shared/subsystem_boot.zig");

pub const panic = @import("panic.zig").panic;

pub export var base_revision: limine.BaseRevision linksection(".limine_reqs") = .{};
pub export var memmap_request: limine.MemmapRequest linksection(".limine_reqs") = .{};
pub export var hhdm_request: limine.HhdmRequest linksection(".limine_reqs") = .{};
pub export var framebuffer_request: limine.FramebufferRequest linksection(".limine_reqs") = .{};
pub export var rsdp_request: limine.RsdpRequest linksection(".limine_reqs") = .{};
pub export var module_request: limine.ModuleRequest linksection(".limine_reqs") = .{};

export fn _start() callconv(.c) noreturn {
    serial.init();
    serial.writeString("MoQiOS kernel started\n");

    if (!base_revision.isSupported()) {
        serial.writeString("  FATAL: Limine protocol not supported\n");
        while (true) asm volatile ("hlt");
    }
    klog.log(.info, "Limine boot: revision 3");

    // HHDM initialization
    if (hhdm_request.response) |resp| {
        hhdm.init(resp.offset);
        klog.logHex(.info, "HHDM offset: ", resp.offset);
    }

    // SK-35: gdt + tsc + BSP GS_BASE via shared fragment (before IDT/FPU).
    // GS is valid early for commonStub; smp/syscall re-set it later.
    subsystem_boot.initCpuSurfaces();
    klog.log(.info, "GDT/TSC/GS loaded");

    idt.init();
    klog.log(.info, "IDT loaded");

    // Task #1: enable lazy FPU/SSE on BSP. Sets CR4.OSFXSR | CR4.OSXMMEXCPT,
    // clears CR0.EM, sets CR0.MP and arms CR0.TS so the first FPU/SSE use
    // takes a #NM (vector 7) for lazy restore. Must come AFTER idt.init so
    // the #NM handler is wired up before any code can trip over CR0.TS.
    context_switch.initCpu();
    klog.log(.info, "FPU/SSE lazy switch armed (BSP)");

    // PS/2 keyboard driver
    const keyboard = @import("drivers/keyboard.zig");
    keyboard.init();

    // VGA text mode uses MMIO at 0xB8000 which may not be HHDM-mapped;
    // skip for now, rely on serial output instead
    klog.log(.info, "VGA skipped (serial-only mode)");

    // M1: symbol table (shared boot fragment — SK-35)
    subsystem_boot.initSymbolTable();
    klog.log(.info, "Symbol table initialized");

    // M2: Physical Memory Manager
    if (memmap_request.response) |memmap| {
        pmm.init(memmap);
    }

    // M2: Page table operations
    paging.init();

    // M2: Address space + DMA (shared portable mm boot — SK-25)
    subsystem_boot.initPortableMm();

    // ACPI — must come after paging init so we can map non-RAM regions
    var rsdp_phys: u64 = 0;
    if (rsdp_request.response) |rsdp_resp| {
        rsdp_phys = rsdp_resp.address;
        mapAcpiRegion();
    }
    acpi.init(rsdp_phys);
    if (acpi.info.cpu_count > 0) {
        serial.writeString("[INF] ACPI: ");
        fmt.writeDecimal(acpi.info.cpu_count);
        serial.writeString(" CPUs detected\n");
    }

    // M2: Slab allocator (shared boot fragment — SK-32)
    subsystem_boot.initSlab();

    // Framebuffer graphics driver
    const framebuffer = @import("drivers/framebuffer.zig");
    framebuffer.init();

    // M6.0: PCI enumeration
    const pci = @import("drivers/pci.zig");
    pci.init();

    // M7: AHCI SATA driver
    const ahci = @import("drivers/ahci.zig");
    ahci.init();

    // M7: Virtio-blk driver
    const virtio_blk = @import("drivers/virtio_blk.zig");
    virtio_blk.init();

    // M7: NVMe driver
    const nvme = @import("drivers/nvme.zig");
    nvme.init();

    // M7: Block device abstraction layer — register all block devices
    // page_cache via shared boot fragment (SK-33)
    subsystem_boot.initPageCache();
    const block_dev = @import("drivers/block_dev.zig");
    if (virtio_blk.hasActiveDisk()) {
        var vb_name: [16]u8 = @splat(0);
        vb_name[0] = 'v';
        vb_name[1] = 'b';
        vb_name[2] = 'l';
        vb_name[3] = 'k';
        vb_name[4] = '0';
        _ = block_dev.registerDevice(.{
            .dev_type = .virtio_blk,
            .sector_size = 512,
            .total_sectors = virtio_blk.getCapacity(),
            .name = vb_name,
            .name_len = 5,
            .supports_flush = false,
            .max_transfer_sectors = 128,
        }, 0);
    }
    if (ahci.hasActiveDisk()) {
        var ahci_name: [16]u8 = @splat(0);
        ahci_name[0] = 's';
        ahci_name[1] = 'd';
        ahci_name[2] = 'a';
        _ = block_dev.registerDevice(.{
            .dev_type = .ahci,
            .sector_size = ahci.getSectorSize(),
            .total_sectors = ahci.getTotalSectors(),
            .name = ahci_name,
            .name_len = 3,
            .supports_flush = true,
            .max_transfer_sectors = 128,
        }, 0);
    }
    // NVMe registration is handled inside nvme.init()
    klog.log(.info, "Block device layer initialized");

    // M7: Test block read
    if (virtio_blk.hasActiveDisk()) {
        const test_buf_phys = pmm.allocPage() orelse @panic("OOM");
        const test_buf: [*]u8 = @ptrFromInt(hhdm.physToVirt(test_buf_phys));
        const n = virtio_blk.readSectors(0, 1, test_buf);
        if (n > 0) {
            klog.log(.info, "Block device read OK");
        }
        pmm.freePage(test_buf_phys);
    }

    // M7: FAT32 filesystem
    const fat32 = @import("fs/fat32.zig");
    fat32.init();

    // M8: e1000 NIC driver
    const e1000 = @import("drivers/e1000.zig");
    e1000.init();

    // Virtio-net driver (high-performance NIC)
    const virtio_net = @import("drivers/virtio_net.zig");
    virtio_net.init();

    // M8: Network protocol stack (ARP cache init, MAC address setup)
    const net_mod = @import("net/mod.zig");
    net_mod.init();

    // ext2 filesystem (on first virtio-blk disk at LBA offset 32768)
    const ext2 = @import("fs/ext2.zig");
    ext2.init();

    // v53.33: Register writeback flush callbacks for eviction-time flushing
    // (SK-46: shared boot fragment).
    subsystem_boot.initWritebackCallbacks();

    // tmpfs + /dev/urandom (shared boot fragments — SK-34)
    subsystem_boot.initTmpfs();
    subsystem_boot.initRandom();

    // M3: LAPIC timer — use LAPIC address from ACPI MADT, fallback to 0xFEE00000
    const lapic_addr = if (acpi.info.lapic_address != 0) acpi.info.lapic_address else 0xFEE00000;
    lapic.init(lapic_addr);

    // Task #2: initialise the BSP's per-CPU run queue BEFORE smp.init creates
    // any kernel threads (createKernelThread/createKernelThreadAffinity may
    // observe the queue via subsequent enqueue paths). AP queues are
    // initialised in smp.apEntry.
    const sched_boot = @import("shared/sched_boot.zig");
    sched_boot.initBspRunQueue();

    // SMP: Start Application Processors
    const smp = @import("smp.zig");
    smp.init();

    // M4: IPC engine + capability system
    subsystem_boot.initIpcAndSyscall();
    klog.log(.info, "IPC engine + capabilities + syscall entry initialized");

    // M5.3: Ramdisk — parse Limine modules
    if (module_request.response) |resp| {
        if (resp.module_count > 0) {
            const mod_file = resp.modules[0];
            serial.writeString("[ramdisk] Found module: ");
            const path_len = strnLen(mod_file.path, 256);
            serial.writeString(mod_file.path[0..path_len]);
            serial.writeString(" (");
            fmt.writeDecimal64(mod_file.size);
            serial.writeString(" bytes)\n");
            // SK-43: shared MRD parse fragment (source stays Limine-specific).
            if (!subsystem_boot.initRamdisk(mod_file.address, mod_file.size)) {
                klog.log(.info, "Failed to parse ramdisk");
            }
        } else {
            klog.log(.info, "No modules loaded");
        }
    } else {
        klog.log(.info, "Module request has no response");
    }

    // Create kernel idle thread (priority 255 = lowest, runs when nothing else
    // is ready) — SK-42: shared portable idle body (sched.kernelIdleLoop).
    _ = sched_boot.createIdleThread() orelse {
        klog.log(.info, "Failed to create idle thread");
        while (true) asm volatile ("hlt");
    };
    klog.log(.info, "Idle thread created");

    // M5.5: Load init program from ramdisk as the first user process (pid 1)
    if (loader.loadProgram("init", 0)) |task_idx| {
        serial.writeString("[kernel] init launched as task ");
        fmt.writeDecimal(task_idx);
        serial.writeString("\n");
    } else {
        klog.log(.info, "Failed to load init from ramdisk — system halted");
        while (true) asm volatile ("hlt");
    }

    // Enable interrupts and start scheduler
    klog.log(.info, "Enabling interrupts...");
    klog.log(.info, "=== MoQiOS scheduler active ===");
    // SK-42: portable boot-context idle (enableIrq + waitForInterrupt loop).
    sched_boot.bootIdleLoop();
}

/// Map the low memory region (0-1MB) via HHDM so ACPI tables and BIOS data
/// are accessible.
fn mapAcpiRegion() void {
    const pml4 = paging.getKernelPml4();
    const flags = paging.MapFlags{
        .writable = false,
        .user = false,
        .no_execute = true,
        .global = true,
    };
    var phys: u64 = 0;
    while (phys < 0x100000) : (phys += paging.PAGE_SIZE) {
        const virt = hhdm.physToVirt(phys);
        paging.mapPage(pml4, virt, phys, flags) catch {};
    }
}

/// Map a single physical page containing an ACPI table at the given physical address.
/// Skips mapping if the page is already mapped (to avoid splitting huge pages).
/// Map a single physical page for ACPI/MMIO access.
/// Uses 2MB huge page mapping to avoid splitting existing huge pages.
pub fn mapAcpiPage(phys_addr: u64) void {
    const page = phys_addr & ~@as(u64, paging.PAGE_SIZE - 1);
    const virt = hhdm.physToVirt(page);
    if (paging.isPageMapped(paging.getKernelPml4(), virt)) return;
    // Use 2MB huge page mapping to avoid splitting
    const huge_page_base = phys_addr & ~@as(u64, paging.PAGE_2MB - 1);
    const pml4 = paging.getKernelPml4();
    const flags = paging.MapFlags{
        .writable = true,
        .user = false,
        .no_execute = true,
        .global = true,
        .write_through = true,
        .cache_disable = true,
    };
    paging.mapHugePage(pml4, hhdm.physToVirt(huge_page_base), huge_page_base, flags) catch {};
}

fn strnLen(s: [*:0]u8, max: usize) usize {
    var i: usize = 0;
    while (i < max and s[i] != 0) : (i += 1) {}
    return i;
}
