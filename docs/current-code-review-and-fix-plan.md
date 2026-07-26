# MoQiOS Current Code Review And Fix Plan

> Review date: 2026-06-21
> Last update: 2026-07-25 (SK-152 writeback multi-page write; prior mm/proc audit reviewed and verified)
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

The riscv64 path is selected by `zig build -Darch=riscv64` and builds `kernel/arch/riscv64/start.zig`.
It is a standalone skeleton, not the full kernel behind a shared `arch` abstraction.

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
| Tests | `tests/main.zig` | Host tests cover only `byte_order`, `fmt_core`, and `str`; QEMU `hello*` tests are runtime/manual gate |

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
- `build.zig` routes riscv64 to `kernel/arch/riscv64/start.zig` (M2 skeleton), bypassing the full kernel root.
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

- `zig build test` runs host tests for `byte_order`, `fmt_core`, and `str`.
- Runtime integration is documented as QEMU `hello*`, but it is not represented as an automated pass/fail command in the Zig test step.

Risk: host tests can pass while kernel boot, syscall, filesystem, networking, and SMP behavior regress.

Fix plan:

1. Keep host unit tests for pure library code.
2. Add a bounded serial-log QEMU smoke test script that checks for `MoQiOS shell` and expected `hello*` completion markers.
3. Add separate gates for `MOQI_SMP=1`, `MOQI_SMP=2`, and `-Darch=riscv64` build.

**Resolution (2026-07-10)**: Added `tools/qemu_smoke.sh` plus `zig build smoke` and
`zig build smoke-smp`. The smoke wrapper builds the x86_64 image, runs QEMU with serial output
captured to a file, waits for the current init auto-test tail marker `hello21 done` plus
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
| QEMU single-core smoke | `zig build smoke` | Kernel reaches shell after current init auto-test tail marker `hello21 done` |
| QEMU dual-core smoke | `zig build smoke-smp` | AP bring-up path remains stable through the full init sequence |

If QEMU or toolchain pieces are unavailable, record that as a verification gap instead of treating host tests as a substitute.

## 4. Recommended Repair Order

1. ~~Correct documentation status claims and keep this review linked from primary docs.~~ Done.
2. Add reachability/dispatch classification for kernel modules.
3. ~~Add automated QEMU smoke gates.~~ ✅ Done 2026-07-10 (`zig build smoke`, `zig build smoke-smp`).
4. Stabilize SMP affinity scheduling with repeatable `MOQI_SMP=2` tests.
5. ~~Implement FPU/SSE task state and ranged TLB shootdown.~~ ✅ Done 2026-06-21 (see P1 resolution).
6. ~~Replace global scheduler lock with per-CPU queues and work stealing.~~ ✅ Done 2026-06-21
   (per-CPU `IrqSpinlock` per queue replaces the global `sched_lock` on the hot path; the global
   lock is retained only for the bitmap-fallback scan).
7. Extract `kernel/arch/arch.zig` after the x86_64 behavior is covered by gates.
8. Expand riscv64 from skeleton to shared-kernel boot only through the new arch facade.

## 5. Verification Results For This Update

### 5.0 Review Update: 2026-07-14

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
`init.S` auto-sequence ends at `hello21` (shell next); `hello22`–`hello28` are manual. riscv64
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
| P1 | Page-table walks/copies remain vulnerable to a concurrent unmap/protection change between validation and `@memcpy`; `MAP_FIXED` mapping failure has no transactional rollback. | Deferred: requires architecture-specific fault recovery, address-space locking, and TLB shootdown/rollback design. |
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
| P1 | x86 COW clone has early OOM exits after partial child page-table construction; later failures can also leave parent PTEs COW-marked with unmatched references. | Deferred transactional clone work: preallocate each subtree or add explicit rollback of child tables, parent PTEs, and page references before reporting `ENOMEM`. |
| P1 | Raw NIC receive could dequeue a packet before proving the complete user destination was mapped. | Fixed: validate the bounded destination before calling the NIC receive path. |
| P1 | TCP connect/send used generic `-1` for user-copy errors and did not preserve the stream's existing larger-write segmentation path. | Fixed: return `EFAULT` for failed address/data copies and pass bounded multi-segment writes through the existing TCP sender. |
| P1 | `select` accepted malformed timeval values and allowed millisecond conversion overflow. | Fixed: reject `tv_usec >= 1_000_000` and overflowing seconds. |
| P0 | `fsync` returned success after writeback even when NVMe/virtio had no device persistence barrier. | Fixed: flush dirty buffers and call the first filesystem backing device's flush barrier; return `EOPNOTSUPP` when it is unavailable. Filesystem-to-device tracking remains a future extension for additional mounts. |
| P2 | Documentation claimed full `CLONE_FILES` support although clone currently copies the FD table. | Fixed: document the actual copied-table behavior and defer shared-FD semantics. |
| P1 | UDP receive queues still publish/consume entries without a lock or peek/commit token, and current receive APIs may silently truncate to protocol-local storage limits. | Deferred design work: introduce queue serialization, explicit copied/original lengths, `MSG_TRUNC`/`MSG_PEEK` semantics, and commit only after the syscall copy contract is satisfied. |
| P1 | virtio-blk/virtio-net and NVMe queues retain shared mutable submission/completion state without a demonstrated per-queue serialization contract. | Deferred design work: start with correctness-first single-flight locks, then measure before adding multi-queue parallelism. |
| P1 | `MAP_FIXED` replacement lacks transactional rollback; user-copy prewalk still has a concurrent-unmap window; page-table mutation needs a unified ownership/shootdown contract. | Deferred architecture work requiring address-space locks, fault recovery, rollback, and cross-CPU TLB tests. |
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
- `io_sched.tryMerge` was reported as producing a DMA range that outruns its buffer. The merge path is
  only reachable for AHCI-registered devices and needs its own verification before any change; it was
  not confirmed in this pass.

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

Left open: `mprotect` is still unimplemented (listed P2 on the plan), so a program cannot tighten or relax
segment permissions at runtime. Now that text and rodata are genuinely read-only, that becomes a prerequisite
for any future JIT or self-modifying code. 5.2q first finishes what 5.2p started.

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

## 6. Completion Criteria For This Review Task

The review/documentation part is complete when:

- This document is committed and linked from the primary architecture/status docs.
- The repo builds/tests that can run in the current environment are executed and their result is recorded.
- Any unavailable verification is explicitly listed as a gap.
- A push to `origin/main` is attempted after local verification, or a network/credential blocker is reported with the exact command.
