//! Pure choice of the lock stripe an O_APPEND write takes. Every descriptor of one file carries the same key (FAT32 open-file slot, ext2 inode
//! number, tmpfs slot, each with its own high tag), so appenders to one file always meet on one stripe -- the end-of-file and staging step stays
//! atomic between them -- while appenders to different files take different stripes and run in parallel.
//! Host-testable.

pub const STRIPES: u32 = 64;

/// Stripe index for a file key: its low bits. Keys are small sequential numbers (slots, inode numbers) under a tag in the top bits, so files
/// created one after another always land on different stripes, up to STRIPES of them. (A hash spread them too, but put two of four
/// consecutive files on one stripe about a third of the time, and then a writer preempted while holding the stripe made the others wait.)
pub fn stripeOf(key: u64) u32 {
    return @intCast(key % STRIPES);
}
