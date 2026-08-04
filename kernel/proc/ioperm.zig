/// ioperm — per-task I/O port permission via the TSS I/O bitmap (IOPB).
///
/// Syscall #483 ioperm_set(port, count, enable) grants/revokes user-space
/// access to I/O ports. The pure bitmap logic lives in ioperm_core.zig
/// (host-tested); this file does privilege checks, lazy allocation, and the
/// arch glue.
///
/// Security model:
///   - CAP_SYS_RAWIO required (same gate as the userdrv framework).
///   - Default is deny-all: a task without an allocated bitmap gets #GP on
///     any port I/O (the per-CPU TSS IOPB is all-ones).
///   - The hardware iomap_base is a u16 offset from the TSS base, so the
///     per-task bitmap (PMM/HHDM memory) cannot be referenced directly — the
///     scheduler COPIES it into the per-CPU TSS block on every context
///     switch. loadForTask MUST run at every point that installs a user
///     task's TSS.RSP0 (sched.setupUserCpuState, sched.tryStealTask,
///     execve, waitpid resume, syscall_entry.prepareSyscallCpu); a missed
///     site would leak the previous task's port permissions.
///   - fork: the child receives an independent COPY (inheritForFork).
///   - exit/exec teardown frees the bitmap pages (freeBitmap, called next to
///     userdrv.cleanupTask in the reap/waitpid paths).
///
/// Compile-time gate: `ioperm_enable = false` turns the syscall into ENOSYS
/// and leaves every TSS IOPB at the deny-all default (identical behavior to
/// before this feature existed).

const builtin = @import("builtin");
const core = @import("ioperm_core.zig");
const errno = @import("../lib/errno.zig");
const task_mod = @import("task.zig");
const cap_check = @import("cap_check.zig");

const is_x86 = builtin.cpu.arch == .x86_64;

pub const ioperm_enable: bool = true;

pub const SYS_IOPERM_SET: u64 = 483;

/// PMM pages backing one task bitmap (8192 bytes = 2 pages).
const BITMAP_PAGES: usize = core.BITMAP_BYTES / 4096;

/// Syscall #483: ioperm_set(port, count, enable) → 0 on success.
pub fn syscallIopermSet(port: u64, count: u64, enable: u64) i64 {
    if (comptime (!is_x86 or !ioperm_enable)) return errno.ENOSYS;
    const sched = @import("sched.zig");
    const cur = sched.currentTask() orelse return errno.ESRCH;
    if (cap_check.requireCap(cur, "cap_sys_rawio") != 0) return errno.EPERM;

    const shape = core.validateRange(port, count);
    if (shape != 0) return shape;

    const bitmap = ensureBitmap(cur) orelse return errno.ENOMEM;
    core.setRange(bitmap, @intCast(port), @intCast(count), enable != 0);

    // The running CPU's TSS holds a COPY of this task's bitmap — refresh it
    // so the new permissions apply immediately, not after the next switch.
    loadForTask(@import("../arch/x86_64/syscall_entry.zig").gsReadCpuId(), cur);
    return 0;
}

/// Lazily allocate the task's bitmap (deny-all default). Returns null on OOM.
fn ensureBitmap(t: *task_mod.Task) ?*core.Bitmap {
    if (t.io_bitmap) |p| return @ptrCast(p);
    const pmm = @import("../mm/pmm.zig");
    const hhdm = @import("../mm/hhdm.zig");
    const phys = pmm.allocContiguous(BITMAP_PAGES) orelse return null;
    const ptr: *core.Bitmap = @ptrFromInt(hhdm.physToVirt(phys));
    ptr.* = core.denyAll();
    t.io_bitmap = @ptrCast(ptr);
    return ptr;
}

/// Copy the incoming task's IOPB into the CPU's TSS (deny-all when the task
/// has none). MUST be paired with every per-switch TSS RSP0 update — see the
/// security model in the file header. No-op for kernel threads' purposes:
/// ring-0 I/O bypasses the bitmap, and a deny-all load is still correct.
pub fn loadForTask(cpu_id: u32, t: *const task_mod.Task) void {
    if (comptime (!is_x86 or !ioperm_enable)) return;
    const gdt = @import("../arch/x86_64/gdt.zig");
    const src: ?*const [core.BITMAP_BYTES]u8 = if (t.io_bitmap) |p| @ptrCast(p) else null;
    gdt.loadIoBitmap(cpu_id, src);
}

/// fork: the child gets an independent copy of the parent's bitmap (if the
/// parent ever allocated one). On OOM the child falls back to deny-all
/// rather than failing the fork.
pub fn inheritForFork(parent: *const task_mod.Task, child: *task_mod.Task) void {
    if (comptime (!is_x86 or !ioperm_enable)) return;
    const src = parent.io_bitmap orelse return;
    const dst = ensureBitmap(child) orelse {
        @import("../arch/arch.zig").serial.writeString("[ioperm] WARN: fork bitmap alloc failed, child deny-all\n");
        return;
    };
    core.inherit(dst, @ptrCast(src));
}

/// Task teardown: return the bitmap pages to the PMM. Idempotent; safe on
/// tasks that never called ioperm_set.
pub fn freeBitmap(t: *task_mod.Task) void {
    if (comptime (!is_x86 or !ioperm_enable)) return;
    const ptr = t.io_bitmap orelse return;
    const pmm = @import("../mm/pmm.zig");
    const hhdm = @import("../mm/hhdm.zig");
    pmm.freeContiguous(hhdm.virtToPhys(@intFromPtr(ptr)), BITMAP_PAGES);
    t.io_bitmap = null;
}
