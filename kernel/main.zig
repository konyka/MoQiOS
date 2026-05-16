/// MoQiOS kernel entry point — M1 + M2 + M3 + M4 + M5 milestones
/// Booted via Limine protocol. Initializes: GDT, IDT, HHDM, klog,
/// TSC, symbol table, PMM, paging, ACPI, slab allocator, DMA stubs,
/// LAPIC timer, scheduler, IPC engine, user-space support.

const limine = @import("limine.zig");
const serial = @import("arch/x86_64/serial.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const idt = @import("arch/x86_64/idt.zig");
const hhdm = @import("mm/hhdm.zig");
const klog = @import("klog.zig");
const acpi = @import("acpi/acpi_parser.zig");
const symbol_table = @import("debug/symbol_table.zig");
const tsc = @import("arch/x86_64/tsc.zig");
const pmm = @import("mm/pmm.zig");
const paging = @import("arch/x86_64/paging.zig");
const addr_space = @import("mm/addr_space.zig");
const slab = @import("mm/slab.zig");
const dma = @import("mm/dma.zig");
const lapic = @import("arch/x86_64/lapic.zig");
const task = @import("proc/task.zig");
const sched = @import("proc/sched.zig");
const ipc = @import("ipc/ipc.zig");
const capability = @import("ipc/capability.zig");
const syscall_entry = @import("arch/x86_64/syscall_entry.zig");
const ramdisk = @import("fs/ramdisk.zig");
const loader = @import("proc/loader.zig");

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

    gdt.init();
    klog.log(.info, "GDT loaded");

    idt.init();
    klog.log(.info, "IDT loaded");

    // VGA text mode uses MMIO at 0xB8000 which may not be HHDM-mapped;
    // skip for now, rely on serial output instead
    klog.log(.info, "VGA skipped (serial-only mode)");

    // M1 additions: TSC, symbol table
    tsc.init();
    symbol_table.init();
    klog.log(.info, "Symbol table initialized");

    // M2: Physical Memory Manager
    if (memmap_request.response) |memmap| {
        pmm.init(memmap);
    }

    // M2: Page table operations
    paging.init();

    // M2: Address space manager
    addr_space.init();

    // ACPI — must come after paging init so we can map non-RAM regions
    var rsdp_phys: u64 = 0;
    if (rsdp_request.response) |rsdp_resp| {
        rsdp_phys = rsdp_resp.address;
        mapAcpiRegion();
    }
    acpi.init(rsdp_phys);
    if (acpi.info.cpu_count > 0) {
        var buf: [64]u8 = undefined;
        serial.writeString("[INF] ACPI: ");
        serial.writeString(formatInt(&buf, acpi.info.cpu_count));
        serial.writeString(" CPUs detected\n");
    }

    // M2: Slab allocator (kernel heap)
    slab.init();

    // M2: DMA stubs
    dma.init();

    // M6.0: PCI enumeration
    const pci = @import("drivers/pci.zig");
    pci.init();

    // M3: LAPIC timer — use LAPIC address from ACPI MADT, fallback to 0xFEE00000
    const lapic_addr = if (acpi.info.lapic_address != 0) acpi.info.lapic_address else 0xFEE00000;
    lapic.init(lapic_addr);

    // M4: IPC engine + capability system
    ipc.init();
    capability.init();
    syscall_entry.init();
    klog.log(.info, "IPC engine + capabilities + syscall entry initialized");

    // M5.3: Ramdisk — parse Limine modules
    if (module_request.response) |resp| {
        if (resp.module_count > 0) {
            const mod_file = resp.modules[0];
            serial.writeString("[ramdisk] Found module: ");
            const path_len = strnLen(mod_file.path, 256);
            serial.writeString(mod_file.path[0..path_len]);
            serial.writeString(" (");
            var buf: [16]u8 = undefined;
            serial.writeString(formatInt(&buf, mod_file.size));
            serial.writeString(" bytes)\n");
            if (!ramdisk.init(mod_file.address, mod_file.size)) {
                klog.log(.info, "Failed to parse ramdisk");
            }
        } else {
            klog.log(.info, "No modules loaded");
        }
    } else {
        klog.log(.info, "Module request has no response");
    }

    // Create kernel idle thread (priority 255 = lowest, runs when nothing else is ready)
    _ = task.createKernelThread(idleThread, 255) orelse {
        klog.log(.info, "Failed to create idle thread");
        while (true) asm volatile ("hlt");
    };
    klog.log(.info, "Idle thread created");

    // M5.5: Load init program from ramdisk as the first user process (pid 1)
    if (loader.loadProgram("init", 0)) |task_idx| {
        serial.writeString("[kernel] init launched as task ");
        var buf: [16]u8 = undefined;
        serial.writeString(formatInt(&buf, task_idx));
        serial.writeString("\n");
    } else {
        klog.log(.info, "Failed to load init from ramdisk — system halted");
        while (true) asm volatile ("hlt");
    }

    // Enable interrupts and start scheduler
    klog.log(.info, "Enabling interrupts...");
    asm volatile ("sti");

    klog.log(.info, "=== MoQiOS scheduler active ===");
    while (true) {
        asm volatile ("hlt");
    }
}

/// Kernel idle thread — lowest priority, halts CPU when no other tasks are runnable.
fn idleThread() callconv(.c) void {
    while (true) {
        asm volatile ("hlt");
    }
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
pub fn mapAcpiPage(phys_addr: u64) void {
    const page = phys_addr & ~@as(u64, paging.PAGE_SIZE - 1);
    const virt = hhdm.physToVirt(page);
    const pml4 = paging.getKernelPml4();
    const flags = paging.MapFlags{
        .writable = false,
        .user = false,
        .no_execute = true,
        .global = true,
    };
    paging.mapPage(pml4, virt, page, flags) catch {};
}

fn formatInt(buf: []u8, value: u64) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var i: usize = 0;
    var v = value;
    while (v > 0) : (v /= 10) {
        buf[i] = @intCast(v % 10 + '0');
        i += 1;
    }
    var j: usize = 0;
    while (j < i / 2) : (j += 1) {
        const tmp = buf[j];
        buf[j] = buf[i - 1 - j];
        buf[i - 1 - j] = tmp;
    }
    return buf[0..i];
}

fn strnLen(s: [*:0]u8, max: usize) usize {
    var i: usize = 0;
    while (i < max and s[i] != 0) : (i += 1) {}
    return i;
}
