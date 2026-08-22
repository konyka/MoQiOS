const std = @import("std");

const kt = @import("kernel_shared");

const byte_order = kt.byte_order;
const aio_policy = kt.aio_policy;
const sync_file_range_policy = kt.sync_file_range_policy;
const openat2_policy = kt.openat2_policy;
const futex_key = kt.futex_key;
const mlock_policy = kt.mlock_policy;
const mprotect_policy = kt.mprotect_policy;
const cow_pte = kt.cow_pte;
const map_fixed = kt.map_fixed;
const vma_stats = kt.vma_stats;
const vma_runtime_stats = kt.vma_runtime_stats;
const rss_stats = kt.rss_stats;
const errno = kt.errno;
const eth = kt.eth;
const fmt = kt.fmt_core;
const fmt_serial = kt.fmt;
const ipv4 = kt.ipv4;
const ipv6 = kt.ipv6;
const str = kt.str;
const tcp_util = kt.tcp_util;
const udp_util = kt.udp_util;
const pci_msix = kt.pci_msix;
const capability_profile = kt.capability_profile;
const capability = kt.capability;
const dac = kt.dac;
const rlimit = kt.rlimit;
const ioprio_policy = kt.ioprio_policy;
const creation_metadata = kt.creation_metadata;
const virtio_net_queue = kt.virtio_net_queue;

test "creation metadata masks requested permissions to nine mode bits" {
    const metadata = creation_metadata.decide(null, .regular_file, 0o1764, 0o027, 41, 52).metadata;
    try std.testing.expectEqual(@as(u32, 0o740), metadata.mode);
}

test "sync_file_range policy validates flags and bounded page ranges" {
    const r = try sync_file_range_policy.validate(4095, 2, sync_file_range_policy.WRITE);
    try std.testing.expectEqual(@as(u64, 0), r.first_page);
    try std.testing.expectEqual(@as(u64, 2), r.page_count);

    const empty = try sync_file_range_policy.validate(123, 0, 0);
    try std.testing.expectEqual(@as(u64, 0), empty.page_count);
    try std.testing.expectError(error.InvalidFlags, sync_file_range_policy.validate(0, 1, 8));
    try std.testing.expectError(error.InvalidOffset, sync_file_range_policy.validate(std.math.maxInt(i64) + 1, 0, 0));
    try std.testing.expectError(error.InvalidOffset, sync_file_range_policy.validate(std.math.maxInt(u64), 2, 0));
    try std.testing.expectError(error.RangeOverflow, sync_file_range_policy.validate(std.math.maxInt(i64), std.math.maxInt(u64), 0));
}

test "mprotect transaction policy enforces fixed resource caps" {
    try std.testing.expect(mprotect_policy.supported(0, 0));
    try std.testing.expect(mprotect_policy.supported(
        mprotect_policy.MAX_PARTIAL_HUGE_DEMOTIONS,
        mprotect_policy.MAX_COW_COPIES,
    ));
    try std.testing.expect(!mprotect_policy.supported(
        mprotect_policy.MAX_PARTIAL_HUGE_DEMOTIONS + 1,
        0,
    ));
    try std.testing.expect(!mprotect_policy.supported(
        0,
        mprotect_policy.MAX_COW_COPIES + 1,
    ));
}

test "openat2 policy validates size, dirfd, flags, mode, and resolve" {
    try std.testing.expectEqual(@as(i64, 0), openat2_policy.validate(
        openat2_policy.AT_FDCWD,
        .{ .flags = openat2_policy.O_CREAT, .mode = 0o644, .resolve = 0 },
        openat2_policy.SIZE,
    ));
    try std.testing.expectEqual(kt.errno.EINVAL, openat2_policy.validate(
        0,
        .{ .flags = 0, .mode = 0, .resolve = 0 },
        openat2_policy.SIZE + 8,
    ));
    try std.testing.expectEqual(kt.errno.EINVAL, openat2_policy.validate(
        openat2_policy.AT_FDCWD,
        .{ .flags = 0, .mode = 0, .resolve = 0 },
        openat2_policy.SIZE - 1,
    ));
    try std.testing.expectEqual(kt.errno.EBADF, openat2_policy.validate(
        3,
        .{ .flags = 0, .mode = 0, .resolve = 0 },
        openat2_policy.SIZE,
    ));
    try std.testing.expectEqual(kt.errno.EINVAL, openat2_policy.validate(
        0,
        .{ .flags = openat2_policy.SUPPORTED_FLAGS | (1 << 40), .mode = 0, .resolve = 0 },
        openat2_policy.SIZE,
    ));
    try std.testing.expectEqual(kt.errno.EINVAL, openat2_policy.validate(
        0,
        .{ .flags = 0, .mode = 0o1000, .resolve = 0 },
        openat2_policy.SIZE,
    ));
    try std.testing.expectEqual(kt.errno.EINVAL, openat2_policy.validate(
        0,
        .{ .flags = 0, .mode = 0o644, .resolve = 0 },
        openat2_policy.SIZE,
    ));
    try std.testing.expectEqual(kt.errno.EINVAL, openat2_policy.validate(
        0,
        .{ .flags = 0, .mode = 0, .resolve = 1 },
        openat2_policy.SIZE,
    ));
}

test "rlimit NPROC policy rejects creation at the soft limit" {
    const policy = kt.rlimit.Policy;
    try std.testing.expect(policy.nprocAllowed(0, 1));
    try std.testing.expect(policy.nprocAllowed(7, 8));
    try std.testing.expect(!policy.nprocAllowed(8, 8));
    try std.testing.expect(!policy.nprocAllowed(9, 1));
    try std.testing.expect(policy.nprocAllowed(64, kt.rlimit.RLIM_INFINITY));
}

test "rlimit DATA charge policy preserves byte-limit boundaries" {
    const policy = kt.rlimit.Policy;
    try std.testing.expect(policy.dataChargeOk(0, 4096, 4096));
    try std.testing.expect(policy.dataChargeOk(4096, 0, 4096));
    try std.testing.expect(!policy.dataChargeOk(4096, 1, 4096));
    try std.testing.expect(!policy.dataChargeOk(8192, 0, 4096));
    try std.testing.expect(policy.dataChargeOk(8192, 1, kt.rlimit.RLIM_INFINITY));
}

test "rlimit FSIZE policy enforces byte-position boundaries" {
    const policy = kt.rlimit.Policy;
    const inf = kt.rlimit.RLIM_INFINITY;
    try std.testing.expectEqual(@as(u64, 4096), policy.fsizeWriteBytes(0, 4096, 4096));
    try std.testing.expectEqual(@as(u64, 0), policy.fsizeWriteBytes(4096, 1, 4096));
    try std.testing.expectEqual(@as(u64, 4), policy.fsizeWriteBytes(4, 8, 8));
    try std.testing.expectEqual(@as(u64, 8), policy.fsizeWriteBytes(4, 8, inf));
    try std.testing.expect(policy.fsizeAllowed(0, 4096, 4096));
    try std.testing.expect(policy.fsizeAllowed(4096, 0, 4096));
    try std.testing.expect(!policy.fsizeAllowed(4096, 1, 4096));
    try std.testing.expect(!policy.fsizeAllowed(8192, 0, 4096));
    try std.testing.expect(policy.fsizeAllowed(8192, 1, inf));
    try std.testing.expect(policy.fsizeAllowed(0, 1, inf));
    try std.testing.expect(!policy.fsizeAllowed(0x7FFF_FFFF_FFFF_FFFE, 2, 0x7FFF_FFFF_FFFF_FFFF));
}

test "private futex keys distinguish roots and exact addresses" {
    const key_a = futex_key.Key{ .root = 0x1000, .addr = 0x4000 };
    const same = futex_key.Key{ .root = 0x1000, .addr = 0x4000 };
    const same_page_other_word = futex_key.Key{ .root = 0x1000, .addr = 0x4004 };
    const same_addr_other_root = futex_key.Key{ .root = 0x2000, .addr = 0x4000 };

    try std.testing.expect(futex_key.aligned(key_a.addr));
    try std.testing.expect(!futex_key.aligned(0x4002));
    try std.testing.expect(futex_key.equal(key_a, same));
    try std.testing.expect(!futex_key.equal(key_a, same_page_other_word));
    try std.testing.expect(!futex_key.equal(key_a, same_addr_other_root));
}

test "AIO cancellation is unsupported when submissions complete synchronously" {
    try std.testing.expect(aio_policy.cancelUnsupported());
}

test "user memory locking is explicitly unsupported" {
    try std.testing.expect(mlock_policy.userMlockUnsupported());
}

test "ioprio policy validates process scope and encoded classes" {
    try std.testing.expect(ioprio_policy.validWhich(ioprio_policy.WHO_PROCESS));
    try std.testing.expect(!ioprio_policy.validWhich(2));
    try std.testing.expect(ioprio_policy.unsupportedWhich(2));
    try std.testing.expect(ioprio_policy.unsupportedWhich(3));
    try std.testing.expect(!ioprio_policy.unsupportedWhich(4));
    try std.testing.expect(ioprio_policy.validValue(ioprio_policy.DEFAULT));
    try std.testing.expect(ioprio_policy.validValue((ioprio_policy.CLASS_RT << 13) | 7));
    try std.testing.expect(ioprio_policy.validValue(ioprio_policy.CLASS_IDLE << 13));
    try std.testing.expect(!ioprio_policy.validValue((ioprio_policy.CLASS_BE << 13) | 8));
    try std.testing.expect(!ioprio_policy.validValue((ioprio_policy.CLASS_IDLE << 13) | 1));
    try std.testing.expect(!ioprio_policy.validValue(0));
    try std.testing.expect(!ioprio_policy.validValue(1 << 15));
}

test "private futex operation decoder rejects unsupported flags and PI" {
    const private_wait = futex_key.privateOp(128) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 0), private_wait.base);
    try std.testing.expect(private_wait.private);

    const private_wake = futex_key.privateOp(129) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 1), private_wake.base);
    try std.testing.expect(private_wake.private);
    try std.testing.expect(futex_key.privateOp(256) == null);
    try std.testing.expect(futex_key.privateOp(-1) == null);

    for ([_]i64{ 6, 7, 8, 11, 12 }) |op| {
        try std.testing.expect(futex_key.piUnsupported(op));
    }
    try std.testing.expect(!futex_key.piUnsupported(0));
}

test "MAP_FIXED replacement policy bounds stack-resident transactions" {
    try std.testing.expect(!map_fixed.pageCountSupported(0));
    try std.testing.expect(map_fixed.pageCountSupported(1));
    try std.testing.expect(map_fixed.pageCountSupported(map_fixed.MAX_ANON_REPLACEMENT_PAGES));
    try std.testing.expect(!map_fixed.pageCountSupported(map_fixed.MAX_ANON_REPLACEMENT_PAGES + 1));
}

test "fixed VMA table statistics report deterministic scan cost" {
    try std.testing.expectEqual(@as(u64, 64), vma_stats.MAX_REGIONS);

    const empty = vma_stats.scanCost(0);
    try std.testing.expectEqual(@as(u64, 64), empty.slots_scanned);
    try std.testing.expectEqual(@as(u64, 0), empty.active_seen);

    const partial = vma_stats.scanCost(10);
    try std.testing.expectEqual(@as(u64, 64), partial.slots_scanned);
    try std.testing.expectEqual(@as(u64, 10), partial.active_seen);

    const full = vma_stats.scanCost(64);
    try std.testing.expectEqual(@as(u64, 64), full.slots_scanned);
    try std.testing.expectEqual(@as(u64, 64), full.active_seen);

    const over_capacity = vma_stats.scanCost(65);
    try std.testing.expectEqual(@as(u64, 64), over_capacity.slots_scanned);
    try std.testing.expectEqual(@as(u64, 64), over_capacity.active_seen);

    try std.testing.expectEqual(@as(u64, 64), vma_stats.avgCost(2, 128));
    try std.testing.expectEqual(@as(u64, 0), vma_stats.avgCost(0, 0));
    try std.testing.expectEqual(@as(u64, 0), vma_stats.avgCost(0, 100));
}

test "VMA occupancy scan visits only active bitmap slots" {
    try std.testing.expectEqual(@as(u64, 0), vma_stats.visitedSlots(0));
    try std.testing.expectEqual(@as(u64, 64), vma_stats.visitedSlots(~@as(u64, 0)));
    try std.testing.expectEqual(@as(u64, 2), vma_stats.visitedSlots((@as(u64, 1) << 3) | (@as(u64, 1) << 61)));
    try std.testing.expect(vma_stats.visitedSlots(0xA5A5) <= vma_stats.MAX_REGIONS);
    const before = vma_runtime_stats.snapshot();
    vma_runtime_stats.recordScan(0x3);
    const after = vma_runtime_stats.snapshot();
    try std.testing.expectEqual(before.scans + 1, after.scans);
    try std.testing.expectEqual(before.visited_slots + 2, after.visited_slots);
}

test "resident RSS telemetry page model counts only present user leaves" {
    try std.testing.expectEqual(@as(u64, 0), rss_stats.addLeafPages(0, false, false));
    try std.testing.expectEqual(@as(u64, 1), rss_stats.addLeafPages(0, true, false));
    try std.testing.expectEqual(@as(u64, 512), rss_stats.addLeafPages(0, true, true));
    try std.testing.expectEqual(@as(u64, 513), rss_stats.addLeafPages(1, true, true));
    try std.testing.expectEqual(@as(u64, 4096), rss_stats.bytesForPages(1));
    try std.testing.expectEqual(@as(u64, 2048), rss_stats.kibForPages(512));
}

test "MAP_FIXED replacement policy settles net charges before commit" {
    const infinity = std.math.maxInt(u64);
    try std.testing.expectEqual(@as(?u64, 8192), map_fixed.chargeAfterReplacement(8192, 4096, 4096, infinity));
    try std.testing.expectEqual(@as(?u64, 4096), map_fixed.chargeAfterReplacement(8192, 4096, 0, infinity));
    try std.testing.expectEqual(@as(?u64, 12288), map_fixed.chargeAfterReplacement(8192, 0, 4096, 12288));
    try std.testing.expectEqual(@as(?u64, null), map_fixed.chargeAfterReplacement(8192, 0, 4096, 8192));
    try std.testing.expectEqual(@as(?u64, null), map_fixed.chargeAfterReplacement(4096, 8192, 0, infinity));
    try std.testing.expectEqual(@as(?u64, null), map_fixed.chargeAfterReplacement(infinity, 0, 1, infinity));
}

test "creation metadata defaults omitted file and directory modes separately" {
    const file = creation_metadata.decide(null, .regular_file, null, 0o022, 1, 2).metadata;
    const directory = creation_metadata.decide(null, .directory, null, 0o022, 1, 2).metadata;
    try std.testing.expectEqual(@as(u32, 0o644), file.mode);
    try std.testing.expectEqual(@as(u32, 0o755), directory.mode);
}

test "creation metadata distinguishes explicit zero mode from omitted mode" {
    const explicit = creation_metadata.decide(null, .regular_file, 0, 0, 1, 2).metadata;
    const omitted = creation_metadata.decide(null, .regular_file, null, 0, 1, 2).metadata;
    try std.testing.expectEqual(@as(u32, 0), explicit.mode);
    try std.testing.expectEqual(@as(u32, 0o666), omitted.mode);
}

test "creation metadata assigns effective owner and group" {
    const metadata = creation_metadata.decide(null, .regular_file, 0o600, 0, 1001, 1002).metadata;
    try std.testing.expectEqual(@as(u32, 1001), metadata.uid);
    try std.testing.expectEqual(@as(u32, 1002), metadata.gid);
}

test "creation metadata never mutates an existing object" {
    const existing: creation_metadata.Metadata = .{ .mode = 0o711, .uid = 7, .gid = 8 };
    const decision = creation_metadata.decide(existing, .directory, 0, 0o777, 1001, 1002);
    try std.testing.expect(!decision.created);
    try std.testing.expectEqual(existing, decision.metadata);
}

test "exclusive create rejects an existing object without ordinary create rejection" {
    try std.testing.expect(creation_metadata.exclusiveCreateRejectsExisting(true, 0x40 | 0x80));
    try std.testing.expect(!creation_metadata.exclusiveCreateRejectsExisting(true, 0x40));
    try std.testing.expect(!creation_metadata.exclusiveCreateRejectsExisting(false, 0x80));
}

test "task umask defaults inherits and returns the previous masked value" {
    var parent = creation_metadata.initialTaskUmask();
    try std.testing.expectEqual(@as(u32, 0o022), parent);
    try std.testing.expectEqual(parent, creation_metadata.inheritedTaskUmask(parent));
    try std.testing.expectEqual(@as(u32, 0o022), creation_metadata.replaceTaskUmask(&parent, 0o1754));
    try std.testing.expectEqual(@as(u32, 0o754), parent);
}

test "task umask replacement is isolated to the selected task state" {
    var first = creation_metadata.initialTaskUmask();
    const second = creation_metadata.initialTaskUmask();
    _ = creation_metadata.replaceTaskUmask(&first, 0o077);
    try std.testing.expectEqual(@as(u32, 0o077), first);
    try std.testing.expectEqual(@as(u32, 0o022), second);
}

test "NOFILE defaults to MAX_FDS and reserves standard descriptors" {
    const limit = rlimit.Policy.default(64);
    try std.testing.expectEqual(@as(u64, 64), limit.cur);
    try std.testing.expectEqual(@as(u64, 64), limit.max);
    try std.testing.expectEqual(@as(?u32, 3), rlimit.Policy.allocationCandidate(~@as(u64, 0b111), 0, limit.cur, 64));
}

test "NOFILE allocation routes through bounded fd APIs" {
    const free = (@as(u64, 1) << 3) | (@as(u64, 1) << 4) | (@as(u64, 1) << 7);
    try std.testing.expectEqual(@as(?u32, 3), rlimit.Policy.allocationCandidate(free, 0, 4, 64));
    try std.testing.expectEqual(@as(?u32, null), rlimit.Policy.allocationCandidate(free, 4, 4, 64));
    try std.testing.expectEqual(@as(?u32, null), rlimit.Policy.allocationCandidate(free, 0, 0, 64));
    try std.testing.expectEqual(@as(?u32, null), rlimit.Policy.allocationCandidate(free, 8, 64, 8));
}

test "NOFILE allocation treats the soft limit as an FD-number upper bound" {
    const free = (@as(u64, 1) << 3) | (@as(u64, 1) << 4);
    try std.testing.expectEqual(@as(?u32, 3), rlimit.Policy.allocationCandidate(free, 0, 4, 64));
    try std.testing.expectEqual(@as(?u32, null), rlimit.Policy.allocationCandidate(free, 4, 4, 64));
    try std.testing.expectEqual(@as(?u32, null), rlimit.Policy.allocationCandidate(free, 0, 3, 64));
}

test "NOFILE explicit occupancy distinguishes replacement from allocation" {
    try std.testing.expectEqual(rlimit.Policy.DupExplicit.no_op, rlimit.Policy.dupExplicit(true, 7, 7, 4, 64));
    try std.testing.expectEqual(rlimit.Policy.DupExplicit.bad_target, rlimit.Policy.dupExplicit(true, 3, 4, 4, 64));
    try std.testing.expectEqual(rlimit.Policy.DupExplicit.no_op, rlimit.Policy.dupExplicit(true, 3, 3, 4, 64));
    try std.testing.expectEqual(rlimit.Policy.DupExplicit.bad_old, rlimit.Policy.dupExplicit(false, 7, 7, 4, 64));
}

test "new task creation restores NOFILE defaults after zeroSlot" {
    const limit = rlimit.Policy.default(8);
    try std.testing.expectEqual(@as(u64, 8), limit.cur);
    try std.testing.expectEqual(@as(u64, 8), limit.max);
}

test "NOFILE blocks future allocations but keeps existing descriptors" {
    const limit = rlimit.Policy.default(64);
    const lowered = try rlimit.Policy.apply(limit, .{ .cur = 4, .max = 64 }, 64, false);
    try std.testing.expect(rlimit.Policy.fdAllowed(lowered.cur, 3, 64));
    try std.testing.expect(!rlimit.Policy.fdAllowed(lowered.cur, 4, 64));
    try std.testing.expect(!rlimit.Policy.fdAllowed(lowered.cur, 10, 64));
}

test "F_DUPFD minimum must be below the active soft limit" {
    try std.testing.expect(rlimit.Policy.dupMinimumValid(4, 3, 64));
    try std.testing.expect(!rlimit.Policy.dupMinimumValid(4, 4, 64));
    try std.testing.expect(!rlimit.Policy.dupMinimumValid(64, std.math.maxInt(u64), 64));
}

test "dup2 rejects out-of-range targets but permits a valid no-op" {
    try std.testing.expectEqual(rlimit.Policy.DupExplicit.bad_target, rlimit.Policy.dupExplicit(true, 3, 4, 4, 64));
    try std.testing.expectEqual(rlimit.Policy.DupExplicit.no_op, rlimit.Policy.dupExplicit(true, 4, 4, 4, 64));
    try std.testing.expectEqual(rlimit.Policy.DupExplicit.bad_old, rlimit.Policy.dupExplicit(false, 4, 4, 4, 64));
}

test "dup3 rejects same-fd before routing through dup2" {
    const source = kt.syscall_entry_source;
    const dispatch = std.mem.indexOf(u8, source, "161 => { // dup3(oldfd, newfd, flags)") orelse return error.TestUnexpectedResult;
    const guard = std.mem.indexOfPos(u8, source, dispatch, "if (frame.rdi == frame.rsi)") orelse return error.TestUnexpectedResult;
    const invalid = std.mem.indexOfPos(u8, source, guard, "frame.rax = @bitCast(errno.EINVAL)") orelse return error.TestUnexpectedResult;
    const flags = std.mem.indexOfPos(u8, source, dispatch, "const O_CLOEXEC: u64 = 0x80000;") orelse return error.TestUnexpectedResult;
    const invalid_flags = std.mem.indexOfPos(u8, source, flags, "if (frame.rdx & ~O_CLOEXEC != 0)") orelse return error.TestUnexpectedResult;
    const dup2_route = std.mem.indexOfPos(u8, source, dispatch, "proc_mgmt_mod.dup2(") orelse return error.TestUnexpectedResult;
    const cloexec = std.mem.indexOfPos(u8, source, dup2_route, "if (dup_result >= 0 and (frame.rdx & O_CLOEXEC) != 0)") orelse return error.TestUnexpectedResult;
    const max_fds_guard = std.mem.indexOfPos(u8, source, cloexec, "if (newfd2 < vfs_mod.MAX_FDS)") orelse return error.TestUnexpectedResult;
    try std.testing.expect(guard < dup2_route);
    try std.testing.expect(invalid < dup2_route);
    try std.testing.expect(flags < invalid_flags);
    try std.testing.expect(invalid_flags < dup2_route);
    try std.testing.expect(dup2_route < cloexec);
    try std.testing.expect(cloexec < max_fds_guard);
}

fn expectSourceRoute(source: []const u8, start_marker: []const u8, end_marker: []const u8, route: []const u8) !void {
    const start = std.mem.indexOf(u8, source, start_marker) orelse return error.TestUnexpectedResult;
    const end = std.mem.indexOfPos(u8, source, start, end_marker) orelse return error.TestUnexpectedResult;
    const route_pos = std.mem.indexOfPos(u8, source, start, route) orelse return error.TestUnexpectedResult;
    try std.testing.expect(route_pos < end);
}

test "creation syscall dispatch forwards mode registers" {
    const source = kt.syscall_entry_source;
    try expectSourceRoute(
        source,
        "255 => { // openat(dirfd, pathname, flags, mode)",
        "256 => { // unlinkat",
        "file_io_mod.openWithMode(frame.rsi, @truncate(frame.rdx), @truncate(frame.r10))",
    );
    try expectSourceRoute(
        source,
        "257 => { // mkdirat(dirfd, pathname, mode)",
        "258 => { // faccessat",
        "dir_ops_mod.mkdirWithMode(frame.rsi, @truncate(frame.rdx))",
    );
    try expectSourceRoute(
        source,
        "83 => { // mkdir(pathname, mode)",
        "84 => { // rmdir",
        "dir_ops_mod.mkdirWithMode(frame.rdi, @truncate(frame.rsi))",
    );
    try expectSourceRoute(
        source,
        "fn syscallOpen(frame: *SyscallFrame) void",
        "fn syscallRead(frame: *SyscallFrame) void",
        "file_io_mod.openWithMode(frame.rdi, @truncate(frame.rsi), @truncate(frame.rdx))",
    );
    try expectSourceRoute(
        source,
        "fn syscallMkdir(frame: *SyscallFrame) void",
        "fn syscallConnect(frame: *SyscallFrame) void",
        "dir_ops_mod.mkdirWithMode(frame.rdi, @truncate(frame.rsi))",
    );
}

