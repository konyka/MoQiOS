//! Pure futex key and operation decoding helpers.

pub const PRIVATE_FLAG: i64 = 128;
const BASE_MASK: i64 = 0x7f;

pub const Key = struct {
    root: u64,
    addr: u64,
};

pub const DecodedOp = struct {
    base: i64,
    private: bool,
};

pub fn equal(a: Key, b: Key) bool {
    return a.root == b.root and a.addr == b.addr;
}

pub fn aligned(addr: u64) bool {
    return (addr & 3) == 0;
}

/// Decode the base futex command and the only supported flag. Unknown flag
/// bits are invalid rather than silently changing queue-key semantics.
pub fn privateOp(raw_op: i64) ?DecodedOp {
    if (raw_op < 0 or (raw_op & ~(BASE_MASK | PRIVATE_FLAG)) != 0) return null;
    return .{
        .base = raw_op & BASE_MASK,
        .private = (raw_op & PRIVATE_FLAG) != 0,
    };
}

pub fn piUnsupported(base: i64) bool {
    return switch (base) {
        6, 7, 8, 11, 12 => true,
        else => false,
    };
}
