/// Pure process_vm_readv/process_vm_writev policy checks.
///
/// This module deliberately has no task, paging, or architecture dependencies.
/// The runtime can use these checks before walking x86 page tables.
const std = @import("std");

pub const USER_ADDR_MAX: u64 = 0x0000_8000_0000_0000;
pub const MAX_IOV: u64 = 16;
pub const IOV_ENTRY_SIZE: u64 = 16;

pub const Iovec = struct {
    base: u64,
    len: u64,
};

pub const Operation = enum {
    readv,
    writev,
};

/// The mapping facts needed by the direction-specific access gate.
///
/// `raw_pte_available` is false when the runtime cannot inspect the raw x86
/// entry. COW and huge mappings are not accepted through that fallback path.
pub const Mapping = struct {
    present: bool,
    user: bool,
    readable: bool,
    writable: bool,
    cow: bool,
    huge: bool,
    raw_pte_available: bool,
};

/// Return whether [base, base + len) is entirely below the user limit.
pub fn validUserRange(base: u64, len: u64) bool {
    if (len == 0) return true;
    if (base == 0 or base >= USER_ADDR_MAX) return false;
    return len <= USER_ADDR_MAX - base;
}

/// Return whether an iovec array fits below the user limit and respects MAX_IOV.
pub fn validIovArray(ptr: u64, count: u64) bool {
    if (count == 0) return true;
    if (count > MAX_IOV or ptr == 0) return false;
    if (count > USER_ADDR_MAX / IOV_ENTRY_SIZE) return false;
    const bytes = count * IOV_ENTRY_SIZE;
    return ptr <= USER_ADDR_MAX - bytes;
}

/// Sum iovec lengths, returning null if the aggregate does not fit in u64.
pub fn aggregateLength(iovecs: []const Iovec) ?u64 {
    var total: u64 = 0;
    for (iovecs) |iov| {
        if (iov.len > std.math.maxInt(u64) - total) return null;
        total += iov.len;
    }
    return total;
}

/// Apply the readv/writev local-versus-remote permission contract.
pub fn permits(operation: Operation, local: Mapping, remote: Mapping) bool {
    const mappingAllowed = struct {
        fn check(mapping: Mapping, writable: bool) bool {
            if (!mapping.present or !mapping.user) return false;
            if (!mapping.raw_pte_available and (mapping.cow or mapping.huge)) return false;
            if (writable and !mapping.raw_pte_available) return false;
            return if (writable) mapping.writable else mapping.readable;
        }
    }.check;

    return switch (operation) {
        .readv => mappingAllowed(local, true) and mappingAllowed(remote, false),
        .writev => mappingAllowed(local, false) and mappingAllowed(remote, true),
    };
}
