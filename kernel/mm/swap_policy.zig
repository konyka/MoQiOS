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

const std = @import("std");
