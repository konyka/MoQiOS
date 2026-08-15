# Resource limits

This milestone implements per-task `RLIMIT_NOFILE` soft and hard limits. The
soft limit is enforced by the common file-descriptor allocation and explicit
target reservation APIs as an exclusive upper bound on the descriptor number:
an FD is allowed only when `fd < rlim_cur`. This applies to `dup`, `dup2`,
`dup3`, `F_DUPFD`, and `F_DUPFD_CLOEXEC`; it is not an open-descriptor count.
Descriptors 0, 1, and 2 remain present but are never newly allocated, and
lowering a limit never closes existing descriptors. Limits are inherited by
fork/clone and preserved by exec.

When no descriptor number below the soft limit is available, table-backed
creators return `EMFILE`. `F_DUPFD` and `F_DUPFD_CLOEXEC` reject a minimum
descriptor at or above the limit with `EINVAL`; `dup2` rejects an out-of-range
target with `EBADF` and allows a valid `oldfd == newfd` no-op. `dup3` rejects
 an out-of-range target with `EBADF` and rejects `oldfd == newfd` with `EINVAL`.
It also rejects any flags other than `O_CLOEXEC` (`0x80000`) with `EINVAL`
before attempting duplication. Successful `dup3(..., O_CLOEXEC)` calls mark the
new descriptor `FD_CLOEXEC` throughout the VFS descriptor table.

`getrlimit`, `setrlimit`, and `prlimit64` provide real per-task operations for
`RLIMIT_NOFILE`, `RLIMIT_STACK`, `RLIMIT_AS`, `RLIMIT_NPROC`, and
`RLIMIT_DATA`. All other `RLIMIT_*` resource types retain their existing
reported/stub behavior and are not enforced.

## RLIMIT_NPROC execution semantics

`RLIMIT_NPROC` carries per-task soft/hard process-count limits over the number
of live tasks sharing the caller's real UID (default
`RLIM_INFINITY` / `RLIM_INFINITY`, matching the former stub report, so an
untouched task sees no behaviour change). The kernel keeps a per-UID live-task
counter (`uid_task_count`) next to the global `task_count`; both are maintained
under `task_lock`, incremented at every task-creation site and decremented at
every reap site (`cancelUnstartedKernelThread`, `reapZombies`, and the waitpid
scan). A zombie still counts until it is reaped, matching Linux semantics —
the limit gates *task creation*, so a reaped slot frees one unit immediately.

The gate lives at every task-creation chokepoint *before* expensive page-table
work: `fork()` checks before `cloneUserPagesCow`, `clone()` before COW cloning
or address-space retention, and `spawn()` before the loader touches any user
memory. When the live count for the real UID reaches the soft limit, creation
is refused with `EAGAIN` (matching Linux). The count applies to every task the
real UID creates, so threads (CLONE_VM) count too, exactly like Linux
`RLIMIT_NPROC`. Lowering the limit below the current live count is legal and
only blocks further creation — no task is killed. Limits are inherited across
fork/clone and preserved by exec; validation and privilege rules are the same
byte-denominated `applyBytes` set as `RLIMIT_STACK`/`RLIMIT_AS`.

The per-UID counter is a bounded table keyed by UID (the kernel issues a small
UID set today). A UID that exhausts the table fails closed: finite limits
refuse creation for it rather than silently granting unlimited budget.
`RLIM_INFINITY` bypasses the count entirely.

## RLIMIT_DATA execution semantics

`RLIMIT_DATA` carries per-task soft/hard byte limits over the charged data
segment (default `RLIM_INFINITY` / `RLIM_INFINITY`, matching the former stub
report, so an untouched task sees no behaviour change). The kernel keeps an
independent per-task `data_used` byte counter alongside `as_used`; the two
ledgers never interact, so a writable private mapping may consume both limits.

Charged: `brk` heap growth and every writable private mapping (anonymous
private, or a writable `MAP_PRIVATE` file mapping). Not charged: read-only
private mappings, `MAP_SHARED` mappings, and the exec'd image's code/rodata
segments — matching Linux, which accounts private-writable VMAs plus the data
segment in `mm->data_vm`.

