# MoQiOS Current Code Review And Fix Plan

> Review date: 2026-06-21
> Last update: 2026-08 (7-area full-repository audit round recorded in §6: memory-safety / concurrency / performance / userland fixes, SMP #GP root cause in TLB shootdown, all builds and SMP=1/SMP=4 smokes passed; prior: 2026-07-28 full-repository audit — copy_file_range fd/rollback, socket option user-copy/SO_ERROR/sockaddr lengths, futex EFAULT/waitv limit, SysV IPC_SET/rt_sigsuspend copies, virtio-net/e1000 rollback/timeouts, hello38-41 regression gates)
> Scope: current worktree code, architecture wiring, documentation consistency, and verification gates.
> Evidence base: `git status`, `rg --files`, `kernel/main.zig`, `build.zig`, scheduler/SMP/syscall/VFS/network sources, and existing docs.

## 1. Current Architecture From Code

MoQiOS is currently a Zig-based monolithic kernel with an x86_64 production path and a riscv64 build skeleton.
The authoritative x86_64 boot path starts at `kernel/main.zig` and initializes the following sequence:

1. Limine protocol checks, serial logging, HHDM, GDT and IDT.
2. Early BSP `GS_BASE` setup for per-CPU interrupt context (`syscall_entry.setPerCpuGsBase(0)`).
3. Keyboard, TSC, symbol table, PMM, paging, address-space manager, ACPI, slab and DMA.
4. Framebuffer, PCI, AHCI, virtio-blk, NVMe, block device registry, page cache.
5. FAT32, e1000, virtio-net, network stack, ext2, VFS writeback callbacks, tmpfs, random.
6. LAPIC, SMP AP startup, IPC/capability system, syscall MSRs and dispatch entry.
7. Limine ramdisk, kernel idle task, `init` user process, then `sti` and scheduler activation.

The riscv64 path is selected by `zig build -Darch=riscv64` and builds `kernel/riscv64_root.zig`
(`build.zig:75`); the aarch64 path similarly builds `kernel/aarch64_root.zig` (`build.zig:120`).
Both are standalone skeletons, not the full kernel behind a shared `arch` abstraction.

### Subsystem Map

| Area | Current code evidence | Current state |
|---|---|---|
| Build | `build.zig` | Default x86_64 kernel/user build; `-Darch=riscv64` skeleton build; host unit-test step exists |
| Boot/arch | `kernel/main.zig`, `kernel/arch/x86_64/*`, `kernel/smp.zig` | x86_64-specific main path; many shared modules import `arch/x86_64` directly |
| Memory | `kernel/mm/*`, `kernel/arch/x86_64/paging.zig` | PMM, HHDM, slab, mmap/brk/swap/COW support exist; paging lacks a shared arch facade |
| Process/scheduler | `kernel/proc/task.zig`, `kernel/proc/sched.zig`, `kernel/proc/per_cpu.zig` | Static 64-task table; per-CPU 256-slot LIFO ring queues with work-stealing (`PerCpuRunQueue`); per-CPU current index/slice/anchor; global bitmap fallback retained |
| Syscalls | `kernel/arch/x86_64/syscall_entry.zig` | Large x86_64 dispatch entry with native/Linux-oriented handlers and many inline imports |
| Filesystems | `kernel/fs/*`, `kernel/main.zig` | ramdisk, FAT32, ext2, tmpfs, procfs, page cache/writeback are wired; several fs helper modules remain standalone |
| Network | `kernel/net/mod.zig`, `kernel/drivers/e1000.zig`, `kernel/drivers/virtio_net.zig` | e1000/virtio-net drivers initialize; ARP/IPv4/ICMP/UDP/TCP path is wired via `net/mod.zig` |
| IPC | `kernel/ipc/ipc.zig`, `kernel/ipc/capability.zig`, timer/event/posix timer modules | Core IPC/capability path initializes; some POSIX/SysV modules are not consistently documented as integrated |
| Tests | `tests/main.zig` | Host tests cover `byte_order`, `fmt_core`, `str`, and `cow_pte` (`build.zig:286-301`); QEMU `hello*` tests are runtime/manual gate |

## 2. Review Findings

### P0 - Documentation Overstates Implemented Scheduler Architecture ✅ RESOLVED 2026-06-21

Evidence:

- `docs/kernel-subsystems.md` describes `scheduler.zig`, O(1) priority queues, per-CPU run queues, and work stealing as complete.
- Current code uses `kernel/proc/sched.zig` and `task.pickReadyForCpu()`, scanning a static task table under `task_lock` by CPU affinity.
- `docs/cross-arch-port-plan.md` still lists per-CPU run queues and work stealing as pending M8-7 work.

Risk: readers and future implementation work will assume scalability properties that the current scheduler does not provide.

Fix plan:

1. Rewrite the scheduler section in `docs/kernel-subsystems.md` to describe the actual affinity-scanning scheduler.
2. Keep O(1) per-CPU run queues/work stealing only in the roadmap, not as current implementation.
3. Add a verification note that M8-7 requires code changes, QEMU multi-core tests, and lock-order review.

**Resolution (2026-06-21)**: M8-7 implemented in `kernel/proc/per_cpu.zig` (~221 lines). `PerCpuRunQueue`
provides 256-slot ring per CPU with local-LIFO `push`/`pop` and `steal_half` for inter-CPU stealing
(respects `cpu_affinity`, TSC-randomized scan start). `pickNext` is now three-tier: local `pop` →
`tryStealForCurrent` → global bitmap fallback. Documentation in `docs/kernel-subsystems.md` §2.2 and
`docs/moqios-architecture-current.md` §1.9.2 / §5 has been rewritten to reflect the actual
implementation.

### P0 - Documentation Treats Some Uncompiled/WIP Modules As Supported Features

Evidence:

- `docs/build-and-toolchain.md` already records isolated modules that are not reached from `kernel/main.zig`.
- Other docs still list features such as futex, select/poll helpers, some SysV/POSIX IPC paths, and extended FS helpers as complete without consistently proving they are compiled or dispatched.
- `kernel/arch/x86_64/syscall_entry.zig` imports some modules directly, so each feature must be checked by reachability plus dispatch table entry, not by file existence.

Risk: support claims become unreliable. A source file existing under `kernel/` is not proof that the feature is built, type-checked through the real root, or reachable from userspace.

Fix plan:

1. For every documented feature, classify it as `wired`, `stub/ENOSYS`, `compiled helper`, or `isolated WIP`.
2. Add a small generated or scripted reachability report to CI/docs so stale claims are caught.
3. Update README and subsystem docs to avoid saying "complete" unless the code is reachable and has a verification path.

### P0 - Push Cannot Be Completed Without Remote Write Verification

Evidence:

- Remote is `git@github.com:konyka/MoQiOS.git`.
- The current environment has restricted network access; pushing requires outbound SSH and credentials.

Risk: final delivery can be blocked after local work is complete.

Fix plan:

1. Complete local docs and verification first.
2. Attempt `git push origin main` only after a clean diff and passing checks.
3. If network/credential approval fails, leave the commit ready and report the exact failed command.

### P1 - x86_64 Coupling Blocks The Cross-Architecture Goal 🚧 PARTIAL (2026-07-11)

Evidence:

- `kernel/arch/arch.zig` facade exists (M4); `main.zig` / `klog.zig` route serial/interrupts/paging/timer/context_switch through it.
- Many drivers/fs/mm/proc/net/IPC files still import `arch/x86_64/*` directly.
- `build.zig` routes riscv64 to `kernel/riscv64_root.zig` (skeleton), bypassing the full kernel root.
- riscv64 M2 verified: soft-float ABI, UART16550, `stvec`+breakpoint trap (`zig build -Darch=riscv64 smoke-riscv`).

Risk: riscv64 cannot share the real kernel subsystems until more call sites migrate and M3–M5 land.

Fix plan:

1. Continue migrating hot shared sites behind `arch.zig` (gdt/tsc/syscall_entry next).
2. Keep x86_64 bootable after each step (`smoke` / `smoke-smp`).
3. Grow riscv64 via M3 (PMM/Sv39) before attempting full `main.zig` reuse.

### P1 - SMP State Is Mid-Migration And Needs Stronger Gates ✅ RESOLVED 2026-06-21

Evidence:

- `smp.enable_ap_startup = true`.
- `sched.zig` uses per-CPU current task index, slice and anchor, but still has a global `sched_lock`.
- `Task.cpu_affinity` pins work to a CPU; code comments and roadmap still mark migration/work-stealing/TLB range shootdown/FPU state as pending.

Risk: enabling more AP scheduling without completing FPU, TLB shootdown and migration invariants can cause intermittent data corruption or faults.

Fix plan:

1. Preserve the current affinity-only scheduler as the baseline.
2. Add explicit tests for `MOQI_SMP=1` and `MOQI_SMP=2` boot-to-shell before changing migration.
3. Implement FPU/SSE save-restore before migrating user tasks across CPUs.
4. Implement ranged TLB shootdown before concurrent page-table modification across CPUs.
5. Replace global scheduler lock only after the invariants above are tested.

**Resolution (2026-06-21)**: All three blocking SMP invariants have been delivered together,
because they are mutually pre-requisite (cross-CPU migration needs independent FPU state, and
shared address-space modification needs ranged TLB shootdown):

- **M8-5b-3 FPU/SSE per-task state ✅**: `kernel/arch/x86_64/context_switch.zig` (~131 lines).
  Lazy save/restore via CR0.TS + #NM. `Task` extended with `fpu_state: [512]u8 align(16)`,
  `fpu_initialized`, `fpu_owned`. Per-CPU `fpu_owners` tracks current FPU holder. `initCpu()`
  invoked from BSP (`main.zig`) and AP (`smp.zig` `apEntry`); `onContextSwitch` does eager
  fxsave + sets CR0.TS; #NM handler does fxrstor / fninit and updates ownership.
- **M8-6 ranged TLB shootdown ✅**: `kernel/arch/x86_64/tlb.zig` (~206 lines). Replaces broadcast
  CR3-flush IPI with per-page invlpg coordinated through a single global request slot. Custom
  `TlbLock` re-enables IRQs while spinning to avoid cross-IPI deadlock. `FLUSH_THRESHOLD = 32`
  pages falls back to CR3 reload. Reuses existing `TLB_SHOOTDOWN_VECTOR = 0xFE`. Integrated into
  `mm/mprotect.zig` and `mm/mmap.zig` unmap paths via `tlb.shootdownRange(addr, page_count)`.
- **M8-7 per-CPU run queues + work-stealing ✅**: `kernel/proc/per_cpu.zig` (~221 lines). 256-slot
  LIFO ring per CPU, `steal_half` from victim's tail end, `cpu_affinity` respected, TSC-randomized
  scan start, only steals when local queue is empty (idle).

With FPU per-task and ranged TLB shootdown in place, user tasks can now safely migrate across
CPUs through work-stealing. AP cores actively pick up unpinned user tasks instead of idling.

### P1 - Automated Tests Are Too Narrow For Current Claims ✅ PARTIALLY RESOLVED 2026-07-10

Evidence:

- `zig build test` runs host tests for `byte_order`, `fmt_core`, `str`, and `cow_pte`.
- Runtime integration is documented as QEMU `hello*`, but it is not represented as an automated pass/fail command in the Zig test step.

Risk: host tests can pass while kernel boot, syscall, filesystem, networking, and SMP behavior regress.

Fix plan:

1. Keep host unit tests for pure library code.
2. Add a bounded serial-log QEMU smoke test script that checks for `MoQiOS shell` and expected `hello*` completion markers.
3. Add separate gates for `MOQI_SMP=1`, `MOQI_SMP=2`, and `-Darch=riscv64` build.

**Resolution (2026-07-10)**: Added `tools/qemu_smoke.sh` plus `zig build smoke` and
`zig build smoke-smp`. The smoke wrapper builds the x86_64 image, runs QEMU with serial output
captured to a file, waits for the current init auto-test tail marker `hello42 done` plus
`MoQiOS shell`, then terminates QEMU instead
of leaving the interactive shell running forever. `tools/qemu_run.sh` now packages user programs
through one `USER_PROGRAMS` loop instead of 29 repeated `if`/`cp` branches, keeping the runtime image
manifest maintainable and avoiding branch-heavy script drift as tests are added.

Remaining gap: these smoke gates still depend on local QEMU/Limine/xorriso availability and are not
yet wired to a hosted CI runner.

### P1 - Work-Stealing Mutated The Thief Queue Without Its Lock ✅ RESOLVED 2026-07-14

Evidence:

- `kernel/proc/per_cpu.zig` `steal_half` originally held only `target.lock`, then appended stolen
  tasks by mutating the thief queue's `head`, `nr_running`, and task slots.
- A concurrent remote wakeup may call `enqueueTask` for the thief queue, and a peer CPU may steal
  from that same queue. Both paths correctly use the thief queue's lock, so the unlocked mutations
  could race with them and lose/corrupt runnable entries.

Fix:

1. Acquire both thief and victim queue locks for every steal.
2. Order the pair by ascending logical CPU ID, which eliminates reciprocal-steal ABBA deadlock.
3. Keep the lock scope to the bounded ring transfer; local `push`/`pop` remain one-lock O(1) paths.

**Resolution (2026-07-14)**: `steal_half` now takes both queue locks in canonical CPU-ID order.
This restores queue ownership invariants while retaining the per-CPU design and its cache-local
LIFO fast path. Host tests plus x86_64/riscv64/aarch64 builds and the x86_64 single-core smoke gate
passed before the correction; the dual-core gate is recorded separately below because it exposed an
independent runtime regression during the final verification run.

### P0 - Reusing A Task Slot Remapped A Shared Kernel Stack On SMP ✅ RESOLVED 2026-07-14

Evidence:

- On a repeatable dual-core `hello2` -> `hello3` -> `hello4` sequence, QEMU reported the initial
  fault as `#PF`, error code `0x2`, at the `call getPerCpuOrNull` instruction in
  `proc.per_cpu.getCurrent`; `CR2=0xffffffff900d8fd8` was on task slot 3's kernel stack.
  The visible `#DF` was the secondary failure while delivering that page fault.
- `task.waitpid` reaped slot 3 after each child and `freeKernelStack` unmapped its 32 high-half
  stack pages. The next child reused slot 3 and remapped those pages through the kernel PML4.
  User PML4s share that upper-half hierarchy, so another CPU may retain a stale translation during
  the unmap/remap window.

Fix:

1. Keep each fixed virtual task-stack slot mapped after its first allocation on x86_64.
2. Reuse its backing pages on later task-slot reuse rather than unmapping, freeing and remapping.
3. Preserve the existing non-x86 free path; its address-space model does not share this x86_64
   high-half mapping contract.

Performance and capacity: the cache has a strict `MAX_TASKS * 128KiB = 8MiB` upper bound. It
removes 32 PMM allocations plus 32 page-table edits at spawn, 32 unmaps/frees at reap, and their
cross-core TLB-coherency cost from every reused task slot. This is faster and safer than sending a
global shootdown for every 4KiB stack page.

**Resolution (2026-07-14)**: `kernel/proc/task.zig` now keeps the mapping for each allocated
x86_64 stack slot. After an isolated-cache rebuild, host tests, x86_64 build, riscv64/aarch64
builds, the single-core smoke gate, and five consecutive dual-core smoke runs all passed. The
five-run dual-core sequence exercises the formerly failing `hello4`/slot-3 reuse path repeatedly.
`zig build smoke-smp-stress` now makes that five-run regression gate executable by default
(`MOQI_SMOKE_RUNS=N` overrides the run count).

### P2 - Version And Date Metadata Is Inconsistent

Evidence:

- `docs/moqios-architecture-current.md` is dated 2026-06-16.
- `docs/moqios-implementation-plan.md` is dated 2026-06-29, which is after this review date.
- Several counts differ across docs (`123`, `125`, and line totals).

Risk: docs look generated or stale and make it hard to know which state is authoritative.

Fix plan:

1. Treat this review doc as the current correction layer.
2. Replace precise line counts with generated command references unless they are refreshed in the same commit.
3. Avoid future-dated implementation metadata.

### P2 - Build Documentation Has Minor Path Drift

Evidence:

- `build.zig` emits `moqi-kernel.elf` and `moqi-kernel-riscv64.elf`.
- Some docs still refer generically to `kernel.elf` as the output path.
- `build.zig` assembles `kernel/arch/x86_64/ap_trampoline_src.S` into `ap_trampoline.bin`, while docs mention `ap_trampoline.S`.
- 2026-06-21 local verification found the Windows environment lacks external `as`, `objcopy`, and `strip`; `build.zig`
  now uses `zig cc`, `ld.lld`, and `zig objcopy` for those steps.
- The installed Zig 0.15.2 toolchain failed to build user C programs with `-mno-sse/-mno-sse2` because compiler-rt
  emitted `__extendhfsf2` with an SSE register return. `build.zig` now keeps SSE disabled for the kernel target but no
  longer disables SSE for user-space C programs. This matches the current SMP roadmap item that FPU/SSE task state
  must be treated as a real runtime invariant before cross-core user task migration.
- Because `zig objcopy --strip-all` does not keep ELF output when the destination is named `.bin`, C user programs now
  compile directly to `user/<name>.bin` as loadable ELF files on this Windows-compatible path. Size-only stripping can
  be restored later behind an optional binutils/toolchain check.

Risk: new contributors will debug non-existent paths or use stale artifact names.

Fix plan:

1. Align build docs with `build.zig` artifact names and Zig-bundled tooling.
2. Document generated files (`user/*.elf`, `user/*.bin`, `kernel/arch/x86_64/ap_trampoline.bin`) as build outputs, not source truth.
3. Add a runtime FPU/SSE smoke test before enabling user task migration across CPUs.

## 3. Verification Plan

Run these gates before claiming the repository is healthy:

| Gate | Command | Proves |
|---|---|---|
| Git cleanliness | `git status --short --branch` | Review starts/ends from known branch state |
| Source inventory | `rg --files` | Docs match current tree shape |
| Host unit tests | `zig build test` | Pure library helpers still pass |
| x86_64 build | `zig build` | Main kernel, user programs, AP trampoline build |
| riscv64 skeleton build | `zig build -Darch=riscv64` | Cross-ISA skeleton still builds |
| QEMU single-core smoke | `zig build smoke` | Kernel reaches shell after current init auto-test tail marker `hello42 done` |
| QEMU SMP smoke | `zig build smoke-smp` | AP bring-up path remains stable through the full init sequence (`MOQI_SMP=N`, default 2) |
| QEMU SMP matrix | `zig build smoke-smp-matrix` | Multiple CPU counts smoke in one pass; default list `1 2 3 4 6 8`, override via `MOQI_SMOKE_MATRIX_CPUS` |

If QEMU or toolchain pieces are unavailable, record that as a verification gap instead of treating host tests as a substitute.

## 4. Recommended Repair Order

1. ~~Correct documentation status claims and keep this review linked from primary docs.~~ Done.
2. Add reachability/dispatch classification for kernel modules.
3. ~~Add automated QEMU smoke gates.~~ ✅ Done 2026-07-10 (`zig build smoke`, `zig build smoke-smp`).
4. ~~Stabilize SMP affinity scheduling with repeatable `MOQI_SMP=2` tests.~~ ✅ Done 2026-07-26 (CPU-count-adaptive model; smoke-smp-matrix covers 1/2/3/4/6/8/12/16 cores; see §5.2).
5. ~~Implement FPU/SSE task state and ranged TLB shootdown.~~ ✅ Done 2026-06-21 (see P1 resolution).
6. ~~Replace global scheduler lock with per-CPU queues and work stealing.~~ ✅ Done 2026-06-21
   (per-CPU `IrqSpinlock` per queue replaces the global `sched_lock` on the hot path; the global
   lock is retained only for the bitmap-fallback scan).
7. Extract `kernel/arch/arch.zig` after the x86_64 behavior is covered by gates.
8. Expand riscv64 from skeleton to shared-kernel boot only through the new arch facade.

## 5. Verification Results For This Update

### 5.0 Review Update: 2026-07-14

> 历史门禁记录（2026-07-19）：下表反映当时的 probe ladder；当前跨架构 smoke
> 覆盖范围以 `docs/cross-arch-port-plan.md` 和 `docs/build-and-toolchain.md` 为准。

| Gate | Result | Notes |
|---|---|---|
| `zig build test` | Passed | Host unit tests passed before the work-stealing correction. |
| `zig build` | Passed | x86_64 kernel, user programs, and AP trampoline passed before the correction. |
| `zig build -Darch=riscv64` | Passed | riscv64 build passed. |
| `zig build -Darch=aarch64` | Passed | aarch64 build passed. |
| `zig build smoke` | Passed | Reached `hello21 done` and `MoQiOS shell` with `MOQI_SMP=1`. |
| `zig build smoke-smp` | Passed (5 consecutive runs) | Repeatedly reached `hello21 done` and `MoQiOS shell` with `MOQI_SMP=2`, including repeated task-slot-3 / `hello4` reuse. |
| `zig build smoke-smp-stress` | Added | Default five-run dual-core regression gate; run it after scheduler, page-table, task-stack or SMP changes. |
| Isolated-cache rebuild | Passed | The default cache intermittently returned `manifest_create ReadOnlyFileSystem`; `ZIG_LOCAL_CACHE_DIR=/tmp/moqios-local-cache ZIG_GLOBAL_CACHE_DIR=/tmp/moqios-global-cache` rebuilt and ran all listed gates. |

The P1 queue-lock correction and the stack-slot reuse fix are source-reviewed, formatted and
dual-core runtime-verified. The default Zig cache issue is environmental; use the isolated cache
variables above for repeatable local verification until its filesystem cause is corrected.

Executed on 2026-07-10:

> 历史门禁记录（2026-07-25）：下表保留当时的验证证据；当前跨架构 smoke
> 覆盖范围以 `docs/cross-arch-port-plan.md` 和 `docs/build-and-toolchain.md` 为准。

| Gate | Result | Notes |
|---|---|---|
| `git status --short --branch` | Passed | Branch `main...origin/main`; clean before this update |
| `zig build test` | Passed | Host unit tests for pure helper modules |
| `zig build` | Passed | x86_64 kernel, user programs, and AP trampoline build |
| `zig build -Darch=riscv64` | Passed | riscv64 skeleton still builds |
| `zig build smoke` | Passed | Reached `MoQiOS shell` after current `init.S` auto-test tail marker `hello21 done` |
| `zig build smoke-smp` | Passed | Dual-core QEMU reached the same shell marker with `MOQI_SMP=2` |

The new smoke gates are now executable, but they prove the repository is not yet runtime-clean.
Do not treat the passing host builds as proof of boot-to-shell health until `zig build smoke` passes.

 The `hello77` gate records syscall #291 as an ext2/FAT32, bounded, best-effort readahead contract:
 only regular ext2 or FAT32 files are eligible, `count` is limited to 32 pages, overflow and unsupported
descriptor types return `EINVAL`, invalid descriptors return `EBADF`, and the call does not move
the fd offset. Acceptance checks subsequent read correctness; it makes no wall-clock claim.

### 5.1 Runtime Fixes From 2026-07-10 Smoke Testing

The new single-core smoke gate exposed a runtime hang at `spawn("hello2")`. The fix set is:

| Area | Change | Performance/safety impact |
|---|---|---|
| PMM contiguous allocation | `allocContiguous` now starts from `next_free_hint` and skips to the first page after a failed run | Avoids repeated low-memory scans for contiguous allocations |
| Kernel stacks | Task stacks moved from physically contiguous HHDM runs to fixed high-half virtual stack windows backed by per-page PMM allocations; stack size raised to 32 pages / 128KB | Removes task creation dependence on contiguous physical memory and avoids stack-probe double faults |
| Signal trampoline | `setupSigreturnTrampoline` now reuses one shared trampoline physical page and maps it with `mapPageNoFlush` into new user page tables | Avoids one PMM allocation and unnecessary TLB invalidation per user process |
| `waitpid` | Blocking wait now queues the parent on child exit waiters and yields via scheduler instead of `hlt`-spinning in the syscall | Fixes single-core parent/child progress and removes polling |
| COW/copy_to_user | Kernel-mode writes to current user COW pages now resolve through the COW fault path; private-page PTE replacement preserves flags while replacing the physical address | Fixes fork wait-status writes to COW user stacks |
| User-space teardown | `destroyUserSpace` skips the shared sigreturn trampoline mapping | Prevents repeated frees of the one shared trampoline page |

The 2026-07-10 rerun passed both single-core and dual-core smoke after the COW/copy_to_user and
shared-trampoline teardown fixes. **Doc drift fixed 2026-07-11**: primary docs now state that
`init.S` auto-sequence runs through `hello42` (shell next); only `hello11` and `hello28` are
manual. riscv64
console docs updated from SBI putchar to UART16550 (M2).

### 5.2 Review Update: 2026-07-18

This review re-ran the current runtime gates and inspected the shared native-user preemption path,
aarch64/riscv64 probe setup, task/FD lifetime handling, and memory-copy fault recovery.

| Area | Finding | Resolution / status |
|---|---|---|
| Native preemption | `nativeTrapFramePreempt` relocated the live TrapFrame before confirming that another task was ready; the no-switch path did unnecessary work and a bad next-task lookup could follow a state mutation. | Fixed: choose and validate the next task first; relocate only before enqueueing an actual switch. This preserves the steal-safe `saved_rsp` ordering while removing needless frame copies. |
| Default timer path | `sk31.onDefaultTimer` read `currentTaskIndex()` twice for each user-mode timer interrupt. | Fixed: capture it once and reuse it for the probe accounting path. |
| aarch64 IRQ masking | `arch.interrupts.enableIrq` and `disableIrq` were no-ops, unlike riscv64 `sstatus.SIE`, so shared probe setup could not enforce its masked critical section. | Fixed: use `daifclr #2` / `daifset #2` for the DAIF.I bit. aarch64 QEMU smoke passed with real masking. |
| Probe allocation failures | aarch64 and riscv64 user-IRQ probe setup leaked newly allocated pages when the second allocation or a mapping failed. | Fixed: unmap and free every allocation on every failure path. |
| User-copy fault recovery | `kernel/mm/copy_from_user.zig` still records the need for an assembly RIP-range fault-recovery guard. | Mitigated P1: page-walk precheck + `userAccessBegin/End` prevent mapped-range faults from taking down the kernel; true exception-table recovery remains a separate design. |
| Fork FD ownership | `kernel/proc/fork.zig` copies socket/epoll/eventfd/timerfd/unix-socket descriptors without the required refcount ownership work. | ✅ Resolved: v53.44 `retainSharedResources` covers ext2/tcp/epoll/unix/timerfd; 2026-07-22 adds eventfd `ref_count` + `eventfdRetain`/`eventfdClose` wiring (same O(1) retain path as timerfd). |
| Scale limits | Static task-table bitmap scans, page-cache clock sweeps, and ext2 directory scans remain linear in their respective structures. | Open P1: profile before replacing bounded structures; no speculative data-structure rewrite in this maintenance pass. |
| Private futex isolation | Bucket-only futex queues could wake waiters for a different word in the same page, while PI/requeue opcodes advertised success without PI/requeue semantics. | Fixed private basic WAIT/WAKE keys to `(page_table_phys, uaddr)` and reject unsupported PI/requeue/bitset/WAKE_OP/waitv operations with `ENOSYS` before mutating user words or queues; hello69 locks the public contract. Shared futex physical keys and real priority inheritance remain separate work. |
| AIO cancellation | `io_cancel` returned `EINVAL` although every `io_submit` request completes synchronously before return and no pending-request state exists. | Fixed: return `ENOSYS` without acquiring context state, reading IOCB, or writing the result buffer; hello70 locks the no-mutation contract. Real asynchronous cancellation remains separate lifecycle work. |
| Memory locking | User mlock-family syscalls reported success while only toggling mapping metadata and did not pin pages or enforce MCL_FUTURE. | Fixed: all user mlock/munlock/mlockall/munlockall calls return `ENOSYS` without inspecting or mutating mappings; hello71 verifies sentinel preservation and MAP_FIXED metadata independence. Internal no-free device locks remain separate. |

> 历史门禁记录（2026-07-25）：下表的 SK-150 声明是当时记录，不代表当前
> RISC-V/AArch64 smoke 合约；当前范围以 `docs/cross-arch-port-plan.md` 为准。

| Gate | Result | Notes |
|---|---|---|
| `zig build test` | Passed | Host helper tests. |
| `zig build` | Passed | x86_64 kernel, userspace programs, and AP trampoline. |
| `zig build -Darch=riscv64` | Passed | riscv64 build. |
| `zig build -Darch=aarch64` | Passed | aarch64 build with real DAIF IRQ masking. |
| `zig build smoke` | Passed | x86_64 reached `hello21 done` and `MoQiOS shell` with `MOQI_SMP=1`. |
| `zig build smoke-smp` | Passed | x86_64 reached the same markers with `MOQI_SMP=2`. |
| `zig build smoke-smp-stress` | Passed | Five consecutive dual-core runs reached the shell. |
| `zig build -Darch=riscv64 smoke-riscv` | Passed | Shared probe ladder, virtio, and U-mode smoke. |
| `zig build -Darch=aarch64 smoke-aarch64` | Passed | Shared probe ladder, default timer, EL0/SVC smoke. |

### 5.2b Review Update: 2026-07-19

> 本节及其后的 5.2b–5.2t 门禁表均为历史审查记录，保留当时的验证证据，
> 不定义当前跨架构 smoke 覆盖范围。当前命令契约以
> `docs/build-and-toolchain.md` 与 `docs/cross-arch-port-plan.md` 为准；当前
> RISC-V 为 SK-2..SK-15、SK-17..SK-19，AArch64 为 M9-1..M9-7 与 SK-2..SK-19。

| Area | Finding | Resolution / status |
|---|---|---|
| C user-program entry alignment | C user images enter `_start` without a CRT call frame, so `rsp` is not guaranteed 16-byte aligned; compiler-generated SSE spills in `main` (e.g. `hello8`) could fault on movaps-class stores. | Fixed: `andq $-16, %rsp` in the `hello8` `_start` before `call main`, plus `-mstackrealign` for all C user programs in `build.zig` so every compiled function realigns defensively. |

| Gate | Result | Notes |
|---|---|---|
| `zig build smoke` | Passed | x86_64 reached `hello21 done` and `MoQiOS shell` with `MOQI_SMP=1`. |
| `zig build smoke-smp` | Passed | Same markers with `MOQI_SMP=2`. |
| `zig build -Darch=riscv64 smoke-riscv` | Passed | Shared probe ladder through SK-36 + virtio + U-mode. |
| `zig build -Darch=aarch64 smoke-aarch64` | Passed | Shared probe ladder through SK-36 + default timer + EL0/SVC. |

### 5.2c Review Update: 2026-07-22

| Area | Finding | Resolution / status |
|---|---|---|
| eventfd fork/close | `vfs.close` left a stale "no module yet" stub and never called `eventfdClose`; `retainSharedResources` omitted `.eventfd`, so fork + close leaked pool slots or (once wired) would free under the child's feet. | Fixed: `EventfdInstance.ref_count` + `eventfdRetain`/`eventfdClose` (free at 0), wired into `FdTable.close` and `retainSharedResources`. Close no longer resets the held spinlock word. Same O(1) retain path as timerfd — no speculative redesign. |
| FAT32 name/dir-entry purity | After SK-61, 8.3 encode/decode and dir-entry field math remained inline in the I/O driver. | SK-62: extracted into `fat32_util.zig` + non-x86 probe; x86 driver delegates 1:1. |
| ext2 parse purity | Superblock/geometry/inode-table math lived only inside the I/O driver. | SK-63: `ext2_util.zig` + non-x86 probe; `init`/`readInode`/`writeInode`/mode predicates delegate. |
| ext2 resolve duplication | `resolveBlock` re-implemented classify bounds and six copy-pasted cache/I/O walks. | SK-64: `switch (classifyLogicalBlock)` + shared `loadIndirectPtr`; `resolveLogicalPure` proves the compose path without I/O. |
| ext2 ensure duplication | `ensureBlock` still hand-rolled the same bounds and repeated root/child/data ensure ladders. | SK-65: same classifier; `ensureIndirectRoot` / `ensureChildIndirect` / `ensureDataPtr`; `indirectRootSlot` + probe lock the resolve/ensure contract. |
| FAT32 long names skipped | `listRootDir` ignored LFN slots and only exposed 8.3 names. | SK-66: `assembleLfnUtf8` + driver pending-chain; checksum/surrogate validated on non-x86. |
| FAT32 long-name create | `createFile` capped at 12 chars and wrote only 8.3 entries. | SK-67: `buildLfnEntries`/`make83Alias` + consecutive-slot write; round-trip probed on non-x86. |
| FAT32 root first-sector only | `listRootDir`/`createFile` ignored later sectors/clusters in the root chain. | SK-68: full sector/cluster walk + optional `growRootDir`; placement helpers in `fat32_util`. |
| FAT32 LFN chain sector-bound | Free-run find/write assumed a single-sector window, so long LFN chains near a sector tail could not span. | SK-69: `findConsecutiveFreeMulti` + `findFreeRunInRoot`/`writeRootEntryRun` across sector/cluster boundaries. |
| IPv6 UDP demux empty | `mod.zig` left `PROTO_UDP` over IPv6 as a TODO; stack could not deliver or emit IPv6 UDP. | SK-70: `udp_util` checksum/parse + `handlePacketV6`/`sendToV6`/`recvFromV6`; syscall `sockaddr_in6` deferred to SK-71. |
| AF_INET6 UDP still IPv4 | `socket(AF_INET6, SOCK_DGRAM)` lacked an IPv6 fd flag; address ops parsed `sockaddr_in` only. | SK-71: `udp_is_v6`/`udp_dst_ip6` + `sockaddr_util` + bind/sendto/recvfrom/connect V6 branches. |
| NDP miss never solicits | `sendToV6` marked incomplete but never sent NS, so new neighbors could not resolve. | SK-72: `buildNeighborSolicitation`/`sendNeighborSolicitation` + wired from `sendToV6`. |
| UDP name queries missing | `getsockname`/`getpeername` accepted only TCP and capped `fd >= 16`. | SK-73: UDP v4/v6 via `encodeUdpName`; `ENOTCONN` when unconnected; `MAX_FDS` bound. |
| IPv6 TCP demux empty | `mod.zig` left `PROTO_TCP` over IPv6 as a TODO. | SK-74: `tcp_util.checksumV6` + checksum-gated `handlePacketV6` (TCB demux deferred). |
| IPv6 TCP no TCB match | Checksum gate dropped all segments; no `remote_ip6` / listen family split. | SK-75: TCB/`ListenSlot` `is_v6`, `findTcbByTupleV6`, `handleIncomingSynV6`; SYN-ACK TX deferred. |
| IPv6 TCP no SYN-ACK TX | `sendSegment` returned false for v6 TCBs after listen SYN. | SK-76: `fillTcpSegment` + `sendSegmentV6` (NDP) + handshake completion in `handlePacketV6`. |
| IPv6 TCP data path split | Established/FIN handling lived only in IPv4 `handlePacket`. | SK-77: shared `driveTcbStateMachine` for both families after demux. |
| TCP sockaddr_in6 gap | TCP bind/connect/name queries and accept peer fill treated addresses as IPv4-only. | SK-78: `tcpConnectSocketV6` + `AddrInfo` v6 fields + `encodeInetName` in syscall paths. |
| NDP NS no retransmit | Cache-miss NS was one-shot; lost solicitations left `incomplete` forever. | SK-79: `ndp.timerTick` + `icmpv6.neighborTimerTick` (RetransTimer/MAX_MULTICAST_SOLICIT). |
| NDP forever reachable | Confirmed neighbors never aged to `stale`. | SK-80: `REACHABLE_TIME_MS` aging in `ndp.timerTick`; stale still usable via lookup. |
| NDP no unicast NUD | Stale neighbors never entered DELAY/PROBE or sent unicast NS. | SK-81: stale→delay on lookup; probe unicast NS via `Solicit` + `buildNeighborSolicitationUnicast`. |
| No IPv6 default router | RS/RA constants existed but were unused; host had no default router. | SK-82: `buildRouterSolicitation` + RA parse → `ndp.setDefaultRouter`. |
| RA prefixes ignored | Prefix Information options were skipped; no on-link table. | SK-83: PIO parse + `ndp.setPrefix`/`isOnLink` + `ipv6.prefixMatch`. |
| No SLAAC addresses | A-flag prefixes were stored but never formed host addresses. | SK-84: `formSlaacAddress`/`installSlaac` on autonomous /64 PIO. |
| SLAAC skipped DAD | New addresses were usable immediately without duplicate detection. | SK-85: tentative→DAD NS→preferred; conflict abandons the address. |
| IPv6 TX always link-local | UDP/TCP IPv6 sends ignored preferred SLAAC globals. | SK-86: `selectSourceAddress` wired into V6 TX and name queries. |
| Off-link IPv6 unroutable | TX NDP-resolved the L3 destination, so off-link peers never sent. | SK-87: `resolveNextHop` uses default-router MAC for off-link. |
| No automatic RS | Hosts waited passively for RA and never solicited routers. | SK-88: `startRouterSolicit` from `net.init` with interval retries. |
| Default router never expired | Router Lifetime was stored but never aged out. | SK-89: `routerLifetimeTimerTick` clears the router and restarts RS. |
| RA prefixes never expired | Prefix Valid Lifetime was stored but never aged out. | SK-90: `prefixLifetimeTimerTick` clears prefixes and matching SLAAC. |
| Preferred Lifetime unused | PIO preferred lifetime ignored; SLAAC stayed preferred forever. | SK-91: age preferred → `deprecated`; source select skips it. |
| Single default router only | A later RA replaced the only default router. | SK-92: multi-router list; prefer reachable; failover on expiry. |
| Dead default router still selected | NUD probe failure did not remove a router from selection. | SK-93: `nud_failed` + failover; active DELAY on stale select. |
| RA Route Information ignored | Off-link TX always used the default router. | SK-94: RIO table + longest-match next hop in `resolveNextHop`. |
| ICMPv6 Redirect ignored | Type 137 was dropped; hosts never updated first hop. | SK-95: Destination Cache + validated Redirect handling. |
| Stale redirect after NUD fail | Destination Cache kept next hops that failed NUD. | SK-96: clear cache entries when next-hop NUD exhausts. |
| No IPv6 Path MTU | Packet Too Big ignored; TX always used link MTU. | SK-97: PMTU cache + UDP/TCP refuse oversized sends. |
| TCP IPv6 MSS fixed | TCP segmented at 1460/1200 ignoring learned PMTU. | SK-98: IPv6 SMSS = PMTU−60 in flush/send. |
| Reno used fixed MSS | cwnd/ssthresh stepped by 1460 after PMTU shrink. | SK-99: congestion control uses `mssForTcb` SMSS. |
| No TCP MSS option | SYN omitted MSS; peer MSS was ignored. | SK-100: advertise local SMSS; clamp to min(local, peer). |
| No IPv4 Path MTU | ICMP Frag Needed ignored; TX always used link MTU. | SK-101: PMTU cache + UDP/TCP refuse oversized; SMSS=PMTU−40. |
| Fixed 1500 SYN MSS ceiling | Interface/RA MTU ignored; MSS always assumed Ethernet 1500. | SK-102: `netif` MTU + RA option type=5; Path MTU/MSS follow. |
| PMTU never raised gradually | Expiry snapped back to link MTU. | SK-103: plateau raise probing before cache clear. |
| Raise waited only on timer | Full-MTU sends did not accelerate recovery. | SK-104: successful full-size TX steps one plateau early. |
| Could not probe above PMTU | TX hard-capped at cached PMTU. | SK-105: armed oversized probe via `getSendMtu`. |
| Timer blind-raised PMTU | Expiry raised cache with no TX proof. | SK-106: expiry arms probe first; blind raise is fallback. |
| Slow PMTU recovery after PTB | Next probe waited for full PMTU lifetime. | SK-107: 30s cooldown auto-arms raise probe. |
| Fast retransmit ignored SACK | Always resent from snd_una including SACKed bytes. | SK-108: retransmit first hole; skip scoreboard ranges. |
| Keepalive used snd_nxt | Empty ACK at snd_nxt often ignored by peers. | SK-109: probe SEQ = SND.UNA−1 per RFC 1122. |
| Zero window could stall forever | Lost window-update left unsent data stuck. | SK-110: persist timer sends 1-byte probes. |
| SACKed bytes blocked the pipe | In-flight used snd_nxt−snd_una during recovery. | SK-111: pipe = flight − sacked (RFC 6675). |
| Fast retransmit waited on 3 dupacks | SACK already proved head loss. | SK-112: RFC 6675 IsLost also enters recovery. |
| Scoreboard replaced / wiped | Latest SACK option overwrote prior holes; new ACK cleared all. | SK-113: UpdateScoreboard merges, clips by [una,nxt), keeps ≤4. |
| Reno recovery overshot pipe | +SMSS/dupack and −acked/partial ignored pipe vs ssthresh. | SK-114: RFC 6937 PRR paces cwnd = pipe + sndcnt. |
| Spurious fast retransmit stuck | Reordering halved cwnd with no undo path. | SK-115: RFC 2883 DSACK restores prior cwnd/ssthresh. |
| Spurious RTO stuck | Delayed ACK cut cwnd with no F-RTO probe. | SK-116: RFC 5682 F-RTO undoes after two new ACKs. |
| Tail loss waited for RTO | Lost last segments produced no dupack/SACK. | SK-117: TLP probes at ~2·SRTT without cutting cwnd. |
| Slow recovery with sparse SACK | DupThresh/IsLost waited despite timed-out head. | SK-118: RACK-lite enters recovery after SRTT+reo_wnd. |
| Post-recovery cwnd undershoot | Exit always set cwnd=ssthresh below measured BDP. | SK-119: delivery-rate sample floors cwnd at min(BDP,2·ssthresh). |
| cwnd burst without pacing | Full window injected at once after rate known. | SK-120: pace SMSS sends by delivery_rate interval. |
| Slow start undershoots BDP | Reno SS ignored measured rate×min_rtt. | SK-121: BBR-lite Startup to 2·BDP then Drain to BDP. |
| Post-startup Reno drift | CA ignored BDP; min_rtt never refreshed. | SK-122: ProbeBW cruises near BDP; ProbeRTT every 10s. |
| ProbeBW lacked drain/probe | Fixed ≤1.25×BDP cruise filled queues. | SK-123: 8-phase gains [5/4,3/4,1×6] on cwnd and pace. |
| Reno CA on long-fat paths | Fallback AI too slow; ½ cut too harsh. | SK-124: CUBIC CA + β=0.7 when BBR rate absent. |
| Slow start overshoots queues | SS grew until loss despite rising RTT. | SK-125: HyStart++ CSS then exit SS on delay. |
| RACK only timed SND.UNA | Sparse SACK used SRTT, not delivered-seg RTT. | SK-126: 8-slot per-segment TX times + RACK ref. |
| Mid-flight holes waited on DupThresh | RACK only entered recovery for the head. | SK-127: any RACK-lost hole enters recovery / preferred rexmit. |
| RACK repair needed fresh ACK | Quiet peers waited for TLP/RTO. | SK-128: timer scans RACK-lost holes before RTO (RTT-paced). |
| HyStart reacted per RTT sample | Single noisy sample entered CSS early. | SK-129: decide only at ACK-train round boundaries. |
| ACK spacing ignored in SS | Queueing stretched ACKs without HyStart signal. | SK-130: inter-ACK gap triggers CSS/exit inside a round. |
| No ECN reaction path | Congestion needed loss or RTT delay only. | SK-131: SYN ECN + ECT + CE→ECE + ECE cut/CWR. |
| ECN then loss double-cut | ECE cut had no undo; FR cut again. | SK-132: ECN undo + skip second CUBIC cut. |
| ECN cut ignored PRR | Post-ECE CA could burst; recovery ignored ECE. | SK-133: ecn_prr drain + recovery ssthresh update. |
| ECE collapsed multi-CE | Sticky ECE hid repeated CE in one window. | SK-134: 3-bit ACE counter echo + delta react. |
| ACE only cut once | After `ecn_reduced`, further ACE advances ignored until CWR. | SK-135: ACE may re-cut after ≥1 RTT; sticky ECE stays once-per-window. |
| ACE delta ignored severity | Any ACE advance applied one CUBIC β cut. | SK-136: stack CUBIC β once per ACE CE count (ECE-only → one). |
| ECN cut left BBR probing | Post-ACE ProbeBW could climb with 5/4 gain on stale rate. | SK-137: jump to drain phase + discount delivery_rate by ACE cuts. |
| CUBIC raced to pre-ACE peak | After ACE β^n cut, W_max stayed at pre-cut cwnd. | SK-138: ACE sets W_max to scaled ssthresh; ECE-only keeps classic. |
| ACE without AccECN negotiate | ACE ran whenever classic `ecn_ok` was set. | SK-139: AE on SYN-ACK → `accecn_ok`; ACE gated on AccECN. |
| ACE in byte12 reserved bits | Non-standard ACE placement conflicted with AccECN flags. | SK-140: ACE packed into AE\|CWR\|ECE; classic sticky ECE unchanged. |
| First ACE cut from zero | Unsynced `ace_peer=0` treated handshake ACE as a large delta. | SK-141: first AccECN ACE sets baseline only; later deltas cut. |
| ACE 0b010 as feedback | Reserved AccECN encoding could skew peer delta / baseline. | SK-142: skip 0b010 on CE count; ignore invalid peer ACE. |
| AccECN still sent ECT(0) | L4S AQMs could not distinguish AccECN/scalable flows. | SK-143: AccECN non-SYN uses ECT(1); classic ECN keeps ECT(0). |
| AccECN CUBIC cuts too harsh | Dense L4S CE marks stacked β^δ and collapsed cwnd. | SK-144: AccECN uses (8−δ)/8 L4S-lite cuts; classic keeps CUBIC. |
| ACE δ ignored flight size | L4S cut used raw ACE δ without delivery normalization. | SK-145: `ip_ce_rx` stats + normalize cuts by `ace_delivered`/SMSS. |
| L4S cut lacked rate memory | Only since-last-cut delivery; no RTT CE-rate EWMA. | SK-146: per-RTT CE/seg Q8 EWMA drives AccECN L4S cuts. |
| ProbeBW ignored CE EWMA | Pacing/cwnd gain only discounted on ACE cut events. | SK-147: AccECN scales ProbeBW gain by CE-rate EWMA. |
| Startup ignored CE EWMA | AccECN still aimed at fixed 2·BDP under marking. | SK-148: EWMA shrinks Startup target; abort at Q8≥64. |
| ProbeRTT fixed under L4S | AccECN kept 10s ProbeRTT despite rising CE EWMA. | SK-149: EWMA shortens ProbeRTT interval (floor base/5). |
| ProbeRTT dwell fixed | 200ms ProbeRTT under high CE may not drain queue. | SK-150: EWMA stretches ProbeRTT duration up to 2·base. |
| TCP send bounce buffer | Full-window send staged 64KB on the 128KB kernel stack and copied twice. | SK-151: `tcpSendFromUser` copies user data straight into the send ring. |
| `fsync` barrier gate | Flush call rejected write-through devices, so every ext2/FAT32 sync returned EOPNOTSUPP. | Fixed: gate the barrier on `block_dev.supportsFlush`; failure maps to EIO. |
| waitpid lost wakeup | `waiting_for_child` was published after the zombie scan released `task_lock`, so a child exiting in that window woke nobody. | Fixed: rescan after publishing the flag, under the same lock the child uses. |
| sigreturn user pointer | The signal frame was read straight from `saved_user_rsp`, a user-controlled address. | Fixed: copy through `copyFromUser`, return EFAULT on a bad range. |
| Clone OOM rollback | Both `cloneUserPages` variants leaked the partial page-table tree on OOM; `fork` leaked a completed root when task creation failed. | Fixed: roll back through `destroyUserSpace` on every failure path. |
| Writeback truncated writes | `writeBuffered` kept only the first 4KB and reported success, losing half of every 8KB `copy_file_range`/`splice` chunk. | SK-152: split across page-sized extents, return bytes accepted, report ENOSPC. |
| User-copy fault recovery | Exception-table TODO still present. | Downgraded to mitigated P1: page-walk precheck already returns EFAULT-style 0 without kernel panic; RIP-range recovery deferred. |
| Fork FD ownership (broader) | Review still listed socket/epoll/eventfd/timerfd as open P0. | Closed: v53.44 + eventfd completion cover the shared-resource set; pipes keep their separate `Pipe.ref_count`. |

### 5.2d Review Update: 2026-07-24

This pass covered the tracked source tree, build graph, shell gates, user-facing status docs, and the
socket/block-device paths identified by static review. “All problems” is bounded to defects discoverable
through those checks; it does not claim proof of absence in uncompiled modules or untested hardware.

| Severity | Finding | Resolution / status |
|---|---|---|
| P1 | `recvfrom` consumed Unix/TCP/UDP data and ignored `copyToUser` failure, so an invalid mapped-range destination could report success while losing queued data. | Mitigated: validate the complete destination and optional source-address buffers before dequeue, and return `-EFAULT` (`-14`) if a later copy reports a short write. A concurrent unmap between validation and copy remains an open TOCTOU limitation. |
| P1 | NVMe advertised flush support while the block layer returned success without submitting a flush command. | Fixed safely: NVMe no longer advertises flush until command support exists; unsupported NVMe/virtio-blk flush returns an error instead of a false durability guarantee. |
| P2 | README status, test claims, and cross-architecture wording had drifted from the current build and smoke gates. | Fixed: synchronized Chinese/English README and recorded the authoritative evidence here. |

The user-buffer page walk adds bounded work proportional to the syscall buffer size, but prevents an
irreversible queue dequeue before validation. No speculative replacement of bounded task, cache, or
directory scans was made without profiling evidence. The real exception-table fault-recovery TODO and
uncompiled-module reachability gap remain explicit follow-up work.

| Gate | Result | Notes |
|---|---|---|
| `zig build test` | Passed | Host helper tests. |
| `zig build` | Passed | x86_64 kernel and userspace. |
| `zig build -Darch=riscv64` | Passed | riscv64 build. |
| `zig build -Darch=aarch64` | Passed | aarch64 build. |
| `zig build smoke` | Passed | x86_64 single-core reached `hello21 done` and `MoQiOS shell`. |
| `zig build -Darch=riscv64 smoke-riscv` | Passed | M7+shared probes+SK-150 markers. |
| `zig build -Darch=aarch64 smoke-aarch64` | Passed | M9-7+shared probes+SK-150 markers. |
| `zig build smoke-smp` | Passed on retry | The first 120-second run stopped in the existing `hello13` signal path before the shell marker; a second run reached the shell. This remains a timing-sensitive regression gate. |
| LSP diagnostics | Unavailable | `zls` is not installed; compiler gates were used instead. |

### 5.2e Review Update: 2026-07-25

This follow-up review rechecked the pushed socket/flush fixes, all three build targets, the user-copy
call sites reachable from the x86 syscall dispatcher, UDP payload sizing, driver queue state, and the
current documentation/toolchain claims. The scope remains evidence-bounded: uncompiled modules,
unverified physical hardware, and concurrency properties not exercised by the available QEMU gates are
reported as residual risks rather than claimed solved.

| Severity | Finding | Resolution / status |
|---|---|---|
| P1 | The legacy `tcp_recv` and TCP `recvmsg` syscalls consumed the receive ring before ignoring a failed `copyToUser`, unlike the newer `recvfrom` path. | Fixed: prevalidate each destination and report `-EFAULT` (or an earlier iovec's completed byte count) for a short copy after dequeue. Queue peek/commit and fault recovery remain broader follow-up work. |
| P1 | `timerfd_settime` accepted a failed/short `copyFromUser` for `new_value`, then passed an undefined temporary to the timer implementation; requested old-value output also ignored copy failure. | Fixed: validate and fully copy both user buffers. The old-value snapshot is copied out before the new timer state is committed, so `EFAULT` leaves the timer unchanged; `timerfd_gettime` now rejects missing/invalid output buffers. Concurrent updates to one timerfd still require a future syscall-level transaction API. |
| P1 | `validateUserRange` formed `addr + len` before checking wraparound. | Fixed: use subtraction against `USER_LIMIT` so wrapping input is rejected without an overflowing expression. |
| P1 | IPv6 UDP queue storage is 1472 bytes while the IPv6 receive path uses a 1232-byte temporary buffer. | Not reproduced as an overflow in the current enqueue path: `handlePacketV6` clamps payloads to `MAX_UDP_PAYLOAD_V6` before enqueue. Keep the protocol-specific capacity invariant explicit in future queue API work. |
| P1 | UDP port/queue publication and dequeue use an unprotected `valid` flag; virtio-blk request state and NVMe polling state are also shared mutable paths without a demonstrated SMP lock contract. | Deferred: requires queue reservation/commit and driver serialization design plus stress coverage; no speculative partial lock rewrite was shipped. |
| P1 | Page-table walks/copies remain vulnerable to a concurrent unmap/protection change between validation and `@memcpy`; general `MAP_FIXED` replacement still needs a broader transaction contract. | Bounded fix: `hello65` covers exact fully tracked anonymous private RW 4K PMM-owned replacements up to 128 pages. Unsupported shapes or resource failures return `ENOMEM` unchanged, and successful replacement zero-fills new pages. Global address-space locking, fault recovery, TLB shootdown, and general rollback remain deferred. |
| P2 | Limine base revision 3 is deprecated by current protocol documentation. | Deferred compatibility task: upgrade only after auditing all requested protocol tags against the target Limine revision. |

The immediate fixes add at most one bounded page walk before the legacy TCP/timer operations already
performed a user copy. No queue, cache, scheduler, or page-table data structure was replaced without
measurements. The remaining P1 items are recorded as design work because a partial implementation could
turn a detectable error into packet corruption, device queue corruption, or a cross-CPU page fault.

| Gate | Result | Notes |
|---|---|---|
| `zig build test` | Passed | Host helper tests. |
| `zig build` | Passed | x86_64 kernel and userspace. |
| `zig build -Darch=riscv64` | Passed | riscv64 build. |
| `zig build -Darch=aarch64` | Passed | aarch64 build. |
| `zig build smoke` | Passed | x86_64 single-core reached shell. |
| `zig build smoke-smp` | Passed | x86_64 dual-core reached shell. |
| `zig build -Darch=riscv64 smoke-riscv` | Passed | M7+shared-probe smoke. |
| `zig build -Darch=aarch64 smoke-aarch64` | Passed | M9-7+shared-probe smoke. |
| `bash -n tools/*.sh` | Passed | Shell scripts parse successfully. |
| LSP diagnostics | Unavailable | `zls` is not installed; compiler gates were used instead. |

### 5.2f Review Update: 2026-07-25

This pass extended the audit from syscall copy semantics into shared address-space lifetime, boot
protocol discovery, timer validation, multiplexing outputs, and raw network user-buffer boundaries.
It also rechecked the deferred UDP/driver/page-table risks against current Linux and Limine contracts.

| Severity | Finding | Resolution / status |
|---|---|---|
| P0 | `CLONE_VM` tasks shared one `page_table_phys`, but every zombie/exec cleanup unconditionally destroyed that root. One thread exit could free page tables still used by another CPU. | Fixed: retain the PML4 root for each shared task and release it on every cleanup path; only the last reference performs batched deep teardown. Exec installs and switches to the new CR3 before releasing the old root. The O(1) PMM root reference is touched only at clone/exec/reap boundaries. |
| P1 | Limine requests had no official start/end markers and therefore relied on whole-image request scanning. | Fixed: add bundled-Limine-compatible markers and linker `KEEP` ordering around `.limine_reqs`. ELF inspection confirms `start < requests/base revision < end` in the writable, loadable `.data` segment. |
| P1 | `timerfd_settime` accepted negative, out-of-range, or overflowing `timespec` fields via signed-to-unsigned bit reinterpretation. | Fixed: reject invalid nanoseconds, negative fields, unknown flags, nanosecond/tick conversion overflow, and expiry addition overflow with `EINVAL`; periodic rearm saturates instead of wrapping. |
| P1 | IPv4 socket `connect`, socket-name output, `socketpair`, `recvmmsg` length output, `epoll_wait`, and `select` ignored short user copies. | Fixed: require complete copies, return `EFAULT`, prevalidate epoll output before consuming ready state, and close newly-created socketpair descriptors when output fails. |
| P1 | Raw network syscalls passed user pointers directly into NIC/UDP code, bypassing the shared mapped-range checks. | Fixed: bounded kernel staging buffers isolate NIC/UDP operations from user page-table lifetime; UDP receive now accepts caller capacity and validates payload/source outputs before dequeue. |
| P1 | x86 COW clone has early OOM exits after partial child page-table construction; later failures can also leave parent PTEs COW-marked with unmatched references. | Fixed (round 6.34): both clone walks (`fork.zig cloneUserPagesCow`, `clone.zig cloneUserPages`) are now transactional — phase 0 demotes parent huge PDEs (neutral) and counts table pages, phase 1 preallocates them into a pool (failure frees only fresh, unlinked pages), phase 2 downgrades/fills with zero allocations and cannot fail partway. The parent is never left COW-marked for a child that does not exist; `clone.zig` additionally gained the `destroyUserSpace` rollback it lacked. |
| P1 | Raw NIC receive could dequeue a packet before proving the complete user destination was mapped. | Fixed: validate the bounded destination before calling the NIC receive path. |
| P1 | TCP connect/send used generic `-1` for user-copy errors and did not preserve the stream's existing larger-write segmentation path. | Fixed: return `EFAULT` for failed address/data copies and pass bounded multi-segment writes through the existing TCP sender. |
| P1 | `select` accepted malformed timeval values and allowed millisecond conversion overflow. | Fixed: reject `tv_usec >= 1_000_000` and overflowing seconds. |
| P0 | `fsync` returned success after writeback even when NVMe/virtio had no device persistence barrier. | Fixed: flush dirty buffers and call the first filesystem backing device's flush barrier; return `EOPNOTSUPP` when it is unavailable. Filesystem-to-device tracking remains a future extension for additional mounts. |
| P2 | Documentation claimed full `CLONE_FILES` support although clone currently copies the FD table. | Fixed: document the actual copied-table behavior and defer shared-FD semantics. |
| P1 | UDP receive queues still publish/consume entries without a lock or peek/commit token, and current receive APIs may silently truncate to protocol-local storage limits. | Deferred design work: introduce queue serialization, explicit copied/original lengths, `MSG_TRUNC`/`MSG_PEEK` semantics, and commit only after the syscall copy contract is satisfied. |
| P1 | virtio-blk/virtio-net and NVMe queues retain shared mutable submission/completion state without a demonstrated per-queue serialization contract. | Deferred design work: start with correctness-first single-flight locks, then measure before adding multi-queue parallelism. |
| P1 | General `MAP_FIXED` replacement and user-copy prewalk still need a unified ownership/shootdown contract; concurrent unmap remains possible between validation and `@memcpy`. | Bounded anonymous private RW replacement is covered by the exact, fully tracked, PMM-owned 4K and 128-page transactional policy and `hello65`; global address-space locks, fault recovery, TLB shootdown, and broader rollback remain deferred. |
| P1 | Filesystem sync APIs can report completion even when the selected NVMe/virtio device cannot issue a persistence barrier. | Deferred ABI work: propagate unsupported flush capability to sync callers rather than silently promising durability. |

| Gate | Result | Notes |
|---|---|---|
| `zig build test` | Passed | Host helper tests. |
| `zig build` | Passed | x86_64 kernel/userspace and Limine-marked ISO. |
| `zig build -Darch=riscv64` | Passed | riscv64 build. |
| `zig build -Darch=aarch64` | Passed | aarch64 build. |
| `zig build smoke` | Passed | x86_64 single-core reached shell. |
| `zig build smoke-smp` | Passed | x86_64 dual-core reached shell. |
| `zig build -Darch=riscv64 smoke-riscv` | Passed | M7+shared-probe smoke. |
| `zig build -Darch=aarch64 smoke-aarch64` | Passed | M9-7+shared-probe smoke. |
| `readelf -SW` / `readelf -sW` | Passed | Markers and requests are ordered in loadable `.data`. |
| `bash -n tools/*.sh` | Passed | Shell scripts parse successfully. |
| LSP diagnostics | Unavailable | `zls` is not installed; compiler gates were used instead. |

| Gate | Result | Notes |
|---|---|---|
| `zig build test` | Passed | Host helper tests. |
| `zig build` / `-Darch=riscv64` / `-Darch=aarch64` | Passed | All three ISA builds. |
| `zig build smoke` | Passed | x86_64 `hello21 done` + `MoQiOS shell`, `MOQI_SMP=1`. |
| `zig build smoke-smp` | Passed | Same markers with `MOQI_SMP=2`. |
| `zig build -Darch=riscv64 smoke-riscv` | Passed | Includes `[SK-150] tcp l4s ewma prtt dur non-x86: OK`. |
| `zig build -Darch=aarch64 smoke-aarch64` | Passed | Includes `[SK-150] tcp l4s ewma prtt dur non-x86: OK`. |

### 5.2f Review Update: 2026-07-25 (uncommitted-worktree audit)

This pass audited the changes that were staged in the worktree but not yet committed, because they had
never been through a build-and-smoke gate as a set. Scope was the worktree diff plus the call sites it
touched (`fsync`, TCP send, `select`, raw net) and their downstream implementations; it does not claim
proof of absence elsewhere.

| Severity | Finding | Resolution / status |
|---|---|---|
| P0 | `fsync`/`fdatasync` on any ext2/FAT32 file always failed with `-EOPNOTSUPP`. The new barrier call used `block_dev.flush(0)`, but device 0 is virtio-blk registered with `supports_flush = false`, and `block_dev.flush` rejects both unsupported capability and the virtio/NVMe dispatch arms — so every sync returned an error after a successful writeback. | Fixed: added `block_dev.supportsFlush(dev)` and gated the barrier on it. Devices advertising a volatile write cache must complete the flush (failure now maps to `-EIO`, not `-EOPNOTSUPP`); write-through devices treat writeback completion as durable and return 0. |
| P0 | `tcp_syscall.tcpSend` staged a `[65536]u8` bounce buffer on the kernel stack. Kernel stacks are 32 pages (128 KiB), so one syscall frame claimed ~50% of the stack, and every full-window write was copied twice (user → stack → ring). | Fixed by SK-151: `tcp.tcpSendFromUser` copies user data straight into `send_buf`, splitting at the ring wrap. Stack use is now constant, bulk copies drop from 2 to 1, and `send_tail` only advances after both segments land so a partial copy cannot corrupt the valid range. |
| P2 | `probeL4sProbeRttDuration` guarded the `2·base` overflow but computed `base·(8+cuts)` (up to 15·base) in u32 first, so the protection was self-contradictory. | Fixed: 64-bit intermediates, saturating at `u32` max. `shared/sk151.zig` locks a base whose 15× product exceeds u32. |
| P2 | `sendto`/`sendmsg` capped a single TCP send at 1460 bytes through their own stack buffers, forcing one syscall per segment. | Fixed: both route through `tcpSendFromUser`, lifting the per-call limit to the available send window with no bounce buffer. |
| P2 | A 10 MB stray ELF (`test2`) sat untracked in the repository root. | Removed and `.gitignore` widened to `test[0-9]*`. |

Reviewed and accepted unchanged from the same worktree diff: the `select` `nfds` bound moved from a
hard-coded 128 to `vfs.MAX_FDS` (64 on x86_64), which *tightens* the check and keeps the 16-byte
`fd_set` accesses in range; the `timeval` validation correctly rejects out-of-range `usec` and
overflowing `sec·1000`; `raw_net.netRecv` now validates the destination before the irreversible NIC
dequeue; and the `tcp_syscall` error codes moved from `-1` to `-EFAULT`, matching POSIX.

| Gate | Result | Notes |
|---|---|---|
| `zig build` | Passed | x86_64 kernel and userspace. |
| `zig build -Darch=riscv64` | Passed | riscv64 build. |
| `zig build -Darch=aarch64` | Passed | aarch64 build. |
| `zig build smoke` | Passed | x86_64 single-core reached shell (`SMP=1`). |
| `zig build smoke-smp` | Passed | x86_64 dual-core reached shell (`SMP=2`), first attempt. |
| `zig build -Darch=riscv64 smoke-riscv` | Passed | Includes `[SK-151] tcp send user->ring non-x86: OK`. |
| `zig build -Darch=aarch64 smoke-aarch64` | Passed | Includes `[SK-151] tcp send user->ring non-x86: OK`. |
| LSP diagnostics | Unavailable | `zls` is not installed; compiler gates were used instead. |

Residual risk: `vfs.syncFile` still returns `void`, so a writeback error cannot reach `fsync`. The
barrier gate above fixes the false failure but not the inverse false success. Propagating writeback
errors through the VFS sync path remains open P1 follow-up work.

### 5.2g Review Update: 2026-07-25 (mm/proc subsystem audit)

With the worktree clean and pushed, this pass audited the memory-management and process/scheduling
subsystems (`kernel/mm/`, `kernel/proc/`, `kernel/sync/`) for lifetime, race, and untrusted-input
defects. Scope is those directories plus the syscall entry points that reach them.

| Severity | Finding | Resolution / status |
|---|---|---|
| P0 | Lost wakeup between `waitpid` and `exitTask`. `task.waitpid` scans for zombies under `task_lock` and releases it, but `waiting_for_child` was published outside any lock afterwards. A child exiting in that window read the flag as false, skipped the wake, and the parent then blocked forever with a reapable zombie sitting there. | Fixed: publish the flag, then rescan before blocking. `exitTask` sets `.zombie` and reads the flag in one `task_lock` section and the rescan takes the same lock, so either the child sees the flag or the rescan sees the zombie. |
| P0 | `sigreturn` dereferenced `saved_user_rsp` directly. Any process can set RSP freely and invoke syscall 15, so an unmapped RSP faulted inside the kernel — fatal, since there is no per-syscall recovery — and an RSP pointing at kernel memory copied that memory into user-visible registers. | Fixed: the frame is copied in through `copyFromUser`; a bad range returns `-EFAULT` and leaves register state untouched. The unused `popSignalFrame` had the same pattern and was converted too, so it is not a trap for the next caller. |
| P1 | `cloneUserPages` / `cloneUserPagesCow` abandoned every page table and leaf page allocated so far when they hit OOM mid-walk, and `fork` did not release a completed child root when `createUserProcess` then failed (`clone` already did). | Fixed: both clone paths roll back through `destroyUserSpace`, which tolerates a partial tree and whose batched frees also undo the COW `addRefBatch` increments. `fork` now mirrors `clone`. |

Verified as safe and deliberately left alone: `validateUserRange` avoids `addr + len` overflow by
subtraction; `dequeueSignal` masks bit 31 before indexing `signal_handlers[31]`; `sched.timerTick`
releases `sched_lock` before taking `task_lock`, matching the documented lock order; and the per-CPU
work-stealing path takes its two locks in CPU-ID order. No function in these directories declares a
stack array above 4 KiB — the largest are ~2 KiB.

No SK probe was added for this round. All three defects are x86-specific control-flow and lifetime
bugs with no pure-function core, so a cross-architecture marker would assert nothing about them.

| Gate | Result | Notes |
|---|---|---|
| `zig build test` | Passed | Host helper tests. |
| `zig build` / `-Darch=riscv64` / `-Darch=aarch64` | Passed | All three ISA builds. |
| `zig build smoke` | Passed | x86_64 single-core reached shell. |
| `zig build smoke-smp` | Passed | x86_64 dual-core reached shell. |
| `zig build smoke-smp-stress` | Passed | 5 consecutive dual-core runs reached shell. Closest available gate to the waitpid race. |
| `zig build -Darch=riscv64 smoke-riscv` | Passed | SK-151 markers. |
| `zig build -Darch=aarch64 smoke-aarch64` | Passed | SK-151 markers. |

Residual risk: the smoke gates exercise `fork`/`waitpid` on every shell command, but they cannot
schedule the exact interleaving the waitpid fix targets, and they never drive the clone paths to OOM.
Both fixes rest on the lock-ordering argument above rather than on a reproduced failure.

Open follow-ups found in this pass but deliberately not changed yet, since each needs a semantic
decision rather than a local fix:

| Severity | Finding | Why deferred |
|---|---|---|
| ~~P1~~ | ~~`clone(CLONE_SETTLS)` calls `wrmsr(FS_BASE)` in the parent's syscall context, so it overwrites the parent's TLS instead of the new thread's.~~ | **Resolved in 5.2m** — `Task.tls_base` plus an install on every switch to a user task. The scope was wider than recorded here: nothing saved `FS_BASE` per task, so the stray base also outlived the `clone` on that CPU. |
| P1 | Non-`MAP_FIXED` `mmap` and `brk` growth map over existing mappings without unmapping, leaking the old frames. `rangeAvailable` already exists but is unused by `mmap`. | Rejecting or unmapping overlaps changes `mmap`/`brk` semantics; needs a decision on which behaviour userland expects. |
| P1 | `vfs.syncFile` returns `void`, so a writeback error cannot reach `fsync` (carried over from 5.2f). | Requires threading errors through the VFS sync path. |
| P2 | A process's 65th `mmap` region is untracked, so `munmap`/`mprotect` cannot find it. | Should return `ENOMEM`; needs a check on whether callers tolerate that. |
| P2 | File-backed `mmap` ignores the `read` return value, mapping zeroes instead of reporting failure. | Small, but changes the error contract of `mmap`. |

### 5.2h Review Update: 2026-07-25 (fs/block-device subsystem audit)

This pass audited `kernel/fs/` and `kernel/drivers/` for lifetime, bounds, overflow, and
silent-error-swallowing defects, with particular attention to indices derived from on-disk data.

| Severity | Finding | Resolution / status |
|---|---|---|
| P0 | `writeBuffered` truncated any write to one 4 KiB buffer and returned `void`, while the VFS advanced the descriptor by the full `count`, grew `file_size`, and reported success. The plain `write()` syscall chunks to 4096 before reaching the VFS and is unaffected, but `copy_file_range(2)` and `splice(2)` pipe→file both push 8 KiB chunks, so the second half of every chunk was silently dropped. | Fixed by SK-152: `writeBuffered` splits across page-sized extents and returns bytes accepted; the VFS advances by that value and reports `ENOSPC` when the pool is exhausted. The 8 KiB chunk sizes are kept, so the I/O batching benefit is unchanged. |
| P1 | Re-writing a shorter run at an offset that already held a longer extent overwrote `data_len` downwards, discarding the still-dirty tail before it reached the disk. | Fixed: `data_len` is now a high-water mark, since only the leading `len` bytes are replaced. |

Reported by the audit but **not confirmed** — recorded here so the next pass does not re-litigate them:

- The claim that any `write()` above 4 KiB loses data overstated the reach of the P0 above.
  `file_io.zig`, `readv.zig`, `aio.zig`, and the `writev` arm of the syscall dispatcher all chunk to
  4096 through a kernel bounce buffer and honour short writes, so the plain write path was correct.
- `io_sched.tryMerge` was reported as producing a DMA range that outruns its buffer.
  **Resolved in round 6.32**: verified by inspection — the merge extends the LBA range but
  keeps the original buffer pointer, so the combined DMA range indeed outruns the buffer.
  The layer was unreachable in practice (`submitRequest`/`dispatchNext` had no callers);
  NCQ hardware queueing supersedes a software elevator on SATA, so `io_sched.zig` was
  removed outright along with the AHCI registration.

Still open from the audit and worth a dedicated round, in rough priority order: the ext2 block-group
descriptor table is read into a single 4 KiB page, so a volume with more than 128 groups overflows it;
`readInode` derives a group index from an on-disk inode number without an upper bound; ext2 directory
parsing does not validate `rec_len`/`name_len` against the block size; `getdents64` advances the
directory offset past entries it did not return when the user buffer fills; and both FAT32 and ext2
write paths discard `writeBlockUncached`/`safeWriteSectors` return values while still updating
metadata. These are all on-disk-data or error-propagation issues that need their own verification
rather than a quick patch.

| Gate | Result | Notes |
|---|---|---|
| `zig build test` | Passed | Host helper tests. |
| `zig build` / `-Darch=riscv64` / `-Darch=aarch64` | Passed | All three ISA builds. |
| `zig build smoke` | Passed | x86_64 single-core reached shell. |
| `zig build smoke-smp` | Passed | x86_64 dual-core reached shell. |
| `zig build -Darch=riscv64 smoke-riscv` | Passed | Includes `[SK-152] writeback multi-page write non-x86: OK`. |
| `zig build -Darch=aarch64 smoke-aarch64` | Passed | Includes `[SK-152] writeback multi-page write non-x86: OK`. |
| `bash -n tools/*.sh` | Passed | Smoke scripts parse. |

### 5.2i Review Update: 2026-07-25 (ext2 on-disk descriptor layout)

This pass took up the ext2 untrusted-on-disk-data group left open by 5.2h. Verifying the block-group
descriptor table by hand against the shipped image turned up a defect more serious than the one that
was queued: the descriptor struct did not match the on-disk layout at all.

| Severity | Finding | Resolution / status |
|---|---|---|
| P0 | `Ext2GroupDesc` modelled only the 18 meaningful bytes and omitted `bg_pad`/`bg_reserved[3]`, so `@sizeOf` was 20 while the on-disk stride is 32. Every descriptor after the first was read 12 bytes short of where it lives: on the shipped test image `gds[1].bg_inode_table` came out as 0 instead of 0x2044, so every inode in group 1 (inode 65 and up, at 64 inodes per group) resolved its inode table to block 0 and read unrelated disk content. `writeGroupDescs`, which sizes its transfer from the same `@sizeOf`, wrote the table back with the 20-byte stride and so overwrote group 1's real on-disk descriptor. | Fixed: the struct now carries the pad and reserved words and is exactly 32 bytes, which corrects all eight indexing sites, `bgdt_size`, and the write-back length at once. `GROUP_DESC_SIZE` records the on-disk stride, and SK-153 pins both. |
| P1 | The descriptor table was read into a single `allocPage()`, which holds 128 descriptors, so a volume with more block groups ran off the end of the allocation. The read also issued one transfer whose sector count can exceed the 128-sector limit virtio-blk enforces, which would have failed the mount outright. | Fixed: the table is allocated with `allocContiguous` sized to the real table, and `readSectorRun` splits the transfer into driver-sized chunks. |
| P1 | `readInode`, `writeInode`, and `freeInode` derived a group index from an inode number with no upper bound, and `freeBlock` did the same for a block number. Both numbers reach these functions from on-disk directory entries and inode block pointers, so a corrupt image could index the descriptor table past its end; inode 0 and a block below `first_data_block` additionally underflowed the `u32` subtraction. | Fixed: `groupForInode` and `groupForBlock` are the single validation entry points, and the four callers now bail out instead of indexing. |

The shipped `disk.img` carries a 2-group ext2 volume (16384 blocks at 8192 per group, 64 inodes per
group), so the P0 was live rather than latent on any file that landed in group 1.

SK-153 was negative-controlled: with the pad fields removed again it reports
`[SK-153] FAILED: stride` and fails the riscv64 smoke gate, so the marker constrains the layout
rather than merely asserting it.

Still open from 5.2h, unchanged by this pass: ext2 directory parsing does not validate
`rec_len`/`name_len` against the block size; `getdents64` advances the directory offset past entries
it did not return when the user buffer fills; and both FAT32 and ext2 write paths discard
`writeBlockUncached`/`safeWriteSectors` return values while still updating metadata.

| Gate | Result | Notes |
|---|---|---|
| `zig build` / `-Darch=riscv64` / `-Darch=aarch64` | Passed | All three ISA builds. |
| `zig build smoke` | Passed | x86_64 single-core reached shell; exercises the 2-group ext2 volume. |
| `zig build smoke-smp` | Passed | x86_64 dual-core reached shell. |
| `zig build smoke-smp-stress` | Passed | 5 consecutive dual-core runs reached shell. |
| `bash tools/qemu_smoke_riscv64.sh` | Passed | Includes `[SK-153] ext2 group desc stride non-x86: OK`. |
| `bash tools/qemu_smoke_aarch64.sh` | Passed | Same marker. |
| SK-153 negative control | Passed | Reverting the struct fix turns the marker to `FAILED: stride`. |

### 5.2j Review Update: 2026-07-25 (ext2 directory records, getdents64 resume)

This pass closed the two remaining items from 5.2h: validating on-disk directory records, and the
`getdents64` resume offset.

| Severity | Finding | Resolution / status |
|---|---|---|
| P1 | All five directory walkers cast `buf + pos` to an 8-byte header knowing only `pos < block_size`, so a record near the end of a block read up to 7 bytes past it; copied `name_len` (up to 255) bytes after the header without checking they stayed in the block, which leaks adjacent memory into a returned filename; and advanced by an unchecked `rec_len`, which can leave `pos` unaligned and make the `@alignCast` in the next iteration invalid. | Fixed: `eu.readDirEntry` is the single validated entry point and every read-side walker goes through it. It reads fields as explicit little-endian bytes, so it is correct at any alignment, and rejects a record whose header would leave the block, whose position or `rec_len` is not 4-aligned, whose `rec_len` cannot hold its own name, or which extends past the block. |
| P1 | `addDirEntry` computed the splittable gap as `last_entry.rec_len - actual_len` on an unvalidated `rec_len`. A `rec_len` smaller than the record's own header plus name made that `u16` subtraction wrap to a huge gap, which passed the `wasted >= aligned_len` test and wrote a new record past the end of the block — an out-of-bounds *write*, not just a read. | Fixed: the gap is computed from a validated record and clamped to 0. The walk also now distinguishes "no valid record in this block" from "first record at offset 0", which previously split on whatever bytes happened to be there. |
| P1 (latent) | `getdents64`'s ext2 arm set the resume offset from the last entry `readDirEntries` *produced* rather than the last one copied to the user, so every entry that did not fit the buffer was skipped for good and a short-buffer walk silently returned a truncated directory. | Fixed: the offset now comes from the last entry actually emitted. Latent rather than live: the VFS has no path that returns a descriptor for an ext2 directory, so this arm is currently unreachable from user space (hello29 confirms `open` fails for `/`, `.`, and a directory created by `mkdir`). |
| P2 | Both arms returned 0 when the buffer was too small for even the first entry, which a caller reads as end of directory, and both ignored `copyToUser`'s result, reporting success and advancing the offset after a copy that wrote nothing. | Fixed: a buffer too small for the next entry is `EINVAL`, a failed copy is `EFAULT`, and neither advances the offset. |

`user/hello29.c` is a new init self-test: it creates six files in a tmpfs directory, then walks it once
with a buffer that takes every entry and once with a buffer that takes one at a time, and fails if the
two counts differ. `hello29: PASS` is now a required marker in the x86_64 smoke gate.

Two honest limits on this round's verification:

- The ext2 resume fix is reasoned, not runtime-verified, because that code path cannot be reached from
  user space today. hello29 covers the tmpfs arm, which was already correct on the resume offset; what
  it does newly cover there is the `EINVAL`/`EFAULT` behaviour.
- SK-154 pins four of the five rules in `readDirEntry` — a host-side attribution run confirmed each of
  `pos` alignment, `rec_len` alignment, `rec_len` minimum, and `rec_len` fit is individually the sole
  reason its fixture case is rejected. The fifth (header fits in the block) cannot be pinned by any
  return-value test: once `rec_len` must be at least 8 and must fit before the block end, a header near
  the end is rejected anyway. That check exists to prevent the out-of-bounds read itself, which the
  probe cannot observe.

While writing hello29 the one-page user stack surfaced as a practical constraint worth recording: a
`char buf[4096]` local makes the buffer straddle the bottom of the single mapped stack page, so
`copyToUser` correctly refuses it. That is what the new `EFAULT` return reports; the old code would
have called it a success with nothing written. A user program therefore cannot pass a full 4 KiB
stack buffer to `getdents64`, and the internal `@min(buf_size, 4096)` clamp is never reached from a
stack buffer.

| Gate | Result | Notes |
|---|---|---|
| `zig build test` | Passed | Host helper tests. |
| `zig build` / `-Darch=riscv64` / `-Darch=aarch64` | Passed | All three ISA builds. |
| `zig build smoke` | Passed | Now gated on `hello29: PASS`; also exercises `mkdir`/`unlink`, which use the two rewritten write-side walks. |
| `zig build smoke-smp` | Passed | x86_64 dual-core reached shell. |
| `zig build smoke-smp-stress` | Passed | 5 consecutive dual-core runs. |
| `bash tools/qemu_smoke_riscv64.sh` | Passed | Includes `[SK-154] ext2 dir record validation non-x86: OK`. |
| `bash tools/qemu_smoke_aarch64.sh` | Passed | Same marker. |
| SK-154 rule attribution | Passed | Host-side run confirming 4 of 5 rules are individually pinned; the fifth is not observable (above). |

### 5.2k Review Update: 2026-07-25 (write-error propagation, fsync)

This pass took up the last item from 5.2h — write paths discarding their return values — and following
it up the call chain turned up that the chain had no way to carry an error even if it had one.

| Severity | Finding | Resolution / status |
|---|---|---|
| P1 | `ext2.writeFile` discarded both `writeBlockUncached` results while still advancing `written` and updating the inode size, and `fat32.writeFile` did the same with three `safeWriteSectors` calls. A failed device write was therefore reported to the caller as bytes successfully written. Because these are the writeback flush callbacks, the cache then cleared the dirty bit and dropped the only copy of the data. | Fixed: both loops stop at the first failed write so the returned count covers only bytes that reached the disk, and a failed inode write reports failure rather than leaving an on-disk size that strands the data. |
| P1 | `fat32.writeFile` grew the file to `offset + count` rather than `offset + bytes_written`, so a loop that stopped early (out of clusters, or now a failed write) still published a size covering bytes that were never written. | Fixed: the size follows the bytes actually written. |
| P1 | `flushFile` and `flushAllByType` returned `void`. They already restored the dirty bit when a write failed, so the information existed and was thrown away: `syncFile`, `syncAll`, `fsync`, `sync`, and `msync` all reported success no matter what. | Fixed: both return whether every buffer was written, `syncFile`/`syncAll`/`invalidateFile` propagate it, and `fsync`/`msync` return `EIO`. `close` also reports `EIO` when the final flush failed, while still releasing the descriptor as POSIX requires. |
| P1 | `aio`'s own flush callbacks ignored the write result and returned `true` unconditionally, so an AIO fsync always claimed success and the cache dropped the buffer even when the write failed. | Fixed: they require the full length to be accepted, and `io_submit`'s fsync arm returns `EIO`. |
| P1 | The live `fsync(fd)`/`fdatasync(fd)` (syscalls 74/75) ignored the descriptor entirely, called `syncAll()`, and returned 0 unconditionally — no error reporting, no descriptor validation, and every dirty buffer of both filesystems flushed to sync one file. | Fixed: they now go through `syscallFsync`, which validates the descriptor, flushes only that file, and reports `EIO`. |
| P1 | `syscallFsync` looked the writeback buffers up with `desc.ext2_file_idx` for FAT32 descriptors too. The two filesystems have separate index spaces and the write path stages FAT32 buffers under `fat32_file_idx`, so `fsync` on a FAT32 file flushed a different file's buffers — usually none, since the field is 0 — and returned success. | Fixed: the index is selected by descriptor type. |

`hello29` gained fsync coverage: it writes a file, calls `fsync` on it, and calls `fsync` on an unused
descriptor, asserting 0 and `EBADF`. That guards the 74/75 rewrite, which previously could not fail.
`hello29: fsync PASS` is now a required marker in the x86_64 smoke gate.

SK-155 drives `flushFile` with a callback that fails and then one that succeeds, checking the returned
status, that the callback ran, and that a failed flush leaves the buffer dirty. Unlike SK-154's
header-bounds rule, there is no redundancy question here: the probe asserts the return value that the
fix introduced, so dropping the `all_ok = false` assignment makes it report
`failure reported as success`. SK-46 now also checks `flushFile`'s status on its success path.

Not verified at runtime: the `EIO` paths themselves, which need a failing block device to reach. The
smoke run confirms the success paths still return 0 and that descriptor validation works.

| Gate | Result | Notes |
|---|---|---|
| `zig build test` | Passed | Host helper tests. |
| `zig build` / `-Darch=riscv64` / `-Darch=aarch64` | Passed | All three ISA builds. |
| `zig build smoke` | Passed | Now also gated on `hello29: fsync PASS`. |
| `zig build smoke-smp` | Passed | x86_64 dual-core reached shell. |
| `zig build smoke-smp-stress` | Passed | 5 consecutive dual-core runs. |
| `bash tools/qemu_smoke_riscv64.sh` | Passed | Includes `[SK-155] writeback flush error propagation non-x86: OK`. |
| `bash tools/qemu_smoke_aarch64.sh` | Passed | Same marker. |

### 5.2l Review Update: 2026-07-25 (brk/mmap address-space coherence)

This pass took up the deferred `mm/proc` item — `mmap` and break growth mapping over existing mappings —
and found the reason nobody had noticed: neither call worked at all for the C user programs. No user
program had ever called `brk` or `mmap`, so `hello30` is the first caller, and it exposed the whole
cluster in one run.

The root cause is an address-space layout that drifted apart from the range checks written for it.
`USER_CODE_BASE` (4MB) and `USER_STACK_TOP` (8MB) describe the flat-binary layout, where the heap grows
from the code up toward the stack. ELF images carry their own load addresses and the C programs link at
16MB — *above* the stack — so their heap grows upward with the stack far below. Every check of the form
"the heap must stay under `USER_STACK_TOP`" is therefore not merely conservative but inverted for ELF.

| Severity | Finding | Resolution / status |
|---|---|---|
| P0 | `brk` rejected any address at or above `USER_STACK_TOP - PAGE` (0x7FF000). For ELF images the initial break is already ~0x1002000, so *every* growth request was refused and the syscall returned the unchanged break — indistinguishable from success for a caller that does not compare, and there is no way for a program to grow its heap. Confirmed before the fix: `brk(0)=0x1002000`, `grow=0x1002000`. | Fixed: the break may move anywhere in `[brk_start, ceiling]`. Flat binaries keep the old stack-relative ceiling, since for them the heap really does grow toward the stack; ELF images use `USER_HEAP_MAX` (4GB). |
| P0 | The growth loop ran `for (old_page..new_page)` unconditionally, so shrinking the break reversed the range. Zig computes the length as `new_page - old_page` on `usize`, which panics the kernel on integer overflow in a Debug build (and would run away in a release build). Reachable from user space by any program that shrinks its break, which is what `free` does. Masked for ELF images only because the check above refused to grow in the first place — flat binaries could reach it today. | Fixed: growth, shrink and no-op are separate branches, and shrinking releases the pages it gives back. Negative control: restoring the reversed range produces `!!! KERNEL PANIC !!! message: integer overflow` and fails the smoke gate. |
| P1 | The break never zeroed the pages it added. `pmm.allocPage` returns frames as-is — `mmap` zeroes explicitly and says why — so a growing heap handed the process whatever the previous owner left in those frames. | Fixed: pages are cleared before they become reachable. Negative control: removing the `@memset` makes `hello30` report `FAIL (heap page not zeroed/writable)`, i.e. the stale data is real and observable, not theoretical. |
| P1 | Both `brk` growth and non-`MAP_FIXED` `mmap` called `mapPage` over whatever was already mapped. `mapPageInner` overwrites a live PTE without complaint, so the old frame was stranded with no remaining reference and the caller's mapping was silently replaced. | Fixed: `brk` refuses to grow across a mapped page, and `mmap` checks the range before honouring a hint. |
| P1 | `mmap` treated a non-`MAP_FIXED` `addr` as binding. POSIX makes it advisory, and honouring it unconditionally let a process destroy its own text: `mmap(&_start, ...)` without `MAP_FIXED` replaced the page it was executing from. | Fixed: the hint is taken only when the range is free, otherwise the kernel picks a free range. Negative control: forcing the hint kills `hello30` with a segfault, exactly as predicted. |
| P1 | `mmap`'s own ceiling check (`base + len >= stack_base`) had the same inversion, so with `base` taken from `brk_current` every anonymous `mmap` returned `ENOMEM`. `rangeAvailable` and `findFreeMmapRange`, which back `mremap`, carried it too. | Fixed: bounds are relative to `USER_ADDR_MAX`, and kernel-chosen placements come from a dedicated window. |
| P2 | Non-fixed `mmap` dragged `brk_current` up past its placements. Combined with the shrink support added here, `brk(0)` would report a break spanning memory the heap does not own, and shrinking would hand those `mmap` pages back to the allocator. | Fixed: `mmap` no longer moves the break. Kernel-chosen placements now come from `USER_MMAP_BASE` (8GB), above both the heap ceiling and the stack's demand-grow window, so the two regions cannot compete. |

`brk_start` is a new `Task` field recording where the loader left the break, so a shrink cannot walk down
into the loaded image and unmap it. It is set on both loader paths and in both `execve` arms, and
inherited across `fork`. Task slots are zeroed on allocation, so a task with no loader-established heap
has `brk_start == 0` and `brk` declines to move it.

`hello30` covers all five properties: the break grows to the requested address, fresh heap pages read as
zero and are writable, the break shrinks without panicking, anonymous `mmap` returns usable zeroed pages
that `munmap` releases, and a hint aimed at the program's own code is placed elsewhere with the code left
intact. `hello30: brk/mmap PASS` is now a required marker in the x86_64 smoke gate — the three negative
controls above all passed the gate before the marker was added, so the gate needed it.

No shared probe: `brk` and `mmap` need a live user address space, which the riscv64/aarch64 ports do not
have yet, so a probe there could only assert against a fixture and would not exercise the fix.

Not verified: the `mremap` paths that `rangeAvailable`/`findFreeMmapRange` back. Their bounds were
corrected alongside the rest, but no user program calls `mremap`, so this is reasoned rather than
runtime-verified. Worth an `mremap` test in a later pass.

| Gate | Result | Notes |
|---|---|---|
| `zig build` / `-Darch=riscv64` / `-Darch=aarch64` | Passed | All three ISA builds. |
| `zig build smoke` | Passed | Now also gated on `hello30: brk/mmap PASS`. |
| `zig build smoke-smp` | Passed | x86_64 dual-core reached shell. |
| `zig build smoke-smp-stress` | Passed | 5 consecutive dual-core runs. |
| `bash tools/qemu_smoke_riscv64.sh` | Passed | Shared probes unaffected. |
| `bash tools/qemu_smoke_aarch64.sh` | Passed | Same. |

### 5.2m Review Update: 2026-07-25 (per-task TLS base, and the yield path it uncovered)

This pass took up the last deferred `mm/proc` item — `CLONE_SETTLS` writing `FS_BASE` in the parent's
context. The write itself was the smaller half of the problem. `Task` had no field for a TLS base, the
context switch never touched `FS_BASE`, and there was no `arch_prctl`, so that one `wrmsr` in `clone` was
the only user `FS_BASE` write in the kernel. The base was therefore a property of the *CPU*, not of the
thread.

| Severity | Finding | Resolution / status |
|---|---|---|
| P1 | `clone(CLONE_SETTLS)` programmed `FS_BASE` on the CPU running the *caller*. The parent began reading the child's TLS block through `%fs`, and the child — the thread the flag names — got whatever base happened to be loaded. Both threads end up with the wrong TLS, so `errno`, thread-locals and any `%fs`-relative slot silently address another thread's block. | Fixed: `clone` records the base on the child and the scheduler installs it. |
| P1 | Because nothing saved or restored `FS_BASE` per task, the stray base outlived the `clone`: it stayed on that CPU for every task scheduled afterwards, including tasks in unrelated address spaces. Paging still confines each task to its own memory, so this is corruption at an attacker-influenced offset rather than a cross-process leak — a task's `%fs` accesses land wherever the last `CLONE_SETTLS` caller pointed. | Fixed: `setupUserCpuState` installs `t.tls_base` on every switch to a user task, so a task with no TLS gets 0 instead of inheriting its predecessor's base. |
| P1 | On x86, `sched.forceReschedule()` drove the scheduler by `call`, from whatever stack it was on. The scheduler hands a CPU over by rewriting the per-CPU stack anchor and loading the next task's CR3, and only an *interrupt return* consumes that anchor. Called from a syscall the handover half-happened: CR3 became the next task's while the syscall still returned through `sysretq` on its own stack, so the caller resumed **in another task's address space** — and with no user mappings at all when that task was a kernel one. | Fixed: `forceReschedule` raises a synchronous yield trap (vector 252) so the switch happens on a real interrupt frame. |
| P1 | The smoke gate passed a run in which a task was killed by a segfault, because the gate only looked for each test's PASS marker and the victim was an unrelated task. | Fixed: a run containing `[SEGFAULT]` or `KERNEL PANIC` now fails the gate even when every marker is present. |

`tls_base` is a new `Task` field. `clone` sets it from the `CLONE_SETTLS` argument and otherwise copies the
parent's; `fork` inherits it, since the child's address space is a copy and its TLS block is at the same
address; `execve` clears it and also programs 0 on the CPU, because `execve` returns straight to user space
without passing through the scheduler and the stale base would otherwise survive into the new image. The
install is one arch hook, `syscall.setUserTlsBase`, and it skips the `wrmsr` when the requested base is
already loaded on this CPU — almost every task has no TLS, so the common path costs a compare.

`arch_prctl(code, addr)` is new (syscall 472) and supports `ARCH_SET_FS`/`ARCH_GET_FS`. Without it a
program had no way to establish TLS at all, and the fix had no user-space entry point to test through.
`ARCH_SET_GS`/`ARCH_GET_GS` return `EINVAL`: `GS` holds this kernel's per-CPU pointer, so letting user
space program it would hand it the kernel's own base at the next `swapgs`.

The yield bug is the more serious find and was not reachable before this pass: no user program had ever
called `sched_yield`, and `hello31` needs it to let the other process run. It is not specific to
`sched_yield` — every `forceReschedule` caller (futex wait, SysV semaphores, `ipc`, blocking `flock`,
`pause`) went through the same path, so all of them could return to user space with the wrong CR3 loaded.
The fix is in `forceReschedule` itself rather than at the call sites. Vector 252's gate has DPL 0, so user
space attempting the same `int` gets `#GP`; the handler deliberately skips the LAPIC EOI, since nothing was
delivered.

`hello31` establishes a TLS block, checks `%fs` actually reaches it, forks, and has each process stamp a
distinct value through its own base and read it back after the other has run. Both `hello31: TLS PASS` and
the child's `hello31: child TLS ok` are required smoke markers.

Negative controls, both of which now fail the gate:

- Dropping the `setUserTlsBase` call from the switch path: the parent segfaults reading `0x200001000` —
  the *child's* TLS page, which does not exist in the parent's address space. The fault address shows the
  mechanism directly, not just a failed assertion.
- Restoring the direct `timerTick(getAnchor())` call in `forceReschedule`: the segfault returns, reported
  against a kernel task with `page_table_phys == 0` while CR3 held the kernel PML4 (`pml4e = 0` for the
  faulting user address). This control is also what showed the old gate was too weak — it passed.

Found and deferred: `cloneUserPagesCow` (and `cloneUserPages`) copy PTE flags as `pte & 0xFFF`, which drops
`NX` at bit 63. Every forked child therefore loses `NX` on the pages that had it, including its heap. The
fix is small but wants a test that asserts an execution fault, which the new "no segfaults" gate rule makes
awkward to express; both need designing together rather than rushing the flag change in here.
**Resolved in 5.2n** — the derivation moved to a shared helper and is unit-tested. End-to-end enforcement
remains untested for the reason recorded there: faults kill instead of raising `SIGSEGV`.

| Gate | Result | Notes |
|---|---|---|
| `zig build` / `-Darch=riscv64` / `-Darch=aarch64` | Passed | All three ISA builds. |
| `zig build test` | Passed | Unit tests. |
| `zig build smoke` | Passed | Now also gated on the two `hello31` markers, plus the no-segfault/no-panic rule. |
| `zig build smoke-smp` | Passed | x86_64 dual-core reached shell. |
| `zig build smoke-smp-stress` | Passed | 5 consecutive dual-core runs. |
| `bash tools/qemu_smoke_riscv64.sh` | Passed | `setUserTlsBase` is a documented no-op there. |
| `bash tools/qemu_smoke_aarch64.sh` | Passed | Same. |

### 5.2n Review Update: 2026-07-25 (COW clone dropped NX)

This pass took the item 5.2m deliberately left open: the COW clone derived the child's page-table entry as
`phys | (pte & 0xFFF)`. `NX` is bit 63, above the address field rather than among the low permission bits,
so the mask dropped it.

Measured before the fix, by counting entries whose parent had `NX` and whose child did not:

```
[nx] parent_pte=0x80000000002e4067 child_pte=0x00000000002e4265
[nx] lost=3 kept=0
```

Not a single non-executable page survived a `fork`. Every child got a writable *and* executable stack and
heap — the W^X property the mappings were created with (`mmap`, `brk` and the stack all pass
`no_execute = true`) held only until the process forked. `EFER.NXE` is enabled (measured: `EFER=0xd01`), so
this was a real loss of enforcement rather than a cosmetic flag difference.

| Severity | Finding | Resolution / status |
|---|---|---|
| P1 | `cloneUserPagesCow` and `cloneUserPages` rebuilt the child's entry from the frame plus the low 12 bits, dropping `NX` at bit 63. Parent and child are supposed to hold the *same* entry, and the parent's side was written as `(pte & ~WRITABLE) \| COW` — preserving the high bits — so the two sides disagreed and only the reconstructed one was wrong. | Fixed: both sides derive the entry from one helper, `cow_pte.cowPte`. Measured after: `[nx] lost=0 kept=3`. |

The asymmetry was the bug's cause, so the fix removes it rather than adding the missing bit to the second
expression. `kernel/mm/cow_pte.zig` is a small import-free module holding the derivation, which also makes
it host-testable; `tests/main.zig` covers that `NX` survives, that the frame is shared read-only with the
COW marker set, that present/user survive, and that re-cloning an already-shared entry is idempotent. One
test states the regression directly by asserting that the low-12-bit rebuild loses `NX` where `cowPte` does
not. Negative control: restoring the old derivation inside `cowPte` fails that test.

The two other readers of the COW bit — both arms of `handleCowFault` — were already correct: they mask out
only the address field and the COW marker, so `NX` survives fault resolution.

Not verified: end-to-end enforcement, i.e. that executing from a data page in a forked child actually
faults. The blocker is that the kernel kills on a user fault instead of delivering `SIGSEGV`, so a test
program cannot survive the fault to report what happened, and the smoke gate now (correctly) fails any run
containing `[SEGFAULT]`. Synchronous fault signal delivery is the missing feature; it would let this and
similar properties be asserted from user space, and is the natural next item.

| Gate | Result | Notes |
|---|---|---|
| `zig build` / `-Darch=riscv64` / `-Darch=aarch64` | Passed | All three ISA builds. |
| `zig build test` | Passed | Includes the new `cow_pte` tests. |
| `zig build smoke` / `smoke-smp` | Passed | Single and dual core. |
| `zig build smoke-smp-stress` | Passed | 5 consecutive dual-core runs. |
| `bash tools/qemu_smoke_riscv64.sh` / `_aarch64.sh` | Passed | Neither port forks user processes yet. |

### 5.2o Review Update: 2026-07-25 (synchronous SIGSEGV delivery — fixing the delivery path itself)

This pass picked up the item 5.2n left open. The working tree already held an unfinished change making a
user page fault deliver `SIGSEGV` to a registered handler instead of killing outright, together with a test
(`user/hello32.c`). The test was never wired into `init.S` / `qemu_run.sh`, so it had never run. Wiring it up
showed the feature did not work at all: the child still took `[SEGFAULT] User process killed`, after which
the machine stopped producing output entirely.

Both root causes are pre-existing defects that the new feature merely ran into, and both were located from
measured diagnostic output rather than inferred.

| Severity | Finding | Resolution / status |
|---|---|---|
| P0 | `deliverSignalToRunningTask` tested `iframe.cs != 0x1B` to decide "is this frame returning to user mode". The GDT defines *two* user code selectors: `USER_CS = 0x1B` for `iretq` and `USER_CS_SYSRET = 0x2B` for `sysret`. Anything that has made a syscall runs on `0x2B`, so the test was effectively always false and interrupt-path signal delivery was dead code — not just for the new feature. Measured on the faulting frame: `cs=0x2b`. | Fixed: both selectors are accepted, via the named `gdt` constants rather than a literal. |
| P0 | On a pending signal the timer path released the lock and returned, skipping scheduling. When delivery failed the signal stayed pending, so *every* tick skipped scheduling and the CPU stopped making progress — the hang above. The diagnostic log showed `cs=0x08` repeating without end. | Fixed: the tick path returns only when delivery succeeded, otherwise it re-acquires the lock and reschedules normally. |
| P1 | The in-flight change made `deliverSignalToRunningTask` return `bool` but left the timer-path call site discarding nothing, so x86_64 did not build. | Fixed with an explicit discard; that path has no fallback, a failed delivery simply leaves the signal pending. |
| P2 | The ramdisk packer and kernel parser both capped the image at 32 files. hello32 was the 33rd, so `mkramdisk.sh` refused to build the image — the practical reason the test had not been wired up. The cap backs no static array (the index lives in the blob), so it is only a sanity bound. | Raised to 64 on both sides, kept in sync by comment. |

With these fixed, hello32 reports `null fault handler ok`, `NX exec fault handler ok`, and `SIGSEGV PASS`.
That also closes 5.2n's "not verified" item: the second half of hello32 forks, `mmap`s a writable anonymous
page and jumps into it, and the resulting instruction-fetch fault arrives as a delivered `SIGSEGV` — W^X
across `fork` is now asserted from user space rather than only from a unit test.

Left open: `copy_from_user.isUserAccessible` checks only the `user` bit, not writability, so
`pushSignalFrame` writing a signal frame onto a read-only COW stack page would take a kernel write-protect
fault. The current test does not hit it because its stack page is already un-shared, but the path needs its
own handling. → taken up in 5.2p.

### 5.2p Review Update: 2026-07-26 (read-only user pages — an unprivileged halt, a fork escalation, and W^X)

Taking up what 5.2o left open. The expectation was a one-line writability check on `copyToUser`; what the
measurements actually turned up was four independent defects, all pre-existing. Two hypotheses formed along
the way were disproved and discarded — they are recorded below so the same ground is not re-covered.

First the premise had to be established rather than assumed. The kernel never sets `CR0.WP`, and that bit
decides whether a kernel write to a read-only page faults or silently goes through. Measured at `_start` and
again at the actual copy site: `CR0=0x8001001b`, **WP=1**. So such a write does fault — and the fault handler
already carries a supervisor-mode COW path (`!user_mode and present and write` in `idt.zig`), which means the
COW case 5.2o worried about was in fact already handled.

| Severity | Finding | Resolution / status |
|---|---|---|
| P0 | `copyToUser` validated its destination with `userRangeMapped`, which only asks whether the page belongs to user space. A `mmap(PROT_READ)` page passes, and the kernel's own `@memcpy` then takes a supervisor-mode write-protect fault that lands in `handlePageFault`'s "Kernel-mode fault without guard — fatal" branch. The `checkFault()` recovery was never armed (`recovery_rip` is always 0) and cannot catch it. Any unprivileged process halts the machine with `read(fd, mmap(PROT_READ) page, n)`. | Fixed: new `paging.isUserWritable` (writable **or** COW-marked, the latter faulting into the existing COW path); `copyToUser` uses it. riscv64/aarch64 keep prior semantics — single address space, no COW, no read-only user pages. Negative control: restoring `userRangeMapped` reproduces `EXCEPTION #14 ... write, protection violation in kernel mode` and a 123 s smoke timeout. |
| P0 | `cowPte()` cleared the write bit and set the COW marker on *every* present entry, whether or not it was writable. A read-only page so marked is indistinguishable from a downgraded writable one, and `handleCowFault` keys on that marker alone — granting `WRITABLE` unconditionally. After `fork`, a child's text, rodata and `PROT_READ` pages therefore became writable on first write, quietly lifting the parent's protection. This is why `mmap_ro` (created after the fork, unmarked) was correctly refused while rodata and text were not. | Fixed: `cow_pte.sharedPte` marks only writable pages and returns read-only ones untouched; both clone paths (`fork.zig`, `clone.zig`) use it, and the parent's entry is rewritten (and its TLB shot down) only when it actually changed. |
| P1 | The ELF loader computed `PF_W` and threw it away (`_ = _writable`), mapping every segment `.writable = true` under a comment claiming it was "initially for loading". Nothing ever tightened it, and the rationale does not hold: segment contents are written through the HHDM alias, never through the user mapping. | Fixed: the mapping honours `PF_W`. |
| P1 | `file_io.read` / `pread` advanced `pos` by the bytes read *from the file* rather than the bytes `copyToUser` actually delivered, so a refused copy still reported 7 bytes read and swallowed the `EFAULT`. This actively misled the investigation: the first version of the test judged by return value and was fooled by it. | Fixed: `pos` advances by `written`; a first-chunk failure returns `-EFAULT`; the `pos == 0` single-byte fallback checks its copy too. |

Hypotheses disproved along the way: (1) *WP might be 0, letting kernel writes through silently* — measured
twice, WP=1; (2) *`handleCowFault` might not check the COW bit and so upgrade read-only pages* — line 683
does check it strictly. The real fault was upstream: read-only pages should never have carried the marker.

Verification: three-architecture builds, `smoke` / `smoke-smp` / `smoke-smp-stress`, and the riscv64 and
aarch64 smokes all pass. `user/hello33.c` is new, wired in, and its PASS marker is now a condition of the
x86 smoke. It tests each destination in a **separate forked child** — the first version shared one process,
and the first successful write landed in its own `.text`, so every result after it rested on a corrupted
instruction stream and meant nothing. The verdict rests on whether the destination bytes actually changed,
compared before and after, not on the return value (see the P1 above). A premise check runs first: the child's
own user-mode store to the page must raise `SIGSEGV` (139), otherwise the later cases prove nothing. Result:
`user_store=SIGSEGV (page is read-only)` with `mmap_ro`, `rodata` and `text` all `rejected`. SK-156 pins the
`sharedPte` contract as a pure function on all three architectures; with the read-only guard removed it
reports `FAILED: read-only page was altered` and the smoke fails.

`mprotect` is implemented at the current HEAD. Its validation, resource preflight,
and page-table/VMA mutation form an atomic transaction: rejected requests leave
the target mapping unchanged. `user/hello74.c` provides raw-ABI coverage for
ordinary-page protection changes, invalid-argument rollback, PROT_NONE recovery,
and fork/COW isolation.

The openat2 acceptance boundary is explicit for both native #320 and standard #437:
only `AT_FDCWD` with an existing path and `open_how{flags=0, mode=0, resolve=0}` at
`size >= 24` is supported. `size < 24`, an invalid dirfd, nonzero resolve, unknown flags,
and an invalid how pointer must return `EINVAL`, `EBADF`, `EINVAL`, `EINVAL`, and `EFAULT`;
`user/hello75.c` exercises each case through raw syscalls and closes every successful fd.

### 5.2q Review Update: 2026-07-26 (a refused copy must not consume the data it cannot deliver)

5.2p turned a kernel halt into a clean refusal. But the refusal happens *after* the data has been taken, and
that loose end is what this pass closes.

The kernel has a guard meant to run before an irreversible read — `validateUserBuffer` — used by recvfrom,
recvmsg, epoll_wait, raw_net and the TCP receive path. It calls `userRangeMapped`, which asks only whether
the destination is mapped, never whether it can be written. A read-only destination therefore cleared the
guard, the data came off the pipe or socket, and only then did `copyToUser` refuse it. Pipes and sockets have
no way to put it back, so the bytes were gone.

| Severity | Finding | Resolution / status |
|---|---|---|
| P1 | A read into a read-only destination consumed the data and delivered nothing. Demonstrated deterministically: `user/hello34.c` writes `payload` to a pipe, closes the write end, reads once into a `mmap(PROT_READ)` page and once into a good buffer. Before the fix, `read(ro)=-14 (rejected)` was followed by `read(ok)=0` — the payload had been eaten. (Closing the write end is what keeps the second read from blocking and hanging the smoke.) | Fixed: new `validateUserBufferWritable` checks the destination *before* anything is taken off the fd. `file_io.read`/`pread` and `readv`/`preadv` validate per chunk, so partial-read semantics survive. |
| P1 | `readv` / `preadv` carried the same "advance by bytes read rather than bytes delivered" bug fixed in `file_io` last pass. | Fixed alongside. |

The guard was switched per call site by direction, not globally: `validateUserBuffer` is used for input
buffers too, and requiring writability there would wrongly reject a legitimate read-only argument. Moved to
the writable check: all ten sites in `socket_syscall` (receive destinations and peer-address out-params),
`tcp_syscall`, epoll's `events_buf`, raw_net's receive buffer and its `src_ip`/`src_port` out-params,
`select`'s three fd_sets (in/out — select writes results back), and `timerfd_settime`'s `old_val_ptr` /
`timerfd_gettime`'s `cur_ptr`. Deliberately left on the mapped-only check: `select`'s `timeout_ptr` and
`timerfd_settime`'s `new_val_ptr`, which are pure inputs.

Two concerns were checked and ruled out rather than assumed. First, whether last pass's `sharedPte` — which
no longer marks read-only pages COW — could let a shared frame be freed while another process still maps it:
it cannot, because `destroyUserSpace` never consults the COW bit and calls `freePage`, which decrements the
refcount and only releases at zero, while fork's first pass bumps that count for *every* present entry
including read-only ones. Second, whether any syscall hands a user pointer straight to a lower layer for a
raw `@memcpy`, bypassing the writability check entirely: all eight call sites of `fd_table.read` pass kernel
buffers, and `readahead`'s destination is an HHDM alias.

Verification: three-architecture builds, `zig build test`, `smoke` / `smoke-smp` / `smoke-smp-stress`, and
the riscv64 and aarch64 smokes all pass. hello34 reports `read(ro)=-14 (rejected)`, `read(ok)=7`, `PASS`, and
its marker is now a smoke condition. Negative control: dropping the pre-check in `file_io.read` brings back
`read(ok)=0` and `payload was consumed by the refused read`.

Left open, with reasons. Around eighty `_ = copyToUser(...)` sites still discard the result, so a refused
copy leaves the syscall reporting success with its out-param unwritten (`uname`, `getrusage`, `sysinfo` and
the like). That is a wrong return value rather than a memory-safety problem or irreversible data loss, and
adding an error path to eighty call sites is a large, regression-prone change; it is deferred rather than
rushed. Separately, `copy_from_user.zig` admits in its own header that instruction-level fault recovery is
still TODO — `checkFault()` always returns null because `recovery_rip` is never set. Validate-then-copy
therefore has a TOCTOU window: a thread sharing the address space can `munmap` the page between the check and
the `@memcpy`, faulting inside the kernel with no recovery. An exception-table guard is the systemic answer
(and would also remove the per-page walk every copy currently pays). It is not attempted here because this
kernel has no working user-space threading example to race with — `hello31` uses fork — so the window cannot
be demonstrated deterministically, and an unverifiable fix is not worth committing. It belongs with
user-space `clone` thread support.

| Gate | Result | Notes |
|---|---|---|
| `zig build` / `-Darch=riscv64` / `-Darch=aarch64` | Passed | All three ISA builds. |
| `zig build test` | Passed | Host helper tests. |
| `zig build smoke` / `smoke-smp` | Passed | Single and dual core; hello32 passes both parts. |
| `zig build smoke-smp-stress` | Passed | 5 consecutive dual-core runs. |
| `bash tools/qemu_smoke_riscv64.sh` / `_aarch64.sh` | Passed | Unaffected; neither port has this fault path. |

### 5.2r Review Update: 2026-07-26 (a task nobody enqueues is a task that may never run)

5.2q closed by saying the next step was user-space threading, so the TOCTOU window could finally be raced
deterministically. Writing that example (`user/hello35.c`) went wrong immediately: `clone` returned a child
TID, the child never executed a single user instruction, and if the creator waited for it with `sched_yield`
the whole machine went silent. The fault turned out not to be in `clone` at all.

`pickNext()` drains the per-CPU run queue first and only falls back to the bitmap scan (`pickReadyForCpu`)
when that queue comes up empty. Every context switch re-enqueues the outgoing task, so on a CPU with two
tasks ping-ponging the queue never empties and the fallback never runs. None of the four task-creation sites
— fork, clone, and the loader's ELF and flat paths — ever called `sched.enqueue`. A new task was therefore
discovered only if its CPU happened to run dry.

fork got away with it because a parent normally blocks in `waitpid` right afterwards: it stops being
re-enqueued, the queue drains, and the bitmap scan picks the child up. A thread creator does not block, by
definition, so the luck ran out. The same starvation applies to a forked parent that keeps running instead of
waiting, which makes this a task-creation bug rather than a clone-specific one.

| Severity | Finding | Resolution / status |
|---|---|---|
| P0 | A newly created task is never placed on any run queue; on a busy CPU it starves indefinitely | Fixed. `createUserProcess` now leaves the task `.blocked`; new `task.publishRunnable(slot)` does `.blocked → .ready` + `sched.enqueue` + cross-CPU kick, called from all four creation sites once the task is actually complete. |
| P1 | `createUserProcess` published `.ready` before fork/clone had built the child's interrupt frame | Fixed by the same change. Another CPU's bitmap scan could previously catch the task with `started == false` and enter it through `setupInitialFrame` at the ELF entry, re-running the program from the top instead of resuming at the fork return. The window is gone now that publication happens after construction. |
| P2 | `clone` never set `child.saved_user_rsp`, unlike fork | Fixed; seeded from the new thread's stack top. |

Worth recording about the diagnosis, because it cost three rounds: `zig build smoke 2>&1 >/dev/null`
swallowed a compile error (`serial` was not in scope at the point I added a probe to `sched.zig`), and the
smoke log path carries no run identity, so the greps that followed were reading the *previous* run's log.
That produced a confident and entirely wrong conclusion that the scheduler never switched to the child. Never
discard build output, and confirm a log belongs to the run being analysed.

Verification: three-architecture builds, `zig build test`, `smoke` / `smoke-smp` / `smoke-smp-stress`, and the
riscv64 and aarch64 smokes all pass. hello35 reports `PASS (thread ran and shares memory)` and its marker is
now a smoke condition. Negative control: removing just the `sched.enqueue` call from `publishRunnable` puts
the machine straight back into the 123-second hang.

No SK probe was added. This is scheduler state-machine behaviour, not a pure function that can be recomputed
across architectures; hello35 is its regression test. Inventing a probe that cannot fail would be worse than
having none, which is the same reasoning that cancelled SK-152.

| Gate | Result | Notes |
|---|---|---|
| `zig build` / `-Darch=riscv64` / `-Darch=aarch64` | Passed | All three ISA builds. |
| `zig build test` | Passed | Host helper tests. |
| `zig build smoke` / `smoke-smp` | Passed | Single and dual core, with hello35 as a new gating marker. |
| `zig build smoke-smp-stress` | Passed | Repeated dual-core runs. |
| `bash tools/qemu_smoke_riscv64.sh` / `_aarch64.sh` | Passed | Shared-probe smokes unaffected. |

Still open. The TOCTOU window from 5.2q is untouched: this round produced the threading primitive it needs but
spent itself on the scheduler bug that surfaced along the way. With `hello35` in place a two-thread
munmap-versus-copy race is now writable, which is the next step. The eighty `_ = copyToUser(...)` sites remain
as recorded in 5.2q.

### 5.2s Review Update: 2026-07-26 (x86 user-copy fault recovery)

The `CLONE_VM` support from 5.2r made the remaining user-copy TOCTOU race testable. A page-table walk can
validate a range and another thread can still unmap it before or during the copy. On x86_64, both
`copyFromUser` and `copyToUser` now use one dedicated `rep movsb` instruction at a known RIP. A supervisor
page fault at exactly that instruction rewrites the saved RIP to a fixup which returns `len - RCX`, preserving
the existing copied-byte return contract without global or per-CPU "copy active" state.

| Severity | Finding | Resolution / status |
|---|---|---|
| P0 | The initial SK-156 files were not reachable: production copies still used `@memcpy` and #PF never referenced the new fixup | Fixed. The shared copy layer selects the guarded primitive on x86_64, and the x86 #PF handler matches its exact instruction RIP. |
| P1 | Handling copy fixup before COW would turn a valid kernel write to a COW user page into a short copy | Fixed. User and supervisor COW resolution runs first; only an unresolved supervisor fault at the guarded RIP uses the copy fixup. |
| P1 | A process-global "copy in progress" flag would be unsafe under SMP, preemption, nested copies, and unrelated faults | Removed. Recovery is stateless and keyed only by the saved fault RIP, following the x86 exception-table model. |
| P1 | Matching only RIP could hide a fault on the helper's trusted kernel operand as a short user copy | Fixed. Recovery additionally requires a non-null user-range CR2 equal to the saved current RSI or RDI; unexpected kernel operand faults remain fatal. |
| P2 | `hello36` was built and launched but its PASS marker was not part of smoke success | Fixed. Both single- and dual-core x86 smokes now require `hello36: PASS`. |
| P2 | Parallel single-/dual-core smokes shared `user_bin`, `iso_root`, and `moqios.iso`, causing nondeterministic packaging failures | Fixed. Each smoke process now supplies a private packaging directory while interactive runs retain the existing defaults. |

The page-table precheck remains deliberate: it rejects ordinary bad pointers before entering the guarded
instruction and protects callers that must decide whether to consume queued data. Non-x86 architectures keep
their existing prevalidated `@memcpy` path; this change does not claim exception recovery for those ports.

`hello36` races 400 writes against unmap/remap in a shared address space and reports full, partial, and refused
writes separately. It is not deterministic fault injection: the final single-core run reported one full write
and 399 prevalidation refusals. The final dual-core run reported three partial writes and 397 refusals; because
the syscall returns a positive short count only from `len - RCX` at the recovery label, those partial writes
are direct runtime evidence that the mid-copy fixup was exercised. Smoke still gates machine survival and PASS,
not a mandatory partial count, so scheduling variance cannot make otherwise-correct runs flaky.

| Gate | Result | Notes |
|---|---|---|
| `zig build` / `-Darch=riscv64` / `-Darch=aarch64` | Passed | All three ISA builds. |
| `zig build test` | Passed | Host helper tests. |
| `zig build smoke` / `smoke-smp` | Passed | Single and dual core; `hello36: PASS` is mandatory, and the final dual-core log observed three recovered partial writes. |
| `zig build -Darch=riscv64 smoke-riscv` | Passed | Existing non-x86 guarded/prevalidated path unaffected. |
| `zig build -Darch=aarch64 smoke-aarch64` | Passed | Existing non-x86 guarded/prevalidated path unaffected. |
| `nm -n zig-out/bin/moqi-kernel.elf` | Passed | Dedicated copy, fault instruction, and fixup symbols emitted at distinct addresses. |

### 5.2t Review Update: 2026-07-26 (output contracts, mmap metadata, and SMP pipes)

This pass started as a full-repository audit. Seven internal/external specialist sessions and the Oracle
synthesis session failed before inspection because their backend returned `Invalid token`; those failures are
not counted as clean reviews. The filesystem fallback completed on a second model, and every reported issue
below was then checked against current source rather than accepted from the report. Several older plan items
were explicitly rejected as stale: non-fixed mmap overlap, brk overlap, `syncFile` error propagation,
`mprotect`, ext2 directory validation, and x86 user-copy fixup are already implemented at current HEAD.

| Severity | Finding | Resolution / status |
|---|---|---|
| P0 | `io_getevents` advanced its completion ring even when the event could not be copied to userspace, permanently losing completion records | Fixed. The head/count advance occurs only after a full `IoEvent` copy; a first-copy failure returns `EFAULT`, while a later failure returns the already delivered count and leaves the failed event queued. |
| P1 | Output syscalls across fs, proc, IPC, networking, timers, futex helpers, and the legacy x86 dispatcher reported success after a failed or partial `copyToUser` | Fixed. Every previously discarded result now requires the full byte count. Irreversible operations (`io_getevents`, message receive, wait, pipe creation, offset-bearing transfers) validate writable output before consuming state and still check the final copy as a race backstop. |
| P1 | `copy_file_range` and splice/sendfile offset pointers were copied back best-effort after data movement | Fixed. Optional offset pointers are proven readable and writable before transfer, so `EFAULT` happens before any I/O side effect; copy-back remains length-checked as a race backstop. |
| P1 | The 65th disjoint mmap was mapped successfully but omitted from the fixed 64-entry region table, making later region operations unable to find it | Fixed. Non-fixed mappings reserve either a free slot or an adjacency merge before allocating pages. MAP_FIXED uses a conservative post-replacement piece count before destroying old mappings and returns `ENOMEM` if the layout cannot be represented. |
| P1 | Global pipe ring indices, contents, allocation, reset, and refcounts were mutated concurrently without synchronization | Fixed. A shared IRQ-safe lock serializes pipe state; readiness consumers use an immutable snapshot API, retain/single-end transitions are centralized, and epoll notification remains outside the critical section. |
| P1 | `poll` treated a wrapped pipe as empty and unconditionally added `POLLERR|POLLHUP` to every valid descriptor | Fixed with the same pipe snapshot. Readability uses ring distance, pipe writability/peer-close are explicit, and errors are no longer fabricated for ordinary files and sockets. |
| P2 | `fcntl` rejected descriptors 32-63 despite x86 `MAX_FDS == 64`, and truncated the argument before validation | Fixed. The original 64-bit fd value is checked against `vfs.MAX_FDS` before conversion; bitmap-based duplication remains O(1). |

The performance choice is deliberately bounded rather than architectural: no heap allocation or dynamic VMA
tree was introduced. Mmap capacity checks scan 64 entries only at mapping time. Pipe locking retains the
existing O(bytes) ring copy and holds the lock only across at most 4095 in-kernel bytes; it never spans user
copy, scheduler calls, or epoll callbacks. Readiness checks take one short snapshot instead of racing several
loads. A scalable dynamic VMA tree and per-pipe locks remain possible future work only after profiling proves
the fixed limits or one global pipe lock are material bottlenecks.

`user/hello37.c` is the deterministic regression gate. It verifies `EFAULT` from output syscalls targeting a
read-only page, `fcntl(F_GETFD)` on descriptor 40, absence of fabricated poll success, and `ENOMEM` on the 65th
non-adjacent mmap region. It is built, packaged, run by init, and required by x86 single- and dual-core smoke.
The source scan gate additionally requires no `_ = ...copyToUser(...)` remains in `kernel/`; future output
syscalls must either propagate full-copy failure or document a deliberately best-effort ABI at the call site.

| Gate | Result | Notes |
|---|---|---|
| `zig build` / `-Darch=riscv64` / `-Darch=aarch64` | Passed | All three ISA builds after the implementation changes. |
| `zig build test` | Passed | Host helper tests. |
| x86 single-/dual-core smoke | Passed | `hello37: PASS (EFAULT/fd/mmap/poll)` and shell marker required. Existing pipe test still transfers all 16 bytes. |
| riscv64 / aarch64 smoke | Passed | Shared probe and user-mode bring-up contracts unaffected. |

### 5.2u Review Update: 2026-08-22 (hello76 sync_file_range acceptance)

`hello76` adds the raw syscall #290 acceptance gate without changing kernel core code. The contract is
bounded and semantic: a request covers exactly `[offset, offset + nbytes)`; `nbytes == 0` is a bounded
no-op; unknown flags and offset-plus-length overflow return `EINVAL`; invalid descriptors return
`EBADF`; pipe/device descriptors return the implementation's unsupported `EINVAL`. The regular-file
case uses the existing ext2 fixture, and every opened descriptor is closed. The test deliberately makes
no wall-clock, throughput, or persistence-performance claim.

| Acceptance item | Evidence |
|---|---|
| Valid regular-file range with supported flags | `hello76: PASS` checks syscall #290 over a finite ext2 file range. |
| Zero length | `hello76` checks `nbytes == 0` returns success without widening the request. |
| Error propagation and cleanup | `EBADF`, unknown flags, overflow, pipe/device unsupported cases, and all fd closes are checked. |

### 5.2v Review Update: 2026-08-22 (hello78 socketpair acceptance)

`hello78` adds the raw syscall #53 acceptance gate without changing kernel core code. The supported
boundary is deliberately narrow: `AF_UNIX` + `SOCK_STREAM` + protocol `0`, with a returned pair that
supports bidirectional `write`/`read`. Invalid domain, type, or protocol must return `EINVAL`; a bad
`sv` pointer must return `EFAULT`; rejected calls must not leak descriptors; and both successful fds
must be closed. This is semantic syscall evidence only and makes no wall-clock, throughput,
compatibility-breadth, or persistence-performance claim.

| Acceptance item | Evidence |
|---|---|
| Supported pair | `hello78: PASS` checks raw #53 and both directions of byte-stream transfer. |
| Validation | Invalid domain/type/protocol return `EINVAL`; bad `sv` returns `EFAULT`. |
| Cleanup | Rejected calls are checked for no fd allocation, and both returned descriptors are closed. |

### 5.2w Review Update: 2026-08-23 (hello79 fallocate acceptance)

`hello79` adds the raw syscall #274 acceptance gate without changing kernel core code. The supported
boundary is strict: only `mode == 0` may operate on a regular file. Every nonzero mode must return
`EOPNOTSUPP` before target lookup or mutation; unsupported pipe/device targets may return the documented
`EINVAL` or `EOPNOTSUPP`. The test checks invalid fd `EBADF`, verifies mode-zero extension and verifies
that rejected nonzero modes do not change file size. This is semantic syscall evidence only and makes no
wall-clock, throughput, allocation-speed, or persistence-performance claim.

| Acceptance item | Evidence |
|---|---|
| Supported mode | `hello79: PASS` checks raw #274 mode `0` over an in-file regular-file range. |
| Unsupported boundary | Nonzero mode returns `EOPNOTSUPP` and preserves the regular-file size. |
| Descriptor/target errors | Invalid fd returns `EBADF`; pipe/device cases accept only `EINVAL` or `EOPNOTSUPP`; all fds close. |

### 5.2x Review Update: 2026-08-23 (hello80 unsupported syscall acceptance)

`hello80` defines an explicit unsupported boundary for the native dispatcher entries acct (#281),
unshare (#282), process_madvise (#440), and Landlock (#444-#446). Each raw call must return `ENOSYS`
before target lookup, namespace/LSM state handling, or user-buffer access; sentinel buffers must remain
unchanged. This is acceptance evidence for an ABI contract, not an implementation of process accounting,
namespaces, cross-process memory advice, or Landlock. The current dispatcher still contains no-op success
arms for these numbers, so the new gate correctly fails until a separately authorized kernel-core change
aligns behavior; the test must not weaken the contract to accept success.

| Acceptance item | Evidence |
|---|---|
| Unsupported calls | `hello80` checks raw #281, #282, #440, and #444-#446 for `-ENOSYS`. |
| No mutation | Sentinel buffers passed to acct, process_madvise, and Landlock remain byte-for-byte unchanged. |
| Scope | Build/init/ramdisk/smoke wiring only; no kernel-core implementation or compatibility claim. |

### 5.2y Review Update: 2026-08-24 (hello82 sched_getaffinity acceptance)

`hello82` records the existing raw syscall #227 boundary without changing kernel core. The accepted
contract is current-pid-only: `pid == 0` and the current TID succeed, while invalid or non-current pids
return `ESRCH` before touching the user buffer. A bad pointer returns `EFAULT`. The current single-CPU
mask contains only CPU 0 (bit 0), and the syscall copies/returns `min(cpusetsize, 128)` bytes; size zero
is a successful no-write boundary and a 129-byte request remains capped at 128. The acceptance test
therefore covers ABI return lengths, mask contents, error ordering, and sentinel preservation, not SMP
affinity support or scheduling performance.

| Acceptance item | Evidence |
|---|---|
| Current PID contract | `hello82` checks `pid == 0` and the current PID, including the CPU-0 mask. |
| Error ordering | Invalid/non-current PID returns `ESRCH` without sentinel mutation; null mask returns `EFAULT`. |
| Size boundary | `hello82` checks sizes 0, 1, 127, 128, and 129 against the 128-byte cap. |
| Scope | User acceptance plus build/init/ramdisk/smoke wiring; no kernel-core edits. |

### 5.3 Historical Verification

Executed on 2026-06-21:

| Gate | Result | Notes |
|---|---|---|
| `git status --short --branch` | Passed | Branch `main...origin/main`; only this update's files modified before commit |
| `zig build` | Passed | After build-system compatibility fixes for Zig-bundled tools on Windows |
| `zig build test` | Passed | Host unit tests for pure helper modules |
| `zig build -Darch=riscv64` | Passed | riscv64 skeleton still builds |
| QEMU single-core smoke | Not run | Current Windows environment did not expose `qemu-system-x86_64`/`xorriso` in `PATH` |
| QEMU dual-core smoke | Not run | Same environment gap; must be run before claiming runtime boot-to-shell health |

The build/test results prove the code compiles in this environment and the host tests pass. They do not prove runtime
kernel behavior, filesystem behavior, networking behavior, or SMP boot-to-shell stability.

### 5.3 SMP Performance Triplet (M8-5b-3 / M8-6 / M8-7) Completed 2026-06-21

| Item | File | Status |
|---|---|---|
| FPU/SSE per-task lazy save/restore | `kernel/arch/x86_64/context_switch.zig` (~131 lines) | ✅ Implemented + integrated (BSP `main.zig`, AP `smp.zig` `apEntry`, `idt.zig` #NM, `sched.zig` `onContextSwitch`) |
| Per-CPU run queues + work-stealing | `kernel/proc/per_cpu.zig` (~221 lines) | ✅ 256-slot LIFO ring + `steal_half` + `cpu_affinity` aware |
| Ranged TLB shootdown | `kernel/arch/x86_64/tlb.zig` (~206 lines) | ✅ IPI vector 0xFE + invlpg loop + 32-page CR3 fallback + custom `TlbLock` |
| Task struct extensions | `kernel/proc/task.zig` | ✅ `fpu_state`/`fpu_initialized`/`fpu_owned` + `cpu_affinity`/`last_cpu` |
| `mprotect`/`mmap` integration | `kernel/mm/mprotect.zig`, `kernel/mm/mmap.zig` | ✅ Both call `tlb.shootdownRange` after PTE change |

Build verification (2026-06-21): `zig build` passed after the triplet was added; runtime QEMU
verification is still limited by environment availability of `qemu-system-x86_64`.

### 5.4 Review Update: 2026-07-26 — CPU-Count-Adaptive SMP Model

This update implements and documents the MADT-driven adaptive CPU selection model replacing any
previous fixed dual-core assumption.

#### Changes implemented

| File | Change |
|---|---|
| `kernel/smp.zig` | `initX86` selects CPUs from MADT type-0/xAPIC entries; upper bound is `min(freeSlotCount+1, MAX_CPUS=256)`; IST allocation scaled to selected count |
| `kernel/arch/cpu_capacity.zig` | New helper: exposes selected/online counts and hardware capacity bounds |
| `kernel/acpi/acpi_parser.zig` | type-9/x2APIC entries explicitly skipped; only type-0 xAPIC (u8 IDs) consumed |
| `kernel/arch/x86_64/gdt.zig` | `initFinalIst` allocates 3×16 KiB IST backing once per selected CPU count |
| `kernel/arch/x86_64/tlb.zig` | Shootdown IPI loop conditions on `isCpuOnline(id)`; never waits for un-initialized or halted CPUs |
| `tools/qemu_smoke.sh` | Accepts arbitrary positive `SMP_COUNT`; parses `[SMP] N CPUs detected/selected/online` markers; strict-SMP mode enforces selected ≥ requested |
| `tools/qemu_smoke_stress.sh` | `MOQI_SMP` (default 2) and `MOQI_SMOKE_RUNS` (default 5) configurable |
| `build.zig` | New `smoke-smp-matrix` step invoking `tools/qemu_smoke_matrix.sh` |

#### Key design decisions recorded

- **Dense logical IDs separate from xAPIC IDs**: kernel arrays indexed 0…configured_cpu_count-1; xAPIC hardware IDs stored in `selected_apic_ids[]` for IPI delivery only. The two need not match.
- **256 metadata slots (hardware-bounded)**: `MAX_CPUS = 256` because xAPIC ID fields are u8. Not a software policy limit — reflects the hardware addressing range of the legacy APIC mode.
- **x2APIC / MADT type-9 explicitly unsupported**: type-9 entries are skipped at parse time. Extending to x2APIC requires a separate design step; current code is correct, not incomplete.
- **Expensive IST backing allocated once, to selected count**: `gdt.initFinalIst(configured_cpu_count)` allocates 3×16 KiB per CPU once at boot. The hot-path per-CPU arrays (`online_cpus`, `selected_apic_ids`) remain hardware-bounded and stable.
- **AP startup serialized**: BSP sends INIT+SIPI to each AP in sequence and waits for the magic word before proceeding to the next. No parallel AP bringup.
- **Task-slot / memory / AP failure degrades gracefully**: if `gdt.initFinalIst` returns fewer slots than selected, or an AP fails to set the magic word within deadline, `configured_cpu_count` (and later `cpu_count`) decreases safely; the kernel continues with fewer online CPUs.
- **Smoke accepts any positive count**: `qemu_smoke.sh` validates `SMP_COUNT` as any positive decimal integer; no artificial ceiling in the script.

#### Verified evidence

| Gate | Count / config | Result |
|---|---|---|
| `zig build test` | host | Passed |
| `zig build` | x86_64 ReleaseFast | Passed |
| `zig build -Darch=riscv64` | — | Passed |
| `zig build -Darch=aarch64` | — | Passed |
| `zig build smoke` | `MOQI_SMP=1` | Passed |
| `zig build smoke-smp` | `MOQI_SMP=2` | Passed |
| `zig build smoke-smp` | `MOQI_SMP=3` | Passed |
| `zig build smoke-smp` | `MOQI_SMP=4` | Passed |
| `zig build smoke-smp` | `MOQI_SMP=6` | Passed |
| `zig build smoke-smp` | `MOQI_SMP=8` | Passed |
| `zig build smoke-smp` | `MOQI_SMP=12` | Passed |
| `zig build smoke-smp` | `MOQI_SMP=16` | Passed (`MOQI_SMOKE_TIMEOUT=600` required in TCG) |
| `zig build smoke-smp-stress` | `MOQI_SMP=8 MOQI_SMOKE_RUNS=3` | Passed — 3 consecutive 8-core runs reached shell |
| `zig build -Darch=riscv64 smoke-riscv` | — | Passed |
| `zig build -Darch=aarch64 smoke-aarch64` | — | Passed |

Note: `zls` (Zig Language Server) is not available in this environment; LSP-level diagnostics were not run. Build and runtime gates above are the verification basis.

### 5.4b Review Update: 2026-07-27 — Post-Review SMP Startup-Handshake and IPI/TLB Hardening

This update documents and records verification for the hardening changes added to `kernel/smp.zig` and
`kernel/arch/x86_64/tlb.zig` after the 2026-07-26 adaptive-SMP review. No code was changed during this
documentation pass; the changes were already present in the worktree and are described here for the
record.

#### Changes implemented (already in worktree)

| File | Change |
|---|---|
| `kernel/smp.zig` | Replaced single-phase magic-word AP confirmation with a two-phase mailbox token protocol (request token at phys `0x7080`, ack at `0x7088`). AP parks immediately on entry if token is zero or already has `AP_MAILBOX_PERMITTED` set. BSP bounds both wait loops at 500,000 `pause` iterations. Pre-grant timeout revokes the token and degrades gracefully; post-grant timeout calls `failCommittedApStartup` (fatal halt). |
| `kernel/arch/x86_64/tlb.zig` | TLB shootdown `completion` counter seeded to the exact online-CPU count; `@atomicRmw(.Sub, 1)` guarantees nonzero-decrement semantics. BSP wait loop bounded by `SHOOTDOWN_WAIT_POLL_LIMIT = 5_000_000`; expiry triggers a fatal halt because coherence cannot be guaranteed. Shootdown skips CPUs where `isCpuOnline` is false. |

#### Key protocol distinctions

- **Pre-grant AP failure is degradable**: if an AP does not report in before the first timeout, the
  BSP clears the token to zero, cancels the pre-allocated idle task, and continues with fewer CPUs.
  The AP, if it eventually reaches `apEntry`, reads token == 0 and parks itself safely.
- **Post-grant AP failure is fatal**: once BSP has written `token | AP_MAILBOX_PERMITTED`, the AP's
  logical CPU ID is committed and the AP may already be modifying shared kernel state. A timeout at
  this point calls `failCommittedApStartup`, which prints a diagnostic and halts the machine to
  prevent a partially-initialized AP from corrupting the scheduler.
- **TLB coherence failure is fatal**: a shootdown that does not complete within `SHOOTDOWN_WAIT_POLL_LIMIT`
  means one or more CPUs may still hold stale translations; continuing would silently violate memory
  safety. The bounded wait + fatal-halt design matches the post-grant AP policy.

#### Focused re-reviews

Two focused Oracle re-reviews were run against the hardened code:

- **Concurrency re-review**: confirmed that the token handshake uses correct release/acquire ordering
  at every publish/read site, that the per-AP serialization in `initX86` prevents token aliasing
  across concurrent APs, and that `failCommittedApStartup` cannot itself race with a completing AP
  (the AP must store `token | AP_MAILBOX_PERMITTED` to ack, which is the exact value that resolves
  the BSP wait — the halt path is only reachable if that store never arrives). **PASS**.
- **Security re-review**: confirmed that an AP with a stale or zero token cannot acquire a logical
  CPU ID (it parks before reading `cpu_id` from the trampoline data area), that `parkUnrequestedAp`
  is a true dead-end (infinite `hlt` with no shared-state side effects), and that the fatal-halt
  path in `failCommittedApStartup` and in `tlb.zig` uses `cli` before `hlt` to prevent any further
  interrupt delivery on the halting CPU. **PASS**.

#### Verified evidence

Prior full smoke matrix (1/2/3/4/6/8/12/16 cores) from §5.4 is retained as the baseline. Additional
focused runs with the hardened code:

| Gate | Count / config | Result |
|---|---|---|
| `zig build smoke-smp` | `MOQI_SMP=3` | Passed |
| `zig build smoke-smp` | `MOQI_SMP=8` | Passed |
| `zig build smoke-smp` | `MOQI_SMP=16` | Passed (`MOQI_SMOKE_TIMEOUT=600` in TCG) |
| Concurrency re-review | focused Oracle pass | PASS |
| Security re-review | focused Oracle pass | PASS |

### 5.5 Review Update: 2026-07-28 — Full-Repository Audit (syscall safety, driver hardening, hello38-41 gates)

This pass is a full-repository audit covering 15 changed files (438 insertions, 108 deletions).
Every finding below was verified against current worktree source before being recorded.

#### Findings and fixes

| Severity | Area | Finding | Resolution |
|---|---|---|---|
| P1 | `copy_file_range` (`kernel/fs/copy_file_range.zig`) | `off_in_ptr`/`off_out_ptr` were read with `copy.validateUserBufferWritable` but the validation was checking the 8-byte pointer slot with the wrong access mode — a NULL or unmapped pointer could reach `@ptrFromInt`. Additionally, the `defer` rollback block restoring `fd.offset` ran even on the success path, reverting the final committed position back to the original value after a successful copy. | Fixed: canonical address bounds check (`>= 0x0000_8000_0000_0000`) added before every `copyFromUser`/`validateUserBufferWritable` call; `defer` rollback is conditioned on `use_off_in`/`use_off_out` and only fires on error paths (offset writeback at end of success path is explicit). `fd_in`/`fd_out` index bounds validated before array access. |
| P1 | `socket_opt` (`kernel/net/socket_opt.zig`) | `setsockopt` user-copy paths for `SO_RCVTIMEO`/`SO_SNDTIMEO`/`SO_LINGER` and all `SOL_TCP` options read directly from `optval_ptr` without a canonical-address guard. `getsockopt` for `SO_ERROR` consumed the pending error value from the TCB before verifying the output buffer was writable, so a bad `optval_ptr` would clear the error and return `EFAULT` — the error was lost. | Fixed: all `setsockopt` read paths gate on `optval_ptr >= 0x0000_8000_0000_0000 → EFAULT`; `getsockopt SO_ERROR` validates the output buffer before reading and clearing the TCB error field. |
| P1 | `socket_syscall` (`kernel/net/socket_syscall.zig`) | `getsockname`/`getpeername`/`accept` filled a fixed 16-byte `sa_buf` and wrote exactly 16 bytes to user space regardless of socket family. AF_UNIX addresses require a `sun_path`-length write (up to 108 bytes); AF_INET6 requires 28 bytes. Writing 16 bytes to an AF_UNIX address slot silently truncated the path. | Fixed: `copySockaddrToUser` helper uses the actual `alen` returned by the address resolver (bounded by `user_optlen`); `getsockname`/`getpeername` pass correct family-specific lengths. |
| P1 | `futex` (`kernel/sync/futex.zig`) | `futex_waitv` did not validate `nr_waiters` against an upper bound before computing `waiters_len = nr_waiters * waiter_size`, allowing a large `nr_waiters` to overflow the multiplication and produce a short `validateUserBuffer` window. Additionally, `FUTEX_WAIT` and `FUTEX_WAIT_BITSET` called `copyUserU32(addr)` without a canonical-address check on `addr`, so a user-supplied address ≥ `0x0000_8000_0000_0000` reached `@ptrFromInt` directly. | Fixed: `futex_waitv` clamps `nr_waiters` to `max_waiters` (128) with `-EINVAL` before the multiply, and uses `std.math.mul` with overflow check; all `copyUserU32` call sites guard `uaddr >= 0x0000_8000_0000_0000 → EFAULT` before the copy. |
| P1 | `signal_syscall` (`kernel/proc/signal_syscall.zig`) | `rt_sigsuspend(mask_ptr, sigsetsize)` called `copy.copyFromUser` with `@min(sigsetsize, 4)` but did not first validate that `mask_ptr` was a canonical user address. A kernel-range pointer passed as `mask_ptr` bypassed the `validateUserBuffer` guard because the guard was absent. | Fixed: canonical-address check added before `copyFromUser`; non-canonical `mask_ptr` returns `-EFAULT`. |
| P1 | `sysv_msg`/`sysv_shm` (`kernel/ipc/sysv_msg.zig`, `kernel/ipc/sysv_shm.zig`) | `msgctl(IPC_SET)` and `shmctl(IPC_SET)` read the `msqid_ds`/`shmid_ds` struct from user space using `@ptrFromInt(buf)` directly without validating that `buf` was a user-range pointer or calling `copyFromUser`. | Fixed: both `IPC_SET` paths now call `copy.validateUserBuffer` + `copy.copyFromUser`; kernel-range or unmapped `buf` returns `-EFAULT`. |
| P1 | `virtio_net` (`kernel/drivers/virtio_net.zig`) | Initialization error path (`abortInitialization`) set `VIRTIO_STATUS_FAILED` on the device but left descriptors partially populated. A subsequent `sendPacket` could see `device.active == false` and return early, but the TX queue notify path was reachable if the flag race was lost during interrupt-driven re-init. Additionally, `sendPacket` polled the used ring with a bare `timeout` counter and no yield, burning CPU time spinning in the kernel for up to 100 000 iterations on a saturated link. | Fixed: `abortInitialization` sets `device.active = false` before touching any shared queue state, making it the single serialization point; `sendPacket` checks `device.active` as the first guard and returns `false` immediately for quarantined devices; TX timeout deactivates the device (`device.active = false`) rather than freeing in-flight DMA buffers unsafely — the device is quarantined and the packet is dropped. |
| P1 | `e1000` (`kernel/drivers/e1000.zig`) | `rollbackInitialization` called `releaseRXResources`/`releaseTXResources` before checking `initialized`, so a double-rollback (errdefer + manual call) on a half-initialized device could free already-freed PMM pages. TX descriptor tail polling also had the same unbounded busy-wait pattern. | Fixed: `rollbackInitialization` sets `initialized = false` then calls `releaseTXResources`/`releaseRXResources` unconditionally; each release function is a no-op for any ring slot whose physical address is already zero, making double-rollback safe. RX/TX engines (`RCTRL_EN`/`TCTRL_EN`) are only written after both `setupRX()` and `setupTX()` succeed, so any page freed by rollback is never DMA-owned at that point. TX timeout path records the hang in the serial log and returns `false` without touching DMA-owned memory. |

#### Regression gates: hello38-41

Four new C regression programs were added to `user/` and wired into `build.zig`
(`c_programs` list now includes `hello38`–`hello41`); `user/init.S` spawns all four:

| Program | What it tests |
|---|---|
| `hello38` | `futex` user-word fault handling: verifies `EFAULT` when the futex word address is unmapped, `EFAULT` on a null `futex_waitv` waiter array, and `EINVAL` when `nr_waiters` exceeds the allowed limit. |
| `hello39` | `setsockopt`/`getsockopt` user-copy and sockaddr length: round-trips `SO_REUSEADDR` and `SO_ERROR` on a TCP socket; verifies `EFAULT` when `optval` is an unmapped pointer, and that `SO_ERROR` clears on read. |
| `hello40` | `msgctl(IPC_SET)` and `rt_sigsuspend` must not mutate kernel state after a failed user-copy: verifies `EFAULT` when the `msqid_ds` buffer pointer is unmapped, and `EINTR` (not a spurious mask change) from `rt_sigsuspend` when the supplied mask pointer is unmapped. |
| `hello41` | `copy_file_range` fd validation and offset rollback: verifies `EBADF` for out-of-range and closed fds, `EINVAL` for special fds, and that explicit `off_in`/`off_out` pointers are correctly updated after a successful copy. |

All four programs emit `helloNN: PASS` on success and are mandatory smoke markers.

#### Validation evidence

| Gate | Config | Result |
|---|---|---|
| `zig fmt` (changed files) | all 15 dirty files | Passed — no formatting deltas |
| `zig build test` | host tests/default | Passed |
| `zig build` | x86_64 ReleaseFast | Passed |
| `zig build -Darch=riscv64` | cross | Passed |
| `zig build -Darch=aarch64` | cross | Passed |
| `zig build smoke` | x86_64 single-core | Passed — `hello38`–`hello41` PASS markers present |
| `zig build smoke-smp-stress` | 8-core, 2 runs | Passed — all markers present in both runs |
| `zig build -Darch=riscv64 smoke-riscv` | — | Passed |
| `zig build -Darch=aarch64 smoke-aarch64` | — | Passed |

#### Deferred items (explicit, with reasons)

- **`process_vm_readv`/`process_vm_writev` true cross-process path**: current implementation accesses the target task's page table by switching CR3 under a spinlock, which is unsafe when the target address space can be concurrently freed (task exit, execve, or munmap from another CPU). A correct implementation requires address-space lifetime synchronization (a held reference on the target `mm`) and consolidation of the three existing dead/inline implementations into a single authoritative path. Deferred until the address-space manager has a reference-counted `mm` abstraction. The syscall is not claimed fixed and is not wired to a smoke gate.
- **`RwLock` IRQ-mode API defect**: `kernel/sync/rwlock.zig` exposes `readLockIrq`/`writeUnlockIrq` variants but the unlock paths do not restore the saved IRQ flags, so any call site that acquired with IRQs enabled and releases with the intent to re-enable them silently leaves interrupts disabled. No current call site in the merged tree uses these variants in a context where the bug is reachable, so it is deferred rather than fixed speculatively. It must be resolved before any IRQ-mode read-writer lock usage is introduced.
- ~~**`~80 discarded copyToUser results`**~~ ✅ RESOLVED (2026-08): `grep -rn "_ = .*copyToUser" kernel/`
  now returns 0 hits. A later fix round required the full byte count at every previously discarded
  site (see §5.2u), and the source-scan gate rejects any new `_ = ...copyToUser(...)` in `kernel/`.
- ~~**TOCTOU window in `copy_from_user`**~~ ✅ RESOLVED (2026-08): the described mechanism no longer
  exists. The current implementation is a single-instruction `rep movsb` copy at a known RIP plus
  `user_copy.faultFixup`, with the #PF handler in `kernel/arch/x86_64/idt.zig` rewriting the faulting
  RIP to the fixup path (`recovery_rip`-style zero-fill/short-count semantics). `checkFault()` and the
  never-armed `recovery_rip` were removed.

---

## 6. 2026-08 全仓库审查与修复轮次

### 6.1 范围

七个领域的静态审查：mm/arch、sync/smp/sched、fs/drivers、net/ipc、probes/acpi、user/lib、
build/tools/docs。审查对象为当前 worktree 代码与验证门禁。

### 6.2 本轮已修复（分组）

**内存安全**
- mprotect / mmap(MAP_FIXED) 范围检查
- mprotect 时 COW unshare
- mremap 尺寸上限 + live-PTE 检查
- slab 大分配 header 修复
- ramdisk/splice 偏移下溢
- preadv/pwritev fd 边界检查
- fork readahead 共享修复
- ICMP echo 栈溢出
- keepalive u32 溢出
- swapOut/COW 释放物理帧前先做 TLB shootdown

**并发/生命周期**
- futex 丢失唤醒 + LOCK_PI + 超时
- wakeN requeue
- TCB 生命周期 + listen 清理
- UDP 端口释放 / EADDRINUSE
- epoll 超时 + pool 锁
- AF_UNIX peer 链接
- ARP 锁
- RX 校验和验证
- writeback 按 inode_id 键控 + truncate/unlink 失效
- fat32 tombstone 删除
- page_cache 拷贝出 + 锁外刷盘
- tmpfs 引用计数
- NVMe/AHCI/virtio-blk/e1000 加锁
- sysv_sem / msgrcv / posix_timer / MINIX IPC 修复
- ACPI 长度验证

**性能**
- 调度器 steal 跳过 + 低开销 active 计数
- writeback 专用内核线程（`vfs.zig` `startWritebackThread`）
- 按 CR3 过滤的 TLB shootdown（`kernel/arch/x86_64/tlb.zig` 三参 `shootdownRange`）
- TCP 发送暂存（staging）
- shm/mq 锁范围收敛 + SHM 退出 detach + mq 等待队列 + mq_attr ABI

**用户态**
- sh.c 管道 fd ABI / sigaction / O_TRUNC / stdin yield
- hello13 ppid
- hello3 open 检查

### 6.3 SMP #GP 根因（验证期间查明）

`shootdownRange` 的 `sti` 窗口会把调度嵌套进缺页帧（page-fault frame），是 SMP 下
间歇 #GP 的根因。修复：`TlbLock` 改为关中断自旋，并在自旋中手动服务本核的
shootdown 广播请求（`kernel/arch/x86_64/tlb.zig`）。

### 6.4 验证

| 门禁 | 结果 |
|---|---|
| `zig build` (x86_64) | 通过 |
| `zig build -Darch=riscv64` | 通过 |
| `zig build -Darch=aarch64` | 通过 |
| `zig build test` | 通过 |
| QEMU smoke SMP=1 | 通过 |
| QEMU smoke SMP=4 | 通过 |

### 6.5 本轮明确未修复（留待下一轮）

以下 18 项已全部于 2026-08-01 补完（提交 `fix: implement deferred review items`）：

- ~~vfs 已解码但不执行 O_APPEND / O_TRUNC~~ → open 存入 status_flags（F_GETFL/F_SETFL 生效），write 路径执行 O_APPEND，tmpfs/fat32/ext2 实现 O_TRUNC（新增 `tmpfsTruncate`、`fat32.truncateFile`）
- ~~socket fd 上限硬编码 16/32~~ → 统一改用 `vfs.MAX_FDS`
- ~~信号不会唤醒阻塞中的任务~~ → `sendSignal` 增加 `kickIfBlocked`（unblockTask + 跨核 kick）；semop/timerfd/epoll/futex/posix_mq 等待循环在唤醒后检查 pending 信号，致命信号走 exitTask，其余返回 -EINTR
- ~~SIGINT/sigaction ABI 截断（28B vs 152B）~~ → signal_mask 扩为 u64；sigaction 在缓冲区足够时读取 offset 24 的 8 字节 sa_mask（28 字节旧调用方兼容）；sigprocmask 支持 sigsetsize=8
- ~~AF_UNIX connect/send 未接入系统调用~~ → connect/sendto/read/write 已接线（STREAM/已 connect 的 DGRAM）
- ~~DNS/DHCP 接收路径~~ → 查询前注册端口、等待循环内泵 RX、255.255.255.255 广播直接用广播 MAC；parseIpV4 改 u32 累加防 panic
- ~~netif 硬编码 10.0.2.15~~ → DHCP 已配置时返回 `dhcp.getIp()`
- ~~panic 不停 AP + 串口锁递归~~ → `panicking` 原子标志：AP 在定时器 tick 检查并停驻；panic 重入回退到无锁 0x3F8 直写
- ~~x86 符号表为死代码（344KB BSS）~~ → x86 不再初始化，MAX_SYMBOLS 缩至 64
- ~~`mapAcpiRegion` 在 1GiB HHDM 下为空操作~~ → 改为带覆盖校验的 no-op 并在失败时告警
- ~~`sk5.zig` 无引用~~ → 已删除
- ~~RwLock/SeqLock/TicketSpinlock 未使用且有缺陷~~ → RwLock 全程关中断 + writer_wait 全程有效；SeqLock 更名 readNeedsRetry 并加获取屏障；TicketSpinlock 增加中断屏蔽
- ~~execve argv[0] 前置行为与 Linux 不一致~~ → 按 Linux 语义使用用户 argv，sh.c 相应补 argv[0]
- ~~fat32 `setFATEntry` 忽略读失败~~ → 返回 bool 并全量传播
- ~~NVMe admin queue 引导后无锁~~ → 增加 admin_lock
- ~~`kernel/boot_info.zig` 孤儿文件~~ → 已删除
- ~~空目录 `tools/mkimage`、`tools/qemu_run`、`tools/test_runner`~~ → 已删除
- ~~posix_mq 超时精度受限于唤醒事件~~ → 增加 futex 风格 deadline 位图 + sched 维护 tick 驱动的 `posix_mq.timerTick`

本轮顺带修复：AIO 负 offset panic 与字节计数、file_io 首块错误返回、非 ext2 truncate 假成功、shutdown 监听槽泄漏、UDP 端口 fork 引用计数、pipe 读端关闭后 EPIPE/SIGPIPE、timerfd 虚假 -1 与周期过期累计、sysv_sem SETVAL 唤醒、mq_close/mqNotify、tcp sendto EDESTADDRREQ、recvmmsg 预校验、epoll 事件忙等、readahead 双插入、wb_tick 无锁、ext2 跨 fd 过期 inode.size。

仍遗留（下一轮）：EINTR 未覆盖 ipc.zig receive/file_lock F_SETLKW/waitpid 阻塞；panic 停 AP 为 tick 检查（~10ms 延迟）而非 NMI；servers/、lib/、drivers/ 空占位目录保留作意向文档。

---

### 6.6 基础设施补完轮次（2026-08-02）

性能优先、安全可靠、全程 TDD（先 host 单测红→实现绿→QEMU 运行时标记→文档→独立提交）。

| 阶段 | 内容 | 验证 |
|---|---|---|
| F0 | host 单测基础设施：`zig build test` 从 4 模块扩到 11（新增 eth/ipv4/ipv6/tcp_util/udp_util/errno/fmt 行为测试；`kernel/host_test.zig` 再导出根 + `docs/build-and-toolchain.md` §13 约定） | 22 测试通过 |
| F1 | NVMe MSI-X 中断驱动（性能核心）：`pci_msix.zig` 纯解析模块（host 单测）、每 I/O 队列一向量（242-245）、ISR 收割 CQ 唤醒提交者、通道所有权取代全程持锁、500ms 有界等待回退轮询、QEMU 挂载 NVMe 设备 + 引导自测（"interrupt-driven read verified"）；顺带修复 QEMU 10 拒绝的 CC 队列项尺寸字段 | smoke SMP=1/4，MSI-X 标记 |
| F2 | loopback 接口：`lo.zig` 回环设备（host 单测），udp/tcp 发送路径对 127/8 绕过 ARP 直投 lo，netPoll/e1000 ISR 排干回送队列；`hello43` 验证 127.0.0.1 上 TCP+UDP 回环 | hello43 PASS |
| F3 | SCHED_FIFO/RR 实时调度类：`sched_policy.zig` 纯策略模块（host 单测），RT rankKey 压制 OTHER、FIFO 无量子、RR 10-tick 轮转、nice 正交；新增 syscall #473-476（Linux 号在本分发表被占用）；`hello44` 运行时验证 | hello44 PASS |
| F4 | moqi_libc 最小 freestanding C 运行时（crt0/unistd/string/stdio-lite/malloc），TDD 宿主测试 91 checks；`sh` 与 `hello10` 迁移示范；`lib/zig_crt/start.zig` | smoke 标记不变 |
| F5 | `servers/init/main.c` C 版 init 取代 1246 行汇编 init.S（静态 parity 校验 119/119 输出事件一致；init.S 保留作回退） | smoke 全标记 |
| F6 | EINTR 补覆盖：ipc.zig receive、file_lock F_SETLKW/flock、waitpid 阻塞路径接入 pendingFatal/pendingAny 协议 | ast-check + smoke |

**调试中发现的两个深层问题（均已修复）**：

1. `sched_setaffinity` 整数收窄 panic：`@min(u32, comptime 32)` 被收窄为 u6，`to_copy * 8` 在 cpusetsize≥8 时整数溢出——该 syscall 此前从未被真实调用过。显式标注 u32 修复。
2. hello44 "fifo child preempted"（SMP=4 偶发）根因链：重调度 IPI 可为任意唤醒抢占运行中的 RT 任务（已加 `peekBestRankKey` 防护）；更根本的是 **setaffinity 不迁移运行中的任务**——hello44 钉 CPU 0 时实际在别的核上运行，父子进程并行执行，"同核压制"前提不成立。诊断方法学：hello44 打印 c0/c1 差值 → 内核 RTDIAG（无 RT 抢占）→ AFFDIAG（无亲和违规）→ 定位到 first-schedule 不经诊断路径 → 确认缺迁移。
3. SMP 压测又暴露三个既有缺陷：`pendingAny` 把默认忽略的 SIGCHLD 也算作 EINTR 条件，导致 waitpid 第二个子进程等待被前一个子进程的 SIGCHLD 虚假打断（新增 `pendingActionable` 谓词——仅"装了 handler 或默认终止"的信号才产生 EINTR，12 处等待点全部切换）；`exitTask` 唤醒 waitpid 父进程时只置 `.ready` 不入队，忙核上队列优先的 pickNext 会让父进程无限饥饿（hello33 偶发挂死），改为置位后经 `per_cpu.enqueueTask` 重新入队；阻塞 waitpid 被**非目标**子进程的退出唤醒后返回 0（虚假成功，hello44 RR 测试 SMP=1 确定性失败），改为重扫描后重新阻塞（无子进程可等时返回 -ECHILD）。hello14/19/27 的 ARP/connect 偶发失败确认为 QEMU slirp 既有抖动（历史日志约 10% 出现率），不在本轮范围。

**仍遗留**：panic 停 AP 为 tick 检查而非 NMI；RT 任务唤醒抢占为尽力而为（同 rank 不抢）；servers/ 服务化与 drivers/ 用户态驱动属长期微内核目标未启动。

---

### 6.7 基础设施补完·第三轮（2026-08-03）

性能优先、安全可靠、全程 TDD（host 单测红→绿 → hello45-47 运行时测试 → smoke 门槛 → 文档 → 独立提交）。

| 阶段 | 内容 | 验证 |
|---|---|---|
| G1 | libc argc/argv/envp：内核 `buildUserStack` 修复 envp 字符串缺失与对齐 pad 位置（argv/envp 恒连续），execve 透传 envp；crt0 解析 SysV 初始栈调 `main(argc,argv,envp)` + `environ` + libc `getenv`；hello45 端到端验证 | hello45 PASS |
| G2 | **文件映射 mmap MAP_PRIVATE（本轮性能核心）**：mmap 只记录后备元数据，缺页按需供给——tmpfs/page_cache 帧零拷贝共享（只读 + COW 位），写入走既有 handleCowFault 私有复制；越 EOF 整页 SIGSEGV、部分页尾部清零；page_cache 驱逐跳过 refcount>1 帧（防复用活帧）；ext2 槽位 retain/release 对称；fork/exec 元数据随行。ramdisk 因非 PMM 内存改为私有副本（文档注明）。纯逻辑抽 `kernel/mm/filemap.zig` 入 host 单测 | hello46 PASS |
| G3 | 引导时 DHCP：`main.zig` 在 NIC 初始化后 `dhcp.discover()`，修复引导期（中断未开）tick 不走导致的死等（5M 迭代兜底）；`[DHCP] lease: x.x.x.x` / `[DHCP] no lease, static` 唯一标记行（内部日志降小写） | smoke 门槛含 `[DHCP] ` |
| G4 | klog 64KiB 环形缓冲（IrqSpinlock，ISR 安全，整行淘汰）+ `/dev/kmsg` 只读 fd（每 fd 独立游标）；纯逻辑 `kernel/lib/kmsg_ring.zig` host 单测 9 项；为将来 syslogd 奠基 | hello47 PASS |
| G5 | TRIM/discard：NVMe Dataset Management（ONCS 探测，I/O 队列通道所有权路径）、virtio-blk DISCARD（特性位探测，无则 no-op）、AHCI 复用既有 trim；`block_dev.discard` 统一路由；fat32/ext2 释放簇/块时批量合并后下发（`kernel/lib/trim_ranges.zig` host 单测 7 项） | fs 写删测试无回归 |
| G6 | `ipc.zig` send/call 阻塞路径补 EINTR（pendingFatal/pendingActionable） | smoke |

**调试记录**：① DHCP 引导即 panic "incorrect alignment"——`receiveOffer/receiveAck` 把 `align(1)` 栈数组 @ptrCast 为 extern struct 指针（该路径此前从未在 x86 引导运行过），缓冲区按 `@alignOf(DhcpPacket)` 对齐修复；② hello46 初版测试在 EOF 前 1 字节处 pread 4 字节并期望返回 4——内核短读语义正确，修正测试期望为 1。

**验证**：`zig build`（x86_64/riscv64/aarch64）+ `zig build test`（新增 filemap/kmsg_ring/trim_ranges/dhcp 单测）+ QEMU smoke SMP=1/SMP=4 全绿（hello45/46/47、`[DHCP]` 已入门槛）。

**仍遗留**：MAP_SHARED 写回（mmap 当前拒绝 EOPNOTSUPP）；mremap 文件区域仅支持收缩；内核态 copy_to_user 不触发文件缺页；PCID/2MB 大页/servers 服务化/drivers 用户态驱动为后续候选；slirp ARP 抖动为环境问题。

---

### 6.8 基础设施补完·第四轮（2026-08-04）

| 阶段 | 内容 | 验证 |
|---|---|---|
| H1 | **MAP_SHARED 文件映射 + 回写**：共享可写帧（无 COW）——tmpfs 直写页面天然一致；ext2/fat32 缺页经 page_cache 帧可写映射 + 标脏，msync/munmap/exit 经 `flushMappedInode` → `writePageByInode` 回写（mmap 页使用 bit-63 标记的独立 4K 缓存命名空间，避免与 ext2 1KiB 块/fat32 簇键冲突）；ramdisk 可写共享拒绝 EROFS；回写后使读命名空间陈旧页失效（`invalidatePage`）；fork 共享区域跳过 COW 降级 | hello48（tmpfs 跨进程共享/ext2 回写/ramdisk EROFS） |
| H2 | G2 遗留：mremap 文件区域允许原地增长（新页按需缺页，越 EOF 访问 SIGSEGV）；mprotect 更新区域 prot 元数据（部分覆盖时拆分，ext2 引用对称） | host 单测 + hello46/48 |
| H3 | **PCID**：CPUID 检测（TCG 不支持→legacy 路径不变；`pcid_enable` 编译期开关）；`pcid_alloc.zig` 纯逻辑分配器 + 逐 PCID 失效代际计数（复用安全）；`switchCr3` 统一 CR3 写路径（同空间命中代际→no_flush 位，否则 flush）；用户映射 global 位断言门（审计全部 user 映射 global=false）；shootdown 代际核对防漏过滤 | 72/72 host 测试；smoke 双 PASS |
| H4 | panic 立即停驻 AP（NMI 广播 `sendNmiAllButSelf`，tick 检查兜底）；修复 KVM 引导期 LAPIC 未映射时 EOI 写 0xB0 崩溃（early-IRQ 防护） | 编译+smoke |

**调试记录**：① hello48 ext2 回写失败根因不是写回路径而是**读侧陈旧缓存**——缺页时 readFile 顺带填充的未标记命名空间条目在 pread 时被优先命中，writePageByInode 后按块失效修复；② hello44 fifo flaky 第三次复发，根因链最终定位：**setaffinity 迁移在原 CPU 无其它可运行任务时沉默失败**（调度器"无可选则保持当前"），修复为先入队目标 CPU 队列再重调度；`AFFDIAG`（钉核任务被调度到错误 CPU 时告警）作为常驻金丝雀保留；③ PCID 在 TCG 不可用，KVM 下暴露 LAPIC 早期 EOI 崩溃（与 PCID 无关的既有 bug，已修）。

**仍遗留**：真实硬件 PCID no-flush 路径未经硅验证（TCG 不支持，KVM 现可引导待测）；MAP_SHARED 与 write() 交错且未 msync 时语义弱于 Linux（§1.8.1 已注明）；mremap 文件区域不支持移动增长；2MB 大页/servers 服务化/drivers 用户态驱动为后续候选。

---

### 6.9 基础设施补完·第五轮（2026-08-05）

| 阶段 | 内容 | 验证 |
|---|---|---|
| I1 | **用户 2MiB 大页匿名映射**：≥2MiB 对齐匿名映射优先按整块大页分配（`pmm.allocContiguous(512)`，失败回退 4K）；新页表操作 `demoteHugePage`（2MiB PDE → 512 个 4K PTE）——所有部分变更路径（部分 munmap/mprotect/mremap 收缩/fork COW/缺页）一律先 demote 再复用 4K 逻辑，仅「整块分配+整块释放」是纯大页路径；swap/reclaim 跳过大页；`huge_user_enable` 编译期门控；顺带修复 `destroyUserSpace` 大页帧泄漏与 `isUserAccessible/isUserWritable` 大页感知 | hello49（内容/mprotect demote 后数据保持/部分 munmap/fork COW） |
| I2 | **servers/syslogd**——首个用户态系统服务：moqi_libc 编写，消费 `/dev/kmsg` 写入 `/tmp/kern.log`（O_APPEND；tmpfs 单文件 256KiB 上限前的单代轮转）；100ms nanosleep 轮询不忙等；init 在测试序列后 spawn（不 waitpid） | `[syslogd] started` 入 smoke 门槛 |
| I3 | **NVMe per-CPU 队列绑定**：`pickQueue(cpu_id, n, busy_mask, rr)` 纯函数——优先 `cpu_id % num_io_queues`（同核提交、ISR 同向量），首选忙时回退轮询；内核线程（写回刷盘）固定队列 0 | host 单测 + NVMe 自测标记回归 |

**说明**：sched_lock 完整拆锁继续推迟——需要先扩展 `qemu_smoke_stress.sh` 的 SMP 压力覆盖作为安全验证前提（下一轮前置项）。I1 代理复核发现的既有小漏（4K PROT_NONE 后 munmap 泄漏帧、`destroyUserSpace` 对 1GiB PDE 的释放）已记录待修。

**调试记录**：① hello49 静默死亡根因——`pmm.allocContiguous` 返回**非 2MiB 对齐**的物理帧，大页 PDE 保留位置位导致首次访问即 #PF（用户态 SIGSEGV 无 handler 时静默退出、无 [exit] 输出，使死因一度不可见）；修复为新增 `allocContiguousAligned(count, align)`，并给缺页失败路径加了 `[#PF]` 诊断行（常驻）。② hello49 测试自身三处断言矛盾（整页填充覆盖边界字节、page300 验证未计入刻意写入、pattern 边界索引），修正测试。

**仍遗留**：kmsg 阻塞读（syslogd 暂轮询）；drivers/ 用户态驱动框架；大页不支持文件映射；SMP 压力测试扩展；真实硬件 PCID 验证。

---

### 6.10 基础设施补完·第六轮（2026-08-06）

| 阶段 | 内容 | 验证 |
|---|---|---|
| J1 | **SMP 并发压测 hello50**：4 worker 跨核并行（tmpfs 写读删/pipe/loopback UDP/mmap 循环，迭代相关模式字校验），纳入 init 序列与 smoke 门槛 | SMP=1/2/4 |
| J1 战果 | hello50 揪出三个深藏内核 bug：① **AP 启动从未设置 CR0.WP**——AP 上内核写绕过页写保护，copyToUser 直写共享 COW 帧（"tmpfs verify" 损坏真相，SMP=1 从不触发因 BSP 有 WP）；② UDP 端口索引 TOCTOU（查用分离两个临界区，releasePort swap-remove 重排后投错队列）；③ FPU lazy-switch 不防迁移（`fpu_owned` 单布尔跨核误判 → fxsave 丢失、fxrstor 陈旧重放）+ popRunnable 缺亲和检查（AFFDIAG 实锤 tid=69 pin=0 cpu=2） | 修复后 8/8 SMP=4 全绿、AFFDIAG=0 |
| J2 | **sched_lock 细化（性能核心）**：Task.state 原子认领协议（`sched_claim.zig` 纯模块，cmpxchg ready→running 独占任务），pick/pop 走队列锁+认领，anchor/CR3 切换仅在认领成功后；老任务最后发布以收窄双栈窗口；`sched_fine_grain_enable` 编译期回退门控（旧全局锁路径 `timerTickLegacy` 逐字节保留）；stats/计数路径原子化 | 89/89 host 测试；smoke SMP=1/4；**stress SMP=4 十连全绿** |
| J3 | kmsg 阻塞读：`kmsgReadOrBlock`（锁内读+阻塞注册防丢唤醒），append 时 ISR 安全 wakeOne + epollNotify；epoll 按游标真实上报 EPOLLIN（修掉恒 EPOLLIN 忙等）；syslogd 去轮询改事件驱动；hello47 改 O_NONBLOCK（G4 行为变更适配） | hello47/50 PASS |
| 顺带 | unlink #111 路由 tmpfs（hello50 暴露）；waitpid 等信号协议在新增阻塞点保持一致 | smoke |

**仍遗留**：timerTick 切换路径的旧任务内核栈窗口已收窄但未完全消除（sched.zig:469-491 注释）；tryStealTask 死代码（若启用需补 onContextSwitch）；fork COW 降级仅本地 invlpg（PCID no-flush 重入下理论窗口，未触发）；drivers/ 用户态驱动框架；真实硬件 PCID 验证。

---

### 6.11 基础设施补完·第七轮（2026-08-07）

| 阶段 | 内容 | 验证 |
|---|---|---|
| K1 | **目录项缓存 dcache**（VFS 性能）：`(fs, parent, name)` → 子项 id，512 项直接映射（FNV-1a + 冲突替换）；ext2 全部命名查找路径（walkPath/resolveParent/rename/unlink/hardlink/symlink）命中即跳过目录块读取；fat32 缓存根目录 files[] 槽位（带防御性重校验，陈旧即回退慢路径）。失效策略保守：ext2 按父 inode + 子 inode 精确失效（addDirEntry/removeDirEntry 的 defer 覆盖失败路径）；fat32 因墓碑槽复用按全表失效。锁序 `fs_lock → dcache.lock`（叶子，绝不持锁做 I/O） | host 单测 10 项 + fs 全套回归 + hello50 |
| K2 | **slab per-CPU magazine**（分配器性能）：每核每 size-class 8 槽 LIFO 杂志——kmalloc/kfree 快路径关中断弹压本地杂志（无需跨核锁；本调度器下关中断窗口内 CPU 不会变，迁移安全论证见文档），空则批量 refill 4 个、满则批量归还 4 个（池锁仍串行池访问）；大对象路径不变；`slab_magazine_enable` 门控，关闭即旧路径逐字节还原；所有权不变量（对象必恰好存在于 池自由表/某核杂志/用户手中 之一）经 20000 步确定性压力单测验证 | host 单测 8 项 + hello50 + stress |
| K3 | **IPv6 loopback ::1**：tcp/udp v6 发送路径对 ::1 绕过 NDP 直投 lo（src=dst=::1，镜像 v4 的 F2 设计），`netif.isLoopbackV6` | smoke 回归 |
| K4 | **fork COW 降级 shootdown 补漏**（正确性）：fork 按页表批量化降级后的失效（每 PT 一次 `shootdownRange`，CR3 过滤），clone 末尾本地 reloadCR3 改为按地址空间过滤的广播——闭合 PCID no-flush 重入下迁移父进程残留可写陈旧项的理论窗口 | fork 密集测试回归 |

**仍遗留**：timerTick 旧栈窗口残余；tryStealTask 死代码；drivers/ 用户态驱动框架与 devmgr（下一轮评估）；真实硬件 PCID 验证；MAP_SHARED 与 write() 交错的弱语义。

---

### 6.12 基础设施补完·第八轮（2026-08-08）

| 阶段 | 内容 | 验证 |
|---|---|---|
| L1 | **用户态驱动框架 v1**：新增 syscall #477-482——`dev_map_mmio`（MMIO 白名单校验：`pmm.isRamPhys` 拒绝 RAM 帧，防映射普通内存；`no_free` 区域标志保证 unmap 不误释放非 PMM 帧；fork COW 跳过非 RAM 帧）、`dev_irq_register/wait/unregister`（PIC GSI 0-15，内核占用互斥 EBUSY，edge 计数防丢，EINTR/超时协议）、`dev_dma_alloc/free`（coherent 分配 + 用户映射，exit 自动清理）；`/dev/pci` 枚举快照；全部入口 `CAP_SYS_RAWIO` 门控（在 ALL_CAPS 内，现状不变） | host 单测 + hello51 端到端 |
| L2 | **hello51 端到端证明**：用户态程序经 /dev/pci 找到 e1000 → 映射 BAR0 → 读出 STATUS 与 MAC（52:54:00:12:34:56 与内核引导一致）；IRQ 注册/超时/注销语义；DMA 分配读写释放 | hello51 PASS 入 smoke 门槛 |
| L3 | **timerTick 旧栈窗口**：评估并尝试延迟发布（pending_release + 入口 flush），实测导致任务活性回归（SMP=1 挂起），**已回退**为 J2 的即时发布——剩余 [release → iretq] 窗口为几条尾声指令、从未观测到碰撞，作为已接受窗口记录在代码注释与本文档 | 回退后全量验证 |

**调试记录**：hello51 的 FREE_GSI=10 写死与本机 e1000 IRQ（10）冲突——改为扫描 /dev/pci 全部 irq= 行动态选空闲 GSI。

**仍遗留**：tryStealTask 死代码；IOAPIC 缺失（GSI≥16 不可路由）；framebuffer 类 Limine-usable 内存被 MMIO 白名单拒绝（保守方向）；devmgr（设备节点管理）未做；真实硬件 PCID 验证；MAP_SHARED 弱语义注记。

---

### 6.13 基础设施补完·第九轮（2026-08-09）

| 阶段 | 内容 | 验证 |
|---|---|---|
| M1 | **IOAPIC 驱动**（`ioapic.zig` + 纯逻辑 `ioapic_core.zig`）：MADT 地址映射、VER 读取重定向项数（QEMU 24 项）、REDTBL 编程（先高双字）；PIC 路径（GSI 0-15）逐字节不变；userdrv `dev_irq_register` 扩展至 GSI≥16（路由到用户向量段 100-127，BSP 投递）；引导标记 `[IOAPIC] initialized (N entries)` | host 单测 + hello51 回归 |
| M2 | **ioperm（TSS I/O 位图）**：每任务 8KiB 位图懒分配（syscall #483 `ioperm_set`，CAP_SYS_RAWIO 门控），**每次上下文切换与 RSP0 同点装载**（防上一任务权限泄漏——安全关键点）；fork 继承独立副本、exit 释放；`ioperm_enable` 门控；hello52 端到端：用户态直接 inb/outb 读 RTC，撤销权限后访问收 #GP（退出码 141=128+13） | 120/120 host 测试 + hello52 |
| M3 | 接线与门禁：hello52 入 init/smoke；三架构编译 | smoke SMP=1/4 |

**仍遗留**：IOAPIC 未消费 MADT ISO 覆盖（电平/极性）；GSI≥16 无真实设备验证（QEMU 默认无高 GSI 设备）；devmgr 未做；真实硬件 PCID 验证。

---

### 6.14 基础设施补完·第十轮（2026-08-10）

| 阶段 | 内容 | 验证 |
|---|---|---|
| N1 | **devfs 设备节点注册框架**：`devfs.zig` 注册表（32 槽，`NodeOps{open/read/write/poll,flags}` + `IoCtx` 游标/标志透传），vfs.open 的 /dev 分支改为纯查表（未注册名 ENOENT）；既有 urandom/kmsg/pci 全部迁移为注册节点（kmsg 阻塞协议原样迁入 devfs_nodes），新增 null/zero/full/tty；`getdents("/dev")` 枚举注册表；epoll 经节点 poll 回调（kmsg 游标准确上报）；tryStealTask 死代码删除（无调用者且绕过 onContextSwitch 的 FPU 隐患路径） | host 单测 + hello47/51/52 回归 |
| N2 | **servers/devmgr 极简起步**：轮询 `getdents("/dev")` 跟踪节点集变化，`[devmgr] started` 入 smoke；文档注明 devfs 事件钩子就位后转事件驱动 | smoke |
| N3 | **MADT ISO 覆盖**：type-2 条目解析进 `info.isos`，ioapic.routeGsi 按覆盖应用电平/极性（无覆盖则 edge/active-high 不变） | host 单测 |
| N4 | hello53 端到端：getdents /dev 全节点、null/zero/full/tty 语义 | hello53 PASS 入门槛 |

**仍遗留**：devfs 仅内核注册（无用户态注册/热插拔通知）；GSI≥16 无真实设备验证；真实硬件 PCID 验证；驱动迁出内核（v2 评估）。

---

### 6.15 基础设施补完·第十一轮（2026-08-11）

| 阶段 | 内容 | 验证 |
|---|---|---|
| P1 | **devfs 用户态节点（微内核设备模型小型化）**：syscall #484 `devfs_register` → 节点 + ctrl_fd；客户端 read/write 经请求队列转发 `{seq,op,offset,len}`（≤4KiB），所有者 `read(ctrl_fd)` 取请求、`write(ctrl_fd, {seq,ret,data})` 应答；seq 单调防串扰、客户端阻塞带完整信号协议、**owner 死亡全量 -EIO 唤醒 + 节点墓碑化**（exitTask 钩子）；锁序 `alloc_lock → node.lock → 调度锁`，阻塞不持锁 | host 单测 8 项 + hello54 |
| P2 | **devfs 变更事件**：原子 change_counter + `/dev/devfs-watch` 阻塞读节点；devmgr 从 1s 轮询改为事件驱动（watch 阻塞读，缺失时回退轮询） | smoke |
| P3 | **hello54 端到端**：子进程注册并服务 /dev/echo54，父进程写读回环 + 第二客户端 + kill 服务进程后 EIO/ENOENT 语义。首次实跑发现死锁：`parseResponse` 对 write 响应误用 read-only 长度规则（8 字节无数据响应被 -EINVAL 拒绝），修复为 op 无关解析 + `Core.complete` 按请求类型校验（补回归单测） | hello54 PASS 入门槛 |

**性能取舍**（已写入 kernel-subsystems §3.9）：用户态节点每 I/O 一次往返，仅用于配置/控制类非热路径设备；块/网热路径设备留内核。

**仍遗留**：proxy 节点 poll 恒 EPOLLIN|EPOLLOUT（v1）；proxy ctrl 的 poll/select 未接（epoll 已接）；用户态节点槽位不复用（≤8 累计）；GSI≥16 无真实设备验证；真实硬件 PCID 验证。

---

### 6.16 基础设施补完·第十二轮（2026-08-12）

| 阶段 | 内容 | 验证 |
|---|---|---|
| Q1 | **devfs proxy 语义 v1.1**：真实 poll（`Core.pollMask`——"可入队不阻塞"：owner 存活且队列未满则就绪，owner 死亡恒就绪防 epoll 永久阻塞）；ctrl fd 的 poll/select 接通（排队请求→POLLIN，与 epoll 一致）；客户端 O_NONBLOCK 门控入队接受（满则立即 -EAGAIN，中途等待保持阻塞——与本内核管道语义一致）；代际（generation）防槽位复用后陈旧 fd 误用 | host 单测 + hello54 回归 |
| Q2 | **devfs 槽位复用**：tombstone 槽位最老优先回收，复用时全量重置 proxy 状态（队列/inflight/owner），Entry.generation 守卫陈旧 fd；变更计数保持单调 | host 单测（复用顺序/状态隔离/陈旧契约） |
| Q3 | **静态 hosts 表**：`dns.resolve` 先查内置表（localhost→127.0.0.1、gateway→10.0.2.2，大小写不敏感），静态名永远可解析；真实 DNS 仍依赖宿主机可达性（环境限制，文档注明，不做门槛断言） | host 单测 |
| Q4 | 门禁：三架构编译 + 139/139 host 测试 + smoke SMP=1/4 + stress 10 连 | 全绿 |

**仍遗留**（环境或后续）：GSI≥16 真实设备验证、真实硬件 PCID、真实 DNS 端到端（依赖宿主机 DNS）、驱动迁出内核评估（v2）。

---

### 6.17 基础设施补完·第十三轮（2026-08-13）

| 阶段 | 内容 | 验证 |
|---|---|---|
| R1 | **/dev/fb0 + fbinfo 节点**：fb 帧经独立映射路径共享可写映射给用户态（fb 在 Limine usable RAM，dev_map_mmio 白名单拒绝——`fbdev.mmapFb`：MAP_SHARED 强制、逐帧 addRef 永久钉住、no_free 区域记账）；mmap fb0 时**自动停用 fbcon 镜像**（否则 present() 周期性覆盖用户像素） | hello56（像素块写读回环） |
| R2 | **fbcon 文本控制台**：VGA 8x16 字体（提取自 ReactOS FreeLoader，GPL 兼容注明），串口输出镜像渲染到 fb（行缓冲/滚屏/光标，双缓冲 present），零分配，`fbcon_enable` 门控 | 引导 160x50 控制台 |
| R3 | **PS/2 鼠标**：i8042 辅助通道初始化（ps2.zig 共享锁与 keyboard 命令协调）、IRQ12、3 字节包解析（位 3 重同步）、/dev/mouse 事件节点 | 初始化标记 + hello56 |
| R4 | **RTC 墙钟**：引导读 CMOS RTC 得 epoch 基准（世纪规则 00-69→2000s；BCD/12h 处理），gettimeofday/CLOCK_REALTIME = epoch + TSC 插值，CLOCK_MONOTONIC 不变 | hello56（>2020 下限 + 单调性） |
| R5 | 调试链：hello56 静默 SIGSEGV 根因为其 **syscall6/syscall4 包装器漏传 rdx（第 3 参数）**——prot/count 为垃圾值导致 RO 映射/pread 空读；新增常驻诊断 `[kill] tid=N code=M`（exitTask 信号死亡）与 `[#PF] user fault addr/rip/err`（Path 4 保护性缺页） | 全量验证 |

**仍遗留**：hello13 fork+SIGUSR1 路径存在低频 SMP #GP（iretq 帧损坏，~5-10% 复现率，与本轮特性无关，stress 多次全绿后偶发）——已定位为下一步专项目标；fbcon 被 fb0 映射单向停用（无恢复路径）；鼠标事件无压力测试。

---

### 6.18 SMP #GP 竞态专项修复（2026-08-13）

**根因链（两轮定位）**：① 初步判为 `exitTask` 唤醒路径对运行中父进程无条件覆写 `.ready`（加 `.blocked` 守卫）——**不充分，竞态仍发**。② 最终根因在 **waitpid/reapZombies 的内核栈释放窗口**：`isCurrentOnAnyCpu` 只判断僵尸任务"当前不在任何 CPU"，但退出 CPU 的切换尾声（commonStub epilogue）**仍在那条内核栈上执行**，此刻释放栈 → epilogue 读到已释放内存 → iretq 帧损坏 → `commonStub` #GP（表象为 hello13 父进程 tid=14）。

**根因链（多轮定位）**：① exitTask 唤醒无条件覆写 `.ready`（加 `.blocked` 守卫，保留）。② reap 的 `isCurrentOnAnyCpu` 不覆盖切换尾声，补 `sched_entries` reap 门（保留）。③ IST4 尝试引发级联，回退。④ **已确认的核心缺陷**：TSS.RSP0 与当前任务栈不同步——切换到内核线程（idle/writeback）时 RSP0 停在旧用户任务栈上，该任务迁移后本核中断帧写到已迁移任务的栈上。修复：a) 切换到内核线程时同步 RSP0/kernel_rsp/tid/ioperm（含首次调度路径）；b) **每次切换在 setCurrentIdx 处无条件同步 RSP0 到 incoming 任务栈**，从结构上消除漏网路径（经崩溃 dump 证实：修复前 TSS.RSP0 落在当前任务 kstack 之外）。诊断（RSP0STALE/DUALCPU 金丝雀、[SW] 切换追踪）已验证并移除。

**残余 #GP 的最终根因（第三轮，帧守卫实锤）**：在 commonStub 尾声（`movq %gs:16,%rsp` 之后、`iretq` 之前）加了**帧守卫**（校验待弹帧 rip 规范化 / cs 白名单 / 用户帧 ss+rsp），当场抓获：弹帧地址 `0x9019f3b0` ≠ 当前任务 `saved_rsp=0x9019ff50`，且帧内容是典型的**活动调用栈数据**（内核文本地址、HHDM 指针）。机理：**commonStub 入口无条件用当前帧地址覆写每核锚点 `%gs:16`，但尾声无条件信任该锚点**——处理程序执行期间任何嵌套的 commonStub 入口（如 fork 后 SIGUSR1 投递压信号帧时触发 COW 缺页 → 嵌套 #PF）都会把锚点顶成嵌套帧；嵌套返回后锚点停留在**已弹出的嵌套帧位置**，外层尾声于是把锚点处（此时是外层自己的活栈帧）当中断帧弹 → iretq #GP。这解释了全部既有证据：fork+SIGUSR1 强相关（COW #PF 是嵌套入口）、帧地址正确但内容损坏、SMP 下更高频（核间时序放大了缺页与信号投递的交叠）。

**修复（frame 指针随返回值走，不走每核锚点）**：
- `interruptDispatch` 改为返回 `u64`：未切换时返回**入口帧指针本身**（嵌套覆写锚点也无关——根本不读锚点）；切换路径经 `sched.switchAnchor` 置 per-CPU `anchor_switched` 标志，有切换才返回锚点值。标志保存/恢复是嵌套安全的（入口存旧值、出口还原）。
- commonStub 尾声 `movq %gs:16,%rsp` → `movq %rax,%rsp`。每中断返回成本仅数条指令。
- 锚点保留原有职责：commonStub 入口写入供切换路径 `old_task.saved_rsp = getAnchor()` 使用。
- **帧守卫转为常驻安全网**（frameGuardPanic：全帧 dump + 崩溃核 TSS.RSP0/cpu_id），异常 dump 同步改为打印崩溃核而非 CPU0。

**连环挖出的另外六处缺陷（同轮实锤修复）**：
1. **waitpid 唤醒竞态后状态未复位**：子在父 `waiting_for_child=true` 之后、`state=.blocked` 之前退出时，exitTask 清旗但跳过 `.ready` 写入，父以 `.blocked` 状态继续运行，下次切出即永久丢失。修复：hlt 环退出后若 `state != .running` 则复位（此时本任务必是本核 current，幂等）。
2. **僵尸滞留 current**：当前任务为 zombie/blocked 且队列无可运行时 `pickNextFg` 返回 null，CPU 永远停在僵尸上下文 → `isCurrentOnAnyCpu` 永远为真 → reap 永远被门挡。修复：当前任务不可运行且常规挑选为空时，回退挑选本核 idle/自举内核线程（带正规 claim）。
3. **waitpid 阻塞协议跨锁分裂**：旗标写入在锁外、扫描在锁内，唤醒可从两者之间滑过。修复：旗标 + 僵尸扫描 + `.blocked` 写入全部置于 `task_lock` 临界区内（`lockTask`/`waitpidScanLocked`/`hasChildrenLocked` 重构），与 exitTask 的唤醒段同锁互斥。
4. **信号帧被 handler 自身栈覆写**：`pushSignalFrame` 把 SignalFrame 放在 handler 入口 RSP **下方**——handler 的任何栈写入都会踩掉已保存的 rsp/rip 槽位，sigreturn 以损坏的 rsp 恢复 → 用户态局部变量错位。修复：SignalFrame 移到 handler 入口 RSP **上方**（trampoline 相应去掉 -160 调整）。同路径附带缺陷：`pushSignalFrame` 只保存 rip/rsp/rflags，sigreturn 把全部 callee-saved 寄存器清零——现随帧保存完整 `GpRegs`（tick 与 syscall 两条投递路径都改）。
5. **信号投递读取过期锚点（hello13 挂死的最终根因）**：`deliverSignalToRunningTask` 经 `getAnchor()` 取"当前帧"——若本次 tick 的处理程序此前发生过嵌套 commonStub 入口（如维护 pass 内的缺页），锚点指向**已弹出的嵌套帧位置**，读到的是活栈数据（探针实锤：保存到的 r8=14 而非 15、rip=0x100144e 落在指令中间——硬件不可能产生）。沿垃圾 rip/rsp 改写并压信号帧 → 用户态上下文被毁（hello13 的 waitpid 收到栈地址 0x7FFEC0 作为 pid → 过滤永不匹配 → 永久阻塞）。修复：三个调用点全部改为**直接传入入口帧指针**（`timerTickFg`/`timerTickLegacy`/`handlePageFault` 本持就有 `frame`），信号投递路径从此不读锚点。
6. **createUserProcess 创建窗口**：槽位预订（bitmap 置位）与字段初始化分属两个锁临界区，窗口内锁内读者可见陈旧/全零字段（`kernel_stack_top=0` 的"就绪内核线程"被挑中 → `setupInitialFrame` 减法溢出 panic）。修复：预订槽位时当即置 `.blocked`。

**验证中排除的假说**（均有实验证据）：双核同跑（claimed_cpu DUAL 检测三跑全零）、中断门嵌套（全 IDT 均为 0x8E 中断门，IF 入口即清）、栈槽双分配（每槽位固定虚拟窗口 + task_lock 保护）、丢唤醒（唤醒侧计数器证明唤醒先于旗标且合法空转）。

**已知残余**：SMP=4 下 hello13 仍有较高比例（10 连跑中 6 例）的 waitpid 挂死：父进程收到的 pid 是用户栈地址（0x7FFEC0），即信号投递时读到的帧内容异常（r8=14 为 fork 前的 parent_pid 值、rip=0x100144e 落在指令中间——非硬件可产生）。已排除：锚点误读（epilogue 与投递路径均已解耦）、信号帧被 handler 覆写、GPR 未保存、丢唤醒、创建窗口。当前最强嫌疑：投递发生前入口帧已被另一写入者损坏（跨核栈使用窗口或一字节级覆写），留待下一轮专项。串行多核打印交错会偶发涂抹单个标记行导致 smoke 脚本误报超时（逐 run 日志核验：无 FRAMEGUARD/PANIC 且到达 shell 即为通过）。

**验证**：三架构编译 + host 测试 + smoke SMP=1/4 + SMP=4 连跑（诊断代码 DUAL/FRAMEMOD/[wp]/WPSTALL/claimed_cpu 已全部移除）。

---

### 6.19 残余 hello13 挂死专项——结案（2026-08-14）

**结论：上一轮"已知残余"挂死由三个独立成因叠加，已全部闭合。**

1. **AP 从 x86 复位态继承 CR0.CD=1/NW=1（真 bug）**：实测挂死现场某核 `cr0=0xE001001B`（复位态 0x60000010 | PE/MP/TS/NE/PG）——AP bring-up 只 OR 了 PE/PG，`context_switch.initCpu()` 又只清 EM，CD/NW 从未清除，该 AP 整个启动周期以 cache-disabled 运行（慢 50-100 倍，且部分微架构下停 snoop 致内核结构脏读）。修复：`initCpu` 增加 `btr $29/$30`。
2. **懒 FPU #NM 活锁（真 bug）**：记录到同一 movups 上 94~178 次 #NM、每 timeslice（10 tick）循环一次——懒恢复模型（切出 fxsave + arm TS、首用 #NM 触发 fxrstor）在 SMP 抢占节奏下构成"arm→fault→clear→preempt→arm"闭环，指令永不完成。修复：改 **eager FPU**——`onContextSwitch` 仅 fxsave（不再 arm TS），新增 `onSwitchIn` 在切入时直接 fxrstor/fninit。改后 #NM 归零。
3. **"父进程冻结于入口指令、零执行"形态是取证探针自身造成的假象（重要教训）**：fentry/ripbytes 等探针在 tick 处理程序中逐 tick 串口打印（115200 波特每行数毫秒），制造"恢复即被下一 tick 抢占"的自持续饥饿风暴，表象与真 bug 无异。决定性对照：同一批次内，含探针的 4 轮全部"冻结"，探针移除后重建的 4 轮全部通过。**教训：中断/调度热路径禁止串口打印，探针只能放系统调用等冷路径或落环形缓冲。**

**最终验证**：移除全部 tick 路径探针后 SMP=4 八连跑全过（stormlines=0，#NM=0）；三架构编译 + host 测试通过。

**遗留说明**：上一轮记录的信号投递帧 rip=0x100144e（指令中间）未再复现——其与懒 FPU 活锁/CD 缺陷共因的可能性大；投递完整性探针（dispatch 入口快照 vs 交付值逐字节比对）曾证明帧与快照一致，即若再现亦非 handler 内改写。此处留存为观察项，不设专项。

---

### 6.20 基础设施补完·第十四轮（2026-08-14）：pthread 子集 v1

| 阶段 | 内容 | 验证 |
|---|---|---|
| 方案 | 盘点未实现基建（explore 代理全仓调研）：首选用户态线程——内核 clone(CLONE_VM/THREAD/SETTLS) 已就绪、futex 已就绪，价值/工作量比最高；CLONE_FILES 共享 fd 表与 __thread(PT_TLS) 列入 v2 | docs/kernel-subsystems.md §2.5a |
| TDD | 先写 hello57 验收测试（create/join/retval/mutex 竞争计数/once/specific/errno 隔离/tgid），再实现至绿 | hello57 全项通过 |
| libc | `pthread.h/pthread.c`：TCB（FS:0）线程模型；create/join/exit/self；glibc 风格 0/1/2 futex mutex（无竞争零 syscall）；once；32 keys getspecific；每线程 errno；crt0 装主线程 FS | 100000 次互斥自增全对 |
| 内核 | `Task.is_thread`；getpid 对线程汇报 tgid；waitpidScanLocked/hasChildrenLocked 跳过线程 | SMP=1 一次通过 |
| 接入 | build.zig（hello57→libc_programs、pthread.c→moqi_libc_sources）、init run_test、qemu_smoke.sh 标记、qemu_run.sh 打包清单 | SMP=4 首跑全过（标记涂抹为既有串行交错问题） |

**性能设计**：mutex 快路径一次 `lock cmpxchg`（无竞争零系统调用）；unlock 无争零唤醒；join 单次 futex 唤醒；TLS 一次安装后纯内存访问；futex 状态机与 glibc 同构。

**验证**：SMP=1 smoke 一次通过（hello57 100000 全对）；SMP=4 首跑通过；三架构编译 + host 测试通过。

### 6.21 基础设施补完·第十五轮（2026-08-15）：作业控制 v1 + 调度/睡眠修复三连

| 阶段 | 内容 | 验证 |
|---|---|---|
| 方案 | 盘点未实现基建：作业控制（ctty/前后台/SIGTTIN/kill(-pgid)/孤儿组）价值最高且内核已有 pgrp/session 骨架 | docs/kernel-subsystems.md §2.4a |
| TDD | 先写 hello58 五项验收（setsid 系列、后台读两类处置、TIOCSPGRP+SIGCONT 恢复、kill(-pgid) 广播、孤儿组 SIGHUP），再实现至绿 | hello58 全项通过（SMP=1/4） |
| 作业控制 | 新增 `proc/jobctl.zig`（单一终端模型：ctty_owner_sid/foreground_pgid、stdinJobCheck、tcSetForegroundPgrp、onSessionLeaderExit）；`Task.stopped` 独立标志；信号默认动作四分（terminate/ignore/stop/cont），SIGSTOP 不可捕获 | §2.4/§2.4a |
| 权限收紧 | syscall 层 setpgid/setsid/getpgid/getsid 全部委托 pgrp.zig（入口内联版无任何校验，任意进程可改任意任务 pgid）；syscallWaitpid 透传 options（WNOHANG 被丢弃曾是 waitpid 永久阻塞根因）；kill(-pgid) 广播 | 严格版 setpgid 生效 |
| 修复① | **nanosleep 忙等饿死**：syscall 全程 IF=0，忙等 nanosleep 期间 LAPIC 不触发，就绪任务饿死数秒 → 睡眠位图（sleep_bm + sleep_deadline_ns）+ 每 tick 唤醒，EINTR/fatal 协议与既有等待原语一致，槽位复用清残留 | §2.4b |
| 修复② | **运行队列 LIFO 饿死**：睡眠循环者反复压栈顶 + idle 每次切换重入队，把第三个就绪任务永久压栈底（hello54 子进程永远拿不到 CPU）→ 改 FIFO 轮转，popRtAware 非 RT 路径同步，SK-17 探针改断言 | §2.2 |
| 修复③ | **sigreturn 丢 rax**：syscall 出口 exec 重定向丢弃保存的 rax 并把新栈指针留在 rax——sigreturn 后用户拿到栈地址而非 syscall 返回值 → 重定向前先弹出原返回值 | hello58 测试 2（r==-4 且 handler 触发） |

**调试教训**：
- tick 路径（IF=0）内放串口打印会让"每次 iretq 后立即有 tick 到期"，被调试的子进程连一条指令都执行不到——观测本身制造挂死；tickalive/switch 类探针必须极低频或零打印。
- 测试自身的竞态（fork 后立即 setpgid 依赖调度顺序）要用 pgid 轮询或 pipe 同步消除，不能靠 nanosleep 时长赌。
- 本内核 pipeRead 非阻塞（空管道返回 0 而非等写者），测试要按此语义轮询。

**验证**：三架构编译 + host 测试通过；SMP=1 smoke 全绿（hello58 PASS）；SMP=4 smoke 全绿。

---

### 6.22 基础设施补完·第十六轮（2026-08-13）：统一验证收口 + 串口写原子化 + rlimit libc 包装器

| 阶段 | 内容 | 验证 |
|---|---|---|
| Limine 固定版本更正 | 上一轮引入的 `v8.0.14-binary` 固定不支持内核要求的 base revision 3（QEMU 直接 `Limine protocol not supported`）；更正为实际通过 smoke 矩阵验证的 `v8.7.0-binary`（`aad3edd`），同步 bootstrap 脚本、合约测试、README 与构建文档 | SMP=1/2/4 smoke |
| 串口写原子化（§6.18 已知残余关闭） | 用户态 stdout/stderr 写路径在 `file_io.zig` 中逐字节 `writeByte`，每字节释放一次串口锁，跨核写者字符级交错涂抹 smoke 标记行（SMP=4 两轮实测误报超时，日志人工核验实为全过）。改为按块（≤4096 字节）单次 `writeString`：每块一次锁获取，交错消除且锁开销下降 | 修复后 SMP=4 smoke 直接通过 |
| 测试程序适配创建元数据语义 | hello36/41/42/44/46/48/50 的 `O_CREAT` 打开原先传 mode 0（旧内核忽略 mode）；新语义下创建出 mode-0 文件导致重开被 DAC 拒绝（hello41/42/44/46/50 FAIL）。统一显式传 `0666`；hello53 `/dev/full` 读检查改 `O_RDWR`（O_WRONLY 描述符读现按 POSIX 返回 EBADF） | SMP=1 smoke 全绿 |
| rlimit libc 包装器 | 关闭 rlimit.md 的 "libc wrappers are future integration work"：新增 `include/resource.h`（16 字节 `struct rlimit` ABI、RLIMIT_* 常量）与 `src/rlimit.c`（原生 236/237/238），宿主机 ABI 测试 `test_rlimit_abi` 锁定 | host 测试 |
| 统一方案 | 新增 [next-phase-plan.md](./next-phase-plan.md)：剩余工作项按"正确性先于性能、小步可验证、锁粒度优先"排序为 P1/P2/P3 + 环境受限轨道 | — |

**验证**：host 测试（Zig 单元 + moqi_libc C + init supervisor 合约）+ smoke SMP=1/2/4 全绿 + ReleaseFast 构建通过。

---

### 6.23 P1 批次第一轮（2026-08-13）：UDP MSG_PEEK/TRUNC + 写盘错误传播收口 + P1 对账

**P1 对账（文档滞后修正）**：next-phase-plan.md 的 P1 九项逐项核对当前代码——
syncFile 错误传播（vfs.zig syncFile→bool→fsync EIO）、kmsg 阻塞读 + syslogd 事件驱动（J3）、
panic NMI 停 AP（sendNmiAllButSelf + tick 兜底）、IOAPIC MADT ISO 应用（routeGsi）、
tryStealTask 删除，共五项**代码早已完成**，文档记录滞后；已对账标注证据位置。

| 阶段 | 内容 | 验证 |
|---|---|---|
| UDP MSG_PEEK/MSG_TRUNC | recvfrom 此前完全忽略 flags。新增 `udp.recvFromEx`/`recvFromV6Ex`（报告数据报完整长度 + 可选不消费），recvfrom 的 UDP v4/v6 分支实现 MSG_PEEK（不消费）与 MSG_TRUNC（半缓冲也返回完整长度）；队列锁（J1 udp_lock）此前已就绪 | hello50 每 worker 四项新验收（peek 两次不消费、trunc 全长上报、消费后队列空），SMP=1/4 smoke |
| **sendto/recvfrom ABI 修复** | 两个 wrapper 的第 4 参数（flags）错读 `frame.rcx`——syscall 惯例 rcx 保存用户 RIP，第 4 参数在 r10。flags 长期被忽略所以从未暴露；本次随 MSG_PEEK 落地修正为 frame.r10 | hello50 flags 验收依赖正确传递，SMP=1/4 通过 |
| FAT32 写错误传播 | `setFATEntry` 吞掉 FAT 元数据写失败（已返回 false，调用点本已闭环）；`zeroCluster`/`updateDirEntry`/`deleteFile` 改返回 bool 并向上传播；deleteFile 在 tombstone 写失败时停止释放簇链（避免活动目录项引用被释放簇）。createFile 回滚路径的 `_ = setFATEntry(nc, 0)` 属 best-effort 释放（create 已失败，泄漏一簇等 fsck），保留丢弃并注释约定 | hello9/10/21 ext2、hello24/25/29 删除/fsync、FAT32 路径 smoke 全绿 |
| ext2 写错误传播 | `allocBlock` 两分支新块清零写失败返回 0（接受位图位泄漏等 fsck，优于交付脏块）；`flushIndirect` 改返回 bool，缓存路径失败保持 dirty 待 cacheFlush 重试，经 `ensureChildIndirect`/`ensureDataPtr` 闭环到 `getBlockForWrite` 既有 null/0 失败约定 | 同上 |
| fbcon 恢复路径（P1-9） | 重估为中工作量：需 mmapFb 登记 + munmap/exit 注销 + 引用计数归零重启 mirror，部分解除映射与区域分裂使边界复杂；记录设计要点后排至 P1 批次末尾 | — |

**验证**：host 测试 + smoke SMP=1（FAT32/ext2 改动后单独一轮）+ SMP=1/4（全量）全绿。

---

### 6.24 P1 批次第二轮（2026-08-13）：fbcon 镜面恢复路径（P1-9 关闭）

**问题**：用户态 mmap /dev/fb0 时 fbcon 文本镜面被单向停用（防止 present() 覆写用户像素），
但映射消失后无恢复路径，控制台输出永久不再上屏。

**方案**：fbdev.zig 新增固定 8 槽映射登记（owner task + base/pages，IrqSpinlock 保护）：
- `mmapFb` 成功建立映射后（而非进入函数时）登记并停用镜面——映射失败不再误关镜面。
- `noteUnmap` 挂入 `mmap.zig` 的 munmap 与 mremap 收缩路径：按区间裁剪登记项，
  中间切断时在有空槽时分裂为两项，无空槽时保留较大半（降级为旧单向行为）。
- `cleanupTask` 挂入两个 reap 路径（task.zig，紧邻 devfs_proxy.cleanupTask）与两个
  exec 路径（execve.zig）：任务退出/换镜像即回收其全部 fb 映射登记。
- 登记计数归零且 framebuffer 仍在（fbcon.isActive）即重新启用镜面并打印
  `[fbcon] mirror restored`。
- smoke 门禁新增 `[fbcon] mirror disabled`/`[fbcon] mirror restored` 双标记
  （hello56 映射 fb0 → 停用，hello56 退出回收 → 恢复），恢复路径从此有持续回归覆盖。

**验证**：host 测试 + smoke SMP=1/4 全绿（含新门禁标记）。

---

### 6.25 P2 批次第一轮（2026-08-13）：pthread v2 之一——detached 栈回收 + malloc 线程安全

**问题（v1 限制，kernel-subsystems §2.5a）**：detached 线程不 join 时 TCB+栈块（malloc 分配）
永久泄漏；且 moqi_libc 的 free-list malloc 完全无锁，多线程并发 create/join 会竞争堆链表。

**方案（性能最优取向：零额外系统调用）**：
- 退出线程无法安全 free 自己仍在运行的栈，故采用**惰性回收**：`pthread_exit` 的 detached
  路径把 TCB 块以单次 CAS 压入无锁死栈链（无分配、无锁、无系统调用），随后以纯寄存器内联
  exit syscall 收尾（连 _exit 调用帧都不建）；下一次 `pthread_create` 以一次 XCHG 取走整条链
  逐个 free。回收延迟有界于创建活动，快路径零成本。
- 竞态闭合：detach 与 exit 的"看到对方标志"由存储/加载顺序保证至少一方看见（不会双压也
  不会漏收）；join 与并发 detach（POSIX UB）竞速时 join 复见 detached==1 即放弃读 retval 与
  free，所有权归死栈链——杜绝 double-free。已接受残余：压链与 exit 之间的信号投递帧可能写到
  已回收栈顶（指令级窗口，与 §6.18 已接受残余同类）。
- malloc/free 增加 test-and-set 自旋锁（临界区短、除 grow 的 brk 外无系统调用，自旋优于
  futex），并发 create/join 不再竞争堆空闲链；单线程程序无感。

**验收**：hello57 新增 8 detached 线程（detach 后立即退出）+ double-detach/join-detached
EINVAL + 后续 create 触发排空的断言组；host 测试 + smoke SMP=1/4 全绿。

**v2 剩余**：CLONE_FILES 真共享 fd 表（内核 fd 表引用计数化，单独一轮）；`__thread`（PT_TLS，
loader + crt0/pthread 布局调整，单独一轮）。

**同轮挖出并关闭的固有内核缺陷（exitTask 自死锁）**：SMP=4 门禁三连卡在 hello58 测试 5
（孤儿 SIGHUP），二分（基线 / 仅回退 hello57 / 基线三连）证明与本轮 libc 改动无关——**基线
在同一位置复现**，为既有缺陷。根因：`exitTask` 在 `task_lock` 临界区内调用
`jobctl.onSessionLeaderExit`，其广播路径 `kickIfBlocked/continueTask → unblockTask` 会重取
`task_lock`（非递归 IrqSpinlock）；目标成员处于 `.blocked`（nanosleep 中）即同 CPU 自死锁，
IF=0 自旋迅速传染全系统 → 串口完全静默。SMP=1 下 D 总在 C 首次阻塞前退完，所以从不触发。
修复：SIGHUP 广播移到 `task_lock.release` 之后（此刻本任务已标 .zombie 且仍是当前任务，
reap 静默门保证槽位有效）。验证：修复前近 4 个 SMP=4 样本 3 次冻结于 D 退出点；修复后
6 个样本 5 次全绿（含 3 连跑），hello58 测试 5 稳定通过。

**残余观察项**：修复后仍有 1/6 样本停滞在 hello58 主线程打印 PASS 之后、`[exit]` 打印之前
——主线程在 write 返回与 exit 系统调用之间不再被调度，init 卡在 waitpid，无任何内核输出。
与 §6.18/6.19 的 SMP 时序竞态同族（调度/信号投递窗口），触发率低；留待 GDB stub 现场取证
（MOQI_DEBUG=1 起 QEMU，停滞后 attach 查看各 CPU RIP 与任务态）的专项。

---

### 6.26 SMP=4 残余停滞专项——结案（2026-08-13）：三个独立根因全部闭合

**取证工具**：新增 `tools/gdb_stall_probe.sh`——QEMU 挂 GDB stub 启动，停滞检测（串口日志
90 秒无增长且未到 shell）后批量转储：各 vCPU 寄存器/回溯、任务表全量状态、阻塞任务的
saved_rsp 帧。另用临时复现 init（连跑 60 次 hello58，未提交）把单轮停滞概率从 ~1/6 压到
接近 1/1，并用 `blocked_by`/`sleep_bm_clear_by` 调用点插桩（验证后已撤除）锁定肇事路径。

**根因①（checkSignalsOnSyscallReturn 幻影僵尸）**：syscall 返回路径对默认动作 terminate
的信号直接写 `state = .zombie`，不走 exitTask——无 fd 清理、无 [kill] 打印、**不唤醒
waitpid 中的父进程**；tick 随后把幻影僵尸切走，再无任何人补 exitTask。这正是 §6.21 注释里
v53.49 在 tick 投递路径修过的同一个 bug 的孪生漏网路径。修复：改调
`exitTask(128 + signum)`。

**根因②（sleepTimerTick 误清睡眠位）**：tick 扫描的 bm 是循环开始前一次性加载的，任务在
两次 nanosleep 之间（旧睡眠已清 deadline、新睡眠未发布）被读到 `deadline==0` 时会被误清位
——读-判-清非原子，裁掉新睡眠刚武装的位，任务永久失醒（.blocked 且 sleep_bm=0）。修复：
tick 只在 zombie 时清位，deadline==0 瞬态位由任务自己清除。

**根因③（yield trap 恢复 .blocked 任务继续运行——系列停滞的主根因）**：阻塞原语
`blockTask + forceReschedule`（int 252 yield trap）的 tick 在**本 CPU 无可运行同伴**时直接
`return`，iretq 恢复的是这个已被标记 .blocked 的任务——它带着 .blocked 状态继续执行，
逃出阻塞循环回到用户态后，下一次抢占的 switch-out 走 `releaseToReady`（只认 .running）→
既不重新入队也无任何唤醒源，任务永久丢失（四核全部 idle-hlt，串口完全静默）。waitpid 的
park 路径早有同款"状态修复"，nanosleep/futex/sleepOn 等路径没有。修复：新增
`sched.repairCurrentAfterBlock()`（返回时本任务必为当前任务，状态非 .running 即修复），
接入全部 12 个 block+forceReschedule 点位（nanosleep、sleepOn、futex×4、timerfd、ipc×3、
posix_mq×2、sysv_sem、file_lock×2）。

**证据链**：GDB 转储显示父任务 .blocked、无 stopped、无 sleep_bm 位、无 wait 标志，四核
全 idle；saved_rsp 帧为 write() 包装器内的用户态抢占帧；`blocked_by` 插桩指向 nanosleep 的
blockTask；修复前复现器 3/3 轮首迭代即冻结，修复后 4/4 轮（240 次 hello58）全过。

**验证**：host 测试 + smoke SMP=1 + 复现器 4 轮 + SMP=4 连跑（见提交记录）。

---

### 6.27 P2 批次第二轮（2026-08-13）：CLONE_FILES 真共享 fd 表（pthread v2 之二）

| 阶段 | 内容 | 验证 |
|---|---|---|
| FdTable 池化 | 从 Task 内嵌（约 57KB/任务）移入静态池（64 槽 + 原子位图，`vfs.allocFdTable/releaseFdTable/freeFdTable`）；`Task.fd_table` 改指针，13 处取地址点修正；release 只判末引用、close 循环后才归还池（避免重分配竞态） | 行为不变：host + SMP=1 smoke |
| CLONE_FILES | clone 共享路径：refs 原子 +1、跳过复制与 retainSharedResources、预分配新表即还池；exitTask 仅末引用执行 fd 关闭循环；fd 位图操作原子化（allocFdAtLeast 抢位重试、freeFd 原子 Or、reserveFdForDup2 原子读改），无表级锁；close-vs-use 弱语义记录在 close 注释 | hello57 新增跨线程共享读 + close 后 EBADF 断言 |
| pthread 接入 | pthread_create 加传 CLONE_FILES（0x400），线程组共享 fd 表与 NOFILE | SMP=1/4 smoke |

**观察项（未复现）**：本轮复核中 hello57 的 fdshare-ebadf 断言曾单次失败（随后 1×SMP=1 +
3×SMP=4 均未复现）；失败分支已加打印，复发时可直接读出返回值定位。

**v2 剩余**：`__thread`（PT_TLS）——loader 解析 PT_TLS + crt0/pthread 的 TLS 布局调整。

---

### 6.28 P2 批次第三轮（2026-08-14）：PT_TLS `__thread` 支持（pthread v2 收官）

- **设计**：x86-64 TLS variant II——FS（tp）指向 TCB（TCB[0]=self），程序 PT_TLS 模板的
  每线程副本位于 tp 正下方 `align_up(memsz, align)` 字节；编译器 LE 模型（R_X86_64_TPOFF32）
  以 tp 负偏移直接访问，无需 `__tls_get_addr` 运行时。
- **内核零改动**：loader 早就在初始栈 auxv 写 AT_PHDR/AT_PHENT/AT_PHNUM；crt0 新增
  `__moqi_tls_setup(sp)` 自行扫描 PT_TLS。
- **libc 布局**：有 PT_TLS 时主线程从静态 main_tcb 改为动态 [TLS][TCB] 块（静态 TCB 无法
  满足 tp 相对位置）；pthread_create 按 [TLS 块（align 对齐）][TCB][栈] 分配并逐线程复制
  模板（filesz 拷贝 + memsz 清零）。无 PT_TLS 的程序保持原布局，行为不变。
- **验收**：hello57 新增 __thread 块——.tdata（初值）与 .tbss（零值）各一变量，3 个线程
  写不同值、忙等放大交错窗口后读回验证隔离，主线程原值不变；SMP=1/4 smoke 全绿。

至此 pthread v2 三件套全部完成（detached 回收 6.25、CLONE_FILES 6.27、PT_TLS 6.28）。

---

### 6.29 P2 批次第四轮（2026-08-14）：tmpfs 单文件上限扩容（一级间接页）

- **问题**：tmpfs 每文件固定 64 页数组（256 KiB 硬顶），syslogd 日志等写路径只能在
  触顶前单代轮转规避。
- **方案（性能最优取向：直辖区零开销）**：ext2 式一级间接页——页号 0..63 仍走
  `entry.pages[]` 直读；页号 64..575 经一页间接表（4KB = 512 个 u64 物理地址，0 为空洞），
  间接页按需分配。单文件上限 64+512=576 页 = 2.25 MiB。`pageAt`/`pageAtAlloc` 两个 helper
  收口全部访问点（read/write/truncate/mmap 读与写缺页/entry 释放）；`page_count` 升 u16。
- **验收**：hello42 新增 600 KiB 大文件块——pwrite 全量 + 首/直辖末/间接首/末页 pread
  抽查 + ftruncate 到 32 KiB 后旧位置读 EOF；SMP=1/4 smoke 全绿。
- **顺路文档修正**：user-space §7.1 与 moqios-architecture-current 的 syslogd 轮询描述
  滞后于 J3（kmsg 阻塞读、事件驱动），一并更正。

---

### 6.30 工程化（2026-08-14）：smoke 门禁 CI 化

- CI 新增 `smoke-qemu` 作业（`.github/workflows/test.yml`）：apt 安装 qemu-system-x86 与
  xorriso 后运行 `zig build smoke`（单核）+ `zig build smoke-smp`（双核），TCG 软模拟
  不依赖 /dev/kvm；Limine 由 limine_bootstrap.sh 按固定 commit 现场克隆构建，disk.img 走
  manifest 校验。自此每次推送/PR 都过完整 boot-to-shell 门禁，此前 CI 只跑主机测试。
- 本地可验证的部分已全部验证（YAML schema、作业步骤）；GitHub 侧运行结果以 gh 观察为准。
- **顺路修复既有 CI 失效**：`mlugg/setup-zig` 的固定 commit 已被上游改写而不可解析，
  两个作业在 setup 阶段即失败（与本次 smoke 作业无关，推送前已存在）。改为直接下载
  ziglang.org 官方 0.16.0 tarball 到 /opt 并写入 GITHUB_PATH——自包含，不受第三方
  action 仓库漂移影响。

---

### 6.31 P2 批次第五轮（2026-08-14）：RLIMIT_STACK 真实执行（rlimit 扩展第一步）

- **语义先行**（计划约束"先定执行语义再实现"）：`docs/rlimit.md` 新增
  "RLIMIT_STACK execution semantics"——per-task 软/硬字节限（默认 8 MiB/8 MiB，
  与原 stub 上报一致），在执行点定义 enforcement：缺页 demand-growth 的地板
  `floor = USER_STACK_TOP - min(rlim_cur, region)`，越地板的栈 fault 拒绝对页并走
  既有 SIGSEGV 投递（默认动作终止）；RLIM_INFINITY 软限仅受架构区域约束；下调
  不解除已映射页，只抬升增长水位线；exec 保留限值但重置水位线，防止旧镜像的深
  水位线绕过地板；fork/clone 继承；CLONE_VM 线程栈为 mmap 区域不受约束（与
  Linux 一致）。
- **纯策略**：`rlimit.zig` 新增 `Policy.stackFloor`/`initialStackLimit`/`applyStack`
  （校验镜像 NOFILE 规则但无表容量上限：仅 `cur > max` 为 EINVAL，提硬限/软限超
  现硬限需 cap_sys_resource 否则 EPERM）。
- **内核接线**：`task.zig` 新增 `stack_cur/stack_max` 字段（槽位复用显式重置）；
  fork/clone 拷贝；execve 两条路径重置水位线；`idt.zig` handleDemandPage 增长
  分支执行地板（不变式 `stack_limit >= floor` 由初值、增长钳位与 setrlimit 抬升
  三处共同维持）；getrlimit/setrlimit/prlimit64 三个入口的 RLIMIT_STACK 从固定
  stub 改为真实 per-task 读写（setrlimit 下调时立即抬升目标水位线）。
- **验收**：hello59（libc 程序）覆盖默认值 8MiB/8MiB、cur>max → EINVAL(-22)、
  软限下调读回、prlimit64 读取、fork 继承、以及真实执行——子进程压到 64 KiB
  后无限递归被 SIGSEGV 杀死（waitpid 状态 139）。串日志实证 fault 地址
  `0x7efff8` = USER_STACK_TOP − 64 KiB，恰为地板，一次不多。
- **门禁**：`zig build`、`zig build test`（191 全绿，含新增 STACK floor/applyStack
  两组宿主机测试）、smoke SMP=1（hello59 PASS）、SMP=4 stress 2/2 全绿。
  smoke 门禁标记新增 `hello59: PASS`/`hello59 done`。
- 其余 RLIMIT_*（AS/NPROC/DATA/…）仍为上报 stub，待各自语义定稿后逐个执行，
  避免 stub 蔓延。

---

### 6.32 P2 批次第六轮（2026-08-14）：AHCI/SATA 实际 I/O 路径端到端验证 + io_sched 结案

- **QEMU 接线**：qemu_run.sh 新增可选 ich9-ahci + scratch SATA 盘
  （`MOQI_AHCI`/`MOQI_AHCI_IMG`，默认开，模式同 NVMe）；8 MiB 镜像首扇区盖戳
  `MoQiAHCI`。smoke 用自己的工作目录镜像，不碰 disk.img。
- **boot I/O 自测**（ahci.zig，仿 NVMe 模式但更进一步）：读 sector 0 验模式；
  **仅当模式匹配**（确认是我们的 scratch 盘）才继续写 sector 1 + flushCache +
  读回比对——真机外来盘永远只读。smoke 门禁新增标记
  `[ahci] boot write+readback verified` 与失败快速通道。
- **抓到并修复两个真 bug**（此前该路径从未跑过）：
  1. NCQ FIS 寄存器映射反转：扇区数应在 Features（cfis[3]/[11]）、NCQ tag 在
     Count（cfis[12] bits 7:3），原代码写反，设备把 count 读成 0（=65536 扇区，
     32 MiB），QEMU 以 "PRDT length smaller than requested size" 拒绝，命令挂死。
  2. `waitCompletion` 在 msi_enabled 时纯靠 ISR 标志位自旋，启动早期（或丢中断）
     必超时；统一为"ISR 加速 + CI/SACT 轮询兜底"（同 NVMe 哲学），内联服务
     pending IS，与 ISR 幂等兼容。
- **io_sched 结案**：按 §706 悬案核查——tryMerge 缺陷属实（合并扩范围但保留原
  buffer 指针，合并 DMA 范围确实越出缓冲区），但 submitRequest/dispatchNext 全库
  无调用方，是不可达死代码；NCQ 硬件排队已取代软件电梯。整层删除
  （kernel/fs/io_sched.zig + ahci 注册点 + Port.io_sched_idx 字段），比修复更优：
  零行为变化、消除 494 行错误倾向代码。§706 悬案关闭。
- **门禁**：`zig build`、`zig build test`（191 全绿）、smoke SMP=1（AHCI 标记齐）、
  SMP=4 stress 2/2 全绿。串日志实证：`NCQ=yes TRIM=yes sectors=16384` →
  `boot read verified (pattern match)` → `boot write+readback verified`。
- kernel-subsystems §6.4 升 ✅；docs/moqios-design.md 文件树移除 io_sched.zig。

---

### 6.33 P2 批次第七轮（2026-08-14）：RLIMIT_AS 真实执行（rlimit 扩展第二步）

- **语义先行**：`docs/rlimit.md` 新增 "RLIMIT_AS execution semantics"——per-task
  软/硬字节限（默认 RLIM_INFINITY，行为不变），内核维护 `as_used` 计费计数：
  brk 堆页、所有 mmap 追踪区域（匿名/文件/设备 eagerly 映射）与按需增长的
  主栈页计入；exec 镜像代码页、内核结构、页表不计。超限按接口区分：
  mmap/mremap 增长 → ENOMEM，brk → 报原 break（POSIX），栈增长 → SIGSEGV。
  munmap/shrink 退款；MAP_FIXED 先退旧再计新（同尺寸替换不触发）；fork 复制
  限值与用量；exec 保留限值、用量清零。
- **纯策略**：`applyStack` 更名 `applyBytes`（STACK/AS 共享的字节限校验）+
  新增 `asChargeOk`（用量超限后只阻断不欠账）。
- **记账挂钩**（最小侵入）：`trackMmapRegion`/`trackNoFreeRegion` 计费、
  `untrackMmapRange` 按实际裁切退款（区域互不重叠，重叠求和精确）；
  mremap 三个增长点（文件原地/匿名原地/moveMapping delta）各自计费；
  brk 增/缩计退；idt 栈缺页逐页计费（swap-in 提前返回不重复计）。
- **syscall 接线**：getrlimit/setrlimit/prlimit64 的 RLIMIT_AS 从 INFINITY stub
  改为真实 per-task 读写；下调低于当前用量合法（只阻断后续计费，同 Linux）。
- **验收**：hello60 覆盖默认 INFINITY、cur>max → EINVAL、1 MiB 软限下子进程
  递归栈计费耗尽被 SIGSEGV 杀（串日志实证第 257 页 0x7bf000 被拒 = 恰好
  1 MiB）、16 MiB 软限下 1 MiB mmap 成功 / 64 MiB mmap ENOMEM、munmap 退款后
  再 mmap 成功、brk 32 MiB 被拒 / 64 KiB 成功、fork 继承。smoke 门禁新增
  `hello60: PASS`/`hello60 done` 双标记。
- **门禁**：`zig build`、`zig build test`（192 全绿，含 asChargeOk 边界组）、
  smoke SMP=1（hello60 PASS）、SMP=4 stress 2/2 全绿。
- 其余 RLIMIT_*（CORE/RSS）仍为上报 stub，待各自语义定稿；NPROC/DATA/FSIZE
  已分别由 hello64/hello63/hello66 收口。

---

### 6.34 P2 批次第八轮（2026-08-14）：fork COW OOM 事务化克隆（review §5.2t 悬案收口）

- **差距确认**：子树/引用泄漏早已修（6.x 经 destroyUserSpace 回滚）；剩余是
  原 P1 条目的后半——OOM 中途失败会把**父进程 PTE 留在 COW 降级态**（ benign
  但违背事务性），且 `clone.zig cloneUserPages` 的 OOM 出口连子树回滚都没有
  （`orelse return null` 直接遗弃半成品页表）。
- **方案**（采用 review 建议的 preallocate 路线）：两条克隆走查统一为三阶段
  事务结构——阶段 0 在父侧降级大页 PDE（语义中性：同内容同权限，仅 4K 粒度化）
  并统计所需子表页数；阶段 1 预分配池页 + 全部表页（失败只释放未链接的新页，
  父进程除中性降级外零改动）；阶段 2 零分配地完成全部父 PTE 降级与子树填充，
  **不存在中途失败点**。池索引一页 512 项可覆盖 1 GiB 用户页表，超过物理内存
  上限，实际不可达；阶段 2 对阶段 0 之后并发出现的表项做 `next >= needed`
  防御性截断（CLONE_VM 并发 mutate 属 P3 地址空间并发项）。
- **验收**：hello61（96 MiB 匿名映射 ≈ 48 张 PT 页规模）fork 后子进程读验证
  共享内容、写触发 COW 私有副本、父进程页面不受污染、munmap 回收。smoke 门禁
  新增 `hello61: PASS`/`hello61 done` 双标记。OOM 路径正确性由结构保证
  （阶段 1 失败只释放池；阶段 2 无分配），无确定性 OOM 注入手段，已在文档注明。
- **门禁**：`zig build`、`zig build test`（192 全绿）、smoke SMP=1、SMP=4
  stress 2/2 全绿（fork/clone 被全部 run_test 派生 + hello50 SMP 压力反复覆盖）。
- review §6.9 表内该 P1 条目标记 Fixed；next-phase-plan 的 fork COW 半项关闭，
  2MB 大页文件映射仍留。

---

### 6.35 P2 批次第九轮（2026-08-14）：文件映射 fault-around 预缺页（2MB 大页文件映射项收口）

- **方案定论**（性能最优原则的诚实结论）：真 2MiB PDE 大页与文件映射的零拷贝
  共享设计**物理不兼容**——MAP_SHARED 写透要求映射后备方自己的帧（tmpfs 页、
  page_cache 帧），这些帧逐 4K 分配、物理不连续；硬件大页要求 2MiB 连续帧，
  意味着每次缺页复制 512 页进连续帧，恰好摧毁写透语义并双倍内存流量。文件
  映射的性能瓶颈是每页一次 #PF 往返，不是 TLB 覆盖——故采用 Linux 同级的
  fault-around：缺页服务成功后向前预供给同区域最多 15 页（64 KiB 窗口）。
- **实现**：`filemap.zig` 新增纯策略 `FAULT_AROUND_AHEAD`/`faultAroundAhead`
  （区域末端截断）/`prefaultSafe`（排除 MAP_SHARED 可写——供给即标脏，预供给
  会为无人写入的数据白付回写）；`idt.zig` 把原 handleFileFault 拆为
  `serveFilePage`（单页供给，逻辑不变）+ `handleFileFault`（先服务缺页页，
  再预供给窗口：已有 PTE 含 swap 项跳过、EOF 截断、失败非致命中断窗口）。
  RLIMIT_AS 计费不变（区域在建映射时已全额计费）。
- **验收**：hello62 在 tmpfs 造 256 KiB 已知模式文件，MAP_PRIVATE 与
  MAP_SHARED 只读各做一次逐字节顺序扫描（跨 4 个 64 KiB 窗口，页偏移错乱
  必现）；hello46（COW/EOF SIGSEGV）与 hello48（MAP_SHARED 写透/EROFS）作为
  回归全绿。host 测试锁定窗口截断与 prefaultSafe 排除规则。
- **门禁**：`zig build`、`zig build test`（193 全绿）、smoke SMP=1、SMP=4
  stress 2/2 全绿。smoke 门禁新增 `hello62: PASS`/`hello62 done` 双标记。
- kernel-subsystems §1.8.1 记录 fault-around 与 2MiB PDE 不兼容的分析定论；
  next-phase-plan 的 2MB 大页文件映射半项关闭。

### 6.36 P1 收口（2026-08-15）：virtio-net TX single-flight 锁契约 + RX 所有权审计

- **对账结论**：`docs/next-phase-plan.md` 的 P1 唯一剩余项原描述为
  "virtio-blk/virtio-net/NVMe 队列 single-flight 锁契约"。逐驱动核对代码后，
  virtio-blk 用 `io_lock: IrqSpinlock`（virtio_blk.zig:167）串行化整笔请求
  （所有请求共享固定描述符 0-2），NVMe 用 `io_locks: [MAX_IO_QUEUES]IrqSpinlock`
  每队列一把锁并写明锁序（nvme.zig:195-210）——二者早已满足 single-flight
  契约。唯一真实缺口是 virtio-net TX：`sendPacket` 从任意 CPU 进入（用户任务
  TX vs. 写回/定时器 TX），同时改写共享 TX virtqueue 的 free list
  （`free_head`/`free_count`，经描述符内存）、描述符链、avail 环与完成索引，
  无任何串行化——并发发送会重复分配/回收同一描述符、丢失 avail 更新、改写
  DMA 所有权并泄漏页。
- **实现**：`virtio_net.zig` 新增 `tx_lock: IrqSpinlock`，`sendPacket` 在首个
  队列可变操作前 acquire、整笔事务（alloc→publish→notify→同步 reclaim）持锁、
  `defer` 释放；失败路径（第二描述符/页分配失败）在持锁下回滚队列状态。RX
  路径（`processRxQueue`）保持无锁——见下方所有权审计。
- **TDD**：新增纯模块 `kernel/drivers/virtio_net_queue.zig`（不依赖内核/硬件
  符号，host 可测），承载队列记账（`init`/`allocDescriptor`/`freeDescriptor`/
  `publishAvail`/`recordCompletion`/`recycleRx`）与 single-flight 不变量；
  8 个 host 测试（alloc-until-full 唯一性、free 恢复容量、重复/越界 free 无操作、
  零大小安全、publish 单槽单步进、completion 单步进、分配失败回滚、RX 单次消费+
  重发）先红后绿，经
  `kernel/host_test.zig` 与 `tests/main.zig` 接入 `zig build test`。
- **RX 所有权审计（本批结论）**：`processRxQueue` 仅由 `handleInterrupt` 调用，
  IDT 中断上下文单所有者（`idt.zig` handleIrq 的 virtio-net 分支）；QEMU smoke
  用 e1000（qemu_run.sh `-device e1000`）而不用 virtio-net，且 PIC 初始化仅
  unmask IRQ1（idt.zig:1317），virtio-net 的 INTx 在当前门禁下不可达。RX 与
  TX 操作不同 virtqueue，故加锁只会引入假依赖并让整笔 TX poll 关中断，无
  正确性收益——**维持无锁，另记 follow-up**：若未来引入 virtio-net 多队列或
  非 ISR RX 拉取，需先为此路径补 per-queue 锁/所有权契约。
- **门禁**：`zig build`、`zig build test`（193 全绿）、smoke SMP=1、smoke
  SMP=2 全绿；riscv64/aarch64 构建通过。riscv64 smoke `[SK-19] FAILED:
  blocked state` 为既有环境失败——在 stash 掉本批全部改动后的干净 main 上
  复现，与本次改动无关（riscv 使用独立 `arch/riscv64/virtio_net.zig`）。

### 6.37 P2 rlimit 第一步（2026-08-15）：RLIMIT_NPROC 真实执行

- **现状核对**：此前 `RLIMIT_NPROC` 的 getrlimit 返回固定 infinity，
  setrlimit/prlimit64 接受后 no-op；`Task` 只有 NOFILE/STACK/AS 字段，
  任务表只有全局 `task_count`，fork/clone/spawn 没有资源闸点。
- **实现**：`Task` 新增 `nproc_cur`/`nproc_max`（默认 infinity）；task 模块
  新增 under-`task_lock` 的固定 UID 计数表。三个任务创建站点和三个回收站点
  对 UID 计数做对称增减，zombie 在 waitpid/reap 前继续计数；未知 UID 在有限
  NPROC 下 fail-closed。fork 在 COW 前、clone 在 COW/retain 前、spawn 在
  loader 前做 `uid_count < rlim_cur` 闸点，拒绝返回 `EAGAIN`；fork/clone
  继承限制，exec 保持限制。syscall get/set/prlimit64 现在均是真实 per-task
  NPROC 操作，沿用 `applyBytes` 的 `cur<=max` 与 `cap_sys_resource` 规则。
- **TDD/验收**：host 策略测试锁定 infinity/边界，libc ABI 锁定
  `RLIMIT_DATA=2`、`RLIMIT_NPROC=6`；新增 `hello64` 验收默认值、EINVAL、
  `nproc_cur=1` 时确定性 `fork -> EAGAIN`、恢复软限、继承和 reap 后计数释放。
  hello64 已接入 build、ramdisk、PID 1 自动测试和 QEMU smoke 标记。
- **配套容量修复**：hello64 使 ramdisk 用户程序数从 64 增至 65；同步将
  `kernel/fs/ramdisk.zig` 与 `tools/mkramdisk.sh` 的 sanity 上限从 64 提至
  128。该上限只约束 blob 文件计数，索引位于 blob 中，每新增文件仅增加
  80 字节镜像空间；FAT32/tmpfs 的独立 64 槽限制不受影响。
- **门禁**：`zig build test`（194/194）、`zig build`、x86_64 smoke SMP=1/2、
  CPU matrix 2/4/8、SMP=4 stress 3/3、riscv64/aarch64 构建均通过。

**后续 P2**：RLIMIT_DATA 仍单独待实现。它复用 AS 的 charge/refund 事务，
  但需要第三个 `data_used` 账本，并精确覆盖 brk 与可写私有 mmap 的
  `munmap`/`mremap`/`MAP_FIXED` 增长和回滚路径，不能与 NPROC 混批。

### 6.38 P2 rlimit 第二步（2026-08-15）：RLIMIT_DATA 真实执行

- **现状核对**：`RLIMIT_DATA` 此前与 NPROC 一样是 stub——getrlimit 返回固定
  infinity、set/prlimit 接受后 no-op；brk 和 mmap 只走 RLIMIT_AS 的
  `as_used` 账本，无独立的 data 账本。
- **实现**：`Task` 新增 `data_cur`/`data_max`/`data_used`（独立于 `as_used`
  的第三账本）。计费对象是 brk 堆增长 + 可写私有 mmap（匿名私有 + 可写文件
  `MAP_PRIVATE`）；只读私有、`MAP_SHARED`、exec 镜像 code/rodata 不计费。
  `trackMmapRegion` 现在为匿名区域记录 `prot`/`shared`，并仅在 `prot`/`shared`
  一致时才 merge（否则合并后单一 prot 无法精确退款）；`untrackMmapRange` 按
  区域 `prot`/`shared` 并行退款 `data_used`。每个增长路径（mmap、匿名与文件
  `mremap` grow、`moveMapping`）都在任何页表变更前做 `dataChargeOk` 预检查，
  超限返回 ENOMEM 且不产生部分变更——绝不在超限后才发现需要回滚。
  fork/clone 继承限制与用量，exec 重置用量而保留限制。
- **TDD/验收**：host 测试锁定 `dataChargeOk` 边界（精确上限/超限/无限），
  libc ABI 常量此前已在 NPROC 批锁定 `RLIMIT_DATA=2`；新增 `hello63` 验收
  默认值、EINVAL、16MiB 软限下可写私有 mmap 超限 ENOMEM、只读/共享 64MiB
  映射不受限、munmap 退款、brk 增长超限拒绝 + 收缩退款、fork 继承。
- **门禁**：`zig build test`（195/195）、`zig build`、x86_64 smoke SMP=1/2、
  CPU matrix 2/4/8、SMP=4 stress 3/3、riscv64/aarch64 构建均通过。

**后续 rlimit**：剩余资源（RLIMIT_CORE/RSS）语义差异较大，各自定稿后
单独成批；当前 P2 的 rlimit 执行语义目标已全部完成。

---

## 7. Completion Criteria For This Review Task

The review/documentation part is complete when:

- This document is committed and linked from the primary architecture/status docs.
- The repo builds/tests that can run in the current environment are executed and their result is recorded.
- Any unavailable verification is explicitly listed as a gap.
- A push to `origin/main` is attempted after local verification, or a network/credential blocker is reported with the exact command.
### Bounded TCP message batching

`sendmmsg` and `recvmmsg` now process up to 16 TCP messages with explicit partial-count semantics. Unix/UDP batching remains outside this bounded contract.
### epoll_create1 flag boundary

The current epoll implementation accepts `flags == 0` and `EPOLL_CLOEXEC` (`0x80000`); unrelated
flags fail with `EINVAL` before fd allocation. `hello83` covers the zero/invalid boundary and
`hello84` covers CLOEXEC creation plus close. The raw gate does not exercise exec inheritance;
the existing exec fd cleanup path remains the lifecycle boundary.
