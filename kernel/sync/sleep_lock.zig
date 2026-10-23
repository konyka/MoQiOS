//! A sleeping mutual-exclusion lock with FIFO ownership handoff.
//!
//! An IRQ-disabling spinlock must never be held across anything that can park
//! the task (a device read that waits for a completion interrupt, an
//! allocation that blocks): the holder is switched out still owning the lock,
//! and the next task to want it spins with interrupts off, so neither the
//! holder's completion interrupt nor a scheduler tick can ever run on that CPU.
//! This lock puts waiters to sleep instead.
//!
//! The lock is generic over the scheduler so the algorithm is host-tested with
//! real threads against a model scheduler (tests/sleep_lock_test.zig); the
//! kernel instantiation lives in sync/task_sleep_lock.zig.
//!
//! Env must provide:
//!   Guard       short IRQ-safe spinlock: acquire() u64, release(u64)
//!   Node        struct with `granted: bool` and `next: ?*Node`
//!   newNode()   a fresh Node
//!   currentTask() ?u32    null before the scheduler exists
//!   enqueue(*?*Node, *Node) bool   link the node and mark the current task
//!                                  blocked (must be oldest-last, see below)
//!   wakeOne(*?*Node) ?u32          pop the OLDEST waiter, set its `granted`,
//!                                  make it runnable
//!   sleepAfterBlock()              give up the CPU until woken
//!   relax()
//!
//! Ownership is handed straight to the oldest waiter on unlock (`held` stays
//! true), so a woken waiter cannot lose the lock to a task that arrives in
//! between, and waiters are served in arrival order.

pub fn SleepLock(comptime Env: type) type {
    return struct {
        const Self = @This();

        guard: Env.Guard = .{},
        held: bool = false,
        waiters: ?*Env.Node = null,

        pub fn lock(self: *Self) void {
            if (Env.currentTask() == null) {
                // Before the scheduler exists nothing can sleep; there is also
                // nothing to contend with, so a plain spin is enough.
                while (true) {
                    const f = self.guard.acquire();
                    if (!self.held) {
                        self.held = true;
                        self.guard.release(f);
                        return;
                    }
                    self.guard.release(f);
                    Env.relax();
                }
            }

            var node: Env.Node = Env.newNode();
            var linked = false;
            while (true) {
                const f = self.guard.acquire();
                if (linked) {
                    if (node.granted) {
                        // unlock() handed us the lock and already unlinked us.
                        self.guard.release(f);
                        return;
                    }
                    // Woken without a grant (a signal kick): take the node off
                    // the queue before anything can write through it.
                    self.unlinkLocked(&node);
                    linked = false;
                }
                if (!self.held) {
                    self.held = true;
                    self.guard.release(f);
                    return;
                }
                node.granted = false;
                node.next = null;
                if (!Env.enqueue(&self.waiters, &node)) {
                    self.guard.release(f);
                    Env.relax();
                    continue;
                }
                linked = true;
                self.guard.release(f);
                Env.sleepAfterBlock();
            }
        }

        pub fn unlock(self: *Self) void {
            const f = self.guard.acquire();
            defer self.guard.release(f);
            // A waiter inherits ownership: `held` stays true across the handoff.
            if (Env.wakeOne(&self.waiters) == null) self.held = false;
        }

        /// Take the lock only if it is free right now.
        pub fn tryLock(self: *Self) bool {
            const f = self.guard.acquire();
            defer self.guard.release(f);
            if (self.held) return false;
            self.held = true;
            return true;
        }

        fn unlinkLocked(self: *Self, node: *Env.Node) void {
            var prev: ?*Env.Node = null;
            var cur = self.waiters;
            while (cur) |n| {
                if (n == node) {
                    if (prev) |p| p.next = n.next else self.waiters = n.next;
                    n.next = null;
                    return;
                }
                prev = n;
                cur = n.next;
            }
            node.next = null;
        }
    };
}
