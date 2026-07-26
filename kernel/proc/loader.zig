/// ELF64 loader — loads ELF binaries from ramdisk into user address space.
///
/// Supports:
///   - ELF64 little-endian x86_64 executables
///   - PT_LOAD segments with separate virtual addresses
///   - Entry point from ELF header (not offset 0)
///
/// Falls back to flat binary loading if the file is not ELF.
const ramdisk = @import("../fs/ramdisk.zig");
const task = @import("task.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const paging = @import("../arch/arch.zig").paging;
const user_space = @import("../mm/user_space.zig");
const serial = @import("../arch/arch.zig").serial;
const fmt = @import("../lib/fmt.zig");

pub const ExecResult = struct {
    pml4: u64,
    entry: u64,
    stack_top: u64,
    brk: u64,
};

// ELF64 structures + header/phdr parsing live in the shared module (SK-44).
const elf = @import("elf.zig");
const Elf64_Ehdr = elf.Elf64_Ehdr;
const Elf64_Phdr = elf.Elf64_Phdr;
const PT_LOAD = elf.PT_LOAD;
const PT_INTERP = elf.PT_INTERP;
const PF_X = elf.PF_X;
const PF_W = elf.PF_W;
const PF_R = elf.PF_R;

// SK-45: the initial-user-stack builder (Linux ABI argc/argv/envp/auxv) is
// shared across arches in `proc/user_stack.zig`; loader re-exports it.
const user_stack = @import("user_stack.zig");
const StackInfo = user_stack.StackInfo;
pub const buildUserStack = user_stack.buildUserStack;

/// Load a program from ramdisk. Detects ELF vs flat binary automatically.
pub fn loadProgram(name: []const u8, parent_tid: u32) ?u32 {
    const file = ramdisk.findFile(name) orelse {
        serial.writeString("[loader] File not found: ");
        serial.writeString(name);
        serial.writeString("\n");
        return null;
    };

    const binary_size = file.size;
    if (binary_size == 0 or binary_size > 4 * 1024 * 1024) {
        serial.writeString("[loader] Invalid binary size\n");
        return null;
    }

    // ELF path: shared validation (SK-44). A file with ELF magic that fails
    // validation is an error — never fall through to the flat-binary loader.
    if (elf.hasMagic(file.data, file.size)) {
        const ehdr = elf.parseHeader(file.data, file.size) orelse {
            serial.writeString("[loader] Invalid ELF header\n");
            return null;
        };
        return loadElf(file, &ehdr, name, parent_tid);
    }

    // Flat binary fallback
    return loadFlatBinary(file, name, parent_tid);
}

/// Load an ELF64 executable (header already validated by elf.parseHeader).
fn loadElf(file: ramdisk.RamdiskFile, ehdr: *const Elf64_Ehdr, name: []const u8, parent_tid: u32) ?u32 {
    const user_pml4 = user_space.createUserSpace() orelse {
        serial.writeString("[loader] OOM for user PML4\n");
        return null;
    };
    serial.writeString("[loader] Flat address space ready\n");

    // Track highest loaded address for brk initialization
    var highest_addr: u64 = 0;
    var success = true;
    var loaded_segments: u32 = 0;

    // Process each PT_LOAD segment
    const phnum = ehdr.e_phnum;
    const phoff = ehdr.e_phoff;

    // Scan for PT_INTERP (dynamic linker) and PT_PHDR
    var phdr_addr: u64 = 0;
    for (0..phnum) |i| {
        const phdr = elf.readPhdr(file.data, file.size, ehdr, i) orelse break;
        if (phdr.p_type == PT_INTERP) {
            serial.writeString("[loader] PT_INTERP detected (dynamic linking not yet supported)\n");
            // Don't break — continue scanning for PT_PHDR
        }
        if (phdr.p_type == elf.PT_PHDR) {
            phdr_addr = phdr.p_vaddr;
        }
    }

    for (0..phnum) |i| {
        const phdr = elf.readPhdr(file.data, file.size, ehdr, i) orelse break;

        if (phdr.p_type != PT_LOAD) continue;

        const seg_vaddr = phdr.p_vaddr;
        const seg_filesz = phdr.p_filesz;
        const seg_memsz = phdr.p_memsz;
        const seg_offset = phdr.p_offset;
        const seg_flags = phdr.p_flags;

        // Validate segment is in user space
        if (seg_vaddr >= 0x0000_8000_0000_0000) {
            serial.writeString("[loader] Segment vaddr in kernel space\n");
            success = false;
            break;
        }

        // Page-aligned bounds
        const seg_start = seg_vaddr & ~(paging.PAGE_SIZE - 1);
        const seg_end_page = (seg_vaddr + seg_memsz + paging.PAGE_SIZE - 1) & ~(paging.PAGE_SIZE - 1);
        const num_pages = (seg_end_page - seg_start) / paging.PAGE_SIZE;

        if (num_pages == 0 or num_pages > 512) continue; // Skip empty or oversized segments

        const writable = (seg_flags & PF_W) != 0;
        const executable = (seg_flags & PF_X) != 0;

        // Allocate and map pages for this segment
        for (0..num_pages) |p| {
            const page_vaddr = seg_start + p * paging.PAGE_SIZE;
            const phys = pmm.allocPage() orelse {
                serial.writeString("[loader] OOM for ELF segment\n");
                success = false;
                break;
            };

            // Zero the page first (handles BSS/memset automatically)
            const page_virt = hhdm.physToVirt(phys);
            const dst: [*]u8 = @ptrFromInt(page_virt);
            @memset(dst[0..paging.PAGE_SIZE], 0);

            // Calculate which part of this page corresponds to file data
            // Virtual range of this page within the segment
            const page_start_in_seg = page_vaddr -| seg_vaddr; // offset into segment's vaddr range
            const page_end_in_seg = page_start_in_seg + paging.PAGE_SIZE;

            // File data range for this page
            const file_copy_start = if (page_start_in_seg < seg_filesz) page_start_in_seg else seg_filesz;
            const file_copy_end = @min(page_end_in_seg, seg_filesz);

            if (file_copy_end > file_copy_start) {
                const copy_len = file_copy_end - file_copy_start;
                const src_offset_in_file = seg_offset + file_copy_start;
                // Where in the page to write (offset for page alignment)
                const page_offset = if (page_vaddr < seg_vaddr) seg_vaddr - page_vaddr else 0;
                if (src_offset_in_file + copy_len <= file.size) {
                    @memcpy(
                        dst[page_offset .. page_offset + copy_len],
                        file.data[src_offset_in_file .. src_offset_in_file + copy_len],
                    );
                }
            }

            // Segment contents go in through the HHDM alias above, not through
            // this mapping, so a read-only segment can be honoured from the
            // start — text and rodata never need a writable window.
            const map_flags = paging.MapFlags{
                .writable = writable,
                .user = true,
                .no_execute = !executable,
                .global = false,
            };
            paging.mapPageNoFlush(user_pml4, page_vaddr, phys, map_flags) catch {
                serial.writeString("[loader] Failed to map ELF page\n");
                pmm.freePage(phys);
                success = false;
                break;
            };
        }

        if (!success) break;

        const seg_end = seg_start + num_pages * paging.PAGE_SIZE;
        if (seg_end > highest_addr) {
            highest_addr = seg_end;
        }
        loaded_segments += 1;
    }

    if (!success or loaded_segments == 0) {
        user_space.destroyUserSpace(user_pml4);
        return null;
    }

    // Set up user stack
    const stack_phys = pmm.allocPage() orelse {
        serial.writeString("[loader] OOM for stack\n");
        user_space.destroyUserSpace(user_pml4);
        return null;
    };
    const user_stack_base = user_space.USER_STACK_TOP - paging.PAGE_SIZE;
    user_space.mapUserPageNoFlush(user_pml4, user_stack_base, stack_phys, true) catch {
        serial.writeString("[loader] Failed to map stack\n");
        pmm.freePage(stack_phys);
        user_space.destroyUserSpace(user_pml4);
        return null;
    };

    // Compute phdr_addr if no PT_PHDR segment found
    // For ET_EXEC: phdr is at e_phoff in the file, mapped at e_phoff virtual
    // For ET_DYN: phdr_addr is relative to load base (already set by PT_PHDR above)
    if (phdr_addr == 0 and phoff > 0) {
        phdr_addr = phoff; // file offset = virtual address for non-PIE executables
    }

    // Build initial user stack with argc/argv/auxv
    const user_rsp = buildUserStack(stack_phys, user_space.USER_STACK_TOP, &.{name}, .{
        .phdr_addr = phdr_addr,
        .phnum = ehdr.e_phnum,
        .entry = ehdr.e_entry,
    });

    // Create task with ELF entry point
    const new_task = task.createUserProcess(
        ehdr.e_entry,
        user_rsp,
        user_pml4,
        parent_tid,
        true,
    ) orelse {
        serial.writeString("[loader] Failed to create task\n");
        user_space.destroyUserSpace(user_pml4);
        return null;
    };

    task.kickRemoteForTask(new_task);

    // Set initial brk to just after the highest loaded segment
    if (task.getTask(new_task)) |t| {
        t.brk_current = highest_addr;
        t.brk_start = highest_addr;
    }

    serial.writeString("[loader] Loaded ");
    serial.writeString(name);
    serial.writeString(" as task ");
    fmt.writeDecimal(new_task);
    serial.writeString(" (ELF, entry=0x");
    fmt.writeHex(ehdr.e_entry);
    serial.writeString(", ");
    fmt.writeDecimal(loaded_segments);
    serial.writeString(" segments)\n");

    return new_task;
}

/// Load a flat binary (no ELF headers) at USER_CODE_BASE.
fn loadFlatBinary(file: ramdisk.RamdiskFile, name: []const u8, parent_tid: u32) ?u32 {
    const binary_size = file.size;
    const pages_needed = (binary_size + paging.PAGE_SIZE - 1) / paging.PAGE_SIZE;

    const user_pml4 = user_space.createUserSpace() orelse {
        serial.writeString("[loader] OOM for user PML4\n");
        return null;
    };

    var code_pages: [256]?u64 = [_]?u64{null} ** 256;
    var allocated: u64 = 0;
    while (allocated < pages_needed) : (allocated += 1) {
        code_pages[allocated] = pmm.allocPage() orelse {
            serial.writeString("[loader] OOM for code pages\n");
            freePages(&code_pages, allocated);
            pmm.freePage(user_pml4);
            return null;
        };
    }

    for (0..allocated) |p| {
        const phys = code_pages[p].?;
        const virt = hhdm.physToVirt(phys);
        const dst: [*]u8 = @ptrFromInt(virt);
        const src_off = p * paging.PAGE_SIZE;
        const remaining = binary_size - src_off;
        const chunk_len: u64 = @min(remaining, paging.PAGE_SIZE);
        @memcpy(dst[0..chunk_len], file.data[src_off .. src_off + chunk_len]);
        if (chunk_len < paging.PAGE_SIZE) {
            @memset(dst[chunk_len..paging.PAGE_SIZE], 0);
        }
    }

    for (0..allocated) |p| {
        const virt_addr = user_space.USER_CODE_BASE + p * paging.PAGE_SIZE;
        const code_flags = paging.MapFlags{
            .writable = true,
            .user = true,
            .no_execute = false,
            .global = false,
        };
        paging.mapPageNoFlush(user_pml4, virt_addr, code_pages[p].?, code_flags) catch {
            serial.writeString("[loader] Failed to map code page\n");
            user_space.destroyUserSpace(user_pml4);
            freePages(&code_pages, allocated);
            return null;
        };
    }

    const stack_phys = pmm.allocPage() orelse {
        serial.writeString("[loader] OOM for stack\n");
        user_space.destroyUserSpace(user_pml4);
        freePages(&code_pages, allocated);
        return null;
    };
    const user_stack_base = user_space.USER_STACK_TOP - paging.PAGE_SIZE;
    user_space.mapUserPageNoFlush(user_pml4, user_stack_base, stack_phys, true) catch {
        serial.writeString("[loader] Failed to map stack\n");
        pmm.freePage(stack_phys);
        user_space.destroyUserSpace(user_pml4);
        freePages(&code_pages, allocated);
        return null;
    };

    // Build initial user stack with argc/argv/auxv
    const user_rsp = buildUserStack(stack_phys, user_space.USER_STACK_TOP, &.{name}, .{
        .entry = user_space.USER_CODE_BASE,
    });

    const new_task = task.createUserProcess(
        user_space.USER_CODE_BASE,
        user_rsp,
        user_pml4,
        parent_tid,
        false,
    ) orelse {
        serial.writeString("[loader] Failed to create task\n");
        user_space.destroyUserSpace(user_pml4);
        freePages(&code_pages, allocated);
        return null;
    };

    task.kickRemoteForTask(new_task);

    const heap_start = user_space.USER_CODE_BASE + allocated * paging.PAGE_SIZE;
    if (task.getTask(new_task)) |t| {
        t.brk_current = heap_start;
        t.brk_start = heap_start;
    }

    serial.writeString("[loader] Loaded ");
    serial.writeString(name);
    serial.writeString(" as task ");
    fmt.writeDecimal(new_task);
    serial.writeString(" (");
    fmt.writeDecimal64(binary_size);
    serial.writeString(" bytes, ");
    fmt.writeDecimal64(pages_needed);
    serial.writeString(" pages)\n");

    return new_task;
}

fn freePages(pages: *[256]?u64, count: u64) void {
    for (0..count) |i| {
        if (pages[i]) |phys| {
            pmm.freePage(phys);
            pages[i] = null;
        }
    }
}

pub fn loadProgramForExec(name: []const u8, argv: []const []const u8) ?ExecResult {
    const file = ramdisk.findFile(name) orelse return null;
    const binary_size = file.size;
    if (binary_size == 0 or binary_size > 4 * 1024 * 1024) return null;
    // Shared validation (SK-44): magic, class, endianness, machine, type.
    const ehdr_v = elf.parseHeader(file.data, file.size) orelse return null;
    const ehdr = &ehdr_v;

    const new_pml4 = user_space.createUserSpace() orelse return null;
    var highest_addr: u64 = 0;
    var success = true;
    var loaded_segments: u32 = 0;
    const phnum = ehdr.e_phnum;

    for (0..phnum) |i| {
        const phdr = elf.readPhdr(file.data, file.size, ehdr, i) orelse break;
        if (phdr.p_type != PT_LOAD) continue;

        const seg_vaddr = phdr.p_vaddr;
        const seg_filesz = phdr.p_filesz;
        const seg_memsz = phdr.p_memsz;
        const seg_offset = phdr.p_offset;
        if (seg_vaddr >= 0x0000_8000_0000_0000) {
            success = false;
            break;
        }

        const seg_flags = phdr.p_flags;
        const seg_writable = (seg_flags & 0x2) != 0;
        const seg_executable = (seg_flags & 0x1) != 0;

        const seg_start = seg_vaddr & ~(paging.PAGE_SIZE - 1);
        const seg_end_page = (seg_vaddr + seg_memsz + paging.PAGE_SIZE - 1) & ~(paging.PAGE_SIZE - 1);
        const num_pages = (seg_end_page - seg_start) / paging.PAGE_SIZE;
        if (num_pages == 0 or num_pages > 512) continue;

        for (0..num_pages) |p| {
            const page_vaddr = seg_start + p * paging.PAGE_SIZE;
            const phys = pmm.allocPage() orelse {
                success = false;
                break;
            };
            const dst: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
            @memset(dst[0..paging.PAGE_SIZE], 0);

            const ps = page_vaddr -| seg_vaddr;
            const pe = ps + paging.PAGE_SIZE;
            const fcs = if (ps < seg_filesz) ps else seg_filesz;
            const fce = @min(pe, seg_filesz);
            if (fce > fcs) {
                const cl = fce - fcs;
                const soff = seg_offset + fcs;
                const poff: usize = if (page_vaddr < seg_vaddr) @intCast(seg_vaddr - page_vaddr) else 0;
                if (soff + cl <= file.size) {
                    @memcpy(dst[poff .. poff + cl], file.data[soff .. soff + cl]);
                }
            }
            // Map with correct permissions: code pages must NOT have NX bit set
            const map_flags = paging.MapFlags{
                .writable = seg_writable,
                .user = true,
                .no_execute = !seg_executable,
                .global = false,
            };
            paging.mapPageNoFlush(new_pml4, page_vaddr, phys, map_flags) catch {
                success = false;
                break;
            };
        }
        const seg_end = seg_vaddr + seg_memsz;
        if (seg_end > highest_addr) highest_addr = seg_end;
        loaded_segments += 1;
    }

    if (!success or loaded_segments == 0) {
        user_space.destroyUserSpace(new_pml4);
        return null;
    }

    const stack_phys = pmm.allocPage() orelse {
        user_space.destroyUserSpace(new_pml4);
        return null;
    };
    const user_stack_base = user_space.USER_STACK_TOP - paging.PAGE_SIZE;
    user_space.mapUserPageNoFlush(new_pml4, user_stack_base, stack_phys, true) catch {
        user_space.destroyUserSpace(new_pml4);
        return null;
    };

    const user_rsp = buildUserStack(stack_phys, user_space.USER_STACK_TOP, argv, .{});

    {
        serial.writeString("[loader-exec] entry=0x");
        fmt.writeHex(ehdr.e_entry);
        serial.writeString(" phnum=");
        fmt.writeDecimal(ehdr.e_phnum);
        serial.writeString("\n");
    }

    return ExecResult{
        .pml4 = new_pml4,
        .entry = ehdr.e_entry,
        .stack_top = user_rsp,
        .brk = highest_addr,
    };
}