test "openat2 dispatch routes both syscall numbers through strict validation" {
    const source = kt.syscall_entry_source;
    try expectSourceRoute(
        source,
        "320 => { // openat2(dirfd, pathname, how, size) — enhanced open",
        "321 => { // faccessat2",
        "syscallOpenat2(frame.rdi, frame.rsi, frame.rdx, frame.r10)",
    );
    try expectSourceRoute(
        source,
        "437 => { // openat2(dirfd, pathname, how, size) — alias of #320",
        "438 => { // pidfd_getfd",
        "syscallOpenat2(frame.rdi, frame.rsi, frame.rdx, frame.r10)",
    );
    try std.testing.expect(std.mem.indexOf(u8, source, "_ = frame.rdi;\n             _ = frame.rdx;\n             _ = frame.r10;\n             frame.rax = @bitCast(file_io_mod.open(frame.rsi, 0));") == null);
}

test "tmpfs exclusive create rejects before existing-entry mutation" {
    const source = kt.tmpfs_source;
    const existing = std.mem.indexOf(u8, source, "if (findEntry(name, parent)) |idx|") orelse return error.TestUnexpectedResult;
    const reject = std.mem.indexOfPos(u8, source, existing, "if (creation_metadata.exclusiveCreateRejectsExisting(create, flags)) return -17;") orelse return error.TestUnexpectedResult;
    const dac_route = std.mem.indexOfPos(u8, source, existing, "dac.decideExistingOpen(") orelse return error.TestUnexpectedResult;
    const truncate = std.mem.indexOfPos(u8, source, existing, "truncateLocked(entry, 0)") orelse return error.TestUnexpectedResult;
    const retain = std.mem.indexOfPos(u8, source, existing, "entry.open_count +|= 1") orelse return error.TestUnexpectedResult;
    try std.testing.expect(reject < dac_route);
    try std.testing.expect(reject < truncate);
    try std.testing.expect(reject < retain);
}

test "statx routes tmpfs fields through locked metadata accessor" {
    try std.testing.expect(std.mem.indexOf(u8, kt.tmpfs_source, "pub fn tmpfsGetMetadata(idx: u8) ?Metadata") != null);
    try expectSourceRoute(
        kt.statx_source,
        "if (fd_entry.fd_type == .tmpfs_file)",
        "bo.writeU16Le(stat_buf[off..], mode)",
        "tmpfs.tmpfsGetMetadata(@intCast(fd_entry.tmpfs_idx))",
    );
    try std.testing.expect(std.mem.indexOf(u8, kt.statx_source, "if (metadata.is_dir) @as(u16, 0o040000) else @as(u16, 0o100000)") != null);
}

test "creat dispatch creates truncates and opens writable with caller mode" {
    const source = kt.syscall_entry_source;
    try expectSourceRoute(source, "85 => { // creat(pathname, mode)", "87 => { // unlink", "const O_WRONLY: u32 = 0x1;");
    try expectSourceRoute(source, "85 => { // creat(pathname, mode)", "87 => { // unlink", "const O_CREAT: u32 = 0x40;");
    try expectSourceRoute(source, "85 => { // creat(pathname, mode)", "87 => { // unlink", "const O_TRUNC: u32 = 0x200;");
    try expectSourceRoute(
        source,
        "85 => { // creat(pathname, mode)",
        "87 => { // unlink",
        "file_io_mod.openWithMode(frame.rdi, O_WRONLY | O_CREAT | O_TRUNC, @truncate(frame.rsi))",
    );
}

test "Linux RLIMIT aliases preserve native syscall numbers" {
    try std.testing.expectEqual(rlimit.Policy.LinuxAlias.setrlimit, rlimit.Policy.linuxAlias(true, 160).?);
    try std.testing.expectEqual(rlimit.Policy.LinuxAlias.prlimit64, rlimit.Policy.linuxAlias(true, 302).?);
    try std.testing.expectEqual(@as(?rlimit.Policy.LinuxAlias, null), rlimit.Policy.linuxAlias(false, 160));
    try std.testing.expectEqual(@as(?rlimit.Policy.LinuxAlias, null), rlimit.Policy.linuxAlias(false, 302));
    try std.testing.expect(std.mem.indexOf(u8, kt.syscall_entry_source, "dispatchLinuxRlimitAlias(frame, syscall_nr)") != null);
}

test "signalfd closes backing eventfd on later failures" {
    const create = std.mem.indexOf(u8, kt.signal_syscall_source, "eventfdCreate(0)") orelse return error.TestUnexpectedResult;
    const cleanup = std.mem.indexOfPos(u8, kt.signal_syscall_source, create, "eventfdClose(eventfd_idx)") orelse return error.TestUnexpectedResult;
    const alloc = std.mem.indexOfPos(u8, kt.signal_syscall_source, cleanup, "fd_table.allocFd()") orelse return error.TestUnexpectedResult;
    try std.testing.expect(cleanup < alloc);
    try std.testing.expect(std.mem.indexOf(u8, kt.signal_syscall_source, "defer if (!installed) eventfd_mod.eventfdClose(eventfd_idx)") != null);
}

test "prlimit re-resolves target after user copies" {
    const snapshot = std.mem.indexOf(u8, kt.syscall_entry_source, "target_tid = if (pid == 0) caller.tid else pid") orelse return error.TestUnexpectedResult;
    const copy_from = std.mem.indexOfPos(u8, kt.syscall_entry_source, snapshot, "copy.copyFromUser(nbuf[0..]") orelse return error.TestUnexpectedResult;
    const relock = std.mem.indexOfPos(u8, kt.syscall_entry_source, copy_from, "const lock_flags = tm.lockTask()") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOfPos(u8, kt.syscall_entry_source, relock, "tm.findTaskByTidLocked(target_tid) orelse return -3") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.syscall_entry_source, "target.fd_table.alloc_limit = applied.cur") != null);
}

test "NOFILE validates cur <= max <= MAX_FDS" {
    try std.testing.expectError(error.InvalidLimit, rlimit.Policy.validate(.{ .cur = 65, .max = 64 }, 64));
    try std.testing.expectError(error.InvalidLimit, rlimit.Policy.validate(.{ .cur = 64, .max = 65 }, 64));
}

test "NOFILE raising hard limit requires privilege" {
    const current = rlimit.Policy.default(32);
    try std.testing.expectError(error.WouldLowerHardLimit, rlimit.Policy.apply(current, .{ .cur = 33, .max = 64 }, 64, false));
    try std.testing.expectEqual(@as(u64, 64), (try rlimit.Policy.apply(current, .{ .cur = 64, .max = 64 }, 64, true)).max);
}

test "NOFILE policy returns the applied limit for prlimit get/set" {
    const current = rlimit.Policy.default(64);
    const updated = try rlimit.Policy.apply(current, .{ .cur = 8, .max = 16 }, 64, false);
    try std.testing.expectEqual(@as(u64, 8), updated.cur);
    try std.testing.expectEqual(@as(u64, 16), updated.max);
}

test "STACK floor clamps to the architecture region" {
    const top: u64 = 0x0080_0000;
    const bottom: u64 = 0x0001_0000;
    // 8 MiB soft limit covers the whole region → floor is the region bottom.
    try std.testing.expectEqual(bottom, rlimit.Policy.stackFloor(top, bottom, 8 * 1024 * 1024));
    // RLIM_INFINITY behaves the same — enforcement never leaves the region.
    try std.testing.expectEqual(bottom, rlimit.Policy.stackFloor(top, bottom, rlimit.RLIM_INFINITY));
    // 64 KiB soft limit → floor is 64 KiB below the top.
    try std.testing.expectEqual(top - 64 * 1024, rlimit.Policy.stackFloor(top, bottom, 64 * 1024));
    // Initial watermark: historical 256 KiB head start, clamped by the floor.
    try std.testing.expectEqual(top - 64 * 4096, rlimit.Policy.initialStackLimit(top, bottom, 8 * 1024 * 1024));
    try std.testing.expectEqual(top - 64 * 1024, rlimit.Policy.initialStackLimit(top, bottom, 64 * 1024));
}

test "STACK setrlimit validation mirrors NOFILE privilege rules" {
    const current: rlimit.Limit = .{ .cur = 8 * 1024 * 1024, .max = 8 * 1024 * 1024 };
    // cur > max is structurally invalid.
    try std.testing.expectError(error.InvalidLimit, rlimit.Policy.applyBytes(current, .{ .cur = 2, .max = 1 }, false));
    // No table-size ceiling: RLIM_INFINITY is a valid value.
    const inf = try rlimit.Policy.applyBytes(current, .{ .cur = 8 * 1024 * 1024, .max = rlimit.RLIM_INFINITY }, true);
    try std.testing.expectEqual(rlimit.RLIM_INFINITY, inf.max);
    // Raising soft above the current hard limit necessarily raises the hard
    // limit too (cur <= max), and needs privilege either way.
    try std.testing.expectError(error.WouldLowerHardLimit, rlimit.Policy.applyBytes(current, .{ .cur = 16 * 1024 * 1024, .max = 16 * 1024 * 1024 }, false));
    try std.testing.expectError(error.WouldLowerHardLimit, rlimit.Policy.applyBytes(current, .{ .cur = 1024, .max = rlimit.RLIM_INFINITY }, false));
    // Lowering both is always allowed; soft may rise up to the hard limit.
    const lowered = try rlimit.Policy.applyBytes(current, .{ .cur = 64 * 1024, .max = 128 * 1024 }, false);
    try std.testing.expectEqual(@as(u64, 64 * 1024), lowered.cur);
    _ = try rlimit.Policy.applyBytes(current, .{ .cur = 8 * 1024 * 1024, .max = 8 * 1024 * 1024 }, false);
}

test "AS charge check blocks past the soft limit without underflow" {
    const inf = rlimit.RLIM_INFINITY;
    // Unlimited always passes.
    try std.testing.expect(rlimit.Policy.asChargeOk(std.math.maxInt(u64), 4096, inf));
    // Fits exactly / would exceed.
    try std.testing.expect(rlimit.Policy.asChargeOk(0, 4096, 4096));
    try std.testing.expect(!rlimit.Policy.asChargeOk(0, 4097, 4096));
    try std.testing.expect(rlimit.Policy.asChargeOk(1024, 3072, 4096));
    try std.testing.expect(!rlimit.Policy.asChargeOk(1024, 3073, 4096));
    // Usage already above the (lowered) limit: blocked, no underflow.
    try std.testing.expect(!rlimit.Policy.asChargeOk(8192, 1, 4096));
    try std.testing.expect(!rlimit.Policy.asChargeOk(8192, 0, 4096));
    // Zero charge at the boundary is allowed.
    try std.testing.expect(rlimit.Policy.asChargeOk(4096, 0, 4096));
}

test "DAC decodes open access modes and adds write for truncate" {
    try std.testing.expectEqual(dac.Access.read, dac.accessForOpen(0));
    try std.testing.expectEqual(dac.Access.write, dac.accessForOpen(1));
    try std.testing.expectEqual(dac.Access.read_write, dac.accessForOpen(2));
    try std.testing.expectEqual(dac.Access.read_write, dac.accessForOpen(0x200));
}

test "DAC uses owner group and other mode classes with strict precedence" {
    const meta: dac.Metadata = .{ .mode = 0o042, .uid = 10, .gid = 20 };

    try std.testing.expect(!dac.allows(meta, .{ .euid = 10, .egid = 20 }, .read));
    try std.testing.expect(dac.allows(meta, .{ .euid = 11, .egid = 20 }, .read));
    try std.testing.expect(!dac.allows(meta, .{ .euid = 11, .egid = 20 }, .write));
    try std.testing.expect(dac.allows(meta, .{ .euid = 11, .egid = 21 }, .write));
    try std.testing.expect(!dac.allows(meta, .{ .euid = 11, .egid = 21 }, .read));
}

test "DAC root and CAP_DAC_OVERRIDE bypass mode denial" {
    const meta: dac.Metadata = .{ .mode = 0, .uid = 10, .gid = 20 };

    try std.testing.expect(dac.allows(meta, .{ .euid = 0, .egid = 30 }, .read_write));
    try std.testing.expect(dac.allows(meta, .{ .euid = 30, .egid = 30, .cap_dac_override = true }, .read_write));
    try std.testing.expect(!dac.allows(meta, .{ .euid = 30, .egid = 30 }, .read));
}

test "DAC requires directory read permission for listing" {
    const meta: dac.Metadata = .{ .mode = 0o700, .uid = 10, .gid = 20 };

    try std.testing.expect(dac.canListDirectory(meta, .{ .euid = 10, .egid = 30 }));
    try std.testing.expect(!dac.canListDirectory(meta, .{ .euid = 11, .egid = 20 }));
}

test "DAC denied truncate decision leaves synthetic size unchanged" {
    const meta: dac.Metadata = .{ .mode = 0o444, .uid = 10, .gid = 20 };
    const decision = dac.decideExistingOpen(meta, .{ .euid = 11, .egid = 21 }, 0x200);
    var size: u32 = 37;

    if (decision.allowed and decision.truncate) size = 0;
    try std.testing.expect(!decision.allowed);
    try std.testing.expect(decision.truncate);
    try std.testing.expectEqual(@as(u32, 37), size);
}

test "descriptor read direction rejects O_WRONLY only" {
    try std.testing.expect(dac.descriptorCanRead(0));
    try std.testing.expect(!dac.descriptorCanRead(1));
    try std.testing.expect(dac.descriptorCanRead(2));
    try std.testing.expect(!dac.descriptorCanRead(1 | 0x400 | 0x800));
}

test "positioned reads enforce descriptor direction through shared routing" {
    const positioned_gate = "const desc = &self.fds[fd];\n        if (!@import(\"dac.zig\").descriptorCanRead(desc.status_flags)) return -9; // EBADF\n\n        switch (desc.fd_type)";
    const positioned_call = "cur.fd_table.readAtOffset(fd, &kbuf, chunk, current_offset)";
    const read_at_start = std.mem.indexOf(u8, kt.vfs_source, "pub fn readAtOffset") orelse return error.TestUnexpectedResult;
    const read_at_source = kt.vfs_source[read_at_start..];

    try std.testing.expect(std.mem.indexOf(u8, read_at_source, positioned_gate) != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.file_io_source, positioned_call) != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.readv_source, positioned_call) != null);
}

test "UID 1000 create ownership remains outside DAC phase one" {
    try std.testing.expect(!dac.enforcesOwnershipOnCreate);
}

test "user metadata probes forward effective DAC credentials" {
    const forwarding = "openWithCredentials(name, 0, cur.euid, cur.egid, cur.effective_caps)";

    try std.testing.expect(std.mem.indexOf(u8, kt.statx_source, forwarding) != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.syscall_entry_source, forwarding) != null);
}

test "capability launch profiles enforce the init trust boundary" {
    const init = capability_profile.profileForLaunch("init", false, true);
    try std.testing.expectEqual(@as(u32, 0), init.uid);
    try std.testing.expectEqual(@as(u32, 0), init.gid);
    try std.testing.expectEqual(@as(u32, @bitCast(@import("kernel_shared").capability.ALL_CAPS)), @as(u32, @bitCast(init.caps)));
    try std.testing.expect(init.initial_init);

    const wrong_name = capability_profile.profileForLaunch("hello14", false, true);
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(wrong_name.caps)));
    try std.testing.expect(!wrong_name.initial_init);

    const unknown = capability_profile.profileForLaunch("syslogd", true, false);
    try std.testing.expectEqual(capability_profile.DEFAULT_UID, unknown.uid);
    try std.testing.expectEqual(capability_profile.DEFAULT_GID, unknown.gid);
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(unknown.caps)));
    try std.testing.expect(!unknown.initial_init);
}

test "capability launch profiles grant only exact trusted compatibility names" {
    const hello14 = capability_profile.profileForLaunch("hello14", true, false).caps;
    try std.testing.expect(hello14.cap_net_raw);
    try std.testing.expectEqual(@as(u32, 1), @popCount(@as(u32, @bitCast(hello14))));

    const hello51 = capability_profile.profileForLaunch("hello51", true, false).caps;
    const hello52 = capability_profile.profileForLaunch("hello52", true, false).caps;
    try std.testing.expect(hello51.cap_sys_rawio);
    try std.testing.expectEqual(@as(u32, 1), @popCount(@as(u32, @bitCast(hello51))));
    try std.testing.expectEqual(@as(u32, @bitCast(hello51)), @as(u32, @bitCast(hello52)));

    const hello54 = capability_profile.profileForLaunch("hello54", true, false).caps;
    try std.testing.expect(hello54.cap_sys_rawio);
    try std.testing.expect(hello54.cap_kill);
    try std.testing.expectEqual(@as(u32, 2), @popCount(@as(u32, @bitCast(hello54))));

    const hello13 = capability_profile.profileForLaunch("hello13", true, false).caps;
    const hello58 = capability_profile.profileForLaunch("hello58", true, false).caps;
    try std.testing.expect(hello13.cap_kill);
    try std.testing.expectEqual(@as(u32, 1), @popCount(@as(u32, @bitCast(hello13))));
    try std.testing.expectEqual(@as(u32, @bitCast(hello13)), @as(u32, @bitCast(hello58)));
}

test "untrusted callers cannot receive named profiles" {
    inline for ([_][]const u8{ "hello14", "hello51", "hello52", "hello54", "hello13", "hello58" }) |name| {
        const profile = capability_profile.profileForLaunch(name, false, false);
        try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(profile.caps)));
        try std.testing.expect(!profile.initial_init);
    }
}

test "named child profiles never carry the initial init marker" {
    const profile = capability_profile.profileForLaunch("hello54", true, false);
    try std.testing.expect(!profile.initial_init);
    try std.testing.expectEqual(capability_profile.DEFAULT_UID, profile.uid);
    try std.testing.expectEqual(capability_profile.DEFAULT_GID, profile.gid);
}

test "raw network gate permits only CAP_NET_RAW" {
    try std.testing.expect(capability_profile.permitsRawNetwork(.{ .cap_net_raw = true }));
    try std.testing.expect(!capability_profile.permitsRawNetwork(.{}));
    try std.testing.expect(!capability_profile.permitsRawNetwork(.{ .cap_kill = true }));
    try std.testing.expect(!capability_profile.permitsRawNetwork(.{ .cap_sys_rawio = true }));
}

test {
    std.testing.refAllDecls(@This());
}

test "little-endian helpers round-trip integer values" {
    var buf: [8]u8 = undefined;

    byte_order.writeU16Le(buf[0..2], 0x1234);
    try std.testing.expectEqual(@as(u16, 0x1234), byte_order.readU16Le(buf[0..2]));
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12 }, buf[0..2]);

    byte_order.writeU32Le(buf[0..4], 0x89abcdef);
    try std.testing.expectEqual(@as(u32, 0x89abcdef), byte_order.readU32Le(buf[0..4]));
    try std.testing.expectEqualSlices(u8, &.{ 0xef, 0xcd, 0xab, 0x89 }, buf[0..4]);

    byte_order.writeU64Le(buf[0..8], 0x0123456789abcdef);
    try std.testing.expectEqual(@as(u64, 0x0123456789abcdef), byte_order.readU64Le(buf[0..8]));
}

test "big-endian network helpers read and write values" {
    var buf: [8]u8 = undefined;

    byte_order.writeU16BeAt(&buf, 1, 0x1234);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34 }, buf[1..3]);
    try std.testing.expectEqual(@as(u16, 0x1234), byte_order.readU16BeAt(&buf, 1));

    byte_order.writeU32BeAt(&buf, 2, 0x89abcdef);
    try std.testing.expectEqualSlices(u8, &.{ 0x89, 0xab, 0xcd, 0xef }, buf[2..6]);
    try std.testing.expectEqual(@as(u32, 0x89abcdef), byte_order.readU32BeAt(&buf, 2));
}

test "format helpers cover decimal, hex, and signed extremes" {
    var buf: [32]u8 = undefined;

    try std.testing.expectEqualStrings("0", fmt.fmtDec(&buf, 0));
    try std.testing.expectEqualStrings("18446744073709551615", fmt.fmtDec(&buf, std.math.maxInt(u64)));
    try std.testing.expectEqualStrings("00000000000000af", fmt.fmtHex16(&buf, 0xaf));
    try std.testing.expectEqualStrings("deadbeef", fmt.fmtHex(&buf, 0xdeadbeef));
    try std.testing.expectEqualStrings("-9223372036854775808", fmt.fmtSignedDec(&buf, std.math.minInt(i64)));
}

test "COW clone keeps no-execute, which lives above the low flag bits" {
    // A writable, non-executable user data page — a stack or heap entry.
    const parent: u64 = cow_pte.NO_EXECUTE | 0x0000_0000_002e_4000 | 0x067;

    const shared = cow_pte.cowPte(parent);

    // The regression: deriving the child's entry from the frame plus the low 12
    // bits drops NX, because NX is bit 63.
    const low_flag_rebuild = (parent & 0x000F_FFFF_FFFF_F000) | (parent & 0xFFF);
    try std.testing.expect(low_flag_rebuild & cow_pte.NO_EXECUTE == 0);
    try std.testing.expect(shared & cow_pte.NO_EXECUTE != 0);
}

test "COW clone shares the frame read-only and marks both sides" {
    const frame: u64 = 0x0000_0000_002e_4000;
    const parent: u64 = cow_pte.NO_EXECUTE | frame | 0x067; // present|writable|user|accessed|dirty

    const shared = cow_pte.cowPte(parent);

    try std.testing.expectEqual(frame, shared & 0x000F_FFFF_FFFF_F000);
    try std.testing.expect(shared & cow_pte.WRITABLE == 0);
    try std.testing.expect(cow_pte.isCow(shared));
    try std.testing.expect(!cow_pte.isCow(parent));
    // Present and user survive, or the child could not reach its own memory.
    try std.testing.expect(shared & 0x005 == 0x005);
}

test "cloning an already-shared page is a no-op on its entry" {
    const parent: u64 = cow_pte.NO_EXECUTE | 0x0000_0000_002c_3000 | 0x067;

    const once = cow_pte.cowPte(parent);
    try std.testing.expectEqual(once, cow_pte.cowPte(once));
}

test "string helpers compare prefixes and bounded C strings" {
    try std.testing.expect(str.eql("moqi", "moqi"));
    try std.testing.expect(!str.eql("moqi", "moqios"));
    try std.testing.expect(str.startsWith("moqios", "moqi"));
    try std.testing.expect(!str.startsWith("moqi", "moqios"));

    const cstr = [_]u8{ 'o', 's', 0, 'x' };
    try std.testing.expectEqual(@as(usize, 2), str.strnlen(&cstr, cstr.len));
    try std.testing.expectEqual(@as(usize, 1), str.strnlen(&cstr, 1));
}

test "errno constants match the negative Linux convention" {
    try std.testing.expectEqual(@as(i64, -1), errno.EPERM);
    try std.testing.expectEqual(@as(i64, -2), errno.ENOENT);
    try std.testing.expectEqual(@as(i64, -12), errno.ENOMEM);
    try std.testing.expectEqual(@as(i64, -22), errno.EINVAL);
    try std.testing.expectEqual(@as(i64, -38), errno.ENOSYS);
    try std.testing.expectEqual(@as(i64, -111), errno.ECONNREFUSED);

    // Every exported constant is a distinct negative errno value.
    inline for (@typeInfo(errno).@"struct".decls) |d| {
        try std.testing.expect(@field(errno, d.name) < 0);
    }
    try std.testing.expect(errno.ENOENT != errno.EAGAIN);
    try std.testing.expect(errno.ENOTCONN != errno.ECONNRESET);
}

test "fmt.zig re-exports the fmt_core helpers unchanged" {
    var buf: [32]u8 = undefined;

    try std.testing.expectEqualStrings("42", fmt_serial.formatInt(&buf, 42));
    try std.testing.expectEqualStrings("0000000000000042", fmt_serial.formatHex(&buf, 0x42));
    try std.testing.expectEqualStrings("000000af", fmt_serial.fmtHex8(&buf, 0xaf));
    try std.testing.expectEqualStrings("ff", fmt_serial.fmtHex(&buf, 0xff));
}

