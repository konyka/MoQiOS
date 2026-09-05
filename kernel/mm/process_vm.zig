/// process_vm_readv / process_vm_writev — cross-process memory access.
///
/// Read or write memory via iovec vectors. The current runtime intentionally
/// permits only the caller's own address space.
/// Extracted from syscall_entry.zig (v18.8).
const std = @import("std");
const futex_mod = @import("../sync/futex.zig");
const task_mod = @import("../proc/task.zig");
const sched_mod = @import("../proc/sched.zig");
const paging_mod = @import("../arch/arch.zig").paging;
const copy = @import("copy_from_user.zig");
const process_vm_policy = @import("process_vm_policy.zig");

const PAGE_SIZE: u64 = 0x1000;
const EFAULT: i64 = -14;
const EPERM: i64 = -1;
const EINVAL: i64 = -22;
const ESRCH: i64 = -3;

fn supportsTarget(caller: *task_mod.Task, target_pid: u32) bool {
    // Task/address-space references are not independently refcounted yet. The
    // running task cannot exit or replace its address space during this call.
    const caller_pid = if (caller.is_thread and caller.parent_tid != 0) caller.parent_tid else caller.tid;
    return caller_pid == target_pid;
}

fn partialOrError(total: u64) i64 {
    return if (total == 0) EFAULT else @intCast(total);
}

fn readIov(ptr: u64, index: u64) error{Fault}!struct { base: u64, len: u64 } {
    const offset = index * 16;
    return .{
        .base = futex_mod.copyUserU64Fallible(ptr + offset) catch return error.Fault,
        .len = futex_mod.copyUserU64Fallible(ptr + offset + 8) catch return error.Fault,
    };
}

fn transferRead(caller_root: u64, target_root: u64, local_base: u64, remote_base: u64, len: u64) u64 {
    _ = caller_root;
    _ = target_root;
    var staging: [4096]u8 = undefined;
    var copied: u64 = 0;
    while (copied < len) {
        const local_addr = local_base + copied;
        const remote_addr = remote_base + copied;
        const local_page_left = PAGE_SIZE - (local_addr & (PAGE_SIZE - 1));
        const remote_page_left = PAGE_SIZE - (remote_addr & (PAGE_SIZE - 1));
        const chunk = @min(len - copied, @min(local_page_left, remote_page_left));
        const chunk_len: usize = @intCast(chunk);
        const staged = copy.copyFromUser(staging[0..], @ptrFromInt(remote_addr), chunk_len);
        const written = copy.copyToUser(@ptrFromInt(local_addr), staging[0..staged], staged);
        copied += written;
        if (staged != chunk_len or written != staged) return copied;
    }
    return copied;
}

fn transferWrite(caller_root: u64, target_root: u64, local_base: u64, remote_base: u64, len: u64) u64 {
    _ = caller_root;
    _ = target_root;
    var staging: [4096]u8 = undefined;
    var copied: u64 = 0;
    while (copied < len) {
        const local_addr = local_base + copied;
        const remote_addr = remote_base + copied;
        const local_page_left = PAGE_SIZE - (local_addr & (PAGE_SIZE - 1));
        const remote_page_left = PAGE_SIZE - (remote_addr & (PAGE_SIZE - 1));
        const chunk = @min(len - copied, @min(local_page_left, remote_page_left));
        const chunk_len: usize = @intCast(chunk);
        const staged = copy.copyFromUser(staging[0..], @ptrFromInt(local_addr), chunk_len);
        const written = copy.copyToUser(@ptrFromInt(remote_addr), staging[0..staged], staged);
        copied += written;
        if (staged != chunk_len or written != staged) return copied;
    }
    return copied;
}

/// process_vm_readv(pid, local_iov, liovcnt, remote_iov, riovcnt, flags) -> bytes read or -errno.
pub fn processVmReadv(target_pid: u32, local_iov_ptr: u64, liovcnt: u64, remote_iov_ptr: u64, riovcnt: u64, flags: u64) i64 {
    if (flags != 0) return EINVAL; // EINVAL: no flags are supported.
    const caller = sched_mod.currentTask() orelse return ESRCH;
    if (!supportsTarget(caller, target_pid)) return EPERM;
    const target_page_table = caller.page_table_phys;
    if (target_page_table == 0) return ESRCH;
    if (liovcnt == 0 or riovcnt == 0) return 0;
    if (!process_vm_policy.validIovArray(local_iov_ptr, liovcnt) or !process_vm_policy.validIovArray(remote_iov_ptr, riovcnt))
        return EFAULT;

    var total: u64 = 0;
    var li: u64 = 0;
    var ri: u64 = 0;
    var loff: u64 = 0;
    var roff: u64 = 0;
    const caller_root = paging_mod.currentRoot();
    while (li < liovcnt and ri < riovcnt) {
        const local = readIov(local_iov_ptr, li) catch return partialOrError(total);
        const remote = readIov(remote_iov_ptr, ri) catch return partialOrError(total);
        if (!process_vm_policy.validUserRange(local.base, local.len) or !process_vm_policy.validUserRange(remote.base, remote.len))
            return partialOrError(total);
        const left = local.len -| loff;
        const right = remote.len -| roff;
        const copy_len = @min(left, right);
        if (copy_len == 0) {
            if (left == 0) {
                li += 1;
                loff = 0;
            }
            if (right == 0) {
                ri += 1;
                roff = 0;
            }
            continue;
        }
        const copied = transferRead(caller_root, target_page_table, local.base + loff, remote.base + roff, copy_len);
        total += copied;
        loff += copied;
        roff += copied;
        if (copied != copy_len) return partialOrError(total);
        if (loff == local.len) {
            li += 1;
            loff = 0;
        }
        if (roff == remote.len) {
            ri += 1;
            roff = 0;
        }
    }
    return @bitCast(total);
}

