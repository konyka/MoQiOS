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
const paging = @import("../arch/x86_64/paging.zig");
const user_space = @import("../mm/user_space.zig");
const serial = @import("../arch/x86_64/serial.zig");

pub const ExecResult = struct {
    pml4: u64,
    entry: u64,
    stack_top: u64,
    brk: u64,
};

// ELF64 structures
const EI_NIDENT = 16;
const ELF_MAGIC = 0x464C457F; // \x7fELF in little-endian

const Elf64_Ehdr = extern struct {
    e_ident: [EI_NIDENT]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

const PT_LOAD = 1;
const PF_X: u32 = 1;
const PF_W: u32 = 2;
const PF_R: u32 = 4;

const Elf64_Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

// Auxiliary vector types (Linux ABI)
const AT_NULL: u64 = 0;
const AT_PHDR: u64 = 3;
const AT_PHNUM: u64 = 5;
const AT_PAGESZ: u64 = 6;
const AT_ENTRY: u64 = 9;
const AT_UID: u64 = 11;
const AT_EUID: u64 = 12;
const AT_GID: u64 = 13;
const AT_EGID: u64 = 14;

const Elf64_auxv_t = extern struct {
    a_type: u64,
    a_val: u64,
};

/// Information needed to build the initial user stack.
const StackInfo = struct {
    /// ELF program header table virtual address (0 for flat binaries).
    phdr_addr: u64 = 0,
    /// Number of program headers (0 for flat binaries).
    phnum: u64 = 0,
    /// Entry point virtual address.
    entry: u64 = 0,
};

/// Build the initial user stack with argc/argv/envp/auxv per Linux x86_64 ABI.
/// Writes directly to the physical stack page via HHDM.
/// Returns the new RSP value for the user process.
///
/// Stack layout (high address to low, RSP points at argc):
///   [string area: argv strings, env strings]  ← bottom of stack page
///   ... padding to 16-byte alignment ...
///   AT_NULL entry (16 bytes)
///   auxv entries (16 bytes each)
///   NULL (envp terminator, 8 bytes)
///   envp pointers (8 bytes each, currently none)
///   NULL (argv terminator, 8 bytes)
///   argv[0..argc-1] pointers (8 bytes each)
///   argc (8 bytes)                             ← RSP
pub fn buildUserStack(
    stack_phys: u64,
    stack_top: u64,
    argv: []const []const u8,
    info: StackInfo,
) u64 {
    // Access the stack page via HHDM
    const page_base: [*]u8 = @ptrFromInt(hhdm.physToVirt(stack_phys));
    const page_size: u64 = user_space.PAGE_SIZE;

    // Phase 1: Write string data at the bottom of the stack page.
    var str_offset: u64 = 0;
    var argv_offsets: [16]u64 = @splat(0);

    for (argv, 0..) |arg, i| {
        if (i >= 16) break;
        argv_offsets[i] = str_offset;
        @memcpy(page_base[str_offset .. str_offset + arg.len], arg);
        str_offset += arg.len;
        page_base[str_offset] = 0;
        str_offset += 1;
    }
    const argc = @min(argv.len, @as(usize, 16));

    // Phase 2: Build the structure from the top of the page downward.
    // We'll compute offsets relative to the start of the page, then
    // convert to user-virtual addresses at the end.
    var pos: u64 = page_size;

    // Helper: push a u64 value (decrement pos by 8, write value)
    const push64 = struct {
        fn f(p: *u64, base: [*]u8, val: u64) void {
            p.* -= 8;
            @atomicStore(u64, @as(*u64, @ptrFromInt(@intFromPtr(base + p.*))), val, .monotonic);
        }
    }.f;

    // AT_NULL entry (auxv terminator)
    push64(&pos, page_base, 0); // a_val = 0
    push64(&pos, page_base, AT_NULL); // a_type = AT_NULL

    // auxv entries (pushed in reverse order)
    // AT_EGID
    push64(&pos, page_base, 0);
    push64(&pos, page_base, AT_EGID);
    // AT_GID
    push64(&pos, page_base, 0);
    push64(&pos, page_base, AT_GID);
    // AT_EUID
    push64(&pos, page_base, 0);
    push64(&pos, page_base, AT_EUID);
    // AT_UID
    push64(&pos, page_base, 0);
    push64(&pos, page_base, AT_UID);
    // AT_ENTRY
    push64(&pos, page_base, info.entry);
    push64(&pos, page_base, AT_ENTRY);
    // AT_PAGESZ
    push64(&pos, page_base, page_size);
    push64(&pos, page_base, AT_PAGESZ);
    // AT_PHNUM
    if (info.phnum > 0) {
        push64(&pos, page_base, info.phnum);
        push64(&pos, page_base, AT_PHNUM);
    }
    // AT_PHDR
    if (info.phdr_addr != 0) {
        push64(&pos, page_base, info.phdr_addr);
        push64(&pos, page_base, AT_PHDR);
    }

    // envp terminator (no env vars yet)
    push64(&pos, page_base, 0);

    // Pad to ensure 16-byte alignment of final RSP.
    {
        const remaining_pushes: u64 = argc + 2;
        const final_pos = pos - remaining_pushes * 8;
        if (final_pos % 16 != 0) {
            push64(&pos, page_base, 0);
        }
    }

    // argv terminator
    push64(&pos, page_base, 0);

    // argv pointers (in reverse order)
    var ai: usize = argc;
    while (ai > 0) {
        ai -= 1;
        const arg_user_addr: u64 = stack_top - page_size + argv_offsets[ai];
        push64(&pos, page_base, arg_user_addr);
    }

    // argc
    push64(&pos, page_base, argc);

    const user_rsp: u64 = stack_top - page_size + pos;
    return user_rsp;
}

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

    // Check for ELF magic
    if (binary_size >= @sizeOf(Elf64_Ehdr)) {
        if (file.data[0] == 0x7F and file.data[1] == 'E' and
            file.data[2] == 'L' and file.data[3] == 'F')
        {
            // Copy ELF header to aligned stack buffer
            var ehdr_buf: [@sizeOf(Elf64_Ehdr)]u8 align(@alignOf(Elf64_Ehdr)) = undefined;
            @memcpy(ehdr_buf[0..@sizeOf(Elf64_Ehdr)], file.data[0..@sizeOf(Elf64_Ehdr)]);
            const ehdr: *const Elf64_Ehdr = @ptrCast(&ehdr_buf);
            return loadElf(file, ehdr, name, parent_tid);
        }
    }

    // Flat binary fallback
    return loadFlatBinary(file, name, parent_tid);
}