test "ipv4 checksum matches the RFC 1071 worked example" {
    // RFC 1071 §3: bytes 00 01 f2 03 f4 f5 f6 f7 sum to 0xddf2, so the
    // one's-complement checksum is 0x220d.
    const data = [_]u8{ 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 };
    try std.testing.expectEqual(@as(u16, 0x220d), ipv4.checksum(&data, data.len));

    // Odd length: the trailing byte pairs with a zero low byte (0x0001+0xf200).
    const odd = [_]u8{ 0x00, 0x01, 0xf2 };
    try std.testing.expectEqual(@as(u16, 0x0dfe), ipv4.checksum(&odd, odd.len));
}

test "ipv4 header build/parse round-trips with a valid checksum" {
    var buf: [20]u8 = undefined;
    const src = [4]u8{ 192, 168, 0, 1 };
    const dst = [4]u8{ 192, 168, 0, 2 };

    ipv4.buildHeader(&buf, src, dst, ipv4.PROTO_UDP, 8);

    // Independently computed header checksum for these exact fields.
    try std.testing.expectEqual(@as(u16, 0xb97d), byte_order.readU16BeAt(&buf, 10));
    // A checksum computed over the final header (field included) is zero.
    try std.testing.expectEqual(@as(u16, 0), ipv4.checksum(&buf, 20));

    const info = ipv4.parseHeader(&buf, 28).?;
    try std.testing.expectEqualSlices(u8, &src, &info.src_ip);
    try std.testing.expectEqualSlices(u8, &dst, &info.dst_ip);
    try std.testing.expectEqual(ipv4.PROTO_UDP, info.protocol);
    try std.testing.expectEqual(@as(u16, 20), info.payload_offset);
    try std.testing.expectEqual(@as(u16, 8), info.payload_len);
    try std.testing.expect(!info.ecn_ce);
}

test "ipv4 parse rejects malformed headers and oversized total_len" {
    var buf: [20]u8 = undefined;
    ipv4.buildHeader(&buf, .{ 10, 0, 0, 1 }, .{ 10, 0, 0, 2 }, ipv4.PROTO_TCP, 40);

    // Version != 4.
    var bad = buf;
    bad[0] = 0x65;
    try std.testing.expect(ipv4.parseHeader(&bad, null) == null);

    // IHL below the 20-byte minimum.
    bad = buf;
    bad[0] = 0x41;
    try std.testing.expect(ipv4.parseHeader(&bad, null) == null);

    // Corrupted header: checksum no longer validates.
    bad = buf;
    bad[8] ^= 0xff;
    try std.testing.expect(ipv4.parseHeader(&bad, null) == null);

    // frame_len shorter than the header.
    try std.testing.expect(ipv4.parseHeader(&buf, 10) == null);

    // total_len (60) beyond the received frame.
    try std.testing.expect(ipv4.parseHeader(&buf, 30) == null);
    try std.testing.expect(ipv4.parseHeader(&buf, 60) != null);
}

test "ipv4 ECN helpers mark the header and keep the checksum valid" {
    var buf: [20]u8 = undefined;
    ipv4.buildHeader(&buf, .{ 10, 0, 0, 1 }, .{ 10, 0, 0, 2 }, ipv4.PROTO_TCP, 0);

    ipv4.setEct0(&buf);
    try std.testing.expectEqual(@as(u8, 0x02), buf[1] & 0x03);
    const info = ipv4.parseHeader(&buf, 20).?;
    try std.testing.expect(!info.ecn_ce); // ECT(0) is not Congestion Experienced

    // Manually mark CE (0x03) and re-seal; parse must report ecn_ce.
    buf[1] = (buf[1] & 0xFC) | ipv4.ECN_CE;
    buf[10] = 0;
    buf[11] = 0;
    byte_order.writeU16BeAt(&buf, 10, ipv4.checksum(&buf, 20));
    try std.testing.expect(ipv4.parseHeader(&buf, 20).?.ecn_ce);
}

test "ipv6 header build/parse round-trips" {
    var buf: [40]u8 = undefined;
    var src: [16]u8 = @splat(0);
    var dst: [16]u8 = @splat(0);
    src[0] = 0x20;
    src[1] = 0x01;
    src[15] = 0x01;
    dst[0] = 0x20;
    dst[1] = 0x01;
    dst[15] = 0x02;

    ipv6.buildHeader(&buf, src, dst, ipv6.PROTO_TCP, 40);

    const info = ipv6.parseHeader(&buf).?;
    try std.testing.expectEqualSlices(u8, &src, &info.src_ip);
    try std.testing.expectEqualSlices(u8, &dst, &info.dst_ip);
    try std.testing.expectEqual(ipv6.PROTO_TCP, info.next_header);
    try std.testing.expectEqual(ipv6.DEFAULT_HOP_LIMIT, info.hop_limit);
    try std.testing.expectEqual(@as(u16, 40), info.payload_offset);
    try std.testing.expectEqual(@as(u16, 40), info.payload_len);
    try std.testing.expect(!info.ecn_ce);

    // Version != 6 is rejected.
    var bad = buf;
    bad[0] = 0x45;
    try std.testing.expect(ipv6.parseHeader(&bad) == null);
}

test "ipv6 address classifiers and solicited-node multicast" {
    const unspecified: [16]u8 = @splat(0);
    try std.testing.expect(ipv6.isUnspecified(unspecified));

    var link_local: [16]u8 = @splat(0);
    link_local[0] = 0xfe;
    link_local[1] = 0x80;
    link_local[15] = 0x34;
    try std.testing.expect(ipv6.isLinkLocal(link_local));
    try std.testing.expect(!ipv6.isMulticast(link_local));

    // fe80::/10 on-link prefix match, including a partial-byte boundary.
    var fe80_prefix: [16]u8 = @splat(0);
    fe80_prefix[0] = 0xfe;
    fe80_prefix[1] = 0x80;
    try std.testing.expect(ipv6.prefixMatch(link_local, fe80_prefix, 10));
    try std.testing.expect(ipv6.prefixMatch(link_local, fe80_prefix, 64));
    try std.testing.expect(!ipv6.prefixMatch(link_local, fe80_prefix, 129));
    var other: [16]u8 = @splat(0);
    other[0] = 0x20;
    other[1] = 0x01;
    try std.testing.expect(!ipv6.prefixMatch(other, fe80_prefix, 10));

    // Solicited-node multicast: ff02::1:ffXX:XXXX from the low 24 bits.
    var target: [16]u8 = @splat(0);
    target[13] = 0xab;
    target[14] = 0xcd;
    target[15] = 0xef;
    const snm = ipv6.solicitedNodeMulticast(target);
    try std.testing.expect(ipv6.isMulticast(snm));
    try std.testing.expect(ipv6.isSolicitedNodeMulticast(snm, target));
    try std.testing.expectEqualSlices(u8, &.{ 0x33, 0x33, 0xff, 0xab, 0xcd, 0xef }, &ipv6.multicastMac(snm));
}

test "eth frame build writes header fields and reports total length" {
    var buf: [14]u8 = undefined;
    const dst = [6]u8{ 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };
    const src = [6]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 };

    const total = eth.buildFrame(&buf, dst, src, eth.ETHERTYPE_IPV4, 46);

    try std.testing.expectEqual(@as(u16, 60), total);
    try std.testing.expectEqualSlices(u8, &dst, buf[0..6]);
    try std.testing.expectEqualSlices(u8, &src, buf[6..12]);
    try std.testing.expectEqual(eth.ETHERTYPE_IPV4, eth.parseEthertype(&buf));

    // ARP and IPv6 ethertypes round-trip through the same offset.
    _ = eth.buildFrame(&buf, dst, src, eth.ETHERTYPE_IPV6, 0);
    try std.testing.expectEqual(eth.ETHERTYPE_IPV6, eth.parseEthertype(&buf));
}

test "tcp sequence comparisons wrap around the u32 boundary" {
    // 0xffffffff is "before" 0 in RFC 793 modular sequence space.
    try std.testing.expect(tcp_util.seqLt(0xffff_ffff, 0));
    try std.testing.expect(tcp_util.seqGt(0, 0xffff_ffff));
    try std.testing.expect(tcp_util.seqLeq(0xffff_ffff, 0xffff_ffff));
    try std.testing.expect(!tcp_util.seqLt(0, 0xffff_ffff));

    // Window [0xfffffff0, 0x10) wraps past the end of sequence space.
    try std.testing.expect(tcp_util.seqInWindow(0xffff_ffff, 0xffff_fff0, 0x10));
    try std.testing.expect(tcp_util.seqInWindow(0, 0xffff_fff0, 0x10));
    try std.testing.expect(tcp_util.seqInWindow(0x0f, 0xffff_fff0, 0x10));
    // Half-open: the right edge is excluded, just-left-of-left is outside.
    try std.testing.expect(!tcp_util.seqInWindow(0x10, 0xffff_fff0, 0x10));
    try std.testing.expect(!tcp_util.seqInWindow(0xffff_ffef, 0xffff_fff0, 0x10));
}

test "tcp ring-buffer helpers stay correct across index wrap" {
    // head/tail live in [0, size); (tail -% head) wraps through 2^32 and the
    // modulo brings it back into ring space.
    try std.testing.expectEqual(@as(u32, 246), tcp_util.ringDataLen(100, 90, 256));
    try std.testing.expectEqual(@as(u32, 20), tcp_util.ringDataLen(100, 120, 256));
    try std.testing.expectEqual(@as(u32, 0), tcp_util.ringDataLen(64, 64, 256));
    // One slot is reserved so a full ring is distinguishable from empty.
    try std.testing.expectEqual(@as(u32, 255), tcp_util.ringAvailable(64, 64, 256));
    try std.testing.expectEqual(@as(u32, 235), tcp_util.ringAvailable(100, 120, 256));
}

test "tcp checksum matches an independently computed RFC 793 vector" {
    // Pseudo-header (10.0.0.1 -> 10.0.0.2, proto TCP, len 20) + a 20-byte
    // header with the checksum field zeroed; expected value computed with an
    // independent RFC 1071 implementation.
    const tcp_hdr = [_]u8{
        0x11, 0x11, 0x22, 0x22, // src/dst ports
        0x01, 0x02, 0x03, 0x04, // seq
        0x00, 0x00, 0x00, 0x00, // ack
        0x50, 0x18, 0x10, 0x00, // offset|flags, window
        0x00, 0x00, 0x00, 0x00, // checksum (0), urgent
    };
    const csum = tcp_util.checksum(.{ 10, 0, 0, 1 }, .{ 10, 0, 0, 2 }, &tcp_hdr, tcp_hdr.len);
    try std.testing.expectEqual(@as(u16, 0x5491), csum);
}

test "udp header parse bounds-checks and reports payload length" {
    const hdr = [_]u8{ 0x04, 0xd2, 0x16, 0x2e, 0x00, 0x0c, 0x00, 0x00 };
    const info = udp_util.parseHeader(&hdr, hdr.len).?;
    try std.testing.expectEqual(@as(u16, 0x04d2), info.src_port);
    try std.testing.expectEqual(@as(u16, 0x162e), info.dst_port);
    try std.testing.expectEqual(@as(u16, 12), info.udp_len);
    try std.testing.expectEqual(@as(u16, 4), info.payload_len);

    // Shorter than the 8-byte header is rejected.
    try std.testing.expect(udp_util.parseHeader(&hdr, 7) == null);

    // A length field at/below the header size yields zero payload bytes.
    const short = [_]u8{ 0x00, 0x01, 0x00, 0x02, 0x00, 0x08, 0x00, 0x00 };
    try std.testing.expectEqual(@as(u16, 0), udp_util.parseHeader(&short, short.len).?.payload_len);
}

test "udp checksums match independently computed vectors" {
    const seg = [_]u8{
        0x04, 0xd2, 0x16, 0x2e, // src/dst ports
        0x00, 0x0c, 0x00, 0x00, // len 12, checksum 0
        0xde, 0xad, 0xbe, 0xef, // payload
    };
    const src4 = [4]u8{ 192, 168, 0, 1 };
    const dst4 = [4]u8{ 192, 168, 0, 2 };
    try std.testing.expectEqual(@as(u16, 0xc5e4), udp_util.checksumV4(src4, dst4, &seg, seg.len));

    var src6: [16]u8 = @splat(0);
    var dst6: [16]u8 = @splat(0);
    src6[0] = 0x20;
    src6[1] = 0x01;
    src6[2] = 0x0d;
    src6[3] = 0xb8;
    src6[15] = 0x01;
    dst6[0] = 0x20;
    dst6[1] = 0x01;
    dst6[2] = 0x0d;
    dst6[3] = 0xb8;
    dst6[15] = 0x02;
    try std.testing.expectEqual(@as(u16, 0xebc3), udp_util.checksumV6(src6, dst6, &seg, seg.len));
}

/// Build a minimal fake PCI config-space image with a capabilities list.
/// caps: list of .{ offset, cap_id, next_offset } entries; status bit 4 set.
fn fakeConfigWithCaps(caps: []const struct { off: u8, id: u8, next: u8 }) [256]u8 {
    var cfg: [256]u8 = @splat(0);
    // Status register (offset 0x06), bit 4: capabilities list present.
    cfg[0x06] = 0x10;
    cfg[0x34] = if (caps.len > 0) caps[0].off else 0;
    for (caps) |c| {
        cfg[c.off] = c.id;
        cfg[c.off + 1] = c.next;
    }
    return cfg;
}

test "pci capability walk finds MSI-X by ID 0x11" {
    const cfg = fakeConfigWithCaps(&.{
        .{ .off = 0x40, .id = 0x01, .next = 0x50 }, // Power Management
        .{ .off = 0x50, .id = 0x05, .next = 0x60 }, // MSI
        .{ .off = 0x60, .id = 0x11, .next = 0x00 }, // MSI-X (last)
    });

    try std.testing.expectEqual(@as(?u8, 0x60), pci_msix.findCapability(&cfg, 0x11));
    try std.testing.expectEqual(@as(?u8, 0x50), pci_msix.findCapability(&cfg, 0x05));
    // Capability not in the list terminates the walk with null.
    try std.testing.expectEqual(@as(?u8, null), pci_msix.findCapability(&cfg, 0x10));

    // No capabilities list (status bit 4 clear) -> null even if bytes match.
    var no_caps = cfg;
    no_caps[0x06] = 0;
    try std.testing.expectEqual(@as(?u8, null), pci_msix.findCapability(&no_caps, 0x11));

    // Empty list pointer -> null.
    var empty = cfg;
    empty[0x34] = 0;
    try std.testing.expectEqual(@as(?u8, null), pci_msix.findCapability(&empty, 0x11));

    // Truncated image cannot host a walk.
    try std.testing.expectEqual(@as(?u8, null), pci_msix.findCapability(cfg[0..0x20], 0x11));
}

test "MSI-X capability parse decodes table size, BIR and offsets" {
    var cfg = fakeConfigWithCaps(&.{
        .{ .off = 0x40, .id = 0x11, .next = 0x00 },
    });
    // Message Control (cap+2): table size N-1 = 3 -> 4 entries.
    cfg[0x42] = 0x03;
    cfg[0x43] = 0x00;
    // Table BIR/offset (cap+4): BIR=4, offset 0x0000_2000 (8-byte aligned).
    byte_order.writeU32Le(cfg[0x44..0x48], 0x0000_2004);
    // PBA BIR/offset (cap+8): BIR=4, offset 0x0000_3000.
    byte_order.writeU32Le(cfg[0x48..0x4C], 0x0000_3004);

    const info = pci_msix.parseMsixCapability(&cfg, 0x40).?;
    try std.testing.expectEqual(@as(u16, 4), info.table_size);
    try std.testing.expectEqual(@as(u8, 4), info.table_bir);
    try std.testing.expectEqual(@as(u32, 0x2000), info.table_offset);
    try std.testing.expectEqual(@as(u8, 4), info.pba_bir);
    try std.testing.expectEqual(@as(u32, 0x3000), info.pba_offset);

    // Wrong capability ID at the offset is rejected.
    try std.testing.expectEqual(@as(?pci_msix.MsixInfo, null), pci_msix.parseMsixCapability(&cfg, 0x44));
}

test "MSI-X table size decode is N-1 based" {
    try std.testing.expectEqual(@as(u16, 1), pci_msix.msixTableSize(0x0000));
    try std.testing.expectEqual(@as(u16, 4), pci_msix.msixTableSize(0x0003));
    try std.testing.expectEqual(@as(u16, 2048), pci_msix.msixTableSize(0x07FF));
    // Enable/function-mask bits (14/15) do not leak into the size.
    try std.testing.expectEqual(@as(u16, 5), pci_msix.msixTableSize(0xC004));
}

test "MSI-X message address/data compose fixed LAPIC delivery" {
    // BSP (APIC ID 0): plain LAPIC base, vector in the low data byte.
    try std.testing.expectEqual(@as(u64, 0xFEE0_0000), pci_msix.composeMessageAddress(0xFEE0_0000, 0));
    try std.testing.expectEqual(@as(u32, 242), pci_msix.composeMessageData(242));

    // Non-zero destination APIC ID lands in address bits 19:12.
    try std.testing.expectEqual(@as(u64, 0xFEE0_3000), pci_msix.composeMessageAddress(0xFEE0_0000, 3));

    // Data word: fixed delivery mode (000) keeps everything above the vector clear.
    try std.testing.expectEqual(@as(u32, 0), pci_msix.composeMessageData(0));
    try std.testing.expectEqual(@as(u32, 0xFF), pci_msix.composeMessageData(0xFF));
}

// ─── loopback (F2) ───
const lo = kt.lo;

test "lo queue enqueue/dequeue preserves FIFO order" {
    var q = lo.LoopbackQueue.init();
    try std.testing.expectEqual(@as(u32, 0), q.pending());

    const a = [_]u8{ 0xaa, 0xbb, 0xcc };
    const b = [_]u8{ 0x11, 0x22 };
    try std.testing.expect(q.enqueue(&a));
    try std.testing.expect(q.enqueue(&b));
    try std.testing.expectEqual(@as(u32, 2), q.pending());

    var out: [lo.MAX_FRAME]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 3), q.dequeue(&out));
    try std.testing.expectEqualSlices(u8, &a, out[0..3]);
    try std.testing.expectEqual(@as(u32, 2), q.dequeue(&out));
    try std.testing.expectEqualSlices(u8, &b, out[0..2]);
    try std.testing.expectEqual(@as(u32, 0), q.dequeue(&out));
    try std.testing.expectEqual(@as(u32, 0), q.pending());
}

test "lo queue head/tail wrap around the ring" {
    var q = lo.LoopbackQueue.init();
    var out: [lo.MAX_FRAME]u8 = undefined;

    // Cycle more frames than QUEUE_DEPTH so head/tail wrap past slot 0.
    var i: u32 = 0;
    while (i < lo.QUEUE_DEPTH * 3) : (i += 1) {
        const frame = [_]u8{ @truncate(i), 0x5a };
        try std.testing.expect(q.enqueue(&frame));
        try std.testing.expectEqual(@as(u32, 2), q.dequeue(&out));
        try std.testing.expectEqual(@as(u8, @truncate(i)), out[0]);
        try std.testing.expectEqual(@as(u8, 0x5a), out[1]);
    }
    try std.testing.expectEqual(@as(u32, 0), q.pending());
    try std.testing.expectEqual(@as(u64, 0), q.dropped);
}

test "lo queue full drops new frames and counts them" {
    var q = lo.LoopbackQueue.init();
    const frame = [_]u8{0x42} ** 64;

    var i: u32 = 0;
    while (i < lo.QUEUE_DEPTH) : (i += 1) try std.testing.expect(q.enqueue(&frame));
    try std.testing.expectEqual(lo.QUEUE_DEPTH, q.pending());

    try std.testing.expect(!q.enqueue(&frame));
    try std.testing.expect(!q.enqueue(&frame));
    try std.testing.expectEqual(@as(u64, 2), q.dropped);

    // One dequeue frees a slot, then exactly one more frame fits.
    var out: [lo.MAX_FRAME]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 64), q.dequeue(&out));
    try std.testing.expect(q.enqueue(&frame));
    try std.testing.expectEqual(lo.QUEUE_DEPTH, q.pending());
}

test "lo queue rejects empty and oversized frames" {
    var q = lo.LoopbackQueue.init();
    try std.testing.expect(!q.enqueue(&[_]u8{}));
    const big = [_]u8{0xff} ** (lo.MAX_FRAME + 1);
    try std.testing.expect(!q.enqueue(&big));
    try std.testing.expectEqual(@as(u32, 0), q.pending());

    // Exactly MAX_FRAME bytes still fits.
    const max_frame = [_]u8{0x7e} ** lo.MAX_FRAME;
    try std.testing.expect(q.enqueue(&max_frame));
    var out: [lo.MAX_FRAME]u8 = undefined;
    try std.testing.expectEqual(lo.MAX_FRAME, q.dequeue(&out));
    try std.testing.expectEqualSlices(u8, &max_frame, &out);
}

test "lo isLoopback classifies the whole 127.0.0.0/8 block" {
    try std.testing.expect(lo.isLoopback(.{ 127, 0, 0, 1 }));
    try std.testing.expect(lo.isLoopback(.{ 127, 0, 0, 0 }));
    try std.testing.expect(lo.isLoopback(.{ 127, 255, 255, 254 }));
    try std.testing.expect(!lo.isLoopback(.{ 126, 255, 255, 255 }));
    try std.testing.expect(!lo.isLoopback(.{ 128, 0, 0, 1 }));
    try std.testing.expect(!lo.isLoopback(.{ 10, 0, 2, 15 }));
    try std.testing.expect(!lo.isLoopback(.{ 0, 0, 0, 0 }));
}

// ─── RT scheduling (F3) ───
// Pure policy-logic tests for kernel/proc/sched_policy.zig (SCHED_FIFO/RR).

test "F3: RT classes beat every OTHER task regardless of priority band" {
    const sp = kt.sched_policy;

    // Lowest-prio RT task (rt 1 → kernel 98) still beats the highest-prio
    // OTHER task (nice -20 → kernel 0).
    try std.testing.expect(sp.beats(sp.SCHED_FIFO, 98, sp.SCHED_OTHER, 0));
    try std.testing.expect(sp.beats(sp.SCHED_RR, 98, sp.SCHED_OTHER, 0));
    // ... and beats the default OTHER task (kernel 20) and idle (255).
    try std.testing.expect(sp.beats(sp.SCHED_FIFO, 98, sp.SCHED_OTHER, 20));
    try std.testing.expect(sp.beats(sp.SCHED_RR, 0, sp.SCHED_OTHER, 255));
    // OTHER never beats RT.
    try std.testing.expect(!sp.beats(sp.SCHED_OTHER, 0, sp.SCHED_FIFO, 98));
    try std.testing.expect(!sp.beats(sp.SCHED_OTHER, 0, sp.SCHED_RR, 98));
}

test "F3: within-class ordering preserves kernel priority order" {
    const sp = kt.sched_policy;

    // RT: higher sched_priority (lower kernel prio) wins; FIFO vs RR at the
    // same RT priority rank equally (neither strictly beats the other).
    try std.testing.expect(sp.beats(sp.SCHED_FIFO, sp.rtToKernelPriority(99), sp.SCHED_RR, sp.rtToKernelPriority(1)));
    try std.testing.expect(!sp.beats(sp.SCHED_FIFO, 10, sp.SCHED_RR, 10));
    try std.testing.expect(!sp.beats(sp.SCHED_RR, 10, sp.SCHED_FIFO, 10));
    // OTHER: identical to the pre-F3 raw comparison (lower number wins).
    try std.testing.expect(sp.beats(sp.SCHED_OTHER, 0, sp.SCHED_OTHER, 20));
    try std.testing.expect(sp.beats(sp.SCHED_OTHER, 20, sp.SCHED_OTHER, 39));
    try std.testing.expect(!sp.beats(sp.SCHED_OTHER, 20, sp.SCHED_OTHER, 20));
}

