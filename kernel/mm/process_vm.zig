/// process_vm_readv / process_vm_writev — cross-process memory access.
///
/// Read or write another process's memory via iovec vectors. The caller's own
/// address space goes through the ordinary user-copy path. For another
/// process, the target's Mm is retained (task.pinTaskMmByTid), each remote
/// page is translated under the target's vm_lock and pinned with a frame
/// reference, and the bytes move through the kernel's direct map after the
/// lock is dropped. A write into a copy-on-write page first gives the target a
/// private copy, exactly as the target's own write fault would.
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

fn isSelf(caller: *task_mod.Task, target_pid: u32) bool {
    const caller_pid = if (caller.is_thread and caller.parent_tid != 0) caller.parent_tid else caller.tid;
    return caller_pid == target_pid;
}

fn ids(t: *const task_mod.Task) process_vm_policy.Ids {
    return .{ .uid = t.uid, .euid = t.euid, .suid = t.suid, .gid = t.gid, .egid = t.egid, .sgid = t.sgid };
}

const hhdm = @import("hhdm.zig");
const pmm = @import("pmm.zig");
const cow_pte = @import("cow_pte.zig");

/// Translate one page of the target and take a frame reference so it cannot
/// be freed while the bytes are copied. A swapped-out page is swapped back in;
/// for a write, a copy-on-write page is first made private to the target.
/// null when the page is absent, not user accessible, or (for a write)
/// read-only. Runs under the target's vm_lock.
fn pinRemotePage(mm: *@import("mm.zig").Mm, page: u64, for_write: bool) ?u64 {
    // A registered vm_lock owner (not a bare acquire): swapIn's allocation may
    // try reclaim, whose non-blocking guard then sees the lock as held by
    // someone and skips instead of spinning on it.
    const caller = sched_mod.currentTask() orelse return null;
    var guard = @import("mm.zig").Mm.beginVmMutation(mm, @ptrCast(caller)) catch return null;
    defer guard.release();
    const root = mm.page_table_phys;
    var raw = paging_mod.getPageEntryRaw(root, page) orelse return null;
    if (raw & paging_mod.PRESENT == 0) {
        // A swapped-out page comes back in exactly as the target's own fault
        // would bring it (trySwapInKernelFault also reads under vm_lock).
        const swap = @import("swap.zig");
        if (!swap.isSwapEntry(raw)) return null;
        raw = swap.swapIn(raw) orelse return null;
        paging_mod.setPageEntryRaw(root, page, raw);
        @import("../arch/arch.zig").tlb.shootdownRange(page, 1, root);
    }
    if (raw & paging_mod.USER == 0) return null;
    var phys = raw & paging_mod.ADDR_MASK;
    if (for_write and raw & paging_mod.WRITABLE == 0) {
        if (!cow_pte.isCow(raw)) return null;
        if (pmm.getRefCount(phys) <= 1) {
            paging_mod.setPageEntryRaw(root, page, (raw & ~cow_pte.COW) | paging_mod.WRITABLE);
        } else {
            // No reclaim under the target's vm_lock: reclaim scans the caller's
            // own Mm, which may be this same address space (CLONE_VM).
            const fresh = pmm.allocPageNoReclaim() orelse return null;
            const src: [*]const u8 = @ptrFromInt(hhdm.physToVirt(phys));
            const dst: [*]u8 = @ptrFromInt(hhdm.physToVirt(fresh));
            @memcpy(dst[0..PAGE_SIZE], src[0..PAGE_SIZE]);
            paging_mod.setPageEntryRaw(root, page, (raw & ~paging_mod.ADDR_MASK & ~cow_pte.COW) | fresh | paging_mod.WRITABLE);
            @import("../arch/arch.zig").tlb.shootdownRange(page, 1, root);
            pmm.freePage(phys);
            phys = fresh;
        }
        @import("../arch/arch.zig").tlb.shootdownRange(page, 1, root);
    }
    pmm.addRef(phys);
    return phys;
}

/// Move up to one remote page's worth of bytes between the caller's buffer
/// and the target. Returns the bytes moved; short when a page is missing.
fn transferRemote(mm: *@import("mm.zig").Mm, local_base: u64, remote_base: u64, len: u64, write: bool) u64 {
    var staging: [4096]u8 = undefined;
    var copied: u64 = 0;
    while (copied < len) {
        const local_addr = local_base + copied;
        const remote_addr = remote_base + copied;
        const local_page_left = PAGE_SIZE - (local_addr & (PAGE_SIZE - 1));
        const remote_page_left = PAGE_SIZE - (remote_addr & (PAGE_SIZE - 1));
        const chunk: usize = @intCast(@min(len - copied, @min(local_page_left, remote_page_left)));
        const page = remote_addr & ~(PAGE_SIZE - 1);
        const phys = pinRemotePage(mm, page, write) orelse return copied;
        defer pmm.freePage(phys);
        const remote_ptr: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys) + (remote_addr - page));
        if (write) {
            const staged = copy.copyFromUser(staging[0..], @ptrFromInt(local_addr), chunk);
            @memcpy(remote_ptr[0..staged], staging[0..staged]);
            copied += staged;
            if (staged != chunk) return copied;
        } else {
            @memcpy(staging[0..chunk], remote_ptr[0..chunk]);
            const written = copy.copyToUser(@ptrFromInt(local_addr), staging[0..chunk], chunk);
            copied += written;
            if (written != chunk) return copied;
        }
    }
    return copied;
}

