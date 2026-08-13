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
`RLIMIT_NOFILE`. All other `RLIMIT_*` resource types retain their existing
reported/stub behavior and are not enforced in this milestone.

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