test "F3: quantum expiry per class" {
    const sp = kt.sched_policy;

    // FIFO runs until it blocks/yields — no quantum expiry.
    try std.testing.expect(!sp.hasQuantumExpiry(sp.SCHED_FIFO));
    // RR and OTHER expire (RR rotates among equal-priority peers).
    try std.testing.expect(sp.hasQuantumExpiry(sp.SCHED_RR));
    try std.testing.expect(sp.hasQuantumExpiry(sp.SCHED_OTHER));
    try std.testing.expectEqual(@as(u64, 10), sp.RR_QUANTUM_TICKS);
}

test "F3: RT priority clamping and kernel-band mapping" {
    const sp = kt.sched_policy;

    try std.testing.expectEqual(@as(u8, 1), sp.clampRtPriority(-5));
    try std.testing.expectEqual(@as(u8, 1), sp.clampRtPriority(0));
    try std.testing.expectEqual(@as(u8, 50), sp.clampRtPriority(50));
    try std.testing.expectEqual(@as(u8, 99), sp.clampRtPriority(100));
    try std.testing.expectEqual(@as(u8, 99), sp.clampRtPriority(1000));

    // Band mapping: rt 99 → kernel 0 (best), rt 1 → kernel 98, round-trips.
    try std.testing.expectEqual(@as(u8, 0), sp.rtToKernelPriority(99));
    try std.testing.expectEqual(@as(u8, 98), sp.rtToKernelPriority(1));
    try std.testing.expectEqual(@as(u8, 99), sp.kernelToRtPriority(0));
    try std.testing.expectEqual(@as(u8, 1), sp.kernelToRtPriority(98));
    var rt: u8 = 1;
    while (rt <= 99) : (rt += 1) {
        try std.testing.expectEqual(rt, sp.kernelToRtPriority(sp.rtToKernelPriority(rt)));
    }
}

test "F3: priority validation per policy (sched_setscheduler rules)" {
    const sp = kt.sched_policy;

    // OTHER requires priority 0.
    try std.testing.expect(sp.validatePriority(sp.SCHED_OTHER, 0));
    try std.testing.expect(!sp.validatePriority(sp.SCHED_OTHER, 1));
    try std.testing.expect(!sp.validatePriority(sp.SCHED_OTHER, -1));
    // FIFO/RR require 1..99.
    try std.testing.expect(!sp.validatePriority(sp.SCHED_FIFO, 0));
    try std.testing.expect(sp.validatePriority(sp.SCHED_FIFO, 1));
    try std.testing.expect(sp.validatePriority(sp.SCHED_FIFO, 99));
    try std.testing.expect(!sp.validatePriority(sp.SCHED_FIFO, 100));
    try std.testing.expect(!sp.validatePriority(sp.SCHED_RR, 0));
    try std.testing.expect(sp.validatePriority(sp.SCHED_RR, 50));
    try std.testing.expect(!sp.validatePriority(sp.SCHED_RR, 100));
    // Unknown policies rejected outright.
    try std.testing.expect(!sp.validatePriority(3, 0)); // BATCH — not implemented
    try std.testing.expect(!sp.validatePriority(6, 0)); // DEADLINE — not implemented
    try std.testing.expect(!sp.isValidClass(3));
    try std.testing.expect(sp.isValidClass(sp.SCHED_OTHER));
    try std.testing.expect(sp.isValidClass(sp.SCHED_FIFO));
    try std.testing.expect(sp.isValidClass(sp.SCHED_RR));
}

test "F3: rankKey bands — RT below OTHER below idle, OTHER order intact" {
    const sp = kt.sched_policy;

    // Every RT key < every OTHER key.
    try std.testing.expect(sp.rankKey(sp.SCHED_FIFO, 98) < sp.rankKey(sp.SCHED_OTHER, 0));
    try std.testing.expect(sp.rankKey(sp.SCHED_RR, 0) < sp.rankKey(sp.SCHED_OTHER, 255));
    // OTHER keys are monotonic in kernel priority (pre-F3 ordering preserved).
    try std.testing.expect(sp.rankKey(sp.SCHED_OTHER, 0) < sp.rankKey(sp.SCHED_OTHER, 20));
    try std.testing.expect(sp.rankKey(sp.SCHED_OTHER, 20) < sp.rankKey(sp.SCHED_OTHER, 255));
    // Idle (OTHER, 255) stays unpickable by the bitmap fallback, matching the
    // old `best_prio = 255` initialiser: its key is not below MAX_PICK_KEY.
    try std.testing.expect(!(sp.rankKey(sp.SCHED_OTHER, 255) < sp.MAX_PICK_KEY));
    try std.testing.expect(sp.rankKey(sp.SCHED_OTHER, 254) < sp.MAX_PICK_KEY);
    try std.testing.expect(sp.rankKey(sp.SCHED_FIFO, 98) < sp.MAX_PICK_KEY);
}
// ─── end RT scheduling (F3) ───

// ─── kmsg ring (G4) ───
const kmsg_ring = kt.kmsg_ring;

/// Drain the ring from `cursor` into `out`, following short reads at the
/// physical wrap. Returns bytes copied and the final cursor.
fn kmsgDrain(ring: anytype, cursor: u64, out: []u8) struct { n: usize, pos: u64 } {
    var pos = cursor;
    var copied: usize = 0;
    while (copied < out.len) {
        const r = ring.read(pos, out[copied..]);
        pos = r.new_pos;
        copied += r.n;
        if (r.n == 0) break;
    }
    return .{ .n = copied, .pos = pos };
}

test "G4: empty ring reads as EOF" {
    var ring: kmsg_ring.KmsgRing(64) = .{};
    var buf: [16]u8 = undefined;
    const r = ring.read(0, &buf);
    try std.testing.expectEqual(@as(usize, 0), r.n);
    try std.testing.expectEqual(@as(u64, 0), r.new_pos);
}

test "G4: append lines and read them back from cursor 0" {
    var ring: kmsg_ring.KmsgRing(64) = .{};
    ring.appendLine("[INF] one\n");
    ring.appendLine("[DBG] two\n");

    var buf: [64]u8 = undefined;
    const d = kmsgDrain(&ring, 0, &buf);
    try std.testing.expectEqualStrings("[INF] one\n[DBG] two\n", buf[0..d.n]);
    try std.testing.expectEqual(@as(u64, 20), d.pos);

    // Reading at the newest cursor is EOF.
    const r = ring.read(d.pos, &buf);
    try std.testing.expectEqual(@as(usize, 0), r.n);
}

test "G4: piecewise append (prefix + body + newline) reads as one line" {
    var ring: kmsg_ring.KmsgRing(64) = .{};
    ring.appendLine("[INF] ");
    ring.appendLine("0x");
    ring.appendLine("deadbeef");
    ring.appendLine("\n");

    var buf: [64]u8 = undefined;
    const d = kmsgDrain(&ring, 0, &buf);
    try std.testing.expectEqualStrings("[INF] 0xdeadbeef\n", buf[0..d.n]);
}

test "G4: wrap drops oldest whole lines, keeps newest intact" {
    var ring: kmsg_ring.KmsgRing(16) = .{};
    ring.appendLine("AAAA\n"); // 5
    ring.appendLine("BBBB\n"); // 10
    ring.appendLine("CCCC\n"); // 15 — 1 byte free
    ring.appendLine("DDDD\n"); // needs 5: drops AAAA only (BBBB..DDDD = 15 <= 16)

    var buf: [32]u8 = undefined;
    const d = kmsgDrain(&ring, 0, &buf);
    try std.testing.expectEqualStrings("BBBB\nCCCC\nDDDD\n", buf[0..d.n]);

    // Absolute cursors survive the wrap: 20 bytes appended total.
    try std.testing.expectEqual(@as(u64, 20), d.pos);
    try std.testing.expectEqual(@as(u64, 5), ring.oldestPos());
}

test "G4: stale cursor clamps forward to the oldest available byte" {
    var ring: kmsg_ring.KmsgRing(16) = .{};
    ring.appendLine("AAAA\n");
    ring.appendLine("BBBB\n");
    ring.appendLine("CCCC\n");
    ring.appendLine("DDDD\n"); // oldest is now absolute 5 ("BBBB\n...")

    var buf: [16]u8 = undefined;
    // Cursor 3 points into long-gone "AAAA\n" — clamp to 5.
    const r = ring.read(3, &buf);
    try std.testing.expect(r.n > 0);
    try std.testing.expectEqual(@as(u8, 'B'), buf[0]);
    try std.testing.expectEqual(@as(u64, 5 + r.n), r.new_pos);
}

test "G4: short read at the physical wrap, continuation gets the rest" {
    var ring: kmsg_ring.KmsgRing(8) = .{};
    ring.appendLine("ab\n"); // bytes 0..3
    ring.appendLine("cd\n"); // bytes 3..6 — write head now near the end
    ring.appendLine("ef\n"); // drops "ab\n", wraps mid-line: bytes 6..9

    // First read must stop at the physical end of the buffer...
    var buf: [8]u8 = undefined;
    const r1 = ring.read(ring.oldestPos(), &buf);
    try std.testing.expect(r1.n > 0);
    // ...and draining must still reconstruct "cd\nef\n" (6 bytes).
    const d = kmsgDrain(&ring, ring.oldestPos(), &buf);
    try std.testing.expectEqualStrings("cd\nef\n", buf[0..d.n]);
    try std.testing.expectEqual(@as(u64, 9), d.pos);
}

test "G4: line longer than the whole ring keeps only its tail" {
    var ring: kmsg_ring.KmsgRing(8) = .{};
    const long = "0123456789\n"; // 11 bytes > 8
    ring.appendLine(long);

    var buf: [16]u8 = undefined;
    const d = kmsgDrain(&ring, 0, &buf);
    try std.testing.expectEqualStrings(long[long.len - 8 ..], buf[0..d.n]);
}

test "G4: ring survives many small lines (overwrite-oldest stress)" {
    var ring: kmsg_ring.KmsgRing(32) = .{};
    // 20 lines of "Lnn\n" (4 bytes each) = 80 bytes through a 32-byte ring.
    var linebuf: [4]u8 = undefined;
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        linebuf[0] = 'L';
        linebuf[1] = '0' + @as(u8, @intCast(i / 10));
        linebuf[2] = '0' + @as(u8, @intCast(i % 10));
        linebuf[3] = '\n';
        ring.appendLine(&linebuf);
    }
    // Only the last 8 lines fit.
    var buf: [64]u8 = undefined;
    const d = kmsgDrain(&ring, 0, &buf);
    try std.testing.expectEqual(@as(usize, 32), d.n);
    try std.testing.expectEqualStrings("L12\nL13\nL14\nL15\nL16\nL17\nL18\nL19\n", buf[0..d.n]);
    try std.testing.expectEqual(@as(u64, 80), d.pos);
}
// ─── end kmsg ring (G4) ───

// ─── DHCP boot (G3) ───
// The lease-state globals are pure (no arch deps): only the packet TX/RX
// paths reach serial/udp/nic, and Zig's lazy decl analysis leaves those
// unanalyzed here. Pinning the defaults matters because netif.getOurIp()
// falls back to static 10.0.2.15 exactly when isConfigured() is false.
test "G3: DHCP lease state defaults to unconfigured (static fallback active)" {
    const dhcp = kt.dhcp;

    try std.testing.expect(!dhcp.isConfigured());
    try std.testing.expectEqual(@as([4]u8, .{ 0, 0, 0, 0 }), dhcp.getIp());
    try std.testing.expectEqual(@as([4]u8, .{ 0, 0, 0, 0 }), dhcp.getGateway());
    try std.testing.expectEqual(@as([4]u8, .{ 255, 255, 255, 0 }), dhcp.getNetmask());
    try std.testing.expectEqual(@as([4]u8, .{ 0, 0, 0, 0 }), dhcp.getDnsServer());
}
// ─── end DHCP boot (G3) ───

// ─── TRIM (G5) ───
const trim_ranges = kt.trim_ranges;
const TrimExtent = trim_ranges.Extent;

test "G5: empty extent list coalesces to zero ranges" {
    var out: [4]TrimExtent = undefined;
    try std.testing.expectEqual(@as(usize, 0), trim_ranges.coalesce(&.{}, &out));
}

test "G5: single extent passes through unchanged" {
    var out: [4]TrimExtent = undefined;
    const in = [_]TrimExtent{.{ .start = 100, .count = 8 }};
    const n = trim_ranges.coalesce(&in, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u64, 100), out[0].start);
    try std.testing.expectEqual(@as(u32, 8), out[0].count);
}

test "G5: adjacent extents merge into one contiguous range" {
    var out: [4]TrimExtent = undefined;
    const in = [_]TrimExtent{
        .{ .start = 100, .count = 8 },
        .{ .start = 108, .count = 8 },
        .{ .start = 116, .count = 4 },
    };
    const n = trim_ranges.coalesce(&in, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u64, 100), out[0].start);
    try std.testing.expectEqual(@as(u32, 20), out[0].count);
}

test "G5: overlapping extents merge without double counting" {
    var out: [4]TrimExtent = undefined;
    const in = [_]TrimExtent{
        .{ .start = 100, .count = 16 },
        .{ .start = 108, .count = 16 }, // overlaps 108..115
    };
    const n = trim_ranges.coalesce(&in, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u64, 100), out[0].start);
    try std.testing.expectEqual(@as(u32, 24), out[0].count);
}

test "G5: disjoint extents stay separate and come out sorted" {
    var out: [4]TrimExtent = undefined;
    // Deliberately unsorted input (ext2 indirect-tree frees arrive out of order).
    const in = [_]TrimExtent{
        .{ .start = 500, .count = 4 },
        .{ .start = 100, .count = 8 },
        .{ .start = 108, .count = 2 },
    };
    const n = trim_ranges.coalesce(&in, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u64, 100), out[0].start);
    try std.testing.expectEqual(@as(u32, 10), out[0].count);
    try std.testing.expectEqual(@as(u64, 500), out[1].start);
    try std.testing.expectEqual(@as(u32, 4), out[1].count);
}

test "G5: zero-count extents are dropped" {
    var out: [4]TrimExtent = undefined;
    const in = [_]TrimExtent{
        .{ .start = 100, .count = 0 },
        .{ .start = 200, .count = 4 },
    };
    const n = trim_ranges.coalesce(&in, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u64, 200), out[0].start);
}

test "G5: contained extent does not grow the range" {
    var out: [4]TrimExtent = undefined;
    const in = [_]TrimExtent{
        .{ .start = 100, .count = 64 },
        .{ .start = 120, .count = 8 }, // fully inside the first
    };
    const n = trim_ranges.coalesce(&in, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u64, 100), out[0].start);
    try std.testing.expectEqual(@as(u32, 64), out[0].count);
}
// ─── end TRIM (G5) ───

// ─── file mmap (G2) ───
const filemap = kt.filemap;

const G2Region = struct {
    base: u64 = 0,
    num_pages: u64 = 0,
    active: bool = false,
    file_kind: u8 = 0,
    prot: u8 = 0,
    file_offset: u64 = 0,
    file_size: u64 = 0,
    shared: bool = false,
};

test "G2: mmap offset must be page-aligned" {
    try std.testing.expect(filemap.offsetValid(0));
    try std.testing.expect(filemap.offsetValid(4096));
    try std.testing.expect(filemap.offsetValid(8192));
    try std.testing.expect(!filemap.offsetValid(1));
    try std.testing.expect(!filemap.offsetValid(4095));
    try std.testing.expect(!filemap.offsetValid(4097));
}

test "fault-around window caps at 15 pages and the region end" {
    const base: u64 = 0x4000_0000;
    // Large region: full 15-page forward window from the first page.
    try std.testing.expectEqual(@as(u64, 15), filemap.faultAroundAhead(base, 1000, base));
    // Window shrinks toward the region end.
    try std.testing.expectEqual(@as(u64, 3), filemap.faultAroundAhead(base, 100, base + 96 * 4096));
    // Last page of the region: nothing ahead.
    try std.testing.expectEqual(@as(u64, 0), filemap.faultAroundAhead(base, 100, base + 99 * 4096));
    // Single-page region: zero.
    try std.testing.expectEqual(@as(u64, 0), filemap.faultAroundAhead(base, 1, base));
    // Prefault safety: writable shared mappings are excluded (dirty-bit
    // would be paid for unwritten data); everything else prefaults.
    try std.testing.expect(!filemap.prefaultSafe(true));
    try std.testing.expect(filemap.prefaultSafe(false));
}

test "G2: findFileRegion matches only active file-backed regions" {
    const regions = [_]G2Region{
        .{ .base = 0x1000, .num_pages = 2, .active = true, .file_kind = 2 },
        .{ .base = 0x4000, .num_pages = 1, .active = true, .file_kind = 0 }, // anonymous
        .{ .base = 0x8000, .num_pages = 4, .active = false, .file_kind = 3 }, // inactive
        .{ .base = 0x10000, .num_pages = 2, .active = true, .file_kind = 3 },
    };
    try std.testing.expectEqual(@as(?usize, 0), filemap.findFileRegion(G2Region, &regions, 0x1000));
    try std.testing.expectEqual(@as(?usize, 0), filemap.findFileRegion(G2Region, &regions, 0x2fff));
    // Just past the end of region 0.
    try std.testing.expectEqual(@as(?usize, null), filemap.findFileRegion(G2Region, &regions, 0x3000));
    // Anonymous and inactive regions are invisible to the file fault path.
    try std.testing.expectEqual(@as(?usize, null), filemap.findFileRegion(G2Region, &regions, 0x4000));
    try std.testing.expectEqual(@as(?usize, null), filemap.findFileRegion(G2Region, &regions, 0x8000));
    try std.testing.expectEqual(@as(?usize, 3), filemap.findFileRegion(G2Region, &regions, 0x11000));
    try std.testing.expectEqual(@as(?usize, null), filemap.findFileRegion(G2Region, &regions, 0x0));
}

test "G2: planFault computes file offset, EOF clamp and COW permissions" {
    const PAGE = filemap.PAGE_SIZE;
    const r = G2Region{
        .base = 0x400000,
        .num_pages = 4,
        .active = true,
        .file_kind = 2,
        .prot = filemap.PROT_READ | filemap.PROT_WRITE,
        .file_offset = 0,
        .file_size = 10000,
    };
    // Page 0: full page from the file, COW-shared (PROT_WRITE, MAP_PRIVATE).
    var p = filemap.planFault(G2Region, &r, 0x400000);
    try std.testing.expect(p.action == .file_page);
    try std.testing.expectEqual(@as(u64, 0), p.file_off);
    try std.testing.expectEqual(@as(u32, 4096), p.valid_bytes);
    try std.testing.expect(p.cow);
    try std.testing.expect(!p.executable);
    // Page 2: partial last page — 10000 - 8192 = 1808 valid bytes, tail zeroed.
    p = filemap.planFault(G2Region, &r, 0x400000 + 2 * PAGE);
    try std.testing.expect(p.action == .file_page);
    try std.testing.expectEqual(@as(u64, 8192), p.file_off);
    try std.testing.expectEqual(@as(u32, 1808), p.valid_bytes);
    // Page 3: wholly past EOF → SIGSEGV (Linux SIGBUS semantics).
    p = filemap.planFault(G2Region, &r, 0x400000 + 3 * PAGE);
    try std.testing.expect(p.action == .segv);

    // PROT_READ mapping: shared read-only, no COW marker.
    const r_ro = G2Region{ .base = 0x400000, .num_pages = 1, .active = true, .file_kind = 2, .prot = filemap.PROT_READ, .file_offset = 0, .file_size = 4096 };
    p = filemap.planFault(G2Region, &r_ro, 0x400000);
    try std.testing.expect(p.action == .file_page);
    try std.testing.expect(!p.cow);

    // Non-zero mmap offset shifts the mapped window into the file.
    const r_off = G2Region{ .base = 0x400000, .num_pages = 2, .active = true, .file_kind = 3, .prot = filemap.PROT_READ, .file_offset = 8192, .file_size = 16384 };
    p = filemap.planFault(G2Region, &r_off, 0x400000 + PAGE);
    try std.testing.expect(p.action == .file_page);
    try std.testing.expectEqual(@as(u64, 12288), p.file_off);
    try std.testing.expectEqual(@as(u32, 4096), p.valid_bytes);

    // PROT_EXEC keeps NX clear; read+exec is not COW.
    const r_x = G2Region{ .base = 0x400000, .num_pages = 1, .active = true, .file_kind = 3, .prot = filemap.PROT_READ | filemap.PROT_EXEC, .file_offset = 0, .file_size = 4096 };
    p = filemap.planFault(G2Region, &r_x, 0x400000);
    try std.testing.expect(p.executable);
    try std.testing.expect(!p.cow);
}

test "G2: munmap head-trim advances the file offset" {
    try std.testing.expectEqual(@as(u64, 8192), filemap.advanceFileOffset(0, 2));
    try std.testing.expectEqual(@as(u64, 12288), filemap.advanceFileOffset(4096, 2));
    try std.testing.expectEqual(@as(u64, 0), filemap.advanceFileOffset(0, 0));
}

test "G2: region merging is only valid between anonymous regions" {
    try std.testing.expect(filemap.canMergeAnon(0, 0));
    try std.testing.expect(!filemap.canMergeAnon(0, 2));
    try std.testing.expect(!filemap.canMergeAnon(3, 0));
    try std.testing.expect(!filemap.canMergeAnon(3, 3));
}

test "G2: PTE synthesis for shared file frames and private copies" {
    const phys: u64 = 0x12345000;

    // Writable MAP_PRIVATE: present+user, read-only, COW marker, NX.
    var pte = filemap.filePte(phys, true, false);
    try std.testing.expectEqual(phys, pte & filemap.PTE_ADDR_MASK);
    try std.testing.expect(pte & filemap.PTE_PRESENT != 0);
    try std.testing.expect(pte & filemap.PTE_USER != 0);
    try std.testing.expect(pte & filemap.PTE_WRITABLE == 0);
    try std.testing.expect(pte & filemap.PTE_COW != 0);
    try std.testing.expect(pte & filemap.PTE_NX != 0);

    // Read-only shared frame: no COW, no writable.
    pte = filemap.filePte(phys, false, false);
    try std.testing.expect(pte & filemap.PTE_COW == 0);
    try std.testing.expect(pte & filemap.PTE_WRITABLE == 0);

    // Executable mapping keeps NX clear.
    pte = filemap.filePte(phys, false, true);
    try std.testing.expect(pte & filemap.PTE_NX == 0);

    // Private copy honours prot, never carries the COW marker.
    pte = filemap.privatePte(phys, filemap.PROT_READ | filemap.PROT_WRITE);
    try std.testing.expectEqual(phys, pte & filemap.PTE_ADDR_MASK);
    try std.testing.expect(pte & filemap.PTE_WRITABLE != 0);
    try std.testing.expect(pte & filemap.PTE_COW == 0);
    try std.testing.expect(pte & filemap.PTE_NX != 0);
    pte = filemap.privatePte(phys, filemap.PROT_READ);
    try std.testing.expect(pte & filemap.PTE_WRITABLE == 0);
}
// ─── end file mmap (G2) ───

// ─── MAP_SHARED (H1) ───

test "H1: sharedPte maps the backing frame writable per prot, never COW" {
    const phys: u64 = 0x45670000;

    // Writable shared mapping: present+user+writable, no COW, NX.
    var pte = filemap.sharedPte(phys, filemap.PROT_READ | filemap.PROT_WRITE);
    try std.testing.expectEqual(phys, pte & filemap.PTE_ADDR_MASK);
    try std.testing.expect(pte & filemap.PTE_PRESENT != 0);
    try std.testing.expect(pte & filemap.PTE_USER != 0);
    try std.testing.expect(pte & filemap.PTE_WRITABLE != 0);
    try std.testing.expect(pte & filemap.PTE_COW == 0);
    try std.testing.expect(pte & filemap.PTE_NX != 0);

    // Read-only shared mapping: not writable, still no COW.
    pte = filemap.sharedPte(phys, filemap.PROT_READ);
    try std.testing.expect(pte & filemap.PTE_WRITABLE == 0);
    try std.testing.expect(pte & filemap.PTE_COW == 0);

    // Executable shared mapping keeps NX clear.
    pte = filemap.sharedPte(phys, filemap.PROT_READ | filemap.PROT_EXEC);
    try std.testing.expect(pte & filemap.PTE_NX == 0);
}