/// process_vm_writev(pid, local_iov, liovcnt, remote_iov, riovcnt, flags) -> bytes written or -errno.
pub fn processVmWritev(target_pid: u32, local_iov_ptr: u64, liovcnt: u64, remote_iov_ptr: u64, riovcnt: u64, flags: u64) i64 {
    if (flags != 0) return EINVAL; // EINVAL: no flags are supported.
    const caller = sched_mod.currentTask() orelse return ESRCH;
    if (!supportsTarget(caller, target_pid)) return EPERM;
    const target_page_table = caller.page_table_phys;
    if (target_page_table == 0) return ESRCH;
    if (liovcnt == 0 or riovcnt == 0) return 0;
    if (!process_vm_policy.validIovArray(local_iov_ptr, liovcnt) or !process_vm_policy.validIovArray(remote_iov_ptr, riovcnt))
        return EFAULT;

    var total: u64 = 0;
    var li: u64 = 0;
    var ri: u64 = 0;
    var loff: u64 = 0;
    var roff: u64 = 0;
    const caller_root = paging_mod.currentRoot();
    while (li < liovcnt and ri < riovcnt) {
        const local = readIov(local_iov_ptr, li) catch return partialOrError(total);
        const remote = readIov(remote_iov_ptr, ri) catch return partialOrError(total);
        if (!process_vm_policy.validUserRange(local.base, local.len) or !process_vm_policy.validUserRange(remote.base, remote.len))
            return partialOrError(total);
        const left = local.len -| loff;
        const right = remote.len -| roff;
        const copy_len = @min(left, right);
        if (copy_len == 0) {
            if (left == 0) {
                li += 1;
                loff = 0;
            }
            if (right == 0) {
                ri += 1;
                roff = 0;
            }
            continue;
        }
        const copied = transferWrite(caller_root, target_page_table, local.base + loff, remote.base + roff, copy_len);
        total += copied;
        loff += copied;
        roff += copied;
        if (copied != copy_len) return partialOrError(total);
        if (loff == local.len) {
            li += 1;
            loff = 0;
        }
        if (roff == remote.len) {
            ri += 1;
            roff = 0;
        }
    }
    return @bitCast(total);
}

test "process_vm validates user ranges without overflow" {
    try std.testing.expect(process_vm_policy.validUserRange(0x1000, 0x1000));
    try std.testing.expect(!process_vm_policy.validUserRange(process_vm_policy.USER_ADDR_MAX - 1, 2));
    try std.testing.expect(!process_vm_policy.validUserRange(1, std.math.maxInt(u64)));
    try std.testing.expect(!process_vm_policy.validUserRange(0, 1));
}

test "process_vm validates bounded iovec arrays" {
    try std.testing.expect(process_vm_policy.validIovArray(0x1000, process_vm_policy.MAX_IOV));
    try std.testing.expect(!process_vm_policy.validIovArray(0x1000, process_vm_policy.MAX_IOV + 1));
    try std.testing.expect(!process_vm_policy.validIovArray(process_vm_policy.USER_ADDR_MAX - 8, 1));
}

test "process_vm rejects unsupported flags before touching memory" {
    try std.testing.expectEqual(EINVAL, processVmReadv(1, 0, 0, 0, 0, 1));
    try std.testing.expectEqual(EINVAL, processVmWritev(1, 0, 0, 0, 0, 1));
}

test "process_vm rejects excessive iovec counts" {
    try std.testing.expectEqual(EFAULT, processVmReadv(1, 0x1000, process_vm_policy.MAX_IOV + 1, 0x1000, 0, 0));
    try std.testing.expectEqual(EFAULT, processVmWritev(1, 0x1000, 0, 0x1000, process_vm_policy.MAX_IOV + 1, 0));
}

test "process_vm only supports the running task or its thread group without address-space refs" {
    var caller: task_mod.Task = undefined;
    caller.tid = 42;
    caller.is_thread = false;
    caller.parent_tid = 0;
    try std.testing.expect(supportsTarget(&caller, 42));
    try std.testing.expect(!supportsTarget(&caller, 43));

    caller.tid = 43;
    caller.is_thread = true;
    caller.parent_tid = 42;
    try std.testing.expect(supportsTarget(&caller, 42));
    try std.testing.expect(!supportsTarget(&caller, 43));
}
