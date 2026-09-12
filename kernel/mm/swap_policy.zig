//! Swap target admission policy — pure decision logic, host-testable.
//!
//! swapon (syscall 318) selects its target by device *path* (e.g. "/dev/sda"),
//! never by an implicit default: the previous hardwired dev0/LBA0 behavior
//! could scribble whatever disk happened to register first. The admission
//! rule rejects exactly one device — the virtio-blk disk 0 that fat32/ext2
//! address directly (the same identity block_dev.discard uses) — because
//! swap writeback there would destroy the root filesystem. The QEMU smoke
//! attaches pattern-stamped NVMe/AHCI scratch images (tools/qemu_run.sh) so
//! every other registered device is a disposable, writable target.
//!
//! `DevKind` mirrors `drivers/block_dev.zig`'s `BlockDevType` ordinals; the
//! kernel call sites hold a comptime assert keeping the two in sync (the pure
//! module must not import the driver layer).

/// Mirrors block_dev.BlockDevType (nvme=0, ahci=1, virtio_blk=2).
pub const DevKind = enum(u8) {
    nvme = 0,
    ahci = 1,
    virtio_blk = 2,
};

/// A device is an admissible swap target unless it is the boot/system disk
/// (virtio-blk driver disk 0). Everything else — the NVMe/AHCI scratch
/// images, or any future non-boot disk — may be swapped onto.
pub fn admitTarget(kind: DevKind, driver_idx: u8) bool {
    return !(kind == .virtio_blk and driver_idx == 0);
}

/// Normalize a swapon path to a bare device name: an optional leading
/// "/dev/" is stripped, anything else is returned unchanged.
pub fn deviceName(path: []const u8) []const u8 {
    const prefix = "/dev/";
    if (path.len >= prefix.len and std.mem.eql(u8, path[0..prefix.len], prefix)) {
        return path[prefix.len..];
    }
    return path;
}

/// swapon's flags word admits no flags yet (Linux SWAP_FLAG_PREFER/priority
/// are unsupported); anything nonzero is -EINVAL.
pub fn flagsValid(flags: u32) bool {
    return flags == 0;
}

// ── swapoff drain state machine (§6.50) ─────────────────────────────────────
//
// swapoff migrates every in-use slot's page back to RAM, then disables the
// device. While the drain runs the area is in `draining`: new swap-outs are
// quiesced (a swap-out racing the drain would re-fill slots forever), but
// swap-ins keep working — threads of a draining address space still fault
// their pages back, and the drain itself swaps in. The kernel keeps the
// authoritative state in swap.zig atomics and serialises the armed→draining
// transition with a CAS; these pure functions are the single decision point.

pub const AreaState = enum { disabled, armed, draining };

/// swapoff's opening decision: only an armed area can start draining.
pub const SwapoffBegin = enum {
    /// armed → draining: walk all address spaces and swap every entry in.
    begin,
    /// Never armed (or already committed): -EINVAL.
    not_armed,
    /// A concurrent swapoff holds the drain: -EBUSY.
    busy,
};

pub fn swapoffBegin(state: AreaState) SwapoffBegin {
    return switch (state) {
        .disabled => .not_armed,
        .armed => .begin,
        .draining => .busy,
    };
}

/// swapon may only arm a fully disabled area; armed and draining are EBUSY.
pub fn swaponAllowed(state: AreaState) bool {
    return state == .disabled;
}

/// New swap-outs (allocSlot, and reclaim's reason to scan at all) exist only
/// in the armed steady state.
pub fn maySwapOut(state: AreaState) bool {
    return state == .armed;
}

/// Swap-in serves every live state: armed, and draining (faults concurrent
/// with the drain, and the drain walk itself).
pub fn maySwapIn(state: AreaState) bool {
    return state != .disabled;
}

/// How a finished drain leaves the area.
pub const DrainFinish = enum {
    /// All in-use slots swapped back in: disable the device.
    commit,
    /// PMM OOM mid-drain: a partial drain stays valid, re-arm the area and
    /// report -ENOMEM.
    rollback,
};

pub fn drainFinish(oom: bool) DrainFinish {
    return if (oom) .rollback else .commit;
}

pub fn drainNextState(finish: DrainFinish) AreaState {
    return switch (finish) {
        .commit => .disabled,
        .rollback => .armed,
    };
}

const std = @import("std");