test "H1: planFault suppresses COW and requests writable shared frames" {
    const PAGE = filemap.PAGE_SIZE;
    const r = G2Region{
        .base = 0x400000,
        .num_pages = 2,
        .active = true,
        .file_kind = 2,
        .prot = filemap.PROT_READ | filemap.PROT_WRITE,
        .file_offset = 0,
        .file_size = 8192,
        .shared = true,
    };
    // Writable MAP_SHARED: no COW marker, direct writable shared frame.
    var p = filemap.planFault(G2Region, &r, 0x400000);
    try std.testing.expect(p.action == .file_page);
    try std.testing.expect(!p.cow);
    try std.testing.expect(p.shared_write);

    // Read-only MAP_SHARED: shared frame, but not writable.
    const r_ro = G2Region{ .base = 0x400000, .num_pages = 1, .active = true, .file_kind = 2, .prot = filemap.PROT_READ, .file_offset = 0, .file_size = 4096, .shared = true };
    p = filemap.planFault(G2Region, &r_ro, 0x400000);
    try std.testing.expect(!p.cow);
    try std.testing.expect(!p.shared_write);

    // EOF rule is unchanged for shared mappings.
    const r_eof = G2Region{ .base = 0x400000, .num_pages = 3, .active = true, .file_kind = 3, .prot = filemap.PROT_READ | filemap.PROT_WRITE, .file_offset = 0, .file_size = 2 * PAGE, .shared = true };
    p = filemap.planFault(G2Region, &r_eof, 0x400000 + 2 * PAGE);
    try std.testing.expect(p.action == .segv);
}

test "H1: mmap page-cache keys live in a flagged 4K namespace" {
    // The FS read paths key the page cache per FS block (e.g. 1KiB ext2
    // blocks); mmap pages must not collide with those entries.
    const key = filemap.mmapCacheKey(7);
    try std.testing.expect(key & filemap.MMAP_CACHE_FLAG != 0);
    try std.testing.expectEqual(@as(u64, 7), filemap.mmapCachePage(key));
    try std.testing.expectEqual(@as(u64, 0), filemap.mmapCachePage(filemap.mmapCacheKey(0)));
    // Stripping is idempotent for unflagged keys (flush callback contract).
    try std.testing.expectEqual(@as(u64, 42), filemap.mmapCachePage(42));
}

test "H1: planProtUpdate classifies mprotect overlap shapes" {
    const PAGE = filemap.PAGE_SIZE;
    const R = 0x800000; // region base, 4 pages

    // No overlap.
    var plan = filemap.planProtUpdate(R, 4, 0x900000, 2);
    try std.testing.expect(plan.overlap == .none);
    try std.testing.expectEqual(@as(u8, 0), plan.slots_needed);

    // Full cover: no split, one extra slot never needed.
    plan = filemap.planProtUpdate(R, 4, R, 4);
    try std.testing.expect(plan.overlap == .cover);
    try std.testing.expectEqual(@as(u64, 4), plan.mid_pages);
    try std.testing.expectEqual(@as(u8, 0), plan.slots_needed);
    plan = filemap.planProtUpdate(R, 4, R - PAGE, 6); // range larger than region
    try std.testing.expect(plan.overlap == .cover);

    // Head overlap: [R, R+2P) protected, tail keeps old prot.
    plan = filemap.planProtUpdate(R, 4, R, 2);
    try std.testing.expect(plan.overlap == .head);
    try std.testing.expectEqual(@as(u64, 2), plan.mid_pages);
    try std.testing.expectEqual(@as(u64, 2), plan.tail_pages);
    try std.testing.expectEqual(@as(u8, 1), plan.slots_needed);

    // Tail overlap: head keeps old prot, [R+2P, R+4P) protected.
    plan = filemap.planProtUpdate(R, 4, R + 2 * PAGE, 2);
    try std.testing.expect(plan.overlap == .tail);
    try std.testing.expectEqual(@as(u64, 2), plan.head_pages);
    try std.testing.expectEqual(@as(u64, 2), plan.mid_pages);
    try std.testing.expectEqual(@as(u8, 1), plan.slots_needed);

    // Middle: three pieces, two extra slots.
    plan = filemap.planProtUpdate(R, 4, R + PAGE, 2);
    try std.testing.expect(plan.overlap == .middle);
    try std.testing.expectEqual(@as(u64, 1), plan.head_pages);
    try std.testing.expectEqual(@as(u64, 2), plan.mid_pages);
    try std.testing.expectEqual(@as(u64, 1), plan.tail_pages);
    try std.testing.expectEqual(@as(u8, 2), plan.slots_needed);
}

test "H1: inSharedFileRegion matches only shared file regions" {
    const regions = [_]G2Region{
        .{ .base = 0x1000, .num_pages = 2, .active = true, .file_kind = 2, .shared = true },
        .{ .base = 0x4000, .num_pages = 2, .active = true, .file_kind = 2, .shared = false }, // private
        .{ .base = 0x8000, .num_pages = 2, .active = true, .file_kind = 0, .shared = true }, // anonymous
        .{ .base = 0xc000, .num_pages = 2, .active = false, .file_kind = 3, .shared = true }, // inactive
    };
    try std.testing.expect(filemap.inSharedFileRegion(G2Region, &regions, 0x1000));
    try std.testing.expect(filemap.inSharedFileRegion(G2Region, &regions, 0x2fff));
    try std.testing.expect(!filemap.inSharedFileRegion(G2Region, &regions, 0x3000));
    try std.testing.expect(!filemap.inSharedFileRegion(G2Region, &regions, 0x4000));
    try std.testing.expect(!filemap.inSharedFileRegion(G2Region, &regions, 0x8000));
    try std.testing.expect(!filemap.inSharedFileRegion(G2Region, &regions, 0xc000));
}

test "H1: mremap file grow extends the demand-fault window" {
    const PAGE = filemap.PAGE_SIZE;
    const g = filemap.fileGrowRange(0x400000, 2, 5);
    try std.testing.expectEqual(@as(u64, 0x400000 + 2 * PAGE), g.start);
    try std.testing.expectEqual(@as(u64, 3), g.pages);

    // A grown region keeps faulting through planFault: new pages inside the
    // recorded file size are served from the file, pages wholly past EOF
    // SIGSEGV (growth past EOF is allowed but faults on access, like Linux).
    const grown = G2Region{
        .base = 0x400000,
        .num_pages = 5, // after fileGrowRange
        .active = true,
        .file_kind = 3,
        .prot = filemap.PROT_READ,
        .file_offset = 0,
        .file_size = 3 * PAGE, // file only covers 3 pages
        .shared = true,
    };
    var p = filemap.planFault(G2Region, &grown, 0x400000 + 2 * PAGE);
    try std.testing.expect(p.action == .file_page); // newly covered, in file
    p = filemap.planFault(G2Region, &grown, 0x400000 + 3 * PAGE);
    try std.testing.expect(p.action == .segv); // growth past EOF
}
// ─── end MAP_SHARED (H1) ───

// ─── PCID (P1) ───
// Pure PCID bookkeeping: 12-bit allocator, pml4→PCID registry with
// invalidation generations, CR3 composition and the context-switch decision.
const pcid_alloc = kt.pcid_alloc;
const SwitchAction = pcid_alloc.SwitchAction;

test "P1: composeCr3 packs phys, pcid and the no-flush bit" {
    const phys: u64 = 0x0000_0000_1234_5000;
    // Legacy flush write: PCID in the low 12 bits, no bit 63.
    try std.testing.expectEqual(phys | 7, pcid_alloc.composeCr3(phys, 7, false));
    // No-flush write sets CR3 bit 63.
    try std.testing.expectEqual(phys | 7 | (@as(u64, 1) << 63), pcid_alloc.composeCr3(phys, 7, true));
    // PCID is masked to 12 bits; phys is masked to the address bits.
    try std.testing.expectEqual(phys | 0x0FFF, pcid_alloc.composeCr3(phys, 0x1FFF, false));
    try std.testing.expectEqual(@as(u64, 0x000F_FFFF_FFFF_FFFF), pcid_alloc.composeCr3(0xFFFF_FFFF_FFFF_FFFF, 0x0FFF, false));
    // Kernel PCID 0 with flush is the plain legacy value.
    try std.testing.expectEqual(phys, pcid_alloc.composeCr3(phys, 0, false));
}

test "P1: allocator hands out 1..4095, never 0, and recycles freed IDs" {
    var a: pcid_alloc.PcidAllocator = .{};
    const first = a.alloc().?;
    try std.testing.expect(first >= 1);
    const second = a.alloc().?;
    try std.testing.expect(first != second);

    a.free(first);
    // The freed ID is reusable; it must surface again within a full cycle.
    var seen_reuse = false;
    var i: u32 = 0;
    while (i < 4096) : (i += 1) {
        const p = a.alloc() orelse break;
        if (p == first) seen_reuse = true;
    }
    try std.testing.expect(seen_reuse);
}

test "P1: allocator exhausts at 4095 live IDs and frees reopen exactly one slot" {
    var a: pcid_alloc.PcidAllocator = .{};
    var count: u32 = 0;
    while (a.alloc()) |_| count += 1;
    try std.testing.expectEqual(@as(u32, 4095), count);
    try std.testing.expect(a.alloc() == null);

    a.free(1234);
    try std.testing.expectEqual(@as(?u16, 1234), a.alloc());
    try std.testing.expect(a.alloc() == null);
}

test "P1: registry maps pml4 to pcid; unregister frees the ID and bumps its generation" {
    var c: pcid_alloc.PcidCore = .{};
    const p1 = c.registerSpace(0x100000).?;
    try std.testing.expect(p1 >= 1);
    try std.testing.expectEqual(p1, c.pcidFor(0x100000).?);
    try std.testing.expect(c.pcidFor(0x200000) == null);

    const g_before = c.generation(p1);
    const freed = c.unregisterSpace(0x100000).?;
    try std.testing.expectEqual(p1, freed);
    // Reuse-invalidation: the freed PCID's generation moved on, so any CPU
    // still holding stale entries observes the change and flushes.
    try std.testing.expect(c.generation(p1) > g_before);
    try std.testing.expect(c.pcidFor(0x100000) == null);
    try std.testing.expect(c.unregisterSpace(0x100000) == null);

    // The recycled PCID is handed out again, with the bumped generation kept.
    const p2 = c.registerSpace(0x200000).?;
    try std.testing.expectEqual(p1, p2);
    try std.testing.expect(c.generation(p2) > g_before);
}

test "P1: noteShootdown bumps only the owning PCID's generation" {
    var c: pcid_alloc.PcidCore = .{};
    const p = c.registerSpace(0x400000).?;
    const q = c.registerSpace(0x500000).?;
    const g0 = c.generation(p);
    c.noteShootdown(0x400000);
    try std.testing.expectEqual(g0 + 1, c.generation(p));
    try std.testing.expectEqual(@as(u64, 0), c.generation(q));
    // Unknown space: no-op, no crash.
    c.noteShootdown(0x999000);
    try std.testing.expectEqual(g0 + 1, c.generation(p));
}

test "P1: decideSwitch — skip / no-flush / flush matrix" {
    const d = pcid_alloc.decideSwitch;
    const A: u64 = 0xAAAA000;
    const B: u64 = 0xBBBB000;
    // Same space already loaded on this CPU: no CR3 write at all.
    try std.testing.expectEqual(SwitchAction.skip, d(5, A, 0, 0, A, 5, 9));
    // Kernel/unregistered target (PCID 0): legacy flush write.
    try std.testing.expectEqual(SwitchAction.flush, d(5, A, 0, 0, 0x100000, 0, 0));
    // A→B→A with unchanged generation: no-flush fast path.
    try std.testing.expectEqual(SwitchAction.no_flush, d(7, B, 5, 9, A, 5, 9));
    // Generation moved (shootdown or PCID reuse): must flush.
    try std.testing.expectEqual(SwitchAction.flush, d(7, B, 5, 9, A, 5, 10));
    // Different space, no previous record: flush.
    try std.testing.expectEqual(SwitchAction.flush, d(7, B, 0, 0, A, 5, 9));
    // PCID matches but CR3 does not (stale record): must not skip.
    try std.testing.expect(d(5, B, 0, 0, A, 5, 9) != SwitchAction.skip);
}

test "P1: registry refuses more than MAX_SPACES live spaces" {
    var c: pcid_alloc.PcidCore = .{};
    var i: usize = 0;
    while (i < pcid_alloc.MAX_SPACES) : (i += 1) {
        try std.testing.expect(c.registerSpace(0x1000 * @as(u64, i + 1)) != null);
    }
    try std.testing.expect(c.registerSpace(0xDEAD000) == null);
}
// ─── end PCID (P1) ───

// ─── NVMe per-CPU (I3) ───
const nvme_queue = kt.nvme_queue;

test "I3: pickQueue prefers the submitting CPU's own queue" {
    const pick = nvme_queue.pickQueue;
    // Preferred channel free → cpu_id % num_queues, rr_hint irrelevant.
    try std.testing.expectEqual(@as(u32, 2), pick(2, 4, 0b1001, 9));
    try std.testing.expectEqual(@as(u32, 0), pick(0, 4, 0b1110, 3));
    // cpu_id wraps modulo the queue count.
    try std.testing.expectEqual(@as(u32, 2), pick(6, 4, 0, 0));
    try std.testing.expectEqual(@as(u32, 3), pick(7, 4, 0, 12));
}

test "I3: pickQueue falls back to round-robin when the preferred channel is busy" {
    const pick = nvme_queue.pickQueue;
    // Bit 2 set (queue 2 busy) → rr_hint % num_queues.
    try std.testing.expectEqual(@as(u32, 1), pick(2, 4, 0b0100, 9));
    // Writeback/boot submitter (cpu 0) with queue 0 busy → fallback too.
    try std.testing.expectEqual(@as(u32, 3), pick(0, 4, 0b0001, 3));
    // Every channel busy → still the round-robin answer (submitter parks
    // there instead of serializing behind its preferred queue).
    try std.testing.expectEqual(@as(u32, 2), pick(3, 4, 0b1111, 6));
    // Busy bits above num_queues are ignored.
    try std.testing.expectEqual(@as(u32, 1), pick(1, 2, 0b1000, 5));
}

test "I3: pickQueue degenerate queue counts" {
    const pick = nvme_queue.pickQueue;
    // Single queue: always 0, whatever the CPU and busy state.
    try std.testing.expectEqual(@as(u32, 0), pick(5, 1, 0b1, 7));
    try std.testing.expectEqual(@as(u32, 0), pick(5, 1, 0, 7));
    // No queues yet (pre-init): 0, no division by zero.
    try std.testing.expectEqual(@as(u32, 0), pick(5, 0, 0, 7));
}
// ─── end NVMe per-CPU (I3) ───

// ─── user huge pages (I1) ───
// Pure 2MiB huge-page helpers: eligibility and the demote decomposition
// (2MiB PDE → 512 4K PTEs mirroring phys+flags). Runtime wiring (map on
// mmap, demote-first on partial mutations) is verified by user/hello49.
const huge_user = kt.huge_user;

test "I1: eligibility requires 2MiB-aligned base and at least 512 pages" {
    try std.testing.expect(!huge_user.eligible(0x400000, 511)); // too small
    try std.testing.expect(huge_user.eligible(0x400000, 512)); // exactly one block
    try std.testing.expect(huge_user.eligible(0x400000, 1024));
    try std.testing.expect(!huge_user.eligible(0x401000, 1024)); // 4K-aligned only
    try std.testing.expect(!huge_user.eligible(0x500000, 4096)); // 1MiB-misaligned
    try std.testing.expect(huge_user.eligible(0x600000, 4096)); // 2MiB-aligned
}

test "I1: hugeBlocksFor counts only full 2MiB blocks" {
    try std.testing.expectEqual(@as(u64, 0), huge_user.hugeBlocksFor(0));
    try std.testing.expectEqual(@as(u64, 0), huge_user.hugeBlocksFor(511));
    try std.testing.expectEqual(@as(u64, 1), huge_user.hugeBlocksFor(512));
    try std.testing.expectEqual(@as(u64, 1), huge_user.hugeBlocksFor(1023));
    try std.testing.expectEqual(@as(u64, 2), huge_user.hugeBlocksFor(1024));
}

test "I1: demotePtes mirrors phys+flags over 512 PTEs, drops the huge bit" {
    const NX: u64 = 1 << 63;
    // Huge PDE: present|writable|user|huge|NX, phys 0x200000 (2MiB-aligned).
    const pde: u64 = 0x200000 | huge_user.PRESENT | huge_user.WRITABLE |
        huge_user.USER | huge_user.HUGE_BIT | NX;
    var out: [512]u64 = undefined;
    _ = huge_user.demotePtes(pde, &out, 0x100000);

    for (0..512) |i| {
        const expect_phys = 0x200000 + @as(u64, @intCast(i)) * huge_user.PAGE_SIZE;
        try std.testing.expectEqual(expect_phys, out[i] & huge_user.ADDR_MASK);
        try std.testing.expect(out[i] & huge_user.PRESENT != 0);
        try std.testing.expect(out[i] & huge_user.WRITABLE != 0);
        try std.testing.expect(out[i] & huge_user.USER != 0);
        try std.testing.expect(out[i] & NX != 0); // NX preserved
        try std.testing.expect(out[i] & huge_user.HUGE_BIT == 0); // huge bit gone
    }
}

test "I1: demotePtes replacement PDE is a PT pointer inheriting p/w/u" {
    const pde_ro: u64 = 0x400000 | huge_user.PRESENT | huge_user.USER | huge_user.HUGE_BIT;
    var out: [512]u64 = undefined;
    const new_pde = huge_user.demotePtes(pde_ro, &out, 0x300000);

    try std.testing.expectEqual(@as(u64, 0x300000), new_pde & huge_user.ADDR_MASK);
    try std.testing.expect(new_pde & huge_user.PRESENT != 0);
    try std.testing.expect(new_pde & huge_user.USER != 0);
    try std.testing.expect(new_pde & huge_user.WRITABLE == 0); // was read-only
    try std.testing.expect(new_pde & huge_user.HUGE_BIT == 0); // a table, not data

    // Read-only huge page demotes to read-only 4K PTEs.
    try std.testing.expect(out[0] & huge_user.WRITABLE == 0);
    try std.testing.expect(out[511] & huge_user.PRESENT != 0);
}
// ─── end user huge pages (I1) ───

// ─── kmsg blocking (J3) ───
// Pure availability helper behind blocking /dev/kmsg reads and the
// cursor-accurate epoll EPOLLIN: bytesAvailable(total, cursor) tells a
// reader at absolute `cursor` how many bytes a stream ending at `total`
// still has for it. Stale cursors (older than the oldest surviving byte)
// report the full absolute backlog — the read path clamps them forward,
// and for block/epoll decisions only "zero vs non-zero" matters.

test "J3: bytesAvailable is zero when caught up or ahead" {
    try std.testing.expectEqual(@as(u64, 0), kmsg_ring.bytesAvailable(0, 0)); // empty stream
    try std.testing.expectEqual(@as(u64, 0), kmsg_ring.bytesAvailable(20, 20)); // at newest byte
    try std.testing.expectEqual(@as(u64, 0), kmsg_ring.bytesAvailable(20, 25)); // cursor in the future
}

test "J3: bytesAvailable counts the unread backlog" {
    try std.testing.expectEqual(@as(u64, 15), kmsg_ring.bytesAvailable(20, 5));
    try std.testing.expectEqual(@as(u64, 20), kmsg_ring.bytesAvailable(20, 0));
    // Stale cursor (bytes already overwritten): reports the full absolute
    // backlog — read() clamps forward, availability is what epoll needs.
    try std.testing.expectEqual(@as(u64, 90), kmsg_ring.bytesAvailable(100, 10));
}

test "J3: bytesAvailable tracks a live ring's newest position" {
    var ring: kmsg_ring.KmsgRing(64) = .{};
    ring.appendLine("[INF] one\n");
    ring.appendLine("[DBG] two\n");
    const total = ring.newestPos();
    try std.testing.expectEqual(@as(u64, 20), total);
    // Fresh reader at cursor 0 sees everything; a caught-up reader sees 0.
    try std.testing.expectEqual(@as(u64, 20), kmsg_ring.bytesAvailable(total, 0));
    try std.testing.expectEqual(@as(u64, 0), kmsg_ring.bytesAvailable(total, total));
    // Mid-stream cursor: exactly the second line remains.
    try std.testing.expectEqual(@as(u64, 10), kmsg_ring.bytesAvailable(total, 10));
    // After another append the same cursor has the new line too.
    ring.appendLine("[ERR] x\n");
    try std.testing.expectEqual(@as(u64, 18), kmsg_ring.bytesAvailable(ring.newestPos(), 10));
}
// ─── end kmsg blocking (J3) ───

// ─── sched claim (J2) ───
// Atomic task-claim protocol behind the fine-grained scheduler: a CPU may run
// a task only after winning the .ready → .running cmpxchg on its state word.
// These tests pin the contention matrix: exactly-one-winner, claim against
// blocked/zombie/running states, and release refusal when the task blocked or
// exited underneath an in-flight switch.
const sched_claim = kt.sched_claim;
const ClaimState = sched_claim.TaskState;

test "J2: tryClaim wins exactly once from ready" {
    var s: ClaimState = .ready;
    try std.testing.expect(sched_claim.tryClaim(&s));
    try std.testing.expectEqual(ClaimState.running, sched_claim.load(&s));
    // A second CPU claiming the same task must lose, leaving state untouched.
    try std.testing.expect(!sched_claim.tryClaim(&s));
    try std.testing.expectEqual(ClaimState.running, sched_claim.load(&s));
}

test "J2: tryClaim refuses blocked and zombie tasks without disturbing them" {
    var s: ClaimState = .blocked;
    try std.testing.expect(!sched_claim.tryClaim(&s));
    try std.testing.expectEqual(ClaimState.blocked, sched_claim.load(&s));

    sched_claim.store(&s, .zombie);
    try std.testing.expect(!sched_claim.tryClaim(&s));
    try std.testing.expectEqual(ClaimState.zombie, sched_claim.load(&s));
}

test "J2: releaseToReady round-trips a claim" {
    var s: ClaimState = .ready;
    try std.testing.expect(sched_claim.tryClaim(&s));
    try std.testing.expect(sched_claim.releaseToReady(&s));
    try std.testing.expectEqual(ClaimState.ready, sched_claim.load(&s));
    // The task is claimable again afterwards (re-pick after preemption).
    try std.testing.expect(sched_claim.tryClaim(&s));
    try std.testing.expectEqual(ClaimState.running, sched_claim.load(&s));
}

test "J2: releaseToReady refuses a task that blocked underneath the switch" {
    var s: ClaimState = .ready;
    try std.testing.expect(sched_claim.tryClaim(&s));
    // The running task blocks itself (futex/waitpid) while the switch is in
    // flight: the release must fail and must NOT resurrect it to .ready.
    sched_claim.store(&s, .blocked);
    try std.testing.expect(!sched_claim.releaseToReady(&s));
    try std.testing.expectEqual(ClaimState.blocked, sched_claim.load(&s));
    // A blocked task stays unclaimable until a wake publishes it.
    try std.testing.expect(!sched_claim.tryClaim(&s));
    sched_claim.store(&s, .ready); // wake path: blocked → ready
    try std.testing.expect(sched_claim.tryClaim(&s));
}

test "J2: releaseToReady refuses a zombie (exited during the switch window)" {
    var s: ClaimState = .ready;
    try std.testing.expect(sched_claim.tryClaim(&s));
    sched_claim.store(&s, .zombie);
    try std.testing.expect(!sched_claim.releaseToReady(&s));
    try std.testing.expectEqual(ClaimState.zombie, sched_claim.load(&s));
    try std.testing.expect(!sched_claim.tryClaim(&s));
}

test "J2: releaseToReady refuses an unclaimed (ready) task" {
    // Releasing a task nobody owns would be a protocol bug: ready stays ready.
    var s: ClaimState = .ready;
    try std.testing.expect(!sched_claim.releaseToReady(&s));
    try std.testing.expectEqual(ClaimState.ready, sched_claim.load(&s));
}