/// Load an ELF64 executable.
fn loadElf(file: ramdisk.RamdiskFile, ehdr: *const Elf64_Ehdr, name: []const u8, parent_tid: u32) ?u32 {
    // Validate ELF header
    if (ehdr.e_ident[4] != 2) { // ELFCLASS64
        serial.writeString("[loader] Not a 64-bit ELF\n");
        return null;
    }
    if (ehdr.e_ident[5] != 1) { // ELFDATA2LSB
        serial.writeString("[loader] Not little-endian ELF\n");
        return null;
    }
    if (ehdr.e_machine != 0x3E) { // EM_X86_64
        serial.writeString("[loader] Not x86_64 ELF\n");
        return null;
    }
    if (ehdr.e_type != 2 and ehdr.e_type != 3) { // ET_EXEC or ET_DYN
        serial.writeString("[loader] Not an executable ELF\n");
        return null;
    }

    const user_pml4 = user_space.createUserSpace() orelse {
        serial.writeString("[loader] OOM for user PML4\n");
        return null;
    };

    // Track highest loaded address for brk initialization
    var highest_addr: u64 = 0;
    var success = true;
    var loaded_segments: u32 = 0;

    // Process each PT_LOAD segment
    const phnum = ehdr.e_phnum;
    const phentsize = ehdr.e_phentsize;
    const phoff = ehdr.e_phoff;

    for (0..phnum) |i| {
        if (phoff + (i + 1) * phentsize > file.size) break;
        // Copy program header to aligned buffer for safe access
        var phdr_buf: [@sizeOf(Elf64_Phdr)]u8 align(@alignOf(Elf64_Phdr)) = undefined;
        const phdr_src_start = phoff + i * phentsize;
        const phdr_copy_len = @min(phentsize, @sizeOf(Elf64_Phdr));
        @memcpy(phdr_buf[0..phdr_copy_len], file.data[phdr_src_start .. phdr_src_start + phdr_copy_len]);
        if (phdr_copy_len < @sizeOf(Elf64_Phdr)) {
            @memset(phdr_buf[phdr_copy_len..], 0);
        }
        const phdr: *const Elf64_Phdr = @ptrCast(&phdr_buf);

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

        const _writable = (seg_flags & PF_W) != 0;
        _ = _writable;
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

            const map_flags = paging.MapFlags{
                .writable = true, // Map writable initially for loading
                .user = true,
                .no_execute = !executable,
                .global = false,
            };
            paging.mapPage(user_pml4, page_vaddr, phys, map_flags) catch {
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
    user_space.mapUserPage(user_pml4, user_stack_base, stack_phys, true) catch {
        serial.writeString("[loader] Failed to map stack\n");
        pmm.freePage(stack_phys);
        user_space.destroyUserSpace(user_pml4);
        return null;
    };

    // Build initial user stack with argc/argv/auxv
    const user_rsp = buildUserStack(stack_phys, user_space.USER_STACK_TOP, &.{name}, .{
        .phdr_addr = 0, // TODO: compute from ELF segments
        .phnum = ehdr.e_phnum,
        .entry = ehdr.e_entry,
    });

    // Create task with ELF entry point
    const new_task = task.createUserProcess(
        ehdr.e_entry,
        user_rsp,
        user_pml4,
        parent_tid,
    ) orelse {
        serial.writeString("[loader] Failed to create task\n");
        user_space.destroyUserSpace(user_pml4);
        return null;
    };

    // Set initial brk to just after the highest loaded segment
    if (task.getTask(new_task)) |t| {
        t.brk_current = highest_addr;
    }

    serial.writeString("[loader] Loaded ");
    serial.writeString(name);
    serial.writeString(" as task ");
    var buf: [16]u8 = undefined;
    serial.writeString(formatInt(&buf, new_task));
    serial.writeString(" (ELF, entry=0x");
    serial.writeString(formatHex(&buf, ehdr.e_entry));
    serial.writeString(", ");
    serial.writeString(formatInt(&buf, loaded_segments));
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
        paging.mapPage(user_pml4, virt_addr, code_pages[p].?, code_flags) catch {
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
    user_space.mapUserPage(user_pml4, user_stack_base, stack_phys, true) catch {
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
    ) orelse {
        serial.writeString("[loader] Failed to create task\n");
        user_space.destroyUserSpace(user_pml4);
        freePages(&code_pages, allocated);
        return null;
    };

    const heap_start = user_space.USER_CODE_BASE + allocated * paging.PAGE_SIZE;
    if (task.getTask(new_task)) |t| {
        t.brk_current = heap_start;
    }

    serial.writeString("[loader] Loaded ");
    serial.writeString(name);
    serial.writeString(" as task ");
    var buf: [16]u8 = undefined;
    serial.writeString(formatInt(&buf, new_task));
    serial.writeString(" (");
    serial.writeString(formatInt(&buf, binary_size));
    serial.writeString(" bytes, ");
    serial.writeString(formatInt(&buf, pages_needed));
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

fn formatHex(buf: []u8, value: u64) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var i: usize = 0;
    var v = value;
    while (v > 0 and i < buf.len) : (v >>= 4) {
        const nibble: u8 = @intCast(v & 0xF);
        buf[i] = if (nibble < 10) '0' + nibble else 'a' + nibble - 10;
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

pub fn loadProgramForExec(name: []const u8, argv: []const []const u8) ?ExecResult {
    const file = ramdisk.findFile(name) orelse return null;
    const binary_size = file.size;
    if (binary_size == 0 or binary_size > 4 * 1024 * 1024) return null;
    if (binary_size < @sizeOf(Elf64_Ehdr)) return null;
    if (!(file.data[0] == 0x7F and file.data[1] == 'E' and file.data[2] == 'L' and file.data[3] == 'F')) return null;

    var ehdr_buf: [@sizeOf(Elf64_Ehdr)]u8 align(@alignOf(Elf64_Ehdr)) = undefined;
    @memcpy(ehdr_buf[0..@sizeOf(Elf64_Ehdr)], file.data[0..@sizeOf(Elf64_Ehdr)]);
    const ehdr: *const Elf64_Ehdr = @ptrCast(&ehdr_buf);

    if (ehdr.e_ident[4] != 2 or ehdr.e_ident[5] != 1 or ehdr.e_machine != 0x3E) return null;
    if (ehdr.e_type != 2 and ehdr.e_type != 3) return null;

    const new_pml4 = user_space.createUserSpace() orelse return null;
    var highest_addr: u64 = 0;
    var success = true;
    var loaded_segments: u32 = 0;
    const phnum = ehdr.e_phnum;
    const phentsize = ehdr.e_phentsize;
    const phoff = ehdr.e_phoff;

    for (0..phnum) |i| {
        if (phoff + (i + 1) * phentsize > file.size) break;
        var phdr_buf: [@sizeOf(Elf64_Phdr)]u8 align(@alignOf(Elf64_Phdr)) = undefined;
        const start = phoff + i * phentsize;
        const clen = @min(phentsize, @sizeOf(Elf64_Phdr));
        @memcpy(phdr_buf[0..clen], file.data[start .. start + clen]);
        if (clen < @sizeOf(Elf64_Phdr)) @memset(phdr_buf[clen..], 0);
        const phdr: *const Elf64_Phdr = @ptrCast(&phdr_buf);
        if (phdr.p_type != PT_LOAD) continue;

        const seg_vaddr = phdr.p_vaddr;
        const seg_filesz = phdr.p_filesz;
        const seg_memsz = phdr.p_memsz;
        const seg_offset = phdr.p_offset;
        if (seg_vaddr >= 0x0000_8000_0000_0000) { success = false; break; }

        const seg_flags = phdr.p_flags;
        const seg_writable = (seg_flags & 0x2) != 0;
        const seg_executable = (seg_flags & 0x1) != 0;

        const seg_start = seg_vaddr & ~(paging.PAGE_SIZE - 1);
        const seg_end_page = (seg_vaddr + seg_memsz + paging.PAGE_SIZE - 1) & ~(paging.PAGE_SIZE - 1);
        const num_pages = (seg_end_page - seg_start) / paging.PAGE_SIZE;
        if (num_pages == 0 or num_pages > 512) continue;

        for (0..num_pages) |p| {
            const page_vaddr = seg_start + p * paging.PAGE_SIZE;
            const phys = pmm.allocPage() orelse { success = false; break; };
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
            paging.mapPage(new_pml4, page_vaddr, phys, map_flags) catch { success = false; break; };
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
    user_space.mapUserPage(new_pml4, user_stack_base, stack_phys, true) catch {
        user_space.destroyUserSpace(new_pml4);
        return null;
    };

    const user_rsp = buildUserStack(stack_phys, user_space.USER_STACK_TOP, argv, .{});

    {
        var buf2: [32]u8 = undefined;
        serial.writeString("[loader-exec] entry=0x");
        serial.writeString(formatHex(&buf2, ehdr.e_entry));
        serial.writeString(" phnum=");
        serial.writeString(formatInt(&buf2, ehdr.e_phnum));
        serial.writeString("\n");
    }

    return ExecResult{
        .pml4 = new_pml4,
        .entry = ehdr.e_entry,
        .stack_top = user_rsp,
        .brk = highest_addr,
    };
}