/// The target of a process_vm call: the caller itself (ordinary user copies),
/// or a retained foreign address space.
const Target = union(enum) {
    self,
    remote: task_mod.TaskMmPin,

    fn release(self: *Target) void {
        switch (self.*) {
            .self => {},
            .remote => |*pin| pin.release(),
        }
    }
};

fn lookupTarget(caller: *task_mod.Task, target_pid: u32) union(enum) { ok: Target, err: i64 } {
    if (isSelf(caller, target_pid)) return .{ .ok = .self };
    var pin = task_mod.pinTaskMmByTid(target_pid) catch return .{ .err = ESRCH };
    if (!process_vm_policy.mayAccess(ids(caller), ids(pin.task), caller.effective_caps.cap_sys_ptrace)) {
        pin.release();
        return .{ .err = EPERM };
    }
    return .{ .ok = .{ .remote = pin } };
}

fn partialOrError(total: u64) i64 {
    return if (total == 0) EFAULT else @intCast(total);
}

/// Sum of the local iovec lengths: Linux returns 0 before the target lookup
/// when the local vector moves no bytes.
fn totalLength(ptr: u64, count: u64) error{Fault}!u64 {
    var total: u64 = 0;
    var i: u64 = 0;
    while (i < count) : (i += 1) total +|= (try readIov(ptr, i)).len;
    return total;
}

fn readIov(ptr: u64, index: u64) error{Fault}!struct { base: u64, len: u64 } {
    const offset = index * 16;
    return .{
        .base = futex_mod.copyUserU64Fallible(ptr + offset) catch return error.Fault,
        .len = futex_mod.copyUserU64Fallible(ptr + offset + 8) catch return error.Fault,
    };
}

fn transferRead(local_base: u64, remote_base: u64, len: u64) u64 {
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

fn transferWrite(local_base: u64, remote_base: u64, len: u64) u64 {
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
    if (process_vm_policy.movesNothing(liovcnt, riovcnt)) return 0;
    if (!process_vm_policy.validIovArray(local_iov_ptr, liovcnt) or !process_vm_policy.validIovArray(remote_iov_ptr, riovcnt))
        return EFAULT;
    if ((totalLength(local_iov_ptr, liovcnt) catch return EFAULT) == 0) return 0;
    var target = switch (lookupTarget(caller, target_pid)) {
        .ok => |t| t,
        .err => |e| return e,
    };
    defer target.release();

    var total: u64 = 0;
    var li: u64 = 0;
    var ri: u64 = 0;
    var loff: u64 = 0;
    var roff: u64 = 0;
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
        const copied = switch (target) {
            .self => transferRead(local.base + loff, remote.base + roff, copy_len),
            .remote => |pin| transferRemote(pin.mm, local.base + loff, remote.base + roff, copy_len, false),
        };
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
    if (process_vm_policy.movesNothing(liovcnt, riovcnt)) return 0;
    if (!process_vm_policy.validIovArray(local_iov_ptr, liovcnt) or !process_vm_policy.validIovArray(remote_iov_ptr, riovcnt))
        return EFAULT;
    if ((totalLength(local_iov_ptr, liovcnt) catch return EFAULT) == 0) return 0;
    var target = switch (lookupTarget(caller, target_pid)) {
        .ok => |t| t,
        .err => |e| return e,
    };
    defer target.release();

    var total: u64 = 0;
    var li: u64 = 0;
    var ri: u64 = 0;
    var loff: u64 = 0;
    var roff: u64 = 0;
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
        const copied = switch (target) {
            .self => transferWrite(local.base + loff, remote.base + roff, copy_len),
            .remote => |pin| transferRemote(pin.mm, local.base + loff, remote.base + roff, copy_len, true),
        };
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
    try std.testing.expectEqual(EFAULT, processVmReadv(1, 0x1000, process_vm_policy.MAX_IOV + 1, 0x1000, 1, 0));
    try std.testing.expectEqual(EFAULT, processVmWritev(1, 0x1000, 1, 0x1000, process_vm_policy.MAX_IOV + 1, 0));
}

test "process_vm treats the caller and its thread group as the self target" {
    var caller: task_mod.Task = undefined;
    caller.tid = 42;
    caller.is_thread = false;
    caller.parent_tid = 0;
    try std.testing.expect(isSelf(&caller, 42));
    try std.testing.expect(!isSelf(&caller, 43));

    caller.tid = 43;
    caller.is_thread = true;
    caller.parent_tid = 42;
    try std.testing.expect(isSelf(&caller, 42));
    try std.testing.expect(!isSelf(&caller, 43));
}
