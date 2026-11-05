const std = @import("std");

const kt = @import("kernel_shared");
const fat32_util = kt.fat32_util;

const byte_order = kt.byte_order;
const aio_policy = kt.aio_policy;
const readahead_policy = kt.readahead_policy;
const sync_file_range_policy = kt.sync_file_range_policy;
const openat2_policy = kt.openat2_policy;
const futex_key = kt.futex_key;
const mlock_policy = kt.mlock_policy;
const mprotect_policy = kt.mprotect_policy;
const mmap_policy = kt.mmap_policy;
const shared_mapping_policy = kt.shared_mapping_policy;
const munmap_policy = kt.munmap_policy;
const process_vm_policy = kt.process_vm_policy;
const mm = kt.mm;
const vm_lock_policy = kt.vm_lock_policy;
const lifecycle_policy = kt.lifecycle_policy;
const clone_flags_policy = kt.clone_flags_policy;
const pidfd_policy = kt.pidfd_policy;
const pidfd_signal_policy = kt.pidfd_signal_policy;
const task_slot_lifetime = kt.task_slot_lifetime;
const nvme_flush_policy = kt.nvme_flush_policy;
const ipc_lifecycle_policy = kt.ipc_lifecycle_policy;
const ipc_endpoint_policy = kt.ipc_endpoint_policy;
const capability_policy = kt.capability_policy;
const capability_generation_policy = kt.capability_generation_policy;
const capability_lifecycle_policy = kt.capability_lifecycle_policy;
const ipc_timeout_policy = kt.ipc_timeout_policy;
const task_lifetime_policy = kt.task_lifetime_policy;
const time_policy = kt.time_policy;
const time_pointer_policy = kt.time_pointer_policy;
const socket_policy = kt.socket_policy;
const socket_address_policy = kt.socket_address_policy;
const ipc_call_reply_policy = kt.ipc_call_reply_policy;
const task_op_policy = kt.task_op_policy;
const clone3_policy = kt.clone3_policy;
const posix_timer_policy = kt.posix_timer_policy;
const posix_mq_policy = kt.posix_mq_policy;
const posix_mq_wait_policy = kt.posix_mq_wait_policy;
const posix_mq_attr_policy = kt.posix_mq_attr_policy;
const posix_mq_receive_policy = kt.posix_mq_receive_policy;
const posix_mq_priority_policy = kt.posix_mq_priority_policy;
const posix_mq_ownership_policy = kt.posix_mq_ownership_policy;
const posix_mq_descriptor_policy = kt.posix_mq_descriptor_policy;
const sysv_shm_policy = kt.sysv_shm_policy;
const sysv_shm_lifecycle_policy = kt.sysv_shm_lifecycle_policy;
const time_set_policy = kt.time_set_policy;
const time_syscall = kt.time_syscall;
const sigreturn_policy = kt.sigreturn_policy;
const sched_queue_policy = kt.sched_queue_policy;

test "runqueue tokens distinguish a reused task slot" {
    const old = sched_queue_policy.Entry{ .task = 3, .incarnation = 9 };
    try std.testing.expect(sched_queue_policy.tokenMatches(old, 9));
    try std.testing.expect(!sched_queue_policy.tokenMatches(old, 10));
}

test "runqueue duplicate policy distinguishes task incarnation identity" {
    const entry = sched_queue_policy.Entry{ .task = 7, .incarnation = 4 };
    try std.testing.expect(sched_queue_policy.sameEntry(entry, .{ .task = 7, .incarnation = 4 }));
    try std.testing.expect(!sched_queue_policy.sameEntry(entry, .{ .task = 8, .incarnation = 4 }));
    try std.testing.expect(!sched_queue_policy.sameEntry(entry, .{ .task = 7, .incarnation = 5 }));
}

test {
    _ = @import("rt_hardening_test.zig");
    _ = @import("rt_round2_test.zig");
    _ = @import("tcp_recv_test.zig");
    _ = @import("ext2_unlink_test.zig");
    _ = @import("stat_fields_test.zig");
    _ = @import("sysv_msg_test.zig");
    _ = @import("unix_epoll_test.zig");
    _ = @import("tcp_port_test.zig");
    _ = @import("ipc_reply_test.zig");
    _ = @import("net_misc_test.zig");
    _ = @import("signal_proc_test.zig");
    _ = @import("signal_delivery_test.zig");
    _ = @import("sigaltstack_test.zig");
    _ = @import("segment_copy_test.zig");
    _ = @import("ext4_test.zig");
    _ = @import("mount_path_test.zig");
    _ = @import("rofs_access_test.zig");
    _ = @import("gpt_test.zig");
    _ = @import("dir_cursor_cache_test.zig");
    _ = @import("sleep_lock_test.zig");
    _ = @import("rofs_map_test.zig");
    _ = @import("nvme_mailbox_test.zig");
    _ = @import("ntfs_test.zig");
    _ = @import("wait_status_test.zig");
}

test "sync syscall propagates aggregate writeback failure as EIO" {
    const source = kt.syscall_entry_source;
    const start = std.mem.indexOf(u8, source, "246 => { // sync()").?;
    const end = std.mem.indexOfPos(u8, source, start, "247 =>").?;
    const body = source[start..end];
    try std.testing.expect(
        std.mem.indexOf(u8, body, "const all_ok = vfs_mod.syncAll();") != null and
            std.mem.indexOf(u8, body, "if (all_ok and flushRootDiskCache()) 0 else @bitCast(@as(i64, -5))") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, body, "frame.rax = 0") == null);
}

test "fsync rejects non-file descriptors" {
    const source = kt.syscall_entry_source;
    const start = std.mem.indexOf(u8, source, "fn syscallFsync").?;
    const end = std.mem.indexOfPos(u8, source, start, "fn syscallClockNanosleep").?;
    const body = source[start..end];
    // EBADF for unused descriptors precedes the type dispatch; non-file
    // descriptor types are rejected with EINVAL inside the same switch.
    try std.testing.expect(std.mem.indexOf(u8, body, "if (desc.fd_type == .none) return -9").? <
        std.mem.indexOf(u8, body, "else => return -22").?);
    try std.testing.expect(std.mem.indexOf(u8, body, "return -22, // EINVAL") != null);
}

test "page cache pins mmap frames before releasing cache lock" {
    const cache = kt.page_cache_source;
    const start = std.mem.indexOf(u8, cache, "pub fn getPageFramePinned").?;
    const end = std.mem.indexOfPos(u8, cache, start, "pub fn copyPageAndRecord").?;
    const body = cache[start..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "pmm.addRef(phys)") != null);
    const idt = kt.idt_source;
    try std.testing.expect(std.mem.indexOf(u8, idt, "getPageFramePinned(region.inode_id, key)") != null);
}

test "non-x86 paging facades preserve mapping query and unmap contracts" {
    const aarch = kt.aarch64_arch_impl_source;
    const riscv = kt.riscv64_arch_impl_source;
    try std.testing.expect(std.mem.indexOf(u8, aarch, "a64pag.isUserMapped") != null);
    try std.testing.expect(std.mem.indexOf(u8, aarch, "a64pag.unmapPage") != null);
    try std.testing.expect(std.mem.indexOf(u8, riscv, "sv39.unmapPage") != null);
    try std.testing.expect(std.mem.indexOf(u8, aarch, "return false;\n    }\n\n    pub fn mapHugePage") == null);
    try std.testing.expect(std.mem.indexOf(u8, aarch, "a64pag.isUserWritable") != null);
    try std.testing.expect(std.mem.indexOf(u8, aarch, "a64pag.isMapped") != null);
    try std.testing.expect(std.mem.indexOf(u8, riscv, "sv39.isUserWritable") != null);
    try std.testing.expect(std.mem.indexOf(u8, aarch, "error.UnsupportedHugePage") != null);
    try std.testing.expect(std.mem.indexOf(u8, riscv, "error.UnsupportedHugePage") != null);
}

test "AArch64 writable pages require EL0 access and RW AP bits" {
    const source = kt.aarch64_paging_source;
    const start = std.mem.indexOf(u8, source, "pub fn isUserWritable").?;
    const end = std.mem.indexOfPos(u8, source, start, "fn mapBlock2MIdentity").?;
    const body = source[start..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "ap_el0") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "leaf & ap_el0") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "leaf & ap_rw") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "if ((l2d & DESC_VALID) == 0) return false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "if ((l3d & DESC_VALID) == 0) return false") != null);
}

test "AArch64 timer has one hardware timer service owner" {
    const gic = kt.aarch64_gic_source;
    const trap = kt.aarch64_trap_source;
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, gic, ".onInterrupt("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, trap, ".onInterrupt("));
}

test "RISC-V mapPage fences newly installed translations" {
    const source = kt.riscv64_sv39_source;
    const start = std.mem.indexOf(u8, source, "pub fn mapPage").?;
    const end = std.mem.indexOfPos(u8, source, start, "pub fn unmapPage").?;
    try std.testing.expect(std.mem.indexOf(u8, source[start..end], "sfence.vma") != null);
}

test "epoll lifecycle policy separates transient borrows from slot recycle" {
    var slot: kt.epoll_lifecycle_policy.Slot = .{ .state = .open, .generation = 8 };
    try std.testing.expect(kt.epoll_lifecycle_policy.acquire(&slot, 8));
    try std.testing.expect(!kt.epoll_lifecycle_policy.acquire(&slot, 7));
    try std.testing.expect(kt.epoll_lifecycle_policy.beginClose(&slot, 8));
    try std.testing.expect(!kt.epoll_lifecycle_policy.recycle(&slot));
    try std.testing.expect(kt.epoll_lifecycle_policy.release(&slot));
    try std.testing.expect(kt.epoll_lifecycle_policy.recycle(&slot));
}

test "epoll immediate-ready control uses locked ready helper" {
    const source = kt.epoll_source;
    const add = std.mem.indexOf(u8, source, "EPOLL_CTL_ADD").?;
    const mod = std.mem.indexOf(u8, source, "EPOLL_CTL_MOD").?;
    const end = std.mem.indexOfPos(u8, source, mod, "EPOLL_CTL_DEL").?;
    try std.testing.expect(std.mem.indexOfPos(u8, source, add, "addToReadyListLocked") != null);
    try std.testing.expect(std.mem.indexOfPos(u8, source, mod, "addToReadyListLocked") != null);
    try std.testing.expect(std.mem.indexOfPos(u8, source, end, "addToReadyList(inst,") == null);
}

test "epoll operational callers use borrowed instances instead of raw lookup" {
    const source = kt.epoll_source;
    try std.testing.expect(std.mem.count(u8, source, "getInstance(") == 0);
    try std.testing.expect(std.mem.count(u8, source, "acquireInstance(") >= 4);
}

test "nested epoll probes do not hold the parent instance lock" {
    const source = kt.epoll_source;
    const collect = std.mem.indexOf(u8, source, "fn collectEvents").?;
    const release = std.mem.indexOfPos(u8, source, collect, "inst.spin.release(saved);").?;
    const probe = std.mem.indexOfPos(u8, source, collect, "computeCurrentEvents").?;
    try std.testing.expect(release < probe);
}

test "epoll registrations validate fd slot incarnations" {
    const vfs = kt.vfs_source;
    const epoll = kt.epoll_source;
    try std.testing.expect(std.mem.indexOf(u8, vfs, "fd_generations: [MAX_FDS]u64") != null);
    try std.testing.expect(std.mem.indexOf(u8, vfs, "fd_generations[fd] +%= 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, vfs, "snapshotFdIdentity") != null);
    try std.testing.expect(std.mem.indexOf(u8, epoll, "fd_generation: u64") != null);
    try std.testing.expect(std.mem.indexOf(u8, epoll, "acquireTransferFd") != null);
    try std.testing.expect(std.mem.indexOf(u8, epoll, "snapshotFdIdentity") != null);
    try std.testing.expect(std.mem.indexOf(u8, epoll, "registration_generation: u64") != null);
    try std.testing.expect(std.mem.indexOf(u8, epoll, "item.registration_generation == snapshot.registration_generation") != null);
}

test "epoll ctl rechecks readiness after registration" {
    const source = kt.epoll_source;
    const ctl = std.mem.indexOf(u8, source, "pub fn epollCtl").?;
    const recheck = std.mem.indexOfPos(u8, source, ctl, "needs_readiness_recheck").?;
    const notify = std.mem.indexOfPos(u8, source, recheck, "epollNotify(desc.fd_type").?;
    try std.testing.expect(recheck < notify);
}

test "epoll delete removes the exact ready-list slot" {
    const source = kt.epoll_source;
    try std.testing.expect(std.mem.indexOf(u8, source, "removeFromReadyListSlot(inst, i)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "fn removeFromReadyListSlot") != null);
}

test "nested epoll readiness propagates without reacquiring the pool lock" {
    const source = kt.epoll_source;
    try std.testing.expect(std.mem.indexOf(u8, source, "propagateNestedReadyLocked") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "visited: u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pending |= @as(u32, 1) << @intCast(parent)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "target_epoll_generation != epoll_pool[child].generation") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "item.events & EPOLLIN == 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "if (item.is_et)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "acquireInstance(snapshot.resource_idx) orelse") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "target_epoll_generation") != null);
}

test "epoll rejects dead nested targets and removes stale target errors" {
    const source = kt.epoll_source;
    const ctl = std.mem.indexOf(u8, source, "pub fn epollCtl").?;
    const target = std.mem.indexOfPos(u8, source, ctl, "acquireInstance(resourceIdxFromDesc(desc)) orelse return EBADF");
    try std.testing.expect(target != null);
    const collect = std.mem.indexOf(u8, source, "fn collectEvents").?;
    try std.testing.expect(std.mem.indexOfPos(u8, source, collect, "acquireInstance(snapshot.resource_idx) orelse") != null);
}

test "epoll notification wakes only on a newly ready instance" {
    const source = kt.epoll_source;
    try std.testing.expect(std.mem.indexOf(u8, source, "if (instance_became_ready) wakeWaiterLocked(inst)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "resetNestedEdgeState") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "item.last_reported = 0") != null);
}

test "epoll ctl pins the fd before taking its identity snapshot" {
    const source = kt.epoll_source;
    const ctl = std.mem.indexOf(u8, source, "pub fn epollCtl").?;
    const pin = std.mem.indexOfPos(u8, source, ctl, "acquireTransferFd").?;
    const snapshot = std.mem.indexOfPos(u8, source, ctl, "snapshotFdIdentity").?;
    try std.testing.expect(pin < snapshot);
}

test "epoll preserves ready registrations beyond max_events" {
    const source = kt.epoll_source;
    try std.testing.expect(std.mem.indexOf(u8, source, "const delivered = count < max_out") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "!snapshot.is_et or !delivered") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "final_events != 0") != null);
}

test "epoll wake state and nested readiness use synchronized loads" {
    const source = kt.epoll_source;
    try std.testing.expect(std.mem.indexOf(u8, source, "@atomicLoad(bool, &node.granted, .acquire)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const saved = inst.spin.acquire();") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "@atomicLoad(bool, &inst.valid, .acquire)") != null);
}

test "epoll MOD advances registration incarnation; adding an epoll fd to itself is EINVAL, a longer loop ELOOP" {
    const source = kt.epoll_source;
    try std.testing.expect(std.mem.indexOf(u8, source, "item.registration_generation +%= 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "if (nestedChainReaches(target.instance, epfd_idx)) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "if (resourceIdxFromDesc(desc) == epfd_idx) return ELOOP") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".same_file = same_file,") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const child_empty = child_inst.ready_head == null") != null);
}

test "fd close invalidates exact epoll registrations" {
    const epoll = kt.epoll_source;
    const vfs = kt.vfs_source;
    try std.testing.expect(std.mem.indexOf(u8, epoll, "invalidateFdRegistrations") != null);
    try std.testing.expect(std.mem.indexOf(u8, epoll, "item.fd_table == fd_table") != null);
    try std.testing.expect(std.mem.indexOf(u8, vfs, "invalidateFdRegistrations(self, fd, fd_generation)") != null);
}

test "initial user stack keeps auxv adjacent to envp and 16-aligned" {
    const hhdm = kt.hhdm;
    const user_stack = kt.user_stack;

    const fake_phys: u64 = 0x30_0000;
    const stack_top: u64 = 0x40_0000;
    const page = try std.heap.page_allocator.alloc(u8, 4096);
    defer std.heap.page_allocator.free(page);
    @memset(page, 0xAA);
    // Identity map the fake physical page at the real allocation.
    hhdm.init(@intFromPtr(page.ptr) -% fake_phys);

    // (argc + nenv) even was the case that pushed the SP-alignment pad
    // between the envp terminator and the first auxv entry, ending crt0's
    // auxv walk at its first word. Both parities must expose a nonzero
    // a_type at envp + 1 and a parseable AT_PHDR/AT_PHNUM/AT_ENTRY chain.
    const cases = [_]struct { argv: []const []const u8, envp: []const []const u8 }{
        .{ .argv = &.{ "prog" }, .envp = &.{} },
        .{ .argv = &.{ "prog", "arg1" }, .envp = &.{} },
        .{ .argv = &.{ "prog", "a", "b" }, .envp = &.{"K=V"} },
        .{ .argv = &.{"prog"}, .envp = &.{ "A=1", "B=2" } },
    };
    for (cases) |case| {
        const sp = user_stack.buildUserStack(fake_phys, stack_top, case.argv, case.envp, .{
            .phdr_addr = 0x1000,
            .phnum = 5,
            .entry = 0x2000,
        });
        const page_virt = stack_top - 4096;
        try std.testing.expectEqual(@as(u64, 0), sp % 16);
        try std.testing.expect(sp >= page_virt and sp < stack_top);
        const words = @as([*]const u64, @ptrFromInt(@intFromPtr(page.ptr) + (sp - page_virt)));

        const argc = words[0];
        try std.testing.expectEqual(@as(u64, case.argv.len), argc);
        // argv pointers resolve to the staged strings; argv and envp are
        // contiguous with their NULL terminators between them.
        const arg0 = words[1];
        const arg0_str: [*:0]const u8 = @ptrFromInt(@intFromPtr(page.ptr) + (arg0 - page_virt));
        try std.testing.expectEqualStrings(case.argv[0], std.mem.span(arg0_str));
        var i: u64 = 1 + argc;
        try std.testing.expectEqual(@as(u64, 0), words[i]); // argv terminator
        i += 1;
        i += @intCast(case.envp.len); // envp pointers
        try std.testing.expectEqual(@as(u64, 0), words[i]); // envp terminator

        // crt0 starts its auxv walk at envp + 1; the first word must be an
        // a_type, never the alignment pad's zero.
        var a: [*]const u64 = words + i + 1;
        try std.testing.expect(a[0] != 0);
        var phdr: u64 = 0;
        var phnum: u64 = 0;
        var entry: u64 = 0;
        while (a[0] != 0) : (a += 2) {
            switch (a[0]) {
                user_stack.AT_PHDR => phdr = a[1],
                user_stack.AT_PHNUM => phnum = a[1],
                user_stack.AT_ENTRY => entry = a[1],
                else => {},
            }
        }
        try std.testing.expectEqual(@as(u64, 0x1000), phdr);
        try std.testing.expectEqual(@as(u64, 5), phnum);
        try std.testing.expectEqual(@as(u64, 0x2000), entry);
    }
}

test "initial user stack: the largest argv and envp fit or are refused, never overlap the pointer area" {
    const hhdm = kt.hhdm;
    const user_stack = kt.user_stack;
    const fake_phys: u64 = 0x32_0000;
    const stack_top: u64 = 0x42_0000;
    const page = try std.heap.page_allocator.alloc(u8, 4096);
    defer std.heap.page_allocator.free(page);
    hhdm.init(@intFromPtr(page.ptr) -% fake_phys);

    // 16 arguments and 16 environment strings of the longest length execve accepts (127 bytes plus the NUL) need 4096 bytes of
    // strings alone; the page also has to hold argc, 34 pointers and the auxv. Whatever buildUserStack does with that, a
    // returned stack pointer must lead to argv[i] strings that read back unchanged.
    var storage: [32][127]u8 = undefined;
    var argv: [16][]const u8 = undefined;
    var envp: [16][]const u8 = undefined;
    for (0..16) |i| {
        @memset(&storage[i], @as(u8, 'a') + @as(u8, @intCast(i)));
        argv[i] = storage[i][0..];
        @memset(&storage[16 + i], @as(u8, 'A') + @as(u8, @intCast(i)));
        envp[i] = storage[16 + i][0..];
    }
    @memset(page, 0);
    const sp = user_stack.buildUserStack(fake_phys, stack_top, argv[0..], envp[0..], .{ .phdr_addr = 0x1000, .phnum = 5, .entry = 0x2000 });
    if (sp == 0) return; // refusing is acceptable
    const page_virt = stack_top - 4096;
    try std.testing.expect(sp >= page_virt and sp < stack_top);
    const words = @as([*]const u64, @ptrFromInt(@intFromPtr(page.ptr) + (sp - page_virt)));
    try std.testing.expectEqual(@as(u64, 16), words[0]);
    for (0..16) |i| {
        const p = words[1 + i];
        try std.testing.expect(p >= page_virt and p + 128 <= stack_top);
        const text: [*]const u8 = @ptrFromInt(@intFromPtr(page.ptr) + (p - page_virt));
        try std.testing.expectEqualSlices(u8, argv[i], text[0..127]);
        try std.testing.expectEqual(@as(u8, 0), text[127]);
    }
    for (0..16) |i| {
        const p = words[1 + 16 + 1 + i];
        const text: [*]const u8 = @ptrFromInt(@intFromPtr(page.ptr) + (p - page_virt));
        try std.testing.expectEqualSlices(u8, envp[i], text[0..127]);
    }
}

test "user stack omits AT_PHDR for flat binaries" {
    const hhdm = kt.hhdm;
    const user_stack = kt.user_stack;
    const fake_phys: u64 = 0x31_0000;
    const stack_top: u64 = 0x41_0000;
    const page = try std.heap.page_allocator.alloc(u8, 4096);
    defer std.heap.page_allocator.free(page);
    @memset(page, 0);
    hhdm.init(@intFromPtr(page.ptr) -% fake_phys);

    const sp = user_stack.buildUserStack(fake_phys, stack_top, &.{"flat"}, &.{}, .{
        .entry = 0x100_000,
    });
    const page_virt = stack_top - 4096;
    const words = @as([*]const u64, @ptrFromInt(@intFromPtr(page.ptr) + (sp - page_virt)));
    var a: [*]const u64 = words;
    // Skip argc/argv/envp: walk from the first word with a nonzero a_type
    // after the envp terminator. With one argv and no envp that is word 4.
    try std.testing.expectEqual(@as(u64, 1), words[0]);
    try std.testing.expectEqual(@as(u64, 0), words[2]); // argv terminator
    try std.testing.expectEqual(@as(u64, 0), words[3]); // envp terminator
    a = words + 4;
    var saw_phdr = false;
    while (a[0] != 0) : (a += 2) {
        if (a[0] == user_stack.AT_PHDR) saw_phdr = true;
    }
    try std.testing.expect(!saw_phdr);
}


test "fat32 open-file lifetime defers unlink reclamation" {
    const fat32 = kt.fat32_source;
    const vfs = kt.vfs_source;
    try std.testing.expect(std.mem.indexOf(u8, fat32, "ref_count: u32 = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, fat32, "unlink_pending: bool = false") != null);
    try std.testing.expect(std.mem.indexOf(u8, fat32, "pub fn retainFile") != null);
    try std.testing.expect(std.mem.indexOf(u8, fat32, "pub fn closeFile") != null);
    try std.testing.expect(std.mem.indexOf(u8, fat32, "deleteFileInternal(file_idx, true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, fat32, "!writeback.invalidateFile(wb_inode, .fat32, writebackFlush)") != null);
    try std.testing.expect(std.mem.indexOf(u8, fat32, "files[file_idx].unlink_pending = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, fat32, "fat_cache_sector = 0xFFFFFFFF") != null);
    try std.testing.expect(std.mem.indexOf(u8, fat32, "flushInode(wb_inode, mmapPageFlush)") != null);
    try std.testing.expect(std.mem.indexOf(u8, fat32, "files[file_idx].ref_count != 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, fat32, "const next_cluster = getFATEntry(cluster) orelse") != null);
    try std.testing.expect(std.mem.indexOf(u8, fat32, "pub fn openFileRetained") != null);
    try std.testing.expect(std.mem.indexOf(u8, fat32, "if (!found_entry)") != null);
    try std.testing.expect(std.mem.indexOf(u8, fat32, "if (!fi.active or (!allow_pending and fi.unlink_pending) or fi.is_dir)") != null);
    try std.testing.expect(std.mem.indexOf(u8, fat32, "files[file_idx].ref_count != 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, vfs, "fat32.openFileRetained(name)") != null);
    try std.testing.expect(std.mem.indexOf(u8, vfs, "retainFile(source.fat32_file_idx)") != null);
    try std.testing.expect(std.mem.indexOf(u8, vfs, "@import(\"fat32.zig\").closeFile") != null);
    try std.testing.expect(std.mem.indexOf(u8, vfs, ".fat32_file => @import(\"fat32.zig\").retainFile") != null);
}

test "fat32 utility rejects malformed geometry and UTF-8" {
    var b = [_]u8{0} ** 512;
    try std.testing.expect(fat32_util.parsePartition(&b, 4) == null);
    b[11] = 0;
    b[12] = 2;
    b[13] = 1;
    b[14] = 1;
    b[16] = 1;
    b[32] = 1;
    b[36] = 1;
    try std.testing.expect(fat32_util.parseBpb(&b, 0) == null);
    var utf16: [8]u16 = undefined;
    try std.testing.expect(fat32_util.utf8ToUtf16(&[_]u8{ 0xED, 0xA0, 0x80 }, &utf16) == null);
    try std.testing.expect(fat32_util.clusterToLba(100, 8, 0) == 0);
    var fat_sector = [_]u8{0} ** 512;
    try std.testing.expect(fat32_util.fatEntryValue(&fat_sector, 509) == null);
    try std.testing.expect(fat32_util.fatEntryLocation(0xFFFF_FFF0, 512, 0x4000_0000).sector == 0);
    var lfn_slots: [20][32]u8 = undefined;
    var short_name = [_]u8{ 'T', 'E', 'S', 'T', ' ', ' ', ' ', ' ', 'T', 'X', 'T' };
    try std.testing.expect(fat32_util.buildLfnEntries("a\x00b", &short_name, lfn_slots[0..]) == null);
}

test "fat32 root directory growth rolls back an unlinked cluster" {
    const source = kt.fat32_source;
    try std.testing.expect(std.mem.indexOf(u8, source, "if (!setFATEntry(last, nc))") != null);
    const rollback_at = std.mem.indexOfPos(u8, source, std.mem.indexOf(u8, source, "if (!setFATEntry(last, nc))").?, "setFATEntry(nc, 0)");
    try std.testing.expect(rollback_at != null);
}

test "fat32 truncate preserves old metadata on failed directory update" {
    const fat32 = kt.fat32_source;
    try std.testing.expect(std.mem.indexOf(u8, fat32, "const old_size = files[file_idx].size") != null);
    try std.testing.expect(std.mem.indexOf(u8, fat32, "if (!tail_ok)") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.vfs_source, "!fat32.truncateFile(idx, 0)") != null);
}

test "virtio net queue rejects sizes beyond fixed ring storage" {
    const source = kt.virtio_net_source;
    try std.testing.expect(std.mem.indexOf(u8, source, "layout.sizeSupported(qsize, QUEUE_SIZE)") != null);
    const policy = kt.virtio_net_queue_source;
    try std.testing.expect(std.mem.indexOf(u8, policy, "size == 0 or size > MAX_QUEUE_SIZE") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "pub fn init(state: *QueueState, size: u16) bool") != null);
}

test "virtio queue layout matches the legacy ring offsets for every size the device may offer" {
    const l = kt.virtio_queue_layout;
    // N=128 (the old size): descriptors 2048 B, avail ends at 2310, used page-aligned at 4096.
    try std.testing.expectEqual(@as(usize, 2048), l.availOffset(128));
    try std.testing.expectEqual(@as(usize, 4096), l.usedOffset(128));
    try std.testing.expectEqual(@as(usize, 2), l.totalPages(128));
    // N=256 (QEMU's default): avail 4096, used 8192, three pages.
    try std.testing.expectEqual(@as(usize, 4096), l.availOffset(256));
    try std.testing.expectEqual(@as(usize, 8192), l.usedOffset(256));
    try std.testing.expectEqual(@as(usize, 3), l.totalPages(256));
    // N=1024 (QEMU's maximum).
    try std.testing.expectEqual(@as(usize, 16384), l.availOffset(1024));
    try std.testing.expectEqual(@as(usize, 20480), l.usedOffset(1024));
    try std.testing.expectEqual(@as(usize, 8), l.totalPages(1024));
    // The used ring always starts on a page boundary and the block always holds the whole used ring.
    var n: usize = 1;
    while (n <= 1024) : (n *= 2) {
        try std.testing.expectEqual(@as(usize, 0), l.usedOffset(n) % 4096);
        try std.testing.expect(l.usedOffset(n) >= l.availOffset(n) + l.availBytes(n));
        try std.testing.expect(l.totalBytes(n) >= l.usedOffset(n) + l.usedBytes(n));
    }
}

test "virtio queue sizes: only powers of two up to the driver maximum are accepted" {
    const l = kt.virtio_queue_layout;
    try std.testing.expect(!l.sizeSupported(0, 256));
    try std.testing.expect(!l.sizeSupported(3, 256));
    try std.testing.expect(!l.sizeSupported(100, 256));
    try std.testing.expect(!l.sizeSupported(512, 256));
    try std.testing.expect(l.sizeSupported(1, 256));
    try std.testing.expect(l.sizeSupported(128, 256));
    try std.testing.expect(l.sizeSupported(256, 256));
}

test "virtio-net uses one contiguous ring block, half as many RX buffers as descriptors, and a pollable RX path" {
    const src = kt.virtio_net_source;
    try std.testing.expect(std.mem.indexOf(u8, src, "pmm.allocContiguous(pages)") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "VQ_AVAIL_OFF") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "@min(vq.num, QUEUE_SIZE) / 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn receivePacket(") != null);
    const nic = kt.nic_source;
    try std.testing.expect(std.mem.indexOf(u8, nic, "drivers.virtio_net.receivePacket(buf, max_len)") != null);
}

test "gettimeofday validates and fills the timezone pointer like Linux" {
    const src = kt.time_syscall_source;
    const start = std.mem.indexOf(u8, src, "pub fn gettimeofday(tv_ptr: u64, tz_ptr: u64) i64") orelse return error.TestUnexpectedResult;
    const end = std.mem.indexOfPos(u8, src, start, "pub fn clock_gettime(") orelse return error.TestUnexpectedResult;
    const body = src[start..end];
    // Both pointers are range-checked before anything is written, so a bad tz cannot leave tv half-delivered.
    try std.testing.expect(std.mem.indexOf(u8, body, "tv_ptr >= user_top or tz_ptr >= user_top") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "if (tz_ptr != 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "copyToUser(@ptrFromInt(tz_ptr)") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.syscall_entry_source, "time_mod.gettimeofday(frame.rdi, frame.rsi)") != null);
}

test "non-x86 identity init failure is an explicit fatal no-retry contract" {
    const aarch = kt.aarch64_paging_source;
    try std.testing.expect(std.mem.indexOf(u8, aarch, "Failure contract: fatal, no retry") != null);
    try std.testing.expect(std.mem.indexOf(u8, aarch, "intentionally NOT freed") != null);
    const riscv = kt.riscv64_sv39_source;
    try std.testing.expect(std.mem.indexOf(u8, riscv, "Failure contract: fatal, no retry") != null);
    try std.testing.expect(std.mem.indexOf(u8, riscv, "intentionally NOT freed") != null);
    const aarch_start = kt.aarch64_start_source;
    try std.testing.expect(std.mem.indexOf(u8, aarch_start, "M9-3 FAILED: MMU enable") != null);
    const riscv_start = kt.riscv64_start_source;
    try std.testing.expect(std.mem.indexOf(u8, riscv_start, "M3 FAILED: Sv39 enable") != null);
}

test "page cache insertions recheck duplicate keys under the cache lock" {
    const source = kt.page_cache_source;
    const plain = std.mem.indexOf(u8, source, "pub fn insertPage(").?;
    const owned = std.mem.indexOf(u8, source, "pub fn insertPageOwned").?;
    const plain_body = source[plain..owned];
    const owned_body = source[owned..std.mem.indexOfPos(u8, source, owned, "pub fn flushInode").?];
    try std.testing.expect(std.mem.indexOf(u8, plain_body, "var existing = hash_buckets[bucket]") != null);
    try std.testing.expect(std.mem.indexOf(u8, owned_body, "var existing = hash_buckets[bucket]") != null);
    try std.testing.expect(std.mem.indexOf(u8, owned_body, "return null") != null);
}

test "owned page insertion distinguishes existing frame from full cache" {
    const source = kt.page_cache_source;
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const OwnedInsertResult") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "existing: u64") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn insertPageOwnedOrGet") != null);
    const idt = kt.idt_source;
    try std.testing.expect(std.mem.indexOf(u8, idt, "insertPageOwnedOrGet(region.inode_id, key, scratch, 4096)") != null);
}

test "full page-cache flushes expose writeback failure" {
    const cache = kt.page_cache_source;
    try std.testing.expect(std.mem.indexOf(u8, cache, "pub fn flushInode(inode_id: u64, writeback_fn: *const fn") != null);
    try std.testing.expect(std.mem.indexOf(u8, cache, ") FlushResult") != null);
    const vfs = kt.vfs_source;
    try std.testing.expect(std.mem.indexOf(u8, vfs, "return ext2_ok and fat32_ok and !mmap_result.failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, vfs, "return ordinary_ok and !mmap_result.failed") != null);
}

test "mapped inode flush reports page-cache failure to recovery callers" {
    const source = kt.vfs_source;
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn flushMappedInode(inode_id: u64) bool") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "return !page_cache.flushInode(inode_id, mappedPageWriteback).failed") != null);
    const idt = kt.idt_source;
    try std.testing.expect(std.mem.indexOf(u8, idt, "if (!vfs.flushMappedInode(region.inode_id))") != null);
}

test "vmsplice validates flags and loops over large iovecs" {
    const source = kt.syscall_entry_source;
    const start = std.mem.indexOf(u8, source, "fn syscallVmsplice").?;
    const end = std.mem.indexOfPos(u8, source, start, "// ── v36.0: helpers").?;
    const body = source[start..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "validateSpliceFlags(flags)") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "while (done < len)") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "if (written <= 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "if (written < copied)") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "fd_type != .pipe_write") != null);
}

test "pipe2 validates and propagates nonblocking flags" {
    const source = kt.syscall_entry_source;
    const start = std.mem.indexOf(u8, source, "fn syscallPipe2").?;
    const end = std.mem.indexOfPos(u8, source, start, "fn syscallMincore").?;
    const body = source[start..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "flags & ~(O_CLOEXEC | O_NONBLOCK) != 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "fds[read_fd].status_flags |= O_NONBLOCK") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "fds[write_fd].status_flags |= O_NONBLOCK") != null);
}

test "FIONBIO updates status flags without changing descriptor flags" {
    const source = kt.ioctl_source;
    const start = std.mem.indexOf(u8, source, "FIONBIO =>").?;
    const end = std.mem.indexOfPos(u8, source, start, "else => return -25").?;
    const body = source[start..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "status_flags |= 0x800") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "status_flags &= ~@as(u32, 0x800)") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "fd_flags |= 0x800") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "fd_flags &= ~@as(u32, 0x800)") == null);
}

test "pipe write propagates status flags for full-pipe EAGAIN" {
    const source = kt.vfs_source;
    try std.testing.expect(std.mem.indexOf(u8, source, "pipeWrite(desc.pipe_idx, buf, count, desc.status_flags)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const nonblocking = (status_flags & @as(u32, 0x800)) != 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "if (n == count or nonblocking) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "return if (n == 0) -11 else @intCast(n);") != null);
}

test "every restartable syscall number delivers signals on its way out" {
    // SA_RESTART is arranged where the signal frame is written (deliverSignalOnSyscallReturn), which only runs for a call whose
    // dispatch branch calls checkSignalsOnSyscallReturn. A number in the restart table whose branch lacks that call would be
    // restartable on paper and never restarted (and its handler would only run at the next call or timer tick).
    const source = kt.syscall_entry_source;
    const restart = kt.syscall_restart_policy;
    var nr: u64 = 0;
    while (nr < 600) : (nr += 1) {
        if (!restart.restartable(nr)) continue;
        var needle_buf: [32]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buf, "\n        {d} => ", .{nr});
        var from: usize = 0;
        var found_branch = false;
        while (std.mem.indexOfPos(u8, source, from, needle)) |at| {
            from = at + needle.len;
            // The branch ends at the first line that closes it ("\n        },").
            const end = std.mem.indexOfPos(u8, source, at, "\n        },") orelse source.len;
            const body = source[at..end];
            // Only the dispatch branches (they assign frame.rax or call a syscall helper); lseek's `0 => new_off` style arms
            // inside other switches are not branches of the dispatcher.
            if (std.mem.indexOf(u8, body, "frame") == null) continue;
            found_branch = true;
            if (std.mem.indexOf(u8, body, "checkSignalsOnSyscallReturn(frame)") == null) {
                std.debug.print("restartable syscall {d}: branch has no checkSignalsOnSyscallReturn:\n{s}\n", .{ nr, body });
                return error.RestartableBranchWithoutSignalDelivery;
            }
        }
        try std.testing.expect(found_branch);
    }
}

test "a pipe write that fits an empty pipe is written whole or not at all" {
    const source = kt.vfs_source;
    try std.testing.expect(std.mem.indexOf(u8, source, "const atomic = count <= PIPE_BUF_SIZE - 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "if (!atomic or room >= count) {") != null);
}

test "a blocking pipe write waits on the writers' queue and readers wake it" {
    const source = kt.vfs_source;
    try std.testing.expect(std.mem.indexOf(u8, source, "sched.blockOn(&pipe_write_waiters[pipe_idx]") != null);
    // every path that makes room or removes the last reader wakes the writers
    try std.testing.expect(std.mem.count(u8, source, "wakeAll(&pipe_write_waiters[") >= 4);
}

test "splice propagates nonblocking flags to transfer helpers" {
    const source = kt.splice_source;
    try std.testing.expect(std.mem.indexOf(u8, source, "splicePipeToPipe(fd_table, fd_in, fd_out, len, flags)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "splicePipeToFile(fd_table, fd_in, fd_out, off_out, len, flags)") != null);
    try std.testing.expect(std.mem.count(u8, source, "(flags & SPLICE_F_NONBLOCK != 0) or (fd_table.fds[pipe_fd].status_flags & 0x800 != 0)") >= 2);
}

test "splice pipe-to-file nonblocking result distinguishes live pipe from EOF" {
    try std.testing.expectEqual(kt.errno.EAGAIN, splice.splicePipeToFileReadResult(splice.SPLICE_F_NONBLOCK, 0, 0, true));
    try std.testing.expectEqual(@as(i64, 0), splice.splicePipeToFileReadResult(splice.SPLICE_F_NONBLOCK, 0, 0, false));
    try std.testing.expectEqual(@as(i64, 37), splice.splicePipeToFileReadResult(splice.SPLICE_F_NONBLOCK, 37, 0, true));
    try std.testing.expectEqual(@as(i64, -5), splice.splicePipeToFileReadResult(splice.SPLICE_F_NONBLOCK, 0, -5, true));
    try std.testing.expectEqual(@as(i64, 0), splice.splicePipeToFileReadResult(0, 0, 0, true));
}

test "pipe-to-pipe splice honors descriptor nonblocking status" {
    const source = kt.splice_source;
    try std.testing.expect(std.mem.count(u8, source, "(flags & SPLICE_F_NONBLOCK != 0) or (fd_table.fds[pipe_fd].status_flags & 0x800 != 0)") >= 2);
    try std.testing.expectEqual(@as(i64, -11), splice.pipeTransferResult(0, 0));
    try std.testing.expectEqual(@as(i64, 17), splice.pipeTransferResult(0, 17));
}

test "blocking splice reservations use the pipe read wait path" {
    const source = kt.vfs_source;
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn pipeReserveReadWait") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "sched.blockOn(&pipe_read_waiters[pipe_idx]") != null);
    const splice_source = kt.splice_source;
    try std.testing.expect(std.mem.count(u8, splice_source, "pipeReserveReadWait(") >= 2);
}

test "sleep timer wiring preserves legacy scheduler wakeups and zero deadlines" {
    const source = kt.sched_source;
    const legacy = std.mem.indexOf(u8, source, "fn timerTickLegacy").?;
    const legacy_end = std.mem.indexOfPos(u8, source, legacy, "fn timerTickFg").?;
    const legacy_body = source[legacy..legacy_end];
    try std.testing.expect(std.mem.indexOf(u8, legacy_body, "sleepTimerTick(") != null);
    const sleep_start = std.mem.indexOf(u8, source, "pub fn sleepTimerTick").?;
    const sleep_end = std.mem.indexOfPos(u8, source, sleep_start, "// M8-2").?;
    const sleep_body = source[sleep_start..sleep_end];
    try std.testing.expect(std.mem.indexOf(u8, sleep_body, "deadline != 0 and now_ns >= deadline") != null);
}

test "mmap rejects unsupported flags; unknown protection bits are ignored as on Linux" {
    try std.testing.expect(
        mmap_policy.flagsValid(mmap_policy.MAP_PRIVATE | mmap_policy.MAP_ANONYMOUS),
    );
    try std.testing.expect(
        !mmap_policy.flagsValid(mmap_policy.MAP_PRIVATE | mmap_policy.MAP_SHARED),
    );
    try std.testing.expect(!mmap_policy.flagsValid(mmap_policy.MAP_PRIVATE | (1 << 63)));
    try std.testing.expect(mmap_policy.flagsValid(mmap_policy.MAP_PRIVATE | 0x2000)); // MAP_LOCKED is acted on (mm/mlock.zig)
    try std.testing.expect(mmap_policy.flagsValid(mmap_policy.MAP_PRIVATE | 0x8000)); // MAP_POPULATE is only a hint
    try std.testing.expectEqual(@as(u64, 0), mmap_policy.normalizeProt(0));
    try std.testing.expectEqual(@as(u64, 0), mmap_policy.normalizeProt(0x8));
    try std.testing.expect(mmap_policy.anonymousFlagsValid(mmap_policy.MAP_PRIVATE | mmap_policy.MAP_ANONYMOUS));
    try std.testing.expect(mmap_policy.anonymousFlagsValid(mmap_policy.MAP_SHARED | mmap_policy.MAP_ANONYMOUS));
    try std.testing.expect(!mmap_policy.isAnonymous(mmap_policy.MAP_PRIVATE));
    try std.testing.expect(mmap_policy.isAnonymous(mmap_policy.MAP_PRIVATE | mmap_policy.MAP_ANONYMOUS));
}

test "clone rejects ignored TID flags and incoherent thread combinations" {
    try std.testing.expect(clone_flags_policy.valid(clone_flags_policy.CLONE_VM, true));
    try std.testing.expect(!clone_flags_policy.valid(clone_flags_policy.CLONE_THREAD, true));
    try std.testing.expect(!clone_flags_policy.valid(clone_flags_policy.CLONE_SIGHAND, true));
    try std.testing.expect(!clone_flags_policy.valid(clone_flags_policy.CLONE_FS, true));
    try std.testing.expect(clone_flags_policy.valid(clone_flags_policy.CLONE_VM | clone_flags_policy.CLONE_PARENT_SETTID, true));
}

test "clone accepts pthread-style CLONE_THREAD only inside a shared address space" {
    const p = clone_flags_policy;
    // moqi_libc pthread_create.
    try std.testing.expect(p.valid(p.CLONE_VM | p.CLONE_FILES | p.CLONE_THREAD | p.CLONE_SETTLS, true));
    try std.testing.expect(p.valid(p.CLONE_VM | p.CLONE_FILES | p.CLONE_THREAD, true));
    try std.testing.expect(p.valid(p.CLONE_VM | p.CLONE_THREAD | p.CLONE_CHILD_CLEARTID, true));
    // A thread group member without the group's address space is incoherent.
    try std.testing.expect(!p.valid(p.CLONE_THREAD, true));
    try std.testing.expect(!p.valid(p.CLONE_FILES | p.CLONE_THREAD, true));
    try std.testing.expect(!p.valid(p.CLONE_VM | p.CLONE_THREAD, false));
    // Shared signal-handler and fs_struct objects are still unimplemented.
    try std.testing.expect(!p.valid(p.CLONE_VM | p.CLONE_THREAD | p.CLONE_SIGHAND, true));
    try std.testing.expect(!p.valid(p.CLONE_VM | p.CLONE_FS | p.CLONE_FILES | p.CLONE_THREAD, true));
}

test "pidfd_open accepts only zero flags" {
    try std.testing.expect(pidfd_policy.flagsValid(0));
    try std.testing.expect(!pidfd_policy.flagsValid(1));
}

test "pidfd_send_signal validates signal and flags" {
    try std.testing.expect(pidfd_signal_policy.signalValid(64));
    try std.testing.expect(!pidfd_signal_policy.signalValid(65));
    try std.testing.expect(pidfd_signal_policy.flagsValid(0));
    try std.testing.expect(!pidfd_signal_policy.flagsValid(1));
    try std.testing.expect(pidfd_signal_policy.aliasesShareValidation());
}

test "NVMe flush policy validates opcode completion" {
    try std.testing.expectEqual(@as(u8, 0), nvme_flush_policy.OPCODE);
    try std.testing.expect(nvme_flush_policy.statusOk(0));
    try std.testing.expect(!nvme_flush_policy.statusOk(2));
}

test "IPC endpoints are reclaimed on owner exit" {
    try std.testing.expect(ipc_lifecycle_policy.shouldReclaim(7, 7));
    try std.testing.expect(!ipc_lifecycle_policy.shouldReclaim(7, 8));
    try std.testing.expect(!ipc_lifecycle_policy.shouldReclaim(null, 7));
    try std.testing.expectEqual(@as(i32, -1), ipc_lifecycle_policy.wakeResult(true, false));
    try std.testing.expectEqual(@as(i32, -1), ipc_lifecycle_policy.wakeResult(true, true));
}

test "IPC endpoint destruction requires the owner" {
    try std.testing.expect(ipc_endpoint_policy.canDestroy(4, 4));
    try std.testing.expect(!ipc_endpoint_policy.canDestroy(4, 5));
    try std.testing.expect(!ipc_endpoint_policy.canDestroy(null, 4));
}

test "IPC capability grants require endpoint owner and known rights" {
    try std.testing.expect(capability_policy.grantAllowed(4, 4, 0x0F));
    try std.testing.expect(!capability_policy.grantAllowed(4, 5, 0x0F));
    try std.testing.expect(!capability_policy.grantAllowed(4, 4, 0x80));
    try std.testing.expect(!capability_policy.grantAllowed(4, 4, 0x100));
    try std.testing.expect(!capability_policy.grantAllowed(4, 4, 0x101));
    try std.testing.expect(capability_policy.grantTargetAllowed(4, 4, 5));
    try std.testing.expect(!capability_policy.grantTargetAllowed(4, 5, 6));
    try std.testing.expect(!capability_policy.grantTargetAllowed(null, 4, 5));
}

test "IPC receive authorization permits owners and receive capabilities only" {
    try std.testing.expect(capability_policy.operationAllowed(false, true, .receive));
    try std.testing.expect(!capability_policy.operationAllowed(false, false, .receive));
    try std.testing.expect(capability_policy.operationAllowed(true, false, .receive));
    try std.testing.expect(!capability_policy.operationAllowed(false, true, .send));
    try std.testing.expect(!capability_policy.operationAllowed(false, true, .notify));
}

test "IPC capabilities reject stale endpoint generations" {
    try std.testing.expect(capability_generation_policy.matches(7, 7));
    try std.testing.expect(!capability_generation_policy.matches(7, 8));
}

test "IPC endpoint generations are wide enough for long-lived slot reuse" {
    try std.testing.expect(capability_generation_policy.matches(@as(u64, 0x1_0000_0000), @as(u64, 0x1_0000_0000)));
    try std.testing.expect(!capability_generation_policy.matches(@as(u64, 0x1_0000_0000), @as(u64, 1)));
}

test "IPC timeout policy gives replies and invalidation precedence" {
    try std.testing.expect(ipc_timeout_policy.deadlineExpired(10, 10));
    try std.testing.expectEqual(@as(i32, 0), ipc_timeout_policy.wakeResult(true, true, true, true));
    try std.testing.expectEqual(@as(i32, -1), ipc_timeout_policy.wakeResult(false, true, true, true));
    try std.testing.expectEqual(@as(i32, -4), ipc_timeout_policy.wakeResult(false, false, true, true));
    try std.testing.expect(ipc_timeout_policy.callSendRegistrationExpires(true, false));
    try std.testing.expect(!ipc_timeout_policy.callSendRegistrationExpires(true, true));
    try std.testing.expect(ipc_timeout_policy.callBindingExpires(true, false));
    try std.testing.expect(!ipc_timeout_policy.callBindingExpires(true, true));
}

test "task lifetime refs protect slot incarnations" {
    var slot = task_lifetime_policy.Slot{};
    task_lifetime_policy.beginSlot(&slot);
    var reference = task_lifetime_policy.pin(&slot).?;
    try std.testing.expect(task_lifetime_policy.markZombie(&slot));
    try std.testing.expect(!task_lifetime_policy.reap(&slot));
    try std.testing.expect(task_lifetime_policy.release(&slot, &reference));
    try std.testing.expect(task_lifetime_policy.reap(&slot));
    task_lifetime_policy.beginSlot(&slot);
    try std.testing.expect(!task_lifetime_policy.release(&slot, &reference));
}

test "POSIX MQ descriptor policy validates access and flags" {
    try std.testing.expect(posix_mq_descriptor_policy.flagsValid(posix_mq_descriptor_policy.O_NONBLOCK));
    try std.testing.expect(!posix_mq_descriptor_policy.flagsValid(3));
    try std.testing.expect(!posix_mq_descriptor_policy.flagsValid(0x400));
    try std.testing.expect(posix_mq_descriptor_policy.canSend(posix_mq_descriptor_policy.O_WRONLY));
    try std.testing.expect(!posix_mq_descriptor_policy.canSend(posix_mq_descriptor_policy.O_RDONLY));
    try std.testing.expect(posix_mq_descriptor_policy.canReceive(posix_mq_descriptor_policy.O_RDONLY));
    try std.testing.expect(!posix_mq_descriptor_policy.canReceive(posix_mq_descriptor_policy.O_WRONLY));
    try std.testing.expect(posix_mq_descriptor_policy.accessAllows(posix_mq_descriptor_policy.O_RDWR, .send));
    try std.testing.expect(posix_mq_descriptor_policy.accessAllows(posix_mq_descriptor_policy.O_RDWR, .receive));
    try std.testing.expectEqual(posix_mq_descriptor_policy.O_NONBLOCK, posix_mq_descriptor_policy.statusFlags(posix_mq_descriptor_policy.O_NONBLOCK | posix_mq_descriptor_policy.O_CLOEXEC));
    try std.testing.expect(posix_mq_descriptor_policy.sigevNotifyValid(0));
    try std.testing.expect(!posix_mq_descriptor_policy.sigevNotifyValid(1));
}

test "CLONE_FILES preserves MQ handle usability until shared sidecar ownership exists" {
    try std.testing.expect(std.mem.indexOf(u8, kt.clone_source, "posix_mq.zig").? >= 0);
    try std.testing.expect(std.mem.indexOf(u8, kt.clone_source, "inheritRefs(") != null);
}

test "parent TID copyout aborts an unpublished child before publication" {
    const source = kt.clone_source;
    try std.testing.expect(std.mem.indexOf(u8, source, "abortUnpublishedChild(child_idx)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "abortUnpublishedChild(child_idx)").? <
        std.mem.indexOf(u8, source, "publishRunnable(child_idx)").?);
}

test "lost current task aborts the unpublished clone child" {
    const source = kt.clone_source;
    const current_failure = std.mem.indexOf(u8, source, "const current_idx = sched.currentTaskIndex() orelse").?;
    const abort = std.mem.indexOfPos(u8, source, current_failure, "abortUnpublishedChild(child_idx)").?;
    try std.testing.expect(abort > current_failure);
}

test "fd table allocation failure releases the kernel stack" {
    const source = kt.task_source;
    var search_from: usize = 0;
    var matches: usize = 0;
    while (std.mem.indexOfPos(u8, source, search_from, "OOM allocating fd table")) |fd_failure| {
        const branch_end = std.mem.indexOfPos(u8, source, fd_failure, "};").?;
        const stack_release = std.mem.indexOfPos(u8, source, fd_failure, "freeKernelStack(stack_virt)").?;
        try std.testing.expect(stack_release < branch_end);
        matches += 1;
        search_from = branch_end + 2;
    }
    try std.testing.expectEqual(@as(usize, 3), matches);
}

test "flat loader transfers mapped page ownership to the user address space" {
    const source = kt.loader_source;
    const map_failure = std.mem.indexOf(u8, source, "Failed to map code page").?;
    const destroy = std.mem.indexOfPos(u8, source, map_failure, "destroyUserSpace(user_pml4)").?;
    const free_suffix = std.mem.indexOfPos(u8, source, destroy, "freePagesFrom(&code_pages, p, allocated)").?;
    try std.testing.expect(free_suffix > destroy);
    try std.testing.expect(std.mem.indexOfPos(u8, source, free_suffix, "freePages(&code_pages, allocated)") == null);
}

test "exec loader frees pages that never enter the page table" {
    const source = kt.loader_source;
    const map_failure = std.mem.indexOf(u8, source, "paging.mapPageNoFlush(new_pml4, page_vaddr, phys").?;
    const map_catch = std.mem.indexOfPos(u8, source, map_failure, "pmm.freePage(phys)").?;
    try std.testing.expect(map_catch > map_failure);
    const stack_failure = std.mem.indexOf(u8, source, "mapUserPageNoFlush(new_pml4, user_stack_base, stack_phys").?;
    const stack_free = std.mem.indexOfPos(u8, source, stack_failure, "pmm.freePage(stack_phys)").?;
    try std.testing.expect(stack_free > stack_failure);
}

test "flat loader uses full address-space teardown for root allocation failure" {
    const source = kt.loader_source;
    const failure = std.mem.indexOf(u8, source, "OOM for code pages").?;
    const teardown = std.mem.indexOfPos(u8, source, failure, "destroyUserSpace(user_pml4)").?;
    try std.testing.expect(teardown > failure);
    try std.testing.expect(std.mem.indexOfPos(u8, source, failure, "pmm.freePage(user_pml4)") == null);
}

test "flat loader capacity matches its fixed code-page table" {
    const source = kt.loader_source;
    try std.testing.expect(std.mem.indexOf(u8, source, "if (pages_needed > 256) return null") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var code_pages: [256]?u64") != null);
}

test "exec aborts destroy the newly loaded address space before returning" {
    const source = kt.execve_source;
    var search_from: usize = 0;
    var matches: usize = 0;
    while (std.mem.indexOfPos(u8, source, search_from, "currentTaskIndex() orelse {")) |failure| {
        const branch_end = std.mem.indexOfPos(u8, source, failure, "};").?;
        const teardown = std.mem.indexOfPos(u8, source, failure, "destroyUserSpace(result.pml4)").?;
        try std.testing.expect(teardown < branch_end);
        matches += 1;
        search_from = branch_end + 2;
    }
    try std.testing.expectEqual(@as(usize, 1), matches);
    // A failed Mm allocation also tears the new space down.
    try std.testing.expect(std.mem.indexOf(u8, source, "createMmForRoot(result.pml4) orelse {\n        user_space.destroyUserSpace(result.pml4);") != null);
}

test "ELF loaders validate segment arithmetic and file payload bounds" {
    const source = kt.loader_source;
    try std.testing.expect(std.mem.indexOf(u8, source, "fn validLoadSegment").? <
        std.mem.indexOf(u8, source, "const seg_start").?);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, source, "validLoadSegment(phdr, file.size)"));
    try std.testing.expect(std.mem.indexOf(u8, source, "phdr.p_filesz > phdr.p_memsz") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "phdr.p_filesz > file_size - phdr.p_offset") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "phdr.p_memsz > USER_ADDR_LIMIT - phdr.p_vaddr") != null);
}

test "ELF loader bounds unaligned first-page copies" {
    const source = kt.loader_source;
    const copy_len = std.mem.indexOf(u8, source, "const copy_len = @min(file_copy_end - file_copy_start, paging.PAGE_SIZE - page_offset)").?;
    const copy = std.mem.indexOfPos(u8, source, copy_len, "dst[page_offset .. page_offset + copy_len]").?;
    try std.testing.expect(copy > copy_len);
}

test "the LAPIC is mapped before any driver can take an MSI, so its EOI is never dropped" {
    // An NVMe/AHCI MSI taken while lapic_base was still 0 had its EOI
    // silently skipped; the vector stayed in-service and masked the timer
    // (vector 240 < 242) on CPU0 for good.
    const main_source = kt.main_source;
    const early = std.mem.indexOf(u8, main_source, "lapic.mapEarly(").?;
    const ahci = std.mem.indexOf(u8, main_source, "ahci.init();").?;
    const nvme = std.mem.indexOf(u8, main_source, "nvme.init();").?;
    try std.testing.expect(early < ahci and early < nvme);
    const lapic_src = kt.lapic_source;
    try std.testing.expect(std.mem.indexOf(u8, lapic_src, "pub fn mapEarly(lapic_phys: u64) void") != null);
}

test "boot treats reaper startup failure as fatal" {
    const main_source = kt.main_source;
    const reaper_start = std.mem.indexOf(u8, main_source, "proc/reaper.zig").?;
    const init_load = std.mem.indexOfPos(u8, main_source, reaper_start, "loader.loadProgram(\"init\"").?;
    try std.testing.expect(std.mem.indexOfPos(u8, main_source, reaper_start, "if (!@import(\"proc/reaper.zig\").start())") != null);
    try std.testing.expect(reaper_start < init_load);
}

test "reaper startup reports kernel-thread allocation failure" {
    const source = kt.reaper_source;
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn start() bool") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "orelse return false") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "return true") != null);
}

test "reaper waitDone cannot abandon detached teardown on signal" {
    const source = kt.reaper_source;
    const start = std.mem.indexOf(u8, source, "pub fn waitDone").?;
    const end = std.mem.indexOfPos(u8, source, start, "pub fn completeLocked").?;
    const body = source[start..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "set.setWaiter(slot, waiter_token)") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "pendingActionable") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "sched.rescheduleAfterBlock()") != null);
}

test "sched_setaffinity pins target lifetime before mutation and migration" {
    const source = kt.syscall_entry_source;
    const start = std.mem.indexOf(u8, source, "fn syscallSchedSetaffinity").?;
    const end = std.mem.indexOfPos(u8, source, start, "fn syscallStatfs").?;
    const body = source[start..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "pinTaskByTid(pid") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "pinTaskByIndex(cur_idx") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "target.cpu_affinity = affinity") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "const was_ready = target.state == .ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "const lock_flags = task_mod2.lockTask()") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "defer target_pin.release()") != null);
    const unlock = std.mem.indexOf(u8, body, "task_mod2.unlockTask(lock_flags)").?;
    const enqueue = std.mem.indexOf(u8, body, "enqueueTask(target)").?;
    const old_cpu = std.mem.indexOf(u8, body, "const old_cpu = target.last_cpu").?;
    try std.testing.expect(old_cpu < unlock);
    try std.testing.expect(unlock < enqueue);
    try std.testing.expect(std.mem.indexOfPos(u8, body, enqueue, "old_cpu").? > enqueue);
}

test "unlinked MQ closes can reclaim a nonempty queue" {
    try std.testing.expect(std.mem.indexOf(u8, kt.posix_mq_source, "q.marked_removed and q.open_count == 0") != null);
}

test "POSIX MQ notify registration is exclusive" {
    try std.testing.expect(std.mem.indexOf(u8, kt.posix_mq_source, "const notify_kind = bo.readU32Le(buf[12..16])") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.posix_mq_source, "sigevNotifyValid(notify_kind)") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.posix_mq_source, "return -16") != null);
}

test "POSIX MQ getsetattr invalid descriptor releases the lock" {
    const source = kt.posix_mq_source;
    try std.testing.expect(std.mem.indexOf(u8, source, "descriptorHandle(owner_idx, mqd) orelse {") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "mq_lock.release(flags);") != null);
}

test "POSIX MQ descriptor tokens round-trip only inside the descriptor window" {
    const p = posix_mq_descriptor_policy;
    try std.testing.expectEqual(@as(u32, p.DESCRIPTOR_BASE), p.tokenValue(0));
    try std.testing.expectEqual(@as(?u32, 0), p.decodeToken(p.tokenValue(0)));
    try std.testing.expectEqual(@as(?u32, p.MAX_DESCRIPTORS - 1), p.decodeToken(p.tokenValue(p.MAX_DESCRIPTORS - 1)));
    try std.testing.expect(p.decodeToken(p.DESCRIPTOR_BASE - 1) == null);
    try std.testing.expect(p.decodeToken(p.DESCRIPTOR_BASE + p.MAX_DESCRIPTORS) == null);
    try std.testing.expect(p.decodeToken(0) == null);
    try std.testing.expect(p.decodeToken(std.math.maxInt(u32)) == null);
}

test "production task slot reset preserves its incarnation" {
    var bytes = [_]u8{0} ** 32;
    const incarnation_offset = 8;
    const incarnation = @as(*u64, @ptrCast(@alignCast(&bytes[incarnation_offset])));
    incarnation.* = 7;
    task_slot_lifetime.resetPreservingIncarnation(&bytes, incarnation);
    try std.testing.expectEqual(@as(u64, 7), incarnation.*);
    try std.testing.expectEqual(@as(u8, 0), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0), bytes[31]);
}

test "IPC call tokens do not reuse endpoint identifiers" {
    const call_reply = kt.ipc_call_reply_policy;
    try std.testing.expect(call_reply.tokenBindsCallee(41, 7, 7, 7));
    try std.testing.expect(!call_reply.tokenBindsCallee(41, 7, 7, 8));
    try std.testing.expect(!call_reply.tokenBindsCallee(41, 7, 8, 7));
    try std.testing.expect(!call_reply.tokenBindsCallee(0, 7, 7, 7));
}

test "IPC direct wake paths pin targets before consuming registrations" {
    const source = kt.ipc_source;
    const pin_call = "task.pinTaskByIndex(";
    const wake_call = "task.unblockTaskIfIncarnation";
    var wakes: usize = 0;
    var previous_wake: usize = 0;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, wake_call)) |wake_at| : (cursor = wake_at + wake_call.len) {
        const pin_at = std.mem.lastIndexOf(u8, source[0..wake_at], pin_call) orelse return error.TestUnexpectedResult;
        try std.testing.expect(pin_at >= previous_wake);
        previous_wake = wake_at;
        wakes += 1;
    }
    try std.testing.expect(wakes >= 4);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, source, ", false) orelse"));
    try std.testing.expect(std.mem.indexOf(u8, source, "endpoints[caller_endpoint].owner_tid != owner_pin.tid") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "Keep the registration intact") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "Do not consume a message") != null);
}

test "POSIX MQ production keeps waiter ownership and queue generations" {
    const mq_source = kt.posix_mq_source;
    const task_source = kt.task_source;
    try std.testing.expect(std.mem.indexOf(u8, task_source, "mq_waiter: MqWaiter") != null);
    try std.testing.expect(std.mem.indexOf(u8, task_source, "detachWaiterForTask(idx)") != null);
    try std.testing.expect(std.mem.indexOf(u8, mq_source, "queue_generations") != null);
    try std.testing.expect(std.mem.indexOf(u8, mq_source, "queue_generations[idx] +%= 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, mq_source, "if (waiter.linked)") != null);
    try std.testing.expect(std.mem.indexOf(u8, mq_source, "freeQueue(q, &wakes)") != null);
}

test "native IPC Message ABI remains exactly 256 bytes" {
    const message = @import("kernel_shared").ipc_message;
    try std.testing.expectEqual(@as(usize, 256), @sizeOf(message.Message));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(message.Message, "sender"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(message.Message, "reply_to"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(message.Message, "msg_type"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(message.Message, "flags"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(message.Message, "payload"));
}

test "task exit clears task-scoped IPC capabilities" {
    try std.testing.expect(capability_lifecycle_policy.clearOnExit(3, true));
    try std.testing.expect(!capability_lifecycle_policy.clearOnExit(3, false));
}

test "socket shutdown rejects unsupported how values" {
    try std.testing.expect(socket_policy.shutdownHowValid(0));
    try std.testing.expect(socket_policy.shutdownHowValid(2));
    try std.testing.expect(!socket_policy.shutdownHowValid(3));
}

test "socket connect validates sockaddr lengths" {
    try std.testing.expect(socket_address_policy.inetLengthValid(16, false));
    try std.testing.expect(!socket_address_policy.inetLengthValid(15, false));
    try std.testing.expect(socket_address_policy.inetLengthValid(28, true));
    try std.testing.expect(!socket_address_policy.inetLengthValid(27, true));
    try std.testing.expect(socket_address_policy.inet4FamilyValid(2));
    try std.testing.expect(!socket_address_policy.inet4FamilyValid(1));
    try std.testing.expect(!socket_address_policy.optionalUserAddressValid(0x8000, 0x8000));
}

test "x86 syscall SFMASK clears direction flag" {
    try std.testing.expect(std.mem.indexOf(u8, kt.syscall_entry_source, "wrmsr(MSR_SFMASK, 0x40700)") != null);
}

test "IPC call/reply policy binds one reply to caller, callee and token" {
    var state = ipc_call_reply_policy.State{};
    try std.testing.expect(ipc_call_reply_policy.begin(&state, 9, 1, 7));
    try std.testing.expect(ipc_call_reply_policy.bindCallee(&state, 2));
    try std.testing.expect(!ipc_call_reply_policy.replyAllowed(&state, 8, 1, 2));
    try std.testing.expect(!ipc_call_reply_policy.replyAllowed(&state, 9, 3, 2));
    try std.testing.expect(ipc_call_reply_policy.replyAllowed(&state, 9, 1, 2));
    try std.testing.expect(ipc_call_reply_policy.consumeReply(&state));
    try std.testing.expect(!ipc_call_reply_policy.consumeReply(&state));
}

test "public native call/reply uses runtime token binding" {
    try std.testing.expect(ipc_call_reply_policy.runtimeAvailable());
}

test "IPC failed call rollback clears the complete reply binding" {
    var binding = ipc_call_reply_policy.ReplyBinding{ .callee_task = 3, .callee_tid = 44, .token = 12 };
    ipc_call_reply_policy.clearBinding(&binding);
    try std.testing.expect(binding.callee_task == null);
    try std.testing.expect(binding.callee_tid == null);
    try std.testing.expectEqual(@as(u64, 0), binding.token);
}

test "native IPC delegation ABI is wired through the public header and dispatch" {
    try std.testing.expect(std.mem.indexOf(u8, kt.syscall_entry_source, "486 => { // moqipc_grant_cap_to") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.moqi_syscalls_header, "SYS_moqipc_grant_cap_to 486") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.moqi_syscalls_header, "SYS_moqipc_recv 300") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.moqi_syscalls_header, "SYS_moqipc_reply 302") != null);
}

test "IPC timeout maintenance is wired into every timer backend" {
    try std.testing.expect(std.mem.indexOf(u8, kt.aarch64_trap_source, "ipc.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.riscv64_trap_source, "ipc.zig") != null);
    // x86: the normal timed-wait tick owns expiry; slow maintenance must not duplicate it.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, kt.sched_source, "ipc.zig\").timeoutTick("));
    const timed_wait = std.mem.indexOf(u8, kt.sched_source, "fn bspTimedWaitTick").?;
    const fg_maint = std.mem.indexOf(u8, kt.sched_source, "fn bspSlowMaintenance") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOfPos(u8, kt.sched_source, timed_wait, "timeoutTick(").? < fg_maint);
    const fg_end = std.mem.indexOfPos(u8, kt.sched_source, fg_maint, "\n}\n") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, kt.sched_source[fg_maint..fg_end], "timeoutTick(") == null);
    try std.testing.expect(std.mem.indexOf(u8, kt.sched_source, "bspSlowMaintenance();") != null);
}

test "absolute timer deadlines are converted from their clock domain" {
    try std.testing.expectEqual(@as(?u64, 100), time_policy.absoluteDeltaNs(0, 1_100, 1_000, 0));
    try std.testing.expectEqual(@as(?u64, 100), time_policy.absoluteDeltaNs(0, 2_100, 1_000, 1_000));
    try std.testing.expectEqual(@as(?u64, 0), time_policy.absoluteDeltaNs(0, 1_100, 1_000, 1_000));
    try std.testing.expectEqual(@as(?u64, 1_100), time_policy.absoluteDeltaNs(0, 1_100, 1_000, -1_000));
    try std.testing.expectEqual(@as(?u64, 100), time_policy.absoluteDeltaNs(1, 1_100, 1_000, 99_000));
    try std.testing.expectEqual(@as(?u64, 0), time_policy.absoluteDeltaNs(0, 900, 1_000, 0));
    try std.testing.expect(time_policy.absoluteDeltaNs(999, 1, 1, 0) == null);
}

test "shared mmap regions remain shared across fork policy checks" {
    try std.testing.expect(shared_mapping_policy.contains(0x4000, 2, 0x4000, 0x1000));
    try std.testing.expect(shared_mapping_policy.contains(0x4000, 2, 0x5000, 0x1000));
    try std.testing.expect(!shared_mapping_policy.contains(0x4000, 2, 0x6000, 0x1000));
}

test "mq_open validates creation attributes instead of silently defaulting" {
    try std.testing.expectEqual(
        posix_mq_attr_policy.Validation.defaults,
        posix_mq_attr_policy.validate(false, true, 0, 0, 8, 512),
    );
    try std.testing.expectEqual(
        posix_mq_attr_policy.Validation.valid,
        posix_mq_attr_policy.validate(true, true, 8, 512, 8, 512),
    );
    try std.testing.expectEqual(
        posix_mq_attr_policy.Validation.invalid,
        posix_mq_attr_policy.validate(true, true, 0, 512, 8, 512),
    );
    try std.testing.expectEqual(
        posix_mq_attr_policy.Validation.invalid,
        posix_mq_attr_policy.validate(true, true, 8, 513, 8, 512),
    );
}

test "timer_create requires a valid output pointer" {
    try std.testing.expect(!posix_timer_policy.timerIdPointerValid(0));
    try std.testing.expect(posix_timer_policy.timerIdPointerValid(0x4000));
    try std.testing.expect(!posix_timer_policy.timerIdPointerValid(posix_timer_policy.USER_LIMIT));
}

test "timer_create rejects an invalid non-null sigevent pointer" {
    try std.testing.expect(posix_timer_policy.sigeventPointerValid(0));
    try std.testing.expect(posix_timer_policy.sigeventPointerValid(0x4000));
    try std.testing.expect(!posix_timer_policy.sigeventPointerValid(posix_timer_policy.USER_LIMIT));
}

test "POSIX timers survive worker-thread exit" {
    try std.testing.expectEqual(@as(u32, 42), posix_timer_policy.timerOwnerTid(true, 99, 42));
    try std.testing.expect(!posix_timer_policy.shouldDeleteForExit(42, true, 99));
    try std.testing.expect(posix_timer_policy.shouldDeleteForExit(42, false, 42));
}

test "POSIX timer policy isolates foreign timer operations" {
    try std.testing.expect(posix_timer_policy.flagsValid(0));
    try std.testing.expect(posix_timer_policy.flagsValid(posix_timer_policy.TIMER_ABSTIME));
    try std.testing.expect(!posix_timer_policy.flagsValid(2));
    try std.testing.expect(posix_timer_policy.ownerMatches(42, 42));
    try std.testing.expect(!posix_timer_policy.ownerMatches(42, 99));
}

test "clock_settime rejects invalid clocks and overflowing timestamps" {
    try std.testing.expectEqual(@as(?i64, 1_000_000_001), time_set_policy.requestedNanoseconds(0, 1, 1));
    try std.testing.expect(time_set_policy.requestedNanoseconds(1, 1, 0) == null);
    try std.testing.expect(time_set_policy.requestedNanoseconds(0, 0, 1_000_000_000) == null);
    try std.testing.expect(time_set_policy.requestedNanoseconds(0, std.math.maxInt(u64), 0) == null);
}

test "clock_settime requires CAP_SYS_TIME" {
    try std.testing.expect(time_set_policy.canSetRealtime(true));
    try std.testing.expect(!time_set_policy.canSetRealtime(false));
}

test "clock syscalls reject unsupported clock IDs" {
    try std.testing.expect(time_syscall.clockIdValid(0));
    try std.testing.expect(time_syscall.clockIdValid(1));
    try std.testing.expect(!time_syscall.clockIdValid(999));
}

test "time output pointer failures use EFAULT" {
    try std.testing.expectEqual(@as(i64, -14), time_pointer_policy.invalidPointerErrno(0, 0x8000));
    try std.testing.expectEqual(@as(i64, -14), time_pointer_policy.invalidPointerErrno(0x8000, 0x8000));
}

test "sigreturn rejects unsafe user register targets" {
    try std.testing.expect(sigreturn_policy.userTargetValid(0x4000));
    try std.testing.expect(!sigreturn_policy.userTargetValid(0));
    try std.testing.expect(!sigreturn_policy.userTargetValid(sigreturn_policy.USER_LIMIT));
}

test "sigreturn sanitizes saved RFLAGS instead of rejecting fault-frame state" {
    const p = sigreturn_policy;
    try std.testing.expectEqual(@as(u64, 0x202), p.sanitizeRflags(0x202));
    // A handler entered from a #PF frame carries RF=1; sigreturn must accept it.
    try std.testing.expectEqual(@as(u64, 0x10246), p.sanitizeRflags(0x10246));
    // Arithmetic flags, TF, DF, AC and ID are user-owned.
    try std.testing.expectEqual(@as(u64, 0x240fd7), p.sanitizeRflags(0x240fd7));
    // IF and the reserved bit are forced on.
    try std.testing.expectEqual(@as(u64, 0x202), p.sanitizeRflags(0));
    // IOPL, NT, VM, VIF and VIP never reach user mode.
    try std.testing.expectEqual(@as(u64, 0x202), p.sanitizeRflags(0x3202));
    try std.testing.expectEqual(@as(u64, 0x202), p.sanitizeRflags(0x4202));
    try std.testing.expectEqual(@as(u64, 0x202), p.sanitizeRflags(0x20202));
    try std.testing.expectEqual(@as(u64, 0x202), p.sanitizeRflags(0x180202));
    try std.testing.expectEqual(p.USER_RFLAGS | 0x202, p.sanitizeRflags(std.math.maxInt(u64)));
}

test "clone3 validates size before bounded argument copying" {
    try std.testing.expect(!clone3_policy.sizeValid(63));
    try std.testing.expect(clone3_policy.sizeValid(64));
    try std.testing.expect(clone3_policy.sizeValid(88));
    try std.testing.expect(!clone3_policy.sizeValid(89));
    try std.testing.expectEqual(@as(usize, 64), clone3_policy.copySize(64));
}

test "POSIX MQ timeout distinguishes absent and zero deadlines" {
    try std.testing.expect(
        std.meta.activeTag(posix_mq_policy.fromNanoseconds(false, null)) == .none,
    );
    try std.testing.expectEqual(@as(u64, 0), posix_mq_policy.fromNanoseconds(true, 0).deadline);
    try std.testing.expect(posix_mq_policy.deadlineTokenMatches(4, 9, 4, 9));
    try std.testing.expect(!posix_mq_policy.deadlineTokenMatches(4, 9, 4, 10));
}

test "POSIX MQ rejects an undersized receive buffer" {
    try std.testing.expect(posix_mq_receive_policy.bufferAcceptsMessage(5, 5));
    try std.testing.expect(!posix_mq_receive_policy.bufferAcceptsMessage(4, 5));
}

test "POSIX MQ selects the highest priority message" {
    const slots = [_]posix_mq_priority_policy.Slot{
        .{ .used = true, .priority = 2 },
        .{ .used = true, .priority = 7 },
        .{ .used = true, .priority = 7 },
    };
    try std.testing.expectEqual(@as(?u32, 1), posix_mq_priority_policy.selectHighest(&slots, 0));
    try std.testing.expectEqual(@as(?u32, 1), posix_mq_priority_policy.nextFree(&[_]posix_mq_priority_policy.Slot{ .{ .used = true }, .{} }, 0));
}

test "POSIX MQ ownership rejects a foreign close" {
    var state = posix_mq_ownership_policy.State{};
    try std.testing.expect(!posix_mq_ownership_policy.release(&state));
    posix_mq_ownership_policy.acquire(&state);
    try std.testing.expect(posix_mq_ownership_policy.release(&state));
}

test "SysV SHM control copies are staged outside the IRQ lock" {
    try std.testing.expect(sysv_shm_policy.copyBeforeLock(sysv_shm_policy.IPC_SET));
    try std.testing.expect(sysv_shm_policy.copyAfterUnlock(sysv_shm_policy.IPC_STAT));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -1))), sysv_shm_policy.encodeKey(-1));
}

test "SysV SHM exit detach requires a VM guard" {
    try std.testing.expect(sysv_shm_lifecycle_policy.detachAllowed(true, true));
    try std.testing.expect(!sysv_shm_lifecycle_policy.detachAllowed(false, true));
    try std.testing.expect(!sysv_shm_lifecycle_policy.detachAllowed(true, false));
    try std.testing.expect(sysv_shm_lifecycle_policy.unmapOnExit(false));
    try std.testing.expect(!sysv_shm_lifecycle_policy.unmapOnExit(true));
}

test "task operation pin selects a live matching task over a zombie" {
    const candidates = [_]task_op_policy.Candidate{
        .{ .tid = 17, .zombie = true },
        .{ .tid = 17 },
        .{ .tid = 23 },
    };
    try std.testing.expectEqual(task_op_policy.Selection{ .selected = 1 }, task_op_policy.select(&candidates, 17));
}

test "task operation pin selection reports zombie and missing TIDs" {
    const candidates = [_]task_op_policy.Candidate{.{ .tid = 17, .zombie = true }};
    try std.testing.expectEqual(task_op_policy.Selection.zombie, task_op_policy.select(&candidates, 17));
    try std.testing.expectEqual(task_op_policy.Selection.task_not_found, task_op_policy.select(&candidates, 23));
}

test "task operation pin selection checks Mm and ref limits" {
    const no_mm = [_]task_op_policy.Candidate{.{ .tid = 17, .mm_available = false }};
    const overflow = [_]task_op_policy.Candidate{.{ .tid = 17, .operation_refs = task_op_policy.MAX_OPERATION_REFS }};
    try std.testing.expectEqual(task_op_policy.Selection.no_mm, task_op_policy.select(&no_mm, 17));
    try std.testing.expectEqual(task_op_policy.Selection.operation_ref_overflow, task_op_policy.select(&overflow, 17));
}

test "task operation pin accepts a live task and blocks reaping" {
    var state = task_op_policy.State{};
    try state.pin();
    try std.testing.expectEqual(@as(u32, 1), state.operation_refs);
    state.zombie = true;
    try std.testing.expect(!state.reap());
    try std.testing.expect(state.release());
    try std.testing.expect(state.reap());
}

test "task operation pin rejects zombies" {
    var state = task_op_policy.State{ .zombie = true };
    try std.testing.expectError(error.Zombie, state.pin());
}

test "task operation pin rejects a task without an Mm" {
    var state = task_op_policy.State{ .mm_available = false };
    try std.testing.expectError(error.NoMm, state.pin());
}

test "task operation pin rejects bounded reference overflow" {
    var state = task_op_policy.State{ .operation_refs = task_op_policy.MAX_OPERATION_REFS };
    try std.testing.expectError(error.OperationRefOverflow, state.pin());
}

test "task operation pin release is stable and idempotent" {
    var state = task_op_policy.State{};
    try state.pin();
    try std.testing.expect(state.release());
    try std.testing.expect(!state.release());
    try std.testing.expectEqual(@as(u32, 0), state.operation_refs);
}

test "task operation pin cannot resurrect a reaped task" {
    var state = task_op_policy.State{ .zombie = true, .reaped = true };
    try std.testing.expectError(error.Zombie, state.pin());
    try std.testing.expect(!state.reap());
}

test "CLONE_VM requires a parent Mm owner" {
    try std.testing.expectEqual(@as(i64, lifecycle_policy.EINVAL), lifecycle_policy.cloneVmResult(lifecycle_policy.CLONE_VM, false));
    try std.testing.expectEqual(@as(i64, 0), lifecycle_policy.cloneVmResult(lifecycle_policy.CLONE_VM, true));
}

test "CLONE_VM child Mm reference balances after ownership transfer" {
    var state = mm.TestRefState{};
    try std.testing.expect(state.retain());
    try std.testing.expectEqual(@as(u32, 2), state.refs);
    state.release();
    try std.testing.expectEqual(@as(u32, 1), state.refs);
    try std.testing.expect(!state.finalized);
    state.release();
    try std.testing.expect(state.finalized);
}

test "threaded exec is rejected before address-space replacement" {
    try std.testing.expectEqual(@as(i64, lifecycle_policy.EPERM), lifecycle_policy.execResult(true, false));
    try std.testing.expectEqual(@as(i64, 0), lifecycle_policy.execResult(false, false));
}

test "exec on a shared (CLONE_VM) address space is rejected" {
    // A CLONE_VM sibling keeps running in the old address space while exec
    // tears it down — reject exactly like the CLONE_THREAD case.
    try std.testing.expectEqual(@as(i64, lifecycle_policy.EPERM), lifecycle_policy.execResult(false, true));
    try std.testing.expectEqual(@as(i64, lifecycle_policy.EPERM), lifecycle_policy.execResult(true, true));
    try std.testing.expectEqual(@as(i64, 0), lifecycle_policy.execResult(false, false));
}

test "Mm test state rejects underflow and double finalization" {
    var state = mm.TestRefState{};
    try std.testing.expect(state.retain());
    state.release();
    state.release();
    state.release();
    try std.testing.expectEqual(mm.TestRefState.TERMINAL_REFS, state.refs);
    try std.testing.expect(state.dying);
    try std.testing.expect(state.finalized);
    try std.testing.expect(!state.retain());
}

test "Mm test state finalizes only after the last retained reference" {
    var state = mm.TestRefState{};
    try std.testing.expect(state.retain());
    state.release();
    try std.testing.expect(!state.dying);
    try std.testing.expect(!state.finalized);
    state.release();
    try std.testing.expect(state.dying);
    try std.testing.expect(state.finalized);
}

test "Mm terminal reference state cannot be resurrected or overflow" {
    var state = mm.TestRefState{ .refs = mm.TestRefState.MAX_LIVE_REFS };
    try std.testing.expect(!state.retain());
    try std.testing.expectEqual(mm.TestRefState.MAX_LIVE_REFS, state.refs);

    state.refs = 1;
    state.dying = false;
    state.finalized = false;
    state.release();
    try std.testing.expectEqual(mm.TestRefState.TERMINAL_REFS, state.refs);
    try std.testing.expect(!state.retain());
    state.release();
    try std.testing.expectEqual(mm.TestRefState.TERMINAL_REFS, state.refs);
}

test "Mm VM lock policy rejects recursive acquire and unlock without ownership" {
    var lock = mm.TestVmLockState{};
    try std.testing.expect(!lock.release());
    try std.testing.expect(lock.acquire());
    try std.testing.expect(!lock.acquire());
    try std.testing.expect(lock.release());
    try std.testing.expect(!lock.release());
}

test "current-task VM lock policy handles no Mm and recursion" {
    try std.testing.expectEqual(vm_lock_policy.Decision.no_mm, vm_lock_policy.decide(false, false));
    try std.testing.expectEqual(vm_lock_policy.Decision.acquire, vm_lock_policy.decide(true, false));
    try std.testing.expectEqual(vm_lock_policy.Decision.recursive, vm_lock_policy.decide(true, true));
}

test "fault-side VM lock policy: no Mm, acquire, or proceed when owned by us" {
    try std.testing.expectEqual(vm_lock_policy.FaultDecision.no_mm, vm_lock_policy.decideFault(false, false));
    try std.testing.expectEqual(vm_lock_policy.FaultDecision.no_mm, vm_lock_policy.decideFault(false, true));
    try std.testing.expectEqual(vm_lock_policy.FaultDecision.acquire, vm_lock_policy.decideFault(true, false));
    try std.testing.expectEqual(vm_lock_policy.FaultDecision.owned_by_us, vm_lock_policy.decideFault(true, true));
}

test "fault-side guard semantics on TestVmLockState: owned_by_us never re-acquires" {
    var lock: mm.TestVmLockState = .{};
    // .acquire decision takes the lock.
    switch (vm_lock_policy.decideFault(true, lock.held)) {
        .acquire => try std.testing.expect(lock.acquire()),
        else => return error.TestUnexpectedResult,
    }
    // .owned_by_us proceeds WITHOUT acquiring — a recursive acquire on a held
    // IrqSpinlock would deadlock, and TestVmLockState.acquire would fail.
    switch (vm_lock_policy.decideFault(true, true)) {
        .owned_by_us => try std.testing.expect(!lock.acquire()),
        else => return error.TestUnexpectedResult,
    }
    // .no_mm touches no lock at all.
    switch (vm_lock_policy.decideFault(false, false)) {
        .no_mm => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(lock.release());
}

test "reclaim VM lock policy: no Mm, owned-by-us recursion, acquire-or-skip" {
    // No address space: reclaim has nothing to scan.
    try std.testing.expectEqual(vm_lock_policy.ReclaimDecision.no_mm, vm_lock_policy.decideReclaim(false, false, false));
    try std.testing.expectEqual(vm_lock_policy.ReclaimDecision.no_mm, vm_lock_policy.decideReclaim(false, true, false));
    // The current task already owns vm_lock (fault → swapIn → allocPage
    // recursion): proceed WITHOUT re-acquiring — legitimate recursion.
    try std.testing.expectEqual(vm_lock_policy.ReclaimDecision.owned_by_us, vm_lock_policy.decideReclaim(true, true, false));
    try std.testing.expectEqual(vm_lock_policy.ReclaimDecision.owned_by_us, vm_lock_policy.decideReclaim(true, true, true));
    // Not owned by us: a successful non-blocking try acquires; contention
    // skips (reclaim is best-effort — it must never wait on vm_lock).
    try std.testing.expectEqual(vm_lock_policy.ReclaimDecision.acquired, vm_lock_policy.decideReclaim(true, false, true));
    try std.testing.expectEqual(vm_lock_policy.ReclaimDecision.skip, vm_lock_policy.decideReclaim(true, false, false));
}

test "reclaim guard semantics on TestVmLockState: contention skips, never blocks" {
    var lock: mm.TestVmLockState = .{};
    // .acquired decision takes the lock.
    switch (vm_lock_policy.decideReclaim(true, false, lock.acquire())) {
        .acquired => {},
        else => return error.TestUnexpectedResult,
    }
    // A contended try fails and the policy decides .skip — the scan is
    // abandoned rather than spinning on a held lock.
    try std.testing.expect(!lock.acquire());
    switch (vm_lock_policy.decideReclaim(true, false, false)) {
        .skip => {},
        else => return error.TestUnexpectedResult,
    }
    // .owned_by_us proceeds WITHOUT acquiring (would deadlock/fail otherwise).
    switch (vm_lock_policy.decideReclaim(true, true, false)) {
        .owned_by_us => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(lock.release());
}
const shm_policy = kt.shm_policy;
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
const socketpair_policy = kt.socketpair_policy;
const message_batch_policy = kt.message_batch_policy;
const fallocate_policy = kt.fallocate_policy;
const splice = kt.splice;
const unsupported_policy = kt.unsupported_policy;
const sched_getaffinity_policy = kt.sched_getaffinity_policy;
const epoll_policy = kt.epoll_policy;
const accept4_policy = kt.accept4_policy;
const sysv_policy = kt.sysv_policy;
const close_range_policy = kt.close_range_policy;
const move_pages_policy = kt.move_pages_policy;

test "SysV msgrcv keeps its IRQ lock cleanup scoped" {
    const source = kt.sysv_msg_source;
    const receive_start = std.mem.indexOf(u8, source, "pub fn msgrcv") orelse unreachable;
    const receive_end = std.mem.indexOfPos(u8, source, receive_start, "/// msgctl") orelse unreachable;
    const receive = source[receive_start..receive_end];

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, receive, "msg_lock.acquire()"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, receive, "defer msg_lock.release(flags);"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, receive, "msg_lock.release(flags);\n\n    // Write"));
}

test "close_range policy accepts UINT_MAX boundary" {
    try std.testing.expectEqual(@as(i64, 0), close_range_policy.validate(3, close_range_policy.UINT_MAX, 0));
    try std.testing.expectEqual(errno.EINVAL, close_range_policy.validate(4, 3, 0));
    try std.testing.expectEqual(errno.EINVAL, close_range_policy.validate(3, close_range_policy.UINT_MAX, 2));
}

test "move_pages policy validates status ABI" {
    try std.testing.expectEqual(@as(i64, 0), move_pages_policy.validate(0, 0, 0, 0, 0, 0));
    try std.testing.expectEqual(errno.EFAULT, move_pages_policy.validate(0, 1, 0, 0, 0, 0));
    try std.testing.expectEqual(errno.EINVAL, move_pages_policy.validate(0, 4097, 0, 0, 0x1000, 0));
}

test "process_vm policy checks user range boundaries" {
    const user_addr_max: u64 = process_vm_policy.USER_ADDR_MAX;
    try std.testing.expect(process_vm_policy.validUserRange(0, 0));
    try std.testing.expect(!process_vm_policy.validUserRange(0, 1));
    try std.testing.expect(process_vm_policy.validUserRange(user_addr_max - 1, 1));
    try std.testing.expect(!process_vm_policy.validUserRange(user_addr_max, 1));
    try std.testing.expect(!process_vm_policy.validUserRange(user_addr_max - 1, 2));
    try std.testing.expect(!process_vm_policy.validUserRange(std.math.maxInt(u64), 2));
}

test "process_vm policy enforces the iovec count and array boundary" {
    const user_addr_max: u64 = process_vm_policy.USER_ADDR_MAX;
    const entry_size: u64 = process_vm_policy.IOV_ENTRY_SIZE;
    const sixteen_entries: u64 = 16;
    const seventeen_entries: u64 = 17;
    const array_bytes: u64 = sixteen_entries * entry_size;

    try std.testing.expect(process_vm_policy.validIovArray(0, 0));
    try std.testing.expect(process_vm_policy.validIovArray(user_addr_max - array_bytes, sixteen_entries));
    try std.testing.expect(!process_vm_policy.validIovArray(user_addr_max - array_bytes + 1, sixteen_entries));
    try std.testing.expect(!process_vm_policy.validIovArray(std.math.maxInt(u64) - 15, 2));
    try std.testing.expect(!process_vm_policy.validIovArray(0x1000, seventeen_entries));
}

test "process_vm policy rejects aggregate iovec length overflow" {
    const valid: []const process_vm_policy.Iovec = &[_]process_vm_policy.Iovec{
        .{ .base = 0x1000, .len = 3 },
        .{ .base = 0x2000, .len = 4 },
    };
    const overflowing: []const process_vm_policy.Iovec = &[_]process_vm_policy.Iovec{
        .{ .base = 0x1000, .len = std.math.maxInt(u64) },
        .{ .base = 0x2000, .len = 1 },
    };

    try std.testing.expectEqual(@as(?u64, 7), process_vm_policy.aggregateLength(valid));
    try std.testing.expectEqual(@as(?u64, null), process_vm_policy.aggregateLength(overflowing));
}

test "process_vm policy keeps readv and writev permissions asymmetric" {
    const readable: process_vm_policy.Mapping = .{
        .present = true,
        .user = true,
        .readable = true,
        .writable = false,
        .cow = false,
        .huge = false,
        .raw_pte_available = true,
    };
    const writable: process_vm_policy.Mapping = .{
        .present = true,
        .user = true,
        .readable = true,
        .writable = true,
        .cow = false,
        .huge = false,
        .raw_pte_available = true,
    };

    try std.testing.expect(process_vm_policy.permits(.readv, writable, readable));
    try std.testing.expect(!process_vm_policy.permits(.readv, readable, writable));
    try std.testing.expect(process_vm_policy.permits(.writev, readable, writable));
    try std.testing.expect(!process_vm_policy.permits(.writev, writable, readable));
}

test "process_vm policy rejects COW and huge mappings without raw PTE access" {
    const readable: process_vm_policy.Mapping = .{
        .present = true,
        .user = true,
        .readable = true,
        .writable = true,
        .cow = false,
        .huge = false,
        .raw_pte_available = true,
    };
    const cow_without_raw: process_vm_policy.Mapping = .{
        .present = true,
        .user = true,
        .readable = true,
        .writable = true,
        .cow = true,
        .huge = false,
        .raw_pte_available = false,
    };
    const huge_without_raw: process_vm_policy.Mapping = .{
        .present = true,
        .user = true,
        .readable = true,
        .writable = true,
        .cow = false,
        .huge = true,
        .raw_pte_available = false,
    };

    try std.testing.expect(!process_vm_policy.permits(.readv, cow_without_raw, readable));
    try std.testing.expect(!process_vm_policy.permits(.readv, readable, huge_without_raw));
    try std.testing.expect(!process_vm_policy.permits(.writev, readable, cow_without_raw));
    try std.testing.expect(!process_vm_policy.permits(.writev, readable, huge_without_raw));
}

test "SysV IPC authorization and removal policy" {
    const owner: sysv_policy.Owner = .{ .uid = 10, .gid = 20, .cuid = 10, .cgid = 20 };
    try std.testing.expect(sysv_policy.modeAllows(0o640, owner, .{ .euid = 10, .egid = 99 }, true, true));
    try std.testing.expect(sysv_policy.modeAllows(0o064, owner, .{ .euid = 99, .egid = 20 }, true, true));
    try std.testing.expect(!sysv_policy.modeAllows(0o600, owner, .{ .euid = 99, .egid = 99 }, true, false));
    try std.testing.expect(sysv_policy.canManage(owner, .{ .euid = 10, .egid = 99 }));
    try std.testing.expect(!sysv_policy.canManage(owner, .{ .euid = 99, .egid = 99 }));
    try std.testing.expect(!sysv_policy.removalCanFree(true, 1));
    try std.testing.expect(sysv_policy.removalCanFree(true, 0));
}

test "munmap and SysV SHM policy validation" {
    try std.testing.expectEqual(@as(u64, 1), munmap_policy.validate(0x4000, 4096).?.num_pages);
    try std.testing.expect(munmap_policy.validate(0x4001, 4096) == null);
    try std.testing.expect(munmap_policy.validate(munmap_policy.USER_ADDR_MAX - 4096, 8192) == null);
    try std.testing.expect(shm_policy.flagsValid(shm_policy.SHM_RDONLY | shm_policy.SHM_EXEC));
    try std.testing.expect(!shm_policy.flagsValid(1));
    try std.testing.expect(shm_policy.rangeEnd(0x7000_0000, 4096, munmap_policy.USER_ADDR_MAX) != null);
}

test "every kernel file with inline tests is listed in host_test.zig's test{} block (or is a known exception)" {
    // Zig runs a `test` block only in a file reached from a `test {}` block of a test root. A kernel file that gains
    // inline tests but is not listed there compiles fine and never runs them: that is how 113 inline tests went
    // unrun for a long time. This test walks the kernel source tree and fails for any file that has `test "..."`
    // blocks but no `_ = @import("<path>");` line in kernel/host_test.zig.
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "kernel", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    const host_test = kt.host_test_source;
    // Files whose import closure reaches x86 inline assembly cannot be analysed on the host.
    const exceptions = [_][]const u8{ "arch/x86_64/clone.zig", "mm/process_vm.zig" };
    var missing: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, "host_test.zig")) continue;
        const src = try dir.readFileAlloc(io, entry.path, allocator, .limited(4 * 1024 * 1024));
        defer allocator.free(src);
        if (std.mem.indexOf(u8, src, "\ntest \"") == null and !std.mem.startsWith(u8, src, "test \"")) continue;
        var exempt = false;
        for (exceptions) |e| exempt = exempt or std.mem.eql(u8, e, entry.path);
        if (exempt) continue;
        var needle_buf: [256]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buf, "_ = @import(\"{s}\");", .{entry.path});
        if (std.mem.indexOf(u8, host_test, needle) == null) {
            std.debug.print("inline tests never run: kernel/{s} (add `_ = @import(\"{s}\");` to the test block in kernel/host_test.zig)\n", .{ entry.path, entry.path });
            missing += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), missing);
}

test "dns_resolve: hostname syntax, error codes, and the order of checks" {
    const hp = kt.hostname_policy;
    const V = hp.Verdict;
    try std.testing.expectEqual(V.ok, hp.check("localhost"));
    try std.testing.expectEqual(V.ok, hp.check("LocalHost"));
    try std.testing.expectEqual(V.ok, hp.check("example.com"));
    try std.testing.expectEqual(V.ok, hp.check("a.b.c.d"));
    try std.testing.expectEqual(V.ok, hp.check("my-host_1.example.org"));
    try std.testing.expectEqual(V.ok, hp.check("example.com.")); // one trailing dot: fully qualified
    try std.testing.expectEqual(V.ok, hp.check("192.168.7.9")); // dotted decimal is a valid name here
    try std.testing.expectEqual(V.empty, hp.check(""));
    try std.testing.expectEqual(V.invalid, hp.check("."));
    try std.testing.expectEqual(V.invalid, hp.check("a..b"));
    try std.testing.expectEqual(V.invalid, hp.check(".a"));
    try std.testing.expectEqual(V.invalid, hp.check("a.b.."));
    try std.testing.expectEqual(V.invalid, hp.check("-a.example"));
    try std.testing.expectEqual(V.invalid, hp.check("a-.example"));
    try std.testing.expectEqual(V.invalid, hp.check("a.-b"));
    try std.testing.expectEqual(V.invalid, hp.check("a.b-"));
    try std.testing.expectEqual(V.invalid, hp.check("bad name!"));
    try std.testing.expectEqual(V.invalid, hp.check("a b"));
    try std.testing.expectEqual(V.invalid, hp.check("a/b"));
    try std.testing.expectEqual(V.invalid, hp.check("\xc3\xa9.example")); // non-ASCII
    // Label length: 63 is the limit.
    const l63 = "a" ** 63;
    const l64 = "a" ** 64;
    try std.testing.expectEqual(V.ok, hp.check(l63));
    try std.testing.expectEqual(V.invalid, hp.check(l64));
    try std.testing.expectEqual(V.ok, hp.check(l63 ++ "." ++ l63));
    // Whole-name length: 253 is the limit (with or without a trailing dot), longer is ENAMETOOLONG.
    const n253 = l63 ++ "." ++ l63 ++ "." ++ l63 ++ "." ++ ("b" ** 61);
    try std.testing.expectEqual(@as(usize, 253), n253.len);
    try std.testing.expectEqual(V.ok, hp.check(n253));
    try std.testing.expectEqual(V.ok, hp.check(n253 ++ "."));
    try std.testing.expectEqual(V.too_long, hp.check(n253 ++ "b"));
    try std.testing.expectEqual(V.too_long, hp.check(n253 ++ ".b")); // 255 bytes: past the first bound too
    try std.testing.expectEqual(V.too_long, hp.check(n253 ++ "bb")); // 255 bytes, no trailing dot
    try std.testing.expectEqual(V.invalid, hp.check("a.-b.c")); // a hyphen-led label in the middle
    try std.testing.expectEqual(V.invalid, hp.check("a-.b.c")); // a hyphen-ended label in the middle (the dot rule)
    try std.testing.expectEqual(V.invalid, hp.check("a-")); // a hyphen-ended last label
    try std.testing.expectEqual(V.too_long, hp.check("a" ** 300));
    try std.testing.expectEqualStrings("example.com", hp.stripTrailingDot("example.com."));
    try std.testing.expectEqualStrings("example.com", hp.stripTrailingDot("example.com"));
    try std.testing.expectEqualStrings(".", hp.stripTrailingDot("."));

    // The system call checks the output pointer before it can wait on the network, then the name, and
    // writes the output only on success; the three resolver tiers it relies on are already host-tested.
    const src = kt.syscall_entry_source;
    const f = std.mem.indexOf(u8, src, "fn syscallDnsResolve(").?;
    const body = src[f..];
    const out_ok = std.mem.indexOf(u8, body, "if (!copy.validateUserBufferWritable(out_ptr, 4)) return -14;").?;
    const name_in = std.mem.indexOf(u8, body, "const name = switch (userPathResult(name_ptr, &buf)) {").?;
    const verdict = std.mem.indexOf(u8, body, "switch (hp.check(name)) {").?;
    const resolve = std.mem.indexOf(u8, body, "@import(\"../../net/dns.zig\").resolve(hp.stripTrailingDot(name))").?;
    const write = std.mem.indexOf(u8, body, "if (copy.copyToUser(@ptrFromInt(out_ptr), &ip, 4) != 4) return -14;").?;
    try std.testing.expect(out_ok < name_in and name_in < verdict and verdict < resolve and resolve < write);
    try std.testing.expect(std.mem.indexOf(u8, body, ".empty => return -2, // ENOENT") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, ".too_long => return -36, // ENAMETOOLONG") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, ".invalid => return -22, // EINVAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "return -2; // ENOENT: did not resolve") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "495 => { // dns_resolve(name, out4)") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.moqi_syscalls_header, "#define SYS_dns_resolve 495") != null);
}

test "setitimer: Linux validation, saturating arithmetic, and the check order" {
    const ip = kt.itimer_policy;
    const max: i64 = std.math.maxInt(i64);
    // timeval_valid: non-negative seconds, 0 <= usec < 1,000,000.
    try std.testing.expect(ip.timevalValid(.{ .sec = 0, .usec = 0 }));
    try std.testing.expect(ip.timevalValid(.{ .sec = max, .usec = 999_999 }));
    try std.testing.expect(!ip.timevalValid(.{ .sec = -1, .usec = 0 }));
    try std.testing.expect(!ip.timevalValid(.{ .sec = 0, .usec = -1 }));
    try std.testing.expect(!ip.timevalValid(.{ .sec = 0, .usec = 1_000_000 }));
    try std.testing.expect(!ip.timevalValid(.{ .sec = std.math.minInt(i64), .usec = 0 }));
    // Nanoseconds saturate rather than overflow (these used to be unchecked u64 arithmetic, a kernel panic).
    try std.testing.expectEqual(@as(u64, 1_500_000_000), ip.timevalNs(.{ .sec = 1, .usec = 500_000 }));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), ip.timevalNs(.{ .sec = max, .usec = 999_999 }));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), ip.timevalNs(.{ .sec = 0x4000000000000000, .usec = 0 }));
    try std.testing.expectEqual(@as(u64, 0), ip.timevalNs(.{ .sec = 0, .usec = 0 }));
    // A deadline saturates at "never".
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), ip.deadlineNs(1_000, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(u64, 1_500), ip.deadlineNs(1_000, 500));
    // alarm(0xffffffff) is about 136 years: fine in u64 nanoseconds, and never overflows.
    try std.testing.expectEqual(@as(u64, 0xffffffff) * 1_000_000_000, ip.alarmNs(0xffffffff));
    try std.testing.expect(ip.whichValid(0) and ip.whichValid(1) and ip.whichValid(2));
    try std.testing.expect(!ip.whichValid(3) and !ip.whichValid(0xffffffff));

    // The syscall reads and validates the new value before it looks at `which`, and writes the old value
    // only after both; a NULL new value means "disarm" and an old-value fault reports EFAULT.
    const src = kt.syscall_entry_source;
    const f = std.mem.indexOf(u8, src, "fn syscallSetitimer(").?;
    const body = src[f..];
    const read = std.mem.indexOf(u8, body, "if (copy.copyFromUser(&buf, @ptrFromInt(new_value_ptr), 32) < 32) return -14;").?;
    const valid = std.mem.indexOf(u8, body, "if (!itimer_policy.timevalValid(interval) or !itimer_policy.timevalValid(value)) return -22;").?;
    const which = std.mem.indexOf(u8, body, "if (!itimer_policy.whichValid(which)) return -22;").?;
    const old = std.mem.indexOf(u8, body, "const rc = syscallGetitimer(which, old_value_ptr);").?;
    try std.testing.expect(read < valid and valid < which and which < old);
    try std.testing.expect(std.mem.indexOf(u8, body, "if (new_value_ptr != 0) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "itimer_policy.deadlineNs(tsc.nanos(), val_ns)") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "itimer_policy.deadlineNs(now_ns, itimer_policy.alarmNs(seconds))") != null);
    // getitimer: a NULL or bad pointer is EFAULT (EINVAL is for the timer number).
    const g = std.mem.indexOf(u8, src, "fn syscallGetitimer(").?;
    try std.testing.expect(std.mem.indexOf(u8, src[g..], "if (!itimer_policy.whichValid(which)) return -22;\n    if (curr_value_ptr == 0 or curr_value_ptr >= 0x0000_8000_0000_0000) return -14;") != null);
    // The scheduler re-arms a periodic timer with a saturating add: a huge interval used to panic the tick.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, kt.sched_source, "now_ns +| t.itimer_real_interval"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, kt.sched_source, "now_ns + t.itimer_real_interval"));
}

test "hostile user pointers cannot panic the copy helpers, and huge ranges skip absent page tables" {
    const c = kt.copy_from_user_source;
    // A NULL user pointer reaches validateUserRange (and fails it) instead of tripping Zig's "cast causes
    // pointer to be null" safety panic at the @ptrFromInt call site: the parameters accept address zero.
    try std.testing.expect(std.mem.indexOf(u8, c, "pub fn copyFromUser(dst: []u8, src_user: [*]allowzero const u8, count: usize) usize {") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, "pub fn copyToUser(dst_user: [*]allowzero u8, src: []const u8, count: usize) usize {") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, "if (addr == 0) return false;") != null); // and address zero is refused

    // A range walk jumps over a stretch that has no page table instead of visiting every 4 KiB page; without
    // the jump munmap of 128 TiB ran for ~13 s (and mprotect effectively forever) inside one system call.
    const m = kt.mmap_source;
    try std.testing.expect(std.mem.indexOf(u8, m, "pub fn skipHole(task: *task_mod.Task, virt: u64, stop_at_regions: bool) u64 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, m, "const resume_at = skipHole(task, virt, false);") != null); // unmapRange
    try std.testing.expect(std.mem.indexOf(u8, m, "p += (skipHole(task, va, false) - va) / user_space.PAGE_SIZE - 1;") != null); // firstMappedPage
    try std.testing.expect(std.mem.indexOf(u8, m, "p += (skipHole(task, va, false) - va) / page - 1;") != null); // fixedReplaceable
    const mp = kt.mprotect_source;
    try std.testing.expect(std.mem.count(u8, mp, "skipHole(cur,") >= 3);
    try std.testing.expect(std.mem.indexOf(u8, mp, "block = ((block | (1024 * 1024 * 1024 - 1)) + 1) - paging.PAGE_2MB;") != null);
    const h = kt.huge_user_impl_source;
    try std.testing.expect(std.mem.count(u8, h, "1024 * 1024 * 1024 - 1") >= 4); // prescanHuge, demoteRange, both protectHugeOverlaps
}

test "signal errnos follow Linux's order of checks, and a NULL siginfo no longer panics" {
    const src = kt.signal_syscall_source;
    const idx = std.mem.indexOf;
    // sigprocmask: new set read (EFAULT) -> unknown how (EINVAL) -> old mask written (EFAULT).
    const sp = idx(u8, src, "pub fn sigprocmask(").?;
    const read_set = idx(u8, src[sp..], "if (set_ptr != 0 and !copy.validateUserBuffer(set_ptr, width)) return -14;").?;
    const bad_how = idx(u8, src[sp..], "if (set_ptr != 0 and how > 2) return -22;").?;
    const old_ok = idx(u8, src[sp..], "if (oldset_ptr != 0 and !copy.validateUserBufferWritable(oldset_ptr, width)) return -14;").?;
    const old_write = idx(u8, src[sp..], "if (oldset_ptr != 0 and copy.copyToUser(").?;
    try std.testing.expect(read_set < bad_how and bad_how < old_ok and old_ok < old_write);

    // kill: the target is found (ESRCH) before an out-of-range signal number is rejected (EINVAL).
    const kp = idx(u8, src, "pub fn killPosix(").?;
    const body = src[kp..];
    try std.testing.expect(idx(u8, body, "if (signum > 64) return -22;\n    const cur") == null); // no up-front check any more
    const find_target = idx(u8, body, "const target = task_mod.getTask(idx) orelse return -3;").?;
    const sig_check = idx(u8, body, "if (signum > 64) return -22;\n        if (!maySignal(cur, target)) return -1;").?;
    try std.testing.expect(find_target < sig_check);
    try std.testing.expect(idx(u8, body, "if (!found) return -3;\n    if (signum > 64) return -22;") != null);
    try std.testing.expect(idx(u8, body, "if (pid == -1) {\n        if (signum > 64) return -22;\n        return killAll(cur, signum);") != null);

    // tkill: bad tid (EINVAL) -> missing thread (ESRCH) -> bad signal (EINVAL).
    const tk = idx(u8, src, "pub fn tkill(").?;
    const tb = src[tk..];
    const tid_ok = idx(u8, tb, "id_policy.tkillTargetTid(tid_arg) orelse return -22;").?;
    const tid_exists = idx(u8, tb, "task_mod.findTaskByTid(tid) orelse return -3; // ESRCH").?;
    const tsig = idx(u8, tb, "if (sig > 64) return -22;").?;
    try std.testing.expect(tid_ok < tid_exists and tid_exists < tsig);

    // rt_sigtimedwait: a NULL or bad set pointer is EFAULT (size 0 stays EINVAL); the info buffer is
    // checked only when a signal is about to be taken, before it is consumed.
    const tw = idx(u8, src, "pub fn rtSigtimedwait(").?;
    const wb = src[tw..];
    try std.testing.expect(idx(u8, wb, "if (sigset_size == 0) return -22;\n    if (sigset_ptr == 0 or sigset_ptr >= 0x0000_8000_0000_0000) return -14; // EFAULT") != null);
    const taking = idx(u8, wb, "if (info_ptr != 0 and !copy.validateUserBufferWritable(info_ptr, si.SIGINFO_SIZE)) return -14;").?;
    const consume = idx(u8, wb, "_ = @atomicRmw(u64, &cur.pending_signals, .And").?;
    try std.testing.expect(taking < consume);

    // rt_sigqueueinfo: a NULL siginfo used to reach @ptrFromInt(0) and panic the kernel; it is EFAULT, and the
    // read comes before the signal-number check.
    const qi = idx(u8, src, "pub fn rtSigqueueinfo(").?;
    const qb = src[qi..];
    const null_check = idx(u8, qb, "if (uinfo_ptr == 0 or !copy.validateUserBuffer(uinfo_ptr, raw.len)) return -14;").?;
    const copy_in = idx(u8, qb, "if (copy.copyFromUser(&raw, @ptrFromInt(uinfo_ptr), raw.len) != raw.len) return -14;").?;
    const qsig = idx(u8, qb, "if (sig > 64) return -22;").?;
    try std.testing.expect(null_check < copy_in and copy_in < qsig);
}

test "memory-management argument rules follow Linux: ranges, rounding, flags, mlockall" {
    const rp = kt.range_policy;
    const E = kt.errno;
    // alignUp wraps to null where Linux's PAGE_ALIGN wraps to 0.
    try std.testing.expectEqual(@as(?u64, 0), rp.alignUp(0));
    try std.testing.expectEqual(@as(?u64, 4096), rp.alignUp(1));
    try std.testing.expectEqual(@as(?u64, 8192), rp.alignUp(4097));
    try std.testing.expectEqual(@as(?u64, null), rp.alignUp(0xffff_ffff_ffff_f001));
    try std.testing.expectEqual(@as(?u64, null), rp.alignUp(std.math.maxInt(u64)));
    // inUserSpace
    try std.testing.expect(rp.inUserSpace(0x1000, 1));
    try std.testing.expect(!rp.inUserSpace(0xffff800000000000, 1));
    try std.testing.expect(!rp.inUserSpace(0x00007ffffffff000, 2));
    try std.testing.expect(rp.inUserSpace(0x00007ffffffff000, 1));
    try std.testing.expect(!rp.inUserSpace(0x1000, std.math.maxInt(u64)));
    // madvise: alignment, then wrap (EINVAL); zero length succeeds; leaving user space is ENOMEM.
    try std.testing.expectEqual(rp.Span{ .err = E.EINVAL }, rp.madviseSpan(0x1001, 4096));
    try std.testing.expectEqual(rp.Span{ .err = E.EINVAL }, rp.madviseSpan(0x1000, std.math.maxInt(u64)));
    try std.testing.expectEqual(rp.Span.empty, rp.madviseSpan(0x1000, 0));
    try std.testing.expectEqual(rp.Span{ .err = E.EINVAL }, rp.madviseSpan(0x1001, 0)); // alignment is checked first
    try std.testing.expectEqual(rp.Span{ .err = E.ENOMEM }, rp.madviseSpan(0xffff800000000000, 4096));
    try std.testing.expectEqual(rp.Span{ .pages = 2 }, rp.madviseSpan(0x1000, 4097));
    for ([_]u32{ 0, 1, 2, 3, 4, 8 }) |a| try std.testing.expect(rp.madviseSupported(a));
    for ([_]u32{ 5, 9, 10, 11, 12, 14, 100, 9999 }) |a| try std.testing.expect(!rp.madviseSupported(a));
    // mincore: alignment EINVAL; a wrapping length or a range outside user space is ENOMEM; zero length is empty.
    try std.testing.expectEqual(rp.Span{ .err = E.EINVAL }, rp.mincoreSpan(0x1001, 4096));
    try std.testing.expectEqual(rp.Span{ .err = E.ENOMEM }, rp.mincoreSpan(0x1000, std.math.maxInt(u64)));
    try std.testing.expectEqual(rp.Span{ .err = E.ENOMEM }, rp.mincoreSpan(0xffff800000000000, 4096));
    try std.testing.expectEqual(rp.Span.empty, rp.mincoreSpan(0x1000, 0));
    try std.testing.expectEqual(rp.Span{ .pages = 1 }, rp.mincoreSpan(0x1000, 1));
    // mlock: zero length is a no-op; the start rounds down and the length grows by the part page.
    try std.testing.expectEqual(rp.Span.empty, rp.lockSpan(0x30000000, 0));
    try std.testing.expectEqual(rp.Span{ .pages = 1 }, rp.lockSpan(0x1000, 4096));
    try std.testing.expectEqual(rp.Span{ .pages = 2 }, rp.lockSpan(0x1fff, 2)); // straddles a page boundary
    try std.testing.expectEqual(rp.Span{ .err = E.ENOMEM }, rp.lockSpan(0x1000, std.math.maxInt(u64)));
    try std.testing.expectEqual(rp.Span{ .err = E.ENOMEM }, rp.lockSpan(0xffff800000000000, 4096));
    try std.testing.expect(!rp.inUserSpace(0x0000_8000_0000_0000, 0)); // the limit itself is outside
    // mlockall flags
    try std.testing.expect(!rp.mlockallFlagsValid(0));
    try std.testing.expect(rp.mlockallFlagsValid(1));
    try std.testing.expect(rp.mlockallFlagsValid(2));
    try std.testing.expect(rp.mlockallFlagsValid(3));
    try std.testing.expect(!rp.mlockallFlagsValid(4)); // MCL_ONFAULT alone
    try std.testing.expect(rp.mlockallFlagsValid(5));
    try std.testing.expect(!rp.mlockallFlagsValid(8));

    // munmap rounds the length up instead of refusing it, and an unaligned address stays EINVAL.
    const mp = kt.munmap_policy;
    try std.testing.expectEqual(@as(u64, 1), mp.validate(0x4000, 1).?.num_pages);
    try std.testing.expectEqual(@as(u64, 2), mp.validate(0x4000, 4097).?.num_pages);
    try std.testing.expect(mp.validate(0x4000, 0) == null);
    try std.testing.expect(mp.validate(0x4001, 4096) == null);
    try std.testing.expect(mp.validate(0x4000, std.math.maxInt(u64)) == null);

    // mmap: the extra flags are accepted, MAP_LOCKED included (it is acted on); unknown protection bits are dropped.
    const m = kt.mmap_policy;
    try std.testing.expect(m.flagsValid(m.MAP_PRIVATE | m.MAP_ANONYMOUS | m.MAP_FIXED_NOREPLACE));
    try std.testing.expect(m.flagsValid(m.MAP_PRIVATE | m.MAP_ANONYMOUS | m.MAP_GROWSDOWN | m.MAP_STACK | m.MAP_POPULATE | m.MAP_NORESERVE));
    try std.testing.expect(m.flagsValid(m.MAP_PRIVATE | 0x2000));
    try std.testing.expectEqual(@as(u64, 3), m.normalizeProt(3 | 0x01000000));
    // File offsets: past the largest file size is EOVERFLOW; a length that wraps when rounded is the caller's ENOMEM.
    try std.testing.expect(!m.fileOffsetOverflows(0, 4096));
    try std.testing.expect(!m.fileOffsetOverflows(1 << 40, 1 << 20));
    try std.testing.expect(m.fileOffsetOverflows(0xffff_ffff_ffff_f000, 4096)); // offset -4096
    try std.testing.expect(m.fileOffsetOverflows(m.MAX_FILE_BYTES - 4095, 8192));
    try std.testing.expect(!m.fileOffsetOverflows(m.MAX_FILE_BYTES - 8191, 4096));
    try std.testing.expect(!m.fileOffsetOverflows(0, 0xffff_ffff_ffff_ffff));
    try std.testing.expect(!m.fileOffsetOverflows(4096, 0xffff_ffff_ffff_f001));

    // The entry points use the policy (order matters: see the comments next to each).
    const mmsrc = kt.mmap_source;
    try std.testing.expect(std.mem.indexOf(u8, mmsrc, "if (offset % user_space.PAGE_SIZE != 0) return -22; // EINVAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, mmsrc, "const prot = mmap_policy.normalizeProt(prot_raw);") != null);
    try std.testing.expect(std.mem.indexOf(u8, mmsrc, "if (length > user_space.USER_ADDR_MAX) return -12; // ENOMEM") != null);
    try std.testing.expect(std.mem.indexOf(u8, mmsrc, "return -75; // EOVERFLOW") != null);
    try std.testing.expect(std.mem.indexOf(u8, mmsrc, "if ((desc.status_flags & 0x03) == 1) return -13; // EACCES") != null);
    try std.testing.expect(std.mem.indexOf(u8, mmsrc, "if (is_noreplace and (hasMmapOverlap(cur, base, num_pages) or !pagesFree(cur, base, num_pages))) return -17; // EEXIST") != null);
    try std.testing.expect(std.mem.indexOf(u8, mmsrc, "if (!fixedReplaceable(cur, base, num_pages)) return -12;\n            unmapRange(cur, base, num_pages);") != null);
    try std.testing.expect(std.mem.indexOf(u8, mmsrc, "if (old_size > 0xFFFFFFFF_FFFFF000 or new_size > 0xFFFFFFFF_FFFFF000) return -22; // EINVAL") != null);
    const se = kt.syscall_entry_source;
    try std.testing.expect(std.mem.indexOf(u8, se, "if (!rp.madviseSupported(advice)) return -22; // EINVAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, se, "if (!@import(\"../../mm/mmap.zig\").rangeMapped(addr, length)) return -12; // ENOMEM: a hole in the range") != null);
    try std.testing.expect(std.mem.indexOf(u8, se, "return @import(\"../../mm/mlock.zig\").mlockall(flags);") != null);
    try std.testing.expect(std.mem.indexOf(u8, se, "return -38;\n}\n\n/// munlockall()") == null);
    try std.testing.expect(std.mem.indexOf(u8, se, "return @import(\"../../mm/mlock.zig\").munlockall();") != null);
    try std.testing.expect(std.mem.indexOf(u8, se, "return @import(\"../../mm/mlock.zig\").mlock(addr, len);") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.mprotect_source, "if (addr >= user_space.USER_ADDR_MAX) return ENOMEM;") != null);
}

test "fcntl flags: FD_CLOEXEC is one bit, F_SETFL touches only APPEND/NONBLOCK/DIRECT/NOATIME, open keeps SYNC/DIRECTORY/NOFOLLOW/NOATIME" {
    const fp = kt.fcntl_policy;
    // F_SETFD keeps only FD_CLOEXEC.
    try std.testing.expectEqual(@as(u32, 1), fp.fdFlagsFromSetfd(1));
    try std.testing.expectEqual(@as(u32, 1), fp.fdFlagsFromSetfd(0xff));
    try std.testing.expectEqual(@as(u32, 0), fp.fdFlagsFromSetfd(2));
    try std.testing.expectEqual(@as(u32, 0), fp.fdFlagsFromSetfd(0));
    // F_SETFL: access mode and creation flags are never changed, the four settable ones are.
    const rdwr: u32 = 2;
    try std.testing.expectEqual(rdwr | 0x800, fp.applySetfl(rdwr, 0x800));
    try std.testing.expectEqual(rdwr, fp.applySetfl(rdwr | 0x800, 0));
    try std.testing.expectEqual(rdwr | 0x800, fp.applySetfl(rdwr, 0 | 0x800 | 1)); // O_WRONLY in arg is ignored
    try std.testing.expectEqual(rdwr, fp.applySetfl(rdwr, 0x40 | 0x200 | 0x80)); // O_CREAT|O_TRUNC|O_EXCL
    try std.testing.expectEqual(rdwr | 0x400, fp.applySetfl(rdwr, 0x400));
    try std.testing.expectEqual(rdwr | 0x4000, fp.applySetfl(rdwr, 0x4000));
    try std.testing.expectEqual(rdwr | 0x40000, fp.applySetfl(rdwr, 0x40000));
    try std.testing.expectEqual(@as(u32, 1), fp.applySetfl(1 | 0x400, 0)); // clearing O_APPEND keeps O_WRONLY
    try std.testing.expectEqual(rdwr | 0x10000, fp.applySetfl(rdwr | 0x10000, 0x800 & 0)); // O_DIRECTORY survives
    // open() keeps the flags F_GETFL reports, and drops the creation-time ones.
    try std.testing.expectEqual(@as(u32, 0x3 | 0x400 | 0x800 | 0x101000 | 0x4000 | 0x10000 | 0x20000 | 0x40000), fp.OPEN_STATUS_MASK);
    try std.testing.expectEqual(@as(u32, 0), fp.OPEN_STATUS_MASK & (0x40 | 0x80 | 0x100 | 0x200 | 0x80000));
    // Sockets, epoll, eventfd and timerfd report O_RDWR; files and pipes report what open() stored.
    for ([_][]const u8{ "tcp_socket", "udp_socket", "unix_socket", "raw_socket", "epoll", "eventfd", "timerfd" }) |t| {
        try std.testing.expect(fp.alwaysReadWrite(t));
        try std.testing.expectEqual(@as(u32, 2), fp.reportedFlags(t, 0));
        try std.testing.expectEqual(@as(u32, 2 | 0x800), fp.reportedFlags(t, 0x800));
    }
    for ([_][]const u8{ "pipe_read", "pipe_write", "tmpfs_file", "special", "devfs", "ext2_file", "rofs_file" }) |t| {
        try std.testing.expect(!fp.alwaysReadWrite(t));
        try std.testing.expectEqual(@as(u32, 1), fp.reportedFlags(t, 1));
    }
    try std.testing.expectEqual(@as(u32, 2), fp.reportedFlags("tcp_socket", 1)); // any stored access mode is replaced
    try std.testing.expectEqual(@as(i64, 2), fp.F_UNLCK);
    // Pipes have one fixed page: asking for more is ENOMEM, asking for less (or nothing) rounds up to it.
    try std.testing.expectEqual(@as(i64, 4096), fp.setPipeSize(4096));
    try std.testing.expectEqual(@as(i64, 4096), fp.setPipeSize(1));
    try std.testing.expectEqual(@as(i64, 4096), fp.setPipeSize(0));
    try std.testing.expectEqual(@as(i64, -12), fp.setPipeSize(4097));
    try std.testing.expectEqual(@as(i64, -12), fp.setPipeSize(1 << 30));
    try std.testing.expect(std.mem.indexOf(u8, kt.vfs_source, "pub const PIPE_BUF_SIZE: u32 = 4096;") != null); // fcntl_policy.PIPE_SIZE mirrors it

    // The entry points use the policy.
    const fc = kt.fcntl_source;
    try std.testing.expect(std.mem.indexOf(u8, fc, "t.fd_table.fds[fd].fd_flags = policy.fdFlagsFromSetfd(arg);") != null);
    try std.testing.expect(std.mem.indexOf(u8, fc, "vfs.setStatusFlags(&t.fd_table.fds[fd], policy.applySetfl(cur_flags, arg));") != null);
    try std.testing.expect(std.mem.indexOf(u8, fc, "policy.reportedFlags(@tagName(d.fd_type), vfs.statusFlagsOf(d))") != null);
    try std.testing.expect(std.mem.indexOf(u8, fc, "F_GETLEASE => return policy.F_UNLCK") != null);
    try std.testing.expect(std.mem.indexOf(u8, fc, "else => return -9, // EBADF: not a pipe") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.vfs_source, "const status = flags & @import(\"fcntl_policy.zig\").OPEN_STATUS_MASK;") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.file_io_source, "if (result >= 0 and (flags & @import(\"fcntl_policy.zig\").O_CLOEXEC) != 0 and result < vfs_mod.MAX_FDS) {\n        cur.fd_table.fds[@intCast(result)].fd_flags = @import(\"fcntl_policy.zig\").FD_CLOEXEC;") != null);
}

test "epoll errnos follow Linux's order: EFAULT, EBADF, EPERM, EINVAL; wait checks maxevents before the buffer" {
    const ep = kt.epoll_policy;
    const E = kt.errno;
    const base: ep.CtlFacts = .{
        .op = ep.CTL_ADD, .event_readable = true, .events = ep.EPOLLIN, .epfd = .{ .epoll = 0 },
        .target_open = true, .target_pollable = true, .target_is_epoll = false, .same_file = false,
    };
    try std.testing.expectEqual(@as(i64, 0), ep.ctlPrecheck(base));
    // The event is read first, so an unreadable one beats a bad descriptor ...
    var f = base;
    f.event_readable = false;
    f.epfd = .closed;
    try std.testing.expectEqual(E.EFAULT, ep.ctlPrecheck(f));
    // ... but DEL carries no event, so there the descriptors decide.
    f.op = ep.CTL_DEL;
    try std.testing.expectEqual(E.EBADF, ep.ctlPrecheck(f));
    f.epfd = .{ .epoll = 0 };
    f.target_open = false;
    try std.testing.expectEqual(E.EBADF, ep.ctlPrecheck(f));
    // A bad epfd and a bad target are both EBADF; a target that cannot poll is EPERM even when epfd is not epoll.
    f = base;
    f.epfd = .not_epoll;
    f.target_pollable = false;
    try std.testing.expectEqual(E.EPERM, ep.ctlPrecheck(f));
    f.target_pollable = true;
    try std.testing.expectEqual(E.EINVAL, ep.ctlPrecheck(f));
    f = base;
    f.same_file = true;
    try std.testing.expectEqual(E.EINVAL, ep.ctlPrecheck(f));
    // An unknown op still has its event read; it is EINVAL only after the descriptors check out.
    f = base;
    f.op = 9;
    try std.testing.expectEqual(@as(i64, 0), ep.ctlPrecheck(f));
    f.event_readable = false;
    try std.testing.expectEqual(E.EFAULT, ep.ctlPrecheck(f));
    // EPOLLEXCLUSIVE: not with MOD, not on an epoll target, not with bits outside IN/OUT/ERR/HUP/WAKEUP/ET.
    f = base;
    f.events = ep.EPOLLIN | ep.EPOLLEXCLUSIVE;
    try std.testing.expectEqual(@as(i64, 0), ep.ctlPrecheck(f));
    f.events = ep.EPOLLOUT | ep.EPOLLEXCLUSIVE | ep.EPOLLET;
    try std.testing.expectEqual(@as(i64, 0), ep.ctlPrecheck(f));
    f.events = ep.EPOLLIN | ep.EPOLLEXCLUSIVE | 0x40000000; // EPOLLONESHOT
    try std.testing.expectEqual(E.EINVAL, ep.ctlPrecheck(f));
    f.events = ep.EPOLLIN | ep.EPOLLEXCLUSIVE | 0x2000; // EPOLLRDHUP
    try std.testing.expectEqual(E.EINVAL, ep.ctlPrecheck(f));
    f.events = ep.EPOLLIN | ep.EPOLLEXCLUSIVE | 0x002; // EPOLLPRI
    try std.testing.expectEqual(E.EINVAL, ep.ctlPrecheck(f));
    f.events = ep.EPOLLIN | ep.EPOLLEXCLUSIVE;
    f.target_is_epoll = true;
    try std.testing.expectEqual(E.EINVAL, ep.ctlPrecheck(f));
    f.target_is_epoll = false;
    f.op = ep.CTL_MOD;
    try std.testing.expectEqual(E.EINVAL, ep.ctlPrecheck(f));
    f.events = ep.EPOLLIN; // without the flag MOD is fine
    try std.testing.expectEqual(@as(i64, 0), ep.ctlPrecheck(f));

    // Targets with no poll operation.
    for ([_][]const u8{ "ramdisk_file", "fat32_file", "ext2_file", "tmpfs_file", "proc_file", "rofs_file" }) |t| {
        try std.testing.expect(!ep.pollable(t));
    }
    for ([_][]const u8{ "pipe_read", "pipe_write", "tcp_socket", "udp_socket", "unix_socket", "eventfd", "timerfd", "epoll", "inotify", "pidfd", "special", "devfs" }) |t| {
        try std.testing.expect(ep.pollable(t));
    }

    // epoll_wait: epfd, then maxevents, then the buffer's range, then "is it epoll".
    const ok: ep.Epfd = .{ .epoll = 3 };
    try std.testing.expectEqual(@as(i64, 0), ep.waitErrno(ok, 1, 0x1000));
    try std.testing.expectEqual(E.EBADF, ep.waitErrno(.closed, 0, 0xffff800000000000));
    try std.testing.expectEqual(E.EINVAL, ep.waitErrno(ok, 0, 0x1000));
    try std.testing.expectEqual(E.EINVAL, ep.waitErrno(ok, -1, 0x1000));
    try std.testing.expectEqual(E.EINVAL, ep.waitErrno(.not_epoll, 0, 0xffff800000000000));
    try std.testing.expectEqual(E.EFAULT, ep.waitErrno(.not_epoll, 4, 0xffff800000000000));
    try std.testing.expectEqual(E.EINVAL, ep.waitErrno(.not_epoll, 4, 0x1000));
    try std.testing.expectEqual(E.EFAULT, ep.waitErrno(ok, 4, 0xffff800000000000));
    // The buffer is range-checked only: NULL and a small bad address pass, the top of user space does not.
    try std.testing.expectEqual(@as(i64, 0), ep.waitErrno(ok, 4, 0));
    try std.testing.expectEqual(@as(i64, 0), ep.waitErrno(ok, 4, 8));
    try std.testing.expectEqual(E.EFAULT, ep.waitErrno(ok, 1000, 0x00007ffffffff000));
    try std.testing.expectEqual(@as(i64, 0), ep.waitErrno(ok, 1, 0x00007ffffffff000));
    // maxevents ceiling is INT_MAX / 12, not the 128 slots the kernel keeps.
    try std.testing.expectEqual(@as(i32, 178956970), ep.MAX_WAIT_EVENTS);
    try std.testing.expectEqual(@as(i64, 0), ep.waitErrno(ok, 129, 0x1000));
    try std.testing.expectEqual(@as(i64, 0), ep.waitErrno(ok, 1024, 0x1000));
    try std.testing.expectEqual(@as(i64, 0), ep.waitErrno(ok, ep.MAX_WAIT_EVENTS, 0x1000));
    try std.testing.expectEqual(E.EINVAL, ep.waitErrno(ok, ep.MAX_WAIT_EVENTS + 1, 0x1000));

    // struct epoll_event is the packed 12-byte x86_64 layout, and the entry points use the policy.
    try std.testing.expectEqual(@as(usize, 12), ep.EVENT_SIZE);
    try std.testing.expectEqual(@as(usize, 4), ep.EVENT_DATA_OFFSET);
    const src = kt.epoll_source;
    try std.testing.expect(std.mem.indexOf(u8, src, "events: u32 align(1),\n    data: u64 align(1),") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "std.debug.assert(@sizeOf(EpollEvent) == epoll_policy.EVENT_SIZE);") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const pre = epoll_policy.ctlPrecheck(.{") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const pre = epoll_policy.waitErrno(kind, max_events, events_buf);") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "if (epoll_policy.ctlHasEvent(op)) event = copyEventFromUser(event_ptr);") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "if ((item.events & epoll_policy.EPOLLEXCLUSIVE) != 0) return EINVAL;") != null);
    const se = kt.syscall_entry_source;
    try std.testing.expect(std.mem.indexOf(u8, se, "return @import(\"../../net/epoll.zig\").epollCtl(fd, op, target, event);") != null);
    try std.testing.expect(std.mem.indexOf(u8, se, "return @import(\"../../net/epoll.zig\").epollWaitFd(fd, events, max_events, timeout);") != null);
}

test "epoll_create1 accepts only zero or EPOLL_CLOEXEC" {
    try std.testing.expectEqual(@as(i64, 0), epoll_policy.validate(0));
    try std.testing.expectEqual(kt.errno.EINVAL, epoll_policy.validate(1));
    try std.testing.expectEqual(@as(i64, 0), epoll_policy.validate(0x80000));

    try std.testing.expectEqual(@as(i64, 0), accept4_policy.validate(0));
    try std.testing.expectEqual(@as(i64, 0), accept4_policy.validate(accept4_policy.SOCK_NONBLOCK));
    try std.testing.expectEqual(@as(i64, 0), accept4_policy.validate(accept4_policy.SOCK_CLOEXEC));
    try std.testing.expectEqual(@as(i64, 0), accept4_policy.validate(accept4_policy.SUPPORTED_FLAGS));
    try std.testing.expectEqual(kt.errno.EINVAL, accept4_policy.validate(1));
    try std.testing.expectEqual(kt.errno.EINVAL, accept4_policy.validate(accept4_policy.SUPPORTED_FLAGS | 1));
}

test "splice validation accepts supported flags and rejects unknown bits" {
    try std.testing.expectEqual(@as(i64, 0), splice.validateSpliceFlags(0));
    try std.testing.expectEqual(@as(i64, 0), splice.validateSpliceFlags(splice.SPLICE_F_MOVE | splice.SPLICE_F_NONBLOCK));
    try std.testing.expectEqual(errno.EINVAL, splice.validateSpliceFlags(4));
}

test "splice validation rejects offsets on pipe endpoints only" {
    try std.testing.expectEqual(@as(i64, 0), splice.validateSpliceOffsets(true, 0, false, 123));
    try std.testing.expectEqual(@as(i64, 0), splice.validateSpliceOffsets(false, 123, true, 0));
    try std.testing.expectEqual(errno.EINVAL, splice.validateSpliceOffsets(true, 1, false, 0));
    try std.testing.expectEqual(errno.EINVAL, splice.validateSpliceOffsets(false, 0, true, 1));
}

test "splice endpoint classification permits only pipe-mediated directions" {
    try std.testing.expect(splice.classifySpliceEndpoints(.file, .pipe_write));
    try std.testing.expect(splice.classifySpliceEndpoints(.pipe_read, .tcp_socket));
    try std.testing.expect(splice.classifySpliceEndpoints(.pipe_read, .file));
    try std.testing.expect(splice.classifySpliceEndpoints(.pipe_read, .pipe_write));
    try std.testing.expect(!splice.classifySpliceEndpoints(.file, .tcp_socket));
    try std.testing.expect(!splice.classifySpliceEndpoints(.tcp_socket, .file));
}

test "sendfile count and 32-bit range validation enforce ABI boundaries" {
    try std.testing.expectEqual(@as(i64, 0), splice.validateSendfileCount(0));
    try std.testing.expectEqual(@as(i64, 0), splice.validateSendfileCount(splice.MAX_SENDFILE_COUNT));
    try std.testing.expectEqual(errno.EINVAL, splice.validateSendfileCount(splice.MAX_SENDFILE_COUNT + 1));
    try std.testing.expectEqual(@as(i64, 0), splice.validate32BitFileRange(0xFFFF_FFFF, 0));
    try std.testing.expectEqual(@as(i64, 0), splice.validate32BitFileRange(0xFFFF_FFFE, 1));
    try std.testing.expectEqual(errno.EINVAL, splice.validate32BitFileRange(0x1_0000_0000, 0));
    try std.testing.expectEqual(errno.EINVAL, splice.validate32BitFileRange(0xFFFF_FFFF, 1));
}

test "splice transfer calculations cap destination and partial progress" {
    try std.testing.expectEqual(@as(u64, 0), splice.transferCapacity(10, 0, 8192));
    try std.testing.expectEqual(@as(u64, 10), splice.transferCapacity(10, 20, 8192));
    try std.testing.expectEqual(@as(u64, 8192), splice.transferCapacity(9000, 9000, 8192));
    try std.testing.expectEqual(@as(u64, 4), splice.acceptedProgress(10, 4));
    try std.testing.expectEqual(@as(u64, 10), splice.acceptedProgress(10, 20));
    try std.testing.expectEqual(@as(u64, 0), splice.acceptedProgress(10, -5));
}

test "sched_getaffinity validates pid before user copy" {
    try std.testing.expectEqual(@as(i64, 0), sched_getaffinity_policy.validatePid(0, 17, true));
    try std.testing.expectEqual(@as(i64, 0), sched_getaffinity_policy.validatePid(17, 17, true));
    try std.testing.expectEqual(errno.ESRCH, sched_getaffinity_policy.validatePid(18, 17, true));
    try std.testing.expectEqual(errno.ESRCH, sched_getaffinity_policy.validatePid(17, 17, false));
}

test "unsupported syscall policy returns ENOSYS without inspecting arguments" {
    try std.testing.expectEqual(kt.errno.ENOSYS, unsupported_policy.acct());
    try std.testing.expectEqual(kt.errno.ENOSYS, unsupported_policy.unshare());
    try std.testing.expectEqual(kt.errno.ENOSYS, unsupported_policy.processMadvise());
    try std.testing.expectEqual(kt.errno.ENOSYS, unsupported_policy.landlock());
    try std.testing.expectEqual(kt.errno.ENOSYS, unsupported_policy.lsm());
}

test "mount_setattr keeps the unsupported ENOSYS contract" {
    try std.testing.expectEqual(@as(i64, -38), kt.unsupported_policy.mountSetattr());
    const source = kt.syscall_entry_source;
    const start = std.mem.indexOf(u8, source, "442 => { // mount_setattr").?;
    const end = std.mem.indexOfPos(u8, source, start, "443 =>").?;
    const body = source[start..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "unsupported_policy.mountSetattr()") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "frame.rax = 0") == null);
}

test "quotactl_fd keeps the unsupported ENOSYS contract" {
    try std.testing.expectEqual(@as(i64, -38), kt.unsupported_policy.quotactlFd());
    const source = kt.syscall_entry_source;
    const start = std.mem.indexOf(u8, source, "443 => { // quotactl_fd").?;
    const end = std.mem.indexOfPos(u8, source, start, "444 =>").?;
    const body = source[start..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "unsupported_policy.quotactlFd()") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "frame.rax = 0") == null);
}

test "rseq_slice_yield keeps the unsupported ENOSYS contract" {
    try std.testing.expectEqual(@as(i64, -38), kt.unsupported_policy.rseqSliceYield());
    const source = kt.syscall_entry_source;
    const start = std.mem.indexOf(u8, source, "471 => { // rseq_slice_yield").?;
    const end = std.mem.indexOfPos(u8, source, start, "472 =>").?;
    const body = source[start..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "unsupported_policy.rseqSliceYield()") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "frame.rax = 0") == null);
}

test "process_mrelease keeps the unsupported ENOSYS contract" {
    try std.testing.expectEqual(@as(i64, -38), kt.unsupported_policy.processMrelease());
    const source = kt.syscall_entry_source;
    const start = std.mem.indexOf(u8, source, "448 => { // process_mrelease").?;
    const end = std.mem.indexOfPos(u8, source, start, "449 =>").?;
    const body = source[start..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "unsupported_policy.processMrelease()") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "frame.rax = 0") == null);
}

test "memfd_secret keeps the unsupported ENOSYS contract" {
    try std.testing.expectEqual(@as(i64, -38), kt.unsupported_policy.memfdSecret());
    const source = kt.syscall_entry_source;
    const start = std.mem.indexOf(u8, source, "447 => { // memfd_secret").?;
    const end = std.mem.indexOfPos(u8, source, start, "448 =>").?;
    const body = source[start..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "unsupported_policy.memfdSecret()") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "frame.rax = @bitCast(@as(i64, -38))") == null);
}

test "listns keeps the unsupported ENOSYS contract" {
    try std.testing.expectEqual(@as(i64, -38), kt.unsupported_policy.listns());
    const source = kt.syscall_entry_source;
    const start = std.mem.indexOf(u8, source, "470 => { // listns").?;
    const end = std.mem.indexOfPos(u8, source, start, "471 =>").?;
    const body = source[start..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "unsupported_policy.listns()") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "frame.rax = 0") == null);
}

test "set_mempolicy_home_node keeps the unsupported ENOSYS contract" {
    try std.testing.expectEqual(@as(i64, -38), kt.unsupported_policy.setMempolicyHomeNode());
    const source = kt.syscall_entry_source;
    const start = std.mem.indexOf(u8, source, "450 => { // set_mempolicy_home_node").?;
    const end = std.mem.indexOfPos(u8, source, start, "451 =>").?;
    const body = source[start..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "unsupported_policy.setMempolicyHomeNode()") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "frame.rax = 0") == null);
}

test "map_shadow_stack keeps the unsupported ENOSYS contract" {
    try std.testing.expectEqual(@as(i64, -38), kt.unsupported_policy.mapShadowStack());
    const source = kt.syscall_entry_source;
    const start = std.mem.indexOf(u8, source, "453 => { // map_shadow_stack").?;
    const end = std.mem.indexOfPos(u8, source, start, "454 =>").?;
    const body = source[start..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "unsupported_policy.mapShadowStack()") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "frame.rax = 0") == null);
}

test "statmount and listmount keep the unsupported ENOSYS contract" {
    try std.testing.expectEqual(@as(i64, -38), kt.unsupported_policy.statmount());
    try std.testing.expectEqual(@as(i64, -38), kt.unsupported_policy.listmount());
    const source = kt.syscall_entry_source;
    for ([_][]const u8{ "457 => { // statmount", "458 => { // listmount" }) |needle| {
        const start = std.mem.indexOf(u8, source, needle).?;
        const end = std.mem.indexOfPos(u8, source, start, "459 =>").?;
        const body = source[start..end];
        try std.testing.expect(std.mem.indexOf(u8, body, "unsupported_policy.") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "frame.rax = 0") == null);
    }
}

test "chroot keeps the unsupported ENOSYS contract" {
    try std.testing.expectEqual(@as(i64, -38), kt.unsupported_policy.chroot());
    const source = kt.syscall_entry_source;
    const start = std.mem.indexOf(u8, source, "280 => { // chroot").?;
    const end = std.mem.indexOfPos(u8, source, start, "281 =>").?;
    const body = source[start..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "unsupported_policy.chroot()") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "syscallChroot") == null);
}

test "memfd_create is implemented on an anonymous tmpfs entry" {
    const source = kt.syscall_entry_source;
    const start = std.mem.indexOf(u8, source, "285 => { // memfd_create").?;
    const end = std.mem.indexOfPos(u8, source, start, "},").?;
    try std.testing.expect(std.mem.indexOf(u8, source[start..end], "syscallMemfdCreate(") != null);
    const tm = kt.tmpfs_source;
    const f = std.mem.indexOf(u8, tm, "pub fn tmpfsCreateAnonymous(").?;
    const f_end = std.mem.indexOfPos(u8, tm, f, "\n}\n").?;
    // born unlinked: never found by path, freed on the last close
    try std.testing.expect(std.mem.indexOf(u8, tm[f..f_end], "entries[idx].deleted = true;") != null);
}

test "LSM self-attribute syscalls keep the unsupported ENOSYS contract" {
    try std.testing.expectEqual(@as(i64, -38), kt.unsupported_policy.lsm());
    const source = kt.syscall_entry_source;
    for ([_][]const u8{ "459 => { // lsm_get_self_attr", "460 => { // lsm_set_self_attr", "461 => { // lsm_list_modules" }) |needle| {
        const start = std.mem.indexOf(u8, source, needle).?;
        const end = std.mem.indexOfPos(u8, source, start, "462 =>").?;
        const body = source[start..end];
        try std.testing.expect(std.mem.indexOf(u8, body, "unsupported_policy.lsm()") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "frame.rax = 0") == null);
    }
}

test "unsupported syscall dispatches route to the pure ENOSYS policy" {
    const source = kt.syscall_entry_source;
    try expectSourceRoute(source, "281 => { // acct(filename)", "282 => {", "unsupported_policy.acct()");
    try expectSourceRoute(source, "282 => { // unshare(flags)", "283 => {", "unsupported_policy.unshare()");
    try expectSourceRoute(source, "440 => { // process_madvise", "441 => {", "unsupported_policy.processMadvise()");
    try expectSourceRoute(source, "444 => { // landlock_create_ruleset", "445 => {", "unsupported_policy.landlock()");
    try expectSourceRoute(source, "445 => { // landlock_add_rule", "446 => {", "unsupported_policy.landlock()");
    try expectSourceRoute(source, "446 => { // landlock_restrict_self", "447 => {", "unsupported_policy.landlock()");
    try expectSourceRoute(source, "459 => { // lsm_get_self_attr", "460 => {", "unsupported_policy.lsm()");
    try expectSourceRoute(source, "460 => { // lsm_set_self_attr", "461 => {", "unsupported_policy.lsm()");
    try expectSourceRoute(source, "461 => { // lsm_list_modules", "462 => {", "unsupported_policy.lsm()");
    try expectSourceRoute(source, "462 => { // mseal", "463 => {", "mseal.zig\").sysMseal(");
    try expectSourceRoute(source, "295 => { // name_to_handle_at", "296 => {", "unsupported_policy.fileHandles()");
    try expectSourceRoute(source, "296 => { // open_by_handle_at", "297 => {", "unsupported_policy.fileHandles()");
    try std.testing.expectEqual(kt.errno.ENOSYS, unsupported_policy.fileHandles());
}

test "fallocate policy rejects unsupported modes before mutation" {
    try std.testing.expectEqual(@as(i64, 0), fallocate_policy.validate(0));
    try std.testing.expectEqual(fallocate_policy.EOPNOTSUPP, fallocate_policy.validate(1));
    try std.testing.expectEqual(fallocate_policy.EOPNOTSUPP, fallocate_policy.validate(0x400));
    try std.testing.expectEqual(fallocate_policy.EOPNOTSUPP, fallocate_policy.validate(0xFFFF_FFFF));
}

test "socketpair policy rejects unsupported combinations before allocation" {
    try std.testing.expectEqual(@as(i64, 0), socketpair_policy.validate(1, 1, 0));
    try std.testing.expectEqual(@as(i64, 0), socketpair_policy.validate(1, 1 | socketpair_policy.TYPE_FLAGS, 0));
    try std.testing.expectEqual(kt.errno.EINVAL, socketpair_policy.validate(2, 1, 0));
    try std.testing.expectEqual(kt.errno.EINVAL, socketpair_policy.validate(1, 1, 6));
    try std.testing.expectEqual(@as(i64, 0), socketpair_policy.validate(1, 2, 0)); // SOCK_DGRAM is supported since hello163
    try std.testing.expectEqual(kt.errno.EINVAL, socketpair_policy.validate(1, 9, 0)); // not a socket type
    try std.testing.expectEqual(kt.errno.EINVAL, socketpair_policy.validate(1, 1 | 0x400, 0));
}

test "message batch policy: vlen clamp, flags, WAITFORONE, results and timeout" {
    const mp = message_batch_policy;
    try std.testing.expectEqual(mp.MAX_MESSAGES, mp.clampVlen(5000));
    try std.testing.expectEqual(@as(u64, 3), mp.clampVlen(3));
    try std.testing.expectEqual(@as(i64, 0), mp.validateRecvFlags(mp.MSG_DONTWAIT | mp.MSG_WAITFORONE));
    try std.testing.expectEqual(kt.errno.EINVAL, mp.validateRecvFlags(0x1000_0000));
    try std.testing.expectEqual(@as(i64, 0), mp.validateSendFlags(mp.MSG_NOSIGNAL));
    try std.testing.expectEqual(kt.errno.EINVAL, mp.validateSendFlags(mp.MSG_WAITFORONE));
    try std.testing.expectEqual(@as(u32, 0), mp.messageFlags(mp.MSG_WAITFORONE, 0));
    try std.testing.expectEqual(mp.MSG_DONTWAIT, mp.messageFlags(mp.MSG_WAITFORONE, 1));
    try std.testing.expectEqual(@as(i64, 3), mp.batchResult(3, -11));
    try std.testing.expectEqual(@as(i64, -11), mp.batchResult(0, -11));
    try std.testing.expect(mp.timeoutDeadline(false, 0, 0, 5) == .none);
    try std.testing.expect(mp.timeoutDeadline(true, 0, 1_000_000_000, 5) == .invalid);
    try std.testing.expectEqual(@as(u64, 5 + 1_500_000_000), mp.timeoutDeadline(true, 1, 500_000_000, 5).deadline);
}

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

test "readahead policy plans bounded aligned page ranges" {
    const range = try readahead_policy.validate(4095, 2);
    try std.testing.expectEqual(@as(u64, 0), range.first_page);
    try std.testing.expectEqual(@as(u32, 2), range.page_count);

    const zero = try readahead_policy.validate(123, 0);
    try std.testing.expectEqual(@as(u32, 0), zero.page_count);
    try std.testing.expectError(error.InvalidOffset, readahead_policy.validate(std.math.maxInt(u64), 0));
    try std.testing.expectError(error.InvalidOffset, readahead_policy.validate(std.math.maxInt(u64), 1));
    try std.testing.expectError(error.TooManyPages, readahead_policy.validate(0, std.math.maxInt(u64)));
    try std.testing.expectError(error.TooManyPages, readahead_policy.validate(0, readahead_policy.MAX_PAGES * 4096 + 1));
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

test "openat2 policy validates size, dirfd, flags, mode, and resolve (a real dirfd is accepted)" {
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
        -5,
        .{ .flags = 0, .mode = 0, .resolve = 0 },
        openat2_policy.SIZE,
    ));
    try std.testing.expectEqual(@as(i64, 0), openat2_policy.validate(
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

test "mlock table: ranges merge, split, count pages and never exceed their capacity" {
    const T = mlock_policy.Table;
    var t = T{};
    // Pages are page numbers. Locking is idempotent and counts each page once.
    try std.testing.expect(t.lock(10, 4));
    try std.testing.expectEqual(@as(u64, 4), t.total());
    try std.testing.expect(t.lock(12, 4)); // overlaps 12..13, adds 14..15
    try std.testing.expectEqual(@as(u64, 6), t.total());
    try std.testing.expect(t.lock(16, 2)); // adjacent: merges into one range
    try std.testing.expectEqual(@as(usize, 1), t.count);
    try std.testing.expectEqual(@as(u64, 8), t.total());
    try std.testing.expectEqual(@as(u64, 3), t.overlapPages(8, 5)); // 10,11,12
    try std.testing.expectEqual(@as(u64, 0), t.overlapPages(20, 5));
    try std.testing.expect(t.contains(10) and t.contains(17));
    try std.testing.expect(!t.contains(9) and !t.contains(18));
    try std.testing.expect(t.covers(11, 3));
    try std.testing.expect(!t.covers(9, 3));
    // Releasing a hole in the middle splits the range in two.
    try std.testing.expect(t.release(12, 2));
    try std.testing.expectEqual(@as(usize, 2), t.count);
    try std.testing.expectEqual(@as(u64, 6), t.total());
    try std.testing.expect(!t.contains(12) and !t.contains(13));
    try std.testing.expect(t.contains(11) and t.contains(14));
    // Releasing from an end truncates; releasing everything empties.
    try std.testing.expect(t.release(10, 2));
    try std.testing.expect(t.release(14, 100));
    try std.testing.expectEqual(@as(usize, 0), t.count);
    try std.testing.expectEqual(@as(u64, 0), t.total());
    // Releasing what is not locked is fine.
    try std.testing.expect(t.release(500, 3));

    // Capacity: MAX_RANGES separate ranges fit, one more does not and leaves the table unchanged.
    var full = T{};
    var i: u64 = 0;
    while (i < mlock_policy.MAX_RANGES) : (i += 1) try std.testing.expect(full.lock(i * 10, 1));
    try std.testing.expect(!full.lock(1000, 1));
    try std.testing.expectEqual(@as(u64, mlock_policy.MAX_RANGES), full.total());
    // A lock that merges with an existing range needs no new slot even when full.
    try std.testing.expect(full.lock(1, 1)); // adjacent to the range at page 0
    // A hole that would split a range cannot be recorded when full: release reports it and changes nothing.
    var split = T{};
    try std.testing.expect(split.lock(100, 10));
    i = 1;
    while (i < mlock_policy.MAX_RANGES) : (i += 1) try std.testing.expect(split.lock(1000 + i * 10, 1));
    try std.testing.expectEqual(mlock_policy.MAX_RANGES, split.count);
    try std.testing.expect(!split.canRelease(103, 2));
    try std.testing.expect(!split.release(103, 2));
    try std.testing.expectEqual(@as(u64, 10 + mlock_policy.MAX_RANGES - 1), split.total());
    try std.testing.expect(split.canRelease(100, 2)); // an end needs no slot
    t = T{};
    t.clear();
    try std.testing.expectEqual(@as(usize, 0), t.count);
    // Zero-length operations touch nothing.
    try std.testing.expect(t.lock(5, 0));
    try std.testing.expectEqual(@as(usize, 0), t.count);
    try std.testing.expect(t.release(5, 0));
}

test "mlock table: a forced release keeps the left piece when a split has no free slot; moved() relocates locks transactionally" {
    const T = mlock_policy.Table;
    var t = T{};
    try std.testing.expect(t.lock(100, 10));
    var i: u64 = 1;
    while (i < mlock_policy.MAX_RANGES) : (i += 1) try std.testing.expect(t.lock(1000 + i * 10, 1));
    // No slot for the right-hand piece: the forced release drops it rather than failing.
    t.releaseLossy(103, 2);
    try std.testing.expectEqual(@as(usize, mlock_policy.MAX_RANGES), t.count);
    try std.testing.expect(t.contains(100) and t.contains(102));
    try std.testing.expect(!t.contains(103) and !t.contains(106));
    // With a free slot it splits exactly like release().
    var u = T{};
    try std.testing.expect(u.lock(100, 10));
    u.releaseLossy(103, 2);
    try std.testing.expect(u.contains(102) and !u.contains(103) and !u.contains(104) and u.contains(105) and u.contains(109));
    try std.testing.expectEqual(@as(u64, 8), u.total());

    // moved(): the locked pages of the old range reappear at the new address, the rest of the table is untouched.
    var m = T{};
    try std.testing.expect(m.lock(10, 2)); // 10,11
    try std.testing.expect(m.lock(13, 1)); // 13
    try std.testing.expect(m.lock(500, 4)); // elsewhere
    const moved = m.moved(10, 4, 200, 4).?;
    try std.testing.expect(moved.covers(200, 2) and !moved.contains(202) and moved.contains(203));
    try std.testing.expect(!moved.touches(10, 4));
    try std.testing.expect(moved.covers(500, 4));
    try std.testing.expectEqual(@as(u64, 7), moved.total());
    // The original is not modified (the caller commits only on success).
    try std.testing.expect(m.covers(10, 2) and m.contains(13));
    // A shrinking move keeps only what still fits.
    const shrunk = m.moved(10, 4, 200, 2).?;
    try std.testing.expect(shrunk.covers(200, 2) and !shrunk.contains(203));
    try std.testing.expectEqual(@as(u64, 6), shrunk.total());
    // No slots for the relocated pieces: null, and nothing changed.
    var full = T{};
    try std.testing.expect(full.lock(10, 2));
    try std.testing.expect(full.lock(13, 1));
    i = 0;
    while (full.count < mlock_policy.MAX_RANGES) : (i += 1) try std.testing.expect(full.lock(1000 + i * 10, 1));
    // The two old pieces free two slots before the two new ones are added, so a full table can still move.
    const ok = full.moved(10, 4, 200, 4).?;
    try std.testing.expectEqual(@as(usize, mlock_policy.MAX_RANGES), ok.count);
    try std.testing.expect(ok.covers(200, 2) and ok.contains(203));
    // Fan one old range out into two new pieces on a full table: 1 slot freed, 2 needed.
    var fan = T{};
    try std.testing.expect(fan.lock(10, 4));
    i = 0;
    while (fan.count < mlock_policy.MAX_RANGES) : (i += 1) try std.testing.expect(fan.lock(1000 + i * 10, 1));
    try std.testing.expect(fan.release(11, 1) == false); // splitting the range itself needs a slot too
    try std.testing.expectEqual(@as(usize, mlock_policy.MAX_RANGES), fan.count);
}

test "mlock is wired into reclaim, madvise and every path that removes or moves pages" {
    // swap reclaim must skip locked pages, inside the scan loop that picks victims.
    const swap_src = kt.swap_source;
    const scan = std.mem.indexOf(u8, swap_src, "fn reclaimScanPass") orelse return error.TestUnexpectedResult;
    const skip = std.mem.indexOf(u8, swap_src, "if (mm.locks.contains(virt_addr / 4096)) continue;") orelse return error.TestUnexpectedResult;
    const swap_out = std.mem.indexOfPos(u8, swap_src, scan, "if (swapOut(pml4_phys, virt_addr, &pt[pt_idx]))") orelse return error.TestUnexpectedResult;
    try std.testing.expect(skip > scan and skip < swap_out);
    // madvise refuses DONTNEED/FREE on a locked range before acting.
    try std.testing.expect(std.mem.indexOf(u8, kt.syscall_entry_source, "(advice == 4 or advice == 8) and @import(\"../../mm/mm.zig\").Mm.locked(") != null);
    // munmap, MAP_FIXED (two paths), mremap shrink and mremap move all adjust the table.
    const mm_src = kt.mmap_mlock_source;
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, mm_src, "m.locks.releaseLossy(")); // + the MREMAP_FIXED destination
    try std.testing.expect(std.mem.indexOf(u8, mm_src, "base_table.moved(") != null);
    try std.testing.expect(std.mem.indexOf(u8, mm_src, "m.locks = t;") != null);
}

test "Mm still fits the 1024-byte slab class after gaining the mlock table" {
    // Mm is kmalloc'ed. Past 1024 bytes the slab hands out a whole page per address space instead.
    try std.testing.expect(@sizeOf(kt.mm.Mm) <= 1024);
}

test "mlock limit rules follow Linux: EPERM only when there is no limit and no privilege, ENOMEM over the limit" {
    const mp = mlock_policy;
    const inf = std.math.maxInt(u64);
    // Linux can_do_mlock: CAP_IPC_LOCK or a non-zero RLIMIT_MEMLOCK.
    try std.testing.expect(!mp.mayAttempt(0, false));
    try std.testing.expect(mp.mayAttempt(0, true));
    try std.testing.expect(mp.mayAttempt(4096, false));
    try std.testing.expect(mp.mayAttempt(inf, false));
    // New total (already locked + request) against the limit in pages; pages already locked inside the request
    // are not charged twice.
    try std.testing.expect(mp.fitsLimit(2 * 4096, false, 0, 2, 0));
    try std.testing.expect(!mp.fitsLimit(2 * 4096, false, 0, 3, 0));
    try std.testing.expect(!mp.fitsLimit(2 * 4096, false, 2, 1, 0));
    try std.testing.expect(mp.fitsLimit(2 * 4096, false, 2, 2, 2)); // relocking what is locked
    try std.testing.expect(mp.fitsLimit(2 * 4096, false, 1, 2, 1)); // 1 locked inside the request: 1 + 2 - 1 = 2
    try std.testing.expect(!mp.fitsLimit(2 * 4096, false, 2, 2, 1)); // 2 + 2 - 1 = 3
    try std.testing.expect(mp.fitsLimit(2 * 4096, true, 2, 100, 0)); // CAP_IPC_LOCK ignores the limit
    try std.testing.expect(mp.fitsLimit(inf, false, 1 << 40, 1 << 20, 0));
    try std.testing.expect(mp.fitsLimit(4096 + 1, false, 0, 1, 0)); // the limit rounds down to whole pages
    try std.testing.expect(!mp.fitsLimit(4095, false, 0, 1, 0));
}

test "mlock2 flags: only MLOCK_ONFAULT is accepted, and the flag check precedes every other check" {
    const mp = mlock_policy;
    try std.testing.expect(mp.mlock2FlagsValid(0));
    try std.testing.expect(mp.mlock2FlagsValid(mp.MLOCK_ONFAULT));
    try std.testing.expect(!mp.mlock2FlagsValid(2));
    try std.testing.expect(!mp.mlock2FlagsValid(3));
    try std.testing.expect(!mp.mlock2FlagsValid(0x100));
    try std.testing.expect(!mp.mlock2FlagsValid(0xFFFF_FFFF));
    try std.testing.expectEqual(@as(u32, 1), mp.MLOCK_ONFAULT);
    // The syscall truncates the flags register to 32 bits like the kernel's unsigned int argument, then
    // validates before touching the limit gate, the range, or the table.
    const ml = kt.mlock_source;
    const flags_check = std.mem.indexOf(u8, ml, "if (!policy.mlock2FlagsValid(@truncate(flags))) return -22;") orelse return error.TestUnexpectedResult;
    const gate = std.mem.indexOfPos(u8, ml, flags_check, "if (!policy.mayAttempt(") orelse return error.TestUnexpectedResult;
    try std.testing.expect(flags_check < gate);
    try std.testing.expect(std.mem.indexOf(u8, kt.syscall_entry_source, "496 => { // mlock2(addr, len, flags)") != null);
}

test "mlock table: canLock predicts lock() exactly, including against a full table" {
    const T = mlock_policy.Table;
    var t = T{};
    try std.testing.expect(t.canLock(5, 3)); // empty table
    var i: u64 = 0;
    while (i < mlock_policy.MAX_RANGES) : (i += 1) try std.testing.expect(t.lock(1000 + i * 10, 2));
    try std.testing.expectEqual(@as(usize, mlock_policy.MAX_RANGES), t.count);
    // Full table: a new disjoint range needs a slot and has none; touching or overlapping one needs none.
    try std.testing.expect(!t.canLock(5, 3));
    try std.testing.expect(!t.canLock(1004, 2)); // gap of 2 pages after 1000..1001 and before 1010
    try std.testing.expect(t.canLock(1002, 2)); // adjacent to 1000..1001: merges
    try std.testing.expect(t.canLock(1001, 1)); // already inside
    try std.testing.expect(t.canLock(998, 2)); // ends where 1000 starts: merges
    try std.testing.expect(t.canLock(5, 0)); // nothing to lock
    // And the prediction agrees with the real thing, without changing the table when it says no.
    const before = t;
    try std.testing.expect(!t.lock(5, 3));
    try std.testing.expectEqual(before.count, t.count);
    try std.testing.expectEqual(before.total(), t.total());
    try std.testing.expect(t.lock(1002, 2));
}

test "mapGate: MAP_LOCKED needs the privilege/limit gate, a locking mapping must fit RLIMIT_MEMLOCK (EAGAIN, not ENOMEM)" {
    const mp = mlock_policy;
    const inf = std.math.maxInt(u64);
    // Neither MAP_LOCKED nor MCL_FUTURE: nothing is checked, whatever the limit is.
    try std.testing.expectEqual(mp.Gate.ok, mp.mapGate(false, false, 0, false, 1 << 30, 1 << 30));
    // MAP_LOCKED with a zero limit and no CAP_IPC_LOCK: EPERM, before the quota is looked at.
    try std.testing.expectEqual(mp.Gate.eperm, mp.mapGate(true, false, 0, false, 0, 1));
    try std.testing.expectEqual(mp.Gate.ok, mp.mapGate(true, false, 0, true, 0, 1)); // the capability lifts it
    // MCL_FUTURE alone never reports EPERM (Linux only asks can_do_mlock for MAP_LOCKED): a zero limit is EAGAIN.
    try std.testing.expectEqual(mp.Gate.eagain, mp.mapGate(false, true, 0, false, 0, 1));
    // Quota: locked + new <= limit in pages (limit rounds down), measured: 8 + 9 > 16 but 8 + 8 = 16.
    try std.testing.expectEqual(mp.Gate.ok, mp.mapGate(false, true, 16 * 4096, false, 8, 8));
    try std.testing.expectEqual(mp.Gate.eagain, mp.mapGate(false, true, 16 * 4096, false, 8, 9));
    try std.testing.expectEqual(mp.Gate.ok, mp.mapGate(true, false, 16 * 4096, false, 16, 0));
    try std.testing.expectEqual(mp.Gate.eagain, mp.mapGate(true, false, 16 * 4096, false, 16, 1));
    try std.testing.expectEqual(mp.Gate.ok, mp.mapGate(false, true, 16 * 4096 + 4095, false, 0, 16)); // rounds down
    try std.testing.expectEqual(mp.Gate.eagain, mp.mapGate(false, true, 16 * 4096 + 4095, false, 0, 17));
    // Unlimited and privileged callers always fit; a huge request cannot wrap around the sum.
    try std.testing.expectEqual(mp.Gate.ok, mp.mapGate(true, true, inf, false, 1 << 40, 1 << 20));
    try std.testing.expectEqual(mp.Gate.ok, mp.mapGate(true, true, 4096, true, 1 << 40, 1 << 20));
    try std.testing.expectEqual(mp.Gate.eagain, mp.mapGate(false, true, 4096, false, std.math.maxInt(u64), 1));
}

test "growGate: growing a locked mapping must fit RLIMIT_MEMLOCK (EAGAIN); an unlocked one grows freely" {
    const mp = mlock_policy;
    // Measured: limit 16 pages, 12 locked, grow by 8 -> EAGAIN; by 4 -> fine.
    try std.testing.expectEqual(mp.Gate.eagain, mp.growGate(true, 16 * 4096, false, 12, 8));
    try std.testing.expectEqual(mp.Gate.ok, mp.growGate(true, 16 * 4096, false, 12, 4));
    try std.testing.expectEqual(mp.Gate.eagain, mp.growGate(true, 16 * 4096, false, 12, 5));
    // A mapping whose tail is not locked is never gated, however far over the limit the address space is.
    try std.testing.expectEqual(mp.Gate.ok, mp.growGate(false, 0, false, 1 << 30, 1 << 30));
    // The privileged are not limited, and a zero limit is EAGAIN, never EPERM (only MAP_LOCKED reports EPERM).
    try std.testing.expectEqual(mp.Gate.ok, mp.growGate(true, 0, true, 1 << 30, 1 << 30));
    try std.testing.expectEqual(mp.Gate.eagain, mp.growGate(true, 0, false, 0, 1));
}

test "mlockall(MCL_CURRENT) fits when everything mapped is within the limit; the privileged are not limited" {
    const mp = mlock_policy;
    const inf = std.math.maxInt(u64);
    try std.testing.expect(mp.currentFits(16 * 4096, false, 16));
    try std.testing.expect(!mp.currentFits(16 * 4096, false, 17));
    try std.testing.expect(mp.currentFits(16 * 4096 + 4095, false, 16));
    try std.testing.expect(!mp.currentFits(0, false, 1));
    try std.testing.expect(mp.currentFits(0, false, 0));
    try std.testing.expect(mp.currentFits(0, true, 1 << 30));
    try std.testing.expect(mp.currentFits(inf, false, 1 << 40));
}

test "mlockall and MAP_LOCKED are wired into mmap, brk, mremap and the syscall table" {
    const ml = kt.mlock_source;
    try std.testing.expect(std.mem.indexOf(u8, ml, "pub fn mlockall(flags: u32) i64 {") != null);
    // Validation and privilege come first, the limit check precedes the commit, FUTURE is recorded last.
    const valid = std.mem.indexOf(u8, ml, "range_policy.mlockallFlagsValid(flags)") orelse return error.TestUnexpectedResult;
    const gate = std.mem.indexOfPos(u8, ml, valid, "policy.mayAttempt(") orelse return error.TestUnexpectedResult;
    const fits = std.mem.indexOfPos(u8, ml, gate, "policy.currentFits(") orelse return error.TestUnexpectedResult;
    const commit = std.mem.indexOfPos(u8, ml, fits, "mm.locks = next;") orelse return error.TestUnexpectedResult;
    const future = std.mem.indexOfPos(u8, ml, commit, "mm.lock_future = ") orelse return error.TestUnexpectedResult;
    try std.testing.expect(valid < gate and gate < fits and fits < commit and commit < future);
    // munlockall also forgets MCL_FUTURE.
    const unl = std.mem.indexOf(u8, ml, "pub fn munlockall() i64 {") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOfPos(u8, ml, unl, "mm.lock_future = false;") != null);
    // mmap: the gate runs before a MAP_FIXED replacement is touched (fixed branch) and after base selection (other
    // branch), and every successful mapping is recorded in the table.
    const mm_src = kt.mmap_mlock_source;
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, mm_src, "mlock_gate.mapGate("));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, mm_src, "mlock_gate.recordLocked("));
    const fixed_gate = std.mem.indexOf(u8, mm_src, "const fixed_gate = mlock_gate.mapGate(") orelse return error.TestUnexpectedResult;
    const first_unmap = std.mem.indexOfPos(u8, mm_src, fixed_gate, "unmapRange(cur, base, num_pages);") orelse return error.TestUnexpectedResult;
    try std.testing.expect(fixed_gate < first_unmap); // the gate runs before a MAP_FIXED replacement touches anything
    // mremap growth of a locked mapping is gated (EAGAIN) and extends the lock only after the call succeeded.
    const grow = std.mem.indexOf(u8, mm_src, "mlock_gate.growGate(") orelse return error.TestUnexpectedResult;
    const call = std.mem.indexOfPos(u8, mm_src, grow, "const result = mremapRegion(") orelse return error.TestUnexpectedResult;
    const record = std.mem.indexOfPos(u8, mm_src, call, "mlock_gate.recordLocked(") orelse return error.TestUnexpectedResult;
    try std.testing.expect(grow < call and call < record);
    // brk: growth under MCL_FUTURE is gated, a shrink releases the locks of the pages it gives back.
    const brk_src = kt.brk_source;
    try std.testing.expect(std.mem.indexOf(u8, brk_src, "mlock_gate.mapGate(") != null);
    try std.testing.expect(std.mem.indexOf(u8, brk_src, "m.locks.releaseLossy(") != null);
    // The flag lives in Mm and every new address space starts without it.
    try std.testing.expect(std.mem.indexOf(u8, kt.mm_source, "lock_future: bool = false,") != null);
    try std.testing.expect(@sizeOf(kt.mm.Mm) <= 1024);
    try std.testing.expect(!kt.mm.Mm.futureLocking(null));
}

test "mremap(MREMAP_FIXED) moves the mapping even when it does not grow; the in-place shrink path must not swallow it" {
    // Measured on Linux: same-size and shrinking MREMAP_FIXED both move the mapping to new_addr (contents kept, the
    // whole old range unmapped). The in-place shrink block returns old_addr, so the FIXED case has to be routed to the
    // move path before it.
    const src = kt.mmap_mlock_source;
    const fn_start = std.mem.indexOf(u8, src, "fn mremapRegion(") orelse return error.TestUnexpectedResult;
    const route = std.mem.indexOfPos(u8, src, fn_start, "if ((mflags & MREMAP_FIXED) != 0 and new_pages <= old_pages) {") orelse return error.TestUnexpectedResult;
    const shrink = std.mem.indexOfPos(u8, src, fn_start, "if (new_pages <= old_pages) {") orelse return error.TestUnexpectedResult;
    try std.testing.expect(route < shrink);
    const body = src[route..shrink];
    try std.testing.expect(std.mem.indexOf(u8, body, "moveOrNoMem(") != null);
    // A file-backed region cannot be moved (it would be unshared), same refusal as the growing path.
    try std.testing.expect(std.mem.indexOf(u8, body, "if (r.file_kind != 0) return -12;") != null);
}

test "mremap(MREMAP_FIXED) onto existing mappings replaces them, like MAP_FIXED, after every refusing check" {
    // Measured on Linux: the destination of MREMAP_FIXED may already be mapped; it is unmapped and the source takes
    // its place. Mappings that cannot be taken (device/no_free, SysV SHM, untracked image/stack/brk pages, or no
    // region slot for a split) are refused before anything changes, exactly as for MAP_FIXED (fixedReplaceable).
    const src = kt.mmap_mlock_source;
    const fn_start = std.mem.indexOf(u8, src, "fn moveOrNoMem(") orelse return error.TestUnexpectedResult;
    const fn_end = std.mem.indexOfPos(u8, src, fn_start, "\nconst PAGE_SZ") orelse return error.TestUnexpectedResult;
    const body = src[fn_start..fn_end];
    const taken = std.mem.indexOf(u8, body, "if (!fixedReplaceable(task, new_base, new_pages)) return -12;") orelse return error.TestUnexpectedResult;
    const unmap = std.mem.indexOfPos(u8, body, taken, "unmapRange(task, new_base, new_pages);") orelse return error.TestUnexpectedResult;
    const untrack = std.mem.indexOfPos(u8, body, unmap, "untrackMmapRange(task, new_base, new_pages);") orelse return error.TestUnexpectedResult;
    const locks = std.mem.indexOfPos(u8, body, untrack, "m.locks.releaseLossy(new_base / PAGE_SZ, new_pages)") orelse return error.TestUnexpectedResult;
    const mv = std.mem.indexOfPos(u8, body, locks, "const moved_to = moveMapping(") orelse return error.TestUnexpectedResult;
    try std.testing.expect(taken < unmap and unmap < untrack and untrack < locks and locks < mv);
    // Every check that can refuse (charges, the relocated lock table) runs before the destination is unmapped.
    const charges = std.mem.indexOf(u8, body, "if (!moveChargesOk(task, region, old_pages, new_pages)) return -12;") orelse return error.TestUnexpectedResult;
    const reloc = std.mem.indexOf(u8, body, "base_table.moved(") orelse return error.TestUnexpectedResult;
    try std.testing.expect(charges < unmap and reloc < unmap);
    // Only for MREMAP_FIXED: a kernel-chosen destination is still searched in free space.
    try std.testing.expect(std.mem.indexOf(u8, body[0..taken], "(mflags & MREMAP_FIXED) != 0") != null);
    // The overlap-with-self refusal stays ahead of any replacement.
    const selfov = std.mem.indexOf(u8, body, "if (rangesOverlap(region.base, old_pages, new_base, new_pages)) return -22;") orelse return error.TestUnexpectedResult;
    try std.testing.expect(selfov < taken);
}

test "mremap on a sub-range: the region is split so the range becomes a whole region (head, middle, tail)" {
    const mp = kt.mremap_policy;
    const HUGE = 512;
    // A range strictly inside an 8 page region at page 0x1000: pages 2..4 of 0..7.
    const a = mp.plan(0x1000, 8, 0, 0x1000 + 2, 3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 2), a.head_pages);
    try std.testing.expectEqual(@as(u64, 3), a.mid_pages);
    try std.testing.expectEqual(@as(u64, 3), a.tail_pages);
    // New region-table slots: one for the middle (the original stays as the head) and one for the tail.
    try std.testing.expectEqual(@as(u32, 2), a.extraSlots());
    // A range at the start of the region: the original becomes the middle, only the tail is new.
    const b = mp.plan(0x1000, 8, 0, 0x1000, 3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0), b.head_pages);
    try std.testing.expectEqual(@as(u64, 5), b.tail_pages);
    try std.testing.expectEqual(@as(u32, 1), b.extraSlots());
    // A range that ends where the region ends: the head stays, the middle is new, there is no tail.
    const c = mp.plan(0x1000, 8, 0, 0x1000 + 5, 3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 5), c.head_pages);
    try std.testing.expectEqual(@as(u64, 0), c.tail_pages);
    try std.testing.expectEqual(@as(u32, 1), c.extraSlots());
    // The whole region: nothing to split.
    const d = mp.plan(0x1000, 8, 0, 0x1000, 8) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0), d.extraSlots());
    try std.testing.expect(!d.needed());
    try std.testing.expect(a.needed() and b.needed() and c.needed());
    // Not inside the region: no plan (the caller keeps its existing errors).
    try std.testing.expect(mp.plan(0x1000, 8, 0, 0x1000 - 1, 3) == null); // starts before it
    try std.testing.expect(mp.plan(0x1000, 8, 0, 0x1000 + 6, 3) == null); // runs past its end
    try std.testing.expect(mp.plan(0x1000, 8, 0, 0x1000 + 8, 1) == null); // starts at its end
    try std.testing.expect(mp.plan(0x1000, 8, 0, 0x1000, 0) == null); // empty
    try std.testing.expect(mp.plan(std.math.maxInt(u64) - 2, 8, 0, std.math.maxInt(u64) - 1, 2) == null); // no wraparound
    // Huge blocks sit at the start of a region (huge-first): the head keeps the whole blocks it still covers, the middle
    // only when the head is empty, the tail never.
    const h1 = mp.plan(0x2000, 2 * HUGE, 2, 0x2000 + HUGE, HUGE) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 1), h1.head_huge);
    try std.testing.expectEqual(@as(u32, 0), h1.mid_huge);
    try std.testing.expectEqual(@as(u32, 0), h1.tail_huge);
    const h2 = mp.plan(0x2000, 2 * HUGE, 2, 0x2000, HUGE) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0), h2.head_huge);
    try std.testing.expectEqual(@as(u32, 1), h2.mid_huge);
    try std.testing.expectEqual(@as(u32, 0), h2.tail_huge);
    // A block the cut runs through is not counted by the head.
    const h3 = mp.plan(0x2000, 2 * HUGE, 2, 0x2000 + 10, 20) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0), h3.head_huge);
    // Two adjacent pieces can be merged back only when they agree on everything that matters.
    try std.testing.expect(mp.canCoalesce(.{ .prot = 3, .shared = false, .may_write = true, .file_kind = 0, .no_free = false, .locked = false, .huge_pages = 0 },
        .{ .prot = 3, .shared = false, .may_write = true, .file_kind = 0, .no_free = false, .locked = false, .huge_pages = 0 }));
    try std.testing.expect(!mp.canCoalesce(.{ .prot = 3, .shared = false, .may_write = true, .file_kind = 0, .no_free = false, .locked = false, .huge_pages = 0 },
        .{ .prot = 1, .shared = false, .may_write = true, .file_kind = 0, .no_free = false, .locked = false, .huge_pages = 0 }));
    try std.testing.expect(!mp.canCoalesce(.{ .prot = 3, .shared = true, .may_write = true, .file_kind = 0, .no_free = false, .locked = false, .huge_pages = 0 },
        .{ .prot = 3, .shared = false, .may_write = true, .file_kind = 0, .no_free = false, .locked = false, .huge_pages = 0 }));
    try std.testing.expect(!mp.canCoalesce(.{ .prot = 3, .shared = false, .may_write = true, .file_kind = 2, .no_free = false, .locked = false, .huge_pages = 0 },
        .{ .prot = 3, .shared = false, .may_write = true, .file_kind = 2, .no_free = false, .locked = false, .huge_pages = 0 })); // file pieces are not merged
    try std.testing.expect(!mp.canCoalesce(.{ .prot = 3, .shared = false, .may_write = true, .file_kind = 0, .no_free = true, .locked = false, .huge_pages = 0 },
        .{ .prot = 3, .shared = false, .may_write = true, .file_kind = 0, .no_free = true, .locked = false, .huge_pages = 0 }));
    try std.testing.expect(!mp.canCoalesce(.{ .prot = 3, .shared = false, .may_write = true, .file_kind = 0, .no_free = false, .locked = false, .huge_pages = 1 },
        .{ .prot = 3, .shared = false, .may_write = true, .file_kind = 0, .no_free = false, .locked = false, .huge_pages = 0 }));
    try std.testing.expect(!mp.canCoalesce(.{ .prot = 3, .shared = false, .may_write = true, .file_kind = 0, .no_free = false, .locked = true, .huge_pages = 0 },
        .{ .prot = 3, .shared = false, .may_write = true, .file_kind = 0, .no_free = false, .locked = false, .huge_pages = 0 }));
}

test "mremap splits the region before it looks for one that starts at old_addr, and merges the pieces back on failure" {
    const src = kt.mmap_mlock_source;
    const fn_start = std.mem.indexOf(u8, src, "fn mremapRegion(") orelse return error.TestUnexpectedResult;
    const preflight = std.mem.indexOfPos(u8, src, fn_start, "if (plan.extraSlots() > free_slots) return -12;") orelse return error.TestUnexpectedResult;
    const split = std.mem.indexOfPos(u8, src, fn_start, "splitRegionForRange(cur, idx, plan, old_addr)") orelse return error.TestUnexpectedResult;
    const exact = std.mem.indexOfPos(u8, src, split, "mremapExact(cur, old_addr, old_pages, new_pages, mflags, new_addr_hint)") orelse return error.TestUnexpectedResult;
    const back = std.mem.indexOfPos(u8, src, exact, "coalesceAround(cur,") orelse return error.TestUnexpectedResult;
    // The free-slot preflight happens before the first change, the split before the whole-region logic, and the merge
    // runs after it whatever its result was (it is not inside an `if (result >= 0)`).
    try std.testing.expect(fn_start < preflight and preflight < split and split < exact and exact < back);
    try std.testing.expect(std.mem.indexOf(u8, src[exact..back], "if (result") == null);
    // File-backed and device regions are not split (their backing references and fault metadata stay whole-region).
    try std.testing.expect(std.mem.indexOf(u8, src[fn_start..preflight], "r.file_kind == 0 and !r.no_free") != null);
    // The pure policy owns the layout.
    try std.testing.expect(std.mem.indexOf(u8, src, "mremap_policy.plan(") != null);
}

test "MAP_LOCKED is a real mmap flag now: it is accepted, and acted on rather than ignored" {
    try std.testing.expect(mmap_policy.flagsValid(mmap_policy.MAP_PRIVATE | mmap_policy.MAP_ANONYMOUS | mmap_policy.MAP_LOCKED));
    try std.testing.expectEqual(@as(u64, 0x2000), mmap_policy.MAP_LOCKED);
    try std.testing.expect((mmap_policy.HINT_FLAGS & mmap_policy.MAP_LOCKED) == 0);
}

test "lockSpan counts the page an unaligned zero-length range starts in, like Linux" {
    const rp = kt.range_policy;
    try std.testing.expectEqual(rp.Span.empty, rp.lockSpan(0x30000000, 0));
    try std.testing.expectEqual(rp.Span{ .pages = 1 }, rp.lockSpan(0x30000064, 0));
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

test "POSIX MQ uses per-open descriptions and validates descriptor semantics" {
    const source = kt.posix_mq_source;
    try std.testing.expect(std.mem.indexOf(u8, source, "var descriptions:") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "var task_handles:") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "q.fd") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "q.flags") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "return EMSGSIZE") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "closeCloexecForTask") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "newattr_ptr >= 0x0000_8000_0000_0000") != null);
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
        "file_io_mod.openAt(dirfdArg(frame.rdi), frame.rsi, @truncate(frame.rdx), @truncate(frame.r10))",
    );
    try expectSourceRoute(
        source,
        "257 => { // mkdirat(dirfd, pathname, mode)",
        "258 => { // faccessat",
        "dir_ops_mod.mkdirAt(dirfdArg(frame.rdi), frame.rsi, @truncate(frame.rdx))",
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
        ".tmpfs_file => {",
        ".rofs_file => switch",
        "tmpfsGetMetadata(@intCast(d.tmpfs_idx))",
    );
    try std.testing.expect(std.mem.indexOf(u8, kt.statx_source, "if (m.is_dir) @as(u32, 0o040000) else 0o100000") != null);
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
    const create = std.mem.indexOf(u8, kt.signal_syscall_source, "eventfdCreate(0, false)") orelse return error.TestUnexpectedResult;
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

test "DAC: CAP_DAC_OVERRIDE bypasses mode denial, uid 0 alone does not" {
    const meta: dac.Metadata = .{ .mode = 0, .uid = 10, .gid = 20 };

    try std.testing.expect(dac.allows(meta, .{ .euid = 0, .egid = 30, .cap_dac_override = true }, .read_write));
    try std.testing.expect(!dac.allows(meta, .{ .euid = 0, .egid = 30 }, .read));
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
    // statx and access resolve their paths through at_path (a volume directory
    // fd or cwd may rewrite the name) but must retain the caller's credentials.
    const forwarding = "openWithCredentials(use_name, 0, cur.euid, cur.egid, cur.effective_caps)";
    try std.testing.expect(std.mem.indexOf(u8, kt.statx_source, "openWithCredentials(use_name, open_flags, cur.euid, cur.egid, cur.effective_caps)") != null);
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
    // hello15 drives the legacy port-addressed UDP calls, which need CAP_NET_RAW
    const hello15 = capability_profile.profileForLaunch("hello15", true, false).caps;
    try std.testing.expectEqual(@as(u32, @bitCast(hello14)), @as(u32, @bitCast(hello15)));

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

test "only the realtime acceptance tests receive CAP_SYS_NICE" {
    inline for ([_][]const u8{ "hello44", "hello104", "hello108" }) |name| {
        const caps = capability_profile.profileForLaunch(name, true, false).caps;
        try std.testing.expect(caps.cap_sys_nice);
        try std.testing.expectEqual(@as(u32, 1), @popCount(@as(u32, @bitCast(caps))));
        try std.testing.expect(!capability_profile.profileForLaunch(name, false, false).caps.cap_sys_nice);
    }
    try std.testing.expect(!capability_profile.profileForLaunch("hello80", true, false).caps.cap_sys_nice);
}

test "scheduler calls: owner may change non-RT policy, RT and other users need CAP_SYS_NICE" {
    const np = kt.nice_policy;
    try std.testing.expect(np.maySetScheduling(1000, 1000, 1000, 1000, false, false));
    try std.testing.expect(!np.maySetScheduling(1000, 1000, 1000, 1000, false, true));
    try std.testing.expect(np.maySetScheduling(1000, 1000, 1000, 1000, true, true));
    try std.testing.expect(!np.maySetScheduling(1000, 1000, 0, 0, false, false));
    try std.testing.expect(!np.maySetScheduling(0, 0, 1000, 1000, false, true)); // uid 0 without CAP_SYS_NICE
    try std.testing.expect(np.maySetScheduling(0, 0, 1000, 1000, true, true));
    try std.testing.expect(np.mayKcmp(1000, 1000, 1000, 1000, false));
    try std.testing.expect(!np.mayKcmp(1000, 1000, 0, 0, false));
    try std.testing.expect(np.mayKcmp(1000, 1000, 0, 0, true));
}

test "only the swap acceptance tests receive CAP_SYS_ADMIN" {
    inline for ([_][]const u8{ "hello96", "hello98", "hello99", "hello100", "hello101" }) |name| {
        const caps = capability_profile.profileForLaunch(name, true, false).caps;
        try std.testing.expect(caps.cap_sys_admin);
        try std.testing.expectEqual(@as(u32, 1), @popCount(@as(u32, @bitCast(caps))));
        try std.testing.expect(!capability_profile.profileForLaunch(name, false, false).caps.cap_sys_admin);
    }
    try std.testing.expect(!capability_profile.profileForLaunch("hello80", true, false).caps.cap_sys_admin);
    try std.testing.expect(!capability_profile.profileForLaunch("hello114", true, false).caps.cap_sys_admin);
}

test "untrusted callers cannot receive named profiles" {
    inline for ([_][]const u8{ "hello14", "hello15", "hello51", "hello52", "hello54", "hello13", "hello58" }) |name| {
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

test "dns query wait expires on TSC time or an iteration backstop, never on timer ticks alone" {
    const dp = kt.dns_policy;
    // Within a system call the timer interrupt does not run (SFMASK clears IF), so a tick-based deadline never
    // expires; the wait is bounded by real time from the TSC, plus a hard cap on iterations in case it is unreadable.
    try std.testing.expectEqual(@as(u64, 2_000_000_000), dp.QUERY_TIMEOUT_NS);
    try std.testing.expect(!dp.waitExpired(1_000, 1_000, 0));
    try std.testing.expect(!dp.waitExpired(1_000, 1_000 + dp.QUERY_TIMEOUT_NS - 1, 10));
    try std.testing.expect(dp.waitExpired(1_000, 1_000 + dp.QUERY_TIMEOUT_NS, 10));
    try std.testing.expect(dp.waitExpired(1_000, 1_000 + 3 * dp.QUERY_TIMEOUT_NS, 10));
    // A clock that does not move (nanos() is 0 until the TSC is calibrated) is bounded by the iteration cap.
    try std.testing.expect(!dp.waitExpired(0, 0, dp.MAX_POLL_ITERS - 1));
    try std.testing.expect(dp.waitExpired(0, 0, dp.MAX_POLL_ITERS));
    // The clock counter wrapping does not make the wait last forever or expire at once.
    try std.testing.expect(!dp.waitExpired(std.math.maxInt(u64) - 5, 10, 0));
    try std.testing.expect(dp.waitExpired(std.math.maxInt(u64) - 5, 10 + dp.QUERY_TIMEOUT_NS, 0));
    // Wiring: neither wait loop in queryDns consults the tick counter any more.
    const src = kt.dns_source;
    const q = std.mem.indexOf(u8, src, "fn queryDns(") orelse return error.TestUnexpectedResult;
    const body = src[q .. q + 5000];
    try std.testing.expect(std.mem.indexOf(u8, body, "getTickCount") == null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, "dns_policy.waitExpired("));
}

test "tcp receiver accepts no more payload than the window it advertised" {
    const u = tcp_util;
    // room = window cap minus what is already buffered, saturating at 0
    try std.testing.expectEqual(@as(u32, 16384), u.acceptableBytes(100000, 0, 16384));
    try std.testing.expectEqual(@as(u32, 1448), u.acceptableBytes(1448, 0, 16384));
    try std.testing.expectEqual(@as(u32, 455), u.acceptableBytes(1448, 15929, 16384));
    try std.testing.expectEqual(@as(u32, 0), u.acceptableBytes(1448, 16384, 16384));
    // a sender that kept sending after a zero window must not be accepted (hello174's failing trace: 17377 buffered)
    try std.testing.expectEqual(@as(u32, 0), u.acceptableBytes(1448, 17377, 16384));
    try std.testing.expectEqual(@as(u32, 0), u.acceptableBytes(452, 18825, 16384));
    // a zero-window probe byte is not accepted either
    try std.testing.expectEqual(@as(u32, 0), u.acceptableBytes(1, 16384, 16384));
    // never more than was sent, and a zero-length segment accepts nothing
    try std.testing.expectEqual(@as(u32, 0), u.acceptableBytes(0, 0, 16384));
    try std.testing.expectEqual(@as(u32, 10), u.acceptableBytes(10, 0, 32768));
    // wired into the receive path: the copy length comes from the advertised cap, not the ring size
    const src = kt.tcp_source;
    const start = std.mem.indexOf(u8, src, "fn processIncomingData(") orelse return error.TestUnexpectedResult;
    const body = src[start .. start + 6000];
    try std.testing.expect(std.mem.indexOf(u8, body, "tcp_util.acceptableBytes(len, ringDataLen(tcb.recv_head, tcb.recv_tail, RECV_BUF_SIZE), rcvWindowCap(tcb));\n    const to_copy = @min(window_room, recv_free);") != null);
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

test "pause() and sigsuspend() share one wait for a deliverable signal, and gettid() names the calling thread" {
    // pause() used to reschedule once and return -EINTR whatever happened, so a program that paused for a signal ran on at
    // once (hello225 saw the handler had not run, and the call returned after ~0 ms instead of ~1 s).
    const ss = kt.signal_syscall_source;
    try std.testing.expect(std.mem.indexOf(u8, ss, "pub fn waitForSignal(cur_idx: u32, cur: *task_mod.Task) void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, ss, "pub fn pause() i64 {") != null);
    // sigsuspend's wait loop is the shared helper, not a second copy
    const sus = std.mem.indexOf(u8, ss, "pub fn rtSigsuspend").?;
    const sus_end = std.mem.indexOf(u8, ss[sus..], "\n}\n").? + sus;
    try std.testing.expect(std.mem.indexOf(u8, ss[sus..sus_end], "waitForSignal(cur_idx, cur);") != null);
    try std.testing.expect(std.mem.indexOf(u8, ss[sus..sus_end], "task_mod.blockTask") == null);
    // the dispatcher calls pause() and delivers the signal before returning, like sigsuspend
    const se = kt.syscall_entry_source;
    const p34 = std.mem.indexOf(u8, se, "34 => { // pause()").?;
    const p34_end = std.mem.indexOf(u8, se[p34..], "},").? + p34;
    try std.testing.expect(std.mem.indexOf(u8, se[p34..p34_end], "signal_syscall_mod.pause()") != null);
    try std.testing.expect(std.mem.indexOf(u8, se[p34..p34_end], "checkSignalsOnSyscallReturn(frame);") != null);
    try std.testing.expect(std.mem.indexOf(u8, se[p34..p34_end], "forceReschedule") == null);
    // gettid: syscall 497, the calling task's own tid (getpid returns the thread group id)
    try std.testing.expect(std.mem.indexOf(u8, se, "497 => { // gettid()") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.process_mgmt_source, "pub fn gettid() i64 {") != null);
}

test "lo queue counts frames queued, delivered, dropped and its high-water mark" {
    var q = lo.LoopbackQueue.init();
    const frame = [_]u8{0x42} ** 64;
    var out: [lo.MAX_FRAME]u8 = undefined;
    var s = q.stats();
    try std.testing.expectEqual(@as(u64, 0), s.queued);
    try std.testing.expectEqual(@as(u64, 0), s.delivered);
    try std.testing.expectEqual(@as(u64, 0), s.dropped);
    try std.testing.expectEqual(@as(u32, 0), s.high_water);

    var i: u32 = 0;
    while (i < 5) : (i += 1) try std.testing.expect(q.enqueue(&frame));
    s = q.stats();
    try std.testing.expectEqual(@as(u64, 5), s.queued);
    try std.testing.expectEqual(@as(u32, 5), s.high_water);
    _ = q.dequeue(&out);
    _ = q.dequeue(&out);
    s = q.stats();
    try std.testing.expectEqual(@as(u64, 2), s.delivered);
    try std.testing.expectEqual(@as(u32, 5), s.high_water); // the peak is kept after the queue shrinks

    // fill it: queued counts only accepted frames, dropped counts the refused ones, the peak is the capacity
    while (q.pending() < lo.QUEUE_DEPTH) try std.testing.expect(q.enqueue(&frame));
    try std.testing.expect(!q.enqueue(&frame));
    try std.testing.expect(!q.enqueue(&frame));
    try std.testing.expect(!q.enqueue(&frame));
    s = q.stats();
    try std.testing.expectEqual(@as(u64, 3), s.dropped);
    try std.testing.expectEqual(lo.QUEUE_DEPTH, s.high_water);
    try std.testing.expectEqual(@as(u64, 5 + (lo.QUEUE_DEPTH - 3)), s.queued);
    try std.testing.expectEqual(@as(u32, lo.QUEUE_DEPTH), s.depth);
    // an empty or oversized frame is refused without being counted as a congestion drop
    try std.testing.expect(!q.enqueue(&[_]u8{}));
    try std.testing.expectEqual(@as(u64, 3), q.stats().dropped);
}

test "the loopback statistics are formatted as one line of name=value pairs" {
    var buf: [256]u8 = undefined;
    const n = lo.formatStats(.{ .queued = 12345, .delivered = 12000, .dropped = 7, .high_water = 16, .depth = 16 }, &buf);
    try std.testing.expectEqualStrings("queued=12345 delivered=12000 dropped=7 high_water=16 depth=16\n", buf[0..n]);
    const z = lo.formatStats(.{ .queued = 0, .delivered = 0, .dropped = 0, .high_water = 0, .depth = 16 }, &buf);
    try std.testing.expectEqualStrings("queued=0 delivered=0 dropped=0 high_water=0 depth=16\n", buf[0..z]);
    // a buffer that is too small gets a truncated line, never an overrun
    var small: [10]u8 = undefined;
    const t = lo.formatStats(.{ .queued = 1, .delivered = 1, .dropped = 1, .high_water = 1, .depth = 16 }, &small);
    try std.testing.expectEqual(small.len, t);
    try std.testing.expectEqualStrings("queued=1 d", small[0..t]);
}

test "the process file system exposes /proc/lostats" {
    try std.testing.expect(std.mem.indexOf(u8, kt.procfs_source, "lostats,") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.procfs_source, ".lostats => generateLoStats(buf, max_len),") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.vfs_source, "str.eql(rest, \"lostats\")") != null);
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
    // Page 3: wholly past EOF → .segv plan, delivered as SIGBUS.
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

test "P1: decideSwitch — skip / gated no-flush / flush matrix" {
    const d = pcid_alloc.decideSwitch;
    const A: u64 = 0xAAAA000;
    const B: u64 = 0xBBBB000;
    // Same space already loaded on this CPU: no CR3 write at all.
    try std.testing.expectEqual(SwitchAction.skip, d(5, A, 0, 0, A, 5, 9, false));
    // Kernel/unregistered target (PCID 0): legacy flush write.
    try std.testing.expectEqual(SwitchAction.flush, d(5, A, 0, 0, 0x100000, 0, 0, false));
    // Phase-0 containment: A→B→A always flushes until per-CPU TLB
    // invalidation epochs prove the no-flush fast path safe.
    try std.testing.expectEqual(SwitchAction.flush, d(7, B, 5, 9, A, 5, 9, false));
    try std.testing.expectEqual(SwitchAction.no_flush, d(7, B, 5, 9, A, 5, 9, true));
    // Generation moved (shootdown or PCID reuse): must flush.
    try std.testing.expectEqual(SwitchAction.flush, d(7, B, 5, 9, A, 5, 10, true));
    // Different space, no previous record: flush.
    try std.testing.expectEqual(SwitchAction.flush, d(7, B, 0, 0, A, 5, 9, false));
    // PCID matches but CR3 does not (stale record): must not skip.
    try std.testing.expect(d(5, B, 0, 0, A, 5, 9, false) != SwitchAction.skip);
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
    // A tab blanks cells without per-cell effects: it names the rows to repaint.
    core.cx = 3;
    core.cells[1][4] = 'q';
    try std.testing.expectEqual(fbcon_core.Effect{ .rows = .{ .first = 1, .last = 1 } }, core.putChar('\t'));
    try std.testing.expectEqual(@as(u8, ' '), core.cellAt(4, 1));
    core.cx = 14;
    try std.testing.expectEqual(fbcon_core.Effect{ .rows = .{ .first = 1, .last = 2 } }, core.putChar('\t'));
    core.cx = 8;
    core.cy = 1;
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

// ─── Audited defect regressions (inotify hash, getdents offset clamp,
// readlink fd parse, mprotect shootdown count, task_op pin precedence,
// chdir cwd boundary) ───

test "inotify: path hash does not overflow on long paths" {
    const inotify_policy = kt.inotify_policy;
    // Short inputs still match plain polynomial math.
    try std.testing.expectEqual(@as(u64, 'a'), inotify_policy.hashPathId("a"));
    try std.testing.expectEqual(@as(u64, 'a') * 31 + 'b', inotify_policy.hashPathId("ab"));
    // >=13 chars overflowed u64 with plain ops (Debug panic). Must wrap.
    _ = inotify_policy.hashPathId("/proc/meminfo");
    var long: [256]u8 = @splat(0xFF);
    _ = inotify_policy.hashPathId(&long);
    // Wrapping reference for a 14-char string.
    var ref: u64 = 0;
    for ("WXYZWXYZWXYZWX") |c| ref = ref *% 31 +% c;
    try std.testing.expectEqual(ref, inotify_policy.hashPathId("WXYZWXYZWXYZWX"));
}

test "getdents: tmpfs arm clamps large offsets and advances without wrap" {
    const getdents_policy = kt.getdents_policy;
    try std.testing.expectEqual(@as(u32, 0), getdents_policy.clampOffset(0));
    try std.testing.expectEqual(@as(u32, 5), getdents_policy.clampOffset(5));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), getdents_policy.clampOffset(0xFFFFFFFF));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), getdents_policy.clampOffset(0x1_0000_0000));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), getdents_policy.clampOffset(0xFFFF_FFFF_FFFF_FFFF));
    // Cursor advance must not wrap u32 (start near the clamp + a full page of entries).
    try std.testing.expectEqual(@as(u64, 0x1_0000_003F), getdents_policy.nextOffset(0xFFFFFFFF, 64));
    try std.testing.expectEqual(@as(u64, 7), getdents_policy.nextOffset(3, 4));
}

test "readlink: /proc/self/fd/N parser rejects u32 overflow" {
    const readlink_policy = kt.readlink_policy;
    try std.testing.expectEqual(@as(?u32, 0), readlink_policy.parseFdPrefix("0"));
    try std.testing.expectEqual(@as(?u32, 42), readlink_policy.parseFdPrefix("42"));
    // Trailing junk after the digits is ignored (fd prefix only).
    try std.testing.expectEqual(@as(?u32, 3), readlink_policy.parseFdPrefix("3abc"));
    // Max valid u32 parses; one past it overflows.
    try std.testing.expectEqual(@as(?u32, 0xFFFFFFFF), readlink_policy.parseFdPrefix("4294967295"));
    try std.testing.expectEqual(@as(?u32, null), readlink_policy.parseFdPrefix("4294967296"));
    try std.testing.expectEqual(@as(?u32, null), readlink_policy.parseFdPrefix("99999999999999999999"));
}

test "mprotect: shootdown page count is ceil(len/PAGE)" {
    try std.testing.expectEqual(@as(u64, 1), mprotect_policy.pageCount(1));
    try std.testing.expectEqual(@as(u64, 1), mprotect_policy.pageCount(4095));
    try std.testing.expectEqual(@as(u64, 1), mprotect_policy.pageCount(4096));
    try std.testing.expectEqual(@as(u64, 2), mprotect_policy.pageCount(4097));
    try std.testing.expectEqual(@as(u64, 3), mprotect_policy.pageCount(3 * 4096));
}

test "task_op_policy: pin checks ref overflow before NoMm like the kernel" {
    var st = task_op_policy.State{
        .mm_available = false,
        .operation_refs = task_op_policy.MAX_OPERATION_REFS,
    };
    try std.testing.expectError(error.OperationRefOverflow, st.pin());
}

test "chdir: cwd join/normalize respects the 256-byte buffer" {
    const chdir_policy = kt.chdir_policy;
    var out: [256]u8 = undefined;

    // Normalized result of 254 and 255 bytes fits (NUL lands in bounds).
    const path254 = "/" ++ "a" ** 253;
    const path255 = "/" ++ "a" ** 254;
    try std.testing.expectEqual(@as(usize, 254), try chdir_policy.resolve("/", path254, &out));
    try std.testing.expectEqual(@as(usize, 255), try chdir_policy.resolve("/", path255, &out));
    try std.testing.expectEqual(@as(u8, '/'), out[0]);
    try std.testing.expectEqual(@as(u8, 'a'), out[254]);

    // 256 bytes does not fit alongside the NUL — reject, don't truncate.
    const path256 = "/" ++ "a" ** 255;
    try std.testing.expectError(error.NameTooLong, chdir_policy.resolve("/", path256, &out));

    // Relative join pushing past the limit is also rejected (no silent
    // dropped separator, no out-of-bounds NUL).
    const cwd = "/" ++ "c" ** 200;
    try std.testing.expectError(error.NameTooLong, chdir_policy.resolve(cwd, "b" ** 100, &out));

    // Relative join within budget still works, including "." / ".." handling.
    try std.testing.expectEqual(@as(usize, 4), try chdir_policy.resolve("/a/b", "../c", &out));
    try std.testing.expectEqualStrings("/a/c", out[0..4]);
    try std.testing.expectEqual(@as(usize, 1), try chdir_policy.resolve("/a", "..", &out));
    try std.testing.expectEqualStrings("/", out[0..1]);
}

// ─── Audited defect regressions (UDP ephemeral port exclusivity, TCP rcv_wnd
// saturation, TCP ephemeral wrap, TIME_WAIT v4 tuple, timespec overflow) ───

test "udp: socket() ephemeral scan picks the first unregistered port" {
    // Empty table → first ephemeral port.
    try std.testing.expectEqual(@as(?u16, 49152), udp_util.firstFreePort(&.{}, 49152, 65534));
    // Registered ports are skipped, even when the scan starts on them.
    try std.testing.expectEqual(@as(?u16, 49154), udp_util.firstFreePort(&.{ 49152, 49153 }, 49152, 65534));
    try std.testing.expectEqual(@as(?u16, 49153), udp_util.firstFreePort(&.{49152}, 49152, 65534));
    // Every candidate taken → null (table exhausted for the range).
    try std.testing.expectEqual(@as(?u16, null), udp_util.firstFreePort(&.{ 49152, 49153, 49154 }, 49152, 49154));
}

test "udp: ensurePortExclusive result maps to skip-in-use / abort-full / use" {
    try std.testing.expectEqual(udp_util.ScanAction.use, udp_util.scanAction(0));
    try std.testing.expectEqual(udp_util.ScanAction.use, udp_util.scanAction(41));
    try std.testing.expectEqual(udp_util.ScanAction.skip_in_use, udp_util.scanAction(0xFFFE));
    try std.testing.expectEqual(udp_util.ScanAction.abort_full, udp_util.scanAction(0xFFFF));
}

test "tcp: advertised rcv_wnd saturates at zero when buffered exceeds window" {
    // RECV_BUF_SIZE (65536) > TCP_WINDOW (32768): buffered can exceed the
    // window; the subtraction must saturate instead of underflowing u32.
    try std.testing.expectEqual(@as(u32, 32768), tcp_util.rcvWindowFromBuffered(0, 32768));
    try std.testing.expectEqual(@as(u32, 1), tcp_util.rcvWindowFromBuffered(32767, 32768));
    try std.testing.expectEqual(@as(u32, 0), tcp_util.rcvWindowFromBuffered(32768, 32768));
    try std.testing.expectEqual(@as(u32, 0), tcp_util.rcvWindowFromBuffered(65535, 32768));
}

test "tcp: ephemeral port counter wraps 65535 → 49152 instead of saturating" {
    try std.testing.expectEqual(@as(u16, 49153), tcp_util.nextEphemeralPort(49152));
    try std.testing.expectEqual(@as(u16, 65535), tcp_util.nextEphemeralPort(65534));
    // Wrap must fire — saturating at 65535 would alias every later 4-tuple.
    try std.testing.expectEqual(@as(u16, 49152), tcp_util.nextEphemeralPort(65535));
}

test "tcp: TIME_WAIT v4 tuple match requires remote_ip like the v6 path" {
    const ip_a: [4]u8 = .{ 10, 0, 0, 1 };
    const ip_b: [4]u8 = .{ 10, 0, 0, 2 };
    try std.testing.expect(tcp_util.tupleMatchV4(80, 5000, ip_a, 80, 5000, ip_a));
    // Same ports, different source host → must NOT reuse the TCB.
    try std.testing.expect(!tcp_util.tupleMatchV4(80, 5000, ip_a, 80, 5000, ip_b));
    try std.testing.expect(!tcp_util.tupleMatchV4(80, 5000, ip_a, 81, 5000, ip_a));
    try std.testing.expect(!tcp_util.tupleMatchV4(80, 5000, ip_a, 80, 5001, ip_a));
}

test "time policy: timespec→ns guards overflow and invalid fields" {
    try std.testing.expectEqual(@as(?u64, 0), time_policy.timespecToNs(0, 0));
    try std.testing.expectEqual(@as(?u64, 1_500_000_000), time_policy.timespecToNs(1, 500_000_000));
    // Largest representable value: 18446744073 s + 709551615 ns == maxInt(u64).
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), time_policy.timespecToNs(18446744073, 709551615));
    // One ns past that must overflow → null, not a wrapped near-zero deadline.
    try std.testing.expectEqual(@as(?u64, null), time_policy.timespecToNs(18446744073, 709551616));
    try std.testing.expectEqual(@as(?u64, null), time_policy.timespecToNs(18446744074, 0));
    try std.testing.expectEqual(@as(?u64, null), time_policy.timespecToNs(std.math.maxInt(i64), 0));
    // Invalid fields rejected (same rule as timerfd's guarded conversion).
    try std.testing.expectEqual(@as(?u64, null), time_policy.timespecToNs(-1, 0));
    try std.testing.expectEqual(@as(?u64, null), time_policy.timespecToNs(0, -1));
    try std.testing.expectEqual(@as(?u64, null), time_policy.timespecToNs(0, 1_000_000_000));
    try std.testing.expectEqual(@as(?u64, 999_999_999), time_policy.timespecToNs(0, 999_999_999));
}

test "time policy: ns→ticks reports overflow, ticks→ns saturates" {
    try std.testing.expectEqual(@as(?u64, 0), time_policy.nsToTicks(0, 100));
    try std.testing.expectEqual(@as(?u64, 1), time_policy.nsToTicks(1, 100));
    try std.testing.expectEqual(@as(?u64, 100), time_policy.nsToTicks(1_000_000_000, 100));
    try std.testing.expectEqual(@as(?u64, 100_000), time_policy.nsToTicks(1_000_000_000_000, 100));
    // maxInt(u64) ns at 100 Hz is ~1.8e12 ticks — still fits u64.
    try std.testing.expectEqual(@as(?u64, 1844674407371), time_policy.nsToTicks(std.math.maxInt(u64), 100));
    // Overflow needs an absurd tick rate; the guard must report null there.
    try std.testing.expectEqual(@as(?u64, null), time_policy.nsToTicks(std.math.maxInt(u64), std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(u64, 1_000_000_000), time_policy.ticksToNs(100, 100));
    try std.testing.expectEqual(std.math.maxInt(u64), time_policy.ticksToNs(std.math.maxInt(u64), 100));
}

test "mprotect COW commit consumes a reservation or defers to the fault path" {
    // The commit loop re-checks each PTE after preflight reserved exactly
    // `reserved` data pages. While reservations remain the copy is consumed;
    // once exhausted the PTE must keep its COW bit and stay non-writable so
    // the next write faults and unshares via the fault path.
    try std.testing.expectEqual(mprotect_policy.CowCommitAction.consume, mprotect_policy.cowCommitAction(1, 0));
    try std.testing.expectEqual(mprotect_policy.CowCommitAction.consume, mprotect_policy.cowCommitAction(3, 2));
    // A concurrent fork/clone COW between preflight and commit can bump a
    // sole-owned frame's refcount 1→2, exhausting the reservation.
    try std.testing.expectEqual(mprotect_policy.CowCommitAction.defer_to_fault, mprotect_policy.cowCommitAction(0, 0));
    try std.testing.expectEqual(mprotect_policy.CowCommitAction.defer_to_fault, mprotect_policy.cowCommitAction(2, 2));
}

test "munmap untrack needs a split slot only for a mid-range cut" {
    const S = munmap_policy.PAGE_SIZE;
    // Region [0x10000, 0x18000): unmapping the middle splits it, so
    // untrackMmapRange must insert a tail piece into a free table slot.
    try std.testing.expect(munmap_policy.needsSplitSlot(0x10000, 8, 0x10000 + 2 * S, 2));
    // Edge-aligned cuts truncate or shift the region in place — no slot.
    try std.testing.expect(!munmap_policy.needsSplitSlot(0x10000, 8, 0x10000, 2)); // head cut
    try std.testing.expect(!munmap_policy.needsSplitSlot(0x10000, 8, 0x10000 + 6 * S, 2)); // tail cut
    try std.testing.expect(!munmap_policy.needsSplitSlot(0x10000, 8, 0x10000, 8)); // full cover
    try std.testing.expect(!munmap_policy.needsSplitSlot(0x10000, 8, 0x20000, 2)); // no overlap
}

test "munmap split-slot preflight rejects only when a needed slot is missing" {
    // Full table + mid-split → reject (ENOMEM) before any mutation.
    try std.testing.expect(!munmap_policy.canUntrack(1, 0));
    // Full table + edge-aligned unmap (no split) → allow.
    try std.testing.expect(munmap_policy.canUntrack(0, 0));
    // Free slot + split → allow.
    try std.testing.expect(munmap_policy.canUntrack(1, 1));
    try std.testing.expect(munmap_policy.canUntrack(2, 2));
    try std.testing.expect(!munmap_policy.canUntrack(3, 2));
}

test "owner generation: tid must match the recorded registration" {
    const owner_gen_policy = kt.owner_gen_policy;
    // Same task still occupying the slot → signal it.
    try std.testing.expect(owner_gen_policy.ownerMatches(42, 42));
    // Slot recycled: an unrelated task with a different tid must NOT be
    // signalled by the stale registration.
    try std.testing.expect(!owner_gen_policy.ownerMatches(42, 43));
    // Slot empty (owner exited, not yet re-used) → no target.
    try std.testing.expect(!owner_gen_policy.ownerMatches(42, null));
}

test "inotify_init1 accepts only nonblock and cloexec flags" {
    const inotify_policy = kt.inotify_policy;
    try std.testing.expect(inotify_policy.initFlagsValid(0));
    try std.testing.expect(inotify_policy.initFlagsValid(inotify_policy.IN_NONBLOCK));
    try std.testing.expect(inotify_policy.initFlagsValid(inotify_policy.IN_CLOEXEC));
    try std.testing.expect(!inotify_policy.initFlagsValid(0x400));
}

test "ipc lifecycle clears blocked state on message and error wakeups" {
    try std.testing.expect(ipc_lifecycle_policy.clearsBlockedState(true, false));
    try std.testing.expect(ipc_lifecycle_policy.clearsBlockedState(false, true));
    try std.testing.expect(!ipc_lifecycle_policy.clearsBlockedState(false, false));
    try std.testing.expect(ipc_lifecycle_policy.wakeEventUnique(&.{ 1, 2 }, 3));
    try std.testing.expect(!ipc_lifecycle_policy.wakeEventUnique(&.{ 1, 2 }, 2));
}

// ─── Audited defect regressions (IPC endpoint slot occupancy + call reply
// payload handoff) ───

test "ipc policy: second blocked sender is rejected instead of overwriting the first" {
    const ipc_policy = kt.ipc_policy;
    var ep = ipc_policy.SlotModel{};
    // First sender finds no receiver and registers + blocks.
    try std.testing.expectEqual(ipc_policy.SendAction.block, ep.send(0xAA));
    try std.testing.expect(ep.waiting_sender);
    try std.testing.expectEqual(@as(?u64, 0xAA), ep.pending_msg);
    // Second sender to the same endpoint must be rejected: registering it
    // would overwrite the first sender's registration and message, stranding
    // the first sender blocked forever (no timeout is enforced).
    try std.testing.expectEqual(ipc_policy.SendAction.busy, ep.send(0xBB));
    try std.testing.expectEqual(@as(?u64, 0xAA), ep.pending_msg); // untouched
    // Receiver picks up the FIRST sender's message and frees the slot.
    var got: ?u64 = null;
    try std.testing.expectEqual(ipc_policy.ReceiveAction.pick_up, ep.receive(&got));
    try std.testing.expectEqual(@as(?u64, 0xAA), got);
    try std.testing.expect(!ep.waiting_sender);
    // Slot free again: a new sender may block once more.
    try std.testing.expectEqual(ipc_policy.SendAction.block, ep.send(0xCC));
}

test "ipc policy: second blocked receiver is rejected symmetrically" {
    const ipc_policy = kt.ipc_policy;
    var ep = ipc_policy.SlotModel{};
    var got: ?u64 = null;
    try std.testing.expectEqual(ipc_policy.ReceiveAction.block, ep.receive(&got));
    try std.testing.expect(ep.waiting_receiver);
    // A second blocked receiver would overwrite the registration — reject.
    try std.testing.expectEqual(ipc_policy.ReceiveAction.busy, ep.receive(&got));
    try std.testing.expectEqual(@as(?u64, null), got);
    // Sender delivers into the waiting receiver and frees the slot.
    try std.testing.expectEqual(ipc_policy.SendAction.deliver, ep.send(0x11));
    try std.testing.expect(!ep.waiting_receiver);
    try std.testing.expectEqual(@as(?u64, 0x11), ep.takeDelivered());
    try std.testing.expectEqual(@as(?u64, null), ep.pending_msg);
}

test "ipc policy: call reply handoff copies the payload and clears the slot" {
    const ipc_policy = kt.ipc_policy;
    var ep = ipc_policy.SlotModel{};
    // Caller blocked in call(); callee replies via reply().
    ep.reply(0xDEAD);
    var reply_buf: ?u64 = null;
    try std.testing.expectEqual(ipc_policy.CallWake.reply_arrived, ep.callTakeReply(&reply_buf));
    try std.testing.expectEqual(@as(?u64, 0xDEAD), reply_buf);
    // Slot cleared: a later receive() cannot consume the reply out of context.
    try std.testing.expectEqual(@as(?u64, null), ep.pending_msg);
}

test "ipc policy: signal kick is discriminated from reply arrival" {
    const ipc_policy = kt.ipc_policy;
    var ep = ipc_policy.SlotModel{};
    var reply_buf: ?u64 = null;
    // Empty slot → bare signal kick, no payload handoff.
    try std.testing.expectEqual(ipc_policy.CallWake.signal_kick, ep.callTakeReply(&reply_buf));
    try std.testing.expectEqual(@as(?u64, null), reply_buf);
    // A blocked sender owns pending_msg: call() must not steal its message
    // as a reply.
    try std.testing.expectEqual(ipc_policy.SendAction.block, ep.send(0x77));
    try std.testing.expectEqual(ipc_policy.CallWake.signal_kick, ep.callTakeReply(&reply_buf));
    try std.testing.expectEqual(@as(?u64, 0x77), ep.pending_msg); // sender's msg untouched
    try std.testing.expectEqual(@as(?u64, null), reply_buf);
}

test "ipc policy: takeSlot returns the payload once and empties the slot" {
    const ipc_policy = kt.ipc_policy;
    var slot: ?u64 = null;
    try std.testing.expectEqual(@as(?u64, null), ipc_policy.takeSlot(u64, &slot));
    slot = 42;
    try std.testing.expectEqual(@as(?u64, 42), ipc_policy.takeSlot(u64, &slot));
    try std.testing.expectEqual(@as(?u64, null), slot);
}

test "tcp: flush send cursor stays in lockstep with snd_nxt across fail-then-retry" {
    // §6.39 follow-up item 9: flushSendBuffer advanced send_unacked BEFORE
    // sendSegment and discarded the result. On TX failure snd_nxt is not
    // advanced, so the invariant
    //   send_unacked == (send_head + (snd_nxt -% snd_una)) % SEND_BUF_SIZE
    // breaks and the next segment carries payload belonging to a later seq.
    // The policy: commit the cursor only on TX success (tcp_util helper,
    // wired into flushSendBuffer).
    const SIZE: u32 = 256; // power-of-two ring, like SEND_BUF_SIZE
    const send_head: u32 = 200; // start near the wrap
    const send_tail: u32 = (send_head + 100) % SIZE; // 100 bytes pending
    const mss: u32 = 40;
    const snd_una: u32 = 1000;
    var snd_nxt: u32 = snd_una;
    var send_unacked = tcp_util.expectedSendUnacked(send_head, snd_nxt, snd_una, SIZE);

    // First flush attempt: sendSegment fails (ARP unresolved / PMTU gate /
    // full NIC TX ring) — snd_nxt does not move, so the cursor must not move.
    var can_send = @min(tcp_util.ringDataLen(send_unacked, send_tail, SIZE), mss);
    try std.testing.expectEqual(@as(u32, 40), can_send);
    send_unacked = tcp_util.flushCommitCursor(send_unacked, can_send, SIZE, false);
    try std.testing.expectEqual(tcp_util.expectedSendUnacked(send_head, snd_nxt, snd_una, SIZE), send_unacked);

    // Retry: all three segments now go out, crossing the ring wrap; the
    // invariant holds after every committed segment.
    while (true) {
        can_send = @min(tcp_util.ringDataLen(send_unacked, send_tail, SIZE), mss);
        if (can_send == 0) break;
        send_unacked = tcp_util.flushCommitCursor(send_unacked, can_send, SIZE, true);
        snd_nxt +%= can_send; // advanceSndNxt on TX success
        try std.testing.expectEqual(tcp_util.expectedSendUnacked(send_head, snd_nxt, snd_una, SIZE), send_unacked);
    }
    try std.testing.expectEqual(snd_una + 100, snd_nxt);
    try std.testing.expectEqual(send_tail, send_unacked);
}

test "tcp: segment option length mirrors the wire layout for the PMTU pre-gate" {
    const L = tcp_util.segmentOptLen;
    // SYN always carries MSS(4) + WS(3) + TS(10) + SACK-permitted(2) = 19,
    // padded to 20.
    try std.testing.expectEqual(@as(u8, 20), L(true, false, false, 0, false));
    // Bare data/ACK segment: no options.
    try std.testing.expectEqual(@as(u8, 0), L(false, false, false, 0, true));
    // TS only: 10 padded to 12.
    try std.testing.expectEqual(@as(u8, 12), L(false, true, false, 0, true));
    // SACK blocks need the ACK flag and SACK negotiation.
    try std.testing.expectEqual(@as(u8, 0), L(false, false, true, 1, false));
    try std.testing.expectEqual(@as(u8, 0), L(false, false, false, 1, true));
    // TS + 1 SACK block: 10 + (2+8) = 20, already aligned.
    try std.testing.expectEqual(@as(u8, 20), L(false, true, true, 1, true));
    // TS + 2 blocks: 10 + 18 = 28; TS + 3 blocks: 10 + 26 = 36.
    try std.testing.expectEqual(@as(u8, 28), L(false, true, true, 2, true));
    try std.testing.expectEqual(@as(u8, 36), L(false, true, true, 3, true));
    // 1 SACK block without TS: 10 padded to 12.
    try std.testing.expectEqual(@as(u8, 12), L(false, false, true, 1, true));
}

test "mremap shrink needs a split slot only when the region outlives old_size" {
    const S = munmap_policy.PAGE_SIZE;
    // mremap shrink unmaps [old_addr + new_pages*S, old_addr + old_pages*S)
    // and calls untrackMmapRange on it, so the same mid-split rule as munmap
    // applies (the call site reuses needsSplitSlot/canUntrack unchanged).
    // Region [0x10000, 16 pages) shrunk from 12 to 8 pages: the cut range
    // [0x10000+8S, 0x10000+12S) sits strictly inside the region — the tail
    // piece (pages 12..16) needs a free table slot.
    try std.testing.expect(munmap_policy.needsSplitSlot(0x10000, 16, 0x10000 + 8 * S, 4));
    try std.testing.expect(!munmap_policy.canUntrack(1, 0)); // full table → ENOMEM
    try std.testing.expect(munmap_policy.canUntrack(1, 1));
    // Region ends exactly at old_size ([0x10000, 12 pages), shrink 12→8):
    // the cut is edge-aligned at the region tail — plain truncation, no slot.
    try std.testing.expect(!munmap_policy.needsSplitSlot(0x10000, 12, 0x10000 + 8 * S, 4));
    try std.testing.expect(munmap_policy.canUntrack(0, 0)); // full table → allow
}

test "tcp: ACK advance must not move the send cursor (snd_nxt unchanged)" {
    // §6.39 item 9 follow-up: the ACK path advanced send_unacked by `acked`
    // next to the (correct) send_head advance. An ACK does not move snd_nxt,
    // so the invariant
    //   send_unacked == (send_head + (snd_nxt -% snd_una)) % SEND_BUF_SIZE
    // breaks: a later flush computes phantom pending bytes and sends stale
    // ring data under live sequence numbers.
    const SIZE: u32 = 256; // power-of-two ring, like SEND_BUF_SIZE
    const mss: u32 = 40;
    var send_head: u32 = 0;
    var send_tail: u32 = 0;
    var snd_una: u32 = 1000;
    var snd_nxt: u32 = snd_una;
    var send_unacked = tcp_util.expectedSendUnacked(send_head, snd_nxt, snd_una, SIZE);

    // App writes 100 bytes; flush sends them all (three segments).
    send_tail = 100;
    while (true) {
        const can_send = @min(tcp_util.ringDataLen(send_unacked, send_tail, SIZE), mss);
        if (can_send == 0) break;
        send_unacked = tcp_util.flushCommitCursor(send_unacked, can_send, SIZE, true);
        snd_nxt +%= can_send; // advanceSndNxt on TX success
    }
    try std.testing.expectEqual(send_tail, send_unacked);

    // Peer ACKs everything: snd_una and send_head advance by `acked`; the
    // fixed kernel does not touch the send cursor (snd_nxt is unchanged).
    const acked = snd_nxt -% snd_una;
    snd_una = snd_nxt;
    send_head = (send_head + acked) % SIZE;

    // The send cursor stays at send_tail — invariant holds across the ACK.
    try std.testing.expectEqual(tcp_util.expectedSendUnacked(send_head, snd_nxt, snd_una, SIZE), send_unacked);
    try std.testing.expectEqual(send_tail, send_unacked);

    // A follow-up write of 50 bytes flushes exactly those 50 bytes (no
    // phantom pending from stale ring slots), crossing no stale data.
    send_tail = (send_tail + 50) % SIZE;
    var sent_bytes: u32 = 0;
    while (true) {
        const can_send = @min(tcp_util.ringDataLen(send_unacked, send_tail, SIZE), mss);
        if (can_send == 0) break;
        send_unacked = tcp_util.flushCommitCursor(send_unacked, can_send, SIZE, true);
        snd_nxt +%= can_send;
        sent_bytes += can_send;
        try std.testing.expectEqual(tcp_util.expectedSendUnacked(send_head, snd_nxt, snd_una, SIZE), send_unacked);
    }
    try std.testing.expectEqual(@as(u32, 50), sent_bytes);
    try std.testing.expectEqual(send_tail, send_unacked);
}

test "eventfd policy: a write broadcasts only when the counter is readable" {
    const eventfd_policy = kt.eventfd_policy;
    // val == 0 onto a zero counter: instance still unreadable → no broadcast
    // (blocked readers must not spin through spurious wake/re-block cycles).
    try std.testing.expect(!eventfd_policy.writeWakesReaders(0));
    // Any nonzero counter after the write → readable → broadcast to all
    // blocked readers (each re-checks; the first drains it to 0).
    try std.testing.expect(eventfd_policy.writeWakesReaders(1));
    try std.testing.expect(eventfd_policy.writeWakesReaders(std.math.maxInt(u64)));
}

test "eventfd policy: read result drains or decrements per EFD_SEMAPHORE" {
    const eventfd_policy = kt.eventfd_policy;
    // Default mode: return the pre-read value, drain the counter to 0.
    const drain = eventfd_policy.readResult(5, false);
    try std.testing.expectEqual(@as(u64, 5), drain.value);
    try std.testing.expectEqual(@as(u64, 0), drain.counter_after);
    // EFD_SEMAPHORE: return 1, decrement the counter by exactly 1.
    const sem = eventfd_policy.readResult(5, true);
    try std.testing.expectEqual(@as(u64, 1), sem.value);
    try std.testing.expectEqual(@as(u64, 4), sem.counter_after);
    const sem_last = eventfd_policy.readResult(1, true);
    try std.testing.expectEqual(@as(u64, 1), sem_last.value);
    try std.testing.expectEqual(@as(u64, 0), sem_last.counter_after);
}

test "eventfd policy: write admission caps the counter at 2^64-2" {
    const eventfd_policy = kt.eventfd_policy;
    const MAX = eventfd_policy.COUNTER_MAX;
    try std.testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_FFFE), MAX);
    // Room for the whole sum → admitted without blocking.
    try std.testing.expect(eventfd_policy.writeAdmitted(0, 0));
    try std.testing.expect(eventfd_policy.writeAdmitted(0, MAX));
    try std.testing.expect(eventfd_policy.writeAdmitted(MAX, 0));
    try std.testing.expect(eventfd_policy.writeAdmitted(5, MAX - 5));
    // Sum would exceed 2^64-2 → caller must block (or EAGAIN), never wrap.
    try std.testing.expect(!eventfd_policy.writeAdmitted(MAX, 1));
    try std.testing.expect(!eventfd_policy.writeAdmitted(5, MAX - 4));
    try std.testing.expect(!eventfd_policy.writeAdmitted(MAX, MAX));
    // 0xFFFFFFFFFFFFFFFF is not a writable value at all (Linux: -EINVAL).
    try std.testing.expect(!eventfd_policy.writeValValid(std.math.maxInt(u64)));
    try std.testing.expect(eventfd_policy.writeValValid(MAX));
    try std.testing.expect(eventfd_policy.writeValValid(0));
}

test "eventfd policy: POLLOUT predicate admits a write of 1 below the cap" {
    const eventfd_policy = kt.eventfd_policy;
    // poll POLLOUT for eventfd: a write of at least 1 must be admitted
    // without blocking (Linux: counter <= 2^64-2 minus the written value).
    try std.testing.expect(eventfd_policy.writeAdmitted(0, 1));
    try std.testing.expect(eventfd_policy.writeAdmitted(eventfd_policy.COUNTER_MAX - 1, 1));
    // Full counter → not writable; poll must not report POLLOUT.
    try std.testing.expect(!eventfd_policy.writeAdmitted(eventfd_policy.COUNTER_MAX, 1));
}

test "time policy: timerfd_create accepts only TFD_CLOEXEC and TFD_NONBLOCK" {
    try std.testing.expect(time_policy.timerfdFlagsValid(0));
    try std.testing.expect(time_policy.timerfdFlagsValid(0x800)); // TFD_NONBLOCK
    try std.testing.expect(time_policy.timerfdFlagsValid(0x80000)); // TFD_CLOEXEC
    try std.testing.expect(time_policy.timerfdFlagsValid(0x80800)); // both
    // Anything else is -EINVAL (Linux timerfd_create).
    try std.testing.expect(!time_policy.timerfdFlagsValid(1));
    try std.testing.expect(!time_policy.timerfdFlagsValid(0x1000));
    try std.testing.expect(!time_policy.timerfdFlagsValid(std.math.maxInt(u32)));
}

test "swap policy: admission rejects only the boot/system disk" {
    const swap_policy = kt.swap_policy;
    // The boot/root disk — the only disk fat32/ext2 address directly — must
    // never be admitted as a swap target: writeback would scribble the root
    // filesystem (see block_dev.discard's system-disk identification).
    try std.testing.expect(!swap_policy.admitTarget(.virtio_blk, 0));
    // Any other device is admissible: the QEMU smoke attaches pattern-stamped
    // NVMe/AHCI scratch images precisely so tests can write them.
    try std.testing.expect(swap_policy.admitTarget(.virtio_blk, 1));
    try std.testing.expect(swap_policy.admitTarget(.ahci, 0));
    try std.testing.expect(swap_policy.admitTarget(.nvme, 0));
}

test "swap policy: device-path normalization strips an optional /dev/ prefix" {
    const swap_policy = kt.swap_policy;
    try std.testing.expectEqualStrings("sda", swap_policy.deviceName("/dev/sda"));
    try std.testing.expectEqualStrings("sda", swap_policy.deviceName("sda"));
    try std.testing.expectEqualStrings("nvme0", swap_policy.deviceName("/dev/nvme0"));
    // A bare "/dev/" or other prefix is not stripped.
    try std.testing.expectEqualStrings("", swap_policy.deviceName("/dev/"));
    try std.testing.expectEqualStrings("/sda", swap_policy.deviceName("/sda"));
    try std.testing.expectEqualStrings("dev/sda", swap_policy.deviceName("dev/sda"));
}

test "swap policy: swapon flags word admits no flags yet" {
    const swap_policy = kt.swap_policy;
    try std.testing.expect(swap_policy.flagsValid(0));
    try std.testing.expect(!swap_policy.flagsValid(1));
    try std.testing.expect(!swap_policy.flagsValid(0x8000)); // SWAP_FLAG_PREFER
    try std.testing.expect(!swap_policy.flagsValid(std.math.maxInt(u32)));
}

test "mprotect policy: swap entries keep their marker, only preserved permission bits move" {
    const mprot_policy = kt.mprotect_policy;
    // Non-present + bit-11 marker = swap entry (see mm/pte_kind.zig's PTE
    // format): writable is preserved at bit 2, COW at bit 3, slot at bits
    // 12-51, NX at 63.
    const entry: u64 = (@as(u64, 1) << 11) | (@as(u64, 0x12345) << 12) | (@as(u64, 1) << 2) | (@as(u64, 1) << 63);

    // Not a swap entry → null (caller runs the normal present-page path).
    try std.testing.expectEqual(@as(?u64, null), mprot_policy.swapEntryUpdate(0x0, 2));
    try std.testing.expectEqual(@as(?u64, null), mprot_policy.swapEntryUpdate(0x5 | (0x8000_0000_0000_0000), 2)); // present page

    // PROT_NONE: the entry is already not-present; leave it untouched so a
    // later PROT_READ still finds the swap slot.
    try std.testing.expectEqual(entry, mprot_policy.swapEntryUpdate(entry, 0).?);

    // PROT_READ: drop preserved writable, set NX.
    const ro = mprot_policy.swapEntryUpdate(entry, 1).?;
    try std.testing.expectEqual(@as(u64, (1 << 11) | (0x12345 << 12) | (1 << 63)), ro);
    // PROT_READ|WRITE: keep preserved writable, set NX.
    const rw = mprot_policy.swapEntryUpdate(entry & ~(@as(u64, 1) << 2), 3).?;
    try std.testing.expectEqual(@as(u64, (1 << 11) | (0x12345 << 12) | (1 << 2) | (1 << 63)), rw);
    // PROT_READ|EXEC: clear NX, drop writable.
    const rx = mprot_policy.swapEntryUpdate(entry, 5).?;
    try std.testing.expectEqual(@as(u64, (1 << 11) | (0x12345 << 12)), rx);
    // The COW-preserved bit (3) survives every update.
    const cow = entry | (@as(u64, 1) << 3);
    try std.testing.expectEqual(cow, mprot_policy.swapEntryUpdate(cow, 3).?);
}

test "pte kind: classify distinguishes free, present, swap, prot_none and unknown" {
    const pte_kind = kt.pte_kind;
    try std.testing.expectEqual(pte_kind.Kind.free, pte_kind.classify(0));
    try std.testing.expectEqual(pte_kind.Kind.present, pte_kind.classify(0x1));
    // Present wins over both markers — a live page is never reclassified.
    try std.testing.expectEqual(pte_kind.Kind.present, pte_kind.classify(0x12345000 | 0x7 | (1 << 10) | (1 << 11)));

    // Swap entry: bit-11 marker + slot round-trip, preserved bits coexist.
    const swap_entry = pte_kind.encodeSwapEntry(0x12345);
    try std.testing.expectEqual(pte_kind.Kind.swap, pte_kind.classify(swap_entry));
    try std.testing.expectEqual(pte_kind.Kind.swap, pte_kind.classify(swap_entry | 0xC | (@as(u64, 1) << 63)));
    try std.testing.expectEqual(@as(u64, 0x12345), pte_kind.decodeSwapEntry(swap_entry));
    const max_slot = pte_kind.encodeSwapEntry(0xF_FFFF_FFFF) | 0x4 | 0x8 | (@as(u64, 1) << 63);
    try std.testing.expectEqual(pte_kind.Kind.swap, pte_kind.classify(max_slot));
    try std.testing.expectEqual(@as(u64, 0xF_FFFF_FFFF), pte_kind.decodeSwapEntry(max_slot));
    try std.testing.expectEqual(@as(u64, 0), pte_kind.decodeSwapEntry(pte_kind.encodeSwapEntry(0)));

    // PROT_NONE reservation of a formerly writable page: present=0, frame
    // and writable kept, reservation marker set — never a swap entry.
    const reservation = (@as(u64, 0x12345) << 12) | pte_kind.PROT_NONE_MARKER | 0x6;
    try std.testing.expectEqual(pte_kind.Kind.prot_none, pte_kind.classify(reservation));

    // Legacy shape (present=0 + writable, no markers) is unknown — and the
    // pre-fix collision must stay closed: bit 1 alone is never a swap entry.
    try std.testing.expectEqual(pte_kind.Kind.unknown, pte_kind.classify((@as(u64, 0x12345) << 12) | 0x6));
    try std.testing.expect(pte_kind.classify((@as(u64, 0x12345) << 12) | 0x2) != pte_kind.Kind.swap);
}

test "pte kind: a PROT_NONE reservation never classifies as a swap entry" {
    const pte_kind = kt.pte_kind;
    // The §6.48 collision, closed: mprotect(PROT_NONE) preserves the frame
    // and the writable bit (bit 1) — the old swap marker. With the marker on
    // bit 10 the reservation classifies distinctly; even the legacy unmarked
    // shape must never be read as a swap entry (that read the PFN as a disk
    // slot and "swapped in" garbage — silent corruption).
    const reservation: u64 = (@as(u64, 0x12345) << 12) | pte_kind.PROT_NONE_MARKER | 0x6;
    try std.testing.expectEqual(pte_kind.Kind.prot_none, pte_kind.classify(reservation));
    try std.testing.expect(pte_kind.classify(reservation) != pte_kind.Kind.swap);
    try std.testing.expectEqual(pte_kind.Kind.swap, pte_kind.classify(pte_kind.encodeSwapEntry(0x12345) | 0x6));
}

test "mprotect policy: a PROT_NONE reservation is never mistaken for a swap entry" {
    const mprot_policy = kt.mprotect_policy;
    // mprotect(PROT_NONE) keeps the frame and every permission bit, clearing
    // only present — a formerly writable page keeps bit 1 set, which the
    // pre-§6.48 swap predicate (non-present + bit 1) misread as a swap entry:
    // a PROT_RW re-mprotect then took the swap-entry branch, left present=0
    // and the mapping was never restored. With the bit-10 reservation marker
    // or without any marker, swapEntryUpdate must return null so the caller
    // runs the normal present-restoring path.
    const legacy_reservation: u64 = (@as(u64, 0x12345) << 12) | 0x6; // writable|user + PFN
    try std.testing.expectEqual(@as(?u64, null), mprot_policy.swapEntryUpdate(legacy_reservation, 3));
    const marked_reservation: u64 = legacy_reservation | (@as(u64, 1) << 10);
    try std.testing.expectEqual(@as(?u64, null), mprot_policy.swapEntryUpdate(marked_reservation, 3));
}

test "pte kind: teardown action reclaims exactly the resource each class holds" {
    const pte_kind = kt.pte_kind;
    // Free and unknown entries hold neither a frame nor a slot — tearing them
    // down must not touch the PMM or the swap bitmap.
    try std.testing.expectEqual(pte_kind.TeardownAction.none, pte_kind.teardownAction(0));
    try std.testing.expectEqual(pte_kind.TeardownAction.none, pte_kind.teardownAction((@as(u64, 0x12345) << 12) | 0x6)); // legacy unknown shape

    // A present page and a PROT_NONE reservation both pin a physical frame:
    // teardown drops one reference (pmm.freePage — decRef, free at zero; the
    // frame may still be COW-shared with a forked child that inherited it
    // while the page was present, so an unconditional free would corrupt).
    try std.testing.expectEqual(pte_kind.TeardownAction.free_frame, pte_kind.teardownAction((@as(u64, 0x12345) << 12) | 0x7));
    try std.testing.expectEqual(pte_kind.TeardownAction.free_frame, pte_kind.teardownAction((@as(u64, 0x12345) << 12) | 0x7 | (@as(u64, 1) << 9) | (@as(u64, 1) << 63))); // present+COW+NX
    try std.testing.expectEqual(pte_kind.TeardownAction.free_frame, pte_kind.teardownAction((@as(u64, 0x12345) << 12) | pte_kind.PROT_NONE_MARKER | 0x6));

    // A swap entry holds a slot but no frame: free the slot only.
    try std.testing.expectEqual(pte_kind.TeardownAction.free_slot, pte_kind.teardownAction(pte_kind.encodeSwapEntry(7)));
    try std.testing.expectEqual(pte_kind.TeardownAction.free_slot, pte_kind.teardownAction(pte_kind.encodeSwapEntry(0xF_FFFF_FFFF) | 0xC | (@as(u64, 1) << 63)));
}

test "filemap: a PROT_NONE region's never-faulted page SIGSEGVs instead of demand-filling" {
    const R = struct { base: u64, file_offset: u64, file_size: u64, prot: u8, shared: bool };
    // A never-faulted file page is a zero PTE — no reservation marker for
    // pte_kind to classify — so the region's prot metadata is the only
    // record that the mapping forbids access (§6.48 residual).
    const r_none = R{ .base = 0x100_0000, .file_offset = 0, .file_size = 8192, .prot = 0, .shared = false };
    try std.testing.expectEqual(filemap.FaultAction.prot_none, filemap.planFault(R, &r_none, 0x100_0000).action);
    try std.testing.expectEqual(filemap.FaultAction.prot_none, filemap.planFault(R, &r_none, 0x100_0000 + 4096).action);
    // Protection wins over EOF: PROT_NONE answers prot_none even past the end.
    try std.testing.expectEqual(filemap.FaultAction.prot_none, filemap.planFault(R, &r_none, 0x100_0000 + 64 * 4096).action);
    // MAP_SHARED PROT_NONE is no exception.
    const r_none_shared = R{ .base = 0x100_0000, .file_offset = 0, .file_size = 8192, .prot = 0, .shared = true };
    try std.testing.expectEqual(filemap.FaultAction.prot_none, filemap.planFault(R, &r_none_shared, 0x100_0000).action);

    // Permitted regions are unchanged: in-bounds is served, past EOF segvs.
    const r_ro = R{ .base = 0x100_0000, .file_offset = 0, .file_size = 100, .prot = 1, .shared = false };
    try std.testing.expectEqual(filemap.FaultAction.file_page, filemap.planFault(R, &r_ro, 0x100_0000).action);
    try std.testing.expectEqual(filemap.FaultAction.segv, filemap.planFault(R, &r_ro, 0x100_0000 + 4096).action);
}

test "swap policy: swapoff begin decision per area state" {
    const swap_policy = kt.swap_policy;
    // swapoff on a never-armed (or already committed) area is EINVAL; on an
    // armed area the drain begins; a concurrent swapoff already draining is
    // EBUSY — the kernel serialises the armed→draining transition with a CAS,
    // this is the pure decision it consults first.
    try std.testing.expectEqual(swap_policy.SwapoffBegin.not_armed, swap_policy.swapoffBegin(.disabled));
    try std.testing.expectEqual(swap_policy.SwapoffBegin.begin, swap_policy.swapoffBegin(.armed));
    try std.testing.expectEqual(swap_policy.SwapoffBegin.busy, swap_policy.swapoffBegin(.draining));
}

test "swap policy: swapon admission per area state" {
    const swap_policy = kt.swap_policy;
    // Only a fully disabled area may be (re-)armed; armed and draining both
    // report EBUSY at the syscall layer.
    try std.testing.expect(swap_policy.swaponAllowed(.disabled));
    try std.testing.expect(!swap_policy.swaponAllowed(.armed));
    try std.testing.expect(!swap_policy.swaponAllowed(.draining));
}

test "swap policy: draining quiesces new swap-outs but still serves swap-ins" {
    const swap_policy = kt.swap_policy;
    // The drain would never finish if reclaim could keep refilling slots, so
    // allocSlot/reclaim are gated off while draining. Swap-in must keep
    // working in every live state: a thread of a draining address space can
    // still fault on its swapped pages (and the drain itself swaps in).
    try std.testing.expect(swap_policy.maySwapOut(.armed));
    try std.testing.expect(!swap_policy.maySwapOut(.draining));
    try std.testing.expect(!swap_policy.maySwapOut(.disabled));
    try std.testing.expect(swap_policy.maySwapIn(.armed));
    try std.testing.expect(swap_policy.maySwapIn(.draining));
    try std.testing.expect(!swap_policy.maySwapIn(.disabled));
}

test "swap policy: drain finish — commit only when fully drained, OOM rolls back to armed" {
    const swap_policy = kt.swap_policy;
    // PMM OOM mid-drain is not fatal: the partially drained area stays valid,
    // the area returns to armed, and the syscall reports ENOMEM.
    try std.testing.expectEqual(swap_policy.DrainFinish.rollback, swap_policy.drainFinish(true));
    try std.testing.expectEqual(swap_policy.AreaState.armed, swap_policy.drainNextState(.rollback));
    // A clean drain (all slots swapped back in) commits: device disabled.
    try std.testing.expectEqual(swap_policy.DrainFinish.commit, swap_policy.drainFinish(false));
    try std.testing.expectEqual(swap_policy.AreaState.disabled, swap_policy.drainNextState(.commit));
}

test "virtio available-ring indices wrap instead of trapping" {
    // avail.idx is a free-running u16. A checked `+ 1` panics the kernel on the
    // 65536th request, which a busy disk (a large directory listing) reaches.
    const sources = [_][]const u8{ kt.virtio_blk_source, kt.virtio_net_source };
    for (sources) |src| {
        var count: usize = 0;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, src, pos, "avail.idx = ")) |at| {
            const eol = std.mem.indexOfScalarPos(u8, src, at, '\n') orelse src.len;
            const line = src[at..eol];
            try std.testing.expect(std.mem.indexOf(u8, line, "+% 1") != null);
            try std.testing.expect(std.mem.indexOf(u8, line, " + 1") == null);
            count += 1;
            pos = eol;
        }
        try std.testing.expect(count >= 3);
    }
}

test "the read-only volume lock sleeps; no spinlock is held across device I/O" {
    // rofs reads can park the task until a completion interrupt (NVMe). A
    // spinlock held across that leaves the next caller spinning with
    // interrupts off while the holder is switched out: a hard hang.
    try std.testing.expect(std.mem.indexOf(u8, kt.rofs_source, "IrqSpinlock") == null);
    try std.testing.expect(std.mem.indexOf(u8, kt.rofs_source, "var rofs_lock: SleepLock") != null);
    // mount/umount: the table spinlock is taken in short scopes only. The
    // device mount must happen outside any mount_lock scope.
    const mount_start = std.mem.indexOf(u8, kt.vfs_source, "pub fn mountFs(") orelse return error.TestUnexpectedResult;
    const mount_end = std.mem.indexOfPos(u8, kt.vfs_source, mount_start, "pub fn umountFs(") orelse return error.TestUnexpectedResult;
    const body = kt.vfs_source[mount_start..mount_end];
    try std.testing.expect(std.mem.indexOf(u8, body, "mount_op_lock.lock();") != null);
    const device_mount = std.mem.indexOf(u8, body, "rofs.mountVolume(") orelse return error.TestUnexpectedResult;
    // every `mount_lock.acquire()` before the device mount must be released (its scope closed) first
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, "mount_lock.acquire()")) |acq| {
        if (acq > device_mount) break;
        const rel = std.mem.indexOfPos(u8, body, acq, "mount_lock.release(") orelse return error.TestUnexpectedResult;
        try std.testing.expect(rel < device_mount);
        pos = acq + 1;
    }
}

test "a task switched away from is published only after the CPU has left its kernel stack" {
    // releaseToReady makes a task claimable by every other CPU. The scheduler
    // pass that decides the switch still runs on the old task's kernel stack
    // and returns through commonStub's epilogue on it, so publishing inside the
    // pass let another CPU resume that task on a stack still in use. The pass
    // must only record the task; commonStub's epilogue publishes it after
    // `movq %rax, %rsp`.
    const sched = kt.sched_source;
    const rel = std.mem.indexOf(u8, sched, "fn recordOldTask(old_task: *task.Task) void {") orelse return error.TestUnexpectedResult;
    const rel_end = std.mem.indexOfPos(u8, sched, rel, "fn publishOldTask(") orelse return error.TestUnexpectedResult;
    const body = sched[rel..rel_end];
    try std.testing.expect(std.mem.indexOf(u8, body, "releaseToReady") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "enqueueTask") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "&pc.pending_release, old_task.self_idx") != null);
    // publishOldTask is defined once and called from exactly two places: the flush
    // (the normal path) and recordOldTask's fallback for a CPU without per-CPU
    // data yet (early boot, no other CPU can claim anything then).
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, sched, "publishOldTask("));
    const flush_fn = std.mem.indexOf(u8, sched, "pub fn pendingReleaseFlush() void {") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, sched[flush_fn..], "publishOldTask(t)") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "publishOldTask(old_task)") != null);

    const idt = kt.idt_source;
    const stack_switch = std.mem.indexOf(u8, idt, "\\\\movq %%rax, %%rsp") orelse return error.TestUnexpectedResult;
    const flush = std.mem.indexOfPos(u8, idt, stack_switch, "call pendingReleaseFlushStub") orelse return error.TestUnexpectedResult;
    const pops = std.mem.indexOfPos(u8, idt, stack_switch, "\\\\popq %%r15") orelse return error.TestUnexpectedResult;
    try std.testing.expect(stack_switch < flush and flush < pops);
    try std.testing.expect(std.mem.indexOf(u8, idt, "cmpl $0xFFFFFFFF, %%gs:116") != null);
    // the offset the assembly hard-codes is asserted next to the field
    try std.testing.expect(std.mem.indexOf(u8, kt.syscall_entry_source, "@offsetOf(PerCpu, \"pending_release\") != 116") != null);

    // A blocked or exited task is not .running, so releaseToReady cannot hold it
    // back; only the marker keeps another CPU from claiming it. It must be stored
    // before current_task_idx moves on, and the task-level "is it live elsewhere"
    // checks must consult it.
    const tick = std.mem.indexOf(u8, sched, "fn timerTickFg(frame: *idt.InterruptFrame) void {") orelse return error.TestUnexpectedResult;
    const tick_end = std.mem.indexOfPos(u8, sched, tick, "\n}\n") orelse return error.TestUnexpectedResult;
    const tick_body = sched[tick..tick_end];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, tick_body, "recordOldTask(old_task);"));
    const record_call = std.mem.indexOf(u8, tick_body, "recordOldTask(old_task);") orelse return error.TestUnexpectedResult;
    const set_current = std.mem.lastIndexOf(u8, tick_body, "setCurrentIdx(next_idx);") orelse return error.TestUnexpectedResult;
    try std.testing.expect(record_call < set_current);
    // Read the marker as code, not as a word in a comment.
    const tsk = kt.task_source;
    const other = std.mem.indexOf(u8, tsk, "pub fn isCurrentOnOtherCpu(") orelse return error.TestUnexpectedResult;
    const other_end = std.mem.indexOfPos(u8, tsk, other, "\n}\n") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, tsk[other..other_end], "@atomicLoad(u32, &pc.pending_release, .acquire) == idx") != null);
    const any = std.mem.indexOf(u8, tsk, "fn isCurrentOnAnyCpu(") orelse return error.TestUnexpectedResult;
    const any_end = std.mem.indexOfPos(u8, tsk, any, "\n}\n") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, tsk[any..any_end], "@atomicLoad(u32, &pc.pending_release, .acquire) == idx") != null);

    // The rollback tick still publishes the old task inside the pass, on its own
    // stack. It is only safe to keep as dead code; turning it on brings the window back.
    try std.testing.expect(std.mem.indexOf(u8, sched, "pub const sched_fine_grain_enable: bool = true;") != null);
}

test "FAT32 only claims root names: a path inside a directory is left to ext2" {
    try std.testing.expect(fat32_util.isRootName("writetest.txt"));
    try std.testing.expect(fat32_util.isRootName("/h48_shared.dat"));
    try std.testing.expect(!fat32_util.isRootName(""));
    try std.testing.expect(!fat32_util.isRootName("testdir/subfile.txt"));
    try std.testing.expect(!fat32_util.isRootName("/testdir/x"));
    try std.testing.expect(!fat32_util.isRootName("a/"));
}

test "chmod is reserved to the owner or CAP_FOWNER" {
    try std.testing.expect(dac.mayChmod(1000, 1000, false));
    try std.testing.expect(!dac.mayChmod(0, 1000, false));
    try std.testing.expect(!dac.mayChmod(4242, 1000, false));
    try std.testing.expect(dac.mayChmod(4242, 1000, true));
    try std.testing.expect(!dac.mayChmod(4242, 0, false)); // uid 0 without CAP_FOWNER
    try std.testing.expect(dac.mayChmod(0, 0, false)); // ... still owns its own files
}

test "chown: giving a file away needs CAP_CHOWN, the owner may only pick its own group" {
    // file owned by root:root, caller 1000:1000 without capabilities
    try std.testing.expect(!dac.mayChown(0, 0, 1000, 1000, false, 1000, 1000));
    try std.testing.expect(!dac.mayChown(0, 0, 1000, 1000, false, null, 1000));
    try std.testing.expect(!dac.mayChown(0, 0, 1000, 1000, false, 0, 0)); // non-owner, no-op ids
    // my own file
    try std.testing.expect(dac.mayChown(1000, 1000, 1000, 1000, false, 1000, 1000));
    try std.testing.expect(dac.mayChown(1000, 5, 1000, 1000, false, null, 1000)); // into my own group
    try std.testing.expect(!dac.mayChown(1000, 1000, 1000, 1000, false, 0, null)); // give to root
    try std.testing.expect(!dac.mayChown(1000, 1000, 1000, 1000, false, null, 0)); // a group I am not in
    try std.testing.expect(dac.mayChown(1000, 1000, 1000, 1000, false, null, null));
    try std.testing.expect(dac.mayChown(0, 0, 1000, 1000, false, null, null)); // chown(-1,-1): nothing to authorize
    // capabilities
    try std.testing.expect(dac.mayChown(0, 0, 1000, 1000, true, 1000, 1000));
    try std.testing.expect(!dac.mayChown(1000, 1000, 0, 0, false, 0, 0)); // uid 0 without CAP_CHOWN
    try std.testing.expect(dac.mayChown(1000, 1000, 0, 0, true, 0, 0));
}

test "DAC directory search and write-search permissions" {
    const no_search: dac.Metadata = .{ .mode = 0o0700, .uid = 0, .gid = 0 };
    const world: dac.Metadata = .{ .mode = 0o0777, .uid = 0, .gid = 0 };
    const list_only: dac.Metadata = .{ .mode = 0o0744, .uid = 0, .gid = 0 };
    const who: dac.Credentials = .{ .euid = 1000, .egid = 1000 };
    try std.testing.expect(!dac.allows(no_search, who, dac.Access.search));
    try std.testing.expect(!dac.allows(no_search, who, dac.Access.write_search));
    try std.testing.expect(dac.allows(no_search, .{ .euid = 0, .egid = 0 }, dac.Access.read));
    try std.testing.expect(!dac.allows(no_search, who, dac.Access.read)); // others have no bits at all
    try std.testing.expect(dac.allows(world, who, dac.Access.write_search));
    try std.testing.expect(dac.allows(list_only, who, dac.Access.read));
    try std.testing.expect(!dac.allows(list_only, who, dac.Access.search));
    try std.testing.expect(dac.allows(no_search, .{ .euid = 0, .egid = 0 }, dac.Access.write_search));
    try std.testing.expect(dac.allows(no_search, .{ .euid = 1000, .egid = 1000, .cap_dac_override = true }, dac.Access.write_search));
}

test "sticky directory: only the entry owner, the directory owner or CAP_FOWNER may remove" {
    const tmp: dac.Metadata = .{ .mode = 0o1777, .uid = 0, .gid = 0 };
    const plain: dac.Metadata = .{ .mode = 0o0777, .uid = 0, .gid = 0 };
    const closed: dac.Metadata = .{ .mode = 0o0755, .uid = 0, .gid = 0 };
    const alice: dac.Credentials = .{ .euid = 1000, .egid = 1000 };
    // another user's file in /tmp
    try std.testing.expect(!dac.mayRemoveEntry(tmp, 2000, alice, false));
    // my own file in /tmp
    try std.testing.expect(dac.mayRemoveEntry(tmp, 1000, alice, false));
    // CAP_FOWNER and root bypass the sticky rule
    try std.testing.expect(dac.mayRemoveEntry(tmp, 2000, alice, true));
    try std.testing.expect(dac.mayRemoveEntry(tmp, 2000, .{ .euid = 0, .egid = 0 }, false));
    // the directory's owner may remove anything in it
    try std.testing.expect(dac.mayRemoveEntry(.{ .mode = 0o1777, .uid = 1000, .gid = 0 }, 2000, alice, false));
    // without the sticky bit, write on the directory is enough
    try std.testing.expect(dac.mayRemoveEntry(plain, 2000, alice, false));
    // no write on the directory: never
    try std.testing.expect(!dac.mayRemoveEntry(closed, 1000, alice, false));
}

test "setpriority: only the owner may renice, and only CAP_SYS_NICE may raise priority" {
    const np = kt.nice_policy;
    const base: np.Request = .{ .caller_euid = 1000, .caller_uid = 1000, .target_uid = 1000, .target_euid = 1000, .cap_sys_nice = false, .current_nice = 0, .new_nice = 5 };
    try std.testing.expect(np.maySetNice(base)); // lower my own priority
    var r = base;
    r.new_nice = -5;
    try std.testing.expect(!np.maySetNice(r)); // raise it: needs CAP_SYS_NICE
    r.cap_sys_nice = true;
    try std.testing.expect(np.maySetNice(r));
    r = base;
    r.target_uid = 0;
    r.target_euid = 0;
    try std.testing.expect(!np.maySetNice(r)); // another user's process
    r.caller_euid = 0;
    try std.testing.expect(np.maySetNice(r)); // root may
    r = base;
    r.current_nice = 5;
    r.new_nice = 5;
    try std.testing.expect(np.maySetNice(r)); // unchanged value
}

test "fat32 root scan: an orphaned LFN chain does not swallow the next file's long name" {
    // Bytes as found on the committed disk.img: a deleted file left its two
    // LFN slots ("unlinktest.txt") behind, then a live file follows with its
    // own two-slot LFN chain and short entry.
    var short_name = [_]u8{ 'F', 'S', 'Y', 'N', 'C', '_', '~', '1', 'T', 'X', 'T' };
    var orphan_short = [_]u8{ 'U', 'N', 'L', 'I', 'N', 'K', '~', '1', 'T', 'X', 'T' };
    var orphan: [2][32]u8 = undefined;
    var live: [2][32]u8 = undefined;
    try std.testing.expectEqual(@as(?u32, 2), fat32_util.buildLfnEntries("unlinktest.txt", &orphan_short, orphan[0..]));
    try std.testing.expectEqual(@as(?u32, 2), fat32_util.buildLfnEntries("fsync_probe.txt", &short_name, live[0..]));

    var acc: fat32_util.LfnAccumulator = .{};
    acc.push(&orphan[0]);
    acc.push(&orphan[1]);
    acc.push(&live[0]);
    acc.push(&live[1]);
    var out: [256]u8 = undefined;
    const n = acc.take(&short_name, out[0..]) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("fsync_probe.txt", out[0..n]);
    // take() consumes the chain
    try std.testing.expectEqual(@as(?u32, null), acc.take(&short_name, out[0..]));
}

test "fat32: clusters a file already owns count its preallocated first cluster" {
    // createFile gives an empty file one cluster; the first write must reuse it.
    try std.testing.expectEqual(@as(u32, 1), fat32_util.ownedClusters(0, 512, true));
    try std.testing.expectEqual(@as(u32, 0), fat32_util.ownedClusters(0, 512, false));
    try std.testing.expectEqual(@as(u32, 1), fat32_util.ownedClusters(30, 512, true));
    try std.testing.expectEqual(@as(u32, 1), fat32_util.ownedClusters(512, 512, true));
    try std.testing.expectEqual(@as(u32, 2), fat32_util.ownedClusters(513, 512, true));
    try std.testing.expectEqual(@as(u32, 8), fat32_util.ownedClusters(4096, 512, true));
}

test "fat32: FAT updates are mirrored to every FAT copy" {
    var lbas: [4]u32 = undefined;
    // fat_start 32, 504 sectors per FAT, 2 FATs, entry in sector 3 of the FAT
    try std.testing.expectEqual(@as(u32, 2), fat32_util.fatCopySectors(32, 504, 2, 32 + 3, &lbas));
    try std.testing.expectEqual(@as(u32, 35), lbas[0]);
    try std.testing.expectEqual(@as(u32, 32 + 504 + 3), lbas[1]);
    // a single-FAT volume writes once; a bogus count is clamped to the buffer
    try std.testing.expectEqual(@as(u32, 1), fat32_util.fatCopySectors(32, 504, 1, 35, &lbas));
    try std.testing.expectEqual(@as(u32, 4), fat32_util.fatCopySectors(32, 504, 9, 35, &lbas));
}

test "fat32: the allocator never hands out clusters past the end of the FAT32 region" {
    // Root disk layout: FAT32 BPB at LBA 0 claims 65536 sectors, but ext2
    // starts at LBA 32768. data_start 1040, 1 sector per cluster.
    const limit = fat32_util.allocLimitCluster(1040, 1, 64496, 32768);
    // cluster c lives at LBA 1040 + (c - 2); the last one below 32768 is 31729
    try std.testing.expectEqual(@as(u32, 31730), limit); // exclusive bound
    try std.testing.expectEqual(@as(u32, 32767), 1040 + (limit - 1 - 2));
    // no foreign volume: the BPB's own cluster count is the bound
    try std.testing.expectEqual(@as(u32, 64496 + 2), fat32_util.allocLimitCluster(1040, 1, 64496, 0));
    // a foreign volume beyond the BPB's own end changes nothing
    try std.testing.expectEqual(@as(u32, 64496 + 2), fat32_util.allocLimitCluster(1040, 1, 64496, 1 << 20));
    // 8 sectors per cluster: a cluster that would straddle the boundary is excluded
    try std.testing.expectEqual(@as(u32, 2 + (32768 - 1040) / 8), fat32_util.allocLimitCluster(1040, 8, 8062, 32768));
    // a foreign volume inside the FAT32 metadata leaves nothing to allocate
    try std.testing.expectEqual(@as(u32, 2), fat32_util.allocLimitCluster(1040, 1, 64496, 512));
}

test "ext2: a freshly allocated inode gets a clean extended area" {
    const eu = kt.ext2_util;
    // 256-byte inodes on this volume: bytes 128..256 are the extended area.
    var rec: [256]u8 = undefined;
    @memset(&rec, 0xAB); // stale bytes left by an earlier owner of the slot
    eu.initExtraInode(rec[0..], 256);
    // i_extra_isize = 32 (the size e2fsprogs writes for the fields it knows),
    // every other extended byte is zero.
    try std.testing.expectEqual(@as(u16, 32), std.mem.readInt(u16, rec[128..130], .little));
    for (rec[130..256]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    // the base inode is left alone (the caller writes it separately)
    for (rec[0..128]) |b| try std.testing.expectEqual(@as(u8, 0xAB), b);
    // 128-byte inodes have no extended area: nothing changes
    var small: [128]u8 = undefined;
    @memset(&small, 0xCD);
    eu.initExtraInode(small[0..], 128);
    for (small) |b| try std.testing.expectEqual(@as(u8, 0xCD), b);
}

test "ext2: a freed inode record is marked deleted for fsck" {
    const eu = kt.ext2_util;
    var ino = std.mem.zeroes(eu.Ext2Inode);
    ino.mode = 0o40755;
    ino.links_count = 2;
    eu.markInodeDeleted(&ino, 1_700_000_000);
    try std.testing.expectEqual(@as(u16, 0), ino.links_count);
    try std.testing.expectEqual(@as(u32, 1_700_000_000), ino.dtime);
    // without a wall clock dtime must still be non-zero, or fsck treats the slot as in use
    var ino2 = std.mem.zeroes(eu.Ext2Inode);
    ino2.links_count = 1;
    eu.markInodeDeleted(&ino2, 0);
    try std.testing.expect(ino2.dtime != 0);
}

test "fat32: deleting a file tombstones exactly its own long-name slots" {
    var sn: [11]u8 = undefined;
    @memcpy(sn[0..], "HELLO1~1TXT");
    var own: [4][32]u8 = undefined;
    const n = fat32_util.buildLfnEntries("hello112-grow-long-name.txt", &sn, own[0..]).?;
    try std.testing.expectEqual(@as(u32, 3), n);
    // an older orphaned single-slot run for another name sits in front
    var other_sn: [11]u8 = undefined;
    @memcpy(other_sn[0..], "OTHER   TXT");
    var orphan: [1][32]u8 = undefined;
    _ = fat32_util.buildLfnEntries("other.txt", &other_sn, orphan[0..]).?;
    var ptrs: [4][*]const u8 = .{ &orphan[0], &own[0], &own[1], &own[2] };
    try std.testing.expectEqual(@as(u32, 3), fat32_util.ownedLfnRun(ptrs[0..], &sn));
    try std.testing.expectEqual(@as(u32, 3), fat32_util.ownedLfnRun(ptrs[1..], &sn));
    // a run whose checksum does not match is not ours
    try std.testing.expectEqual(@as(u32, 0), fat32_util.ownedLfnRun(ptrs[1..], &other_sn));
    // an incomplete run (missing the last-slot marker) is not ours either
    try std.testing.expectEqual(@as(u32, 0), fat32_util.ownedLfnRun(ptrs[2..], &sn));
    try std.testing.expectEqual(@as(u32, 0), fat32_util.ownedLfnRun(ptrs[0..0], &sn));
}

test "fat32: FSInfo free-count and next-free hint become unknown" {
    var sec = [_]u8{0} ** 512;
    std.mem.writeInt(u32, sec[0..4], 0x41615252, .little);
    std.mem.writeInt(u32, sec[484..488], 0x61417272, .little);
    std.mem.writeInt(u32, sec[488..492], 64482, .little);
    std.mem.writeInt(u32, sec[492..496], 2, .little);
    sec[510] = 0x55;
    sec[511] = 0xAA;
    try std.testing.expect(fat32_util.invalidateFsInfo(sec[0..]));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), std.mem.readInt(u32, sec[488..492], .little));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), std.mem.readInt(u32, sec[492..496], .little));
    try std.testing.expectEqual(@as(u8, 0x55), sec[510]);
    // not an FSInfo sector: untouched
    var junk = [_]u8{0x11} ** 512;
    try std.testing.expect(!fat32_util.invalidateFsInfo(junk[0..]));
    for (junk) |b| try std.testing.expectEqual(@as(u8, 0x11), b);
}

test "fat32: BPB exposes the FSInfo sector" {
    var b = [_]u8{0} ** 512;
    std.mem.writeInt(u16, b[11..13], 512, .little);
    b[13] = 1;
    std.mem.writeInt(u16, b[14..16], 32, .little);
    b[16] = 2;
    std.mem.writeInt(u32, b[32..36], 65536, .little);
    std.mem.writeInt(u32, b[36..40], 504, .little);
    std.mem.writeInt(u32, b[44..48], 2, .little);
    std.mem.writeInt(u16, b[48..50], 1, .little);
    @memcpy(b[82..87], "FAT32");
    try std.testing.expectEqual(@as(u32, 2048 + 1), fat32_util.parseBpb(&b, 2048).?.fsinfo_lba);
    std.mem.writeInt(u16, b[48..50], 0xFFFF, .little);
    try std.testing.expectEqual(@as(u32, 0), fat32_util.parseBpb(&b, 0).?.fsinfo_lba);
}

test "credentials: uid changes follow capabilities(7) and CAP_SETUID gates arbitrary ids" {
    const cp = kt.cred_policy;
    const K = cp.KEEP;
    const root: cp.Ids = .{ .r = 0, .e = 0, .s = 0 };
    const all: cp.Caps = .{ .effective = 0xFFFF, .permitted = 0xFFFF };
    // root drops to 1000 for good: every capability goes with it
    const dropped = cp.setOne(root, 1000, true).?;
    try std.testing.expectEqual(@as(u32, 1000), dropped.s);
    const c1 = cp.capsAfterUidChange(root, dropped, all);
    try std.testing.expectEqual(@as(u32, 0), c1.permitted);
    try std.testing.expectEqual(@as(u32, 0), c1.effective);
    // temporary drop (saved uid stays 0): effective cleared, permitted kept
    const tmp = cp.setres(root, K, 1000, K, true).?;
    const c2 = cp.capsAfterUidChange(root, tmp, all);
    try std.testing.expectEqual(@as(u32, 0), c2.effective);
    try std.testing.expectEqual(@as(u32, 0xFFFF), c2.permitted);
    // ... and back to euid 0 without CAP_SETUID (0 is the saved uid): effective restored
    const back = cp.setres(tmp, K, 0, K, false).?;
    const c3 = cp.capsAfterUidChange(tmp, back, c2);
    try std.testing.expectEqual(@as(u32, 0xFFFF), c3.effective);
    // an unprivileged user cannot pick a foreign id, even when its euid is 0 ...
    const u: cp.Ids = .{ .r = 1000, .e = 1000, .s = 1000 };
    try std.testing.expect(cp.setOne(u, 0, false) == null);
    try std.testing.expect(cp.setres(u, K, 0, K, false) == null);
    try std.testing.expect(cp.setre(u, 0, K, false) == null);
    try std.testing.expect(cp.setres(.{ .r = 0, .e = 0, .s = 0 }, 4242, K, K, false) == null);
    // ... but may swap among its own ids
    const own = cp.setres(.{ .r = 1000, .e = 2000, .s = 3000 }, 3000, 1000, 2000, false).?;
    try std.testing.expectEqual(@as(u32, 3000), own.r);
    // unprivileged setuid changes only the effective id
    const eff = cp.setOne(.{ .r = 1000, .e = 2000, .s = 2000 }, 1000, false).?;
    try std.testing.expectEqual(@as(u32, 2000), eff.s);
    try std.testing.expectEqual(@as(u32, 1000), eff.e);
    // setreuid: setting the real id moves the saved id to the new effective id
    const re = cp.setre(.{ .r = 1000, .e = 1000, .s = 0 }, 1000, 1000, false).?;
    try std.testing.expectEqual(@as(u32, 1000), re.s);
    // a non-root user's capabilities are untouched by its own id shuffles
    const c4 = cp.capsAfterUidChange(u, u, .{ .effective = 4, .permitted = 4 });
    try std.testing.expectEqual(@as(u32, 4), c4.effective);
}

test "only hello115, hello119, hello123 and hello126 start as root with just the ID capabilities" {
    for ([_][]const u8{ "hello115", "hello119", "hello123", "hello126" }) |name| {
        const p = capability_profile.profileForLaunch(name, true, false);
        try std.testing.expectEqual(@as(u32, 0), p.uid);
        try std.testing.expect(p.caps.cap_setuid and p.caps.cap_setgid);
        try std.testing.expectEqual(@as(u32, 2), @popCount(@as(u32, @bitCast(p.caps))));
        const untrusted = capability_profile.profileForLaunch(name, false, false);
        try std.testing.expectEqual(@as(u32, 1000), untrusted.uid);
        try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(untrusted.caps)));
    }
    try std.testing.expectEqual(@as(u32, 1000), capability_profile.profileForLaunch("hello118", true, false).uid);
}

test "supplementary groups select the group class and widen chown targets" {
    const gp = kt.group_policy;
    const sup = [_]u32{ 50, 60 };
    try std.testing.expect(gp.member(1000, &sup, 1000));
    try std.testing.expect(gp.member(1000, &sup, 60));
    try std.testing.expect(!gp.member(1000, &sup, 70));
    // 0640 root:60 file, caller 1000:1000 in supplementary group 60 reads it
    const meta: dac.Metadata = .{ .mode = 0o640, .uid = 0, .gid = 60 };
    try std.testing.expect(dac.allows(meta, .{ .euid = 1000, .egid = 1000, .groups = &sup }, .read));
    try std.testing.expect(!dac.allows(meta, .{ .euid = 1000, .egid = 1000, .groups = &sup }, .write));
    try std.testing.expect(!dac.allows(meta, .{ .euid = 1000, .egid = 1000 }, .read));
    // the owner may hand its file to a supplementary group, not to a foreign one
    try std.testing.expect(dac.mayChownIn(1000, 1000, 1000, 1000, &sup, false, null, 50));
    try std.testing.expect(!dac.mayChownIn(1000, 1000, 1000, 1000, &sup, false, null, 70));
    // getgroups/setgroups argument rules
    try std.testing.expectEqual(gp.GetResult{ .count = 2 }, gp.get(0, 2));
    try std.testing.expectEqual(gp.GetResult{ .copy = 2 }, gp.get(5, 2));
    try std.testing.expectEqual(gp.GetResult.einval, gp.get(1, 2));
    try std.testing.expectEqual(gp.GetResult.einval, gp.get(-1, 0));
    try std.testing.expectEqual(gp.SetCheck.eperm, gp.checkSet(1, false));
    try std.testing.expectEqual(gp.SetCheck.einval, gp.checkSet(gp.NGROUPS_MAX + 1, true));
    try std.testing.expectEqual(gp.SetCheck.einval, gp.checkSet(-1, true));
    try std.testing.expectEqual(gp.SetCheck.ok, gp.checkSet(0, true));
}

test "credentials: execve copies euid into the saved uid and drops capabilities without a root uid" {
    const cp = kt.cred_policy;
    const all: cp.Caps = .{ .effective = 0, .permitted = 0x60 };
    // uid 1000 with root kept only as the saved uid: the new program is unprivileged
    const a = cp.afterExec(.{ .r = 1000, .e = 1000, .s = 0 }, .{ .r = 1000, .e = 1000, .s = 0 }, all);
    try std.testing.expectEqual(@as(u32, 1000), a.uid.s);
    try std.testing.expectEqual(@as(u32, 1000), a.gid.s);
    try std.testing.expectEqual(@as(u32, 0), a.caps.permitted);
    try std.testing.expectEqual(@as(u32, 0), a.caps.effective);
    // root: permitted kept, effective raised to permitted
    const b = cp.afterExec(.{ .r = 0, .e = 0, .s = 0 }, .{ .r = 0, .e = 0, .s = 0 }, all);
    try std.testing.expectEqual(@as(u32, 0x60), b.caps.permitted);
    try std.testing.expectEqual(@as(u32, 0x60), b.caps.effective);
    // real root, effective 1000: permitted kept but nothing effective
    const c = cp.afterExec(.{ .r = 0, .e = 1000, .s = 0 }, .{ .r = 0, .e = 0, .s = 0 }, all);
    try std.testing.expectEqual(@as(u32, 1000), c.uid.s);
    try std.testing.expectEqual(@as(u32, 0x60), c.caps.permitted);
    try std.testing.expectEqual(@as(u32, 0), c.caps.effective);
    // never more than the task already had
    const d = cp.afterExec(.{ .r = 0, .e = 0, .s = 0 }, .{ .r = 0, .e = 0, .s = 0 }, .{ .effective = 0, .permitted = 0 });
    try std.testing.expectEqual(@as(u32, 0), d.caps.effective);
}

test "procfs: /proc/PID/maps pins the target address space before walking it" {
    const src = kt.procfs_source;
    const start = std.mem.indexOf(u8, src, "fn generatePidMaps(").?;
    const end = std.mem.indexOfPos(u8, src, start, "\nfn ").?;
    const body = src[start..end];
    // looked up and retained under task_lock, released after the walk
    const lock = std.mem.indexOf(u8, body, "lockTask()").?;
    const retain = std.mem.indexOf(u8, body, "retainUserSpace(root)").?;
    const unlock = std.mem.indexOf(u8, body, "unlockTask(flags)").?;
    const walk = std.mem.indexOf(u8, body, "enumerateVMAs(root").?;
    try std.testing.expect(lock < retain and retain < walk);
    try std.testing.expect(std.mem.indexOf(u8, body, "defer user_space.destroyUserSpace(root)") != null);
    _ = unlock;
    // never walks through an unpinned task pointer
    try std.testing.expect(std.mem.indexOf(u8, body, "t.page_table_phys") == null);
}

test "ext2: every path-to-inode resolution used by syscalls checks search permission" {
    const src = kt.ext2_source;
    // the unchecked walkers are gone; one resolver takes the caller's credentials
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn walkPathToInodePublic(") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn walkPathToInodeNoFollow(") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "fn walkPathToInodeResolve(") == null);
    const r = std.mem.indexOf(u8, src, "fn resolveInode(").?;
    const r_end = std.mem.indexOfPos(u8, src, r, "\n}\n").?;
    const body = src[r..r_end];
    try std.testing.expect(std.mem.indexOf(u8, body, "Access.search") != null);
    // symlink targets are resolved with the same credentials
    try std.testing.expect(std.mem.indexOf(u8, body, "resolveInode(new_start, target, depth + 1, who, true)") != null);
    const se = kt.syscall_entry_source;
    try std.testing.expect(std.mem.indexOf(u8, se, "walkPathToInodePublic") == null);
    // native truncate(76) is the authorized #210 path
    const t76 = std.mem.indexOf(u8, se, "        76 => {").?;
    const t76_end = std.mem.indexOfPos(u8, se, t76, "},").?;
    try std.testing.expect(std.mem.indexOf(u8, se[t76..t76_end], "syscallTruncate(") != null);
}

test "SysV IPC_SET: owner may hand an object to another uid/gid; the creator ids never change" {
    const owner: sysv_policy.Owner = .{ .uid = 1000, .gid = 1000, .cuid = 1000, .cgid = 1000 };
    const K = sysv_policy.IPC_SET_KEEP;
    // owner transfers ownership and changes the mode
    const r = sysv_policy.applySet(owner, .{ .euid = 1000, .egid = 1000 }, .{ .mode = 0o640, .uid = 2000, .gid = 60 }).?;
    try std.testing.expectEqual(@as(u32, 2000), r.owner.uid);
    try std.testing.expectEqual(@as(u32, 60), r.owner.gid);
    try std.testing.expectEqual(@as(u32, 1000), r.owner.cuid);
    try std.testing.expectEqual(@as(u32, 0o640), r.mode);
    // KEEP leaves a field alone; mode bits above 0777 are ignored
    const k = sysv_policy.applySet(owner, .{ .euid = 1000, .egid = 1000 }, .{ .mode = 0o7644, .uid = K, .gid = K }).?;
    try std.testing.expectEqual(@as(u32, 1000), k.owner.uid);
    try std.testing.expectEqual(@as(u32, 0o644), k.mode);
    // the creator keeps management rights after giving the object away
    const after: sysv_policy.Owner = r.owner;
    try std.testing.expect(sysv_policy.applySet(after, .{ .euid = 1000, .egid = 1000 }, .{ .mode = 0o600, .uid = K, .gid = K }) != null);
    // a stranger may not
    try std.testing.expect(sysv_policy.applySet(owner, .{ .euid = 4242, .egid = 4242 }, .{ .mode = 0o600, .uid = 4242, .gid = K }) == null);
    // CAP_SYS_ADMIN may
    try std.testing.expect(sysv_policy.applySet(owner, .{ .euid = 4242, .egid = 4242, .cap_sys_admin = true }, .{ .mode = 0o600, .uid = 4242, .gid = K }) != null);
    // buffer decoding: the one-word form only sets the mode
    try std.testing.expect(!sysv_policy.isExtendedSet(0o600));
    const old = sysv_policy.decodeSet(0o600, null);
    try std.testing.expectEqual(K, old.uid);
    try std.testing.expectEqual(@as(u32, 0o600), old.mode);
    const ext_first = 0o640 | sysv_policy.IPC_SET_EXTENDED;
    try std.testing.expect(sysv_policy.isExtendedSet(ext_first));
    const ext = sysv_policy.decodeSet(ext_first, .{ 2000, 60 });
    try std.testing.expectEqual(@as(u32, 0o640), ext.mode);
    try std.testing.expectEqual(@as(u32, 2000), ext.uid);
    try std.testing.expectEqual(@as(u32, 60), ext.gid);
}

test "rlimit: every Linux resource round-trips; out-of-range resources are EINVAL" {
    const rl = kt.rlimit;
    try std.testing.expectEqual(@as(u32, 16), rl.RLIM_NLIMITS);
    // the six enforced resources keep their dedicated fields; the rest live in the recorded table
    try std.testing.expect(rl.recordedSlot(4) != null); // RLIMIT_CORE
    try std.testing.expect(rl.recordedSlot(5) != null); // RLIMIT_RSS
    try std.testing.expect(rl.recordedSlot(15) != null); // RLIMIT_RTTIME
    try std.testing.expect(rl.recordedSlot(7) == null); // NOFILE has its own field
    try std.testing.expect(rl.recordedSlot(16) == null);
    try std.testing.expect(!rl.resourceValid(16));
    try std.testing.expect(rl.resourceValid(0));
    var table = rl.RecordedLimits{};
    const core = rl.recordedSlot(4).?;
    try std.testing.expectEqual(rl.RLIM_INFINITY, table.get(core).cur);
    // lowering needs no privilege; raising the hard limit back does
    try table.set(core, .{ .cur = 0, .max = 0 }, false);
    try std.testing.expectEqual(@as(u64, 0), table.get(core).max);
    try std.testing.expectError(error.WouldLowerHardLimit, table.set(core, .{ .cur = 0, .max = 10 }, false));
    try table.set(core, .{ .cur = 0, .max = 10 }, true);
    try std.testing.expectError(error.InvalidLimit, table.set(core, .{ .cur = 11, .max = 10 }, true));
    try std.testing.expectEqual(@as(u64, 10), table.get(core).max);
}

test "rlimit: task creation no longer seeds limits per task (they come with the Mm)" {
    const src = kt.task_source;
    try std.testing.expect(std.mem.indexOf(u8, src, "recorded_limits") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "fSize_max") == null);
}

test "virtio-blk: FLUSH is negotiated when offered and fsync reaches it" {
    const vb = kt.virtio_blk_policy;
    // the driver accepts exactly DISCARD and FLUSH out of what the device offers
    try std.testing.expectEqual(@as(u32, vb.F_FLUSH | vb.F_DISCARD), vb.negotiate(vb.F_FLUSH | vb.F_DISCARD | (1 << 5)));
    try std.testing.expectEqual(@as(u32, vb.F_FLUSH), vb.negotiate(vb.F_FLUSH));
    try std.testing.expectEqual(@as(u32, 0), vb.negotiate(1 << 5));
    try std.testing.expectEqual(@as(u32, 4), vb.T_FLUSH);
    try std.testing.expectEqual(@as(u32, 1 << 9), vb.F_FLUSH);
    // block_dev routes a virtio flush to the driver instead of failing it
    const bd = kt.block_dev_source;
    const f = std.mem.indexOf(u8, bd, "pub fn flush(dev: u8) i32 {").?;
    const f_end = std.mem.indexOfPos(u8, bd, f, "\n}\n").?;
    try std.testing.expect(std.mem.indexOf(u8, bd[f..f_end], ".virtio_blk => return -1") == null);
}

test "fsync/sync flush the disk the filesystems live on, not global device 0" {
    const se = kt.syscall_entry_source;
    try std.testing.expect(std.mem.indexOf(u8, se, "supportsFlush(0)") == null);
    try std.testing.expect(std.mem.indexOf(u8, se, "block_dev.flush(0)") == null);
    const h = std.mem.indexOf(u8, se, "fn flushRootDiskCache() bool {").?;
    const h_end = std.mem.indexOfPos(u8, se, h, "\n}\n").?;
    try std.testing.expect(std.mem.indexOf(u8, se[h..h_end], "findByDriver(.virtio_blk, 0)") != null);
    // both durability calls use it
    const sync = std.mem.indexOf(u8, se, "246 => { // sync()").?;
    try std.testing.expect(std.mem.indexOfPos(u8, se, sync, "flushRootDiskCache()").? < std.mem.indexOfPos(u8, se, sync, "247 =>").?);
    const fs = std.mem.indexOf(u8, se, "fn syscallFsync(").?;
    try std.testing.expect(std.mem.indexOfPos(u8, se, fs, "flushRootDiskCache()").? < std.mem.indexOfPos(u8, se, fs, "\n}\n").?);
}

test "prctl: PDEATHSIG validated, NO_NEW_PRIVS is a one-way flag" {
    const pp = kt.prctl_policy;
    try std.testing.expect(pp.pdeathsigValid(0));
    try std.testing.expect(pp.pdeathsigValid(9));
    try std.testing.expect(pp.pdeathsigValid(31));
    try std.testing.expect(!pp.pdeathsigValid(32)); // no real-time signals to deliver
    try std.testing.expect(!pp.pdeathsigValid(0xFFFF_FFFF_0000_0009));
    // PR_SET_NO_NEW_PRIVS: arg2 must be exactly 1 and the rest 0; it cannot be cleared
    try std.testing.expectEqual(pp.NnpSet.set, pp.setNoNewPrivs(1, 0, 0, 0));
    try std.testing.expectEqual(pp.NnpSet.einval, pp.setNoNewPrivs(0, 0, 0, 0));
    try std.testing.expectEqual(pp.NnpSet.einval, pp.setNoNewPrivs(2, 0, 0, 0));
    try std.testing.expectEqual(pp.NnpSet.einval, pp.setNoNewPrivs(1, 1, 0, 0));
    try std.testing.expect(pp.getNoNewPrivsArgsValid(0, 0, 0, 0));
    try std.testing.expect(!pp.getNoNewPrivsArgsValid(1, 0, 0, 0));
    // death signal targets: only non-thread children of the exiting task that asked for one
    try std.testing.expectEqual(@as(?u32, 9), pp.deathSignalFor(100, 100, false, 9));
    try std.testing.expectEqual(@as(?u32, null), pp.deathSignalFor(100, 100, false, 0));
    try std.testing.expectEqual(@as(?u32, null), pp.deathSignalFor(100, 100, true, 9));
    try std.testing.expectEqual(@as(?u32, null), pp.deathSignalFor(101, 100, false, 9));
}

test "open_tree_attr / file_getattr / file_setattr are ENOSYS, not a silent success" {
    try std.testing.expectEqual(kt.errno.ENOSYS, unsupported_policy.openTreeAttr());
    try std.testing.expectEqual(kt.errno.ENOSYS, unsupported_policy.fileGetattr());
    try std.testing.expectEqual(kt.errno.ENOSYS, unsupported_policy.fileSetattr());
    const se = kt.syscall_entry_source;
    try std.testing.expect(std.mem.indexOf(u8, se, "frame.rax = 0; // accept (simplified)") == null);
}

test "syslog(2): action decoding, privilege and the global read cursor" {
    const sp = kt.syslog_policy;
    // reads/clears need privilege; the size query does not
    try std.testing.expectEqual(sp.Action.read_all, sp.decode(3).?);
    try std.testing.expectEqual(sp.Action.read_unread, sp.decode(2).?);
    try std.testing.expectEqual(sp.Action.read_clear, sp.decode(4).?);
    try std.testing.expectEqual(sp.Action.clear, sp.decode(5).?);
    try std.testing.expectEqual(sp.Action.size_unread, sp.decode(9).?);
    try std.testing.expectEqual(sp.Action.size_buffer, sp.decode(10).?);
    try std.testing.expectEqual(sp.Action.console_level, sp.decode(8).?);
    try std.testing.expectEqual(sp.Error.eperm, sp.check(3, 100, false).?);
    try std.testing.expectEqual(sp.Error.eperm, sp.check(5, 0, false).?);
    try std.testing.expect(sp.check(10, 0, false) == null);
    // bad type, negative length, bad console level
    try std.testing.expectEqual(sp.Error.einval, sp.check(42, 0, true).?);
    try std.testing.expectEqual(sp.Error.einval, sp.check(3, -1, true).?);
    try std.testing.expectEqual(sp.Error.einval, sp.check(8, 9, true).?);
    try std.testing.expect(sp.check(3, 0, true) == null);
    // "clear" moves a cursor; reads of type 3 start from it, type 2 from the unread cursor
    var st = sp.State{};
    try std.testing.expectEqual(@as(u64, 0), st.startFor(.read_all, 0));
    st.clear(500);
    try std.testing.expectEqual(@as(u64, 500), st.startFor(.read_all, 100)); // oldest 100, cleared to 500
    try std.testing.expectEqual(@as(u64, 600), st.startFor(.read_all, 600)); // ring dropped past it
    try std.testing.expectEqual(@as(u64, 0), st.startFor(.read_unread, 0));
    st.consumed(700);
    try std.testing.expectEqual(@as(u64, 700), st.startFor(.read_unread, 0));
}

test "memfd_create: flag and name validation" {
    const mp = kt.memfd_policy;
    try std.testing.expect(mp.flagsValid(0));
    try std.testing.expect(mp.flagsValid(mp.MFD_CLOEXEC));
    try std.testing.expect(mp.flagsValid(mp.MFD_CLOEXEC | mp.MFD_ALLOW_SEALING));
    try std.testing.expect(!mp.flagsValid(mp.MFD_HUGETLB)); // no hugetlbfs
    try std.testing.expect(!mp.flagsValid(0x100));
    // Linux: the name (without the "memfd:" prefix) may be at most 249 bytes
    try std.testing.expect(mp.nameLenValid(0));
    try std.testing.expect(mp.nameLenValid(249));
    try std.testing.expect(!mp.nameLenValid(250));
}

test "memfd seals: add rules and what each seal forbids" {
    const mp = kt.memfd_policy;
    // a memfd created without MFD_ALLOW_SEALING starts with F_SEAL_SEAL (nothing can be added)
    try std.testing.expectEqual(mp.F_SEAL_SEAL, mp.initialSeals(0));
    try std.testing.expectEqual(@as(u32, 0), mp.initialSeals(mp.MFD_ALLOW_SEALING));
    // adding: unknown bits EINVAL, F_SEAL_SEAL present EPERM, otherwise OR-ed in
    try std.testing.expectEqual(mp.AddResult{ .ok = mp.F_SEAL_GROW }, mp.addSeals(0, mp.F_SEAL_GROW));
    try std.testing.expectEqual(mp.AddResult{ .ok = mp.F_SEAL_GROW | mp.F_SEAL_SHRINK }, mp.addSeals(mp.F_SEAL_GROW, mp.F_SEAL_SHRINK));
    try std.testing.expectEqual(mp.AddResult.eperm, mp.addSeals(mp.F_SEAL_SEAL, mp.F_SEAL_GROW));
    try std.testing.expectEqual(mp.AddResult.einval, mp.addSeals(0, 0x100));
    // what the seals forbid
    try std.testing.expect(!mp.writeAllowed(mp.F_SEAL_WRITE, 0, 1, 10));
    try std.testing.expect(mp.writeAllowed(mp.F_SEAL_GROW, 0, 4, 10)); // inside the current size
    try std.testing.expect(!mp.writeAllowed(mp.F_SEAL_GROW, 8, 4, 10)); // would grow
    try std.testing.expect(mp.writeAllowed(0, 8, 4, 10));
    try std.testing.expect(!mp.truncateAllowed(mp.F_SEAL_SHRINK, 5, 10));
    try std.testing.expect(mp.truncateAllowed(mp.F_SEAL_SHRINK, 20, 10));
    try std.testing.expect(!mp.truncateAllowed(mp.F_SEAL_GROW, 20, 10));
    try std.testing.expect(mp.truncateAllowed(mp.F_SEAL_GROW | mp.F_SEAL_SHRINK, 10, 10)); // no change
}

test "memfd seals vs mmap: F_SEAL_WRITE forbids new shared writable mappings and is refused while one exists" {
    const mp = kt.memfd_policy;
    // mapping a sealed file
    try std.testing.expect(!mp.mmapAllowed(mp.F_SEAL_WRITE, true, true));
    try std.testing.expect(!mp.mmapAllowed(mp.F_SEAL_FUTURE_WRITE, true, true));
    try std.testing.expect(mp.mmapAllowed(mp.F_SEAL_WRITE, true, false)); // shared read-only is fine
    try std.testing.expect(mp.mmapAllowed(mp.F_SEAL_WRITE, false, true)); // private COW is fine
    try std.testing.expect(mp.mmapAllowed(0, true, true));
    // sealing while a shared writable mapping exists: EBUSY for WRITE, not for FUTURE_WRITE
    try std.testing.expectEqual(mp.AddResult.ebusy, mp.addSealsMapped(0, mp.F_SEAL_WRITE, 1));
    try std.testing.expectEqual(mp.AddResult{ .ok = mp.F_SEAL_FUTURE_WRITE }, mp.addSealsMapped(0, mp.F_SEAL_FUTURE_WRITE, 1));
    try std.testing.expectEqual(mp.AddResult{ .ok = mp.F_SEAL_WRITE }, mp.addSealsMapped(0, mp.F_SEAL_WRITE, 0));
    try std.testing.expectEqual(mp.AddResult{ .ok = mp.F_SEAL_GROW }, mp.addSealsMapped(0, mp.F_SEAL_GROW, 1));
}

test "memfd seals vs mmap: a shared mapping of a write-sealed file can never become writable" {
    const mp = kt.memfd_policy;
    try std.testing.expect(!mp.mapMayWrite(mp.F_SEAL_WRITE, true, true));
    try std.testing.expect(!mp.mapMayWrite(mp.F_SEAL_FUTURE_WRITE, true, true));
    try std.testing.expect(mp.mapMayWrite(mp.F_SEAL_WRITE, false, true)); // private COW
    try std.testing.expect(mp.mapMayWrite(mp.F_SEAL_GROW, true, true));
    try std.testing.expect(!mp.mapMayWrite(0, true, false)); // read-only fd
}

test "renameat2 flags: NOREPLACE, EXCHANGE, and EINVAL for unknown, WHITEOUT and both together" {
    const rp = kt.rename_policy;
    try std.testing.expectEqual(rp.Mode.replace, rp.mode(0).ok);
    try std.testing.expectEqual(rp.Mode.noreplace, rp.mode(rp.RENAME_NOREPLACE).ok);
    try std.testing.expectEqual(rp.Mode.exchange, rp.mode(rp.RENAME_EXCHANGE).ok);
    try std.testing.expectEqual(@as(i64, -22), rp.mode(rp.RENAME_NOREPLACE | rp.RENAME_EXCHANGE).err);
    try std.testing.expectEqual(@as(i64, -22), rp.mode(rp.RENAME_WHITEOUT).err);
    try std.testing.expectEqual(@as(i64, -22), rp.mode(0x100).err);
}

test "rename routing: /tmp to /tmp is tmpfs, /tmp to elsewhere is EXDEV, /tmpx is not /tmp" {
    const rp = kt.rename_policy;
    try std.testing.expectEqual(rp.Route.tmpfs, rp.route("/tmp/a", "/tmp/b"));
    try std.testing.expectEqual(rp.Route.cross, rp.route("/tmp/a", "/b"));
    try std.testing.expectEqual(rp.Route.cross, rp.route("/a", "/tmp/b"));
    try std.testing.expectEqual(rp.Route.other, rp.route("/a", "/b"));
    try std.testing.expectEqual(rp.Route.other, rp.route("/tmpx/a", "/b"));
}

test "rename target rules: type mismatch, non-empty directory, NOREPLACE and EXCHANGE" {
    const rp = kt.rename_policy;
    try std.testing.expectEqual(@as(i64, 0), rp.checkTarget(.replace, false, .{ .exists = false }));
    try std.testing.expectEqual(@as(i64, 0), rp.checkTarget(.replace, false, .{ .exists = true }));
    try std.testing.expectEqual(@as(i64, -21), rp.checkTarget(.replace, false, .{ .exists = true, .is_dir = true }));
    try std.testing.expectEqual(@as(i64, -20), rp.checkTarget(.replace, true, .{ .exists = true }));
    try std.testing.expectEqual(@as(i64, -39), rp.checkTarget(.replace, true, .{ .exists = true, .is_dir = true, .empty = false }));
    try std.testing.expectEqual(@as(i64, 0), rp.checkTarget(.replace, true, .{ .exists = true, .is_dir = true }));
    try std.testing.expectEqual(@as(i64, -17), rp.checkTarget(.noreplace, false, .{ .exists = true }));
    try std.testing.expectEqual(@as(i64, 0), rp.checkTarget(.noreplace, false, .{ .exists = false }));
    try std.testing.expectEqual(@as(i64, -2), rp.checkTarget(.exchange, false, .{ .exists = false }));
    try std.testing.expectEqual(@as(i64, 0), rp.checkTarget(.exchange, true, .{ .exists = true }));
}

test "directory rename link deltas: a cross-parent move shifts one link from the old parent to the new" {
    const rp = kt.rename_policy;
    const same = rp.dirMoveLinkDelta(5, 5);
    try std.testing.expectEqual(@as(i32, 0), same.old_parent);
    try std.testing.expectEqual(@as(i32, 0), same.new_parent);
    const cross = rp.dirMoveLinkDelta(5, 9);
    try std.testing.expectEqual(@as(i32, -1), cross.old_parent);
    try std.testing.expectEqual(@as(i32, 1), cross.new_parent);
}

test "directory rename cycle check: the destination parent chain may not pass through the moved directory" {
    const rp = kt.rename_policy;
    // ancestors of the destination parent, nearest first, ending at root (2)
    try std.testing.expect(rp.dirMoveCreatesCycle(12, &.{ 12, 2 })); // into itself
    try std.testing.expect(rp.dirMoveCreatesCycle(12, &.{ 15, 12, 2 })); // into a descendant
    try std.testing.expect(!rp.dirMoveCreatesCycle(12, &.{ 13, 2 })); // into a sibling
    try std.testing.expect(!rp.dirMoveCreatesCycle(12, &.{2})); // into root
}

test "directory rename over an empty directory: the victim's link goes, so the old parent loses one and the new parent nets zero" {
    const rp = kt.rename_policy;
    const same = rp.dirReplaceLinkDelta(5, 5);
    try std.testing.expectEqual(@as(i32, -1), same.old_parent);
    try std.testing.expectEqual(@as(i32, 0), same.new_parent);
    const cross = rp.dirReplaceLinkDelta(5, 9);
    try std.testing.expectEqual(@as(i32, -1), cross.old_parent);
    try std.testing.expectEqual(@as(i32, 0), cross.new_parent);
}

test "rename exchange link deltas: only a directory/non-directory swap across parents moves a link" {
    const rp = kt.rename_policy;
    // a = entry in old parent, b = entry in new parent
    const dd = rp.exchangeLinkDelta(5, 9, true, true);
    try std.testing.expectEqual(@as(i32, 0), dd.old_parent);
    try std.testing.expectEqual(@as(i32, 0), dd.new_parent);
    const df = rp.exchangeLinkDelta(5, 9, true, false); // dir leaves old parent, file arrives
    try std.testing.expectEqual(@as(i32, -1), df.old_parent);
    try std.testing.expectEqual(@as(i32, 1), df.new_parent);
    const fd = rp.exchangeLinkDelta(5, 9, false, true);
    try std.testing.expectEqual(@as(i32, 1), fd.old_parent);
    try std.testing.expectEqual(@as(i32, -1), fd.new_parent);
    const same = rp.exchangeLinkDelta(5, 5, true, false);
    try std.testing.expectEqual(@as(i32, 0), same.old_parent + same.new_parent);
}

test "mseal: argument rules, overlap detection and the bounded seal table" {
    const sp = kt.mseal_policy;
    try std.testing.expectEqual(@as(i64, -22), sp.validate(0x1001, 0x1000, 0)); // unaligned
    try std.testing.expectEqual(@as(i64, -22), sp.validate(0x1000, 0x1000, 1)); // flags must be 0
    try std.testing.expectEqual(@as(i64, 0), sp.validate(0x1000, 0, 0)); // len 0: no-op
    try std.testing.expectEqual(@as(i64, -22), sp.validate(0xFFFF_FFFF_FFFF_F000, 0x2000, 0)); // wraps
    try std.testing.expectEqual(@as(i64, 0), sp.validate(0x1000, 0x1001, 0)); // len rounds up

    var t: sp.Table = .{};
    try std.testing.expect(!t.overlaps(0x1000, 0x1000));
    try std.testing.expect(t.add(0x10000, 0x3000));
    try std.testing.expect(t.overlaps(0x12000, 0x1000));
    try std.testing.expect(t.overlaps(0xF000, 0x2000)); // straddles the start
    try std.testing.expect(!t.overlaps(0x13000, 0x1000)); // just after
    try std.testing.expect(!t.overlaps(0xF000, 0x1000)); // just before
    try std.testing.expect(t.add(0x11000, 0x1000)); // re-seal inside: idempotent
    var n: usize = 0;
    while (n < sp.MAX_SEALS) : (n += 1) _ = t.add(0x100000 + n * 0x10000, 0x1000);
    try std.testing.expect(!t.add(0x9000_0000, 0x1000)); // table full: ENOMEM at the caller
}

test "mseal: destructive madvise is refused only on sealed, private, anonymous, read-only pages" {
    const sp = kt.mseal_policy;
    try std.testing.expect(sp.discardBlocked(true, true, false)); // sealed anon read-only
    try std.testing.expect(!sp.discardBlocked(true, true, true)); // writable: caller could zero it anyway
    try std.testing.expect(!sp.discardBlocked(true, false, false)); // file-backed: re-read from the file
    try std.testing.expect(!sp.discardBlocked(false, true, false)); // not sealed
}

test "at-path join with a stored directory path: absolute names and AT_FDCWD pass through, relative names join" {
    const ap = kt.at_join_policy;
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/abs", ap.joinStored("/a/b", "/abs", &buf).?);
    try std.testing.expectEqualStrings("/a/b/x", ap.joinStored("/a/b", "x", &buf).?);
    try std.testing.expectEqualStrings("/a/b/x", ap.joinStored("/a/b/", "x", &buf).?);
    try std.testing.expectEqualStrings("testdir/x", ap.joinStored("testdir", "x", &buf).?);
    var long: [300]u8 = @splat('a');
    try std.testing.expect(ap.joinStored("/d", long[0..260], &buf) == null);
}

test "relative names join the working directory; plain names from the root stay bare" {
    const ap = kt.at_join_policy;
    var buf: [256]u8 = undefined;
    try std.testing.expect(ap.underCwd("/", "f", &buf) == .keep);
    try std.testing.expect(ap.underCwd("", "f", &buf) == .keep);
    try std.testing.expect(ap.underCwd("/testdir", "/abs", &buf) == .keep);
    try std.testing.expect(ap.underCwd("/testdir", "", &buf) == .keep);
    try std.testing.expectEqualStrings("/testdir/f", ap.underCwd("/testdir", "f", &buf).path);
    try std.testing.expectEqualStrings("/tmp/a/b", ap.underCwd("/tmp/a", "b", &buf).path);
    try std.testing.expectEqualStrings("/tmp/x", ap.underCwd("/", "tmp/x", &buf).path);
    try std.testing.expectEqualStrings("/tmp", ap.underCwd("/", "tmp", &buf).path);
    try std.testing.expect(ap.underCwd("/", "tmpx", &buf) == .keep);
    try std.testing.expectEqualStrings("hello2", ap.underCwd("/", "./hello2", &buf).path);
    try std.testing.expectEqualStrings("hello2", ap.underCwd("/testdir", "../hello2", &buf).path);
    try std.testing.expectEqualStrings("/", ap.underCwd("/testdir", "..", &buf).path);
    try std.testing.expectEqualStrings("/a/c/d", ap.underCwd("/a/b", "../c/./d", &buf).path);
    try std.testing.expectEqualStrings("testdir/x", ap.underCwd("/", "testdir/x", &buf).path[1..]);
    var long: [300]u8 = @splat('a');
    try std.testing.expect(ap.underCwd("/d", long[0..255], &buf) == .too_long);
}

test "directory-descriptor joins: a stored relative path counts from the root" {
    const ap = kt.at_join_policy;
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/testdir/x", ap.absJoin("testdir", "x", &buf).path);
    try std.testing.expectEqualStrings("/testdir/x", ap.absJoin("/testdir/", "x", &buf).path);
    try std.testing.expectEqualStrings("hello2", ap.absJoin("testdir", "../hello2", &buf).path);
    try std.testing.expectEqualStrings("/dev/null", ap.absJoin("/dev", "null", &buf).path);
    try std.testing.expectEqualStrings("/tmp/d/f", ap.absJoin("/tmp/d", "f", &buf).path);
}

test "relative names from the root that name /tmp, /dev or /proc must become absolute" {
    const ap = kt.at_join_policy;
    try std.testing.expect(ap.namesRootTree("tmp"));
    try std.testing.expect(ap.namesRootTree("tmp/x"));
    try std.testing.expect(ap.namesRootTree("dev/null"));
    try std.testing.expect(ap.namesRootTree("proc/meminfo"));
    try std.testing.expect(!ap.namesRootTree("tmpx"));
    try std.testing.expect(!ap.namesRootTree("testdir/tmp"));
    try std.testing.expect(!ap.namesRootTree("hello2"));
    try std.testing.expect(!ap.namesRootTree(""));
}

test "every /tmp routing check stops at a component boundary (/tmpfoo is not tmpfs)" {
    const sources = [_][]const u8{ kt.vfs_source, kt.tmpfs_source, kt.unlink_source, kt.dir_ops_source };
    for (sources) |src| {
        var pos: usize = 0;
        var seen: usize = 0;
        while (std.mem.indexOfPos(u8, src, pos, "[3] == 'p'")) |i| {
            const line_end = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
            try std.testing.expect(std.mem.indexOf(u8, src[i..line_end], "[4] == '/'") != null);
            seen += 1;
            pos = i + 1;
        }
        try std.testing.expect(seen > 0);
    }
}

test "chdir '..' leaves no trailing slash" {
    const cp = kt.chdir_policy;
    var out: [256]u8 = undefined;
    var n = try cp.resolve("/tmp/d", "..", &out);
    try std.testing.expectEqualStrings("/tmp", out[0..n]);
    n = try cp.resolve("/a/b/c", "../..", &out);
    try std.testing.expectEqualStrings("/a", out[0..n]);
    n = try cp.resolve("/a/b", "../x", &out);
    try std.testing.expectEqualStrings("/a/x", out[0..n]);
    n = try cp.resolve("/a", "..", &out);
    try std.testing.expectEqualStrings("/", out[0..n]);
    n = try cp.resolve("/", "..", &out);
    try std.testing.expectEqualStrings("/", out[0..n]);
}

test "ext2 readlink copies the target out under fs_lock (no slice into a stack inode)" {
    const src = kt.ext2_source;
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn readSymlinkByPath(path: []const u8, out: *[256]u8) ?[]const u8") != null);
    const start = std.mem.indexOf(u8, src, "pub fn readSymlinkByPath(").?;
    const end = std.mem.indexOfPos(u8, src, start, "\n}\n").?;
    try std.testing.expect(std.mem.indexOf(u8, src[start..end], "return readSymlinkTarget(") == null);
}

test "exec name policy: only ramdisk names (bare or directly under /) are executable" {
    const ep = kt.exec_policy;
    try std.testing.expectEqualStrings("hello2", ep.programName("hello2").ok);
    try std.testing.expectEqualStrings("hello2", ep.programName("/hello2").ok);
    try std.testing.expectEqual(@as(i64, -2), ep.programName("").err);
    try std.testing.expectEqual(@as(i64, -2), ep.programName("/").err);
    try std.testing.expectEqual(@as(i64, -2), ep.programName("/testdir/hello2").err);
    try std.testing.expectEqual(@as(i64, -2), ep.programName("/tmp/x").err);
    var long: [80]u8 = @splat('a');
    try std.testing.expectEqual(@as(i64, -36), ep.programName(long[0..64]).err);
}

test "execveat flags: AT_EMPTY_PATH and AT_SYMLINK_NOFOLLOW are known, others EINVAL" {
    const ep = kt.exec_policy;
    try std.testing.expectEqual(@as(i64, 0), ep.checkAtFlags(0));
    try std.testing.expectEqual(@as(i64, 0), ep.checkAtFlags(0x1000));
    try std.testing.expectEqual(@as(i64, 0), ep.checkAtFlags(0x100));
    try std.testing.expectEqual(@as(i64, -22), ep.checkAtFlags(0x2));
    try std.testing.expectEqual(@as(i64, -22), ep.checkAtFlags(0x200));
}

test "exec failures map to Linux errnos, not a blanket EPERM" {
    const ep = kt.exec_policy;
    try std.testing.expectEqual(@as(i64, -1), ep.errno(.denied));
    try std.testing.expectEqual(@as(i64, -2), ep.errno(.not_found));
    try std.testing.expectEqual(@as(i64, -8), ep.errno(.bad_format));
    try std.testing.expectEqual(@as(i64, -12), ep.errno(.no_memory));
    try std.testing.expectEqual(@as(i64, -14), ep.errno(.fault));
}

test "exec reports ENOEXEC for a ramdisk file that is not ELF before loading it" {
    const src = kt.execve_source;
    const find = std.mem.indexOf(u8, src, "ramdisk.findFile(name) orelse return .{ .err = policy.errno(.not_found) }").?;
    const enoexec = std.mem.indexOfPos(u8, src, find, "parseHeader(file.data, file.size) == null) return .{ .err = policy.errno(.bad_format) }").?;
    const load = std.mem.indexOfPos(u8, src, find, "loader.loadProgramForExec(").?;
    try std.testing.expect(enoexec < load);
}

test "utimensat policy: nsec validation, UTIME_NOW/OMIT and who may set what" {
    const up = kt.utimens_policy;
    const NOW = up.UTIME_NOW;
    const OMIT = up.UTIME_OMIT;
    // NULL times = both now.
    const nul = up.parse(null).ok;
    try std.testing.expect(nul[0] == .now and nul[1] == .now);
    const a = up.parse(.{ .{ .sec = 100, .nsec = 5 }, .{ .sec = 200, .nsec = NOW } }).ok;
    try std.testing.expectEqual(@as(u32, 100), a[0].set);
    try std.testing.expect(a[1] == .now);
    try std.testing.expect(up.parse(.{ .{ .sec = 1, .nsec = OMIT }, .{ .sec = 1, .nsec = OMIT } }).ok[0] == .keep);
    try std.testing.expectEqual(@as(i64, -22), up.parse(.{ .{ .sec = 1, .nsec = 1_000_000_000 }, .{ .sec = 1, .nsec = 0 } }).err);
    try std.testing.expectEqual(@as(i64, -22), up.parse(.{ .{ .sec = 1, .nsec = 0 }, .{ .sec = 1, .nsec = -1 } }).err);
    try std.testing.expectEqual(@as(i64, -75), up.parse(.{ .{ .sec = -1, .nsec = 0 }, .{ .sec = 1, .nsec = 0 } }).err);
    try std.testing.expectEqual(@as(i64, -75), up.parse(.{ .{ .sec = 0x1_0000_0000, .nsec = 0 }, .{ .sec = 1, .nsec = 0 } }).err);
    // A keep slot's seconds are ignored (not range checked).
    try std.testing.expect(up.parse(.{ .{ .sec = -5, .nsec = OMIT }, .{ .sec = 7, .nsec = 0 } }).ok[0] == .keep);
    try std.testing.expect(up.nothingToDo(.{ .keep, .keep }));
    try std.testing.expect(!up.nothingToDo(.{ .keep, .now }));

    // Explicit times: owner or CAP_FOWNER only (EPERM), write access is not enough.
    const set = [2]up.Spec{ .{ .set = 5 }, .now };
    try std.testing.expectEqual(@as(i64, 0), up.authorize(set, true, false, false));
    try std.testing.expectEqual(@as(i64, 0), up.authorize(set, false, true, false));
    try std.testing.expectEqual(@as(i64, -1), up.authorize(set, false, false, true));
    // Now-only: owner, CAP_FOWNER, or write access (EACCES otherwise).
    const now = [2]up.Spec{ .now, .keep };
    try std.testing.expectEqual(@as(i64, 0), up.authorize(now, false, false, true));
    try std.testing.expectEqual(@as(i64, -13), up.authorize(now, false, false, false));
}

test "linkat/fchownat flag policy and cross-filesystem link routing" {
    const ap = kt.at_flags_policy;
    // linkat: AT_SYMLINK_FOLLOW (0x400) selects following; AT_EMPTY_PATH (0x1000) needs
    // CAP_DAC_READ_SEARCH, which no program here holds, so it is ENOENT for an empty name.
    try std.testing.expectEqual(false, ap.linkFlags(0).ok);
    try std.testing.expectEqual(true, ap.linkFlags(0x400).ok);
    try std.testing.expectEqual(@as(i64, -22), ap.linkFlags(0x100).err);
    try std.testing.expectEqual(@as(i64, -22), ap.linkFlags(0x2).err);
    try std.testing.expectEqual(@as(i64, -2), ap.linkFlags(0x1000).err);
    // fchownat: AT_SYMLINK_NOFOLLOW (0x100) and AT_EMPTY_PATH (0x1000) only.
    const c0 = ap.chownFlags(0).ok;
    try std.testing.expect(c0.follow and !c0.empty_path);
    const c1 = ap.chownFlags(0x100 | 0x1000).ok;
    try std.testing.expect(!c1.follow and c1.empty_path);
    try std.testing.expectEqual(@as(i64, -22), ap.chownFlags(0x400).err);
    // linking across the /tmp boundary is EXDEV; inside /tmp tmpfs has no hard links (EPERM).
    try std.testing.expectEqual(@as(i64, -18), ap.linkRoute("/tmp/a", "testdir/b"));
    try std.testing.expectEqual(@as(i64, -18), ap.linkRoute("testdir/a", "/tmp/b"));
    try std.testing.expectEqual(@as(i64, -1), ap.linkRoute("/tmp/a", "/tmp/b"));
    try std.testing.expectEqual(@as(i64, 0), ap.linkRoute("testdir/a", "/testdir/b"));
    try std.testing.expectEqual(@as(i64, 0), ap.linkRoute("/tmpx/a", "b"));
    // symlinks cannot be created on tmpfs.
    try std.testing.expectEqual(@as(i64, -1), ap.symlinkRoute("/tmp/l"));
    try std.testing.expectEqual(@as(i64, 0), ap.symlinkRoute("testdir/l"));
}

test "statx layout reports exactly the fields it fills and rejects bad flags/masks" {
    const sp = kt.stat_info;
    var buf: [144]u8 = @splat(0xAA);
    const with_times = sp.Common{ .mode = 0o100644, .nlink = 2, .uid = 7, .gid = 8, .ino = 99, .size = 1234, .blocks = 8, .times = .{ .atime = 10, .mtime = 20, .ctime = 30 } };
    sp.packStatx(&buf, with_times);
    const rd32 = struct {
        fn f(b: []const u8, o: usize) u32 {
            return @as(u32, b[o]) | (@as(u32, b[o + 1]) << 8) | (@as(u32, b[o + 2]) << 16) | (@as(u32, b[o + 3]) << 24);
        }
    }.f;
    const rd64 = struct {
        fn f(b: []const u8, o: usize) u64 {
            return @as(u64, rd32(b, o)) | (@as(u64, rd32(b, o + 4)) << 32);
        }
    }.f;
    try std.testing.expectEqual(@as(u32, 0x7FF), rd32(&buf, 0));
    try std.testing.expectEqual(@as(u32, 2), rd32(&buf, 16));
    try std.testing.expectEqual(@as(u32, 7), rd32(&buf, 20));
    try std.testing.expectEqual(@as(u64, 99), rd64(&buf, 32));
    try std.testing.expectEqual(@as(u64, 1234), rd64(&buf, 40));
    try std.testing.expectEqual(@as(u64, 8), rd64(&buf, 48));
    try std.testing.expectEqual(@as(u64, 10), rd64(&buf, 64)); // atime.tv_sec
    try std.testing.expectEqual(@as(u32, 0), rd32(&buf, 72)); // atime.tv_nsec
    try std.testing.expectEqual(@as(u64, 30), rd64(&buf, 96)); // ctime
    try std.testing.expectEqual(@as(u64, 20), rd64(&buf, 112)); // mtime
    try std.testing.expectEqual(@as(u64, 0), rd64(&buf, 80)); // btime not provided
    // Unknown times/blocks: the mask must not claim them, and the bytes are zero.
    var b2: [144]u8 = @splat(0xAA);
    sp.packStatx(&b2, .{ .mode = 0o100644, .nlink = 1, .size = 5, .ino = 3 });
    try std.testing.expectEqual(@as(u32, 0x31F), rd32(&b2, 0));
    try std.testing.expectEqual(@as(u64, 0), rd64(&b2, 64));
    try std.testing.expectEqual(@as(u64, 0), rd64(&b2, 48));
    // flags / mask validation
    try std.testing.expectEqual(@as(i64, 0), sp.checkStatxArgs(0, 0x7FF).err_or_zero());
    try std.testing.expectEqual(@as(i64, 0), sp.checkStatxArgs(0x100 | 0x1000 | 0x800, 0).err_or_zero());
    try std.testing.expectEqual(@as(i64, -22), sp.checkStatxArgs(0x2, 0).err_or_zero());
    try std.testing.expectEqual(@as(i64, -22), sp.checkStatxArgs(0, 0x8000_0000).err_or_zero());
    try std.testing.expect(sp.checkStatxArgs(0x1000, 0).empty_path);
    try std.testing.expect(!sp.checkStatxArgs(0, 0).empty_path);
}

test "access(2) policy: mode bits, real vs effective ids, faccessat2 flags" {
    const ap = kt.access_policy;
    const file = ap.Meta{ .mode = 0o100640, .uid = 1000, .gid = 50 };
    const owner = ap.Creds{ .euid = 1000, .egid = 1000 };
    const group = ap.Creds{ .euid = 2000, .egid = 50 };
    const other = ap.Creds{ .euid = 3000, .egid = 3000 };
    try std.testing.expectEqual(ap.Verdict.ok, ap.verdict(file, owner, ap.R | ap.W));
    try std.testing.expectEqual(ap.Verdict.denied, ap.verdict(file, owner, ap.X));
    try std.testing.expectEqual(ap.Verdict.ok, ap.verdict(file, group, ap.R));
    try std.testing.expectEqual(ap.Verdict.denied, ap.verdict(file, group, ap.W));
    try std.testing.expectEqual(ap.Verdict.denied, ap.verdict(file, other, ap.R));
    try std.testing.expectEqual(ap.Verdict.ok, ap.verdict(file, other, 0)); // F_OK needs nothing
    try std.testing.expectEqual(ap.Verdict.invalid, ap.verdict(file, owner, 8));
    // CAP_DAC_OVERRIDE bypasses R/W, but X still needs an execute bit somewhere.
    const root = ap.Creds{ .euid = 0, .egid = 0, .cap_dac_override = true };
    try std.testing.expectEqual(ap.Verdict.ok, ap.verdict(file, root, ap.R | ap.W));
    try std.testing.expectEqual(ap.Verdict.denied, ap.verdict(file, root, ap.X));
    try std.testing.expectEqual(ap.Verdict.ok, ap.verdict(.{ .mode = 0o100700, .uid = 1, .gid = 1 }, root, ap.X));
    try std.testing.expectEqual(ap.Verdict.ok, ap.verdict(.{ .mode = 0o040000, .uid = 1, .gid = 1 }, root, ap.X)); // directories: search

    // Real ids are the default; AT_EACCES (0x200) switches to the effective ids.
    const c = ap.credsFor(.{ .uid = 1000, .gid = 1000, .euid = 0, .egid = 0, .cap_dac_override = true }, false);
    try std.testing.expectEqual(@as(u32, 1000), c.euid);
    try std.testing.expect(!c.cap_dac_override); // privilege belongs to the effective identity
    const e = ap.credsFor(.{ .uid = 1000, .gid = 1000, .euid = 0, .egid = 0, .cap_dac_override = true }, true);
    try std.testing.expectEqual(@as(u32, 0), e.euid);
    try std.testing.expect(e.cap_dac_override);
    const same = ap.credsFor(.{ .uid = 5, .gid = 6, .euid = 5, .egid = 6, .cap_dac_override = true }, false);
    try std.testing.expect(same.cap_dac_override); // ids agree: nothing to drop

    try std.testing.expectEqual(@as(i64, 0), ap.checkFlags(0).err_or_zero());
    try std.testing.expect(ap.checkFlags(0x200).effective);
    try std.testing.expect(!ap.checkFlags(0x100).follow);
    try std.testing.expectEqual(@as(i64, -22), ap.checkFlags(0x4).err_or_zero());
    try std.testing.expect(ap.checkFlags(0x1000).empty_path);
}

test "the ramdisk file-count limit leaves room to grow" {
    const rd = kt.ramdisk_source;
    const k_pos = std.mem.indexOf(u8, rd, "pub const MAX_FILES: u32 = ").?;
    const k_end = std.mem.indexOfScalarPos(u8, rd, k_pos, ';').?;
    const kernel_limit = try std.fmt.parseInt(u32, rd[k_pos + "pub const MAX_FILES: u32 = ".len .. k_end], 10);
    // 121+ programs are packed today; a limit with no headroom stops the next test program.
    try std.testing.expect(kernel_limit >= 256);
}

test "namespace errno policy: unlink, rmdir, mkdir and open on an existing object" {
    const np = kt.namespace_policy;
    const K = np.Kind;
    // unlink: a directory is EISDIR, anything else goes; missing is ENOENT.
    try std.testing.expectEqual(@as(i64, 0), np.unlink(.file));
    try std.testing.expectEqual(@as(i64, 0), np.unlink(.symlink));
    try std.testing.expectEqual(@as(i64, -21), np.unlink(.directory));
    try std.testing.expectEqual(@as(i64, -2), np.unlink(.missing));
    // rmdir: a non-directory is ENOTDIR, a non-empty directory ENOTEMPTY.
    try std.testing.expectEqual(@as(i64, 0), np.rmdir(.directory, true));
    try std.testing.expectEqual(@as(i64, -39), np.rmdir(.directory, false));
    try std.testing.expectEqual(@as(i64, -20), np.rmdir(.file, true));
    try std.testing.expectEqual(@as(i64, -20), np.rmdir(.symlink, true));
    try std.testing.expectEqual(@as(i64, -2), np.rmdir(.missing, true));
    // mkdir: any existing name is EEXIST.
    try std.testing.expectEqual(@as(i64, -17), np.mkdir(.directory));
    try std.testing.expectEqual(@as(i64, -17), np.mkdir(.file));
    try std.testing.expectEqual(@as(i64, -17), np.mkdir(.symlink));
    try std.testing.expectEqual(@as(i64, 0), np.mkdir(.missing));

    const O_WRONLY: u32 = 1;
    const O_RDWR: u32 = 2;
    const O_CREAT: u32 = 0x40;
    const O_EXCL: u32 = 0x80;
    const O_TRUNC: u32 = 0x200;
    const O_DIRECTORY: u32 = 0x10000;
    const O_NOFOLLOW: u32 = 0x20000;
    // open on an existing object.
    try std.testing.expectEqual(@as(i64, 0), np.openExisting(.file, 0));
    try std.testing.expectEqual(@as(i64, -17), np.openExisting(.file, O_CREAT | O_EXCL));
    try std.testing.expectEqual(@as(i64, -17), np.openExisting(.directory, O_CREAT | O_EXCL));
    try std.testing.expectEqual(@as(i64, -20), np.openExisting(.file, O_DIRECTORY));
    try std.testing.expectEqual(@as(i64, 0), np.openExisting(.directory, O_DIRECTORY));
    try std.testing.expectEqual(@as(i64, -21), np.openExisting(.directory, O_WRONLY));
    try std.testing.expectEqual(@as(i64, -21), np.openExisting(.directory, O_RDWR));
    try std.testing.expectEqual(@as(i64, -21), np.openExisting(.directory, O_TRUNC));
    try std.testing.expectEqual(@as(i64, 0), np.openExisting(.directory, 0));
    try std.testing.expectEqual(@as(i64, -40), np.openExisting(.symlink, O_NOFOLLOW));
    try std.testing.expectEqual(@as(i64, 0), np.openExisting(.symlink, 0));
    // O_NOFOLLOW|O_DIRECTORY on a symlink is ENOTDIR on Linux (the link is not a directory).
    try std.testing.expectEqual(@as(i64, -20), np.openExisting(.symlink, O_NOFOLLOW | O_DIRECTORY));
    // open of a missing name: ENOENT unless O_CREAT.
    try std.testing.expectEqual(@as(i64, -2), np.openMissing(0));
    try std.testing.expectEqual(@as(i64, 0), np.openMissing(O_CREAT));
    _ = K;
}

test "vfs uses the Linux x86_64 O_DIRECTORY value (0x10000), not O_LARGEFILE's 0x8000" {
    try std.testing.expect(std.mem.indexOf(u8, kt.vfs_source, "(flags & 0o100000)") == null);
    try std.testing.expect(std.mem.indexOf(u8, kt.vfs_source, "o_creat and (flags & 0x10000) != 0") != null);
}

test "read/write gates: EISDIR for reading a directory, EBADF for writing without write access" {
    const np = kt.namespace_policy;
    try std.testing.expectEqual(@as(i64, -21), np.readGate(true));
    try std.testing.expectEqual(@as(i64, 0), np.readGate(false));
    try std.testing.expectEqual(@as(i64, -9), np.writeGate(false));
    try std.testing.expectEqual(@as(i64, 0), np.writeGate(true));
}

test "fd-table write paths answer EBADF, not a bare -1, for a non-writable descriptor" {
    const src = kt.vfs_source;
    const start = std.mem.indexOf(u8, src, "pub fn write(self: *FdTable, fd: u32").?;
    const body = src[start .. std.mem.indexOfPos(u8, src, start, "return n;\n            },\n            .tcp_socket").?];
    try std.testing.expect(std.mem.indexOf(u8, body, "if (!desc.writable) return -1;") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "namespace_policy.zig\").writeGate(desc.writable)") != null);
}

test "path-length classification: a copy with no NUL inside the limit is ENAMETOOLONG" {
    const np = kt.namespace_policy;
    var full: [255]u8 = @splat('a'); // 255 bytes copied, no terminator: the path did not fit
    try std.testing.expectEqual(@as(i64, -36), np.pathCopyErrno(&full, 255, 255));
    var fits: [256]u8 = @splat('a');
    fits[10] = 0; // "aaaaaaaaaa" + NUL
    try std.testing.expectEqual(@as(i64, 0), np.pathCopyErrno(&fits, 11, 255));
    // exactly 255 characters plus the NUL does not fit the 255-byte copy window either
    var edge: [256]u8 = @splat('b');
    edge[254] = 0; // 254 chars + NUL = 255 bytes copied
    try std.testing.expectEqual(@as(i64, 0), np.pathCopyErrno(&edge, 255, 255));
    // nothing copied is a fault, handled by the caller (EFAULT)
    try std.testing.expectEqual(@as(i64, -14), np.pathCopyErrno(&fits, 0, 255));
}

test "pathFromCopy: NUL-terminated name slice or the errno" {
    const np = kt.namespace_policy;
    var buf: [256]u8 = @splat(0);
    @memcpy(buf[0..4], "abc\x00");
    switch (np.pathFromCopy(&buf, 4, 255)) {
        .ok => |p| try std.testing.expectEqualStrings("abc", p),
        .err => return error.TestUnexpectedResult,
    }
    // empty string: copied 1 (just the NUL) is a zero-length name, not an error here
    buf[0] = 0;
    switch (np.pathFromCopy(&buf, 1, 255)) {
        .ok => |p| try std.testing.expectEqual(@as(usize, 0), p.len),
        .err => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(i64, -14), np.pathFromCopy(&buf, 0, 255).err);
    var full: [256]u8 = @splat('x');
    try std.testing.expectEqual(@as(i64, -36), np.pathFromCopy(&full, 255, 255).err);
    // a smaller limit (names of 15/63/127 bytes) is judged against its own window
    var small: [16]u8 = @splat('y');
    try std.testing.expectEqual(@as(i64, -36), np.pathFromCopy(&small, 15, 15).err);
    small[14] = 0;
    switch (np.pathFromCopy(&small, 15, 15)) {
        .ok => |p| try std.testing.expectEqual(@as(usize, 14), p.len),
        .err => return error.TestUnexpectedResult,
    }
}

test "syscall_entry reads user paths through the checked helper (no raw 255-byte truncating copies)" {
    const src = kt.syscall_entry_source;
    // Every remaining direct call is either the helper itself, a fixed-size non-path
    // name where truncation is the specified behaviour (PR_SET_NAME), the memfd name
    // (length checked explicitly), or wrapped in namespace_policy.pathCopyErrno (mount/umount).
    var pos: usize = 0;
    var raw: usize = 0;
    while (std.mem.indexOfPos(u8, src, pos, "copy.copyPathFromUser(")) |i| {
        pos = i + 1;
        const line_start = if (std.mem.lastIndexOfScalar(u8, src[0..i], '\n')) |nl| nl + 1 else 0;
        const line_end = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
        const line = src[line_start..line_end];
        const ok = std.mem.indexOf(u8, line, "pathCopyErrno(") != null or
            std.mem.indexOf(u8, line, "pathFromCopy(") != null or
            std.mem.indexOf(u8, line, "&name_buf, arg2, 15") != null or // PR_SET_NAME (comm is 15 bytes)
            std.mem.indexOf(u8, line, "&name_buf, name_ptr, 251") != null; // memfd_create: explicit NUL/length check follows
        if (!ok) raw += 1;
    }
    // The helper (userPathResult) is the only unchecked 255-byte reader left.
    try std.testing.expectEqual(@as(usize, 1), raw);
}

test "writeback overlap: a staged extent serves any read that falls inside it, not only one at its start" {
    const wo = kt.writeback_overlap;
    // extent [100, 110) holds 10 bytes
    const e = wo.Extent{ .offset = 100, .len = 10 };
    // read exactly at the start
    try std.testing.expectEqual(wo.Hit{ .skip = 0, .copy = 4, .dst = 0 }, wo.overlap(e, 100, 4).?);
    // read inside: starts 3 bytes in, wants 4
    try std.testing.expectEqual(wo.Hit{ .skip = 3, .copy = 4, .dst = 0 }, wo.overlap(e, 103, 4).?);
    // read running past the end of the extent: only the 2 staged bytes
    try std.testing.expectEqual(wo.Hit{ .skip = 8, .copy = 2, .dst = 0 }, wo.overlap(e, 108, 5).?);
    // read starting before the extent but reaching into it: bytes land after the gap
    try std.testing.expectEqual(wo.Hit{ .skip = 0, .copy = 3, .dst = 7 }, wo.overlap(e, 93, 10).?);
    // disjoint
    try std.testing.expect(wo.overlap(e, 110, 4) == null);
    try std.testing.expect(wo.overlap(e, 90, 10) == null);
    try std.testing.expect(wo.overlap(e, 100, 0) == null);
    // a read window larger than a page is clamped by the caller; offsets near u64 max do not wrap
    try std.testing.expect(wo.overlap(.{ .offset = 0xFFFF_FFFF_FFFF_FFF0, .len = 8 }, 0xFFFF_FFFF_FFFF_FFF4, 4) != null);
}

test "positioned I/O offsets are signed: a value with the top bit set is EINVAL" {
    const np = kt.namespace_policy;
    try std.testing.expectEqual(@as(i64, 0), np.positionedOffsetErrno(0));
    try std.testing.expectEqual(@as(i64, 0), np.positionedOffsetErrno(0x7FFF_FFFF_FFFF_FFFF));
    try std.testing.expectEqual(@as(i64, -22), np.positionedOffsetErrno(0x8000_0000_0000_0000));
    try std.testing.expectEqual(@as(i64, -22), np.positionedOffsetErrno(@bitCast(@as(i64, -1))));
}

test "truncate tail zeroing: bytes past the new size in the last kept block must be cleared" {
    const np = kt.namespace_policy;
    // 1 KiB blocks. Shrinking 10 -> 4 keeps block 0 and must zero [4, 1024) in it.
    try std.testing.expectEqual(np.TailZero{ .block = 0, .from = 4, .len = 1020 }, np.truncateTail(4, 1024).?);
    // 2500 -> block 2, offset 452
    try std.testing.expectEqual(np.TailZero{ .block = 2, .from = 452, .len = 572 }, np.truncateTail(2500, 1024).?);
    // block-aligned sizes and zero need nothing
    try std.testing.expect(np.truncateTail(2048, 1024) == null);
    try std.testing.expect(np.truncateTail(0, 1024) == null);
    // 4 KiB blocks
    try std.testing.expectEqual(np.TailZero{ .block = 0, .from = 100, .len = 3996 }, np.truncateTail(100, 4096).?);
}

test "shared open-file offset pool: promote, share, release, reuse" {
    const sp = kt.shared_offset;
    var pool = sp.Pool(4){};
    // A private descriptor (slot 0) keeps its own offset; promoting moves it into the pool.
    const a = pool.promote(100).?;
    try std.testing.expect(a != 0);
    try std.testing.expectEqual(@as(u64, 100), pool.load(a));
    pool.store(a, 250);
    try std.testing.expectEqual(@as(u64, 250), pool.load(a));
    // sharing bumps the count; both holders see one offset
    pool.retain(a);
    pool.store(a, 300);
    try std.testing.expectEqual(@as(u64, 300), pool.load(a));
    // releasing one holder keeps the slot, the last release frees it
    try std.testing.expect(!pool.release(a));
    try std.testing.expectEqual(@as(u64, 300), pool.load(a));
    try std.testing.expect(pool.release(a));
    // a freed slot is reused and starts from the new offset
    const b = pool.promote(7).?;
    try std.testing.expectEqual(@as(u64, 7), pool.load(b));
    // exhaustion returns null, and a held slot is never handed out twice
    var held: [4]u16 = undefined;
    var n: usize = 0;
    var p2 = sp.Pool(4){};
    while (p2.promote(0)) |s| : (n += 1) held[n] = s;
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expect(p2.promote(0) == null);
    for (held[0..n], 0..) |s, i| for (held[0..n], 0..) |t, j| if (i != j) try std.testing.expect(s != t);
    // slot 0 means "private" and is never allocated
    for (held[0..n]) |s| try std.testing.expect(s != 0);
}

test "dup2/dup3 errors and descriptor flags: EBADF for a bad source, close-on-exec never inherited" {
    const rl = kt.rlimit;
    // a source that is not open is EBADF (it used to be a bare -1)
    try std.testing.expectEqual(@as(i64, -9), rl.Policy.dupExplicitErrno(.bad_old));
    try std.testing.expectEqual(@as(i64, -9), rl.Policy.dupExplicitErrno(.bad_target));
    try std.testing.expectEqual(@as(i64, 0), rl.Policy.dupExplicitErrno(.replace));
    // the copy's descriptor flags are exactly what the caller asked for, never the source's
    const np = kt.namespace_policy;
    try std.testing.expectEqual(@as(u32, 0), np.dupFdFlags(1, false));
    try std.testing.expectEqual(@as(u32, 1), np.dupFdFlags(0, true));
    try std.testing.expectEqual(@as(u32, 1), np.dupFdFlags(1, true));
    // pipe ends report their access mode through F_GETFL
    try std.testing.expectEqual(@as(u32, 0), np.pipeStatusFlags(false));
    try std.testing.expectEqual(@as(u32, 1), np.pipeStatusFlags(true));
}

test "shared open-file description: status flags live next to the offset" {
    const sp = kt.shared_offset;
    var pool = sp.Pool(4){};
    const s = pool.promote(0).?;
    pool.setFlags(s, 0x802);
    try std.testing.expectEqual(@as(u32, 0x802), pool.flags(s));
    pool.retain(s);
    pool.setFlags(s, 0x400);
    try std.testing.expectEqual(@as(u32, 0x400), pool.flags(s));
    _ = pool.release(s);
    try std.testing.expect(pool.release(s));
    // a recycled slot starts with clean flags
    const t = pool.promote(0).?;
    try std.testing.expectEqual(@as(u32, 0), pool.flags(t));
}

test "mprotect/mremap argument rules: zero length, holes and unmapped sources" {
    const mp = kt.mprotect_policy;
    // len == 0 is a successful no-op (after the alignment check), not EINVAL
    try std.testing.expectEqual(mp.Early.noop, mp.early(0x1000, 0, 3));
    try std.testing.expectEqual(mp.Early{ .err = -22 }, mp.early(0x1001, 0, 3)); // alignment is checked first
    try std.testing.expectEqual(mp.Early{ .err = -22 }, mp.early(0x1000, 4096, 0x100)); // unknown PROT bits
    try std.testing.expectEqual(mp.Early.noop, mp.early(0x1000, 0, 0x100)); // len 0 wins over prot (Linux order)
    try std.testing.expectEqual(mp.Early.proceed, mp.early(0x1000, 4096, 7));
    // a range with a hole is ENOMEM; fully covered is fine
    try std.testing.expectEqual(@as(i64, 0), mp.coverageErrno(4, 4));
    try std.testing.expectEqual(@as(i64, -12), mp.coverageErrno(4, 3));
    try std.testing.expectEqual(@as(i64, -12), mp.coverageErrno(1, 0));
    // mremap of a source that is not (fully) mapped is EFAULT
    try std.testing.expectEqual(@as(i64, 0), mp.remapSourceErrno(2, 2));
    try std.testing.expectEqual(@as(i64, -14), mp.remapSourceErrno(2, 1));
    try std.testing.expectEqual(@as(i64, -14), mp.remapSourceErrno(2, 0));
}

test "clock ids: which clock reads which time source, and which ones sleep/timers accept" {
    const ts = kt.clock_ids;
    const K = ts.Source;
    try std.testing.expectEqual(K.realtime, ts.sourceOf(0).?);
    try std.testing.expectEqual(K.monotonic, ts.sourceOf(1).?);
    try std.testing.expectEqual(K.process_cpu, ts.sourceOf(2).?);
    try std.testing.expectEqual(K.thread_cpu, ts.sourceOf(3).?);
    try std.testing.expectEqual(K.monotonic, ts.sourceOf(4).?); // MONOTONIC_RAW
    try std.testing.expectEqual(K.realtime, ts.sourceOf(5).?); // REALTIME_COARSE
    try std.testing.expectEqual(K.monotonic, ts.sourceOf(6).?); // MONOTONIC_COARSE
    try std.testing.expectEqual(K.monotonic, ts.sourceOf(7).?); // BOOTTIME (no suspend here)
    try std.testing.expect(ts.sourceOf(8) == null);
    try std.testing.expect(ts.sourceOf(99) == null);
    // negative clock ids are dynamic clocks (fd-based): not supported
    try std.testing.expect(ts.sourceOf(@bitCast(@as(i64, -1))) == null);
    // which clocks clock_nanosleep accepts (verdicts below)
    // clock_nanosleep (measured on Linux): REALTIME, MONOTONIC and BOOTTIME sleep; MONOTONIC_RAW, the two COARSE clocks
    // and THREAD_CPUTIME are EOPNOTSUPP (95); unknown ids are EINVAL. PROCESS_CPUTIME really sleeps on Linux (until that
    // much CPU time has passed, which never comes while asleep); here it stays EINVAL, a documented difference.
    const V = ts.SleepVerdict;
    try std.testing.expectEqual(V.ok, ts.sleepVerdict(0));
    try std.testing.expectEqual(V.ok, ts.sleepVerdict(1));
    try std.testing.expectEqual(V.ok, ts.sleepVerdict(7));
    try std.testing.expectEqual(V.not_supported, ts.sleepVerdict(4));
    try std.testing.expectEqual(V.not_supported, ts.sleepVerdict(5));
    try std.testing.expectEqual(V.not_supported, ts.sleepVerdict(6));
    try std.testing.expectEqual(V.not_supported, ts.sleepVerdict(3));
    try std.testing.expectEqual(V.invalid, ts.sleepVerdict(2));
    try std.testing.expectEqual(V.invalid, ts.sleepVerdict(8));
    try std.testing.expectEqual(V.invalid, ts.sleepVerdict(99));
    try std.testing.expectEqual(V.invalid, ts.sleepVerdict(@bitCast(@as(i64, -1))));
    try std.testing.expectEqual(@as(i64, -95), ts.sleepErrno(ts.sleepVerdict(4)));
    try std.testing.expectEqual(@as(i64, -22), ts.sleepErrno(ts.sleepVerdict(2)));
    try std.testing.expectEqual(@as(i64, 0), ts.sleepErrno(ts.sleepVerdict(1)));
    // The syscall asks for the verdict, not a bare boolean.
    try std.testing.expect(std.mem.indexOf(u8, kt.syscall_entry_source, "const sleep_verdict = clock_ids.sleepVerdict(clockid);") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.syscall_entry_source, "if (sleep_verdict != .ok) return clock_ids.sleepErrno(sleep_verdict);") != null);
    // coarse clocks report a coarser resolution than the precise ones
    try std.testing.expectEqual(@as(u64, 1), ts.resolutionNs(1));
    try std.testing.expectEqual(@as(u64, 1_000_000), ts.resolutionNs(6));
    try std.testing.expectEqual(@as(u64, 1_000_000), ts.resolutionNs(5));
}

test "root user tasks start as leaders of their own group and session; wait options are validated" {
    const pp = kt.proc_id_policy;
    // a task with no parent to inherit from leads group and session = its tid (when it fits u16)
    try std.testing.expectEqual(@as(u16, 5), pp.rootGroupId(5));
    try std.testing.expectEqual(@as(u16, 0), pp.rootGroupId(0));
    try std.testing.expectEqual(@as(u16, 0), pp.rootGroupId(0x1_0000)); // too large: stays 0 (unnamed), never wraps
    try std.testing.expectEqual(@as(u16, 0xFFFF), pp.rootGroupId(0xFFFF));
    // wait4/waitpid options: WNOHANG, WUNTRACED, WCONTINUED, __WNOTHREAD, __WALL, __WCLONE
    try std.testing.expectEqual(@as(i64, 0), pp.waitOptionsErrno(0));
    try std.testing.expectEqual(@as(i64, 0), pp.waitOptionsErrno(1));
    try std.testing.expectEqual(@as(i64, 0), pp.waitOptionsErrno(1 | 2 | 8));
    try std.testing.expectEqual(@as(i64, 0), pp.waitOptionsErrno(0x20000000 | 0x40000000 | 0x80000000));
    try std.testing.expectEqual(@as(i64, -22), pp.waitOptionsErrno(0x4));
    try std.testing.expectEqual(@as(i64, -22), pp.waitOptionsErrno(0x10));
    try std.testing.expectEqual(@as(i64, -22), pp.waitOptionsErrno(0x1000_0000));
}

test "waitpid child selection: pid > 0, -1, 0 and < -1" {
    const pp = kt.proc_id_policy;
    // pid > 0: exactly that child
    try std.testing.expect(pp.waitMatches(5, 5, 9, 9));
    try std.testing.expect(!pp.waitMatches(5, 6, 9, 9));
    // pid == -1: any child
    try std.testing.expect(pp.waitMatches(-1, 6, 1, 9));
    // pid == 0: a child in the caller's own process group
    try std.testing.expect(pp.waitMatches(0, 6, 9, 9));
    try std.testing.expect(!pp.waitMatches(0, 6, 4, 9));
    // pid < -1: a child in group -pid
    try std.testing.expect(pp.waitMatches(-4, 6, 4, 9));
    try std.testing.expect(!pp.waitMatches(-4, 6, 5, 9));
    // pid == INT_MIN must not overflow when negated
    try std.testing.expect(!pp.waitMatches(@import("std").math.minInt(i32), 6, 4, 9));
}

test "socket blocking policy: EAGAIN only for non-blocking sockets, EOF and errors never block" {
    const np = kt.namespace_policy;
    const B = np.SockWait;
    // empty receive queue on a blocking socket: wait; on a non-blocking one: EAGAIN
    try std.testing.expectEqual(B.wait, np.recvWait(false, true, false));
    try std.testing.expectEqual(B.eagain, np.recvWait(true, true, false));
    // a peer that is gone (connected stream with a closed peer, or never connected) is EOF, never a wait
    try std.testing.expectEqual(B.eof, np.recvWait(false, true, true));
    try std.testing.expectEqual(B.eof, np.recvWait(true, true, true));
    // data in the queue is always read, even when the peer is gone
    try std.testing.expectEqual(B.proceed, np.recvWait(false, false, true));
    // MSG_DONTWAIT behaves like O_NONBLOCK for this call only
    try std.testing.expect(np.nonblockRequested(0x800, 0));
    try std.testing.expect(np.nonblockRequested(0, 0x40));
    try std.testing.expect(!np.nonblockRequested(0, 0));
    // accept: empty backlog waits unless non-blocking
    try std.testing.expectEqual(B.wait, np.acceptWait(false));
    try std.testing.expectEqual(B.eagain, np.acceptWait(true));
    // send into a full buffer waits unless non-blocking
    try std.testing.expectEqual(B.wait, np.sendWait(false, true));
    try std.testing.expectEqual(B.eagain, np.sendWait(true, true));
    try std.testing.expectEqual(B.proceed, np.sendWait(false, false));
}

test "socket() argument policy: type flags, address family, protocol" {
    const np = kt.namespace_policy;
    // SOCK_CLOEXEC / SOCK_NONBLOCK are flags on top of the type, not a different type
    const ok = np.socketArgs(1, 1 | 0x80000 | 0x800, 0).ok;
    try std.testing.expectEqual(@as(u32, 1), ok.sock_type);
    try std.testing.expect(ok.cloexec and ok.nonblock);
    const plain = np.socketArgs(1, 2, 0).ok;
    try std.testing.expectEqual(@as(u32, 2), plain.sock_type);
    try std.testing.expect(!plain.cloexec and !plain.nonblock);
    // errors
    try std.testing.expectEqual(@as(i64, -97), np.socketArgs(99, 1, 0).err); // EAFNOSUPPORT
    try std.testing.expectEqual(@as(i64, -22), np.socketArgs(1, 77, 0).err); // unknown type
    try std.testing.expectEqual(@as(i64, -22), np.socketArgs(1, 1 | 0x100000, 0).err); // unknown flag bits
    try std.testing.expectEqual(@as(i64, -93), np.socketArgs(1, 1, 5).err); // EPROTONOSUPPORT
    try std.testing.expectEqual(@as(i64, 0), @as(i64, if (np.socketArgs(1, 1, 0) == .ok) 0 else -1));
    // internet families keep their protocol numbers: TCP=6 with STREAM, UDP=17 with DGRAM, 0 = default
    try std.testing.expect(np.socketArgs(2, 1, 6) == .ok);
    try std.testing.expect(np.socketArgs(2, 2, 17) == .ok);
    try std.testing.expectEqual(@as(i64, -93), np.socketArgs(2, 1, 17).err);
    try std.testing.expectEqual(@as(i64, -93), np.socketArgs(2, 2, 6).err);
    // SOCK_RAW (3) is a valid type
    try std.testing.expect(np.socketArgs(2, 3, 1) == .ok);
    // a bad descriptor or a non-socket: EBADF vs ENOTSOCK
    try std.testing.expectEqual(@as(i64, -9), np.socketFdErrno(false, false));
    try std.testing.expectEqual(@as(i64, -88), np.socketFdErrno(true, false));
    try std.testing.expectEqual(@as(i64, 0), np.socketFdErrno(true, true));
}

test "unix stream connect: data sent before accept is kept, not refused" {
    const np = kt.namespace_policy;
    // A connector that is queued on a backlog but not yet accepted may already send:
    // the bytes wait in its own pending buffer until accept pairs it.
    try std.testing.expectEqual(np.StreamSend.queue_pending, np.streamSendState(.{ .connected = false, .queued = true }));
    try std.testing.expectEqual(np.StreamSend.deliver, np.streamSendState(.{ .connected = true, .queued = false }));
    try std.testing.expectEqual(np.StreamSend.not_connected, np.streamSendState(.{ .connected = false, .queued = false }));
    // and reading from a queued, not yet accepted connector waits instead of reporting EOF
    try std.testing.expectEqual(np.SockWait.wait, np.streamRecvState(.{ .connected = false, .queued = true }, false));
    try std.testing.expectEqual(np.SockWait.eagain, np.streamRecvState(.{ .connected = false, .queued = true }, true));
    try std.testing.expectEqual(np.SockWait.eof, np.streamRecvState(.{ .connected = false, .queued = false }, false));
}

test "stream send after the peer is gone is EPIPE, before any connection is ENOTCONN" {
    const np = kt.namespace_policy;
    try std.testing.expectEqual(@as(i64, -32), np.streamSendErrno(true, false)); // was connected, peer closed
    try std.testing.expectEqual(@as(i64, -107), np.streamSendErrno(false, false)); // never connected
    try std.testing.expectEqual(@as(i64, 0), np.streamSendErrno(true, true));
    try std.testing.expectEqual(@as(i64, 0), np.streamSendErrno(false, true)); // queued: handled elsewhere
}

test "tkill target tid must be a positive pid_t" {
    const ip = kt.proc_id_policy;
    try std.testing.expectEqual(@as(?u32, 1), ip.tkillTargetTid(1));
    try std.testing.expectEqual(@as(?u32, 0x7FFF_FFFF), ip.tkillTargetTid(0x7FFF_FFFF));
    try std.testing.expectEqual(@as(?u32, null), ip.tkillTargetTid(0));
    try std.testing.expectEqual(@as(?u32, null), ip.tkillTargetTid(-5));
    try std.testing.expectEqual(@as(?u32, null), ip.tkillTargetTid(0x8000_0000));
}

test "siginfo policy is reachable from the host test root" {
    const sp = kt.siginfo_policy;
    try std.testing.expectEqual(@as(usize, 128), sp.SIGINFO_SIZE);
    try std.testing.expectEqual(@as(usize, 432), @sizeOf(sp.UContext));
}

test "uname image carries the mutable names in the right fields" {
    const u = kt.uts;
    const b = u.unameBytes("box", "lan");
    try std.testing.expectEqualStrings("MoQiOS", std.mem.sliceTo(b[0..u.FIELD], 0));
    try std.testing.expectEqualStrings("box", std.mem.sliceTo(b[u.FIELD .. 2 * u.FIELD], 0));
    try std.testing.expectEqualStrings("x86_64", std.mem.sliceTo(b[4 * u.FIELD .. 5 * u.FIELD], 0));
    try std.testing.expectEqualStrings("lan", std.mem.sliceTo(b[5 * u.FIELD .. 6 * u.FIELD], 0));
    const empty = u.unameBytes("", "");
    try std.testing.expectEqual(@as(u8, 0), empty[u.FIELD]);
    try std.testing.expectEqual(@as(u8, 0), empty[5 * u.FIELD]);
}

test "a 64-byte hostname fits its uname field with the NUL terminator" {
    const u = kt.uts;
    const long: [64]u8 = @splat('h');
    const b = u.unameBytes(&long, "");
    try std.testing.expectEqual(@as(u8, 'h'), b[u.FIELD + 63]);
    try std.testing.expectEqual(@as(u8, 0), b[u.FIELD + 64]);
    try std.testing.expect(u.nameLenValid(64));
    try std.testing.expect(!u.nameLenValid(65));
}

test "siginfo encodes the Linux x86-64 siginfo_t layout" {
    const sp = kt.siginfo_policy;
    const b = sp.encode(10, .{ .code = sp.SI_QUEUE, .a = sp.pidUid(77, 5), .b = 0xdeadbeef });
    try std.testing.expectEqual(@as(u8, 10), b[0]);
    try std.testing.expectEqual(@as(u8, 0xff), b[8]); // si_code -1
    try std.testing.expectEqual(@as(u8, 77), b[16]);
    try std.testing.expectEqual(@as(u8, 5), b[20]);
    try std.testing.expectEqual(@as(u8, 0xef), b[24]);
    try std.testing.expectEqual(@as(u8, 0), b[100]);
    const round = sp.decode(&b);
    try std.testing.expectEqual(sp.SI_QUEUE, round.code);
    try std.testing.expectEqual(@as(u64, 0xdeadbeef), round.b);
}

test "rt_sigqueueinfo may only forge negative codes towards other processes" {
    const sp = kt.siginfo_policy;
    try std.testing.expect(sp.queueinfoAllowed(sp.SI_QUEUE, false));
    try std.testing.expect(!sp.queueinfoAllowed(sp.SI_USER, false));
    try std.testing.expect(!sp.queueinfoAllowed(sp.SI_KERNEL, false));
    try std.testing.expect(!sp.queueinfoAllowed(sp.SI_TKILL, false));
    try std.testing.expect(sp.queueinfoAllowed(sp.SI_USER, true));
}

test "child and fault siginfo codes" {
    const sp = kt.siginfo_policy;
    const exited = sp.childInfo(9, 0, 7, true);
    try std.testing.expectEqual(sp.CLD_EXITED, exited.code);
    try std.testing.expectEqual(@as(u64, 7), exited.b);
    const killed = sp.childInfo(9, 0, 128 + 11, false);
    try std.testing.expectEqual(sp.CLD_KILLED, killed.code);
    try std.testing.expectEqual(@as(u64, 11), killed.b);
    try std.testing.expectEqual(sp.SEGV_MAPERR, sp.faultInfo(false, false, 0x10).code);
    try std.testing.expectEqual(sp.SEGV_ACCERR, sp.faultInfo(false, true, 0x10).code);
    try std.testing.expectEqual(sp.BUS_ADRERR, sp.faultInfo(true, false, 0x10).code);
    try std.testing.expectEqual(@as(u64, 0x10), sp.faultInfo(false, false, 0x10).a);
}

test "poll timeout: negative waits forever, zero polls once" {
    const pp = kt.poll_policy;
    try std.testing.expect(pp.pollTimeout(0xFFFF_FFFF_FFFF_FFFF) == .forever);
    try std.testing.expect(pp.pollTimeout(0xFFFF_FFFF) == .forever);
    try std.testing.expectEqual(@as(u64, 0), pp.pollTimeout(0).ms);
    try std.testing.expectEqual(@as(u64, 120), pp.pollTimeout(120).ms);
}

test "select timeout validation and rounding" {
    const pp = kt.poll_policy;
    try std.testing.expect(pp.selectTimeout(-1, 0) == null);
    try std.testing.expect(pp.selectTimeout(0, -1) == null);
    try std.testing.expect(pp.selectTimeout(0, 1_000_000) == null);
    try std.testing.expectEqual(@as(u64, 0), pp.selectTimeout(0, 0).?.ms);
    try std.testing.expectEqual(@as(u64, 1), pp.selectTimeout(0, 1).?.ms);
    try std.testing.expectEqual(@as(u64, 100), pp.selectTimeout(0, 100_000).?.ms);
    try std.testing.expectEqual(@as(u64, 2500), pp.selectTimeout(2, 500_000).?.ms);
    try std.testing.expect(pp.selectTimeout(std.math.maxInt(i64), 0).? == .forever);
}

test "poll revents always reports errors and hangups, only requested data events" {
    const pp = kt.poll_policy;
    try std.testing.expectEqual(pp.POLLIN, pp.revents(pp.POLLIN | pp.POLLOUT, pp.POLLIN));
    try std.testing.expectEqual(@as(u32, 0), pp.revents(pp.POLLIN, pp.POLLOUT));
    try std.testing.expectEqual(pp.POLLHUP, pp.revents(pp.POLLHUP, 0));
    try std.testing.expectEqual(pp.POLLERR | pp.POLLOUT, pp.revents(pp.POLLERR | pp.POLLOUT, pp.POLLOUT));
    try std.testing.expectEqual(pp.POLLIN | pp.POLLRDNORM, pp.revents(pp.POLLIN, pp.POLLRDNORM));
}

test "select readiness and wait slicing" {
    const pp = kt.poll_policy;
    try std.testing.expect(pp.selectReadable(pp.POLLHUP));
    try std.testing.expect(!pp.selectReadable(pp.POLLOUT));
    try std.testing.expect(pp.selectWritable(pp.POLLERR));
    try std.testing.expect(!pp.selectWritable(pp.POLLIN));
    try std.testing.expect(pp.nfdsValid(64, 64));
    try std.testing.expect(!pp.nfdsValid(65, 64));
    try std.testing.expectEqual(@as(u64, 5_000_000), pp.sliceDeadline(0, null, 5));
    try std.testing.expectEqual(@as(u64, 2_000_000), pp.sliceDeadline(0, 2_000_000, 5));
}

test "ppoll and pselect6 timespec timeouts round up and reject bad fields" {
    const pp = kt.poll_policy;
    try std.testing.expect(pp.timespecWait(-1, 0) == null);
    try std.testing.expect(pp.timespecWait(0, 1_000_000_000) == null);
    try std.testing.expectEqual(@as(u64, 0), pp.timespecWait(0, 0).?.ms);
    try std.testing.expectEqual(@as(u64, 1), pp.timespecWait(0, 1).?.ms);
    try std.testing.expectEqual(@as(u64, 2), pp.timespecWait(0, 1_000_001).?.ms);
    try std.testing.expectEqual(@as(u64, 1500), pp.timespecWait(1, 500_000_000).?.ms);
    try std.testing.expect(pp.timespecWait(std.math.maxInt(i64), 0).? == .forever);
}

test "ioctl: terminal requests need a terminal, FIONREAD on files counts bytes after the offset" {
    const ip = kt.ioctl_policy;
    try std.testing.expectEqual(@as(i64, -25), ip.terminalCheck(ip.TCGETS, .other));
    try std.testing.expectEqual(@as(i64, -25), ip.terminalCheck(ip.TIOCGWINSZ, .other));
    try std.testing.expectEqual(@as(i64, -25), ip.terminalCheck(ip.TIOCGPGRP, .other));
    try std.testing.expectEqual(@as(i64, 0), ip.terminalCheck(ip.TCGETS, .terminal));
    try std.testing.expectEqual(@as(i64, 0), ip.terminalCheck(ip.FIONREAD, .other));
    try std.testing.expectEqual(@as(i64, 0), ip.terminalCheck(ip.FIOCLEX, .other));
    try std.testing.expectEqual(@as(u32, 6), ip.fileReadable(10, 4));
    try std.testing.expectEqual(@as(u32, 0), ip.fileReadable(10, 10));
    try std.testing.expectEqual(@as(u32, 0), ip.fileReadable(10, 99));
}

test "scm_rights: parse and build control messages" {
    const sp = kt.scm_policy;
    var buf: [24]u8 = @splat(0);
    std.mem.writeInt(u64, buf[0..8], 20, .little);
    std.mem.writeInt(i32, buf[8..12], sp.SOL_SOCKET, .little);
    std.mem.writeInt(i32, buf[12..16], sp.SCM_RIGHTS, .little);
    std.mem.writeInt(i32, buf[16..20], 7, .little);
    const r = sp.parseRights(&buf).ok;
    try std.testing.expectEqual(@as(usize, 1), r.count);
    try std.testing.expectEqual(@as(i32, 7), r.fds[0]);
    std.mem.writeInt(u64, buf[0..8], 8, .little);
    try std.testing.expect(sp.parseRights(&buf).err == .invalid);
    std.mem.writeInt(u64, buf[0..8], 20, .little);
    std.mem.writeInt(i32, buf[12..16], 2, .little);
    try std.testing.expect(sp.parseRights(&buf).err == .invalid);

    var out: [64]u8 = @splat(0xAA);
    const b = sp.buildRights(&[_]i32{9}, 64, &out);
    try std.testing.expectEqual(@as(usize, 24), b.written);
    try std.testing.expectEqual(@as(u64, 20), std.mem.readInt(u64, out[0..8], .little));
    try std.testing.expectEqual(@as(u8, 0), out[20]);
    const none = sp.buildRights(&[_]i32{ 1, 2 }, 8, &out);
    try std.testing.expect(none.truncated and none.written == 0);
    const partial = sp.buildRights(&[_]i32{ 1, 2, 3 }, 24, &out);
    try std.testing.expectEqual(@as(usize, 2), partial.fits);
    try std.testing.expect(partial.truncated);
    try std.testing.expect(sp.deliveredBy(0, 1));
    try std.testing.expect(!sp.deliveredBy(5, 5));
}

test "scm_rights: a read for control data stops at descriptor boundaries" {
    const sp = kt.scm_policy;
    try std.testing.expectEqual(@as(usize, 100), sp.readPlan(100, null, null, true).cap);
    const front = sp.readPlan(100, 10, null, true);
    try std.testing.expectEqual(@as(usize, 10), front.cap);
    try std.testing.expect(!front.deliver);
    const own = sp.readPlan(100, 0, 30, true);
    try std.testing.expectEqual(@as(usize, 30), own.cap);
    try std.testing.expect(own.deliver);
    const plain = sp.readPlan(100, 0, 30, false);
    try std.testing.expectEqual(@as(usize, 100), plain.cap);
    try std.testing.expect(!plain.deliver);
}

test "sockopt policy: identity, read-only options, buffers, ucred, timeval" {
    const p = kt.sockopt_policy;
    try std.testing.expectEqual(@as(u32, 6), p.identity(.tcp, false).protocol);
    try std.testing.expectEqual(@as(u32, 10), p.identity(.udp, true).domain);
    try std.testing.expectEqual(@as(u32, 1), p.identity(.unix_stream, false).domain);
    try std.testing.expect(p.readOnly(p.SO_TYPE) and p.readOnly(p.SO_PEERCRED));
    try std.testing.expect(!p.readOnly(p.SO_REUSEADDR));
    try std.testing.expectEqual(@as(?u16, 8), p.flagBit(p.SO_REUSEPORT));
    try std.testing.expectEqual(@as(u32, 131072), p.bufferValue(65536, p.SOCK_MIN_RCVBUF));
    try std.testing.expectEqual(p.SOCK_MIN_SNDBUF, p.bufferValue(1, p.SOCK_MIN_SNDBUF));
    const raw = p.encodeCred(.{ .pid = 42, .uid = 7, .gid = 9 });
    try std.testing.expectEqual(@as(u8, 42), raw[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), p.encodeCred(.{})[4]);
    try std.testing.expectEqual(@as(?u32, 2500), p.timevalMs(2, 500_000));
    try std.testing.expectEqual(@as(?u32, null), p.timevalMs(0, 1_000_000));
}

test "sockopt policy: applySet/encodeGet round trip and rejections" {
    const p = kt.sockopt_policy;
    var s: p.Stored = .{};
    var one = [_]u8{ 1, 0, 0, 0 };
    var out: [16]u8 = undefined;
    const f: p.Facts = .{ .id = p.identity(.udp, false) };
    try std.testing.expectEqual(@as(i64, 0), p.applySet(&s, p.SO_REUSEPORT, &one));
    try std.testing.expectEqual(@as(?usize, 4), p.encodeGet(s, f, p.SO_REUSEPORT, &out));
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    try std.testing.expectEqual(@as(i64, -92), p.applySet(&s, p.SO_TYPE, &one));
    try std.testing.expectEqual(@as(i64, -22), p.applySet(&s, p.SO_REUSEADDR, one[0..2]));
    var big = [_]u8{ 0x00, 0x00, 0x01, 0x00 };
    try std.testing.expectEqual(@as(i64, 0), p.applySet(&s, p.SO_RCVBUF, &big));
    _ = p.encodeGet(s, f, p.SO_RCVBUF, &out);
    try std.testing.expectEqual(@as(u32, 131072), std.mem.readInt(u32, out[0..4], .little));
    const cred_f: p.Facts = .{ .id = p.identity(.unix_stream, false), .cred = .{ .pid = 5, .uid = 6, .gid = 7 } };
    try std.testing.expectEqual(@as(?usize, 12), p.encodeGet(s, cred_f, p.SO_PEERCRED, &out));
    try std.testing.expectEqual(@as(?usize, null), p.encodeGet(s, f, p.SO_PEERCRED, &out));
}

test "udp receive policy: empty queue waits, fails with EAGAIN or delivers" {
    const up = kt.udp_recv_policy;
    try std.testing.expectEqual(up.Step.deliver, up.step(true, false, false));
    try std.testing.expectEqual(up.Step.wait, up.step(false, false, false));
    try std.testing.expectEqual(up.Step.eagain, up.step(false, true, false));
    try std.testing.expectEqual(up.Step.eagain, up.step(false, false, true));
    try std.testing.expectEqual(@as(?u64, null), up.deadlineNs(100, 0));
    try std.testing.expectEqual(@as(?u64, 100 + 5_000_000), up.deadlineNs(100, 5));
    try std.testing.expect(up.timedOut(10, 10));
    try std.testing.expect(!up.timedOut(null, 1 << 60));
}

test "irq time: windowed maximum resets on take, boot-wide maximum stays" {
    const p = kt.irq_time_policy;
    var a: p.Acc = .{};
    a.enterVec(0, true, 14);
    a.exit(1000);
    _ = a.takeWindow();
    a.enterVec(2000, true, 240);
    a.exit(2100);
    a.enterVec(3000, true, 14);
    a.exit(3800);
    const w = a.takeWindow();
    try std.testing.expectEqual(@as(u64, 800), w.cycles);
    try std.testing.expectEqual(@as(u8, 14), w.vector);
    try std.testing.expectEqual(@as(u64, 0), a.takeWindow().cycles);
    try std.testing.expectEqual(@as(u64, 1000), a.max_cycles);
    var n: p.Acc = .{};
    n.enterVec(100, false, 32);
    n.enterVec(150, false, 33);
    n.exit(180);
    n.exit(300);
    try std.testing.expectEqual(@as(u64, 200), n.total_cycles);
    try std.testing.expectEqual(@as(u8, 32), n.max_vector);
}

test "ext2 directory path assembly: join, depth limit, loop detection" {
    const dp = kt.ext2_dirpath;
    var c: dp.Chain = .{};
    var out: [dp.MAX_PATH + 1]u8 = undefined;
    try std.testing.expectEqualStrings("/", try dp.join(&c, &out));
    try std.testing.expect(c.push("c"));
    try std.testing.expect(c.push("b"));
    try std.testing.expect(c.push("a"));
    try std.testing.expectEqualStrings("/a/b/c", try dp.join(&c, &out));
    try std.testing.expect(!c.push(""));
    var big: dp.Chain = .{};
    const name: [200]u8 = @splat('x');
    try std.testing.expect(big.push(&name));
    try std.testing.expect(big.push(&name));
    try std.testing.expectError(error.TooLong, dp.join(&big, &out));
    try std.testing.expectEqual(dp.Step.done, dp.nextStep(dp.ROOT_INO, dp.ROOT_INO, &.{}));
    try std.testing.expectEqual(dp.Step.up, dp.nextStep(12, 7, &.{12}));
    try std.testing.expectEqual(dp.Step.invalid, dp.nextStep(12, 12, &.{12}));
    try std.testing.expectEqual(dp.Step.invalid, dp.nextStep(12, 7, &.{ 12, 7 }));
}

test "fd stat policy: type bits, permissions, link counts and synthetic inodes" {
    const fp = kt.fd_stat_policy;
    try std.testing.expectEqual(fp.S_IFIFO, fp.typeBits(.pipe));
    try std.testing.expectEqual(fp.S_IFSOCK, fp.typeBits(.socket));
    try std.testing.expectEqual(fp.S_IFCHR, fp.typeBits(.char_device));
    try std.testing.expectEqual(fp.S_IFDIR, fp.typeBits(.directory));
    try std.testing.expectEqual(fp.S_IFREG, fp.typeBits(.anon));
    try std.testing.expectEqual(fp.S_IFIFO | 0o600, fp.mode(.pipe, true));
    try std.testing.expectEqual(fp.S_IFSOCK | 0o600, fp.mode(.socket, false));
    try std.testing.expectEqual(fp.S_IFCHR | 0o666, fp.mode(.char_device, true));
    try std.testing.expectEqual(@as(u32, 0), fp.mode(.anon, true) & 0o111);
    try std.testing.expectEqual(@as(u64, 1), fp.nlink(.pipe));
    try std.testing.expectEqual(@as(u64, 2), fp.nlink(.directory));
    try std.testing.expect(fp.syntheticIno(1, 3) != fp.syntheticIno(2, 3));
    try std.testing.expect(fp.syntheticIno(1, 3) != fp.syntheticIno(1, 4));
}

test "stream write loop: blocking writes finish, non-blocking report progress" {
    const np = kt.namespace_policy;
    // everything went in
    try std.testing.expectEqual(np.WriteStep.done, np.writeProgress(100, 0, 100, false));
    try std.testing.expectEqual(np.WriteStep.done, np.writeProgress(100, 60, 40, true));
    try std.testing.expectEqual(np.WriteStep.done, np.writeProgress(0, 0, 0, false));
    // short: a blocking write goes on, a non-blocking one returns what fitted
    try std.testing.expectEqual(np.WriteStep.again, np.writeProgress(100, 0, 40, false));
    try std.testing.expectEqual(np.WriteStep.partial, np.writeProgress(100, 0, 40, true));
    // ring full: blocking waits; non-blocking is EAGAIN unless something went in already
    try std.testing.expectEqual(np.WriteStep.wait, np.writeProgress(100, 0, -11, false));
    try std.testing.expectEqual(np.WriteStep.wait, np.writeProgress(100, 40, -11, false));
    try std.testing.expectEqual(np.WriteStep.fail, np.writeProgress(100, 0, -11, true));
    try std.testing.expectEqual(np.WriteStep.partial, np.writeProgress(100, 40, -11, true));
    // other errors: progress wins over the error
    try std.testing.expectEqual(np.WriteStep.fail, np.writeProgress(100, 0, -32, false));
    try std.testing.expectEqual(np.WriteStep.partial, np.writeProgress(100, 40, -32, false));
}

test "datagram size must fit the ring with its length prefix" {
    const np = kt.namespace_policy;
    try std.testing.expect(np.dgramFits(100, 8192));
    try std.testing.expect(np.dgramFits(8190, 8192));
    try std.testing.expect(!np.dgramFits(8191, 8192));
    try std.testing.expect(!np.dgramFits(70000, 8192));
}

test "a timed-out blocking write reports what was sent, else EAGAIN" {
    try std.testing.expectEqual(@as(i64, -11), kt.namespace_policy.sendTimeoutResult(0));
    try std.testing.expectEqual(@as(i64, 8192), kt.namespace_policy.sendTimeoutResult(8192));
}

test "tcp: a full data segment fits the MTU together with its options" {
    // Ethernet: MSS 1460 + 20 IP + 20 TCP = 1500. With timestamps (12 option
    // bytes) the payload must shrink or the PMTU gate refuses the segment and
    // the send ring can never drain.
    try std.testing.expectEqual(@as(u32, 1460), tcp_util.dataSegmentCap(1460, 0));
    try std.testing.expectEqual(@as(u32, 1448), tcp_util.dataSegmentCap(1460, 12));
    try std.testing.expectEqual(@as(u32, 1424), tcp_util.dataSegmentCap(1460, 36));
    for ([_]u8{ 0, 12, 20, 28, 36 }) |opt| {
        const cap = tcp_util.dataSegmentCap(1460, opt);
        try std.testing.expect(20 + 20 + @as(u32, opt) + cap <= 1500);
    }
    // Degenerate MSS never yields a zero-length "full" segment.
    try std.testing.expectEqual(@as(u32, 1), tcp_util.dataSegmentCap(8, 12));
}

test "tcp: the duplicate-ACK counter saturates instead of overflowing" {
    var c: u3 = 0;
    for (0..100) |_| c = tcp_util.bumpDupAck(c);
    try std.testing.expectEqual(@as(u3, 7), c);
    try std.testing.expectEqual(@as(u3, 1), tcp_util.bumpDupAck(0));
    try std.testing.expectEqual(@as(u3, 3), tcp_util.bumpDupAck(2));
}

test "tcp: PRR never leaves an empty pipe with a zero congestion window" {
    // Nothing in flight and nothing allowed: one segment must still go out,
    // otherwise no ACK ever arrives to end recovery and no RTO is armed.
    try std.testing.expectEqual(@as(u32, 1448), tcp_util.prrCwnd(0, 0, 1448));
    try std.testing.expectEqual(@as(u32, 1448), tcp_util.prrCwnd(0, 100, 1448));
    // Otherwise the window is exactly pipe + sndcnt.
    try std.testing.expectEqual(@as(u32, 4000), tcp_util.prrCwnd(0, 4000, 1448));
    try std.testing.expectEqual(@as(u32, 2896), tcp_util.prrCwnd(1448, 1448, 1448));
    try std.testing.expectEqual(@as(u32, 1448), tcp_util.prrCwnd(1448, 0, 1448));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), tcp_util.prrCwnd(0xffff_fff0, 0x100, 1448));
}

test "tcp: an idle connection has nothing unacked whatever its initial sequence" {
    // snd_max initialised to the ISS: idle means una == nxt == max.
    for ([_]u32{ 0, 1000, 0x7fff_ffff, 0x8000_0000, 0x8000_0001, 3946014917, 0xffff_ffff }) |iss| {
        try std.testing.expect(!tcp_util.unackedPending(iss, iss, iss));
        // After sending 100 bytes the data is pending until acknowledged.
        try std.testing.expect(tcp_util.unackedPending(iss, iss +% 100, iss +% 100));
        try std.testing.expect(!tcp_util.unackedPending(iss +% 100, iss +% 100, iss +% 100));
    }
    // The old default (snd_max = 0) made every ISS >= 2^31 look unacked.
    try std.testing.expect(tcp_util.unackedPending(3946014917, 3946014917, 0));
}

test "tcp: every place that seeds snd_nxt from the ISS also seeds snd_max" {
    const src = kt.tcp_source;
    var from: usize = 0;
    var seeds: usize = 0;
    while (std.mem.indexOfPos(u8, src, from, ".snd_nxt = ")) |at| {
        from = at + 1;
        const line_end = std.mem.indexOfPos(u8, src, at, "\n").?;
        const line = src[at..line_end];
        if (std.mem.indexOf(u8, line, ".iss;") == null) continue;
        seeds += 1;
        const next_end = std.mem.indexOfPos(u8, src, line_end + 1, "\n").?;
        const next = src[line_end + 1 .. next_end];
        try std.testing.expect(std.mem.indexOf(u8, next, ".snd_max = ") != null);
    }
    try std.testing.expect(seeds >= 7);
}

test "tcp: the receiver never SACKs data it did not keep" {
    // rcv_nxt = 1000. A segment ahead of it is dropped (no out-of-order queue),
    // so reporting it as SACKed made the sender treat it as delivered and
    // never resend it: the connection stalled until it gave up.
    try std.testing.expectEqual(tcp_util.OooReport.none, tcp_util.oooReport(2000, 2500, 1000));
    try std.testing.expectEqual(tcp_util.OooReport.none, tcp_util.oooReport(1001, 1100, 1000));
    // A duplicate of data already received: DSACK it (RFC 2883).
    try std.testing.expectEqual(tcp_util.OooReport.dsack_whole, tcp_util.oooReport(500, 800, 1000));
    try std.testing.expectEqual(tcp_util.OooReport.dsack_whole, tcp_util.oooReport(500, 1000, 1000));
    // A segment straddling rcv_nxt: the part before it is a duplicate.
    try std.testing.expectEqual(tcp_util.OooReport.dsack_prefix, tcp_util.oooReport(900, 1100, 1000));
    // Sequence wrap-around.
    try std.testing.expectEqual(tcp_util.OooReport.none, tcp_util.oooReport(10, 60, 0xffff_ff00));
    try std.testing.expectEqual(tcp_util.OooReport.dsack_whole, tcp_util.oooReport(0xffff_ff00, 0xffff_ff80, 10));
}

test "tcp: the retransmit timeout forgets the SACK scoreboard" {
    const src = kt.tcp_source;
    const at = std.mem.indexOf(u8, src, "tcb.retransmit_count += 1;").?;
    const win = src[at .. at + 400];
    try std.testing.expect(std.mem.indexOf(u8, win, "tcb.sack_scoreboard_count = 0;") != null);
}

test "tcp: BDP-derived windows never fall below two segments" {
    // Loopback: ~1 ms RTT and a sparse rate sample give a BDP of a few bytes.
    try std.testing.expectEqual(@as(u32, 2896), tcp_util.bdpWindow(9, 1448));
    try std.testing.expectEqual(@as(u32, 2896), tcp_util.bdpWindow(0, 1448));
    try std.testing.expectEqual(@as(u32, 100_000), tcp_util.bdpWindow(100_000, 1448));
    try std.testing.expectEqual(@as(u32, 2), tcp_util.bdpWindow(0, 0));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), tcp_util.bdpWindow(0xffff_ffff, 1448));
}

test "tcp: every BBR path that assigns a BDP window applies the floor" {
    const src = kt.tcp_source;
    try std.testing.expect(std.mem.indexOf(u8, src, "tcb.ssthresh = bdp;") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "tcb.cwnd = bdp;") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "tcp_util.bdpWindow(probeBbrCycleCwnd(bdp, gain)") != null);
}

test "read(): a full chunk only asks for another one when it cannot block" {
    const np = kt.namespace_policy;
    // Regular files always have the next bytes.
    try std.testing.expect(np.readContinues(true, false));
    // A pipe, socket or device continues only if data is already waiting.
    try std.testing.expect(np.readContinues(false, true));
    try std.testing.expect(!np.readContinues(false, false));
}

test "file_io.read consults readiness before a follow-up chunk on non-file descriptors" {
    const src = kt.file_io_source;
    try std.testing.expect(std.mem.indexOf(u8, src, "readContinues(regular") != null);
}

test "shutdown half-close: EOF and EPIPE follow the shut direction only" {
    const np = kt.namespace_policy;
    const none: np.HalfClose = .{};
    try std.testing.expect(!np.halfCloseReadEof(none));
    try std.testing.expect(!np.halfCloseSendBroken(none));
    // This end SHUT_WR: it cannot send; its own reads are unaffected.
    const wr: np.HalfClose = .{ .shut_wr = true };
    try std.testing.expect(np.halfCloseSendBroken(wr));
    try std.testing.expect(!np.halfCloseReadEof(wr));
    // The peer SHUT_WR: this end reads EOF once drained, and can still send.
    const peer_wr: np.HalfClose = .{ .peer_shut_wr = true };
    try std.testing.expect(np.halfCloseReadEof(peer_wr));
    try std.testing.expect(!np.halfCloseSendBroken(peer_wr));
    // This end SHUT_RD: reads EOF locally; the peer's sends fail (seen from the peer as peer_shut_rd).
    const rd: np.HalfClose = .{ .shut_rd = true };
    try std.testing.expect(np.halfCloseReadEof(rd));
    try std.testing.expect(!np.halfCloseSendBroken(rd));
    const peer_rd: np.HalfClose = .{ .peer_shut_rd = true };
    try std.testing.expect(np.halfCloseSendBroken(peer_rd));
    try std.testing.expect(!np.halfCloseReadEof(peer_rd));
}

test "unix epoll: a shut-down stream is readable (EOF) and writable (EPIPE)" {
    const up = kt.unix_epoll_policy;
    const base: up.State = .{ .stream = true, .rx_bytes = 0, .listening = false, .pending_connections = 0, .disconnected = false, .peer_free = 100 };
    try std.testing.expectEqual(@as(u32, up.EPOLLOUT), up.events(base));
    var eof = base;
    eof.read_eof = true;
    try std.testing.expectEqual(@as(u32, up.EPOLLIN | up.EPOLLOUT), up.events(eof));
    var broken = base;
    broken.send_broken = true;
    broken.peer_free = null;
    try std.testing.expectEqual(@as(u32, up.EPOLLOUT), up.events(broken));
}

test "tcp send errors: ENOTCONN before a connection, EPIPE after shutdown, ECONNRESET after RST" {
    const rp = kt.tcp_recv_policy;
    const S = rp.TcpState;
    // Open for writing: no error (established, or the peer only closed its side).
    try std.testing.expectEqual(@as(i64, 0), rp.sendErrno(S.established, false, false, true));
    try std.testing.expectEqual(@as(i64, 0), rp.sendErrno(S.close_wait, false, false, true));
    // Never connected, listening, or connected and gone: EPIPE (Linux; recv is the call that says ENOTCONN).
    try std.testing.expectEqual(@as(i64, -32), rp.sendErrno(S.closed, false, false, false));
    try std.testing.expectEqual(@as(i64, -32), rp.sendErrno(S.listen, false, false, false));
    try std.testing.expectEqual(@as(i64, -32), rp.sendErrno(S.closed, false, false, true));
    // Shutdown for writing (FIN requested or sent): EPIPE.
    try std.testing.expectEqual(@as(i64, -32), rp.sendErrno(S.established, true, false, true));
    try std.testing.expectEqual(@as(i64, -32), rp.sendErrno(S.fin_wait_2, false, false, true));
    // Peer RST wins.
    try std.testing.expectEqual(@as(i64, -104), rp.sendErrno(S.closed, false, true, true));
    // What may be queued.
    try std.testing.expect(rp.canQueueSend(S.established, false));
    try std.testing.expect(rp.canQueueSend(S.close_wait, false));
    try std.testing.expect(!rp.canQueueSend(S.established, true));
    try std.testing.expect(!rp.canQueueSend(S.fin_wait_1, false));
    // read() on a socket that never connected is ENOTCONN, not EOF.
    try std.testing.expect(rp.recvNeverConnected(S.closed, false));
    try std.testing.expect(!rp.recvNeverConnected(S.closed, true));
    try std.testing.expect(!rp.recvNeverConnected(S.established, false));
}

test "tcp: an orphaned connection answers new data with RST, not with silence" {
    const tu = tcp_util;
    // Closed by the application (orphan), in a FIN_WAIT state, new payload.
    try std.testing.expect(tu.orphanRejectsData(true, true, 1000, 10, 1000));
    // A pure duplicate of data already received is not new.
    try std.testing.expect(!tu.orphanRejectsData(true, true, 900, 100, 1000));
    // No payload, not an orphan, or not in a FIN_WAIT state: unaffected.
    try std.testing.expect(!tu.orphanRejectsData(true, true, 1000, 0, 1000));
    try std.testing.expect(!tu.orphanRejectsData(false, true, 1000, 10, 1000));
    try std.testing.expect(!tu.orphanRejectsData(true, false, 1000, 10, 1000));
    // Boundaries: the segment ends exactly at rcv_nxt (all old) vs one byte past it.
    try std.testing.expect(!tu.orphanRejectsData(true, true, 990, 10, 1000));
    try std.testing.expect(tu.orphanRejectsData(true, true, 990, 11, 1000));
    // A zero-length segment ahead of rcv_nxt carries nothing to reject.
    try std.testing.expect(!tu.orphanRejectsData(true, true, 2000, 0, 1000));
    // A zero-length segment at rcv_nxt - 1 (keepalive) is not data either.
    try std.testing.expect(!tu.orphanRejectsData(true, true, 999, 0, 1000));
    // A one-byte duplicate just below rcv_nxt (a keepalive probe) is old data.
    try std.testing.expect(!tu.orphanRejectsData(true, true, 999, 1, 1000));
    // Wrap-around: rcv_nxt just below 2^32, segment crossing zero.
    try std.testing.expect(tu.orphanRejectsData(true, true, 0xffff_fff0, 0x20, 0xffff_fff8));
}

test "socket send: EPIPE raises SIGPIPE unless MSG_NOSIGNAL" {
    const np = kt.namespace_policy;
    try std.testing.expect(np.raisesSigpipe(-32, 0));
    try std.testing.expect(!np.raisesSigpipe(-32, np.MSG_NOSIGNAL));
    try std.testing.expect(np.raisesSigpipe(-32, 0x40)); // MSG_DONTWAIT does not suppress it
    // Only EPIPE raises the signal.
    try std.testing.expect(!np.raisesSigpipe(-11, 0));
    try std.testing.expect(!np.raisesSigpipe(-104, 0));
    try std.testing.expect(!np.raisesSigpipe(5, 0));
    try std.testing.expectEqual(@as(u32, 0x4000), np.MSG_NOSIGNAL);
}

test "every socket send entry point routes its result through sendResult" {
    try std.testing.expect(std.mem.count(u8, kt.vfs_source, "sendResult(") >= 2);
    try std.testing.expect(std.mem.count(u8, kt.socket_syscall_source, "sendResult(") >= 4);
}

test "tcp: shutdown(SHUT_RD) makes reads EOF and is wired into the data path" {
    try std.testing.expect(kt.tcp_recv_policy.shutRdEof(true));
    try std.testing.expect(!kt.tcp_recv_policy.shutRdEof(false));
    const src = kt.tcp_source;
    // read side, blocking wait, incoming data and the shutdown call all consult the flag.
    try std.testing.expect(std.mem.count(u8, src, "shutRdEof(tcb.shut_rd)") >= 2);
    try std.testing.expect(std.mem.indexOf(u8, src, "if (tcb.shut_rd) {\n        tcb.rcv_nxt +%= len;") != null);
    try std.testing.expect(std.mem.count(u8, src, "tcb.shut_rd = true;") >= 2);
}

test "tcp readiness: idle, data, peer EOF, our SHUT_RD, reset, closed" {
    const rd = kt.tcp_ready_policy;
    const S = kt.tcp_recv_policy.TcpState;
    const idle: rd.Snapshot = .{ .active = true, .state = S.established, .recv_bytes = 0, .send_space = 100, .reset_by_peer = false, .shut_rd = false, .fin_pending = false };
    // An idle connection is writable only: no error, no hang-up.
    try std.testing.expectEqual(@as(u32, rd.OUT), rd.events(idle));
    // Queued data is readable.
    var data = idle;
    data.recv_bytes = 5;
    try std.testing.expectEqual(@as(u32, rd.IN | rd.OUT), rd.events(data));
    // A full send ring is not writable.
    var full = idle;
    full.send_space = 0;
    try std.testing.expectEqual(@as(u32, 0), rd.events(full));
    // Peer sent FIN (CLOSE_WAIT): readable (EOF) and still writable, no hang-up yet.
    var cw = idle;
    cw.state = S.close_wait;
    try std.testing.expectEqual(@as(u32, rd.IN | rd.OUT | rd.RDHUP), rd.events(cw));
    // Our SHUT_RD: a read returns EOF at once.
    var sr = idle;
    sr.shut_rd = true;
    try std.testing.expectEqual(@as(u32, rd.IN | rd.OUT), rd.events(sr));
    // Both sides finished: hang-up.
    var both = idle;
    both.state = S.last_ack;
    try std.testing.expect(rd.events(both) & rd.HUP != 0);
    var fw2 = idle;
    fw2.state = S.fin_wait_2;
    try std.testing.expect(rd.events(fw2) & rd.HUP == 0); // our side closed, peer may still send
    // Closed connection and a reaped slot.
    var closed = idle;
    closed.state = S.closed;
    try std.testing.expect(rd.events(closed) & rd.HUP != 0);
    try std.testing.expect(rd.events(closed) & rd.IN != 0);
    var gone = idle;
    gone.active = false;
    try std.testing.expect(rd.events(gone) & rd.HUP != 0);
    // RST is the only thing that reports ERR.
    var rst = idle;
    rst.reset_by_peer = true;
    rst.state = S.closed;
    try std.testing.expect(rd.events(rst) & rd.ERR != 0);
    try std.testing.expect(rd.events(idle) & rd.ERR == 0);
    // Handshake in progress / listener.
    var syn = idle;
    syn.state = S.syn_sent;
    try std.testing.expectEqual(@as(u32, 0), rd.events(syn));
    var lst = idle;
    lst.state = S.listen;
    try std.testing.expectEqual(@as(u32, 0), rd.events(lst));
    lst.recv_bytes = 1;
    try std.testing.expectEqual(@as(u32, rd.IN), rd.events(lst));
}

test "poll and epoll share the TCP readiness function" {
    try std.testing.expect(std.mem.indexOf(u8, kt.poll_source, "tcp_mod.tcpReadiness(desc.tcb_idx)") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.epoll_source, "tcp.tcpReadiness(resource_idx)") != null);
}

test "tcp readiness: RDHUP follows the peer's FIN, not our own shutdown" {
    const rd = kt.tcp_ready_policy;
    const S = kt.tcp_recv_policy.TcpState;
    const idle: rd.Snapshot = .{ .active = true, .state = S.established, .recv_bytes = 0, .send_space = 100, .reset_by_peer = false, .shut_rd = false, .fin_pending = false };
    try std.testing.expectEqual(@as(u32, 0), rd.events(idle) & rd.RDHUP);
    // Peer closed its writing side: CLOSE_WAIT and every state after it.
    for ([_]S{ S.close_wait, S.last_ack, S.closing, S.time_wait, S.closed }) |st| {
        var s = idle;
        s.state = st;
        try std.testing.expect(rd.events(s) & rd.RDHUP != 0);
    }
    // Our own SHUT_RD / SHUT_WR do not make the peer "hang up".
    var sr = idle;
    sr.shut_rd = true;
    try std.testing.expectEqual(@as(u32, 0), rd.events(sr) & rd.RDHUP);
    var sw = idle;
    sw.fin_pending = true;
    try std.testing.expectEqual(@as(u32, 0), rd.events(sw) & rd.RDHUP);
    var fw = idle;
    fw.state = S.fin_wait_2;
    try std.testing.expectEqual(@as(u32, 0), rd.events(fw) & rd.RDHUP);
    try std.testing.expectEqual(@as(u32, 0x2000), rd.RDHUP);
}

test "epoll wakes a waiter on the peer's FIN with RDHUP" {
    try std.testing.expect(std.mem.indexOf(u8, kt.tcp_source, "epoll.EPOLLIN | epoll.EPOLLHUP | epoll.EPOLLRDHUP") != null);
}

test "unix epoll: RDHUP follows the peer's SHUT_WR or disconnect, not our own state" {
    const up = kt.unix_epoll_policy;
    const base: up.State = .{ .stream = true, .rx_bytes = 0, .listening = false, .pending_connections = 0, .disconnected = false, .peer_free = 100 };
    try std.testing.expectEqual(@as(u32, 0), up.events(base) & up.EPOLLRDHUP);
    var psw = base;
    psw.peer_shut_wr = true;
    psw.read_eof = true;
    try std.testing.expect(up.events(psw) & up.EPOLLRDHUP != 0);
    try std.testing.expect(up.events(psw) & up.EPOLLIN != 0);
    // Our own shutdown flags (read_eof / send_broken) alone are not a peer hang-up.
    var own = base;
    own.read_eof = true;
    own.send_broken = true;
    try std.testing.expectEqual(@as(u32, 0), up.events(own) & up.EPOLLRDHUP);
    // The peer closed.
    var gone = base;
    gone.disconnected = true;
    try std.testing.expect(up.events(gone) & up.EPOLLRDHUP != 0);
    // Datagram sockets and listeners never report it.
    var dg = base;
    dg.stream = false;
    dg.peer_shut_wr = true;
    try std.testing.expectEqual(@as(u32, 0), up.events(dg) & up.EPOLLRDHUP);
    var ls = base;
    ls.listening = true;
    ls.peer_shut_wr = true;
    try std.testing.expectEqual(@as(u32, 0), up.events(ls) & up.EPOLLRDHUP);
    try std.testing.expectEqual(@as(u32, 0x2000), up.EPOLLRDHUP);
}

test "tcp: a closed port answers with RST per RFC 9293" {
    const tu = tcp_util;
    // SYN without ACK: SEQ 0, ACK = seq + 1.
    const r1 = tu.resetReply(false, 0, 1000, 0, true, false);
    try std.testing.expectEqual(@as(u32, 0), r1.seq);
    try std.testing.expectEqual(@as(u32, 1001), r1.ack);
    try std.testing.expect(r1.with_ack);
    // Data without ACK: ACK covers the payload.
    const r2 = tu.resetReply(false, 0, 1000, 20, false, false);
    try std.testing.expectEqual(@as(u32, 1020), r2.ack);
    // SYN + FIN + payload each count.
    const r3 = tu.resetReply(false, 0, 10, 5, true, true);
    try std.testing.expectEqual(@as(u32, 17), r3.ack);
    // A segment with ACK: SEQ is its ACK number, no ACK in the reset.
    const r4 = tu.resetReply(true, 5555, 1000, 0, false, false);
    try std.testing.expectEqual(@as(u32, 5555), r4.seq);
    try std.testing.expect(!r4.with_ack);
    // Wrap-around of the acknowledged range.
    const r5 = tu.resetReply(false, 0, 0xffff_ffff, 0, true, false);
    try std.testing.expectEqual(@as(u32, 0), r5.ack);
}

test "tcp connect: rejection, progress and failure mapping" {
    const rp = kt.tcp_recv_policy;
    const S = rp.TcpState;
    try std.testing.expectEqual(@as(i64, 0), rp.connectRejection(S.closed));
    try std.testing.expectEqual(@as(i64, -114), rp.connectRejection(S.syn_sent));
    try std.testing.expectEqual(@as(i64, -114), rp.connectRejection(S.syn_received));
    try std.testing.expectEqual(@as(i64, -106), rp.connectRejection(S.established));
    try std.testing.expectEqual(@as(i64, -106), rp.connectRejection(S.listen));
    try std.testing.expectEqual(rp.ConnectWait.keep_waiting, rp.connectProgress(S.syn_sent));
    try std.testing.expectEqual(rp.ConnectWait.connected, rp.connectProgress(S.established));
    try std.testing.expectEqual(rp.ConnectWait.failed, rp.connectProgress(S.closed));
    try std.testing.expectEqual(@as(i64, -111), rp.connectFailure(111));
    try std.testing.expectEqual(@as(i64, -110), rp.connectFailure(110));
    try std.testing.expectEqual(@as(i64, -111), rp.connectFailure(0));
}

test "tcp readiness: a pending SO_ERROR is reported as ERR" {
    const rd = kt.tcp_ready_policy;
    const S = kt.tcp_recv_policy.TcpState;
    const refused: rd.Snapshot = .{ .active = true, .state = S.closed, .recv_bytes = 0, .send_space = 0, .reset_by_peer = false, .shut_rd = false, .fin_pending = false, .so_error = 111 };
    try std.testing.expect(rd.events(refused) & rd.ERR != 0);
    try std.testing.expect(rd.events(refused) & rd.HUP != 0);
    var ok = refused;
    ok.so_error = 0;
    ok.state = S.established;
    ok.send_space = 10;
    try std.testing.expect(rd.events(ok) & rd.ERR == 0);
}

test "icmp port unreachable: reply decision, quote length and matching" {
    const up = kt.icmp_unreach_policy;
    // Only loopback datagrams that found no socket are answered.
    try std.testing.expect(up.shouldReply(true, false, false));
    try std.testing.expect(!up.shouldReply(false, false, false));
    try std.testing.expect(!up.shouldReply(true, true, false));
    try std.testing.expect(!up.shouldReply(true, false, true));
    // IP header plus the first 8 payload bytes, never more than the datagram has.
    try std.testing.expectEqual(@as(u32, 28), up.quoteLen(20, 100));
    try std.testing.expectEqual(@as(u32, 24), up.quoteLen(20, 24));
    try std.testing.expectEqual(@as(u32, 32), up.quoteLen(24, 100));

    // A well-formed message: ICMP header, quoted IP header (UDP), quoted UDP header.
    var msg: [8 + 20 + 8]u8 = @splat(0);
    msg[0] = 3;
    msg[1] = 3;
    msg[8] = 0x45;
    msg[8 + 9] = 17;
    std.mem.writeInt(u16, msg[28..30], 24990, .big);
    std.mem.writeInt(u16, msg[30..32], 24999, .big);
    const q = up.parseQuote(&msg).?;
    try std.testing.expectEqual(@as(u16, 24990), q.src_port);
    try std.testing.expectEqual(@as(u16, 24999), q.dst_port);
    // Wrong code, wrong quoted protocol, too short: ignored.
    var bad = msg;
    bad[1] = 4;
    try std.testing.expect(up.parseQuote(&bad) == null);
    bad = msg;
    bad[8 + 9] = 6;
    try std.testing.expect(up.parseQuote(&bad) == null);
    try std.testing.expect(up.parseQuote(msg[0..30]) == null);
    // A longer quoted header (IHL 6) moves the UDP header.
    var long: [8 + 24 + 8]u8 = @splat(0);
    long[0] = 3;
    long[1] = 3;
    long[8] = 0x46;
    long[8 + 9] = 17;
    std.mem.writeInt(u16, long[32..34], 1111, .big);
    std.mem.writeInt(u16, long[34..36], 2222, .big);
    const ql = up.parseQuote(&long).?;
    try std.testing.expectEqual(@as(u16, 1111), ql.src_port);
    try std.testing.expectEqual(@as(u16, 2222), ql.dst_port);

    // Only a socket connected to exactly that peer is affected.
    try std.testing.expect(up.matchesConnected(q, 24990, true, 24999));
    try std.testing.expect(!up.matchesConnected(q, 24990, false, 24999));
    try std.testing.expect(!up.matchesConnected(q, 24990, true, 25000));
    try std.testing.expect(!up.matchesConnected(q, 24991, true, 24999));
}

test "udp: the pending error is consulted by recv, SO_ERROR and readiness" {
    try std.testing.expect(std.mem.indexOf(u8, kt.socket_syscall_source, "udp.takePendingError(src_port)") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.epoll_source, "peekPendingError(@intCast(resource_idx))") != null);
    try std.testing.expect(std.mem.count(u8, kt.socket_syscall_source, "udp.setPeerPort(") >= 2);
    try std.testing.expect(std.mem.indexOf(u8, kt.socket_syscall_source, "pending_send_err = udp.takePendingError(src_port)") != null);
}

test "poll timeout write-back: remaining time arithmetic and unit split" {
    const pp = kt.poll_policy;
    // remaining = original - elapsed, never below zero.
    try std.testing.expectEqual(@as(u64, 850_000_000), pp.remainingNs(1_000_000_000, 150_000_000));
    try std.testing.expectEqual(@as(u64, 0), pp.remainingNs(100, 100));
    try std.testing.expectEqual(@as(u64, 0), pp.remainingNs(100, 5_000_000_000));
    // timespec (ns) and timeval (us) fractions.
    const ts = pp.splitNs(2_500_000_123, 1);
    try std.testing.expectEqual(@as(i64, 2), ts.sec);
    try std.testing.expectEqual(@as(i64, 500_000_123), ts.frac);
    const tv = pp.splitNs(2_500_000_123, 1000);
    try std.testing.expectEqual(@as(i64, 2), tv.sec);
    try std.testing.expectEqual(@as(i64, 500_000), tv.frac);
    // Parsing the caller's value back into nanoseconds.
    try std.testing.expectEqual(@as(?u64, 1_500_000_000), pp.timeoutNs(1, 500_000_000, 1));
    try std.testing.expectEqual(@as(?u64, 1_000_500_000), pp.timeoutNs(1, 500, 1000));
    try std.testing.expectEqual(@as(?u64, null), pp.timeoutNs(-1, 0, 1));
    try std.testing.expectEqual(@as(?u64, null), pp.timeoutNs(0, 1_000_000_000, 1));
    try std.testing.expectEqual(@as(?u64, null), pp.timeoutNs(0, 1_000_000, 1000));
    // Overflow saturates instead of wrapping.
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), pp.timeoutNs(std.math.maxInt(i64), 0, 1));
}

test "timeout write-back happens on success and EINTR, not on argument errors" {
    const pp = kt.poll_policy;
    try std.testing.expect(pp.writesBackTimeout(0));
    try std.testing.expect(pp.writesBackTimeout(3));
    try std.testing.expect(pp.writesBackTimeout(-4)); // EINTR
    try std.testing.expect(!pp.writesBackTimeout(-14)); // EFAULT
    try std.testing.expect(!pp.writesBackTimeout(-22)); // EINVAL
    try std.testing.expect(!pp.writesBackTimeout(-9)); // EBADF
}

test "ppoll, pselect6 and select write the remaining timeout back" {
    try std.testing.expect(std.mem.indexOf(u8, kt.poll_source, "finishTimeout(back, rc)") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.select_source, "poll_mod.beginTimeout(timeout_ptr, 1000)") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.select_source, "poll_mod.beginTimeout(timeout_ptr, 1)") != null);
    try std.testing.expect(std.mem.count(u8, kt.select_source, "finishTimeout(back, rc)") >= 2);
}

test "socketpair accepts stream, datagram and seqpacket, nothing else" {
    const sp = kt.socketpair_policy;
    try std.testing.expectEqual(@as(i64, 0), sp.validate(1, 1, 0));
    try std.testing.expectEqual(@as(i64, 0), sp.validate(1, 2, 0));
    try std.testing.expectEqual(@as(i64, 0), sp.validate(1, 2 | sp.SOCK_NONBLOCK | sp.SOCK_CLOEXEC, 0));
    try std.testing.expectEqual(@as(i64, -22), sp.validate(1, 3, 0));
    try std.testing.expectEqual(@as(i64, 0), sp.validate(1, 5, 0)); // SOCK_SEQPACKET since hello168
    try std.testing.expectEqual(@as(i64, -22), sp.validate(1, 4, 0)); // SOCK_RDM
    try std.testing.expectEqual(@as(i64, -22), sp.validate(1, 9, 0));
    try std.testing.expectEqual(@as(i64, -22), sp.validate(2, 2, 0));
    try std.testing.expectEqual(@as(i64, -22), sp.validate(1, 2, 7));
    try std.testing.expect(std.mem.indexOf(u8, kt.socket_syscall_source, "unixSocketPair(sock_type & 0xff)") != null);
}

test "a datagram send never calls a lock-taking helper from inside the lock" {
    const src = kt.unix_socket_source;
    const at = std.mem.indexOf(u8, src, "// One datagram: it fits the ring or it never will.").?;
    const body = src[at .. at + 900];
    // The fits check must not return through unixSendRights while unix_lock is held.
    try std.testing.expect(std.mem.indexOf(u8, body, "orelse return unixSendRights") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "orelse break :blk true") != null);
}

test "SCM_CREDENTIALS: message layout, parsing and claim validation" {
    const sp = kt.scm_policy;
    // Layout: CMSG_LEN 28, CMSG_SPACE 32, {pid, uid, gid} little endian.
    var out: [64]u8 = @splat(0xAA);
    const b = sp.buildCredentials(1234, 1000, 100, 64, &out);
    try std.testing.expectEqual(@as(usize, 32), b.written);
    try std.testing.expect(!b.truncated);
    try std.testing.expectEqual(@as(u64, 28), std.mem.readInt(u64, out[0..8], .little));
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, out[8..12], .little));
    try std.testing.expectEqual(@as(i32, 2), std.mem.readInt(i32, out[12..16], .little));
    try std.testing.expectEqual(@as(i32, 1234), std.mem.readInt(i32, out[16..20], .little));
    try std.testing.expectEqual(@as(u32, 1000), std.mem.readInt(u32, out[20..24], .little));
    try std.testing.expectEqual(@as(u32, 100), std.mem.readInt(u32, out[24..28], .little));
    try std.testing.expectEqual(@as(u8, 0), out[31]); // padding is zeroed
    // A buffer that cannot hold the whole message gets none of it.
    const small = sp.buildCredentials(1, 2, 3, 20, &out);
    try std.testing.expect(small.truncated);
    try std.testing.expectEqual(@as(usize, 0), small.written);
    // Exactly CMSG_LEN is enough (the trailing padding may be cut).
    const exact = sp.buildCredentials(1, 2, 3, 28, &out);
    try std.testing.expect(!exact.truncated);
    try std.testing.expectEqual(@as(usize, 28), exact.written);

    // Parsing a sender-supplied message.
    var ctl: [32]u8 = @splat(0);
    std.mem.writeInt(u64, ctl[0..8], 28, .little);
    std.mem.writeInt(i32, ctl[8..12], 1, .little);
    std.mem.writeInt(i32, ctl[12..16], 2, .little);
    std.mem.writeInt(i32, ctl[16..20], 77, .little);
    std.mem.writeInt(u32, ctl[20..24], 5, .little);
    std.mem.writeInt(u32, ctl[24..28], 6, .little);
    const p = sp.parseRights(&ctl).ok;
    try std.testing.expect(p.has_cred);
    try std.testing.expectEqual(@as(i32, 77), p.cred_pid);
    try std.testing.expectEqual(@as(u32, 5), p.cred_uid);
    try std.testing.expectEqual(@as(u32, 6), p.cred_gid);
    try std.testing.expectEqual(@as(usize, 0), p.count);
    // A credentials message of the wrong size is invalid.
    std.mem.writeInt(u64, ctl[0..8], 24, .little);
    try std.testing.expect(sp.parseRights(&ctl).err == .invalid);
    // Too long is invalid as well (never read past the 12 bytes of ucred).
    var long: [40]u8 = @splat(0);
    std.mem.writeInt(u64, long[0..8], 32, .little);
    std.mem.writeInt(i32, long[8..12], 1, .little);
    std.mem.writeInt(i32, long[12..16], 2, .little);
    try std.testing.expect(sp.parseRights(&long).err == .invalid);

    // Claims: own ids are always fine; anything else needs the capability.
    try std.testing.expect(sp.credsAcceptable(10, 1000, 100, 10, 1000, 100, false, false, false));
    try std.testing.expect(!sp.credsAcceptable(11, 1000, 100, 10, 1000, 100, false, false, false));
    try std.testing.expect(!sp.credsAcceptable(10, 0, 100, 10, 1000, 100, false, false, false));
    try std.testing.expect(!sp.credsAcceptable(10, 1000, 0, 10, 1000, 100, false, false, false));
    try std.testing.expect(sp.credsAcceptable(11, 1000, 100, 10, 1000, 100, true, false, false));
    try std.testing.expect(sp.credsAcceptable(10, 0, 100, 10, 1000, 100, false, true, false));
    try std.testing.expect(sp.credsAcceptable(10, 1000, 0, 10, 1000, 100, false, false, true));
    // The capability for one id does not cover another.
    try std.testing.expect(!sp.credsAcceptable(11, 0, 100, 10, 1000, 100, true, false, false));
    // Neither does a different capability cover the pid.
    try std.testing.expect(!sp.credsAcceptable(11, 1000, 100, 10, 1000, 100, false, true, true));
    try std.testing.expect(!sp.credsAcceptable(10, 0, 100, 10, 1000, 100, true, false, true));
    try std.testing.expect(!sp.credsAcceptable(10, 1000, 0, 10, 1000, 100, true, true, false));
}

test "SO_PASSCRED is a stored boolean and the receive path honours it" {
    const spo = kt.sockopt_policy;
    try std.testing.expectEqual(@as(u64, 16), spo.SO_PASSCRED);
    try std.testing.expect(spo.flagBit(spo.SO_PASSCRED) != null);
    try std.testing.expect(!spo.readOnly(spo.SO_PASSCRED));
    // Its bit differs from every other boolean option.
    for ([_]u64{ spo.SO_REUSEADDR, spo.SO_KEEPALIVE, spo.SO_BROADCAST, spo.SO_REUSEPORT, spo.SO_DEBUG }) |o| {
        try std.testing.expect(spo.flagBit(o).? != spo.flagBit(spo.SO_PASSCRED).?);
    }
    try std.testing.expect(std.mem.indexOf(u8, kt.socket_syscall_source, "sp.buildCredentials(out.cred.pid") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.socket_syscall_source, "rights.cred_override") != null);
}

test "recv flags: peek, truncation report and MSG_WAITALL rules" {
    const rf = kt.recv_flags_policy;
    try std.testing.expect(rf.peek(0x2));
    try std.testing.expect(rf.peek(0x2 | 0x40));
    try std.testing.expect(!rf.peek(0x40));
    try std.testing.expect(rf.truncReportsFullLength(0x20));
    try std.testing.expect(!rf.truncReportsFullLength(0x2));
    // WAITALL: streams only, blocking only, never with PEEK.
    try std.testing.expect(rf.waitAll(0x100, true, false));
    try std.testing.expect(!rf.waitAll(0x100, false, false));
    try std.testing.expect(!rf.waitAll(0x100, true, true));
    try std.testing.expect(!rf.waitAll(0x100 | 0x2, true, false));
    try std.testing.expect(!rf.waitAll(0, true, false));
    // The loop: done when full, again while short, stop on EOF / error / signal.
    try std.testing.expectEqual(rf.Step.done, rf.waitAllStep(8, 3, 5));
    try std.testing.expectEqual(rf.Step.done, rf.waitAllStep(8, 0, 8));
    try std.testing.expectEqual(rf.Step.again, rf.waitAllStep(8, 3, 2));
    try std.testing.expectEqual(rf.Step.again, rf.waitAllStep(8, 3, 1));
    try std.testing.expectEqual(rf.Step.stop, rf.waitAllStep(8, 3, 0));
    try std.testing.expectEqual(rf.Step.stop, rf.waitAllStep(8, 3, -4));
    try std.testing.expectEqual(rf.Step.stop, rf.waitAllStep(8, 3, -11));
}

test "peek never consumes: the peek entry points do not advance the read cursors" {
    const us = kt.unix_socket_source;
    const at = std.mem.indexOf(u8, us, "pub fn unixPeek").?;
    const end = std.mem.indexOfPos(u8, us, at, "pub fn unixIsStream").?;
    const body = us[at..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "buf_read = ") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "buf_count -= ") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "rx_pos +=") == null);
    const ts = kt.tcp_source;
    const tat = std.mem.indexOf(u8, ts, "pub fn tcpPeek").?;
    const tend = std.mem.indexOfPos(u8, ts, tat, "pub fn tcpRecvBlocking").?;
    const tbody = ts[tat..tend];
    try std.testing.expect(std.mem.indexOf(u8, tbody, "recv_head = ") == null);
    try std.testing.expect(std.mem.indexOf(u8, tbody, "sendSegment") == null);
}

test "fork and clone give the child the parent's SSE/x87 state" {
    try std.testing.expect(std.mem.indexOf(u8, kt.fork_source, "inheritFpuState(parent, child)") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.clone_source, "inheritFpuState(parent, child)") != null);
    // The helper saves the live registers of the calling task before copying,
    // and hands the child a clean ownership state so it restores from its area.
    const cs = kt.context_switch_source;
    const at = std.mem.indexOf(u8, cs, "pub fn inheritFpuState").?;
    // The body ends at the first closing brace in column 0.
    const end = std.mem.indexOfPos(u8, cs, at, "\n}\n").?;
    const body = cs[at..end];
    // The live registers of the calling task are saved into ITS area first.
    try std.testing.expect(std.mem.indexOf(u8, body, "fxsave (%[buf])") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "@ptrCast(&parent.fpu_state)") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "parent.fpu_owned and parent.fpu_home_cpu == my_cpu + 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "@memcpy(&child.fpu_state, &parent.fpu_state)") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "child.fpu_owned = false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "child.fpu_initialized = true") != null);
}

test "recvmsg honours MSG_PEEK / MSG_WAITALL / MSG_TRUNC on AF_UNIX and TCP" {
    const src = kt.socket_syscall_source;
    // AF_UNIX path
    try std.testing.expect(std.mem.indexOf(u8, src, "net_mod.unix_socket.unixPeek(idx, &data, room, &full)") != null);
    // WAITALL really loops: the guard is exactly "got something and WAITALL applies",
    // and the loop keeps reading while the step policy says "again".
    try std.testing.expect(std.mem.indexOf(u8, src, "if (n > 0 and rf.waitAll(flags, is_stream, nonblock)) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "while (rf.waitAllStep(room, got, 1) == .again) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "unixRecvBlockingRights(idx, @as([*]u8, @ptrCast(&data)) + got, room - got, false, &more)") != null);
    // A peek never reaches the consuming read.
    try std.testing.expect(std.mem.indexOf(u8, src, "if (rf.peek(flags)) {\n        // MSG_PEEK: look without consuming; no descriptor set is delivered.") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "out_flags |= rf.MSG_TRUNC") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "rf.truncReportsFullLength(flags) and cut_datagram") != null);
    // TCP path: only the supported flags are accepted, and a peek goes through tcpPeek.
    try std.testing.expect(std.mem.indexOf(u8, src, "rf_tcp.MSG_PEEK | net_mod.tcp_recv_policy.MSG_DONTWAIT | rf_tcp.MSG_WAITALL") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "net_mod.tcp.tcpPeek(tcb_idx, &tmp, room)") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "rf_tcp.waitAll(flags, true, base_nonblock)") != null);
    // The old per-iovec consume-then-copy loop must not come back: iovecs are validated first.
    const at = std.mem.indexOf(u8, src, "// Validate every iovec and total the room first").?;
    try std.testing.expect(at > 0);
}

test "seqpacket: identity, epoll room rule and the connection-oriented paths" {
    const spo = kt.sockopt_policy;
    try std.testing.expectEqual(@as(u32, 5), spo.identity(.unix_seqpacket, false).sock_type);
    try std.testing.expectEqual(@as(u32, 1), spo.identity(.unix_seqpacket, false).domain);
    try std.testing.expectEqual(@as(u32, 1), spo.identity(.unix_stream, false).sock_type);
    try std.testing.expectEqual(@as(u32, 2), spo.identity(.unix_dgram, false).sock_type);

    // A connected seqpacket socket sends records: it needs room for the
    // length prefix, like a datagram, not a single byte like a stream.
    const up = kt.unix_epoll_policy;
    const seq: up.State = .{ .stream = true, .msg_boundaries = true, .rx_bytes = 0, .listening = false, .pending_connections = 0, .disconnected = false, .peer_free = 2 };
    try std.testing.expectEqual(@as(u32, 0), up.events(seq) & up.EPOLLOUT);
    var roomy = seq;
    roomy.peer_free = 3;
    try std.testing.expect(up.events(roomy) & up.EPOLLOUT != 0);
    var strm = seq;
    strm.msg_boundaries = false;
    strm.peer_free = 1;
    try std.testing.expect(up.events(strm) & up.EPOLLOUT != 0);

    const src = kt.unix_socket_source;
    try std.testing.expect(std.mem.indexOf(u8, src, "fn connectionOriented(sock_type: u32) bool") != null);
    // connectionOriented is exactly {stream, seqpacket}: a datagram socket is not.
    try std.testing.expect(std.mem.indexOf(u8, src, "return sock_type == SOCK_STREAM or sock_type == SOCK_SEQPACKET;") != null);
    // socketpair really builds a seqpacket pair (the type check admits all three).
    try std.testing.expect(std.mem.indexOf(u8, src, "if (sock_type != SOCK_STREAM and sock_type != SOCK_DGRAM and sock_type != SOCK_SEQPACKET) return -22;\n    const saved") != null);
    // Both receive paths (read and peek) report EOF for a connection-oriented socket with no peer.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, src, "if (connectionOriented(sock.sock_type) and !sock.connected and !queuedOnBacklogLocked(idx)) return 0;"));
    // A blocking read waits only while a peer may still send.
    try std.testing.expect(std.mem.indexOf(u8, src, "(!connectionOriented(sock.sock_type) or sock.connected or queuedOnBacklogLocked(idx))") != null);
    // A vanished seqpacket peer is EPIPE, not ENOTCONN.
    try std.testing.expect(std.mem.indexOf(u8, src, "sock.sock_type == SOCK_SEQPACKET and sock.was_connected) -32 else -107") != null);
}

test "socket(AF_UNIX, SOCK_SEQPACKET): type matrix and the listen/connect/accept paths" {
    const np = kt.namespace_policy;
    // SEQPACKET (5) is an AF_UNIX type only, with the usual flags on top.
    try std.testing.expectEqual(@as(u32, 5), np.socketArgs(1, 5 | 0x80000 | 0x800, 0).ok.sock_type);
    try std.testing.expect(np.socketArgs(1, 5 | 0x80000 | 0x800, 0).ok.cloexec);
    try std.testing.expectEqual(@as(i64, -22), np.socketArgs(2, 5, 0).err);
    try std.testing.expectEqual(@as(i64, -22), np.socketArgs(10, 5, 0).err);
    try std.testing.expectEqual(@as(i64, -93), np.socketArgs(1, 5, 7).err);
    // Types 4 and 6.. stay invalid, RAW stays invalid for AF_UNIX.
    try std.testing.expectEqual(@as(i64, -22), np.socketArgs(1, 4, 0).err);
    try std.testing.expectEqual(@as(i64, -22), np.socketArgs(1, 6, 0).err);
    try std.testing.expectEqual(@as(i64, -22), np.socketArgs(1, 3, 0).err);

    const src = kt.unix_socket_source;
    // socket() admits all three types.
    try std.testing.expect(std.mem.indexOf(u8, src, "if (sock_type != SOCK_STREAM and sock_type != SOCK_DGRAM and sock_type != SOCK_SEQPACKET) return -22; // EINVAL\n\n    const saved") != null);
    // listen and accept work on connection-oriented sockets only.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, "if (!connectionOriented(sock.sock_type)) return -22; // EINVAL\n    if (!sock.bound) return -22;"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, "if (!connectionOriented(sock.sock_type)) return -22; // EINVAL\n    if (!sock.listening) return -22;"));
    // connect: a listener of another type is EPROTOTYPE, and a seqpacket client queues on the listener like a stream client.
    try std.testing.expect(std.mem.indexOf(u8, src, "if (peer.sock_type != sock.sock_type) return -91; // EPROTOTYPE\n    if (connectionOriented(sock.sock_type) and !peer.listening) return -111; // ECONNREFUSED") != null);
    // accept: the new socket takes the listener's type, and only same-type connectors are accepted.
    try std.testing.expect(std.mem.indexOf(u8, src, "queued.sock_type != sock.sock_type or queued.connected or queued.listening") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".sock_type = sock.sock_type,\n        .connected = true,\n        .was_connected = true,\n        .peer_idx = @intCast(conn_idx),") != null);
    // A record sent between connect() and accept() is parked, length-prefixed, in the pending buffer.
    try std.testing.expect(std.mem.indexOf(u8, src, "if (sock.sock_type == SOCK_SEQPACKET and !sock.connected) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "if (2 + len > UNIX_PENDING_MAX) return -90; // EMSGSIZE") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "if (sock.pending_len + 2 + len > UNIX_PENDING_MAX) return -11; // EAGAIN") != null);
    // Half-close, send room and epoll treat seqpacket like a stream.
    try std.testing.expect(std.mem.indexOf(u8, src, "return connectionOriented(unix_sockets[idx].sock_type) and np.halfCloseReadEof(halfCloseLocked(idx));") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "if (connectionOriented(sock.sock_type)) {\n        if (!sock.connected or !peer.connected or peer.peer_idx != @as(u8, @intCast(idx))) return null;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "if (connectionOriented(sock.sock_type)) {\n        if (shut_rd) sock.shut_rd = true;") != null);
}

test "cpu_time_policy: process totals, reclaimed threads and waited-for children" {
    const ct = kt.cpu_time_policy;
    // Two members: one stopped, one running a slice (user mode, 1000 ticks at 1000 MHz-equivalent = 1 us/tick-mhz).
    var total: ct.Times = .{};
    total = ct.addMember(total, .{ .user_us = 100, .sys_us = 10, .running = false, .is_user = true, .sched_in_tsc = 0 }, 5000, 1000);
    total = ct.addMember(total, .{ .user_us = 200, .sys_us = 20, .running = true, .is_user = true, .sched_in_tsc = 2000 }, 5000, 1000);
    try std.testing.expectEqual(@as(u64, 100 + 200 + 3), total.user_us); // 3000 tsc / 1000 mhz = 3 us in flight
    try std.testing.expectEqual(@as(u64, 30), total.sys_us);
    // A running kernel-mode task charges its slice to system time.
    const k = ct.addMember(.{}, .{ .user_us = 0, .sys_us = 0, .running = true, .is_user = false, .sched_in_tsc = 1000 }, 5000, 1000);
    try std.testing.expectEqual(@as(u64, 4), k.sys_us);
    try std.testing.expectEqual(@as(u64, 0), k.user_us);
    // A reclaimed thread's time moves to the leader.
    const dead = ct.foldDeadThread(.{ .user_us = 5, .sys_us = 6 }, 250_000, 1_000);
    try std.testing.expectEqual(@as(u64, 250_005), dead.user_us);
    try std.testing.expectEqual(@as(u64, 1_006), dead.sys_us);
    // wait4 reports the child's group plus the children it had waited for; the waiter inherits that.
    const usage = ct.reapedUsage(.{ .user_us = 100, .sys_us = 10, .child_user_us = 40, .child_sys_us = 4 });
    try std.testing.expectEqual(@as(u64, 140), usage.user_us);
    try std.testing.expectEqual(@as(u64, 14), usage.sys_us);
    const waiter = ct.inheritFromChild(.{ .child_user_us = 1, .child_sys_us = 2 }, usage);
    try std.testing.expectEqual(@as(u64, 141), waiter.child_user_us);
    try std.testing.expectEqual(@as(u64, 16), waiter.child_sys_us);
    // Saturating, never wrapping.
    const sat = ct.foldDeadThread(.{ .user_us = std.math.maxInt(u64) }, 1, 0);
    try std.testing.expectEqual(std.math.maxInt(u64), sat.user_us);
}

test "process CPU time wiring: reap folds children and threads, readers use the group totals" {
    const task_src = kt.task_source;
    // A reclaimed thread's time is folded into its leader before its slot is freed or detached.
    try std.testing.expect(std.mem.indexOf(u8, task_src, "fn freeSlotLocked(i: u32, t: *Task) void {\n    foldThreadTimeLocked(i, t);") != null);
    try std.testing.expect(std.mem.indexOf(u8, task_src, "fn detachLocked(i: u32, t: *Task, waiter: u32) void {\n    foldThreadTimeLocked(i, t);") != null);
    // Reaping a child adds its usage to the waiter's group leader.
    try std.testing.expect(std.mem.indexOf(u8, task_src, "const inherited = cpu_time_policy.inheritFromChild(") != null);
    try std.testing.expect(std.mem.indexOf(u8, task_src, "tasks[li].child_utime_us = inherited.child_user_us;") != null);
    // An exiting task folds its running slice before it becomes a zombie.
    try std.testing.expect(std.mem.indexOf(u8, task_src, "if (t.is_user) t.utime_us +|= slice else t.stime_us +|= slice;\n        t.sched_in_tsc = 0;") != null);
    // Members count by group: threads by parent_tid, the leader by tid.
    try std.testing.expect(std.mem.indexOf(u8, task_src, "const in_group = if (m.is_thread) m.parent_tid == gid else m.tid == gid;") != null);

    const wp = kt.waitpid_source;
    // Every reap path reports the usage, including the blocking one.
    try std.testing.expect(std.mem.indexOf(u8, wp, "if (usage_out) |u| u.* = reaped.usage;") != null);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, wp, "task_mod.waitpid(cur_idx, pid, &exit_code, usage_out)"));

    const sc = kt.syscall_entry_source;
    // wait4 fills the rusage only when a child was reaped; RUSAGE_SELF/CHILDREN use the process totals.
    try std.testing.expect(std.mem.indexOf(u8, sc, "if (rusage_ptr != 0 and rc > 0) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, sc, "if (who != .thread) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, sc, "user_us = pt.child_user_us;") != null);
    const ts = kt.time_syscall_source;
    try std.testing.expect(std.mem.indexOf(u8, ts, "if (!thread) return task_mod.processCpuTimes(idx, tsc.read(), tsc.tsc_freq_mhz).selfUs() *| 1000;") != null);
}

test "TCP over IPv6 loopback: a SYN to a port nobody listens on is answered with a RST" {
    const src = kt.tcp_source;
    // The v6 receive path resets a ::1 SYN that created no connection and has no listener.
    try std.testing.expect(std.mem.indexOf(u8, src, "if (pendingBacklogCount() == before and !hasListener(dst_port, true)) {\n                sendLoopbackResetV6(src_ip, dst_ip, src_port, dst_port, flags, ack_num, seq_num, payload_len);") != null);
    // The IPv4 rule is unchanged (v4 listeners only).
    try std.testing.expect(std.mem.indexOf(u8, src, "if (pendingBacklogCount() == before and !hasListener(dst_port, false)) {\n                sendLoopbackReset(") != null);
    // The reply is ::1 only, never answers a RST, goes back out through lo, and is checksummed for IPv6.
    try std.testing.expect(std.mem.indexOf(u8, src, "if (!netif.isLoopbackV6(src_ip) or !netif.isLoopbackV6(dst_ip)) return;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "fn sendLoopbackResetV6(") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const csum = tcpChecksumV6(dst_ip, src_ip, pkt[tcp_off..].ptr, 20);") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const frame_len = eth.buildFrame(&pkt, mac, mac, eth.ETHERTYPE_IPV6, ipv6.HEADER_LEN + 20);\n    _ = lo_dev.sendPacket(&pkt, frame_len);") != null);
    // Same RFC 9293 reply rule as IPv4: a segment carrying an ACK is answered by RST with seq = ack, otherwise RST|ACK.
    const tu = kt.tcp_util;
    const with_ack = tu.resetReply(true, 1000, 5, 0, false, false);
    try std.testing.expectEqual(@as(u32, 1000), with_ack.seq);
    try std.testing.expect(!with_ack.with_ack);
    const syn = tu.resetReply(false, 0, 77, 0, true, false);
    try std.testing.expectEqual(@as(u32, 78), syn.ack);
    try std.testing.expect(syn.with_ack);
}

test "ICMPv6 port unreachable for UDP over ::1: quote parsing, reply rule and wiring" {
    const up = kt.icmp_unreach_policy;
    // ICMPv6 header (8) + invoking IPv6 header (40) + UDP header (8): ports 24890 -> 24899.
    var msg: [56]u8 = @splat(0);
    msg[0] = 1; // destination unreachable
    msg[1] = 4; // port unreachable
    msg[8] = 0x60; // version 6
    msg[8 + 6] = 17; // next header UDP
    msg[48] = 0x61;
    msg[49] = 0x3a; // 24890
    msg[50] = 0x61;
    msg[51] = 0x43; // 24899
    const q = up.parseQuoteV6(&msg).?;
    try std.testing.expectEqual(@as(u16, 24890), q.src_port);
    try std.testing.expectEqual(@as(u16, 24899), q.dst_port);
    // Wrong type/code, non-UDP quote, wrong IP version and short messages are rejected.
    var bad = msg;
    bad[0] = 3;
    try std.testing.expect(up.parseQuoteV6(&bad) == null);
    bad = msg;
    bad[1] = 3;
    try std.testing.expect(up.parseQuoteV6(&bad) == null);
    bad = msg;
    bad[8 + 6] = 6;
    try std.testing.expect(up.parseQuoteV6(&bad) == null);
    bad = msg;
    bad[8] = 0x40;
    try std.testing.expect(up.parseQuoteV6(&bad) == null);
    try std.testing.expect(up.parseQuoteV6(msg[0..55]) == null);
    // The reply is ::1 to ::1 only, and never when the port is bound.
    try std.testing.expect(up.shouldReplyV6(true, true, false));
    try std.testing.expect(!up.shouldReplyV6(true, true, true));
    try std.testing.expect(!up.shouldReplyV6(false, true, false));
    try std.testing.expect(!up.shouldReplyV6(true, false, false));

    // Wiring: the v6 receive path replies, the checksum covers the reply's own pseudo header, ICMPv6 dispatches to the UDP socket.
    const us = kt.udp_source;
    try std.testing.expect(std.mem.indexOf(u8, us, "shouldReplyV6(netif.isLoopbackV6(src_ip), netif.isLoopbackV6(dst_ip), bound)") != null);
    try std.testing.expect(std.mem.indexOf(u8, us, "icmpv6.checksum(dst_ip, src_ip, pkt[icmp_off..].ptr, icmp_len)") != null);
    try std.testing.expect(std.mem.indexOf(u8, us, "pkt[icmp_off] = 1;\n    pkt[icmp_off + 1] = 4;") != null);
    try std.testing.expect(std.mem.indexOf(u8, us, "eth.ETHERTYPE_IPV6, ipv6.HEADER_LEN + icmp_len);\n    _ = lo.sendPacket(&pkt, frame_len);") != null);
    const v6src = kt.icmpv6_source;
    try std.testing.expect(std.mem.indexOf(u8, v6src, "DEST_UNREACHABLE => {") != null);
    try std.testing.expect(std.mem.indexOf(u8, v6src, "@import(\"udp.zig\").notifyUnreachable(q.src_port, q.dst_port);") != null);
}

test "ioctl(TIOCOUTQ): socket send-queue reporting and its wiring" {
    const ip = kt.ioctl_policy;
    try std.testing.expectEqual(@as(u64, 0x5411), ip.TIOCOUTQ);
    // It is not a terminal-only request: a socket must reach the handler.
    try std.testing.expect(!ip.isTerminalRequest(ip.TIOCOUTQ));
    try std.testing.expectEqual(@as(i64, 0), ip.terminalCheck(ip.TIOCOUTQ, .other));

    const src = kt.ioctl_source;
    try std.testing.expect(std.mem.indexOf(u8, src, ".tcp_socket => @import(\"../net/tcp.zig\").tcpSendQueued(desc.tcb_idx),") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".unix_socket => @import(\"../net/unix_socket.zig\").unixSendQueued(desc.unix_sock_idx),") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".udp_socket => 0,\n                else => return -25, // ENOTTY") != null);
    // The counter is clamped to a non-negative int before copy-out.
    try std.testing.expect(std.mem.indexOf(u8, src, "const v: i32 = @intCast(@min(queued, 0x7FFF_FFFF));") != null);

    // TCP counts the whole send ring (unsent + unacknowledged); AF_UNIX counts the peer's ring after validating the back-reference.
    const ts = kt.tcp_source;
    try std.testing.expect(std.mem.indexOf(u8, ts, "pub fn tcpSendQueued(tcb_idx: u32) u32 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "return ringDataLen(tcb.send_head, tcb.send_tail, SEND_BUF_SIZE);\n}\n\n/// Return the number of bytes of free space in the send buffer.") != null);
    const us = kt.unix_socket_source;
    try std.testing.expect(std.mem.indexOf(u8, us, "if (!sock.active or !sock.connected or sock.peer_idx >= MAX_UNIX_SOCKETS) return 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, us, "if (!peer.active or peer.peer_idx != @as(u8, @intCast(idx))) return 0;\n    return peer.buf_count;") != null);
}

test "TCP delivery-rate samples: only bulk, recent acknowledgements measure the path" {
    const tu = kt.tcp_util;
    // A lone small write acknowledged after the delayed-ACK interval says nothing about bandwidth.
    try std.testing.expect(!tu.deliverySampleUsable(100, 1460, 400));
    // At most one segment is application-limited, however quick.
    try std.testing.expect(!tu.deliverySampleUsable(1460, 1460, 5));
    // More than one segment, soon after the previous sample: a real sample.
    try std.testing.expect(tu.deliverySampleUsable(2921, 1460, 5));
    try std.testing.expect(tu.deliverySampleUsable(65536, 1460, 1000));
    // Across an idle gap the sender set the pace.
    try std.testing.expect(!tu.deliverySampleUsable(65536, 1460, 1001));
    // No time elapsed: no rate; a zero SMSS never divides or underflows.
    try std.testing.expect(!tu.deliverySampleUsable(65536, 1460, 0));
    try std.testing.expect(tu.deliverySampleUsable(2, 0, 10));
    try std.testing.expect(!tu.deliverySampleUsable(1, 0, 10));
    // And the wiring: the sampler consults the rule instead of accepting any positive elapsed time.
    try std.testing.expect(std.mem.indexOf(u8, kt.tcp_source, "if (tcp_util.deliverySampleUsable(delivered, mssForTcb(tcb), elapsed)) {") != null);
}

test "a pipe dup2'd onto stdin/stdout/stderr is released by close() and at exit, so its reader sees EOF" {
    const vfs = kt.vfs_source;
    // close(0..2) is a no-op only while the slot still holds the console; once dup2 put something else there it is a real close.
    try std.testing.expect(std.mem.indexOf(u8, vfs, "if (fd <= FD_STDERR and self.fds[fd].fd_type == .special) return 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, vfs, "        if (fd <= FD_STDERR) return 0;\n") == null);
    // Both exit paths walk the whole table, not just fd 3 and up.
    const ts = kt.task_source;
    try std.testing.expect(std.mem.indexOf(u8, ts, "var fd: u32 = 3;") == null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, ts, "var fd: u32 = 0;\n"));
}

test "TCP pacing never drops below one congestion window per RTT, so a collapsed delivery-rate estimate cannot lock the sender" {
    const tu = kt.tcp_util;
    // The stuck state seen in hello174: a 5.5 kB/s estimate, a two-segment window, ~100 ms RTT (delayed ACKs).
    // Paced at 5.5 kB/s a segment leaves every ~264 ms, each ACK covers one segment, and a one-segment
    // sample is rejected, so the estimate can never rise again.
    try std.testing.expectEqual(@as(u32, 29200), tu.paceRateFloor(2920, 100));
    try std.testing.expectEqual(@as(u32, 29200), tu.pacedRate(5530, 2920, 100));
    // At that floor a delayed ACK covers two segments and the sample is usable and higher than the stuck estimate.
    try std.testing.expect(tu.deliverySampleUsable(2920, 1460, 100));
    try std.testing.expect(tu.pacedRate(5530, 2920, 100) > 5530);
    // A healthy estimate above the floor is left alone.
    try std.testing.expectEqual(@as(u32, 1_000_000), tu.pacedRate(1_000_000, 14600, 100));
    // No estimate yet means no pacing at all, whatever the window.
    try std.testing.expectEqual(@as(u32, 0), tu.pacedRate(0, 14600, 100));
    // No RTT sample yet: treat it as 1 ms rather than dividing by zero.
    try std.testing.expectEqual(@as(u32, 2_920_000), tu.paceRateFloor(2920, 0));
    // Saturates instead of wrapping.
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), tu.paceRateFloor(0xffff_ffff, 1));
    try std.testing.expectEqual(@as(u32, 0), tu.paceRateFloor(0, 100));
    // The pacer consults it.
    try std.testing.expect(std.mem.indexOf(u8, kt.tcp_source, "tcp_util.pacedRate(v32, tcb.cwnd, tcb.srtt)") != null);
}

test "SO_SNDBUF / SO_RCVBUF values: doubling, minimums and the rmem_max cap never overflow" {
    const p = kt.sockopt_policy;
    // Runtime-known requests: with comptime arguments the whole call folds at compile time and hides a narrowed integer type.
    var req: u32 = 8192;
    std.mem.doNotOptimizeAway(&req);
    try std.testing.expectEqual(@as(u32, 16384), p.bufferValue(req, p.SOCK_MIN_SNDBUF));
    req = 100;
    try std.testing.expectEqual(@as(u32, 4608), p.bufferValue(req, p.SOCK_MIN_SNDBUF));
    try std.testing.expectEqual(@as(u32, 2304), p.bufferValue(req, p.SOCK_MIN_RCVBUF));
    req = 0;
    try std.testing.expectEqual(@as(u32, 0), p.bufferValue(req, 0));
    // Requests at and above rmem_max are capped, then doubled: 2 * 212992 does not fit in the 18 bits that
    // @min(request, RMEM_MAX) would narrow to.
    req = p.RMEM_MAX;
    try std.testing.expectEqual(@as(u32, 2 * p.RMEM_MAX), p.bufferValue(req, p.SOCK_MIN_RCVBUF));
    req = 131072;
    try std.testing.expectEqual(@as(u32, 262144), p.bufferValue(req, p.SOCK_MIN_RCVBUF));
    req = 1 << 20;
    try std.testing.expectEqual(@as(u32, 2 * p.RMEM_MAX), p.bufferValue(req, p.SOCK_MIN_SNDBUF));
    req = 1 << 30;
    try std.testing.expectEqual(@as(u32, 2 * p.RMEM_MAX), p.bufferValue(req, p.SOCK_MIN_SNDBUF));
    req = std.math.maxInt(u32);
    try std.testing.expectEqual(@as(u32, 2 * p.RMEM_MAX), p.bufferValue(req, p.SOCK_MIN_SNDBUF));
}

test "TCP buffer limits: SO_SNDBUF / SO_RCVBUF bound the rings only when set" {
    const tu = kt.tcp_util;
    // Never set: the whole ring (one slot is reserved).
    try std.testing.expectEqual(@as(u32, 65535), tu.bufferLimit(false, 16384, 65536));
    // Set: half of the stored (doubled) value, never more than the ring.
    try std.testing.expectEqual(@as(u32, 8192), tu.bufferLimit(true, 16384, 65536));
    try std.testing.expectEqual(@as(u32, 2304), tu.bufferLimit(true, 4608, 65536));
    try std.testing.expectEqual(@as(u32, 65535), tu.bufferLimit(true, 425984, 65536));
    try std.testing.expectEqual(@as(u32, 0), tu.bufferLimit(true, 0, 65536));
    // Room under a limit saturates: a limit lowered below what is queued leaves no room, never a huge wrapped one.
    try std.testing.expectEqual(@as(u32, 4096), tu.roomUnder(4096, 8192));
    try std.testing.expectEqual(@as(u32, 0), tu.roomUnder(8192, 8192));
    try std.testing.expectEqual(@as(u32, 0), tu.roomUnder(9000, 8192));

    // Wiring: every place that sizes the send ring or the window goes through the limit.
    const src = kt.tcp_source;
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, src, "const free_space = tcp_util.roomUnder(used, sendLimit(tcb));"));
    try std.testing.expect(std.mem.indexOf(u8, src, "if (tcp_util.roomUnder(used, sendLimit(tcb)) > 0) return 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "return tcp_util.roomUnder(ringDataLen(tcb.send_head, tcb.send_tail, SEND_BUF_SIZE), sendLimit(tcb));") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".send_space = tcp_util.roomUnder(ringDataLen(tcb.send_head, tcb.send_tail, SEND_BUF_SIZE), sendLimit(tcb)),") != null);
    // two window recomputations (data arrival, recv) plus the new acceptance bound in processIncomingData
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, src, "RECV_BUF_SIZE), rcvWindowCap(tcb));"));
    try std.testing.expect(std.mem.indexOf(u8, src, "return @min(TCP_WINDOW, tcp_util.bufferLimit(tcb.options.rcv_buf_set, tcb.options.rcv_buf_size, RECV_BUF_SIZE));") != null);
    // The option setter stores the doubled, clamped value and records that the option was set.
    const so = kt.socket_opt_source;
    try std.testing.expect(std.mem.indexOf(u8, so, "opts.snd_buf_size = sp.bufferValue(bo.readU32Le(&buf), sp.SOCK_MIN_SNDBUF);\n                opts.snd_buf_set = true;") != null);
    try std.testing.expect(std.mem.indexOf(u8, so, "opts.rcv_buf_size = sp.bufferValue(bo.readU32Le(&buf), sp.SOCK_MIN_RCVBUF);\n                opts.rcv_buf_set = true;") != null);
}

test "TCP delivery-rate sampling restarts after the connection goes idle" {
    const tu = kt.tcp_util;
    // Everything acknowledged: the next sample has no base (it only seeds one).
    try std.testing.expectEqual(@as(u32, 0), tu.sampleBaseAfterAck(true, 12345));
    // Data still in flight: the sample base is now.
    try std.testing.expectEqual(@as(u32, 12345), tu.sampleBaseAfterAck(false, 12345));
    // A zero base means the sampler skips the next sample.
    const src = kt.tcp_source;
    try std.testing.expect(std.mem.indexOf(u8, src, "tcb.rate_sample_ms = tcp_util.sampleBaseAfterAck(tcb.snd_una == tcb.snd_nxt, now);") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "if (tcb.rate_sample_ms != 0) {\n        const elapsed = now -% tcb.rate_sample_ms;") != null);
}

test "netdevice ioctls: request set and ioctl wiring" {
    const f = kt.ifreq_policy;
    // The request numbers are Linux's.
    try std.testing.expectEqual(@as(u64, 0x8910), f.SIOCGIFNAME);
    try std.testing.expectEqual(@as(u64, 0x8912), f.SIOCGIFCONF);
    try std.testing.expectEqual(@as(u64, 0x8913), f.SIOCGIFFLAGS);
    try std.testing.expectEqual(@as(u64, 0x8915), f.SIOCGIFADDR);
    try std.testing.expectEqual(@as(u64, 0x8919), f.SIOCGIFBRDADDR);
    try std.testing.expectEqual(@as(u64, 0x891b), f.SIOCGIFNETMASK);
    try std.testing.expectEqual(@as(u64, 0x8921), f.SIOCGIFMTU);
    try std.testing.expectEqual(@as(u64, 0x8927), f.SIOCGIFHWADDR);
    try std.testing.expectEqual(@as(u64, 0x8933), f.SIOCGIFINDEX);
    try std.testing.expectEqual(@as(usize, 40), f.IFREQ_SIZE);
    // They are not terminal requests: a socket must reach the handler.
    try std.testing.expect(!kt.ioctl_policy.isTerminalRequest(f.SIOCGIFADDR));

    const src = kt.ioctl_source;
    // Only socket descriptors answer; everything else is ENOTTY.
    try std.testing.expect(std.mem.indexOf(u8, src, ".tcp_socket, .udp_socket, .unix_socket, .raw_socket => {},\n                else => return -25, // ENOTTY\n            }\n            return netdeviceIoctl(cmd, arg);") != null);
    // eth0 only exists once a NIC is up; lo is always there with index 1.
    try std.testing.expect(std.mem.indexOf(u8, src, "if (nic.isActive()) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".index = 1,") != null);
    // An unknown name or index is ENODEV, a bad user pointer EFAULT, a negative ifc_len EINVAL.
    try std.testing.expect(std.mem.indexOf(u8, src, "const found = idx orelse return ifr.ENODEV;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "if (len_in < 0) return -22;") != null);
    // SIOCGIFCONF reports the bytes written back in ifc_len, and only whole records.
    try std.testing.expect(std.mem.indexOf(u8, src, "const fit = ifr.confFit(ifs.len, @intCast(len_in));") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "written = ifr.confSize(ifs.len);") != null);
    // eth0 is added only inside the nic.isActive() branch, after lo; with no NIC the count stays 1.
    try std.testing.expect(std.mem.indexOf(u8, src, "    n += 1;\n    if (nic.isActive()) {\n        out[n] = .{\n            .name = ifr.makeName(\"eth0\"),") != null);
    // SIOCGIFCONF copies exactly the whole records that fit, then writes the byte count back.
    try std.testing.expect(std.mem.indexOf(u8, src, "written = fit * ifr.IFREQ_SIZE;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "std.mem.writeInt(i32, hdr[0..4], @intCast(written), .little);") != null);
    // All nine requests reach the handler through one dispatch arm.
    try std.testing.expect(std.mem.indexOf(u8, src, "ifr.SIOCGIFNAME, ifr.SIOCGIFCONF, ifr.SIOCGIFFLAGS, ifr.SIOCGIFADDR, ifr.SIOCGIFBRDADDR, ifr.SIOCGIFNETMASK, ifr.SIOCGIFMTU, ifr.SIOCGIFHWADDR, ifr.SIOCGIFINDEX => {") != null);
    // SIOCGIFNAME looks up by index; every other request by name.
    try std.testing.expect(std.mem.indexOf(u8, src, "ifr.findByIndex(ifs[0..count], std.mem.readInt(u32, req[16..20], .little))") != null);
}

test "ifreq policy: interface lookup and request encodings" {
    const f = kt.ifreq_policy;
    const lo_if: f.Iface = .{ .name = f.makeName("lo"), .index = 1, .flags = f.IFF_UP | f.IFF_LOOPBACK | f.IFF_RUNNING, .ip = .{ 127, 0, 0, 1 }, .netmask = .{ 255, 0, 0, 0 }, .mtu = 65536, .loopback = true };
    const eth_if: f.Iface = .{ .name = f.makeName("eth0"), .index = 2, .flags = f.IFF_UP | f.IFF_BROADCAST | f.IFF_RUNNING | f.IFF_MULTICAST, .ip = .{ 10, 0, 2, 15 }, .netmask = .{ 255, 255, 255, 0 }, .mac = .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 }, .mtu = 1500 };
    const ifs = [_]f.Iface{ lo_if, eth_if };
    try std.testing.expectEqual(@as(?usize, 1), f.findByName(&ifs, &f.makeName("eth0")));
    try std.testing.expectEqual(@as(?usize, null), f.findByName(&ifs, &f.makeName("eth1")));
    try std.testing.expectEqual(@as(?usize, null), f.findByName(&ifs, &f.makeName("")));
    // A name that fills all 16 bytes with no terminator names nothing, and a prefix of a real name is not a match.
    try std.testing.expectEqual(@as(?usize, null), f.findByName(&ifs, &([_]u8{'e'} ** f.IFNAMSIZ)));
    try std.testing.expectEqual(@as(?usize, null), f.findByName(&ifs, &f.makeName("eth")));
    try std.testing.expectEqual(@as(?usize, 0), f.findByIndex(&ifs, 1));
    try std.testing.expectEqual(@as(?usize, null), f.findByIndex(&ifs, 9));
    var buf: [f.IFREQ_SIZE]u8 = @splat(0xAA);
    try std.testing.expectEqual(@as(i64, 0), f.answer(f.SIOCGIFADDR, eth_if, &buf));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, buf[16..18], .little));
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 2, 15 }, buf[20..24]);
    try std.testing.expectEqual(@as(u8, 0), buf[39]); // the rest of the union is zeroed
    try std.testing.expectEqual(@as(i64, 0), f.answer(f.SIOCGIFBRDADDR, eth_if, &buf));
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 2, 255 }, buf[20..24]);
    try std.testing.expectEqual(f.EADDRNOTAVAIL, f.answer(f.SIOCGIFBRDADDR, lo_if, &buf));
    try std.testing.expectEqual(@as(i64, 0), f.answer(f.SIOCGIFHWADDR, eth_if, &buf));
    try std.testing.expectEqual(f.ARPHRD_ETHER, std.mem.readInt(u16, buf[16..18], .little));
    try std.testing.expectEqualSlices(u8, &eth_if.mac, buf[18..24]);
    try std.testing.expectEqual(@as(i64, 0), f.answer(f.SIOCGIFHWADDR, lo_if, &buf));
    try std.testing.expectEqual(f.ARPHRD_LOOPBACK, std.mem.readInt(u16, buf[16..18], .little));
    try std.testing.expectEqual(@as(i64, 0), f.answer(f.SIOCGIFMTU, lo_if, &buf));
    try std.testing.expectEqual(@as(u32, 65536), std.mem.readInt(u32, buf[16..20], .little));
    try std.testing.expectEqual(@as(i64, 0), f.answer(f.SIOCGIFINDEX, eth_if, &buf));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, buf[16..20], .little));
    try std.testing.expectEqual(@as(i64, 0), f.answer(f.SIOCGIFFLAGS, lo_if, &buf));
    try std.testing.expectEqual(@as(u16, 0x49), std.mem.readInt(u16, buf[16..18], .little));
    try std.testing.expectEqual(@as(i64, 0), f.answer(f.SIOCGIFFLAGS, eth_if, &buf));
    try std.testing.expectEqual(@as(u16, 0x1043), std.mem.readInt(u16, buf[16..18], .little));
    try std.testing.expectEqual(@as(i64, 0), f.answer(f.SIOCGIFNETMASK, lo_if, &buf));
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0 }, buf[20..24]);
    try std.testing.expectEqual(@as(i64, 0), f.answer(f.SIOCGIFNAME, eth_if, &buf));
    try std.testing.expectEqualSlices(u8, &eth_if.name, buf[0..16]);
    try std.testing.expectEqual(f.EINVAL, f.answer(0x1234, eth_if, &buf));
    // SIOCGIFCONF sizing: whole 40-byte records only.
    try std.testing.expectEqual(@as(usize, 80), f.confSize(2));
    try std.testing.expectEqual(@as(usize, 2), f.confFit(2, 80));
    try std.testing.expectEqual(@as(usize, 1), f.confFit(2, 79));
    try std.testing.expectEqual(@as(usize, 0), f.confFit(2, 39));
    try std.testing.expectEqual(@as(usize, 2), f.confFit(2, 4000));
    var rec: [f.IFREQ_SIZE]u8 = undefined;
    f.confRecord(eth_if, &rec);
    try std.testing.expectEqualSlices(u8, &eth_if.name, rec[0..16]);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 2, 15 }, rec[20..24]);
    // Every request the ioctl dispatches on is recognised; others are not.
    for ([_]u64{ f.SIOCGIFNAME, f.SIOCGIFCONF, f.SIOCGIFFLAGS, f.SIOCGIFADDR, f.SIOCGIFBRDADDR, f.SIOCGIFNETMASK, f.SIOCGIFMTU, f.SIOCGIFHWADDR, f.SIOCGIFINDEX }) |cmd| {
        try std.testing.expect(f.isRequest(cmd));
    }
    try std.testing.expect(!f.isRequest(0x8914)); // SIOCSIFADDR: the set requests are not implemented
    // A 16-byte name with no NUL names nothing even when an interface shares its 15-byte prefix; the empty name too.
    const odd: f.Iface = .{ .name = ([_]u8{'a'} ** 15) ++ [_]u8{0}, .index = 7 };
    try std.testing.expectEqual(@as(?usize, null), f.findByName(&[_]f.Iface{odd}, &(([_]u8{'a'} ** 15) ++ [_]u8{'a'})));
    try std.testing.expectEqual(@as(?usize, 0), f.findByName(&[_]f.Iface{odd}, &(([_]u8{'a'} ** 15) ++ [_]u8{0})));
    // Even an interface whose stored name fills all 16 bytes is not selected by an unterminated request name.
    const full: f.Iface = .{ .name = [_]u8{'b'} ** f.IFNAMSIZ, .index = 8 };
    try std.testing.expectEqual(@as(?usize, null), f.findByName(&[_]f.Iface{full}, &([_]u8{'b'} ** f.IFNAMSIZ)));
    // A loopback interface has no broadcast address even if the BROADCAST flag were set on it.
    const lo_bc: f.Iface = .{ .name = f.makeName("lo"), .index = 1, .flags = f.IFF_UP | f.IFF_BROADCAST, .ip = .{ 127, 0, 0, 1 }, .netmask = .{ 255, 0, 0, 0 }, .loopback = true };
    try std.testing.expectEqual(@as(?[4]u8, null), f.broadcast(lo_bc));
    try std.testing.expectEqual(f.EADDRNOTAVAIL, f.answer(f.SIOCGIFBRDADDR, lo_bc, &buf));
    // An interface without the BROADCAST flag has none either.
    var plain = eth_if;
    plain.flags = f.IFF_UP;
    try std.testing.expectEqual(@as(?[4]u8, null), f.broadcast(plain));
    // confFit is bounded by both the interface count and the caller's buffer.
    try std.testing.expectEqual(@as(usize, 2), f.confFit(2, 1 << 20));
    try std.testing.expectEqual(@as(usize, 3), f.confFit(5, 3 * f.IFREQ_SIZE + 39));
    try std.testing.expect(f.isRequest(f.SIOCGIFCONF) and !f.isRequest(0x541B));
}

test "tcp_info policy: option numbers, MAXSEG rules, state mapping and the TCP_INFO layout" {
    const t = kt.tcp_info_policy;
    // Linux's numbers.
    try std.testing.expectEqual(@as(u64, 2), t.TCP_MAXSEG);
    try std.testing.expectEqual(@as(u64, 7), t.TCP_SYNCNT);
    try std.testing.expectEqual(@as(u64, 8), t.TCP_LINGER2);
    try std.testing.expectEqual(@as(u64, 9), t.TCP_DEFER_ACCEPT);
    try std.testing.expectEqual(@as(u64, 11), t.TCP_INFO);
    try std.testing.expectEqual(@as(u64, 13), t.TCP_CONGESTION);
    try std.testing.expectEqual(@as(u64, 18), t.TCP_USER_TIMEOUT);
    try std.testing.expectEqual(@as(u64, 25), t.TCP_NOTSENT_LOWAT);
    // TCP_MAXSEG range: 88..1460 inclusive.
    try std.testing.expect(!t.maxsegValid(87) and t.maxsegValid(88) and t.maxsegValid(1460) and !t.maxsegValid(1461) and !t.maxsegValid(0));
    // The user ceiling only ever lowers the path MSS; 0 means none.
    try std.testing.expectEqual(@as(u32, 1460), t.effectiveMss(1460, 0));
    try std.testing.expectEqual(@as(u32, 536), t.effectiveMss(1460, 536));
    try std.testing.expectEqual(@as(u32, 1000), t.effectiveMss(1000, 1400));
    // Our states map to Linux's numbering.
    const S = kt.tcp_recv_policy.TcpState;
    try std.testing.expectEqual(t.LinuxState.established, t.linuxState(S.established));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(t.linuxState(S.established)));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(t.linuxState(S.syn_sent)));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(t.linuxState(S.syn_received)));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(t.linuxState(S.fin_wait_1)));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(t.linuxState(S.fin_wait_2)));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(t.linuxState(S.time_wait)));
    try std.testing.expectEqual(@as(u8, 7), @intFromEnum(t.linuxState(S.closed)));
    try std.testing.expectEqual(@as(u8, 8), @intFromEnum(t.linuxState(S.close_wait)));
    try std.testing.expectEqual(@as(u8, 9), @intFromEnum(t.linuxState(S.last_ack)));
    try std.testing.expectEqual(@as(u8, 10), @intFromEnum(t.linuxState(S.listen)));
    try std.testing.expectEqual(@as(u8, 11), @intFromEnum(t.linuxState(S.closing)));
    // struct tcp_info layout: byte fields, then 32-bit fields at Linux's offsets, everything else zero.
    var out: [t.TCP_INFO_LEN]u8 = undefined;
    t.encode(.{ .state = .established, .retransmits = 3, .ts = true, .sack = true, .wscale = true, .ecn = true, .snd_wscale = 7, .rcv_wscale = 2, .rto_us = 200_000, .snd_mss = 1448, .rcv_mss = 1400, .unacked = 4096, .pmtu = 1500, .rtt_us = 1000, .rttvar_us = 500, .snd_ssthresh = 65535, .snd_cwnd_segs = 10, .rcv_space = 32768 }, &out);
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    try std.testing.expectEqual(@as(u8, 3), out[2]);
    try std.testing.expectEqual(@as(u8, 0xF), out[5]); // TS | SACK | WSCALE | ECN
    try std.testing.expectEqual(@as(u8, 0x27), out[6]); // rcv_wscale in the high nibble, snd_wscale in the low
    try std.testing.expectEqual(@as(u32, 200_000), std.mem.readInt(u32, out[8..12], .little));
    try std.testing.expectEqual(@as(u32, 1448), std.mem.readInt(u32, out[16..20], .little));
    try std.testing.expectEqual(@as(u32, 1400), std.mem.readInt(u32, out[20..24], .little));
    try std.testing.expectEqual(@as(u32, 4096), std.mem.readInt(u32, out[24..28], .little));
    try std.testing.expectEqual(@as(u32, 1500), std.mem.readInt(u32, out[60..64], .little));
    try std.testing.expectEqual(@as(u32, 1000), std.mem.readInt(u32, out[68..72], .little));
    try std.testing.expectEqual(@as(u32, 500), std.mem.readInt(u32, out[72..76], .little));
    try std.testing.expectEqual(@as(u32, 65535), std.mem.readInt(u32, out[76..80], .little));
    try std.testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, out[80..84], .little));
    try std.testing.expectEqual(@as(u32, 32768), std.mem.readInt(u32, out[96..100], .little));
    try std.testing.expectEqual(@as(u8, 0), out[1]);
    try std.testing.expectEqual(@as(u8, 0), out[103]);
    // Unit helpers: ms to us saturates, cwnd in whole segments, zero MSS never divides by zero.
    try std.testing.expectEqual(@as(u32, 5000), t.msToUs(5));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), t.msToUs(0xFFFF_FFFF));
    try std.testing.expectEqual(@as(u32, 10), t.cwndSegments(14600, 1460));
    try std.testing.expectEqual(@as(u32, 3), t.cwndSegments(4500, 1460));
    try std.testing.expectEqual(@as(u32, 7), t.cwndSegments(7, 0));
}

test "TCP socket options: MAXSEG / INFO / CONGESTION wiring" {
    const so = kt.socket_opt_source;
    // MAXSEG: validated, only before the connection is up, stored as a ceiling.
    try std.testing.expect(std.mem.indexOf(u8, so, "if (!tip.maxsegValid(v)) return -22;") != null);
    try std.testing.expect(std.mem.indexOf(u8, so, "if (!tcp_mod.tcpMaxsegSettable(tcb_idx)) return -22;\n                opts.user_mss = v;") != null);
    // CONGESTION: only the algorithm that runs; anything else is ENOENT.
    try std.testing.expect(std.mem.indexOf(u8, so, "if (!std.mem.eql(u8, name[0..len], tip.CONGESTION_NAME)) return -2; // ENOENT") != null);
    // The inert options reject a negative value (except LINGER2, where negative means "no FIN_WAIT_2").
    try std.testing.expect(std.mem.indexOf(u8, so, "< 0 and optname != tip.TCP_LINGER2) return -22;") != null);
    // TCP_INFO truncates to the caller's length and reports the length written.
    try std.testing.expect(std.mem.indexOf(u8, so, "const n: u32 = @intCast(@min(@as(usize, user_optlen), info.len));") != null);
    try std.testing.expect(std.mem.indexOf(u8, so, "tcp_mod.tcpInfoSnapshot(tcb_idx) orelse return -88") != null);

    const ts = kt.tcp_source;
    // The sender's MSS honours the user ceiling.
    try std.testing.expect(std.mem.indexOf(u8, ts, "return @intCast(tcp_info_policy.effectiveMss(path, tcb.options.user_mss));") != null);
    // MAXSEG is settable only while the connection has not been established.
    try std.testing.expect(std.mem.indexOf(u8, ts, ".closed, .listen, .syn_sent => true,\n        else => false,") != null);
}

test "ip_opt policy: validation, readback and the patched header bytes" {
    const p = kt.ip_opt_policy;
    const v4 = kt.ipv4;
    // Option numbers and levels are Linux's.
    try std.testing.expectEqual(@as(u64, 0), p.SOL_IP);
    try std.testing.expectEqual(@as(u64, 41), p.SOL_IPV6);
    try std.testing.expectEqual(@as(u64, 1), p.IP_TOS);
    try std.testing.expectEqual(@as(u64, 2), p.IP_TTL);
    try std.testing.expectEqual(@as(u64, 16), p.IPV6_UNICAST_HOPS);
    try std.testing.expectEqual(@as(u64, 26), p.IPV6_V6ONLY);
    try std.testing.expectEqual(@as(u64, 67), p.IPV6_TCLASS);
    // A socket answers only the level of its own family.
    try std.testing.expect(p.levelApplies(p.SOL_IP, .v4) and !p.levelApplies(p.SOL_IPV6, .v4));
    try std.testing.expect(p.levelApplies(p.SOL_IPV6, .v6) and !p.levelApplies(p.SOL_IP, .v6));
    // Value decoding: a 4-byte int, or a single byte; anything else is invalid.
    try std.testing.expectEqual(@as(?i32, 17), p.readInt(&.{ 17, 0, 0, 0 }));
    try std.testing.expectEqual(@as(?i32, -1), p.readInt(&.{ 0xFF, 0xFF, 0xFF, 0xFF }));
    try std.testing.expectEqual(@as(?i32, 200), p.readInt(&.{200}));
    try std.testing.expectEqual(@as(?i32, null), p.readInt(&.{ 1, 2 }));
    try std.testing.expectEqual(@as(?i32, null), p.readInt(&.{}));
    const none: p.IpOpts = .{};
    const opt = struct {
        fn set(cur: p.IpOpts, name: u64, v: i32) kt.ip_opt_policy.SetResult {
            var b: [4]u8 = undefined;
            std.mem.writeInt(i32, &b, v, .little);
            return kt.ip_opt_policy.applySet(cur, kt.ip_opt_policy.SOL_IP, name, &b);
        }
        fn set6(cur: p.IpOpts, name: u64, v: i32) kt.ip_opt_policy.SetResult {
            var b: [4]u8 = undefined;
            std.mem.writeInt(i32, &b, v, .little);
            return kt.ip_opt_policy.applySet(cur, kt.ip_opt_policy.SOL_IPV6, name, &b);
        }
    };
    // IP_TTL: 1..255 sets, -1 restores the default, everything else is EINVAL.
    try std.testing.expectEqual(@as(u8, 17), opt.set(none, p.IP_TTL, 17).ok.ttl);
    try std.testing.expectEqual(@as(u8, 1), opt.set(none, p.IP_TTL, 1).ok.ttl);
    try std.testing.expectEqual(@as(u8, 255), opt.set(none, p.IP_TTL, 255).ok.ttl);
    try std.testing.expectEqual(@as(u8, 0), opt.set(.{ .ttl = 9 }, p.IP_TTL, -1).ok.ttl);
    try std.testing.expectEqual(@as(i64, -22), opt.set(none, p.IP_TTL, 0).err);
    try std.testing.expectEqual(@as(i64, -22), opt.set(none, p.IP_TTL, 256).err);
    try std.testing.expectEqual(@as(i64, -22), opt.set(none, p.IP_TTL, -2).err);
    // IP_TOS: low byte only, ECN bits cleared.
    try std.testing.expectEqual(@as(u8, 0x10), opt.set(none, p.IP_TOS, 0x10).ok.tos);
    try std.testing.expectEqual(@as(u8, 0x10), opt.set(none, p.IP_TOS, 0x13).ok.tos);
    try std.testing.expectEqual(@as(u8, 0xB8), opt.set(none, p.IP_TOS, 0x1B8).ok.tos);
    // IPv6 hop limit and traffic class.
    try std.testing.expectEqual(@as(u8, 9), opt.set6(none, p.IPV6_UNICAST_HOPS, 9).ok.hops);
    try std.testing.expectEqual(@as(i64, -22), opt.set6(none, p.IPV6_UNICAST_HOPS, 256).err);
    try std.testing.expectEqual(@as(i64, -22), opt.set6(none, p.IPV6_UNICAST_HOPS, -2).err);
    try std.testing.expectEqual(@as(u8, 0), opt.set6(.{ .hops = 9 }, p.IPV6_UNICAST_HOPS, -1).ok.hops);
    try std.testing.expectEqual(@as(u8, 0xB8), opt.set6(none, p.IPV6_TCLASS, 0xBB).ok.tclass);
    try std.testing.expectEqual(@as(i64, -22), opt.set6(none, p.IPV6_TCLASS, 256).err);
    // V6ONLY: always on here; asking for dual-stack cannot be honoured.
    try std.testing.expectEqual(@as(i64, -22), opt.set6(none, p.IPV6_V6ONLY, 0).err);
    _ = opt.set6(none, p.IPV6_V6ONLY, 1).ok;
    // Unknown options / levels.
    try std.testing.expectEqual(@as(i64, -92), opt.set(none, 99, 1).err);
    try std.testing.expectEqual(@as(i64, -92), p.applySet(none, 7, p.IP_TTL, &.{ 1, 0, 0, 0 }).err);
    try std.testing.expectEqual(@as(i64, -22), p.applySet(none, p.SOL_IP, p.IP_TTL, &.{ 1, 2 }).err);
    // Readback: defaults when unset.
    try std.testing.expectEqual(@as(?i32, 64), p.getValue(none, p.SOL_IP, p.IP_TTL));
    try std.testing.expectEqual(@as(?i32, 33), p.getValue(.{ .ttl = 33 }, p.SOL_IP, p.IP_TTL));
    try std.testing.expectEqual(@as(?i32, 0x28), p.getValue(.{ .tos = 0x28 }, p.SOL_IP, p.IP_TOS));
    try std.testing.expectEqual(@as(?i32, 64), p.getValue(none, p.SOL_IPV6, p.IPV6_UNICAST_HOPS));
    try std.testing.expectEqual(@as(?i32, 12), p.getValue(.{ .hops = 12 }, p.SOL_IPV6, p.IPV6_UNICAST_HOPS));
    try std.testing.expectEqual(@as(?i32, 0x20), p.getValue(.{ .tclass = 0x20 }, p.SOL_IPV6, p.IPV6_TCLASS));
    try std.testing.expectEqual(@as(?i32, 1), p.getValue(none, p.SOL_IPV6, p.IPV6_V6ONLY));
    try std.testing.expectEqual(@as(?i32, null), p.getValue(none, p.SOL_IP, 99));
    // Nothing set: the header is left exactly as built.
    try std.testing.expect(!p.ipv4NeedsPatch(none) and !p.ipv6NeedsPatch(none));
    try std.testing.expect(p.ipv4NeedsPatch(.{ .ttl = 5 }) and p.ipv4NeedsPatch(.{ .tos = 4 }));
    try std.testing.expect(p.ipv6NeedsPatch(.{ .hops = 5 }) and p.ipv6NeedsPatch(.{ .tclass = 4 }));

    // IPv4 header patch: TTL at byte 8, TOS at byte 1 with the existing ECN bits kept, and the checksum recomputed so
    // that the header sums to zero. An ECT(0) mark (0x02) survives the patch.
    var h4: [20]u8 = undefined;
    v4.buildHeader(&h4, .{ 10, 0, 2, 15 }, .{ 10, 0, 2, 2 }, v4.PROTO_TCP, 100);
    h4[1] = 0x02;
    p.patchIpv4(&h4, .{ .ttl = 5, .tos = 0xB8 }, v4.checksum);
    try std.testing.expectEqual(@as(u8, 5), h4[8]);
    try std.testing.expectEqual(@as(u8, 0xBA), h4[1]);
    try std.testing.expectEqual(@as(u16, 0), v4.checksum(&h4, 20));
    // Only the TTL set: TOS keeps its ECN bits and stays otherwise zero.
    v4.buildHeader(&h4, .{ 10, 0, 2, 15 }, .{ 10, 0, 2, 2 }, v4.PROTO_UDP, 40);
    p.patchIpv4(&h4, .{ .ttl = 200 }, v4.checksum);
    try std.testing.expectEqual(@as(u8, 200), h4[8]);
    try std.testing.expectEqual(@as(u8, 0), h4[1]);
    try std.testing.expectEqual(@as(u16, 0), v4.checksum(&h4, 20));
    // Only the TOS set: the default TTL is written back.
    v4.buildHeader(&h4, .{ 10, 0, 2, 15 }, .{ 10, 0, 2, 2 }, v4.PROTO_UDP, 40);
    p.patchIpv4(&h4, .{ .tos = 0x20 }, v4.checksum);
    try std.testing.expectEqual(@as(u8, 64), h4[8]);
    try std.testing.expectEqual(@as(u8, 0x20), h4[1]);
    try std.testing.expectEqual(@as(u16, 0), v4.checksum(&h4, 20));
    // IPv6 header patch: hop limit at byte 7, traffic class spans bytes 0/1, ECN bits kept, address bytes untouched.
    var h6: [40]u8 = undefined;
    kt.ipv6.buildHeader(&h6, @splat(1), @splat(2), kt.ipv6.PROTO_TCP, 100);
    kt.ipv6.setEct0(&h6);
    p.patchIpv6(&h6, .{ .hops = 9, .tclass = 0xB8 });
    try std.testing.expectEqual(@as(u8, 9), h6[7]);
    const tc: u8 = ((h6[0] & 0x0f) << 4) | (h6[1] >> 4);
    try std.testing.expectEqual(@as(u8, 0xBA), tc);
    try std.testing.expectEqual(@as(u8, 0x60), h6[0] & 0xF0);
    try std.testing.expectEqual(@as(u8, 1), h6[8]);
    try std.testing.expectEqual(@as(u8, 2), h6[39]);
    // Only the hop limit set: the traffic class is left alone.
    kt.ipv6.buildHeader(&h6, @splat(1), @splat(2), kt.ipv6.PROTO_UDP, 40);
    p.patchIpv6(&h6, .{ .hops = 3 });
    try std.testing.expectEqual(@as(u8, 3), h6[7]);
    try std.testing.expectEqual(@as(u8, 0x60), h6[0]);
    try std.testing.expectEqual(@as(u8, 0), h6[1]);
    // Only the class set: the default hop limit is written back.
    kt.ipv6.buildHeader(&h6, @splat(1), @splat(2), kt.ipv6.PROTO_UDP, 40);
    p.patchIpv6(&h6, .{ .tclass = 0x28 });
    try std.testing.expectEqual(@as(u8, 64), h6[7]);
    try std.testing.expectEqual(@as(u8, 0x28), ((h6[0] & 0x0f) << 4) | (h6[1] >> 4));
}

test "IP socket options: dispatch and send-path wiring" {
    const so = kt.socket_opt_source;
    // SOL_IP / SOL_IPV6 are routed before the SOL_SOCKET/SOL_TCP-only guard in both directions.
    try std.testing.expect(std.mem.indexOf(u8, so, "if (level == ipo.SOL_IP or level == ipo.SOL_IPV6) return setIpOpt(ref, resolved_v6, level, optname, optval_ptr, optlen);") != null);
    try std.testing.expect(std.mem.indexOf(u8, so, "if (level == ipo.SOL_IP or level == ipo.SOL_IPV6) return getIpOpt(ref, v6, level, optname, optval_ptr, optlen_ptr);") != null);
    // Only the level that matches the socket's family applies.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, so, "if (!ipo.levelApplies(level, fam)) return -92;"));
    // The SOL_SOCKET round trip for TCP carries the IP options so a REUSEPORT/BROADCAST/DEBUG set does not wipe them.
    try std.testing.expect(std.mem.indexOf(u8, so, "        .ip = o.ip,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, so, "    o.ip = st.ip;\n") != null);
    // The send paths patch the finished header before ECN marking (TCP) / before framing (UDP).
    const ts = kt.tcp_source;
    try std.testing.expect(std.mem.indexOf(u8, ts, "if (ip_opt_policy.ipv4NeedsPatch(tcb.options.ip)) ip_opt_policy.patchIpv4(send_pkt[14..][0..20], tcb.options.ip, ipv4.checksum);\n    // SK-131/143: ECT(1) for AccECN/L4S, else ECT(0) for classic ECN.") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "if (ip_opt_policy.ipv6NeedsPatch(tcb.options.ip)) ip_opt_policy.patchIpv6(send_pkt[14..][0..40], tcb.options.ip);\n    // SK-131/143: ECT(1) for AccECN/L4S, else ECT(0) for classic ECN.") != null);
    const us = kt.udp_source;
    try std.testing.expect(std.mem.indexOf(u8, us, "if (ip_opt_policy.ipv4NeedsPatch(po.ip)) ip_opt_policy.patchIpv4(send_pkt[14..][0..20], po.ip, ipv4.checksum);") != null);
    try std.testing.expect(std.mem.indexOf(u8, us, "if (ip_opt_policy.ipv6NeedsPatch(po.ip)) ip_opt_policy.patchIpv6(send_pkt[14..][0..40], po.ip);") != null);
}

test "SOL_SOCKET priority / mark / device binding / flag rules" {
    const p = kt.sockopt_policy;
    try std.testing.expectEqual(@as(u64, 10), p.SO_OOBINLINE);
    try std.testing.expectEqual(@as(u64, 12), p.SO_PRIORITY);
    try std.testing.expectEqual(@as(u64, 19), p.SO_SNDLOWAT);
    try std.testing.expectEqual(@as(u64, 25), p.SO_BINDTODEVICE);
    try std.testing.expectEqual(@as(u64, 36), p.SO_MARK);
    // OOBINLINE is a plain boolean flag with its own bit; the others live in Stored fields.
    try std.testing.expectEqual(@as(?u16, 64), p.flagBit(p.SO_OOBINLINE));
    try std.testing.expect(p.storedOnly(p.SO_PRIORITY) and p.storedOnly(p.SO_MARK) and p.storedOnly(p.SO_BINDTODEVICE));
    try std.testing.expect(!p.storedOnly(p.SO_OOBINLINE) and !p.storedOnly(p.SO_RCVBUF));
    // SO_PRIORITY: 0..6 for anyone, anything else needs CAP_NET_ADMIN.
    try std.testing.expect(!p.priorityNeedsAdmin(0) and !p.priorityNeedsAdmin(6));
    try std.testing.expect(p.priorityNeedsAdmin(7) and p.priorityNeedsAdmin(-1) and p.priorityNeedsAdmin(std.math.maxInt(i32)) and p.priorityNeedsAdmin(std.math.minInt(i32)));
    var s: p.Stored = .{};
    var v: [4]u8 = undefined;
    std.mem.writeInt(i32, &v, 6, .little);
    try std.testing.expectEqual(@as(i64, 0), p.applySetPriv(&s, p.SO_PRIORITY, &v, false, 1));
    try std.testing.expectEqual(@as(i32, 6), s.priority);
    std.mem.writeInt(i32, &v, 7, .little);
    try std.testing.expectEqual(@as(i64, -1), p.applySetPriv(&s, p.SO_PRIORITY, &v, false, 1));
    try std.testing.expectEqual(@as(i32, 6), s.priority); // a refused set changes nothing
    try std.testing.expectEqual(@as(i64, 0), p.applySetPriv(&s, p.SO_PRIORITY, &v, true, 1));
    try std.testing.expectEqual(@as(i32, 7), s.priority);
    std.mem.writeInt(i32, &v, -3, .little);
    try std.testing.expectEqual(@as(i64, -1), p.applySetPriv(&s, p.SO_PRIORITY, &v, false, 1));
    try std.testing.expectEqual(@as(i64, 0), p.applySetPriv(&s, p.SO_PRIORITY, &v, true, 1));
    try std.testing.expectEqual(@as(i32, -3), s.priority);
    try std.testing.expectEqual(@as(i64, -22), p.applySetPriv(&s, p.SO_PRIORITY, v[0..2], true, 1));
    // SO_MARK: privileged always.
    std.mem.writeInt(u32, &v, 0xABCD, .little);
    try std.testing.expectEqual(@as(i64, -1), p.applySetPriv(&s, p.SO_MARK, &v, false, 1));
    try std.testing.expectEqual(@as(u32, 0), s.mark);
    try std.testing.expectEqual(@as(i64, 0), p.applySetPriv(&s, p.SO_MARK, &v, true, 1));
    try std.testing.expectEqual(@as(u32, 0xABCD), s.mark);
    // Readback.
    var out: [16]u8 = undefined;
    const f: p.Facts = .{ .id = p.identity(.tcp, false) };
    try std.testing.expectEqual(@as(?usize, 4), p.encodeGet(s, f, p.SO_PRIORITY, &out));
    try std.testing.expectEqual(@as(i32, -3), std.mem.readInt(i32, out[0..4], .little));
    try std.testing.expectEqual(@as(?usize, 4), p.encodeGet(s, f, p.SO_MARK, &out));
    try std.testing.expectEqual(@as(u32, 0xABCD), std.mem.readInt(u32, out[0..4], .little));
    try std.testing.expectEqual(@as(?usize, 4), p.encodeGet(s, f, p.SO_SNDLOWAT, &out));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, out[0..4], .little));
    // SO_SNDLOWAT is read-only in effect (Linux refuses to set it); SO_RCVLOWAT is not offered at all.
    try std.testing.expectEqual(@as(i64, -92), p.applySetPriv(&s, p.SO_SNDLOWAT, &v, true, 1));
    try std.testing.expectEqual(@as(?usize, null), p.encodeGet(s, f, 18, &out));
    // SO_BINDTODEVICE names: lo always, eth0 only when a NIC is up; empty unbinds; anything else is ENODEV.
    try std.testing.expectEqual(@as(?u8, 1), p.deviceIndex("lo", 1));
    try std.testing.expectEqual(@as(?u8, 1), p.deviceIndex("lo\x00junk", 1));
    try std.testing.expectEqual(@as(?u8, 0), p.deviceIndex("", 1));
    try std.testing.expectEqual(@as(?u8, 0), p.deviceIndex("\x00", 1));
    try std.testing.expectEqual(@as(?u8, null), p.deviceIndex("eth0", 1));
    try std.testing.expectEqual(@as(?u8, 2), p.deviceIndex("eth0", 2));
    try std.testing.expectEqual(@as(?u8, null), p.deviceIndex("eth", 2));
    try std.testing.expectEqual(@as(?u8, null), p.deviceIndex("lo0", 2));
    try std.testing.expectEqual(@as(?u8, null), p.deviceIndex("nosuch9", 2));
    try std.testing.expectEqualStrings("lo", p.deviceName(1));
    try std.testing.expectEqualStrings("eth0", p.deviceName(2));
    try std.testing.expectEqualStrings("", p.deviceName(0));
    try std.testing.expectEqualStrings("", p.deviceName(9));
    // Bind / read back / unbind through the policy, including the failed-bind-keeps-old-binding rule.
    try std.testing.expectEqual(@as(i64, 0), p.applySetPriv(&s, p.SO_BINDTODEVICE, "lo\x00", false, 1));
    try std.testing.expectEqual(@as(u8, 1), s.bound_if);
    try std.testing.expectEqual(@as(i64, -19), p.applySetPriv(&s, p.SO_BINDTODEVICE, "nosuch9\x00", false, 1));
    try std.testing.expectEqual(@as(u8, 1), s.bound_if);
    try std.testing.expectEqual(@as(?usize, 3), p.encodeGet(s, f, p.SO_BINDTODEVICE, &out));
    try std.testing.expectEqualStrings("lo\x00", out[0..3]);
    try std.testing.expectEqual(@as(i64, 0), p.applySetPriv(&s, p.SO_BINDTODEVICE, "\x00", false, 1));
    try std.testing.expectEqual(@as(?usize, 0), p.encodeGet(s, f, p.SO_BINDTODEVICE, &out));
    // Everything else still goes through the old rules.
    try std.testing.expectEqual(@as(i64, -92), p.applySetPriv(&s, p.SO_TYPE, &v, true, 1));
    try std.testing.expectEqual(@as(i64, 0), p.applySetPriv(&s, p.SO_OOBINLINE, &.{ 1, 0, 0, 0 }, false, 1));
    try std.testing.expect(s.flags & 64 != 0);
}

test "SOL_SOCKET extras: wiring and the hello179 capability profile" {
    const cp = kt.capability_profile;
    const h = cp.profileForLaunch("hello179", true, false);
    try std.testing.expect(h.caps.cap_net_admin and h.caps.cap_setuid);
    try std.testing.expectEqual(@as(u32, 0), h.uid);
    // No other net/privileged cap rides along, and an ordinary program has none of it.
    try std.testing.expect(!h.caps.cap_net_raw and !h.caps.cap_sys_admin);
    try std.testing.expect(!cp.profileForLaunch("hello178", true, false).caps.cap_net_admin);

    const so = kt.socket_opt_source;
    // All four SOL_SOCKET set paths use the privilege-aware entry; none calls the bare one.
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, so, "sp.applySet(&st"));
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, so, "applySol("));
    // AF_UNIX has no devices to bind to.
    try std.testing.expect(std.mem.indexOf(u8, so, "if (!is_inet and optname == sp.SO_BINDTODEVICE) return -92;") != null);
    try std.testing.expect(std.mem.indexOf(u8, so, "return @import(\"../ipc/capability.zig\").hasSysCap(cur_idx, \"cap_net_admin\");") != null);
    // eth0 exists as a device only when the NIC does.
    try std.testing.expect(std.mem.indexOf(u8, so, "return if (@import(\"nic.zig\").isActive()) 2 else 1;") != null);
    // TCP routes the stored-only options through the same round trip as REUSEPORT/BROADCAST/DEBUG, and carries them.
    try std.testing.expect(std.mem.indexOf(u8, so, "sp.storedOnly(optname) or (sp.flagBit(optname) != null") != null);
    try std.testing.expect(std.mem.indexOf(u8, so, "        .priority = o.priority,\n        .mark = o.mark,\n        .bound_if = o.bound_if,\n    };") != null);
    try std.testing.expect(std.mem.indexOf(u8, so, "    o.priority = st.priority;\n    o.mark = st.mark;\n    o.bound_if = st.bound_if;\n}") != null);
}

test "AF_UNIX getsockname / getpeername: address encoding and wiring" {
    const sa = kt.socket_address_policy;
    var out: [2 + 108 + 1]u8 = undefined;
    // The unnamed address is just the family.
    try std.testing.expectEqual(@as(u32, 2), sa.unixNameEncode("", &out));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[0..2], .little));
    // A named address is family + path + NUL, and the length counts the NUL.
    @memset(&out, 0x55);
    try std.testing.expectEqual(@as(u32, 2 + 14 + 1), sa.unixNameEncode("/tmp/h180.sock", &out));
    try std.testing.expectEqualStrings("/tmp/h180.sock", out[2..16]);
    try std.testing.expectEqual(@as(u8, 0), out[16]);
    // The longest path the kernel stores (108 bytes) still fits.
    const long = [_]u8{'a'} ** 108;
    try std.testing.expectEqual(@as(u32, 2 + 108 + 1), sa.unixNameEncode(&long, &out));
    try std.testing.expectEqual(@as(u8, 0), out[110]);

    const us = kt.unix_socket_source;
    // The accepted socket answers getsockname with the listener's address but owns no address.
    try std.testing.expect(std.mem.indexOf(u8, us, "unix_sockets[new_idx].name_only = true;\n    unix_sockets[new_idx].path_len = sock.path_len;") != null);
    try std.testing.expect(std.mem.indexOf(u8, us, "if (sock.bound or sock.name_only) return -22; // EINVAL") != null);
    // connect() remembers the address it resolved, for both stream and datagram sockets.
    try std.testing.expect(std.mem.indexOf(u8, us, "sock.peer_path_len = @intCast(path_len);\n    @memcpy(sock.peer_path[0..path_len], path[0..path_len]);") != null);
    // A queued (not yet accepted) stream client already has the listener's address as its peer.
    try std.testing.expect(std.mem.indexOf(u8, us, "if (s.peer_path_len > 0 and queuedOnBacklogLocked(idx)) {") != null);
    // Streams verify the back-reference; a datagram target must still be bound to the resolved address.
    try std.testing.expect(std.mem.indexOf(u8, us, "if (connectionOriented(s.sock_type) and peer.peer_idx != @as(u8, @intCast(idx))) return .{ .ok = false };") != null);
    try std.testing.expect(std.mem.indexOf(u8, us, "if (!connectionOriented(s.sock_type) and !(peer.bound and peer.path_len == s.peer_path_len and") != null);
    // No live peer is ENOTCONN, not a name.
    try std.testing.expect(std.mem.indexOf(u8, us, "if (!s.connected or s.peer_idx >= MAX_UNIX_SOCKETS) return .{ .ok = false };") == null);
    // A target that has been freed answers nothing.
    try std.testing.expect(std.mem.indexOf(u8, us, "    if (!peer.active) return .{ .ok = false };\n    if (connectionOriented(s.sock_type) and peer.peer_idx") != null);
    try std.testing.expect(std.mem.indexOf(u8, us, "if (s.peer_idx >= MAX_UNIX_SOCKETS) return .{ .ok = false };") != null);

    const ss = kt.socket_syscall_source;
    try std.testing.expect(std.mem.indexOf(u8, ss, "const n = net_mod.unix_socket.unixSockName(desc.unix_sock_idx) orelse return -9;") != null);
    try std.testing.expect(std.mem.indexOf(u8, ss, "const n = net_mod.unix_socket.unixPeerName(desc.unix_sock_idx) orelse return -9;\n        if (!n.ok) return ENOTCONN;") != null);
}

test "AF_UNIX datagram sendto / sendmsg with an address, and EMSGSIZE" {
    const np = kt.namespace_policy;
    // A datagram plus its 2-byte length prefix must fit the ring; otherwise it can never be delivered.
    try std.testing.expect(np.dgramFits(8190, 8192));
    try std.testing.expect(!np.dgramFits(8191, 8192));
    try std.testing.expect(!np.dgramFits(8192, 8192));
    try std.testing.expect(np.dgramFits(0, 8192));

    const us = kt.unix_socket_source;
    // The addressed variant is the one implementation; the plain entry point is a thin wrapper.
    try std.testing.expect(std.mem.indexOf(u8, us, "return unixSendRightsTo(idx, data, len, rights, null);") != null);
    // Only datagram sockets take an address: streams are EISCONN/EOPNOTSUPP, seqpacket ignores it.
    try std.testing.expect(std.mem.indexOf(u8, us, "SOCK_DGRAM => dest_in,\n        SOCK_SEQPACKET => null,\n        else => if (dest_in != null) return if (sock.connected) @as(i64, -106) else @as(i64, -95) else null,") != null);
    // The target is whoever is bound to that path now; no one is ECONNREFUSED, another socket type EPROTOTYPE.
    try std.testing.expect(std.mem.indexOf(u8, us, "peer_i = findBoundLocked(d) orelse return -111; // ECONNREFUSED\n            if (unix_sockets[peer_i].sock_type != sock.sock_type) return -91; // EPROTOTYPE") != null);
    // A datagram larger than the whole ring is EMSGSIZE in both the immediate and the blocking path.
    try std.testing.expect(std.mem.indexOf(u8, us, "if (!np.dgramFits(len, UNIX_SOCK_BUF_SIZE)) return -90; // EMSGSIZE") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, us, "if (!np.dgramFits(len, UNIX_SOCK_BUF_SIZE)) return -90; // EMSGSIZE"));
    // The blocking addressed send retries in short sleeps with the socket's send timeout, and only on EAGAIN.
    try std.testing.expect(std.mem.indexOf(u8, us, "const r = unixSendRightsTo(idx, data, len, null, dest);\n        if (r != -11 or nonblock) return r;") != null);
    try std.testing.expect(std.mem.indexOf(u8, us, "if (urp.timedOut(deadline, tsc.nanos())) return -11;\n        const w = @import(\"../fs/poll.zig\").waitSlice(deadline);") != null);
    try std.testing.expect(std.mem.indexOf(u8, us, "const ms = if (unixOptView(idx)) |v| v.opts.snd_ms else 0;\n            deadline = urp.deadlineNs(tsc.nanos(), ms);\n            armed = true;\n        }\n        if (urp.timedOut(deadline, tsc.nanos())) return -11;") != null);

    const ss = kt.socket_syscall_source;
    // sendto and sendmsg both resolve the destination through the one parser, and the parser checks family and length.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, ss, "unixDestPath(") - 1);
    try std.testing.expect(std.mem.indexOf(u8, ss, "if (bo.readU16Le(out[0..2]) != 1) return .{ .err = -97 }; // EAFNOSUPPORT") != null);
    try std.testing.expect(std.mem.indexOf(u8, ss, "if (n == 0) return .{ .err = -22 };") != null);
    try std.testing.expect(std.mem.indexOf(u8, ss, "unixSendRightsTo(idx, &data, @intCast(got), &rights, dest)") != null);
    try std.testing.expect(std.mem.indexOf(u8, ss, "unixSendToBlocking(unix_idx, &tmp_unix, n_unix, dest_buf[2..][0..dlen]") != null);

    // write() on a message socket is one message, never chunked into several datagrams.
    const fi = kt.file_io_source;
    try std.testing.expect(std.mem.indexOf(u8, fi, "if (isMessageSocket(cur, fdIndex(fd))) {\n                if (n > MESSAGE_WRITE_MAX) return -90; // EMSGSIZE") != null);
    try std.testing.expect(std.mem.indexOf(u8, fi, "return !@import(\"../net/unix_socket.zig\").unixIsStream(d.unix_sock_idx);") != null);
    try std.testing.expect(std.mem.indexOf(u8, fi, "const MESSAGE_WRITE_MAX: usize = 8192;") != null);
}

test "poll/select wake-up protocol: generation snapshot, waiter bitmap, wiring" {
    const w = kt.poll_wake_policy;
    // A notification since the snapshot means: do not sleep, rescan.
    try std.testing.expect(!w.mustSkipSleep(7, 7));
    try std.testing.expect(w.mustSkipSleep(7, 8));
    try std.testing.expect(w.mustSkipSleep(0xFFFF_FFFF, 0));
    // The generation wraps without losing the "changed" property.
    try std.testing.expectEqual(@as(u32, 0), w.nextGeneration(0xFFFF_FFFF));
    try std.testing.expect(w.mustSkipSleep(0xFFFF_FFFF, w.nextGeneration(0xFFFF_FFFF)));
    // One bit per task slot; slot numbers wrap into the 64-bit map.
    try std.testing.expectEqual(@as(u64, 1), w.waiterBit(0));
    try std.testing.expectEqual(@as(u64, 1) << 63, w.waiterBit(63));
    try std.testing.expectEqual(@as(u64, 1), w.waiterBit(64));
    // A notification takes every waiter and leaves none; each re-arms itself.
    const t = w.takeAll(0b1010_0001);
    try std.testing.expectEqual(@as(u64, 0b1010_0001), t.wake);
    try std.testing.expectEqual(@as(u64, 0), t.remaining);
    try std.testing.expectEqual(@as(u64, 0), w.takeAll(0).wake);

    // Wiring: every readiness notification bumps the generation first; a waiter snapshots BEFORE it scans and
    // passes the snapshot to the sleep, in both poll and select.
    try std.testing.expect(std.mem.indexOf(u8, kt.epoll_source, "pub fn epollNotify(fd_type: vfs.FdType, resource_idx: u32, ready_events: u32) void {\n    // poll()/select() waiters wake on every readiness change (they rescan; the sleep slice is the fallback).\n    @import(\"../fs/poll_wake.zig\").notify();") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.poll_source, "    while (true) {\n        const seen = poll_wake.generation();\n        var ready: u64 = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.poll_source, "const rc = waitSliceSeen(seen, deadline);") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.select_source, "const seen = @import(\"poll_wake.zig\").generation();") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.select_source, "const rc = poll_mod.waitSliceSeen(seen, deadline);") != null);
    // The short slice is still the upper bound of one sleep: sources that never notify keep working.
    try std.testing.expect(std.mem.indexOf(u8, kt.poll_source, "return poll_wake.waitUntil(seen, pp.sliceDeadline(now, deadline, WAKE_SLICE_MS));") != null);
    // The sleep publishes itself before blocking and re-checks the generation after.
    const pw = kt.poll_wake_source;
    try std.testing.expect(std.mem.indexOf(u8, pw, "_ = @atomicRmw(u64, &waiter_bm, .Or, bit, .seq_cst);") != null);
    try std.testing.expect(std.mem.indexOf(u8, pw, "if (!pw.mustSkipSleep(seen, generation())) {\n        sched.forceReschedule();\n    }") != null);
    try std.testing.expect(std.mem.indexOf(u8, pw, "sched.repairCurrentAfterBlock();") != null);
    // On the way out the waiter clears its own slot from both the sleep map and the waiter map, and a
    // pending signal is looked at both before sleeping and after waking.
    try std.testing.expect(std.mem.indexOf(u8, pw, "_ = @atomicRmw(u64, &sched.sleep_bm, .And, ~bit, .seq_cst);\n    _ = @atomicRmw(u64, &waiter_bm, .And, ~bit, .seq_cst);") != null);
    try std.testing.expect(std.mem.indexOf(u8, pw, "if (sig_mod.pendingActionable(cur)) return -4;\n    if (tsc.nanos() >= deadline_ns) return 0;") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, pw, "if (sig_mod.pendingActionable(cur)) return -4;"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, pw, "if (sig_mod.pendingFatal(cur)) |s| task_mod.exitTask(128 + @as(i32, @intCast(s)));"));
    try std.testing.expect(std.mem.indexOf(u8, pw, "_ = @atomicRmw(u32, &generation_counter, .Add, 1, .seq_cst);\n    if (@atomicLoad(u64, &waiter_bm, .seq_cst) == 0) return;") != null);
}

test "TCP bind errors and SO_REUSEADDR sharing" {
    const p = kt.tcp_port_policy;
    try std.testing.expectEqual(@as(i64, -98), p.BIND_EADDRINUSE);
    try std.testing.expectEqual(@as(i64, -22), p.BIND_EINVAL);
    try std.testing.expectEqual(@as(i64, -13), p.BIND_EACCES);
    // Ports below 1024 need the capability; 0 (ephemeral) and 1024 do not.
    try std.testing.expect(p.bindNeedsPrivilege(1) and p.bindNeedsPrivilege(80) and p.bindNeedsPrivilege(1023));
    try std.testing.expect(!p.bindNeedsPrivilege(0) and !p.bindNeedsPrivilege(1024) and !p.bindNeedsPrivilege(49152));
    // A held port is shareable only with SO_REUSEADDR on the new socket AND a TIME_WAIT holder.
    try std.testing.expect(p.reuseMayShare(true, true));
    try std.testing.expect(!p.reuseMayShare(false, true));
    try std.testing.expect(!p.reuseMayShare(true, false));
    try std.testing.expect(!p.reuseMayShare(false, false));

    const ts = kt.tcp_source;
    // A socket that already has an address, or is not CLOSED, is EINVAL; a plain conflict is EADDRINUSE.
    try std.testing.expect(std.mem.indexOf(u8, ts, "if (tcb.state != .closed or tcb.bound_explicitly) return tcp_port_policy.BIND_EINVAL;") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "return tcp_port_policy.BIND_EADDRINUSE;") != null);
    // Port 0 (let the kernel choose) never conflicts, and the socket's own slot is skipped.
    try std.testing.expect(std.mem.indexOf(u8, ts, "if (i == tcb_idx) continue;") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "if (tcbs[i].local_port == port and port != 0) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "tcp_port_policy.reuseMayShare(tcb.options.reuse_addr, @intFromEnum(tcbs[i].state) == @intFromEnum(TcpState.time_wait))") != null);
    // Both bind paths (IPv4 and IPv6) refuse a privileged port without the capability with EACCES.
    const ss = kt.socket_syscall_source;
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ss, "if (net_mod.tcp_port_policy.bindNeedsPrivilege(parsed.port) and !cap_mod.hasSysCap(cur_idx, \"cap_net_bind\")) return net_mod.tcp_port_policy.BIND_EACCES;\n        return net_mod.tcp.tcpBind(tcb_idx, parsed.port);"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ss, "if (net_mod.tcp_port_policy.bindNeedsPrivilege(port) and !cap_mod.hasSysCap(cur_idx, \"cap_net_bind\")) return net_mod.tcp_port_policy.BIND_EACCES;\n    return net_mod.tcp.tcpBind(tcb_idx, port);"));
    // UDP (IPv4 and IPv6) refuses a privileged port the same way; no bare -1 is left in any bind path.
    try std.testing.expect(std.mem.indexOf(u8, ss, "if (net_mod.tcp_port_policy.bindNeedsPrivilege(parsed.port) and !cap_mod.hasSysCap(cur_idx, \"cap_net_bind\")) return net_mod.tcp_port_policy.BIND_EACCES;\n            const cur_port = t.fd_table.fds[fd].udp_port;") != null);
    try std.testing.expect(std.mem.indexOf(u8, ss, "if (net_mod.tcp_port_policy.bindNeedsPrivilege(new_port) and !cap_mod.hasSysCap(cur_idx, \"cap_net_bind\")) return net_mod.tcp_port_policy.BIND_EACCES;") != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ss, "!cap_mod.hasSysCap(cur_idx, \"cap_net_bind\")) return -1;"));
    // hello183 runs as uid 0 with only CAP_SETUID so the child's setuid leaves it unprivileged.
    const h = kt.capability_profile.profileForLaunch("hello183", true, false);
    try std.testing.expect(h.caps.cap_setuid and !h.caps.cap_net_bind and !h.caps.cap_net_admin);
    try std.testing.expectEqual(@as(u32, 0), h.uid);
}

test "TCP socket-state errnos: accept, listen, shutdown, getpeername, and the AF_INET family byte order" {
    const rp = kt.tcp_recv_policy;
    const S = rp.TcpState;
    // accept: only a listener.
    try std.testing.expectEqual(@as(i64, 0), rp.acceptErrno(S.listen));
    for ([_]S{ S.closed, S.syn_sent, S.syn_received, S.established, S.fin_wait_1, S.fin_wait_2, S.closing, S.time_wait, S.close_wait, S.last_ack }) |st| {
        try std.testing.expectEqual(@as(i64, -22), rp.acceptErrno(st));
    }
    // listen: a fresh or already-listening socket; anything else EINVAL.
    try std.testing.expectEqual(@as(i64, 0), rp.listenErrno(S.closed));
    try std.testing.expectEqual(@as(i64, 0), rp.listenErrno(S.listen));
    for ([_]S{ S.syn_sent, S.syn_received, S.established, S.fin_wait_1, S.fin_wait_2, S.closing, S.time_wait, S.close_wait, S.last_ack }) |st| {
        try std.testing.expectEqual(@as(i64, -22), rp.listenErrno(st));
    }
    // shutdown: a listener is fine; a never-connected socket is ENOTCONN; a connected (or once-connected) one is fine.
    try std.testing.expectEqual(@as(i64, 0), rp.shutdownErrno(S.listen, false));
    try std.testing.expectEqual(@as(i64, -107), rp.shutdownErrno(S.closed, false));
    try std.testing.expectEqual(@as(i64, 0), rp.shutdownErrno(S.closed, true));
    try std.testing.expectEqual(@as(i64, 0), rp.shutdownErrno(S.established, true));
    try std.testing.expectEqual(@as(i64, 0), rp.shutdownErrno(S.syn_sent, false));
    // getpeername: a peer, or a handshake in progress; a fresh socket and a listener have none.
    try std.testing.expectEqual(@as(i64, -107), rp.peernameErrno(S.closed, false));
    try std.testing.expectEqual(@as(i64, -107), rp.peernameErrno(S.listen, false));
    try std.testing.expectEqual(@as(i64, 0), rp.peernameErrno(S.established, true));
    try std.testing.expectEqual(@as(i64, 0), rp.peernameErrno(S.syn_sent, false));
    try std.testing.expectEqual(@as(i64, 0), rp.peernameErrno(S.time_wait, true));
    // send on a listener / never-connected socket is EPIPE; a peer RST still wins.
    try std.testing.expectEqual(@as(i64, -32), rp.sendErrno(S.listen, false, false, false));
    try std.testing.expectEqual(@as(i64, -104), rp.sendErrno(S.listen, false, true, false));

    // The family field of a sockaddr_in is a little-endian u16: a Linux program stores 02 00.
    const sa = kt.socket_address_policy;
    try std.testing.expect(sa.inet4FamilyValid(std.mem.readInt(u16, &[_]u8{ 2, 0 }, .little)));
    try std.testing.expect(!sa.inet4FamilyValid(std.mem.readInt(u16, &[_]u8{ 0, 2 }, .little)));
    const ss = kt.socket_syscall_source;
    // Every IPv4 address parse that checks the family reads it little-endian (the old reads were big-endian).
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, ss, "inet4FamilyValid(bo.readU16Le(sock_addr[0..2]))"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ss, "readU16BeAt(&sock_addr, 0)"));
    // TCP bind refuses a non-AF_INET address before looking at the port.
    try std.testing.expect(std.mem.indexOf(u8, ss, "inet4FamilyValid(bo.readU16Le(sock_addr[0..2]))) return -97; // EAFNOSUPPORT\n    const port = bo.readU16BeAt(&sock_addr, 2);") != null);
    // getpeername asks the state first.
    try std.testing.expect(std.mem.indexOf(u8, ss, "const peer_rc = net_mod.tcp.tcpPeerErrno(desc.tcb_idx);\n    if (peer_rc != 0) return peer_rc;") != null);
    // The kernel entry points use the policy.
    const ts = kt.tcp_source;
    try std.testing.expect(std.mem.indexOf(u8, ts, "const acc_rc = tcp_recv_policy.acceptErrno(tcb.state);\n    if (acc_rc != 0) return acc_rc;") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "const lis_rc = tcp_recv_policy.listenErrno(tcb.state);\n    if (lis_rc != 0) return lis_rc;") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "const sd_rc = tcp_recv_policy.shutdownErrno(tcb.state, tcb.was_established);\n    if (sd_rc != 0) return sd_rc;") != null);
}

test "descriptor errnos: EBADF for closed/out-of-range fds, ESPIPE for unseekable types, ENOENT for an empty path" {
    // Which descriptor kinds lseek() applies to (by FdType tag).
    const sk = kt.fd_seek_policy;
    for ([_][]const u8{ "pipe_read", "pipe_write", "tcp_socket", "udp_socket", "unix_socket", "raw_socket", "epoll", "eventfd", "timerfd", "inotify", "pidfd", "devfs_ctrl" }) |t| {
        try std.testing.expect(!sk.seekable(t));
    }
    for ([_][]const u8{ "ramdisk_file", "fat32_file", "ext2_file", "tmpfs_file", "proc_file", "devfs", "rofs_file", "special", "none" }) |t| {
        try std.testing.expect(sk.seekable(t));
    }
    // The policy's names are real FdType tags: a renamed variant would otherwise silently become seekable.
    try std.testing.expect(std.mem.indexOf(u8, kt.vfs_source, "    pipe_read = 4,") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.vfs_source, "    pidfd = 18,") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.vfs_source, "    devfs_ctrl = 21,") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.vfs_source, "return @import(\"fd_seek_policy.zig\").seekable(@tagName(t));") != null);

    const v = kt.vfs_source;
    // read(): an out-of-range or unused descriptor is EBADF in all three places that used to say -1.
    try std.testing.expect(std.mem.indexOf(u8, v, "pub fn read(self: *FdTable, fd: u32, buf: [*]u8, count: usize) i64 {\n        if (fd >= MAX_FDS) return -9; // EBADF") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "fn readInner(self: *FdTable, fd: u32, buf: [*]u8, count: usize) i64 {\n        if (fd >= MAX_FDS) return -9; // EBADF") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "            .none => return -9, // EBADF\n            .special => {\n                // stdin (fd 0): read from keyboard buffer") != null);
    // close(): a descriptor that is not open is EBADF; one already closing stays a quiet success.
    try std.testing.expect(std.mem.indexOf(u8, v, "return if (slotLifecycle(state) == SLOT_CLOSING) 0 else -9; // EBADF: not an open descriptor") != null);

    // open(""): ENOENT, before the cwd-relative resolution can turn it into the current directory.
    const f = kt.file_io_source;
    try std.testing.expect(std.mem.indexOf(u8, f, "    if (name.len == 0) return -2;\n\n    const cur_idx = sched_mod.currentTaskIndex() orelse return -1;") != null);

    // lseek on an unseekable descriptor is ESPIPE, decided before the offset is touched.
    const s = kt.syscall_entry_source;
    try std.testing.expect(std.mem.indexOf(u8, s, "    if (!vfs_mod.fdTypeSeekable(desc.fd_type)) return -29;\n    vfs_mod.syncOffsetIn(desc);") != null);
}

test "the program break belongs to the address space: CLONE_VM threads share it, every other path sets it on the new Mm" {
    // The break used to live in Task, so a CLONE_VM thread got a copy of brk_current but no brk_start (brk refused to
    // move at all) and, even with both copied, each thread would have kept its own stale break. Threads that grow the
    // malloc heap failed with ENOMEM as soon as they ran concurrently. The state is in Mm now (vm_lock protects it).
    var m: kt.mm.Mm = undefined;
    m.brk_start = 0;
    m.brk_current = 0;
    try std.testing.expectEqual(@as(u64, 0), m.brk_current + m.brk_start);
    try std.testing.expect(std.mem.indexOf(u8, kt.task_source, "brk_current: u64") == null);
    try std.testing.expect(std.mem.indexOf(u8, kt.task_source, "brk_start: u64") == null);
    // brk reads and writes only through the Mm.
    try std.testing.expect(std.mem.indexOf(u8, kt.brk_source, "cur.brk_current") == null);
    try std.testing.expect(std.mem.indexOf(u8, kt.brk_source, "cur.brk_start") == null);
    try std.testing.expect(std.mem.indexOf(u8, kt.brk_source, "mm.brk_current = addr;") != null);
    // The stack-growth check in the page-fault handler consults the shared break too.
    try std.testing.expect(std.mem.indexOf(u8, kt.idt_source, "current.brk_current") == null);
    // fork and a clone without CLONE_VM copy the break into the child's new Mm; a CLONE_VM clone shares the Mm and copies nothing.
    try std.testing.expect(std.mem.indexOf(u8, kt.fork_source, "inheritBreak(") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.clone_source, "child.brk_current") == null);
    try std.testing.expect(std.mem.indexOf(u8, kt.clone_source, "child_mm.inheritBreak(parent_mm);") != null);
    // The loader and exec set it on the Mm they create.
    try std.testing.expect(std.mem.indexOf(u8, kt.loader_source, "t.brk_current") == null);
    try std.testing.expect(std.mem.indexOf(u8, kt.execve_source, "cur.brk_current") == null);
    try std.testing.expect(std.mem.indexOf(u8, kt.execve_source, "new_mm.setBreak(result.brk);") != null);
    try std.testing.expect(@sizeOf(kt.mm.Mm) <= 1024);
}

test "the mapping table belongs to the address space: CLONE_VM threads share one table, teardown happens when the Mm dies" {
    // The table of mappings (mmap_regions) was in Task and clone copied it, so a mapping made by one thread was missing
    // from every other thread's table: madvise/mremap said ENOMEM/EINVAL for it, a re-map after another thread's munmap
    // collided with a stale entry. It is in Mm now (vm_lock protects it).
    try std.testing.expect(std.mem.indexOf(u8, kt.task_source, "mmap_regions") == null);
    try std.testing.expect(std.mem.indexOf(u8, kt.task_source, "mmap_active_bm") == null);
    try std.testing.expect(std.mem.indexOf(u8, kt.mm_source, "vma_tab: @import(\"vma_table.zig\").VmaTable,") != null);
    // Nobody reaches for the old Task fields.
    for ([_][]const u8{ kt.mmap_source, kt.mprotect_source, kt.clone_source, kt.fork_source, kt.idt_source, kt.syscall_entry_source }) |src| {
        try std.testing.expect(std.mem.indexOf(u8, src, "mmap_regions") == null);
        try std.testing.expect(std.mem.indexOf(u8, src, "mmap_active_bm") == null);
    }
    // fork and a clone without CLONE_VM copy the table into the child's new Mm, taken under the parent's vm_lock
    // together with the page-table clone; a CLONE_VM clone shares the Mm and copies nothing.
    try std.testing.expect(std.mem.indexOf(u8, kt.fork_source, "vma_table.zig\").snapshot(parent.vma(), &vma_snap);") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.clone_source, "vma_table.zig\").snapshot(parent.vma(), &vma_snap);") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.clone_source, "child.vma().regions") == null);
    try std.testing.expect(std.mem.indexOf(u8, kt.clone_source, "child_mm.inheritBreak(parent_mm);") != null);
    // File references are released once, when the last user of the Mm drops it, not by each thread or by exec.
    try std.testing.expect(std.mem.indexOf(u8, kt.task_source, "releaseFileRefs(") == null);
    try std.testing.expect(std.mem.indexOf(u8, kt.execve_source, "releaseFileRefs(") == null);
    try std.testing.expect(std.mem.indexOf(u8, kt.user_space_source, "releaseFileRefs(&mm.vma_tab)") != null);
    // A thread's death must not unmap device mappings the group still uses: that happens in the Mm finalizer.
    try std.testing.expect(std.mem.indexOf(u8, kt.user_space_source, "no_free") != null);
    try std.testing.expect(@sizeOf(kt.mm.Mm) <= 1024);
}

test "signal dispositions belong to the address space: CLONE_VM threads share one table" {
    // handlers, sa_mask and sa_flags were per-Task arrays that clone copied, so a handler installed by one thread was
    // invisible to the others (and a signal sent to the process ran whichever handler the receiving thread happened to
    // have). They live in Mm now, next to the mapping table.
    try std.testing.expect(std.mem.indexOf(u8, kt.task_source, "signal_handlers: [64]u64") == null);
    try std.testing.expect(std.mem.indexOf(u8, kt.task_source, "signal_sa_masks: [64]u64") == null);
    try std.testing.expect(std.mem.indexOf(u8, kt.task_source, "signal_sa_flags: [64]u64") == null);
    try std.testing.expect(std.mem.indexOf(u8, kt.mm_source, "grp: *@import(\"group_state.zig\").GroupState,") != null);
    for ([_][]const u8{ kt.clone_source, kt.fork_source, kt.idt_source, kt.syscall_entry_source, kt.execve_source }) |src| {
        try std.testing.expect(std.mem.indexOf(u8, src, ".signal_handlers") == null);
        try std.testing.expect(std.mem.indexOf(u8, src, ".signal_sa_masks") == null);
        try std.testing.expect(std.mem.indexOf(u8, src, ".signal_sa_flags") == null);
    }
    // A CLONE_VM clone shares the Mm and copies no dispositions; a copied address space gets a copy.
    try std.testing.expect(std.mem.indexOf(u8, kt.clone_source, "child.sigact().handlers[i] = parent.sigact().handlers[i]") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.clone_source, "if (!shares_vm) {\n        for (0..64) |i| {") != null);
    try std.testing.expect(@sizeOf(kt.mm.Mm) <= 1024);
}

test "RLIMIT_AS and RLIMIT_DATA accounting belongs to the address space: CLONE_VM threads charge one counter" {
    // as_used/data_used were per-Task counters that clone copied, so each thread of a process had its own idea of how much
    // address space was in use and the limit could be exceeded by the number of threads. They are in Mm now, like
    // Linux's mm->total_vm / data_vm.
    try std.testing.expect(std.mem.indexOf(u8, kt.task_source, "as_used: u64") == null);
    try std.testing.expect(std.mem.indexOf(u8, kt.task_source, "data_used: u64") == null);
    try std.testing.expect(std.mem.indexOf(u8, kt.mm_source, "as_used: u64 = 0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.mm_source, "data_used: u64 = 0,") != null);
    for ([_][]const u8{ kt.mmap_source, kt.brk_source, kt.idt_source, kt.clone_source, kt.fork_source, kt.execve_source }) |src| {
        try std.testing.expect(std.mem.indexOf(u8, src, ".as_used") == null);
        try std.testing.expect(std.mem.indexOf(u8, src, ".data_used") == null);
    }
    // fork and a copied-address-space clone start the child's new Mm at the parent's charge; a CLONE_VM clone shares it.
    try std.testing.expect(std.mem.indexOf(u8, kt.clone_source, "child_mm.inheritCharges(parent_mm);") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.fork_source, "child_mm.inheritCharges(parent_mm);") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.mm_source, "mm.as_used = parent.as_used;") != null);
    // exec: the new image's Mm is already at 0, nothing is reset by hand.
    try std.testing.expect(std.mem.indexOf(u8, kt.execve_source, "asUsed()") == null);
    try std.testing.expect(@sizeOf(kt.mm.Mm) <= 1024);
}

test "resource limits belong to the thread group: one Limits record in the Mm, shared by CLONE_VM threads, inherited by fork and kept by exec" {
    // Every limit was a per-Task field that clone copied, so setrlimit in one thread was invisible to every other
    // thread, including the ones that already existed. They live in the thread-group state page of the Mm now.
    for ([_][]const u8{ "nofile_cur", "nofile_max", "stack_cur", "stack_max", "as_cur", "as_max", "data_cur", "data_max", "nproc_cur", "nproc_max", "fSize_cur", "fSize_max", "recorded_limits" }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, kt.task_source, name) == null);
        for ([_][]const u8{ kt.mmap_source, kt.brk_source, kt.idt_source, kt.clone_source, kt.fork_source, kt.execve_source, kt.syscall_entry_source }) |src| {
            try std.testing.expect(std.mem.indexOf(u8, src, name) == null);
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, kt.mm_source, "grp: *@import(\"group_state.zig\").GroupState,") != null);
    // fork and a copied-address-space clone copy the limits; a CLONE_VM clone shares them; exec carries them over.
    try std.testing.expect(std.mem.indexOf(u8, kt.fork_source, "child_mm.inheritLimits(parent_mm);") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.clone_source, "child_mm.inheritLimits(parent_mm);") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.execve_source, "new_mm.inheritLimits(om)") != null);
    try std.testing.expect(@sizeOf(kt.mm.Mm) <= 1024);
}

test "a new thread-group state starts with the default limits: unlimited, except NOFILE and STACK" {
    const gs = kt.group_state;
    const st = gs.GroupState.initial(64);
    try std.testing.expectEqual(@as(u64, 64), st.lim.nofile.cur);
    try std.testing.expectEqual(@as(u64, 64), st.lim.nofile.max);
    try std.testing.expectEqual(@as(u64, 8 * 1024 * 1024), st.lim.stack.cur);
    try std.testing.expectEqual(@as(u64, 8 * 1024 * 1024), st.lim.stack.max);
    for ([_]gs.Limit{ st.lim.as, st.lim.data, st.lim.nproc, st.lim.fsize }) |l| {
        try std.testing.expectEqual(gs.RLIM_INFINITY, l.cur);
        try std.testing.expectEqual(gs.RLIM_INFINITY, l.max);
    }
    for (st.lim.recorded.v) |l| try std.testing.expectEqual(gs.RLIM_INFINITY, l.cur);
    for (st.sig.handlers) |h| try std.testing.expectEqual(@as(u64, 0), h);
}

test "the file-system context belongs to the thread group: cwd and umask live in the shared group state" {
    // cwd, cwd_len and umask_val were per-Task fields that clone copied, so chdir()/umask() in one thread was invisible to
    // every other thread of the process (Linux: CLONE_FS, which every pthread has).
    for ([_][]const u8{ "cwd: [256]u8", "cwd_len: u32", "umask_val: u32" }) |decl| {
        try std.testing.expect(std.mem.indexOf(u8, kt.task_source, decl) == null);
    }
    const srcs = [_][]const u8{ kt.clone_source, kt.fork_source, kt.syscall_entry_source, kt.execve_source };
    for (srcs) |src| {
        // Every use goes through fsctx(); a bare task.cwd / task.cwd_len / task.umask_val is the old per-thread field.
        for ([_][]const u8{ "cur", "child", "parent", "t1", "t2", "task", "current" }) |who| {
            var buf: [32]u8 = undefined;
            const cwd = try std.fmt.bufPrint(&buf, "{s}.cwd", .{who});
            try std.testing.expect(std.mem.indexOf(u8, src, cwd) == null);
            const um = try std.fmt.bufPrint(&buf, "{s}.umask_val", .{who});
            try std.testing.expect(std.mem.indexOf(u8, src, um) == null);
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, kt.group_state_source, "fs: FsContext") != null);
    // fork and a copied-address-space clone copy it; a CLONE_VM clone shares it.
    try std.testing.expect(std.mem.indexOf(u8, kt.fork_source, "child_mm.inheritFs(parent_mm);") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.clone_source, "child_mm.inheritFs(parent_mm);") != null);
    try std.testing.expect(std.mem.indexOf(u8, kt.execve_source, "new_mm.inheritFs(om)") != null);
}

test "the current directory is copied and replaced under the group state's lock" {
    // chdir rewrote a 256-byte array in several steps while getcwd and every relative path lookup read it, so a reader could see
    // half of the old path and half of the new one (hello222 caught it on the target). Reads go through snapshot(), writes
    // through set(), and both hold the lock for the copy only.
    const gs = kt.group_state;
    var st = gs.GroupState.initial(64);
    const snap0 = st.fs.snapshot();
    try std.testing.expectEqualStrings("/", snap0.slice());
    try std.testing.expect(st.fs.set("/tmp/some/dir"));
    const snap1 = st.fs.snapshot();
    try std.testing.expectEqualStrings("/tmp/some/dir", snap1.slice());
    try std.testing.expectEqual(@as(u8, 0), st.fs.cwd[13]); // still NUL-terminated
    try std.testing.expectEqual(@as(u32, 13), st.fs.cwd_len);
    // a snapshot is private: a later set() does not change it
    try std.testing.expect(st.fs.set("/x"));
    try std.testing.expectEqualStrings("/tmp/some/dir", snap1.slice());
    try std.testing.expectEqualStrings("/x", st.fs.snapshot().slice());
    // the longest path that fits, and the limits
    var long: [255]u8 = undefined;
    @memset(&long, 'y');
    long[0] = '/';
    try std.testing.expect(st.fs.set(&long));
    try std.testing.expectEqual(@as(usize, 255), st.fs.snapshot().len);
    try std.testing.expectEqual(@as(u8, 0), st.fs.cwd[255]);
    var too_long: [256]u8 = undefined;
    @memset(&too_long, 'y');
    try std.testing.expect(!st.fs.set(&too_long));
    try std.testing.expect(!st.fs.set(""));
    try std.testing.expectEqual(@as(usize, 255), st.fs.snapshot().len); // a refused set changed nothing
    // Real threads: one keeps replacing the directory with one of two equally long paths that differ in every byte, the others
    // copy it. Every copy must be one of the two paths whole.
    const Race = struct {
        fn flip(state: *gs.GroupState, stop: *std.atomic.Value(bool)) void {
            var a: [200]u8 = undefined;
            var b: [200]u8 = undefined;
            @memset(&a, 'a');
            @memset(&b, 'b');
            a[0] = '/';
            b[0] = '/';
            var n: usize = 0;
            while (n < 400000) : (n += 1) _ = state.fs.set(if (n & 1 == 0) &a else &b);
            stop.store(true, .release);
        }
        fn read(state: *gs.GroupState, stop: *std.atomic.Value(bool), torn: *std.atomic.Value(u32), reads: *std.atomic.Value(u32)) void {
            while (!stop.load(.acquire)) {
                const snap = state.fs.snapshot();
                _ = reads.fetchAdd(1, .monotonic);
                const p = snap.slice();
                if (p.len == 1) continue; // the initial "/", before the first set
                var ok = p.len == 200 and p[0] == '/';
                if (ok) {
                    const c = p[1];
                    ok = (c == 'a' or c == 'b');
                    for (p[1..]) |x| ok = ok and x == c;
                }
                if (!ok) _ = torn.fetchAdd(1, .monotonic);
            }
        }
    };
    var race_state = gs.GroupState.initial(64);
    var stop = std.atomic.Value(bool).init(false);
    var torn = std.atomic.Value(u32).init(0);
    var reads = std.atomic.Value(u32).init(0);
    const t0 = try std.Thread.spawn(.{}, Race.flip, .{ &race_state, &stop });
    const t1 = try std.Thread.spawn(.{}, Race.read, .{ &race_state, &stop, &torn, &reads });
    const t2 = try std.Thread.spawn(.{}, Race.read, .{ &race_state, &stop, &torn, &reads });
    t0.join();
    t1.join();
    t2.join();
    try std.testing.expectEqual(@as(u32, 0), torn.load(.monotonic));
    try std.testing.expect(reads.load(.monotonic) > 1000);
    // no caller reads the array directly any more
    for ([_][]const u8{ kt.syscall_entry_source }) |src| {
        try std.testing.expect(std.mem.indexOf(u8, src, "fsctx().cwd[0..") == null);
    }
}

test "a new group state starts at / with umask 022" {
    const gs = kt.group_state;
    const st = gs.GroupState.initial(64);
    try std.testing.expectEqual(@as(u32, 1), st.fs.cwd_len);
    try std.testing.expectEqual(@as(u8, '/'), st.fs.cwd[0]);
    try std.testing.expectEqual(@as(u32, 0o022), st.fs.umask);
    // One default, two spellings: the policy module's and the group state's must agree.
    try std.testing.expectEqual(kt.creation_metadata.DEFAULT_UMASK, gs.DEFAULT_UMASK);
}
