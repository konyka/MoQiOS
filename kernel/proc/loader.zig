const ramdisk = @import("../fs/ramdisk.zig");
const task = @import("task.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const paging = @import("../arch/x86_64/paging.zig");
const user_space = @import("../mm/user_space.zig");
const serial = @import("../arch/x86_64/serial.zig");

pub fn loadProgram(name: []const u8) ?u32 {
    const file = ramdisk.findFile(name) orelse {
        serial.writeString("[loader] File not found: ");
        serial.writeString(name);
        serial.writeString("\n");
        return null;
    };

    const binary_size = file.size;
    if (binary_size == 0 or binary_size > 1024 * 1024) {
        serial.writeString("[loader] Invalid binary size\n");
        return null;
    }

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

    const copy_len: u64 = @min(binary_size, paging.PAGE_SIZE);
    for (0..allocated) |p| {
        const phys = code_pages[p].?;
        const virt = hhdm.physToVirt(phys);
        const dst: [*]u8 = @ptrFromInt(virt);
        if (p == 0) {
            @memcpy(dst[0..copy_len], file.data[0..copy_len]);
            if (copy_len < paging.PAGE_SIZE) {
                @memset(dst[copy_len..paging.PAGE_SIZE], 0);
            }
        } else {
            const src_off = p * paging.PAGE_SIZE;
            const remaining = binary_size - src_off;
            const chunk_len: u64 = @min(remaining, paging.PAGE_SIZE);
            @memcpy(dst[0..chunk_len], file.data[src_off .. src_off + chunk_len]);
            if (chunk_len < paging.PAGE_SIZE) {
                @memset(dst[chunk_len..paging.PAGE_SIZE], 0);
            }
        }
    }

    for (0..allocated) |p| {
        const virt_addr = user_space.USER_CODE_BASE + p * paging.PAGE_SIZE;
        const code_flags = paging.MapFlags{
            .writable = false,
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
        serial.writeString("[loader] OOM for stack page\n");
        user_space.destroyUserSpace(user_pml4);
        freePages(&code_pages, allocated);
        return null;
    };
    const user_stack_base = user_space.USER_STACK_TOP - paging.PAGE_SIZE;
    user_space.mapUserPage(user_pml4, user_stack_base, stack_phys, true) catch {
        serial.writeString("[loader] Failed to map stack page\n");
        pmm.freePage(stack_phys);
        user_space.destroyUserSpace(user_pml4);
        freePages(&code_pages, allocated);
        return null;
    };

    const new_task = task.createUserProcess(
        user_space.USER_CODE_BASE,
        user_space.USER_STACK_TOP,
        user_pml4,
    ) orelse {
        serial.writeString("[loader] Failed to create task\n");
        user_space.destroyUserSpace(user_pml4);
        freePages(&code_pages, allocated);
        return null;
    };

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
