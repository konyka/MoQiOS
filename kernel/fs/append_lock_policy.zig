//! Pure choice of the lock stripe an O_APPEND write takes. Every descriptor of one file carries the same inode_id (FAT32 first cluster,
//! ext2 inode number, tmpfs slot, each with its own high tag), so appenders to one file always meet on one stripe -- the end-of-file and
//! staging step stays atomic between them -- while appenders to different files usually take different stripes and run in parallel.
//! Host-testable.

pub const STRIPES: u32 = 16;

/// Stripe index for an inode id: a 64-bit mix folded to `STRIPES`, so ids that differ only in the tag or low bits still spread.
pub fn stripeOf(inode_id: u64) u32 {
    var x = inode_id;
    x ^= x >> 33;
    x *%= 0xff51afd7ed558ccd;
    x ^= x >> 33;
    x *%= 0xc4ceb9fe1a85ec53;
    x ^= x >> 33;
    return @intCast(x % STRIPES);
}