Charges happen at mapping/creation time (a snapshot of the region's protection
at mmap), and are refunded on `munmap`, `mremap` shrink, `MAP_FIXED`
replacement, `brk` shrink, and exec (which resets `data_used` for the fresh
image while preserving `data_cur`/`data_max`). Every growth path checks the
data soft limit *before* any page-table mutation: mmap, the anonymous and
file-backed `mremap` grow paths, and `moveMapping` all preflight `dataChargeOk`
and refuse with `ENOMEM` on overflow. A mapping/charge never partially applies
— a refused grow leaves both `as_used` and `data_used` untouched and no page is
demoted or copied. Because `data_used` is snapshotted at mmap time, `mprotect`
changing writability does not rebalance the ledger — the same snapshot model
RLIMIT_AS already uses, and the reason merge only combines regions with
matching `prot`/`shared`.

Validation and privilege rules are the same byte-denominated `applyBytes` set
as `RLIMIT_STACK`/`RLIMIT_AS`; lowering below the current usage is legal and
only blocks further charges. Limits and usage are inherited across fork/clone
and preserved by exec (usage reset). moqi_libc wrappers and the ABI constants
are covered by the `test_rlimit_abi` host test.

## RLIMIT_STACK execution semantics

`RLIMIT_STACK` carries per-task soft/hard byte limits (default 8 MiB / 8 MiB,
matching the values the stub previously reported). The soft limit is enforced
at the demand-growth page-fault path: the growth floor is

    floor = USER_STACK_TOP - min(rlim_cur, USER_STACK_TOP - USER_STACK_BOTTOM)

so a fault whose growth would reach below `floor` is refused and delivered as
`SIGSEGV`, exactly like any other unhandled stack fault. `RLIM_INFINITY` as
the soft limit caps growth only at the architecture region bottom.
Already-mapped stack pages are never unmapped by lowering the limit; lowering
only raises the growth watermark (`stack_limit`) so no further page below the
new floor can be claimed. `exec` preserves both limit values (like
`RLIMIT_NOFILE`) but resets the watermark to
`max(stack_top - 256 KiB, floor)` for the fresh image, so a deep watermark
inherited from the previous image cannot bypass the floor.

`setrlimit`/`prlimit64` validation mirrors the NOFILE policy: `cur > max` is
`EINVAL`; raising the hard limit — or the soft limit above the current hard
limit — without `cap_sys_resource` is `EPERM`. Limits are inherited across
fork/clone. `CLONE_VM` thread stacks are mmap-backed and outside the
auto-grow region, so the limit constrains only the main stack, as on Linux.

## RLIMIT_AS execution semantics

`RLIMIT_AS` carries per-task soft/hard byte limits over the total charged
address space (default `RLIM_INFINITY` / `RLIM_INFINITY`, matching the former
stub report, so an untouched task sees no behaviour change). The kernel keeps
a per-task `as_used` byte counter; a charge that would push it past the soft
limit is refused per interface: `mmap`/anonymous `mremap` growth fail with
`ENOMEM`, `brk` reports the unchanged break, and stack demand-growth is
refused exactly like crossing the stack floor — `SIGSEGV`.

Charged: `brk` heap pages, every mmap-tracked region (anonymous, file-backed,
and eager device regions such as fb0/MMIO), and each demand-faulted main-stack
page. Not charged: the exec'd image's code/data demand pages, kernel
structures, and page tables. `munmap`/`mremap` shrink/`brk` shrink refund;
`MAP_FIXED` replacement refunds the old range before charging the new one, so
a same-size replace never trips the limit. Fork copies the limits and the
current usage (the child's space mirrors the parent's); exec preserves the
limits and resets usage to zero — the fresh image starts uncharged like a
newly created task. Validation is the same byte-denominated rule set as
`RLIMIT_STACK` (`applyBytes`: `cur > max` → `EINVAL`, raising hard/soft above
the current hard without `cap_sys_resource` → `EPERM`); lowering below the
current usage is legal and only blocks further charges, matching Linux.

Linux-personality x86_64 tasks may call `setrlimit` at syscall 160 and
`prlimit64` at syscall 302. Native syscall 160 remains `dup`, and native
syscall 302 remains `moqipc_reply`. The Linux aliases use the current task's
`.linux` personality only. `signalfd4` releases its eventfd backing if later
task lookup or descriptor allocation fails, and `prlimit64` re-resolves its
target after user-memory copies before changing limits.

moqi_libc exposes the wrappers in `lib/moqi_libc/include/resource.h`
(`getrlimit`, `setrlimit`, `prlimit64` over native syscalls 236/237/238,
16-byte `struct rlimit`); the ABI is pinned by the
`test_rlimit_abi` host test.
