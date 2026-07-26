/// Safe user-space memory access with address range validation.
///
/// Validates that user pointers are in user space (< USER_LIMIT) before copying.
/// If the address range extends into kernel space or overflows, returns 0 (no bytes copied).
/// SK-40: page-walk and root-table reads go through the arch facade
/// (`paging.currentRoot` / `paging.isUserAccessible`), and copies are
/// bracketed by `userAccessBegin/End` (riscv64 sstatus.SUM; no-op elsewhere).
/// For truly safe fault recovery, an instruction-level guard is still TODO.
const paging = @import("../arch/arch.zig").paging;

/// User-space address limit (canonical hole start).
pub const USER_LIMIT: u64 = 0x0000_8000_0000_0000;

/// Prefer the running task's page table when available (SMP/AP syscall path).
inline fn activeRoot() u64 {
    const sched = @import("../proc/sched.zig");
    const task_mod = @import("../proc/task.zig");
    if (sched.currentTaskIndex()) |idx| {
        if (task_mod.getTask(idx)) |t| {
            if (t.page_table_phys != 0) return t.page_table_phys;
        }
    }
    return paging.currentRoot();
}

/// Verify every page in [addr, addr+len) is present and user-accessible in the
/// current address space. This is essential: copyFromUser/copyToUser access
/// user pointers with a plain @memcpy, and there is no per-instruction fault
/// recovery, so a bad (but in-range) user pointer would otherwise fault inside
/// the kernel and halt the whole system. Returns false on the first page that
/// is missing or not user-accessible.
fn userRangeMapped(addr: u64, len: usize) bool {
    if (len == 0) return true;
    const root = activeRoot();
    var page = addr & ~@as(u64, 0xFFF);
    const end = addr + len;
    while (page < end) : (page += 0x1000) {
        if (!paging.isUserAccessible(root, page)) return false;
    }
    return true;
}

/// Every page of the range must accept a kernel write. Being mapped to user
/// space is not enough: a read-only page passes that check and then faults
/// inside the kernel's own copy, which has no recovery path and takes the
/// machine down. Any process can arrange one with `mmap(PROT_READ)`.
fn userRangeWritable(addr: u64, len: usize) bool {
    if (len == 0) return true;
    const root = activeRoot();
    var page = addr & ~@as(u64, 0xFFF);
    const end = addr + len;
    while (page < end) : (page += 0x1000) {
        if (!paging.isUserWritable(root, page)) return false;
    }
    return true;
}

/// Validate a user buffer before a syscall consumes data from a kernel queue.
/// Unlike validateUserRange, this also checks the active page table so callers
/// can reject a bad destination before performing an irreversible dequeue.
pub fn validateUserBuffer(addr: u64, len: usize) bool {
    return validateUserRange(addr, len) and userRangeMapped(addr, len);
}

/// Global recovery state (for future assembly-based recovery).
var recovery_rip: u64 = 0;
var in_user_access: bool = false;

/// Called by page fault handler. Currently unused (direct copy approach).
pub fn checkFault() ?u64 {
    if (in_user_access and recovery_rip != 0) {
        in_user_access = false;
        return recovery_rip;
    }
    return null;
}

/// Validate that a user-space address range [addr, addr+len) is entirely in user space.
/// Returns false if the range touches kernel space or wraps around.
pub fn validateUserRange(addr: u64, len: usize) bool {
    if (addr == 0) return false;
    if (addr >= USER_LIMIT) return false;
    // Subtraction avoids an overflowing addr + len expression.
    if (@as(u64, len) > USER_LIMIT - addr) return false;
    return true;
}

/// Safely copy bytes from user space to a kernel buffer.
/// Returns the number of bytes successfully copied.
/// Validates that the source range is in user space before copying.
/// Uses @memcpy for efficient bulk copy (compiler generates SSE/AVX).
pub fn copyFromUser(dst: []u8, src_user: [*]const u8, count: usize) usize {
    const copy_len = if (count > dst.len) dst.len else count;
    if (copy_len == 0) return 0;

    // Validate user-space address range
    const src_addr: u64 = @intFromPtr(src_user);
    if (!validateUserRange(src_addr, copy_len)) return 0;
    // Ensure the source pages are actually mapped and user-accessible before
    // touching them, so a bad user pointer returns 0 instead of faulting.
    if (!userRangeMapped(src_addr, copy_len)) return 0;

    paging.userAccessBegin();
    @memcpy(dst[0..copy_len], src_user[0..copy_len]);
    paging.userAccessEnd();
    return copy_len;
}

/// Safely copy bytes from kernel buffer to user space.
/// Returns the number of bytes successfully copied.
/// Validates that the destination range is in user space before copying.
/// Uses @memcpy for efficient bulk copy.
pub fn copyToUser(dst_user: [*]u8, src: []const u8, count: usize) usize {
    const copy_len = if (count > src.len) src.len else count;
    if (copy_len == 0) return 0;

    // Validate user-space address range
    const dst_addr: u64 = @intFromPtr(dst_user);
    if (!validateUserRange(dst_addr, copy_len)) return 0;
    // Ensure the destination pages are actually mapped and writable before
    // writing, so a bad or read-only user pointer returns 0 instead of faulting.
    if (!userRangeWritable(dst_addr, copy_len)) return 0;

    paging.userAccessBegin();
    @memcpy(dst_user[0..copy_len], src[0..copy_len]);
    paging.userAccessEnd();
    return copy_len;
}
