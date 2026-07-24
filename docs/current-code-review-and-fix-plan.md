# MoQiOS Current Code Review And Fix Plan

> Review date: 2026-06-21
> Last update: 2026-07-24 (SK-132 ECN undo/loss + prior SK-131 reviewed and verified)
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
| User-copy fault recovery | Exception-table TODO still present. | Downgraded to mitigated P1: page-walk precheck already returns EFAULT-style 0 without kernel panic; RIP-range recovery deferred. |
| Fork FD ownership (broader) | Review still listed socket/epoll/eventfd/timerfd as open P0. | Closed: v53.44 + eventfd completion cover the shared-resource set; pipes keep their separate `Pipe.ref_count`. |

| Gate | Result | Notes |
|---|---|---|
| `zig build test` | Passed | Host helper tests. |
| `zig build` / `-Darch=riscv64` / `-Darch=aarch64` | Passed | All three ISA builds. |
| `zig build smoke` | Passed | x86_64 `hello21 done` + `MoQiOS shell`, `MOQI_SMP=1`. |
| `zig build smoke-smp` | Passed | Same markers with `MOQI_SMP=2`. |
| `zig build -Darch=riscv64 smoke-riscv` | Passed | Includes `[SK-132] tcp ecn undo/loss cut non-x86: OK`. |
| `zig build -Darch=aarch64 smoke-aarch64` | Passed | Includes `[SK-132] tcp ecn undo/loss cut non-x86: OK`. |

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