test "J2: contended cmpxchg claims grant exclusive ownership" {
    // N hammering threads × M rounds: a won claim must imply sole ownership
    // (nobody else inside the claimed section), and every claim is released.
    const THREADS = 4;
    const ROUNDS = 5000;
    const Shared = struct {
        state: ClaimState = .ready,
        in_section: u32 = 0,
        overlap: u32 = 0,
        claimed: u32 = 0,
        released: u32 = 0,
    };
    var shared: Shared = .{};
    const Worker = struct {
        fn run(sh: *Shared) void {
            var i: u32 = 0;
            while (i < ROUNDS) : (i += 1) {
                if (!sched_claim.tryClaim(&sh.state)) continue;
                // Claim won: we must be the sole owner.
                if (@atomicRmw(u32, &sh.in_section, .Xchg, 1, .seq_cst) != 0) {
                    @atomicStore(u32, &sh.overlap, 1, .seq_cst);
                }
                _ = @atomicRmw(u32, &sh.claimed, .Add, 1, .seq_cst);
                // Leave the exclusive section BEFORE releasing: the state is
                // still .running (ours), so no new claim can sneak in.
                @atomicStore(u32, &sh.in_section, 0, .seq_cst);
                // The owner always releases successfully (nothing else can
                // move a claimed task out of .running).
                if (!sched_claim.releaseToReady(&sh.state)) {
                    @atomicStore(u32, &sh.overlap, 1, .seq_cst);
                }
                _ = @atomicRmw(u32, &sh.released, .Add, 1, .seq_cst);
            }
        }
    };
    var threads: [THREADS]std.Thread = undefined;
    for (&threads) |*th| th.* = try std.Thread.spawn(.{}, Worker.run, .{&shared});
    for (&threads) |*th| th.join();

    try std.testing.expectEqual(@as(u32, 0), shared.overlap);
    try std.testing.expectEqual(shared.claimed, shared.released);
    try std.testing.expect(shared.claimed > 0);
    // All claims released: the task ends up .ready, never stuck .running.
    try std.testing.expectEqual(ClaimState.ready, sched_claim.load(&shared.state));
}
// ─── end sched claim (J2) ───
// ─── dcache (K1) ───
const dcache = kt.dcache;

// Find a parent id whose (fs, parent, name) key lands on the same direct-mapped
// slot as `ref_parent` for the same name — deterministic conflict generator.
fn dcacheConflictingParent(fs: dcache.FsKind, name: []const u8, ref_parent: u32) u32 {
    const h = dcache.hashName(name);
    const want = dcache.slotFor(fs, ref_parent, h);
    var p: u32 = ref_parent + 1;
    while (p != ref_parent) : (p +%= 1) {
        if (dcache.slotFor(fs, p, h) == want) return p;
    }
    unreachable; // 512 slots, u32 parents — a collision always exists
}

test "K1: lookup on empty cache misses" {
    dcache.resetPure();
    try std.testing.expect(dcache.lookupPure(.ext2, 2, "hello") == null);
    try std.testing.expect(dcache.lookupPure(.fat32, 2, "hello") == null);
}

test "K1: fill then lookup hits and returns the child" {
    dcache.resetPure();
    dcache.fillPure(.ext2, 2, "foo", 1234);
    try std.testing.expectEqual(@as(?u32, 1234), dcache.lookupPure(.ext2, 2, "foo"));
    // Wrong parent / wrong fs / wrong name all miss (full key compare).
    try std.testing.expect(dcache.lookupPure(.ext2, 3, "foo") == null);
    try std.testing.expect(dcache.lookupPure(.fat32, 2, "foo") == null);
    try std.testing.expect(dcache.lookupPure(.ext2, 2, "fop") == null);
    try std.testing.expect(dcache.lookupPure(.ext2, 2, "fo") == null);
    try std.testing.expect(dcache.lookupPure(.ext2, 2, "fooo") == null);
}

test "K1: same name under different parents and filesystems stays distinct" {
    dcache.resetPure();
    dcache.fillPure(.ext2, 10, "name", 100);
    dcache.fillPure(.ext2, 20, "name", 200);
    dcache.fillPure(.fat32, 10, "name", 7);
    try std.testing.expectEqual(@as(?u32, 100), dcache.lookupPure(.ext2, 10, "name"));
    try std.testing.expectEqual(@as(?u32, 200), dcache.lookupPure(.ext2, 20, "name"));
    try std.testing.expectEqual(@as(?u32, 7), dcache.lookupPure(.fat32, 10, "name"));
}

test "K1: conflict on the same slot replaces the old entry" {
    dcache.resetPure();
    dcache.fillPure(.ext2, 1000, "conflict", 111);
    const p2 = dcacheConflictingParent(.ext2, "conflict", 1000);
    dcache.fillPure(.ext2, p2, "conflict", 222);
    // Direct-mapped replace-on-conflict: the older entry is gone.
    try std.testing.expect(dcache.lookupPure(.ext2, 1000, "conflict") == null);
    try std.testing.expectEqual(@as(?u32, 222), dcache.lookupPure(.ext2, p2, "conflict"));
}

test "K1: same-slot different-name lookup misses (full name compare)" {
    dcache.resetPure();
    dcache.fillPure(.ext2, 500, "alpha", 42);
    const p2 = dcacheConflictingParent(.ext2, "beta", 500);
    // (p2, "beta") hashes to alpha's slot but neither parent nor name match.
    try std.testing.expect(dcache.lookupPure(.ext2, p2, "beta") == null);
    // And the original entry is untouched by the failed lookup.
    try std.testing.expectEqual(@as(?u32, 42), dcache.lookupPure(.ext2, 500, "alpha"));
}

test "K1: invalidateParent drops only entries under that parent" {
    dcache.resetPure();
    dcache.fillPure(.ext2, 11, "a", 1);
    dcache.fillPure(.ext2, 11, "b", 2);
    dcache.fillPure(.ext2, 12, "a", 3);
    dcache.fillPure(.fat32, 11, "a", 4);
    const dropped = dcache.invalidateParentPure(.ext2, 11);
    try std.testing.expectEqual(@as(u32, 2), dropped);
    try std.testing.expect(dcache.lookupPure(.ext2, 11, "a") == null);
    try std.testing.expect(dcache.lookupPure(.ext2, 11, "b") == null);
    try std.testing.expectEqual(@as(?u32, 3), dcache.lookupPure(.ext2, 12, "a"));
    try std.testing.expectEqual(@as(?u32, 4), dcache.lookupPure(.fat32, 11, "a"));
}

test "K1: invalidateFs drops every entry of one filesystem only" {
    dcache.resetPure();
    dcache.fillPure(.fat32, 2, "x", 9);
    dcache.fillPure(.fat32, 7, "y", 8);
    dcache.fillPure(.ext2, 2, "x", 5);
    _ = dcache.invalidateFsPure(.fat32);
    try std.testing.expect(dcache.lookupPure(.fat32, 2, "x") == null);
    try std.testing.expect(dcache.lookupPure(.fat32, 7, "y") == null);
    try std.testing.expectEqual(@as(?u32, 5), dcache.lookupPure(.ext2, 2, "x"));
}

test "K1: capacity is bounded at 512 with replace-on-conflict" {
    dcache.resetPure();
    var i: u32 = 0;
    while (i < dcache.CAPACITY * 3) : (i += 1) {
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "f{d}", .{i}) catch unreachable;
        dcache.fillPure(.ext2, 2, name, i);
    }
    try std.testing.expect(dcache.countValidPure() <= dcache.CAPACITY);
    const st = dcache.statsPure();
    try std.testing.expectEqual(@as(u64, dcache.CAPACITY * 3), st.fills);
}

test "K1: overlong names are never cached" {
    dcache.resetPure();
    const long_name = "x" ** 300;
    dcache.fillPure(.ext2, 2, long_name, 77);
    try std.testing.expect(dcache.lookupPure(.ext2, 2, long_name) == null);
    try std.testing.expectEqual(@as(u32, 0), dcache.countValidPure());
    dcache.fillPure(.ext2, 2, "", 1);
    try std.testing.expect(dcache.lookupPure(.ext2, 2, "") == null);
}

test "K1: stats count hits and misses" {
    dcache.resetPure();
    dcache.fillPure(.ext2, 2, "stat", 55);
    _ = dcache.lookupPure(.ext2, 2, "stat"); // hit
    _ = dcache.lookupPure(.ext2, 2, "nope"); // miss
    const st = dcache.statsPure();
    try std.testing.expectEqual(@as(u64, 1), st.hits);
    try std.testing.expectEqual(@as(u64, 1), st.misses);
    try std.testing.expectEqual(@as(u64, 1), st.fills);
}
// ─── end dcache (K1) ───

// ─── slab magazine (K2) ───
// Pure per-CPU magazine bookkeeping from kernel/mm/slab_mag.zig: push/pop
// LIFO, batch refill/flush against a mock backing store, boundary behaviour,
// and the no-duplication/no-loss ownership invariant under a simulated
// kmalloc/kfree protocol. The kernel wiring (IRQ-off windows, pool locking)
// lives in kernel/mm/slab.zig; here only the lock-free core is exercised.
const slab_mag = kt.slab_mag;

const K2_NUM_OBJS = 64;

const K2MockPool = struct {
    storage: [K2_NUM_OBJS]u64 = undefined,
    free: [K2_NUM_OBJS]?*anyopaque = undefined,
    count: usize = 0,
    pops: u32 = 0,
    pushes: u32 = 0,

    fn init() K2MockPool {
        var p = K2MockPool{};
        for (0..K2_NUM_OBJS) |i| {
            p.storage[i] = i;
            p.free[i] = &p.storage[i];
        }
        p.count = K2_NUM_OBJS;
        return p;
    }

    pub fn popFree(self: *K2MockPool) ?*anyopaque {
        if (self.count == 0) return null;
        self.count -= 1;
        const obj = self.free[self.count];
        self.free[self.count] = null;
        self.pops += 1;
        return obj;
    }

    pub fn pushFree(self: *K2MockPool, obj: *anyopaque) void {
        self.free[self.count] = obj;
        self.count += 1;
        self.pushes += 1;
    }
};

/// Assert every mock object exists exactly once across pool, magazine and
/// `hands` (user-held) — the no-duplication / no-loss invariant.
fn k2ExpectConservation(pool: *K2MockPool, m: *slab_mag.Magazine, hands: []?*anyopaque) !void {
    var seen = [_]bool{false} ** K2_NUM_OBJS;
    for (pool.free[0..pool.count]) |o| {
        const idx = @as(*u64, @ptrCast(@alignCast(o.?))).*;
        try std.testing.expect(!seen[@intCast(idx)]);
        seen[@intCast(idx)] = true;
    }
    for (m.slots[0..m.count]) |o| {
        const idx = @as(*u64, @ptrCast(@alignCast(o.?))).*;
        try std.testing.expect(!seen[@intCast(idx)]);
        seen[@intCast(idx)] = true;
    }
    for (hands) |o| {
        if (o) |obj| {
            const idx = @as(*u64, @ptrCast(@alignCast(obj))).*;
            try std.testing.expect(!seen[@intCast(idx)]);
            seen[@intCast(idx)] = true;
        }
    }
    for (seen) |s| try std.testing.expect(s);
}

test "K2: magazine push/pop is LIFO and tracks count" {
    var m: slab_mag.Magazine = .{};
    try std.testing.expect(m.isEmpty());
    try std.testing.expectEqual(@as(?*anyopaque, null), m.pop());

    var a: u64 = 1;
    var b: u64 = 2;
    try std.testing.expect(m.push(&a));
    try std.testing.expect(m.push(&b));
    try std.testing.expectEqual(@as(u8, 2), m.len());
    try std.testing.expectEqual(@as(?*anyopaque, &b), m.pop());
    try std.testing.expectEqual(@as(?*anyopaque, &a), m.pop());
    try std.testing.expect(m.isEmpty());
}

test "K2: magazine boundary — full push fails, empty pop returns null" {
    var m: slab_mag.Magazine = .{};
    var objs: [slab_mag.MAG_SIZE]u64 = undefined;
    for (0..slab_mag.MAG_SIZE) |i| try std.testing.expect(m.push(&objs[i]));
    try std.testing.expect(m.isFull());
    try std.testing.expectEqual(@as(u8, slab_mag.MAG_SIZE), m.len());

    var extra: u64 = 0;
    try std.testing.expect(!m.push(&extra)); // full: refused, not overwritten
    try std.testing.expectEqual(@as(u8, slab_mag.MAG_SIZE), m.len());

    for (0..slab_mag.MAG_SIZE) |_| try std.testing.expect(m.pop() != null);
    try std.testing.expectEqual(@as(?*anyopaque, null), m.pop());
}

test "K2: refill moves a full batch from the pool" {
    var pool = K2MockPool.init();
    var m: slab_mag.Magazine = .{};
    const n = m.refill(&pool);
    try std.testing.expectEqual(@as(u8, slab_mag.REFILL_BATCH), n);
    try std.testing.expectEqual(@as(u8, slab_mag.REFILL_BATCH), m.len());
    try std.testing.expectEqual(K2_NUM_OBJS - slab_mag.REFILL_BATCH, pool.count);
    try std.testing.expectEqual(@as(u32, slab_mag.REFILL_BATCH), pool.pops);

    var hands = [_]?*anyopaque{null} ** K2_NUM_OBJS;
    try k2ExpectConservation(&pool, &m, &hands);
}

test "K2: refill is partial when the pool has fewer than a batch" {
    var pool = K2MockPool.init();
    // Drain the pool to REFILL_BATCH - 1 objects.
    for (0..K2_NUM_OBJS - (slab_mag.REFILL_BATCH - 1)) |_| _ = pool.popFree();
    var m: slab_mag.Magazine = .{};
    const n = m.refill(&pool);
    try std.testing.expectEqual(@as(u8, slab_mag.REFILL_BATCH - 1), n);
    try std.testing.expectEqual(@as(usize, 0), pool.count);
    // A second refill on an empty pool is a no-op.
    try std.testing.expectEqual(@as(u8, 0), m.refill(&pool));
    try std.testing.expectEqual(@as(u8, slab_mag.REFILL_BATCH - 1), m.len());
}

test "K2: flush moves half the magazine back to the pool" {
    var pool = K2MockPool.init();
    var m: slab_mag.Magazine = .{};
    _ = m.refill(&pool); // 4 in mag
    _ = m.refill(&pool); // 8 in mag (full)
    try std.testing.expect(m.isFull());

    const n = m.flush(&pool);
    try std.testing.expectEqual(@as(u8, slab_mag.FLUSH_BATCH), n);
    try std.testing.expectEqual(@as(u8, slab_mag.MAG_SIZE - slab_mag.FLUSH_BATCH), m.len());
    try std.testing.expectEqual(@as(u32, slab_mag.FLUSH_BATCH), pool.pushes);

    var hands = [_]?*anyopaque{null} ** K2_NUM_OBJS;
    try k2ExpectConservation(&pool, &m, &hands);
}

test "K2: flush on a non-full magazine flushes at most a batch" {
    var pool = K2MockPool.init();
    // Make room: the mock's backing array is exactly K2_NUM_OBJS deep.
    _ = pool.popFree();
    _ = pool.popFree();
    var m: slab_mag.Magazine = .{};
    var a: u64 = 0;
    var b: u64 = 0;
    _ = m.push(&a);
    _ = m.push(&b);
    const n = m.flush(&pool); // count < FLUSH_BATCH: flushes count
    try std.testing.expectEqual(@as(u8, 2), n);
    try std.testing.expect(m.isEmpty());
    try std.testing.expectEqual(@as(usize, K2_NUM_OBJS), pool.count); // 62 + 2 flushed
}

test "K2: simulated kmalloc/kfree protocol conserves objects under stress" {
    // Mirror the slab.zig fast path: alloc = pop, refill-on-empty then pop;
    // free = push, flush-half-on-full then push.
    var pool = K2MockPool.init();
    var m: slab_mag.Magazine = .{};
    var hands = [_]?*anyopaque{null} ** K2_NUM_OBJS;

    var seed: u64 = 0x12345678;
    var live: usize = 0;
    var step: u32 = 0;
    while (step < 20000) : (step += 1) {
        // xorshift PRNG for a deterministic op mix.
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        const do_alloc = (seed & 1) == 0 or live == 0;

        if (do_alloc) {
            if (live == K2_NUM_OBJS) continue;
            var obj = m.pop();
            if (obj == null) {
                _ = m.refill(&pool);
                obj = m.pop();
            }
            if (obj) |o| { // pool OOM is possible: alloc returns null
                hands[live] = o;
                live += 1;
            }
        } else {
            live -= 1;
            const o = hands[live].?;
            hands[live] = null;
            if (!m.push(o)) {
                _ = m.flush(&pool);
                try std.testing.expect(m.push(o)); // post-flush push must fit
            }
        }
        if (step % 997 == 0) try k2ExpectConservation(&pool, &m, &hands);
    }
    try k2ExpectConservation(&pool, &m, &hands);
}

test "K2: batching parameters are consistent" {
    try std.testing.expectEqual(@as(usize, 8), slab_mag.MAG_SIZE);
    try std.testing.expectEqual(@as(usize, 4), slab_mag.REFILL_BATCH);
    try std.testing.expectEqual(@as(usize, 4), slab_mag.FLUSH_BATCH);
    try std.testing.expect(slab_mag.REFILL_BATCH <= slab_mag.MAG_SIZE);
    try std.testing.expect(slab_mag.FLUSH_BATCH < slab_mag.MAG_SIZE); // post-flush push always fits
}
// ─── end slab magazine (K2) ───

// ─── user driver framework (L1) ───
const userdrv_core = kt.userdrv_core;

test "L1: dev_map_mmio request validation" {
    // Well-formed MMIO request (e1000 BAR0-shaped): aligned, 128 KiB.
    try std.testing.expectEqual(@as(i64, 0), userdrv_core.validateMmioRequest(0xFEBC0000, 0x20000));
    // Exactly the 16 MiB cap is accepted; one byte past it is not.
    try std.testing.expectEqual(@as(i64, 0), userdrv_core.validateMmioRequest(0x100000, userdrv_core.MMIO_MAX_SIZE));
    try std.testing.expectEqual(errno.EINVAL, userdrv_core.validateMmioRequest(0x100000, userdrv_core.MMIO_MAX_SIZE + 1));
    // Zero size and non-page-aligned phys are rejected.
    try std.testing.expectEqual(errno.EINVAL, userdrv_core.validateMmioRequest(0xFEBC0000, 0));
    try std.testing.expectEqual(errno.EINVAL, userdrv_core.validateMmioRequest(0xFEBC0123, 0x1000));
    // phys + size must not wrap the 64-bit address space.
    try std.testing.expectEqual(errno.EINVAL, userdrv_core.validateMmioRequest(0xFFFFFFFFFFFFF000, 0x2000));
    try std.testing.expectEqual(errno.EINVAL, userdrv_core.validateMmioRequest(0xFFFFFFFFFFFFF000, 0x1000));
}

test "L1: MMIO-vs-RAM overlap detection" {
    // Fake machine: RAM is [0, 128 MiB), everything above is fair game.
    const ram = [_]userdrv_core.PhysRange{.{ .base = 0, .len = 0x8000000 }};
    // e1000 BAR0 / IOAPIC / LAPIC windows are not RAM.
    try std.testing.expect(!userdrv_core.overlapsRamRanges(&ram, 0xFEBC0000, 0x20000));
    try std.testing.expect(!userdrv_core.overlapsRamRanges(&ram, 0xFEC00000, 0x1000));
    try std.testing.expect(!userdrv_core.overlapsRamRanges(&ram, 0xFEE00000, 0x1000));
    // Plain RAM is rejected, including a range that only straddles the top.
    try std.testing.expect(userdrv_core.overlapsRamRanges(&ram, 0x100000, 0x1000));
    try std.testing.expect(userdrv_core.overlapsRamRanges(&ram, 0x7FFF000, 0x2000));
    try std.testing.expect(userdrv_core.overlapsRamRanges(&ram, 0, 0x1000));
    // Touching-but-not-overlapping (base == RAM top) is allowed.
    try std.testing.expect(!userdrv_core.overlapsRamRanges(&ram, 0x8000000, 0x1000));
    // Disjoint ranges in the list are each consulted.
    const ram2 = [_]userdrv_core.PhysRange{
        .{ .base = 0, .len = 0x9FC00 },
        .{ .base = 0x100000, .len = 0x7F00000 },
    };
    // The EBDA hole between the two RAM pieces is not RAM.
    try std.testing.expect(!userdrv_core.overlapsRamRanges(&ram2, 0x9FC00, 0x1000));
    try std.testing.expect(userdrv_core.overlapsRamRanges(&ram2, 0x200000, 0x1000));
}

test "L1: IRQ table register/unregister/edge accounting" {
    var table: userdrv_core.IrqTable = .{};

    // PIC-only ceiling: GSI >= 16 cannot be routed without an IOAPIC.
    const PIC_MAX_GSI: u8 = 16;
    // A free GSI registers fine; the keyboard line is kernel-owned.
    const slot = try table.registerIrq(10, 7, false, PIC_MAX_GSI);
    try std.testing.expect(slot < userdrv_core.MAX_IRQ_SLOTS);
    try std.testing.expectError(error.KernelOwned, table.registerIrq(1, 7, true, PIC_MAX_GSI));
    try std.testing.expectError(error.Invalid, table.registerIrq(16, 7, false, PIC_MAX_GSI));
    // Same GSI twice (any owner) is busy.
    try std.testing.expectError(error.Busy, table.registerIrq(10, 8, false, PIC_MAX_GSI));

    // Edge counting is per-GSI and saturates instead of wrapping.
    try std.testing.expect(table.recordEdge(10));
    try std.testing.expect(table.recordEdge(10));
    try std.testing.expect(!table.recordEdge(9)); // not registered
    try std.testing.expectEqual(@as(u64, 2), table.find(10).?.edge_count);
    table.find(10).?.edge_count = std.math.maxInt(u64);
    try std.testing.expect(table.recordEdge(10));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), table.find(10).?.edge_count);

    // Only the owning task may unregister.
    try std.testing.expect(!table.unregisterIrq(10, 8));
    try std.testing.expect(table.unregisterIrq(10, 7));
    try std.testing.expect(!table.unregisterIrq(10, 7)); // already gone
    try std.testing.expect(table.find(10) == null);

    // The table holds exactly MAX_IRQ_SLOTS registrations.
    for (0..userdrv_core.MAX_IRQ_SLOTS) |i| {
        _ = try table.registerIrq(@intCast(3 + i), 7, false, PIC_MAX_GSI);
    }
    try std.testing.expectError(error.Full, table.registerIrq(15, 7, false, PIC_MAX_GSI));

    // Bulk release on task exit frees exactly that task's slots.
    try std.testing.expect(table.unregisterIrq(3, 7)); // make room
    _ = try table.registerIrq(0, 9, false, PIC_MAX_GSI); // owner 9 keeps its slot
    var released: [userdrv_core.MAX_IRQ_SLOTS]u8 = @splat(0xFF);
    const n = table.releaseAllForTask(7, &released);
    try std.testing.expectEqual(@as(u32, userdrv_core.MAX_IRQ_SLOTS - 1), n);
    try std.testing.expect(table.find(4) == null);
    try std.testing.expect(table.find(0) != null); // other owner untouched
    for (released[0..n]) |gsi| try std.testing.expect(gsi != 0xFF and gsi != 0);
}

test "M1: IRQ table routes GSI >= 16 once the IOAPIC ceiling is raised" {
    var table: userdrv_core.IrqTable = .{};
    // With an IOAPIC present the kernel passes the routable ceiling (e.g. 44
    // for the 100-127 user vector window); GSIs 16..43 then register fine and
    // the ceiling itself is still exclusive.
    const IOAPIC_MAX_GSI: u8 = 44;
    _ = try table.registerIrq(16, 7, false, IOAPIC_MAX_GSI);
    _ = try table.registerIrq(43, 7, false, IOAPIC_MAX_GSI);
    try std.testing.expectError(error.Invalid, table.registerIrq(44, 7, false, IOAPIC_MAX_GSI));
    try std.testing.expectError(error.KernelOwned, table.registerIrq(1, 7, true, IOAPIC_MAX_GSI));
    try std.testing.expect(table.recordEdge(16));
    try std.testing.expectEqual(@as(u64, 1), table.find(16).?.edge_count);
}

