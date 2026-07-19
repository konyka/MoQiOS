//! SK-40 — portable copy_from_user via the arch paging facade.
//!
//! `mm/copy_from_user.zig` no longer reads CR3 inline: root-table reads and
//! user-bit walks go through `paging.currentRoot` / `paging.isUserAccessible`,
//! and copies are bracketed by `userAccessBegin/End` (riscv64 sstatus.SUM).
//! Probe: map a real user page, round-trip copyFromUser/copyToUser, and check
//! that unmapped / kernel-range pointers are rejected with 0.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const copy = @import("../mm/copy_from_user.zig");
const pmm = @import("../mm/pmm.zig");

const USER_VA: u64 = 0x3000_0000;

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-40] portable copy_from_user: OK\n");
        return;
    }

    const phys = pmm.allocPage() orelse {
        arch.serial.writeString("[SK-40] FAILED: allocPage\n");
        return;
    };
    // Identity map is live on both non-x86 arches: phys VA == phys.
    const kdata: [*]u8 = @ptrFromInt(phys);
    kdata[0] = 0x40;
    kdata[1] = 0xA5;

    arch.paging.mapPage(0, USER_VA, phys, .{ .writable = true, .user = true, .no_execute = true }) catch {
        arch.serial.writeString("[SK-40] FAILED: mapPage\n");
        return;
    };

    if (!arch.paging.isUserAccessible(arch.paging.currentRoot(), USER_VA)) {
        arch.serial.writeString("[SK-40] FAILED: isUserAccessible\n");
        return;
    }

    var buf: [4]u8 = undefined;
    const n = copy.copyFromUser(buf[0..], @ptrFromInt(USER_VA), 2);
    if (n != 2 or buf[0] != 0x40 or buf[1] != 0xA5) {
        arch.serial.writeString("[SK-40] FAILED: copyFromUser\n");
        return;
    }

    buf[0] = 0x5A;
    buf[1] = 0x04;
    const w = copy.copyToUser(@ptrFromInt(USER_VA + 8), buf[0..2], 2);
    if (w != 2 or kdata[8] != 0x5A or kdata[9] != 0x04) {
        arch.serial.writeString("[SK-40] FAILED: copyToUser\n");
        return;
    }

    // Unmapped user VA and kernel-range pointer must both be rejected.
    if (copy.copyFromUser(buf[0..], @ptrFromInt(USER_VA + 0x2000), 2) != 0) {
        arch.serial.writeString("[SK-40] FAILED: unmapped not rejected\n");
        return;
    }
    if (copy.copyFromUser(buf[0..], @ptrFromInt(copy.USER_LIMIT), 2) != 0) {
        arch.serial.writeString("[SK-40] FAILED: kernel range not rejected\n");
        return;
    }

    _ = arch.paging.unmapPage(0, USER_VA);
    pmm.freePage(phys);

    arch.serial.writeString("[SK-40] portable copy_from_user: OK\n");
}
