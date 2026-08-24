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
pub const aio_policy = @import("fs/aio_policy.zig");
pub const readahead_policy = @import("fs/readahead_policy.zig");
pub const sync_file_range_policy = @import("fs/sync_file_range_policy.zig");
pub const openat2_policy = @import("fs/openat2_policy.zig");
pub const fallocate_policy = @import("fs/fallocate_policy.zig");
pub const futex_key = @import("sync/futex_key.zig");
pub const mlock_policy = @import("mm/mlock_policy.zig");
pub const mprotect_policy = @import("mm/mprotect_policy.zig");
pub const cow_pte = @import("mm/cow_pte.zig");
pub const map_fixed = @import("mm/map_fixed.zig");
pub const vma_stats = @import("mm/vma_stats.zig");
pub const vma_runtime_stats = @import("mm/vma_runtime_stats.zig");
pub const rss_stats = @import("mm/rss_stats.zig");
pub const pci_msix = @import("drivers/pci_msix.zig");
pub const lo = @import("net/lo.zig");
pub const sched_policy = @import("proc/sched_policy.zig");
pub const sched_claim = @import("proc/sched_claim.zig");
pub const unsupported_policy = @import("proc/unsupported_policy.zig");
pub const sched_getaffinity_policy = @import("proc/sched_getaffinity_policy.zig");
pub const epoll_policy = @import("net/epoll_policy.zig");
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
pub const huge_user = @import("mm/huge_user.zig");
pub const nvme_queue = @import("drivers/nvme_queue.zig");
pub const virtio_net_queue = @import("drivers/virtio_net_queue.zig");
pub const socketpair_policy = @import("net/socketpair_policy.zig");
pub const message_batch_policy = @import("net/message_batch_policy.zig");
pub const slab_mag = @import("mm/slab_mag.zig");
pub const dcache = @import("fs/dcache.zig");
pub const userdrv_core = @import("drivers/userdrv_core.zig");
pub const ioapic_core = @import("arch/x86_64/ioapic_core.zig");
pub const ioperm_core = @import("proc/ioperm_core.zig");
pub const rlimit = @import("proc/rlimit.zig");
pub const ioprio_policy = @import("proc/ioprio_policy.zig");
pub const creation_metadata = @import("proc/creation_metadata.zig");
pub const devfs = @import("fs/devfs.zig");
pub const devfs_proxy = @import("fs/devfs_proxy.zig");
pub const static_hosts = @import("net/static_hosts.zig");
pub const madt_iso = @import("acpi/madt_iso.zig");
pub const fbcon_core = @import("drivers/fbcon_core.zig");
pub const fbcon_font = @import("drivers/fbcon_font.zig");
pub const mouse = @import("drivers/mouse.zig");
pub const capability_profile = @import("proc/capability_profile.zig");
pub const capability = @import("ipc/capability.zig");
pub const rtc = @import("drivers/rtc.zig");
pub const dac = @import("fs/dac.zig");
pub const statx_source = @embedFile("fs/statx.zig");
pub const tmpfs_source = @embedFile("fs/tmpfs.zig");
pub const syscall_entry_source = @embedFile("arch/x86_64/syscall_entry.zig");
pub const vfs_source = @embedFile("fs/vfs.zig");
pub const fcntl_source = @embedFile("fs/fcntl.zig");
pub const task_source = @embedFile("proc/task.zig");
pub const signal_syscall_source = @embedFile("proc/signal_syscall.zig");
pub const file_io_source = @embedFile("fs/file_io.zig");
pub const readv_source = @embedFile("fs/readv.zig");
