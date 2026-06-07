/// Safe user-space memory access with address range validation.
///
/// Validates that user pointers are in user space (< USER_LIMIT) before copying.
/// If the address range extends into kernel space or overflows, returns 0 (no bytes copied).
/// For truly safe fault recovery, an assembly-level RIP-range guard is needed (TODO).
const paging = @import("../arch/x86_64/paging.zig");

/// User-space address limit (canonical hole start).
pub const USER_LIMIT: u64 = 0x0000_8000_0000_0000;

/// Physical address of the page table currently loaded in CR3.
inline fn currentPml4() u64 {
    const cr3 = asm volatile ("mov %%cr3, %[v]"
        : [v] "=r" (-> u64),
    );
    return cr3 & 0x000F_FFFF_FFFF_F000;
}

/// Prefer the running task's page table when available (SMP/AP syscall path).
inline fn activePml4() u64 {
    const sched = @import("../proc/sched.zig");
    const task_mod = @import("../proc/task.zig");
    if (sched.currentTaskIndex()) |idx| {
        if (task_mod.getTask(idx)) |t| {
            if (t.page_table_phys != 0) return t.page_table_phys;
        }
    }
    return currentPml4();
}

/// Verify every page in [addr, addr+len) is present and user-accessible in the
/// current address space. This is essential: copyFromUser/copyToUser access
/// user pointers with a plain @memcpy, and there is no per-instruction fault
/// recovery, so a bad (but in-range) user pointer would otherwise fault inside
/// the kernel and halt the whole system. Returns false on the first page that
/// is missing or not user-accessible.
fn userRangeMapped(addr: u64, len: usize) bool {
    if (len == 0) return true;
    const pml4 = activePml4();
    var page = addr & ~@as(u64, 0xFFF);
    const end = addr + len;
    while (page < end) : (page += 0x1000) {
        const pte = paging.getPageEntry(pml4, page) orelse return false;
        if (!pte.user) return false;
    }
    return true;
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
    // Check for overflow: addr + len must not wrap or exceed USER_LIMIT
    const end = addr + @as(u64, len);
    if (end < addr) return false; // overflow
    if (end > USER_LIMIT) return false;
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

    @memcpy(dst[0..copy_len], src_user[0..copy_len]);
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
    // Ensure the destination pages are actually mapped and user-accessible
    // before writing, so a bad user pointer returns 0 instead of faulting.
    if (!userRangeMapped(dst_addr, copy_len)) return 0;

    @memcpy(dst_user[0..copy_len], src[0..copy_len]);
    return copy_len;
}