test "L1: dev_dma_alloc size validation" {
    try std.testing.expectEqual(@as(i64, 0), userdrv_core.validateDmaSize(4096));
    try std.testing.expectEqual(@as(i64, 0), userdrv_core.validateDmaSize(1));
    try std.testing.expectEqual(@as(i64, 0), userdrv_core.validateDmaSize(userdrv_core.DMA_MAX_SIZE));
    try std.testing.expectEqual(errno.EINVAL, userdrv_core.validateDmaSize(0));
    try std.testing.expectEqual(errno.EINVAL, userdrv_core.validateDmaSize(userdrv_core.DMA_MAX_SIZE + 1));
}

test "L1: /dev/pci listing format" {
    const devs = [_]userdrv_core.PciInfo{
        .{
            .bus = 0,
            .device = 0,
            .function = 0,
            .vendor_id = 0x8086,
            .device_id = 0x1237,
            .class_code = 0x06,
            .subclass = 0x00,
            .irq_line = 0,
            .bars = .{ 0, 0, 0, 0, 0, 0 },
            .bar_sizes = .{ 0, 0, 0, 0, 0, 0 },
        },
        .{
            .bus = 0,
            .device = 3,
            .function = 0,
            .vendor_id = 0x8086,
            .device_id = 0x100e,
            .class_code = 0x02,
            .subclass = 0x00,
            .irq_line = 11,
            .bars = .{ 0xFEBC0000, 0xC040, 0, 0, 0, 0 },
            .bar_sizes = .{ 0x20000, 0x40, 0, 0, 0, 0 },
        },
    };
    var buf: [512]u8 = undefined;
    const n = userdrv_core.genPciListing(&devs, &buf);
    try std.testing.expectEqualStrings(
        "00:00.0 8086:1237 class=06:00 irq=0\n" ++
            "00:03.0 8086:100e class=02:00 irq=11 bar0=febc0000+00020000 bar1=0000c040+00000040\n",
        buf[0..n],
    );
    // A tiny output buffer truncates cleanly (never overruns).
    var tiny: [8]u8 = undefined;
    const tn = userdrv_core.genPciListing(&devs, &tiny);
    try std.testing.expect(tn <= tiny.len);
}
// ─── end user driver framework (L1) ───

// ─── M1: IOAPIC redirection-table encode/decode (ioapic_core) ───

const ioapic_core = kt.ioapic_core;

test "M1: REDTBL encode matches the hardware bit layout" {
    // vector 0x64, dest APIC 1, masked: dest at bits 56-63, mask at bit 16.
    const raw = ioapic_core.encodeRedEntry(.{ .vector = 0x64, .dest_apic_id = 1, .masked = true });
    try std.testing.expectEqual(@as(u64, (1 << 56) | (1 << 16) | 0x64), raw);

    // Defaults are fixed-delivery, physical dest, edge, active-high: all zero.
    const unmasked = ioapic_core.encodeRedEntry(.{ .vector = 32, .dest_apic_id = 0, .masked = false });
    try std.testing.expectEqual(@as(u64, 32), unmasked);
}

test "M1: REDTBL encode/decode round-trips routing fields" {
    const raw = ioapic_core.encodeRedEntry(.{
        .vector = 117,
        .dest_apic_id = 3,
        .masked = false,
        .trigger = .level,
        .polarity = .active_low,
    });
    const d = ioapic_core.decodeRedEntry(raw);
    try std.testing.expectEqual(@as(u8, 117), d.vector);
    try std.testing.expectEqual(@as(u8, 3), d.dest_apic_id);
    try std.testing.expect(!d.masked);
    try std.testing.expectEqual(ioapic_core.Trigger.level, d.trigger);
    try std.testing.expectEqual(ioapic_core.Polarity.active_low, d.polarity);
}

test "M1: REDTBL mask toggle preserves vector and destination" {
    const routed = ioapic_core.encodeRedEntry(.{ .vector = 104, .dest_apic_id = 2, .masked = false });
    const masked = ioapic_core.setRedEntryMask(routed, true);
    try std.testing.expectEqual(@as(u8, 104), ioapic_core.redEntryVector(masked));
    const d = ioapic_core.decodeRedEntry(masked);
    try std.testing.expect(d.masked);
    try std.testing.expectEqual(@as(u8, 2), d.dest_apic_id);
    // Unmasking returns to the exact original entry.
    try std.testing.expectEqual(routed, ioapic_core.setRedEntryMask(masked, false));
}

// ─── M2: ioperm bitmap logic (ioperm_core) ───

const ioperm_core = kt.ioperm_core;

test "M2: ioperm range validation" {
    try std.testing.expectEqual(@as(i64, 0), ioperm_core.validateRange(0, 1));
    try std.testing.expectEqual(@as(i64, 0), ioperm_core.validateRange(0x70, 2));
    try std.testing.expectEqual(@as(i64, 0), ioperm_core.validateRange(0, 65536));
    try std.testing.expectEqual(@as(i64, 0), ioperm_core.validateRange(65535, 1));
    try std.testing.expectEqual(errno.EINVAL, ioperm_core.validateRange(0, 0));
    try std.testing.expectEqual(errno.EINVAL, ioperm_core.validateRange(65536, 1));
    try std.testing.expectEqual(errno.EINVAL, ioperm_core.validateRange(65535, 2));
    try std.testing.expectEqual(errno.EINVAL, ioperm_core.validateRange(0, 65537));
}

test "M2: fresh bitmap denies every port; enable/disable toggles bits" {
    var bitmap: ioperm_core.Bitmap = ioperm_core.denyAll();
    try std.testing.expect(!ioperm_core.isAllowed(&bitmap, 0));
    try std.testing.expect(!ioperm_core.isAllowed(&bitmap, 0x70));
    try std.testing.expect(!ioperm_core.isAllowed(&bitmap, 65535));

    ioperm_core.setRange(&bitmap, 0x70, 2, true);
    try std.testing.expect(ioperm_core.isAllowed(&bitmap, 0x70));
    try std.testing.expect(ioperm_core.isAllowed(&bitmap, 0x71));
    try std.testing.expect(!ioperm_core.isAllowed(&bitmap, 0x6F));
    try std.testing.expect(!ioperm_core.isAllowed(&bitmap, 0x72));

    ioperm_core.setRange(&bitmap, 0x70, 2, false);
    try std.testing.expect(!ioperm_core.isAllowed(&bitmap, 0x70));
    try std.testing.expect(!ioperm_core.isAllowed(&bitmap, 0x71));
}

test "M2: range enable crosses byte boundaries" {
    var bitmap: ioperm_core.Bitmap = ioperm_core.denyAll();
    ioperm_core.setRange(&bitmap, 6, 5, true); // ports 6..10 — spans bytes 0 and 1
    for (0..16) |p| {
        const expect_allowed = p >= 6 and p <= 10;
        try std.testing.expectEqual(expect_allowed, ioperm_core.isAllowed(&bitmap, @intCast(p)));
    }
}

test "M2: inherit copies the bitmap into independent storage" {
    var parent: ioperm_core.Bitmap = ioperm_core.denyAll();
    ioperm_core.setRange(&parent, 0x70, 2, true);

    var child: ioperm_core.Bitmap = ioperm_core.denyAll();
    ioperm_core.inherit(&child, &parent);
    try std.testing.expect(ioperm_core.isAllowed(&child, 0x70));
    try std.testing.expect(ioperm_core.isAllowed(&child, 0x71));
    try std.testing.expect(!ioperm_core.isAllowed(&child, 0x72));

    // Later parent changes must not leak into the child's copy (and back).
    ioperm_core.setRange(&parent, 0x70, 2, false);
    ioperm_core.setRange(&child, 0x3F8, 1, true);
    try std.testing.expect(ioperm_core.isAllowed(&child, 0x70));
    try std.testing.expect(!ioperm_core.isAllowed(&parent, 0x3F8));
}

// ─── devfs: /dev device-node registration table (fs/devfs.zig) ───

const devfs = kt.devfs;

test "devfs: register/lookup/enumerate round-trip" {
    devfs.resetForTest();
    try std.testing.expectEqual(@as(u32, 0), devfs.nodeCount());
    try std.testing.expect(devfs.lookup("null") == null);

    const null_idx = devfs.register("null", devfs.null_node_ops) orelse return error.TestFailed;
    const zero_idx = devfs.register("zero", devfs.zero_node_ops) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 0), null_idx);
    try std.testing.expectEqual(@as(u32, 1), zero_idx);
    try std.testing.expectEqual(@as(u32, 2), devfs.nodeCount());

    // Lookup finds both, misses unregistered names.
    try std.testing.expectEqual(null_idx, devfs.lookup("null").?);
    try std.testing.expectEqual(zero_idx, devfs.lookup("zero").?);
    try std.testing.expect(devfs.lookup("kmsg") == null);

    // Enumeration order is registration order, with stable slot indices.
    try std.testing.expectEqualStrings("null", devfs.nameAt(0).?);
    try std.testing.expectEqualStrings("zero", devfs.nameAt(1).?);
    try std.testing.expect(devfs.nameAt(2) == null);
    try std.testing.expect(devfs.opsAt(0) != null);
    try std.testing.expect(devfs.opsAt(2) == null);
}

test "devfs: registration rejects invalid, duplicate, and overflowing names" {
    devfs.resetForTest();

    // Invalid names: empty, too long, containing '/' or NUL.
    try std.testing.expect(devfs.register("", .{}) == null);
    try std.testing.expect(devfs.register("this-name-is-way-too-long-for-devfs", .{}) == null);
    try std.testing.expect(devfs.register("a/b", .{}) == null);
    try std.testing.expect(devfs.lookup("a/b") == null);
    try std.testing.expectEqual(@as(u32, 0), devfs.nodeCount());

    // A 24-byte name is exactly at the limit and works.
    const max_name = "abcdefghijklmnopqrstuvwx";
    try std.testing.expectEqual(@as(usize, devfs.MAX_NAME_LEN), max_name.len);
    try std.testing.expect(devfs.register(max_name, .{}) != null);
    try std.testing.expect(devfs.lookup(max_name) != null);

    // Duplicates are rejected; the original slot/ops stay authoritative.
    const first = devfs.register("dup", devfs.null_node_ops) orelse return error.TestFailed;
    try std.testing.expect(devfs.register("dup", devfs.zero_node_ops) == null);
    try std.testing.expectEqual(first, devfs.lookup("dup").?);

    // The table fills at MAX_NODES and then refuses new names.
    devfs.resetForTest();
    var name_buf: [8]u8 = undefined;
    for (0..devfs.MAX_NODES) |i| {
        name_buf[0] = 'n';
        name_buf[1] = @intCast('0' + (i / 10));
        name_buf[2] = @intCast('0' + (i % 10));
        try std.testing.expect(devfs.register(name_buf[0..3], .{}) != null);
    }
    try std.testing.expectEqual(devfs.MAX_NODES, devfs.nodeCount());
    try std.testing.expect(devfs.register("overflow", .{}) == null);
}

test "devfs: null/zero/full node ops semantics" {
    var ctx: devfs.IoCtx = .{};

    // /dev/null: read is instant EOF, write discards and reports count.
    const nread = devfs.null_node_ops.read.?(&ctx, @ptrCast(&ctx), 16);
    try std.testing.expectEqual(@as(i64, 0), nread);
    const payload = "discard me";
    try std.testing.expectEqual(@as(i64, payload.len), devfs.null_node_ops.write.?(&ctx, payload.ptr, payload.len));
    try std.testing.expectEqual(@as(i64, 0), devfs.null_node_ops.write.?(&ctx, payload.ptr, 0));

    // /dev/zero: read zero-fills the whole buffer; write behaves like null.
    var buf = [_]u8{0xAA} ** 64;
    try std.testing.expectEqual(@as(i64, 64), devfs.zero_node_ops.read.?(&ctx, &buf, buf.len));
    for (buf) |b| try std.testing.expectEqual(@as(u8, 0), b);

    // /dev/full: write fails with -ENOSPC (except a zero-length write),
    // read is EOF.
    try std.testing.expectEqual(@as(i64, -28), devfs.full_node_ops.write.?(&ctx, payload.ptr, payload.len));
    try std.testing.expectEqual(@as(i64, 0), devfs.full_node_ops.write.?(&ctx, payload.ptr, 0));
    try std.testing.expectEqual(@as(i64, 0), devfs.full_node_ops.read.?(&ctx, &buf, buf.len));

    // Poll masks use the EPOLLIN/EPOLLOUT bit values.
    try std.testing.expectEqual(devfs.POLL_IN | devfs.POLL_OUT, devfs.null_node_ops.poll.?(&ctx));
    try std.testing.expectEqual(@as(u32, 0x001), devfs.POLL_IN);
    try std.testing.expectEqual(@as(u32, 0x004), devfs.POLL_OUT);
}

test "devfs: IoCtx O_NONBLOCK decoding" {
    var ctx: devfs.IoCtx = .{};
    try std.testing.expect(!ctx.nonBlocking());
    ctx.status_flags = 0x800;
    try std.testing.expect(ctx.nonBlocking());
    ctx.offset = 42;
    try std.testing.expectEqual(@as(u64, 42), ctx.offset);
}
// ─── end devfs ───

// ─── MADT ISO (type 2): parse-table + flag decode (acpi/madt_iso.zig) ───

const madt_iso = kt.madt_iso;

test "madt_iso: table add/lookup, same-GSI override, capacity bound" {
    var table: madt_iso.IsoTable = .{};
    try std.testing.expect(table.lookup(1) == null);

    try std.testing.expect(table.add(.{ .bus = 0, .irq = 1, .gsi = 1, .flags = 0xD }));
    try std.testing.expect(table.add(.{ .bus = 0, .irq = 12, .gsi = 12, .flags = 0 }));
    try std.testing.expectEqual(@as(u32, 2), table.count);

    const iso1 = table.lookup(1).?;
    try std.testing.expectEqual(@as(u8, 1), iso1.irq);
    try std.testing.expectEqual(@as(u16, 0xD), iso1.flags);
    try std.testing.expect(table.lookup(2) == null);

    // Re-adding the same GSI replaces the entry instead of growing.
    try std.testing.expect(table.add(.{ .bus = 0, .irq = 1, .gsi = 1, .flags = 0x5 }));
    try std.testing.expectEqual(@as(u32, 2), table.count);
    try std.testing.expectEqual(@as(u16, 0x5), table.lookup(1).?.flags);

    // The table fills at MAX_ISO and then refuses new GSIs.
    var full: madt_iso.IsoTable = .{};
    for (0..madt_iso.MAX_ISO) |i| {
        try std.testing.expect(full.add(.{ .gsi = @intCast(i) }));
    }
    try std.testing.expect(!full.add(.{ .gsi = 999 }));
    // ... but overriding an existing GSI still succeeds.
    try std.testing.expect(full.add(.{ .gsi = 3, .flags = 0xF }));
}

test "madt_iso: flags decode to trigger/polarity with bus-conformant defaults" {
    // 0 = conforms to bus spec → the pre-ISO defaults: edge, active-high.
    try std.testing.expectEqual(madt_iso.Trigger.edge, madt_iso.triggerOf(0));
    try std.testing.expectEqual(madt_iso.Polarity.active_high, madt_iso.polarityOf(0));

    // Explicit active-high / edge encodings.
    try std.testing.expectEqual(madt_iso.Polarity.active_high, madt_iso.polarityOf(1));
    try std.testing.expectEqual(madt_iso.Trigger.edge, madt_iso.triggerOf(1 << 2));

    // Active-low (0b11) and level (0b11 << 2); the two fields are independent.
    try std.testing.expectEqual(madt_iso.Polarity.active_low, madt_iso.polarityOf(3));
    try std.testing.expectEqual(madt_iso.Trigger.level, madt_iso.triggerOf(3 << 2));
    const both: u16 = 3 | (3 << 2); // 0xF: level + active-low
    try std.testing.expectEqual(madt_iso.Trigger.level, madt_iso.triggerOf(both));
    try std.testing.expectEqual(madt_iso.Polarity.active_low, madt_iso.polarityOf(both));

    // Reserved encodings (0b10) fall back to the defaults.
    try std.testing.expectEqual(madt_iso.Polarity.active_high, madt_iso.polarityOf(2));
    try std.testing.expectEqual(madt_iso.Trigger.edge, madt_iso.triggerOf(2 << 2));
}
// ─── end MADT ISO ───

// ─── devfs proxy (P1) ───
// Userspace-owned /dev nodes (fs/devfs_proxy.zig pure core) + devfs
// tombstone/change-counter support (fs/devfs.zig). The glue (blocking
// protocol, ctrl fd, syscall 484) is exercised end-to-end by user/hello54.c.

const devfs_proxy = kt.devfs_proxy;

test "devfs: unregister tombstones a slot; lookup/getdents skip it, ops survive" {
    devfs.resetForTest();
    try std.testing.expectEqual(@as(u64, 0), devfs.changeCounter());

    const a = devfs.register("alpha", devfs.null_node_ops) orelse return error.TestFailed;
    const b = devfs.register("beta", devfs.zero_node_ops) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u64, 2), devfs.changeCounter());

    try std.testing.expect(devfs.unregister(a));
    // Tombstone: name no longer resolves, enumeration skips the slot.
    try std.testing.expect(devfs.lookup("alpha") == null);
    try std.testing.expectEqual(b, devfs.lookup("beta").?);
    try std.testing.expect(devfs.nameAt(a) == null);
    try std.testing.expectEqualStrings("beta", devfs.nameAt(b).?);
    // ...but the ops stay callable so in-flight fds get a clean -EIO from
    // the (proxy) op instead of a stale-pointer crash.
    try std.testing.expect(devfs.opsAt(a) != null);
    // Slots stay dense while tombstoned; the counter bumped on unregister.
    try std.testing.expectEqual(@as(u32, 2), devfs.nodeCount());
    try std.testing.expectEqual(@as(u64, 3), devfs.changeCounter());

    // Double unregister / out-of-range unregister are rejected.
    try std.testing.expect(!devfs.unregister(a));
    try std.testing.expect(!devfs.unregister(999));

    // The name is free again — re-registering REUSES the tombstoned slot
    // (v1.1: slots are recyclable, guarded by the per-slot generation).
    const a2 = devfs.register("alpha", devfs.null_node_ops) orelse return error.TestFailed;
    try std.testing.expectEqual(a, a2);
    try std.testing.expectEqual(a2, devfs.lookup("alpha").?);
    try std.testing.expectEqual(@as(u32, 2), devfs.nodeCount());
    try std.testing.expectEqual(@as(u64, 4), devfs.changeCounter());
}

test "devfs: change hook fires on register and unregister" {
    devfs.resetForTest();
    const S = struct {
        var bumps: u32 = 0;
        fn hook() void {
            bumps += 1;
        }
    };
    devfs.change_hook = S.hook;
    defer devfs.change_hook = null;

    const idx = devfs.register("hooked", devfs.null_node_ops) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 1), S.bumps);
    try std.testing.expectEqual(@as(u32, 1), devfs.changeCounter());
    try std.testing.expect(devfs.unregister(idx));
    try std.testing.expectEqual(@as(u32, 2), S.bumps);
    try std.testing.expectEqual(@as(u64, 2), devfs.changeCounter());
}

test "devfs proxy: enqueue validates shape and assigns monotonic seqs" {
    var core: devfs_proxy.Core = .{};
    try std.testing.expect(core.owner_alive);

    // Shape validation: bad op, write payload/len mismatch, oversize.
    try std.testing.expect(core.enqueue(3, 0, 1, "") == null);
    try std.testing.expect(core.enqueue(devfs_proxy.OP_WRITE, 0, 3, "ab") == null);
    try std.testing.expect(core.enqueue(devfs_proxy.OP_READ, 0, 1, "x") == null);
    try std.testing.expect(core.enqueue(devfs_proxy.OP_READ, 0, devfs_proxy.MAX_PAYLOAD + 1, "") == null);

    const s1 = core.enqueue(devfs_proxy.OP_READ, 0, 64, "") orelse return error.TestFailed;
    const s2 = core.enqueue(devfs_proxy.OP_WRITE, 0, 2, "ab") orelse return error.TestFailed;
    const s3 = core.enqueue(devfs_proxy.OP_READ, 4096, 64, "") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 1), s1);
    try std.testing.expectEqual(@as(u32, 2), s2);
    try std.testing.expectEqual(@as(u32, 3), s3);

    // Freeing a slot lets a new request in; seqs never recycle.
    core.cancel(s1);
    var last: u32 = s3;
    for (0..devfs_proxy.MAX_PENDING - 2) |_| {
        last = core.enqueue(devfs_proxy.OP_READ, 0, 64, "") orelse return error.TestFailed;
    }
    try std.testing.expectEqual(@as(u32, devfs_proxy.MAX_PENDING + 1), last);
    // Full: MAX_PENDING requests outstanding.
    try std.testing.expect(core.enqueue(devfs_proxy.OP_READ, 0, 64, "") == null);
}

test "devfs proxy: request wire layout is exact (seq/op/offset/len + payload)" {
    var core: devfs_proxy.Core = .{};
    const payload = "hello";
    _ = core.enqueue(devfs_proxy.OP_WRITE, 0x1122_3344_5566_7788, payload.len, payload) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, devfs_proxy.REQ_WIRE_LEN + payload.len), core.queuedWireLen().?);

    var buf: [devfs_proxy.REQ_WIRE_LEN + devfs_proxy.MAX_PAYLOAD]u8 = @splat(0);
    const n = core.takeRequest(&buf) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, devfs_proxy.REQ_WIRE_LEN + payload.len), n);
    try std.testing.expectEqual(@as(usize, 20), devfs_proxy.REQ_WIRE_LEN);
    // u32 seq LE @0, u32 op LE @4, u64 offset LE @8, u32 len LE @16, payload @20.
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, buf[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0 }, buf[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11 }, buf[8..16]);
    try std.testing.expectEqualSlices(u8, &.{ 5, 0, 0, 0 }, buf[16..20]);
    try std.testing.expectEqualStrings("hello", buf[20..25]);

    // The handed-out request is in-flight: not handed out twice.
    try std.testing.expect(core.queuedWireLen() == null);
    try std.testing.expect(core.takeRequest(&buf) == null);

    // A read request carries no payload but keeps the wanted byte count.
    _ = core.enqueue(devfs_proxy.OP_READ, 7, 64, "") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, devfs_proxy.REQ_WIRE_LEN), core.queuedWireLen().?);
    const n2 = core.takeRequest(&buf) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, devfs_proxy.REQ_WIRE_LEN), n2);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0 }, buf[0..4]); // seq 2
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, buf[4..8]); // OP_READ
    try std.testing.expectEqualSlices(u8, &.{ 7, 0, 0, 0, 0, 0, 0, 0 }, buf[8..16]);
    try std.testing.expectEqualSlices(u8, &.{ 64, 0, 0, 0 }, buf[16..20]);
}

test "devfs proxy: complete matches seq, stages read data, rejects bad responses" {
    var core: devfs_proxy.Core = .{};
    const rd = core.enqueue(devfs_proxy.OP_READ, 0, 64, "") orelse return error.TestFailed;
    const wr = core.enqueue(devfs_proxy.OP_WRITE, 0, 6, "abcdef") orelse return error.TestFailed;
    var buf: [devfs_proxy.REQ_WIRE_LEN + devfs_proxy.MAX_PAYLOAD]u8 = undefined;
    _ = core.takeRequest(&buf);
    _ = core.takeRequest(&buf);

    // Unknown seq is rejected.
    try std.testing.expect(!core.complete(999, 0, ""));
    // A queued (not handed-out) request cannot be completed either.
    const queued = core.enqueue(devfs_proxy.OP_READ, 0, 64, "") orelse return error.TestFailed;
    try std.testing.expect(!core.complete(queued, 0, ""));

    // Read response: data staged, ret = byte count.
    try std.testing.expect(core.complete(rd, 3, "xyz"));
    const done = core.pollDone(rd) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i32, 3), done.ret);
    try std.testing.expectEqualStrings("xyz", done.data);
    core.collect(rd);
    try std.testing.expect(core.pollDone(rd) == null); // slot freed

    // Write responses carry a byte count in ret and no data; ret may not
    // exceed the requested length on either op.
    try std.testing.expect(!core.complete(wr, 0, "x"));
    try std.testing.expect(!core.complete(wr, 7, "")); // wr.len == 6
    try std.testing.expect(core.complete(wr, 6, ""));
    const wdone = core.pollDone(wr) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i32, 6), wdone.ret);
    try std.testing.expectEqual(@as(usize, 0), wdone.data.len);
    core.collect(wr);

    // Error completion propagates a negative errno.
    const e = core.enqueue(devfs_proxy.OP_READ, 0, 64, "") orelse return error.TestFailed;
    _ = core.takeRequest(&buf); // `queued` (seq 3) is the oldest
    _ = core.takeRequest(&buf); // then `e` goes in-flight
    try std.testing.expect(core.complete(e, -28, ""));
    try std.testing.expectEqual(@as(i32, -28), core.pollDone(e).?.ret);
}

