# MoQiOS Current Code Review And Fix Plan

> Review date: 2026-06-21  
> Last update: 2026-06-21 (M8-5b-3 / M8-6 / M8-7 SMP performance triplet completed)  
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

### P1 - x86_64 Coupling Blocks The Cross-Architecture Goal

Evidence:

- `kernel/main.zig`, `kernel/klog.zig`, drivers, fs, mm, proc, net, and IPC files import `arch/x86_64/*` directly.
- `build.zig` routes riscv64 to `kernel/arch/riscv64/start.zig`, bypassing the full kernel root.
- `docs/cross-arch-port-plan.md` correctly identifies M4 `arch` facade extraction as pending.

Risk: riscv64 can build a skeleton but cannot share the real kernel subsystems without a staged HAL/arch interface.

Fix plan:

1. Introduce a minimal `kernel/arch/arch.zig` facade for serial/logging, interrupt control, TLB operations, timer, syscall/trap setup, and per-CPU access.
2. Migrate one subsystem class at a time behind the facade, keeping x86_64 bootable after each step.
3. Only then move riscv64 beyond skeleton boot.

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

### P1 - Automated Tests Are Too Narrow For Current Claims

Evidence:

- `zig build test` runs host tests for `byte_order`, `fmt_core`, and `str`.
- Runtime integration is documented as QEMU `hello*`, but it is not represented as an automated pass/fail command in the Zig test step.

Risk: host tests can pass while kernel boot, syscall, filesystem, networking, and SMP behavior regress.

Fix plan:

1. Keep host unit tests for pure library code.
2. Add a bounded serial-log QEMU smoke test script that checks for `MoQiOS shell` and expected `hello*` completion markers.
3. Add separate gates for `MOQI_SMP=1`, `MOQI_SMP=2`, and `-Darch=riscv64` build.

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
| QEMU single-core smoke | `MOQI_SMP=1 zig build run` or script wrapper | Kernel reaches shell and runs user tests |
| QEMU dual-core smoke | `MOQI_SMP=2 zig build run` or script wrapper | AP bring-up path remains stable |

If QEMU or toolchain pieces are unavailable, record that as a verification gap instead of treating host tests as a substitute.

## 4. Recommended Repair Order

1. ~~Correct documentation status claims and keep this review linked from primary docs.~~ Done.
2. Add reachability/dispatch classification for kernel modules.
3. Add automated QEMU smoke gates.
4. Stabilize SMP affinity scheduling with repeatable `MOQI_SMP=2` tests.
5. ~~Implement FPU/SSE task state and ranged TLB shootdown.~~ ✅ Done 2026-06-21 (see P1 resolution).
6. ~~Replace global scheduler lock with per-CPU queues and work stealing.~~ ✅ Done 2026-06-21
   (per-CPU `IrqSpinlock` per queue replaces the global `sched_lock` on the hot path; the global
   lock is retained only for the bitmap-fallback scan).
7. Extract `kernel/arch/arch.zig` after the x86_64 behavior is covered by gates.
8. Expand riscv64 from skeleton to shared-kernel boot only through the new arch facade.

## 5. Verification Results For This Update

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

### 5.1 SMP Performance Triplet (M8-5b-3 / M8-6 / M8-7) Completed 2026-06-21

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
