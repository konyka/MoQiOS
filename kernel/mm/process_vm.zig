/// process_vm_readv / process_vm_writev — cross-process memory access.
///
/// Read or write memory of another process via iovec vectors,
/// walking the target's page table directly.
/// Extracted from syscall_entry.zig (v18.8).
const futex_mod = @import("../sync/futex.zig");
const task_mod = @import("../proc/task.zig");
const paging_mod = @import("../arch/arch.zig").paging;
const hhdm_mod = @import("../mm/hhdm.zig");

/// process_vm_readv(pid, local_iov, liovcnt, remote_iov, riovcnt, flags) -> bytes read or -errno.
pub fn processVmReadv(target_pid: u32, local_iov_ptr: u64, liovcnt: u64, remote_iov_ptr: u64, riovcnt: u64) i64 {
    if (local_iov_ptr == 0 or local_iov_ptr >= 0x0000_8000_0000_0000 or
        remote_iov_ptr == 0 or remote_iov_ptr >= 0x0000_8000_0000_0000)
        return -14; // -EFAULT
    if (liovcnt == 0 or riovcnt == 0) return 0;

    // Find target process
    var target_page_table: u64 = 0;
    for (0..task_mod.MAX_TASKS) |i| {
        if (task_mod.getTask(@intCast(i))) |t| {
            if (t.tid == target_pid and t.state != .zombie) {
                target_page_table = t.page_table_phys;
                break;
            }
        }
    }
    if (target_page_table == 0) return -3; // -ESRCH

    var total: u64 = 0;
    const iov_count = @min(liovcnt, riovcnt);
    const max_iov: u32 = @intCast(@min(iov_count, 16));

    var i: u32 = 0;
    while (i < max_iov) : (i += 1) {
        const local_off = i * 16;
        const local_base = futex_mod.copyUserU64(local_iov_ptr + local_off);
        const local_len = futex_mod.copyUserU64(local_iov_ptr + local_off + 8);
        const remote_off = i * 16;
        const remote_base = futex_mod.copyUserU64(remote_iov_ptr + remote_off);
        const remote_len = futex_mod.copyUserU64(remote_iov_ptr + remote_off + 8);

        const copy_len: u64 = @min(local_len, remote_len);
        if (copy_len == 0) continue;

        // Copy byte-by-byte via page table translation
        var copied: u64 = 0;
        while (copied < copy_len) : (copied += 1) {
            const remote_addr = remote_base + copied;
            const pte_val = paging_mod.getPageEntryRaw(target_page_table, remote_addr) orelse break;
            if (pte_val & 1 == 0) break; // not present
            const phys = pte_val & 0x000F_FFFF_FFFF_F000;
            const page_offset = remote_addr & 0xFFF;
            const src_ptr: [*]const u8 = @ptrCast(hhdm_mod.physToPtr(u8, phys));
            const dst_addr = local_base + copied;
            if (dst_addr >= 0x0000_8000_0000_0000) break;
            const dst_ptr: [*]u8 = @ptrFromInt(dst_addr);
            dst_ptr[0] = src_ptr[page_offset];
        }
        total += copied;
    }
    return @bitCast(total);
}

/// process_vm_writev(pid, local_iov, liovcnt, remote_iov, riovcnt, flags) -> bytes written or -errno.
pub fn processVmWritev(target_pid: u32, local_iov_ptr: u64, liovcnt: u64, remote_iov_ptr: u64, riovcnt: u64) i64 {
    if (local_iov_ptr == 0 or local_iov_ptr >= 0x0000_8000_0000_0000 or
        remote_iov_ptr == 0 or remote_iov_ptr >= 0x0000_8000_0000_0000)
        return -14; // -EFAULT
    if (liovcnt == 0 or riovcnt == 0) return 0;

    var target_page_table: u64 = 0;
    for (0..task_mod.MAX_TASKS) |i| {
        if (task_mod.getTask(@intCast(i))) |t| {
            if (t.tid == target_pid and t.state != .zombie) {
                target_page_table = t.page_table_phys;
                break;
            }
        }
    }
    if (target_page_table == 0) return -3; // -ESRCH

    var total: u64 = 0;
    const iov_count = @min(liovcnt, riovcnt);
    const max_iov: u32 = @intCast(@min(iov_count, 16));

    var i: u32 = 0;
    while (i < max_iov) : (i += 1) {
        const local_off = i * 16;
        const local_base = futex_mod.copyUserU64(local_iov_ptr + local_off);
        const local_len = futex_mod.copyUserU64(local_iov_ptr + local_off + 8);
        const remote_off = i * 16;
        const remote_base = futex_mod.copyUserU64(remote_iov_ptr + remote_off);
        const remote_len = futex_mod.copyUserU64(remote_iov_ptr + remote_off + 8);

        const copy_len: u64 = @min(local_len, remote_len);
        if (copy_len == 0) continue;

        var copied: u64 = 0;
        while (copied < copy_len) : (copied += 1) {
            const remote_addr = remote_base + copied;
            const pte_val = paging_mod.getPageEntryRaw(target_page_table, remote_addr) orelse break;
            if (pte_val & 1 == 0) break;
            if (pte_val & 2 == 0) break; // not writable
            const phys = pte_val & 0x000F_FFFF_FFFF_F000;
            const page_offset = remote_addr & 0xFFF;
            const dst_ptr: [*]u8 = @ptrCast(hhdm_mod.physToPtr(u8, phys));
            const src_addr = local_base + copied;
            if (src_addr >= 0x0000_8000_0000_0000) break;
            const src_ptr: [*]const u8 = @ptrFromInt(src_addr);
            dst_ptr[page_offset] = src_ptr[0];
        }
        total += copied;
    }
    return @bitCast(total);
}