test "devfs proxy: cancel drops queued requests, defers inflight ones" {
    var core: devfs_proxy.Core = .{};
    var buf: [devfs_proxy.REQ_WIRE_LEN + devfs_proxy.MAX_PAYLOAD]u8 = undefined;

    const q = core.enqueue(devfs_proxy.OP_WRITE, 0, 2, "zz") orelse return error.TestFailed;
    core.cancel(q); // queued → freed immediately, owner never sees it
    try std.testing.expect(core.takeRequest(&buf) == null);

    const f = core.enqueue(devfs_proxy.OP_READ, 0, 64, "") orelse return error.TestFailed;
    _ = core.takeRequest(&buf); // inflight
    core.cancel(f); // owner already has it: late response is accepted then dropped
    try std.testing.expect(core.complete(f, 1, "k"));
    try std.testing.expect(core.pollDone(f) == null); // cancelled → freed, not done
}

test "devfs proxy: owner-death drain completes everything with -EIO" {
    var core: devfs_proxy.Core = .{};
    var buf: [devfs_proxy.REQ_WIRE_LEN + devfs_proxy.MAX_PAYLOAD]u8 = undefined;

    const inflight = core.enqueue(devfs_proxy.OP_READ, 0, 64, "") orelse return error.TestFailed;
    _ = core.takeRequest(&buf);
    const queued = core.enqueue(devfs_proxy.OP_WRITE, 0, 1, "q") orelse return error.TestFailed;

    try std.testing.expectEqual(@as(u32, 2), core.drain());
    try std.testing.expect(!core.owner_alive);
    try std.testing.expectEqual(@as(i32, -5), core.pollDone(inflight).?.ret); // -EIO
    try std.testing.expectEqual(@as(i32, -5), core.pollDone(queued).?.ret);
    core.collect(inflight);
    core.collect(queued);

    // New client ops fail fast; the owner is gone.
    try std.testing.expect(core.enqueue(devfs_proxy.OP_READ, 0, 64, "") == null);
    // Drain is idempotent.
    try std.testing.expectEqual(@as(u32, 0), core.drain());
}

test "devfs proxy: response wire parse (seq/ret/data)" {
    // read response: seq=4, ret=2, data "hi"
    const wire = [_]u8{ 4, 0, 0, 0, 2, 0, 0, 0, 'h', 'i' };
    const rsp = devfs_proxy.parseResponse(&wire) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 4), rsp.seq);
    try std.testing.expectEqual(@as(i32, 2), rsp.ret);
    try std.testing.expectEqualStrings("hi", rsp.data);

    // write response / error response: exactly 8 bytes, no data
    const wwire = [_]u8{ 9, 0, 0, 0, 0xFB, 0xFF, 0xFF, 0xFF }; // ret = -5
    const wrsp = devfs_proxy.parseResponse(&wwire) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 9), wrsp.seq);
    try std.testing.expectEqual(@as(i32, -5), wrsp.ret);
    try std.testing.expectEqual(@as(usize, 0), wrsp.data.len);

    try std.testing.expect(devfs_proxy.parseResponse(wire[0..7]) == null); // short header
    // ret>0 with fewer data bytes than ret still parses — write responses
    // carry a byte count in ret and NO data, and the parser is
    // op-agnostic; the per-op data-length rule is Core.complete's job.
    const partial = devfs_proxy.parseResponse(wire[0..9]) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i32, 2), partial.ret);
    try std.testing.expectEqual(@as(usize, 1), partial.data.len);
    const extra = [_]u8{ 4, 0, 0, 0, 0, 0, 0, 0, 'x' }; // ret<=0 must be exactly 8
    try std.testing.expect(devfs_proxy.parseResponse(&extra) == null);
    const oversize = [_]u8{ 4, 0, 0, 0, 1, 0x10, 0, 0 }; // ret = 4097 > MAX_PAYLOAD
    try std.testing.expect(devfs_proxy.parseResponse(&oversize) == null);
}

test "devfs proxy: write response survives the wire (parse+complete, hello54 deadlock regression)" {
    // Regression: parseResponse used to demand 8+ret bytes for ANY
    // ret > 0, so a legitimate write response ({seq, ret=len}, 8 bytes,
    // no data) was rejected with -EINVAL and the client never woke.
    var core: devfs_proxy.Core = .{};
    const payload = "userspace echo via devfs proxy";
    const wr = core.enqueue(devfs_proxy.OP_WRITE, 0, payload.len, payload) orelse return error.TestFailed;
    var buf: [devfs_proxy.REQ_WIRE_LEN + devfs_proxy.MAX_PAYLOAD]u8 = undefined;
    _ = core.takeRequest(&buf);

    // The owner answers exactly 8 bytes: seq, ret = bytes consumed.
    var wwire: [8]u8 = undefined;
    wwire[0] = @intCast(wr);
    wwire[1] = 0;
    wwire[2] = 0;
    wwire[3] = 0;
    wwire[4] = payload.len;
    wwire[5] = 0;
    wwire[6] = 0;
    wwire[7] = 0;
    const rsp = devfs_proxy.parseResponse(&wwire) orelse return error.TestFailed;
    try std.testing.expectEqual(wr, rsp.seq);
    try std.testing.expectEqual(@as(i32, payload.len), rsp.ret);
    try std.testing.expectEqual(@as(usize, 0), rsp.data.len);
    try std.testing.expect(core.complete(rsp.seq, rsp.ret, rsp.data));
    const done = core.pollDone(wr) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(i32, payload.len), done.ret);
    try std.testing.expectEqual(@as(usize, 0), done.data.len);

    // A read response whose data length disagrees with ret is rejected
    // at complete() (parser can't know the op).
    const rd = core.enqueue(devfs_proxy.OP_READ, 0, 64, "") orelse return error.TestFailed;
    _ = core.takeRequest(&buf);
    try std.testing.expect(!core.complete(rd, 3, "xy")); // data.len != ret
    try std.testing.expect(core.complete(rd, 3, "xyz"));
}
// ─── end devfs proxy (P1) ───

// ─── v1.1 finishing: devfs slot reuse + proxy poll + static hosts ───
// devfs tombstone-slot reuse with per-slot generations (fs/devfs.zig),
// devfs proxy readiness predicates (fs/devfs_proxy.zig Core), and the
// static host table consulted before real DNS (net/static_hosts.zig).

const static_hosts = kt.static_hosts;

test "devfs: tombstone slots are reused oldest-first; change counter stays monotonic" {
    devfs.resetForTest();

    const a = devfs.register("alpha", devfs.null_node_ops) orelse return error.TestFailed;
    const b = devfs.register("beta", devfs.zero_node_ops) orelse return error.TestFailed;
    const c = devfs.register("gamma", devfs.full_node_ops) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 0), a);
    try std.testing.expectEqual(@as(u32, 1), b);
    try std.testing.expectEqual(@as(u32, 2), c);
    try std.testing.expectEqual(@as(u64, 3), devfs.changeCounter());

    // Tombstone the middle slot: reuse prefers it over appending.
    try std.testing.expect(devfs.unregister(b));
    const d = devfs.register("delta", devfs.null_node_ops) orelse return error.TestFailed;
    try std.testing.expectEqual(b, d); // reused slot 1, not appended at 3
    try std.testing.expectEqual(@as(u32, 3), devfs.nodeCount());
    try std.testing.expectEqualStrings("delta", devfs.nameAt(d).?);
    try std.testing.expectEqual(d, devfs.lookup("delta").?);
    try std.testing.expect(devfs.lookup("beta") == null);

    // Oldest tombstone first: with slots 0 and 2 dead, slot 0 wins.
    try std.testing.expect(devfs.unregister(a));
    try std.testing.expect(devfs.unregister(c));
    const e = devfs.register("epsilon", devfs.zero_node_ops) orelse return error.TestFailed;
    try std.testing.expectEqual(a, e);
    const f = devfs.register("zeta", devfs.zero_node_ops) orelse return error.TestFailed;
    try std.testing.expectEqual(c, f);

    // No tombstones left: registration appends again.
    const g = devfs.register("eta", devfs.zero_node_ops) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 3), g);
    try std.testing.expectEqual(@as(u32, 4), devfs.nodeCount());

    // Counter never goes backwards: 3 registers + 3 unregisters + 4 more
    // registers = 10 events, each bump exactly +1.
    try std.testing.expectEqual(@as(u64, 10), devfs.changeCounter());
}

test "devfs: per-slot generation identifies a registration; stale fds are detectable" {
    devfs.resetForTest();

    const x = devfs.register("xray", devfs.null_node_ops) orelse return error.TestFailed;
    const gen_open = devfs.generationAt(x) orelse return error.TestFailed;

    // Tombstone: the generation is unchanged while the slot is dead — a
    // stale fd still matches it, but the proxy op fails on owner_alive
    // (opsAt keeps returning the ops, per the tombstone contract).
    try std.testing.expect(devfs.unregister(x));
    try std.testing.expectEqual(gen_open, devfs.generationAt(x).?);
    try std.testing.expect(devfs.opsAt(x) != null);

    // Reuse bumps the generation: an fd that cached (idx, gen_open) can no
    // longer match the new registration on the same slot.
    const y = devfs.register("yank", devfs.zero_node_ops) orelse return error.TestFailed;
    try std.testing.expectEqual(x, y);
    const gen_new = devfs.generationAt(y) orelse return error.TestFailed;
    try std.testing.expect(gen_new != gen_open);

    // Out-of-range slots report no generation.
    try std.testing.expect(devfs.generationAt(devfs.MAX_NODES) == null);
}

test "devfs proxy: poll readiness reflects owner state and queue saturation" {
    var core: devfs_proxy.Core = .{};
    var buf: [devfs_proxy.REQ_WIRE_LEN + devfs_proxy.MAX_PAYLOAD]u8 = undefined;

    // Fresh node: owner alive, queue empty → a new request is accepted
    // without blocking, so both directions report ready.
    try std.testing.expect(core.canAccept());
    try std.testing.expectEqual(devfs.POLL_IN | devfs.POLL_OUT, core.pollMask());

    // Saturate the request queue (MAX_PENDING outstanding): nothing ready.
    var seqs: [devfs_proxy.MAX_PENDING]u32 = undefined;
    for (&seqs) |*s| {
        s.* = core.enqueue(devfs_proxy.OP_READ, 0, 64, "") orelse return error.TestFailed;
    }
    try std.testing.expect(!core.canAccept());
    try std.testing.expectEqual(@as(u32, 0), core.pollMask());

    // Handing requests to the owner does NOT free slots (inflight still
    // occupies one) — readiness only returns when a slot actually frees.
    _ = core.takeRequest(&buf);
    try std.testing.expect(!core.canAccept());
    try std.testing.expectEqual(@as(u32, 0), core.pollMask());

    // A cancelled queued request frees its slot → acceptable again.
    core.cancel(seqs[devfs_proxy.MAX_PENDING - 1]);
    try std.testing.expect(core.canAccept());
    try std.testing.expectEqual(devfs.POLL_IN | devfs.POLL_OUT, core.pollMask());

    // Owner death: ops fail fast with -EIO, so the node must ALWAYS report
    // ready (a not-ready report would sleep pollers forever on a dead node).
    _ = core.drain();
    try std.testing.expect(!core.owner_alive);
    try std.testing.expect(!core.canAccept());
    try std.testing.expectEqual(devfs.POLL_IN | devfs.POLL_OUT, core.pollMask());
}

test "static hosts: built-in table resolves localhost/gateway before any DNS query" {
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, static_hosts.lookup("localhost").?);
    try std.testing.expectEqual([4]u8{ 10, 0, 2, 2 }, static_hosts.lookup("gateway").?);

    // DNS names are case-insensitive.
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, static_hosts.lookup("LOCALHOST").?);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, static_hosts.lookup("LocalHost").?);

    // Unknown names miss (the caller falls through to the real resolver).
    try std.testing.expect(static_hosts.lookup("example.com") == null);
    try std.testing.expect(static_hosts.lookup("") == null);
    try std.testing.expect(static_hosts.lookup("localhost.localdomain") == null);
    try std.testing.expect(static_hosts.lookup("localhos") == null);
}
// ─── end v1.1 finishing ───

// ─── fbcon core: cell grid / cursor / scroll (drivers/fbcon_core.zig) ───

const fbcon_core = kt.fbcon_core;
const fbcon_font = kt.fbcon_font;

test "fbcon core: init clamps geometry and blanks the grid" {
    const core = fbcon_core.Core.init(1000, 1000);
    try std.testing.expectEqual(fbcon_core.MAX_COLS, core.cols);
    try std.testing.expectEqual(fbcon_core.MAX_ROWS, core.rows);
    try std.testing.expectEqual(@as(u16, 0), core.cx);
    try std.testing.expectEqual(@as(u16, 0), core.cy);
    try std.testing.expectEqual(@as(u8, ' '), core.cellAt(0, 0));
    try std.testing.expectEqual(@as(u8, ' '), core.cellAt(core.cols - 1, core.rows - 1));
}

test "fbcon core: printable chars advance and wrap to the next line" {
    var core = fbcon_core.Core.init(4, 3);
    try std.testing.expectEqual(fbcon_core.Effect{ .cell = .{ .x = 0, .y = 0, .ch = 'a' } }, core.putChar('a'));
    try std.testing.expectEqual(@as(u16, 1), core.cx);
    _ = core.putChar('b');
    _ = core.putChar('c');
    // Last column: the cell is drawn, the cursor wraps to the next row.
    try std.testing.expectEqual(fbcon_core.Effect{ .cell = .{ .x = 3, .y = 0, .ch = 'd' } }, core.putChar('d'));
    try std.testing.expectEqual(@as(u16, 0), core.cx);
    try std.testing.expectEqual(@as(u16, 1), core.cy);
    try std.testing.expectEqual(@as(u8, 'a'), core.cellAt(0, 0));
    try std.testing.expectEqual(@as(u8, 'd'), core.cellAt(3, 0));
}

test "fbcon core: newline is CR+LF, backspace retreats, tab aligns to 8" {
    var core = fbcon_core.Core.init(16, 4);
    _ = core.putChar('x');
    _ = core.putChar('\n');
    try std.testing.expectEqual(@as(u16, 0), core.cx);
    try std.testing.expectEqual(@as(u16, 1), core.cy);
    _ = core.putChar('y');
    _ = core.putChar('\r');
    try std.testing.expectEqual(@as(u16, 0), core.cx);
    try std.testing.expectEqual(@as(u16, 1), core.cy);
    _ = core.putChar(0x08);
    try std.testing.expectEqual(@as(u16, 0), core.cx); // clamped at column 0
    _ = core.putChar('z');
    _ = core.putChar('\t');
    try std.testing.expectEqual(@as(u16, 8), core.cx);
    // Control bytes without console meaning are ignored.
    try std.testing.expectEqual(fbcon_core.Effect.none, core.putChar(0x07));
    try std.testing.expectEqual(@as(u16, 8), core.cx);
}

test "fbcon core: full screen scrolls, keeps upper lines, clears the bottom" {
    var core = fbcon_core.Core.init(2, 2);
    _ = core.putChar('a');
    _ = core.putChar('b'); // wraps to row 1
    _ = core.putChar('c');
    // 'd' fills the last cell of the last row: drawn, then the grid scrolls.
    try std.testing.expectEqual(fbcon_core.Effect.scroll, core.putChar('d'));
    // After the scroll: old row 1 ("cd") is now row 0, row 1 is blank.
    try std.testing.expectEqual(@as(u8, 'c'), core.cellAt(0, 0));
    try std.testing.expectEqual(@as(u8, 'd'), core.cellAt(1, 0));
    try std.testing.expectEqual(@as(u8, ' '), core.cellAt(0, 1));
    try std.testing.expectEqual(@as(u8, ' '), core.cellAt(1, 1));
    try std.testing.expectEqual(@as(u16, 0), core.cx);
    try std.testing.expectEqual(@as(u16, 1), core.cy);

    // A character in the very last cell also reports the scroll (the drawn
    // cell scrolled up with the grid).
    _ = core.putChar('e');
    try std.testing.expectEqual(fbcon_core.Effect.scroll, core.putChar('f'));
    try std.testing.expectEqual(@as(u8, 'e'), core.cellAt(0, 0));
    try std.testing.expectEqual(@as(u8, 'f'), core.cellAt(1, 0));
}

test "fbcon font: printable ASCII glyphs are present and shaped" {
    // Space is blank, '!' has ink, glyphs are 8x16.
    for (fbcon_font.data[0]) |row| try std.testing.expectEqual(@as(u8, 0), row);
    var ink: u32 = 0;
    for (fbcon_font.data['!' - 32]) |row| ink += @popCount(row);
    try std.testing.expect(ink > 10);
    try std.testing.expectEqual(@as(usize, 96), fbcon_font.data.len);
    try std.testing.expectEqual(@as(usize, 16), fbcon_font.data[0].len);
}
// ─── end fbcon core ───

// ─── PS/2 mouse packet assembly (drivers/mouse.zig pure decls) ───

const mouse = kt.mouse;

test "mouse packet assembler: frames 3-byte packets and resyncs" {
    var asm_: mouse.PacketAssembler = .{};
    try std.testing.expect(asm_.feed(0x08) == null); // bit3 set: packet start
    try std.testing.expect(asm_.feed(0x05) == null);
    const p = asm_.feed(0x07).?;
    try std.testing.expectEqual([3]u8{ 0x08, 0x05, 0x07 }, p);

    // A byte with bit 3 clear is not a valid packet start: dropped.
    try std.testing.expect(asm_.feed(0x00) == null);
    try std.testing.expectEqual(@as(u8, 0), asm_.count);
    // Middle bytes may legitimately carry bit 3, so assembly is purely
    // positional: three bytes after a start complete a packet.
    _ = asm_.feed(0x09);
    _ = asm_.feed(0x11);
    const p2 = asm_.feed(0x0B).?;
    try std.testing.expectEqual([3]u8{ 0x09, 0x11, 0x0B }, p2);
    try std.testing.expectEqual(@as(u8, 0), asm_.count);
}

test "mouse decodePacket: buttons, sign extension, Y inversion, clamping" {
    // Right button, dx=+5, wire dy=+5 (down) → reported dy=-5.
    const e1 = mouse.decodePacket(.{ 0x0A, 5, 5 });
    try std.testing.expectEqual(@as(u8, 2), e1.buttons);
    try std.testing.expectEqual(@as(i8, 5), e1.dx);
    try std.testing.expectEqual(@as(i8, -5), e1.dy);

    // Negative deltas via the sign bits (bit4=X sign, bit5=Y sign):
    // wire dx=0xFE (-2), wire dy=0xFE (-2 = up 2) → reported dy=+2.
    const e2 = mouse.decodePacket(.{ 0x39, 0xFE, 0xFE });
    try std.testing.expectEqual(@as(u8, 1), e2.buttons);
    try std.testing.expectEqual(@as(i8, -2), e2.dx);
    try std.testing.expectEqual(@as(i8, 2), e2.dy);

    // Large wire deltas clamp into the i8 event range instead of wrapping.
    const e3 = mouse.decodePacket(.{ 0x08, 0xFF, 0xFF });
    try std.testing.expectEqual(@as(i8, 127), e3.dx);
    try std.testing.expectEqual(@as(i8, -128), e3.dy);
}
// ─── end PS/2 mouse ───

// ─── RTC wall-clock conversion (drivers/rtc.zig pure decls) ───

const rtc = kt.rtc;

test "rtc: BCD decode and century rule" {
    try std.testing.expectEqual(@as(u8, 0), rtc.bcdToBin(0x00));
    try std.testing.expectEqual(@as(u8, 59), rtc.bcdToBin(0x59));
    try std.testing.expectEqual(@as(u8, 99), rtc.bcdToBin(0x99));
    // Century pivot: 00-69 → 2000s, 70-99 → 1900s.
    try std.testing.expectEqual(@as(u16, 2000), rtc.expandYear(0));
    try std.testing.expectEqual(@as(u16, 2026), rtc.expandYear(26));
    try std.testing.expectEqual(@as(u16, 2069), rtc.expandYear(69));
    try std.testing.expectEqual(@as(u16, 1970), rtc.expandYear(70));
    try std.testing.expectEqual(@as(u16, 1999), rtc.expandYear(99));
}

test "rtc: Gregorian date to Unix epoch seconds" {
    // The epoch itself.
    try std.testing.expectEqual(@as(u64, 0), rtc.dateTimeToEpoch(1970, 1, 1, 0, 0, 0));
    // Known anchors (verifiable against any Unix date tool).
    try std.testing.expectEqual(@as(u64, 946684800), rtc.dateTimeToEpoch(2000, 1, 1, 0, 0, 0));
    try std.testing.expectEqual(@as(u64, 1704067200), rtc.dateTimeToEpoch(2024, 1, 1, 0, 0, 0));
    try std.testing.expectEqual(@as(u64, 951782400), rtc.dateTimeToEpoch(2000, 2, 29, 0, 0, 0)); // leap day
    try std.testing.expectEqual(@as(u64, 1754438400), rtc.dateTimeToEpoch(2025, 8, 6, 0, 0, 0));
    // Time-of-day folds in.
    try std.testing.expectEqual(@as(u64, 3661), rtc.dateTimeToEpoch(1970, 1, 1, 1, 1, 1));
    // Leap-year math across the century boundary (2000 was a leap year).
    try std.testing.expect(rtc.isLeapYear(2000));
    try std.testing.expect(!rtc.isLeapYear(1900));
    try std.testing.expect(rtc.isLeapYear(2024));
    try std.testing.expect(!rtc.isLeapYear(2026));
}

test "rtc: calendar validation rejects impossible days" {
    try std.testing.expect(rtc.validDate(2024, 2, 29));
    try std.testing.expect(!rtc.validDate(2023, 2, 29));
    try std.testing.expect(!rtc.validDate(2024, 4, 31));
    try std.testing.expect(rtc.validDate(2024, 10, 20));
    try std.testing.expect(rtc.validClockTime(23, 59, 59, true));
    try std.testing.expect(!rtc.validClockTime(24, 0, 0, true));
    try std.testing.expect(rtc.validClockTime(12, 0, 0, false));
    try std.testing.expect(rtc.validClockTime(1, 0, 0, false));
    try std.testing.expect(!rtc.validClockTime(0, 0, 0, false));
    try std.testing.expect(!rtc.validClockTime(13, 0, 0, false));
    try std.testing.expect(!rtc.validClockTime(12, 60, 0, false));
    try std.testing.expectEqual(@as(?u8, 13), rtc.normalizeRtcHour(1, true, false));
    try std.testing.expectEqual(@as(?u8, 0), rtc.normalizeRtcHour(12, false, false));
    try std.testing.expectEqual(@as(?u8, null), rtc.normalizeRtcHour(0, false, false));
    try std.testing.expectEqual(@as(?u8, null), rtc.normalizeRtcHour(13, false, false));
    try std.testing.expectEqual(@as(?u8, null), rtc.normalizeRtcHour(0x80, false, true));
    try std.testing.expectEqual(@as(?u8, 0), rtc.normalizeRtcHour(12, false, false));
    try std.testing.expectEqual(@as(?u8, 12), rtc.normalizeRtcHour(12, true, false));
    try std.testing.expectEqual(@as(?u8, 23), rtc.normalizeRtcHour(11, true, false));
    try std.testing.expectEqual(@as(?u8, null), rtc.normalizeRtcHour(0x92, false, true));
    try std.testing.expectEqual(@as(?u8, 23), rtc.normalizeRtcHour(23, false, true));
    try std.testing.expectEqual(@as(?u8, 13), rtc.decodeRtcHour(0x81, false, false));
    try std.testing.expectEqual(@as(?u8, 0), rtc.decodeRtcHour(0x12, false, false));
    try std.testing.expectEqual(@as(?u8, null), rtc.decodeRtcHour(0x92, false, true));
}
// ─── end RTC ───
