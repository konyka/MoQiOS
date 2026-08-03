//! Host unit-test module root (not part of the kernel build — wired only
//! into `zig build test`, see build.zig and docs/build-and-toolchain.md).
//!
//! Why one wrapper: a Zig file may belong to only one module, and module
//! file-membership follows *all* path imports eagerly (even inside function
//! bodies). The net helpers share lib/byte_order.zig; ipv4.zig and
//! lib/fmt.zig both reach sync/irq_spinlock.zig through arch; and the arch
//! closure itself path-imports mm/cow_pte.zig (via x86_64 paging). So none
//! of the files below can be wired as separate test modules — they are
//! compiled here as a single module and re-exported; tests/main.zig picks
//! the pieces it needs.
//!
//! This file must sit directly under kernel/ so every path import stays
//! inside the module's root directory. Zig's lazy decl analysis keeps the
//! arch-specific decls (IrqSpinlock, netif, serial, ...) unanalyzed as long
//! as tests only touch pure decls — do not refAllDecls() this module.
pub const byte_order = @import("lib/byte_order.zig");
pub const errno = @import("lib/errno.zig");
pub const fmt = @import("lib/fmt.zig");
pub const fmt_core = @import("lib/fmt_core.zig");
pub const str = @import("lib/str.zig");
pub const cow_pte = @import("mm/cow_pte.zig");
pub const pci_msix = @import("drivers/pci_msix.zig");
pub const lo = @import("net/lo.zig");
pub const sched_policy = @import("proc/sched_policy.zig");
pub const eth = @import("net/eth.zig");
pub const ipv4 = @import("net/ipv4.zig");
pub const ipv6 = @import("net/ipv6.zig");
pub const tcp_util = @import("net/tcp_util.zig");
pub const udp_util = @import("net/udp_util.zig");
pub const filemap = @import("mm/filemap.zig");
pub const dhcp = @import("net/dhcp.zig");
pub const kmsg_ring = @import("lib/kmsg_ring.zig");
pub const trim_ranges = @import("lib/trim_ranges.zig");
pub const pcid_alloc = @import("mm/pcid_alloc.zig");
