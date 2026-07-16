# MoQiOS 跨 CPU 架构移植路线图（2026-06 起）

本文件是 MoQiOS 从「单一 x86_64」走向「多 ISA、性能最优、SMP 可扩展」的总体计划与进度跟踪。
目标第二 ISA 选定 **riscv64**（特权架构最简洁、最易自举，Zig/LLVM 原生支持），第三 ISA
（aarch64）复用同一抽象层。

> 现实预期：完整跨 ISA 移植是**数月级、多轮**工程。本文件按里程碑（M0–M9）分解，每个里程碑
> 都要求「可构建 + 可验证 + x86_64 不回归」。

---

## 0. 现状基线（移植起点 → 2026-07 更新）

- **架构抽象**：`kernel/arch/arch.zig` 已存在（M4）；x86_64 / riscv64 / aarch64 各有 `arch_impl.zig`。
  **SK-8**…**SK-28**：facade、portable mm、K/U 原生帧抢占三角。
  **SK-29（2026-07-16）**：shared sched enqueue/pick 驱动 U↔U 原生帧抢占；
  探针 `[SK-29] sched native-user preempt: OK`。
  完整 `main.zig` / Limine 驱动仍未在非 x86 链接。
- **SMP（x86_64）**：`enable_ap_startup=true`；M8-1…M8-7 已完成（per-CPU 调度、FPU、
  TLB shootdown、work-stealing）。门禁：`zig build smoke` / `smoke-smp`。
- **riscv64**：M0–M7 完成（…PMM/Sv39、timer/sched、U-mode/`ecall`、virtio-mmio blk + net MAC）。
  门禁：`zig build -Darch=riscv64 smoke-riscv`。后续：共享内核复用 / TX-RX 网栈。
- **aarch64**：M9-1…M9-7 完成（…EL0/`SVC` + 抢占调度）。
  门禁：`zig build -Darch=aarch64 smoke-aarch64`。后续：共享内核复用。
- **引导**：x86_64 经 Limine；riscv64 经 OpenSBI `-kernel`（链接地址 `0x80200000`）；
  aarch64 经 QEMU `-kernel`（链接地址 `0x40000000`，EL1；DTB 经 loader @ `0x4a000000`）。

### 环境约束（影响验证手段）

- 本开发机现已具备 `qemu-system-x86_64` 与 `qemu-system-riscv64`。
- riscv64 可用 `tools/qemu_run_riscv64.sh` 做运行时验证；x86_64 用 `zig build smoke` /
  `zig build smoke-smp` 做 boot-to-shell 门禁。

---

## 1. 设计原则（性能最优 + 可移植）

1. **薄 arch 接口**：把"硬件相关、其余内核必须调用"的能力抽象为稳定接口，各 ISA 提供实现：
   - CPU/启动：早期 init、per-CPU 访问（x86: `%gs`；riscv: `tp`；arm: `TPIDR_EL1`）
   - 内存：页表格式与 map/unmap、TLB 失效与跨核 shootdown、HHDM
   - 陷入/中断：trap 入口、寄存器帧、向量/原因解码、EOI、IPI 发送
   - 上下文切换：保存/恢复帧、首帧构造、用户态进入
   - 定时器：单次/周期 tick（x86: LAPIC timer；riscv: SBI timer/CLINT；arm: generic timer）
   - 控制台：早期串口（x86: 8250 COM1；riscv: SBI console/UART16550；arm: PL011）
2. **per-CPU 优先、最少共享**：per-CPU 结构 **64B cache line 对齐**，杜绝 false sharing。
3. **可扩展调度**：per-CPU 运行队列 + work-stealing，每队列一把锁（取代单一全局 `sched_lock`）。
4. **IPI 驱动**：reschedule IPI、TLB shootdown IPI。
5. **渐进抽取，不做大爆炸重构**：先让第二 ISA 的最小路径跑起来，再按"实际需要"的接口逐步把
   x86_64 代码迁到 `arch` 接口后面，每步保持可构建、x86_64 不回归。避免一次性改 60 个文件。

---

## 2. 里程碑

| 里程碑 | 内容 | 验证方式 | 状态 |
|---|---|---|---|
| **M0** | 路线图文档（本文件）、第二 ISA 选型（riscv64） | 文档评审 | ✅ 完成 |
| **M1** | `-Darch` 多目标构建；riscv64 内核**骨架**（`_start`+SBI 控制台+`kmain`+linker.ld）启动并打印 | 交叉编译成合法 riscv64 ELF（readelf/objdump）；x86_64 不回归（构建+启动到 shell）；运行时验证待 emulator | ✅ 完成（构建+运行时） |
| **M2** | riscv64 早期 init：**soft-float ABI（lp64，禁用 F/D）**；解析 a0(hartid)/a1(DTB)；UART16550 直驱；`stvec` + trap 帧；breakpoint 自测 | QEMU virt 启动打印 + `ebreak` 陷入被捕获 | ✅ 完成（2026-07-10） |
| **M3** | riscv64 物理内存管理：从 DTB `/memory` 建 PMM；Sv39 恒等映射 + map/unmap + 缺页自测 | QEMU virt：`page-fault trap: OK` + `M3 complete` | ✅ 完成（2026-07-11） |
| **M4** | **抽取 `arch` 接口**：定义 `kernel/arch/arch.zig`（comptime 选择实现）；x86 侧经 facade 重导出；riscv64 提供同名 stub/实装 | x86_64 仍启动到 shell；riscv64 后端可编译（完整 `main.zig` 复用待 M5+） | ✅ 接口完成（渐进迁移进行中） |
| **M5** | riscv64 定时器（`stimecmp`）+ 最小抢占调度（双内核线程轮转） | QEMU virt：`preemptive switches=` + `M5 complete` | ✅ 完成（2026-07-11） |
| **M6** | riscv64 用户态：U-mode `sret`、用户页 U 位隔离、`ecall`（sys_write/sys_exit） | QEMU virt：`hello from U` + `M6 complete` | ✅ 完成（2026-07-11） |
| **M7** | riscv64 virtio-mmio blk + net 探测（blk 读扇区魔数；net 协商 MAC） | QEMU virt：`disk magic: OK` + `virtio-net MAC: OK` | ✅ 完成（2026-07-11）；TX/RX 与 FS 待共享内核 |
| **M8** | **SMP（先 x86_64，后 riscv64）**：per-CPU 调度器（per-CPU 运行队列+work-stealing+per-CPU TSS/anchor）、通用 IPI、TLB shootdown；启用 `enable_ap_startup` | QEMU 多核：用户任务真正并行；零崩溃 | ✅ x86_64 完成（见 §4）；riscv64 SMP 待 M5+ |
| **M9** | aarch64 后端（骨架 → … → U-mode → preempt sched） | QEMU aarch64：`preemptive switches=` + `M9-7 complete` | ✅ M9-7 完成（2026-07-11） |

> SMP（M8）与第二 ISA（M2–M7）相对独立，可并行；M8 的 per-CPU 改造也会反哺 riscv64/aarch64 的
> 多核。M4 的 `arch` 接口是二者共同地基。

---

## 3. 本轮（Round 1）交付 = M0 + M1

- ✅ M0：本路线图 + 选型 riscv64。
- ✅ M1：
  - `build.zig` 增加 `-Darch=x86_64|riscv64`（默认 x86_64，行为与之前完全一致）。
  - `kernel/arch/riscv64/start.zig`：S-mode `_start` → 设栈 → `kmain`，经控制台打印后停机
    （M1 用 SBI；**M2 起改 UART16550 直驱**）。
  - `kernel/arch/riscv64/linker.ld`：链接到 `0x80200000`（OpenSBI 之上）。
  - `tools/qemu_run_riscv64.sh`：`qemu-system-riscv64 -machine virt -bios default -kernel ...`。
  - 验证：`zig build -Darch=riscv64` 产出合法 riscv64 ELF（readelf）；`zig build`（x86_64）仍启动到
    `MoQiOS shell`。

### 运行时验证（M1，待 emulator）

```bash
sudo dnf install qemu-system-riscv      # 或对应发行版包名
zig build -Darch=riscv64
MOQI_SERIAL=stdio ./tools/qemu_run_riscv64.sh
# 预期串口输出：
#   MoQiOS riscv64 skeleton: booted in S-mode via OpenSBI
#   [riscv64] arch skeleton online; halting (Milestone 1)
```

---

## 3.5 M4 完成记录（2026-06-21）

### 完成内容

- **`kernel/arch/arch.zig`**：统一接口入口，使用 `comptime switch (builtin.cpu.arch)` 自动
  选择对应架构的 `arch_impl`，当前支持 x86_64 和 riscv64。
- **`kernel/arch/x86_64/arch_impl.zig`**：重导出现有 x86_64 模块（serial、gdt、idt、
  paging、lapic、tsc 等），与现有代码完全兼容，零回归。
- **`kernel/arch/riscv64/arch_impl.zig`**：riscv64 的实现，包含：
  - UART16550 直驱串口（M2；M1 曾用 SBI legacy console）
  - `stvec` 向量配置 + 基本 trap 帧
  - 分页/定时器/上下文切换 stub（待后续里程碑实现）
- **首步迁移**：`main.zig` 中的串口通过 `arch.zig` 引入，作为渐进迁移的第一步。
- **`riscv64/start.zig`**：强制 `comptime import arch_impl`，确保架构实现被编译引入。

### 验证结果

- x86_64：`zig build` 正常构建，启动到 `MoQiOS shell`，零回归
- riscv64：`zig build -Darch=riscv64` 产出合法 ELF，通过 readelf 验证

### 下一步

- 逐步将 gdt/tsc/syscall_entry 等剩余 x86 直连模块迁到 `arch.zig` 接口后面
- 每次迁移一个模块，保持 x86_64 可构建 + 启动到 shell
- riscv64 侧同步实现对应接口（待 M3–M7 里程碑）

---

## 3.6 M2 完成记录（2026-07-10）

### 完成内容

- **soft-float ABI**：`build.zig` 使用 `-mcpu baseline_rv64-f-d`，ELF flags = `RVC, soft-float ABI`。
- **hartid / DTB**：`_start` 保留 a0/a1 传入 `kmain`；校验 FDT magic `0xd00dfeed`。
- **UART16550**：`kernel/arch/riscv64/uart.zig` 直驱 QEMU virt `0x10000000`（不再依赖 SBI putchar）。
- **`stvec` + trap 帧**：`trap.zig` 提供 `TrapFrame`、对齐的 `trapEntry`、`trapHandler`。
- **陷入自测**：OpenSBI 默认 `medeleg` **不**委托 illegal-instruction（cause 2），改用已委托的
  breakpoint（cause 3 / `ebreak`）。验证输出含 `breakpoint trap: OK`。
- **入口对齐**：`_start` 放入 `.text.boot`（OpenSBI 跳到 payload base `0x80200000`，非 ELF e_entry）；
  `trapEntry` 必须 4 字节对齐（否则 `stvec` MODE 位被污染）。

### arch 渐进迁移（同轮）

- `kernel/main.zig` 经 `arch.zig` 使用：`serial`、`interrupts`、`paging`、`timer`、`context_switch`。
- 仍直连 x86：`gdt`、`tsc`、`syscall_entry`（待后续里程碑纳入 arch 契约）。

### 3.7 M3 完成记录（2026-07-11）

- **`fdt.zig`**：解析 `/memory` `reg`（父节点 `#address-cells/#size-cells` 栈，避免 `/soc` 覆盖）。
- **`pmm.zig`**：4K 页侵入式 freelist；排除内核镜像与 DTB 页。
- **`sv39.zig`**：根页表 + DRAM/UART 恒等映射，`satp` MODE=Sv39；`mapPage`/`unmapPage`。
- **自测**：映射 VA `0x40000000` R/W → unmap → 故意 load → `page-fault trap: OK`。
- **门禁**：`zig build -Darch=riscv64 smoke-riscv`（随后由 M5 门禁覆盖）。

### 3.8 M5 完成记录（2026-07-11）

- **`timer.zig`**：Sstc `stimecmp` 周期定时器（virt 10 MHz）。
- **`sched.zig`**：双内核线程私有栈；timer IRQ 中切换 `TrapFrame*` 并 `sret`。
- **`trap.zig`**：`trapHandler` 返回待恢复帧指针；处理 supervisor-timer（cause 5）。
- **自测**：`thread0`/`thread1` 均启动，`preemptive switches=8` 后 `M5 complete`。
- **说明**：此为骨架内最小调度，尚未接入完整 `proc/sched.zig`（待共享内核路径）。

### 3.9 M6 完成记录（2026-07-11）

- **`user.zig`**：用户 text/stack 页（PTE.U）；手写用户程序 `sys_write` + `sys_exit`。
- **`trap.zig`**：`sscratch` 切换内核 trap 栈；处理 `ecall` from U（cause 8）。
- **隔离**：内核恒等映射无 U 位；用户 VA `0x10000`/`0x20000` 单独映射。
- **流程**：M3 → M6（U-mode）→ `sys_exit` → M5（sched）→ shutdown。
- **门禁**：串口含 `hello from U`、`M6 complete`、`M5 complete`。

### 3.10 M7 完成记录（2026-07-11，virtio-blk + virtio-net）

- **`virtio_blk.zig`**：virtio-mmio 探测（8 槽 `0x10001000+`）；legacy(v1)/modern(v2) 双布局；
  单 virtqueue（8 描述符）+ 轮询 used ring；`readSector` 同步读。
- **队列内存**：BSS 双页（desc+avail | used 物理连续，满足 legacy 对齐）+ 请求页。
- **`virtio_net.zig`**：同槽位探测 DeviceID=1；协商 `VIRTIO_NET_F_MAC`；读 config MAC。
- **QEMU**：`qemu_run_riscv64.sh` 挂 `virtio-blk-device`（测试盘魔数 `MOQI_RV64_DISK`）+
  `virtio-net-device`（user netdev）。
- **自测**：`disk magic: OK` / `M7 complete`；`virtio-net MAC: OK` / `M7-net complete`。
- **流程**：M3 → **M7（blk+net）** → M6（U-mode）→ M5（sched）→ shutdown。
- **说明**：net TX/RX 与 ext2/FS 集成推迟至共享内核复用阶段。

### 3.11 M9-1…M9-7 完成记录（2026-07-11，aarch64）

- **构建**：`-Darch=aarch64`（`baseline-neon`）→ ELF @ `0x40000000`；QEMU `virt,gic-version=3`。
- **M9-1…M9-6**：PL011、DTB loader、VBAR/`brk`、PMM+MMU+#PF、CNTV、GICv3 PPI IRQ、EL0/`SVC`。
- **M9-7**：双 EL1 内核线程 + CNTV 抢占切换；IRQ 帧保存 ELR/SPSR 以支持换栈；
  `preemptive switches=` 达标后打印 `M9-7 complete`。
- **门禁**：`smoke-aarch64`（…`hello from U` + `M9-6` + `preemptive switches=` + `M9-7 complete`）。
- **后续**：SK-17 — 更大 `proc/sched` 复用 / 共享内核主路径接入。

### 3.12 SK-15 完成记录（2026-07-14）

- **共享探针** `kernel/shared/sk15.zig`：`createKernelThread`×2 + `buildKernelTrapFrame` +
  `armSharedPreemptTimer` + `enterTrapFrame`；timer IRQ 经 arch trap → `sk15.onTimer` 换栈。
- **riscv64**：`stimecmp`/STIE；TrapFrame 保留 `gp`/`tp`/`sp`；boot stack 256KiB（FdTable memset）。
- **aarch64**：GICv3 + CNTV；boot stack 256KiB。
- **门禁**：`smoke-riscv` / `smoke-aarch64` 要求 `[SK-15] shared preempt: OK`；`zig build smoke` 不回归。
- **后续**：SK-16 — M5/M9-7 收敛到共享 dual preempt。

### 3.13 SK-16 完成记录（2026-07-14）

- **共享** `kernel/shared/sk16.zig`：与 SK-15 同路径（`createKernelThread` + `buildKernelTrapFrame` +
  `armSharedPreemptTimer` + `enterTrapFrame`），完成时回调 arch 里程碑钩子。
- **riscv64** `sched.zig` / **aarch64** `sched.zig`：删除 BSS 双栈本地调度；保留
  `M5 complete` / `M9-7 complete`（aarch64 仍导出 `TrapFrame` 布局）。
- **门禁**：`[SK-16] shared milestone preempt: OK` + 既有 M5/M9-7 标记；三门禁不回归。
- **后续**：SK-17 — `per_cpu` 队列 + `sched.enqueue` / 优先级 pick。

### 3.14 SK-17 完成记录（2026-07-14）

- **共享** `kernel/shared/sk17.zig`：对齐 `main.zig` 的 `per_cpu.init(0)` → 创建不同
  priority 内核线程 → `sched.enqueue` → LIFO `pop` + `task.pickReadyForCpu`。
- **不调用** `sched.timerTick`（仍含 x86 CR3/iretq）；为后续 block/wake 与主路径收敛铺路。
- **门禁**：`[SK-17] shared sched queue+pick: OK`；三门禁不回归。
- **后续**：SK-18 — 可移植 wake/block（无 `forceReschedule`）。

### 3.15 SK-18 完成记录（2026-07-14）

- **共享** `kernel/shared/sk18.zig`：按 `sleepOn` 同序挂 `WaitNode`，验证 FIFO `wakeOne` +
  `wakeAll`、blocked 不可 pick、就绪后清 `wait_queue`。
- **不调用** `sleepOn`/`forceReschedule`/`timerTick`。
- **门禁**：`[SK-18] shared sched wake+block: OK`；三门禁不回归。
- **后续**：SK-19 — 可移植 `sleepOn` hook + `main.zig` BSP 引导片段共享。

### 3.16 SK-19 完成记录（2026-07-14）

- **共享** `kernel/shared/sched_boot.zig`：`initBspRunQueue` + `createIdleThread`；`main.zig` 改用。
- **`sched.blockOn` / `setPortableReschedule` / `setCurrentTaskIndex`**：`sleepOn` 可在非 x86
  经 hook 停车而不进入 `timerTick`；`kickCpu`/`forceReschedule` 经 comptime 隔离 x86。
- **探针** `sk19.zig`：`[SK-19] shared sleepOn+sched_boot: OK`。
- **后续**：SK-20 — 可移植协作 switch 后端接 `forceReschedule`。

### 3.17 SK-20 完成记录（2026-07-14）

- **`switchToSoftwareFrame`**：按 `InterruptFrame.rsp` 恢复栈后 sret/eret（不覆盖 SK-14 resume）。
- **`portableKernelSwitch`**：非 x86 `forceReschedule` 默认路径；`.blocked` 保留调用方
  安装的 resume 帧，`.running` 保存续体后入队。
- **探针** `sk20.zig`：`blockOn` → 安装 resume entry → switch → `wakeOne` → switch back。
- **门禁**：`[SK-20] portable sleepOn switch: OK`；三门禁不回归。
- **后续**：SK-21 — 更多 `main.zig` 子系统 init 共享。

### 3.18 SK-21 完成记录（2026-07-14）

- **共享** `kernel/shared/subsystem_boot.zig`：`initCpuSurfaces`（gdt/tsc/GS）+
  `initIpcAndSyscall`（对齐 main.zig M4）；`main.zig` 改用后者。
- **探针** `sk21.zig`：`initAll` + TSC 单调读；`[SK-21] shared subsystem boot: OK`。
- **后续**：SK-22 — 可移植 `timerTick` 子集。

### 3.19 SK-22 完成记录（2026-07-14）

- **`sched.timerTickPortable` / `resetTimeslice`**：仅做时间片递减；到期则
  `forceReschedule`（软件帧协作切换），无 IRQ frame / CR3 / 信号 / 写回。
- **探针** `sk22.zig`：双同优先级线程经 tick 抢占；`[SK-22] portable timerTick: OK`。
- **后续**：SK-23 — arch 定时器 IRQ 接到共享时间片。

### 3.20 SK-23 完成记录（2026-07-14）

- **`sched.hardwareTimerTick` / `timesliceExpired`**：IRQ 安全记账（不切换）。
- **trap**：riscv/aarch64 定时器路径在 sk15/sk16 之后调用 `sk23.onTimerIrq`。
- **探针**：任务 `wfi`，IRQ 耗尽时间片后 `forceReschedule`；`[SK-23] irq ticks wired to timeslice: OK`。
- **后续**：SK-24 — IRQ 上下文内直接软件帧抢占，或更多引导收敛。

### 3.21 SK-24 完成记录（2026-07-15）

- **`sched.preemptFromIrq`**：从原生 TrapFrame 取 PC/SP，写入软件 `InterruptFrame`，
  经 `switchToSoftwareFrame` 切走（不返回 IRQ epilogue）。
- **arch**：`irqInterruptedPc` / `irqInterruptedSp`（riscv `sepc`/`sp`；aarch64 `elr` /
  `frame+192`）。
- **trap**：sk23 之后调用 `sk24.onTimerIrq`；到期则 noreturn 抢占。
- **探针**：任务 `wfi`，IRQ 到期直接抢占到对端；`[SK-24] irq software-frame preempt: OK`。
- **后续**：更多引导 / `main` 收敛，或用户态 IRQ 抢占路径。

### 3.22 SK-25 完成记录（2026-07-16）

- **`subsystem_boot.initPortableMm`**：对齐 `main.zig` M2 的 `addr_space.init` + `dma.init`。
- **`main.zig`**：改调该共享入口；`initAll` 亦纳入 portable mm。
- **探针**：`addRange`/`findRange` + `dma.allocCoherent` 单页往返；
  `[SK-25] shared portable mm boot: OK`。
- **后续**：SK-26 — 继续引导收敛，或用户态 IRQ（原生 TrapFrame，非软件帧）。

### 3.23 SK-26 完成记录（2026-07-16）

- **薄探针**：EL0 `wfi` / U-mode nop 忙等 + 开中断；timer IRQ 经原生 TrapFrame 计数，
  首个用户态 tick 后 `finishUserIrqProbe` 回到 announce（**不** `preemptFromIrq`）。
- **arch**：`irqFromUserMode` / `prepareUserIrqProbe` / `enterUserIrqProbe` /
  `finishUserIrqProbe`；riscv 看 `SPP`，aarch64 看 `spsr` EL0（`spsr=0`，异于 M9-6 的 DAIF mask）。
- **探针**：`[SK-26] user timer IRQ visible: OK`。
- **后续**：SK-27 — 用户态原生 TrapFrame 抢占，或继续引导/`main` 收敛。

### 3.24 SK-27 完成记录（2026-07-16）

- **换帧**：复用 SK-15 的 `onTimer` 帧指针切换；`buildUserTrapFrame` 造 U/EL0 假帧。
- **aarch64**：`vectors.S` IRQ 保存/恢复 `SP_EL0` → `TrapFrame.sp_el0`（勿用 frame+192）。
- **探针**：K→U→U 被打断→完成；`[SK-27] user trapframe preempt: OK`。
- **后续**：SK-28 — 继续引导/`main` 收敛，或双用户/共享调度接入用户抢占。

### 3.25 SK-28 完成记录（2026-07-16）

- **U↔U**：两用户假帧 + 双栈；`onTimer` 帧指针切换（同 SK-15/27）。
- **enterTrapFrame**：支持直接进入 U/EL0（riscv 设 sscratch+user SP；aarch64 恢复 SP_EL0）。
- **探针**：`[SK-28] dual-user trapframe preempt: OK`；退出走 `finishUserIrqProbe`。
- **后续**：SK-29 — 共享 sched 接入原生用户抢占，或继续引导/`main` 收敛。

### 3.26 SK-29 完成记录（2026-07-16）

- **`sched.nativeTrapFramePreempt`**：先 `pickNext` 再 `enqueue` current（LIFO 安全）；
  把 live TrapFrame 写入 `Task.saved_rsp`，返回 next 帧指针给 IRQ epilogue。
- **探针**：双用户任务经 shared runqueue 切换；**不**走 `preemptFromIrq`/软件帧。
- **标记**：`[SK-29] sched native-user preempt: OK`。
- **后续**：SK-30 — 时间片/`preemptFromIrq` 原生用户路径，或继续引导/`main` 收敛。

---

## 4. M8 进度（x86_64 SMP）

把 M8 拆成可单独验证、可单独提交的小步；每步保持 **x86_64 单核不回归**（构建 + 启动到
`MoQiOS shell`），多核相关行为在 AP 上线（M8-5）后用 `-smp N` 验证。

| 子步 | 内容 | 状态 |
|---|---|---|
| **M8-1** | 通用 IPI 基础设施：`lapic.sendIpi(apic_id, vector)` + `sendIpiAllButSelf`；reschedule(0xFD)/TLB-shootdown(0xFE) 向量与 `interruptDispatch` 分发 + 处理器 | ✅ 完成（单核休眠态，未改调度行为） |
| **M8-2** | per-CPU 当前任务/时间片状态：`current_idx`/`slice_remaining` 迁入 `PerCpu`（单核等价 BSP） | ✅ 完成（单核回归一致，386 行启动到 shell） |
| **M8-3** | per-CPU 上下文切换 anchor：`commonStub` 经 `%gs` 取 per-CPU anchor（无需 swapgs） | ✅ 完成（单核回归一致，386 行启动到 shell） |
| **M8-4** | per-CPU TSS RSP0：`setRsp0` 作用于当前 CPU 而非固定 BSP | ✅ 完成（单核回归一致，386 行启动到 shell） |
| **M8-5a** | AP 上线 + 开定时器 + `enable_ap_startup=true`，但仍 BSP-only 调度（AP 空闲取中断） | ✅ 完成（`-smp 2`：2 CPUs online，BSP 跑完全部测试到 shell，零故障） |
| **M8-5b-2** | 亲和调度（无迁移）+ AP 参与 `timerTick` + AP 绑核 idle 引导 | ✅ 2b 完成（用户任务暂绑 BSP，`MOQI_SMP=2` 稳定到 shell）；2c round-robin@AP 待办 |
| **M8-5b-2d** | `saved_user_rsp` 迁入 Task + 上下文切换同步 | ✅ 3/3 `MOQI_SMP=2`→shell（用户仍绑 BSP） |
| **M8-5b-2e** | flat round-robin@AP（`assignCpuAffinity` flat 分支） | ✅ 完成 |
| **M8-5b-3** | FPU/SSE 按任务保存 + AP `CR4.OSFXSR` 对齐 | ✅ 完成（2026-06-21） |
| **M8-5b-4** | 可迁移调度（`saved_user_rsp` 随任务） | ✅ 完成 |
| **M8-5b** | （父项）AP 真正并行调度 | ✅ 全部完成（2026-06-21） |
| **M8-6** | 跨核 TLB shootdown：per-CPU shootdown 描述符 + 范围 `invlpg`（取代 M8-1 的 CR3 全刷回退） | ✅ 完成（2026-06-21） |
| **M8-7** | per-CPU 运行队列 + work-stealing（取代全局 `sched_lock` 瓶颈） | ✅ 完成（2026-06-21） |

### M8-1 设计要点

- **向量选择**：`0xFD`（reschedule）、`0xFE`（TLB shootdown），避开 PIC 重映射区（32–47）、LAPIC
  定时器（240）、AHCI（241），且低于 spurious（`0xFF`）。256 个 IDT stub 在 `idt.init()` 已全部安装，
  因此无需新增门，只需在 `interruptDispatch` 增加分发分支。
- **`sendIpi`**：Fixed 投递（000）、物理目的、assert（bit14）、edge；轮询 ICR delivery-status（bit12）。
  允许 self-IPI（目标为自身 APIC ID），用于强制本核 reschedule。
- **休眠态安全**：单核下无人发送 IPI，两个处理器分支不会触发，调度行为与之前逐字节一致；故
  本步唯一验证目标是「仍构建并启动到 shell」。后续 M8-5 上线 AP 后这些原语才真正被驱动。

### M8-2 设计要点

- **存储下沉**：运行任务索引 `current_task_idx`（`0xFFFFFFFF`=无）与剩余时间片 `slice_remaining`
  从 `sched.zig` 模块全局变量改为 `PerCpu` 字段，经 `GS_BASE` 访问。`sched` 内新增
  `getCurrentIdx/setCurrentIdx/getSlice/setSlice` 访问器，调度器所有读写改走访问器。
- **早期启动安全**：新增 `syscall_entry.getPerCpuOrNull()`，当 `GS_BASE==0`（`syscall_entry.init()`
  之前）返回 null；`currentTask()/currentTaskIndex()` 在 per-CPU 数据就绪前安全返回「无任务」。
  初始化序列保证 `GS_BASE` 在 `sti`（首个定时器中断）之前已设好。
- **单核等价**：uniprocessor 下 `GS_BASE` 恒指向 `percpu_array[0]`，访问器与旧全局变量逐字节等价；
  `slice_remaining` 初值置为 `TIMESLICE_TICKS`(10) 以匹配旧默认。`saved_stack_anchor` 仍为全局
  （M8-3 下沉），TSS 仍绑 BSP（M8-4 下沉），故 AP 仍停泊。

### M8-3 设计要点（关键）

- **GS 不变量（本内核特性）**：`GS_BASE` 在**所有模式**下都指向「本核」的 `PerCpu`。`init`/`apEntry`
  把 `GS_BASE` 与 `KERNEL_GS_BASE` 都设为 `&percpu_array[cpu]`；syscall 路径的 `swapgs` 只是
  percpu↔percpu（基址不变），上下文切换更新的是 `KERNEL_GS_BASE` 而非 `GS_BASE`。故
  **`commonStub` 中可直接用 `%gs` 而无需 swapgs**，即使中断来自用户态。
- **anchor 下沉**：`commonStub` 用 `movq %rsp, %gs:16` / `movq %gs:16, %rsp` 存取本核
  `PerCpu.saved_stack_anchor`（偏移 16，`sched.zig` 用 `comptime` 断言守护）。删除原 `pub export var
  saved_stack_anchor` 全局；`sched`/`execve` 改用 `sched.getAnchor()/setAnchor()`。
- **早期启动安全**：在 `idt.init()` 之后立即设 BSP `GS_BASE`（`setPerCpuGsBase(0)`），保证启动后续任何
  异常进入 `commonStub` 时 `%gs` 有效（否则 `GS_BASE==0` 会让 stub 自身写 `0x10` 触发三重故障，丢诊断）。
- **多核可扩展**：每核有独立 `GS_BASE` → 各自的 anchor，互不干扰；这是让 AP 能跑上下文切换的前置条件。
- **为何不用 swapgs-on-CS**：鉴于上面的 GS 不变量，swapgs 在本内核里是 no-op 基址交换，加之只会增加
  复杂度与风险；故采用更精简且等价的「直接 `%gs`」方案。代价：用户态 `%gs` 被内核占用（用户程序不能用
  `%gs` 做 TLS）——当前 `hello*` 程序均不使用，符合现状。

### M8-4 设计要点

- **TSS RSP0 按当前核**：调度器/`execve` 原先调用 `gdt.setRsp0Bsp`（固定写 `tss[0]`），改为
  `gdt.setRsp0(currentCpuId(), ...)`，写「本核」的 `tss[cpu_id].rsp0`。
- **硬件正确性**：每核加载自己的 GDT（`gdt_entries[cpu_id]`），其 entry 6（`TSS_SEL=0x30`）指向
  `tss[cpu_id]`，故 `ltr 0x30` 在第 N 核加载 `tss[N]`；写本核 `tss[cpu_id].rsp0` 即影响该核用户→内核
  中断投递所用栈。`PerCpu.kernel_rsp`（syscall 路径用栈）此前已是 per-CPU。
- **单核等价**：`currentCpuId()==0`，与 `setRsp0Bsp` 完全一致；回归零非规范 RSP0 告警。

### M8-5a 设计要点（解除历史阻塞点）

- **历史阻塞点**：此前「AP 一旦真正运行，BSP 用户进程就随机三重故障」。两个根因均已修复：
  (1) TSS 错位致用户态中断投递从未工作（已改 packed TSS）；(2) 调度状态用共享全局——M8-2~M8-4 已全部
  下沉为 per-CPU。故现在可安全 `enable_ap_startup=true`。
- **AP 上线路径**：`apEntry` 顺序调整为「设 `GS_BASE` → 开 LAPIC 定时器(`initAp`)」，保证首个定时器中断进入
  `commonStub` 时 `%gs:anchor` 已有效；随后进入 `apIdleLoop`(`sti;hlt`)。
- **BSP-only 调度（本步）**：`timerTick` 开头 `if (currentCpuId()!=0) return;`，AP 取定时器中断但不调度；
  全局 tick（`incrementTick`）仅 BSP 自增，避免多核下时钟走快 N 倍（`handleLapicTimer` 中按核门控）。
- **CPL0 中断不需 RSP0**：AP 空闲时处于内核态(CPL0)，定时器中断不切栈（无特权级变化），直接用 AP 当前内核栈；
  故 M8-5a AP 不触及 TSS RSP0。
- **验证**：`-smp 2` 下 `[SMP] 2 CPUs online`，AP 走完 B–J 全部 bring-up 标记并 `AP 1 initialized`，BSP 跑完
  `init` 自动序列（至 `hello21`）到 `MoQiOS shell`，**零故障/零非规范 RSP0**
  （串口约 395 行，比单核多 9 行 SMP bring-up 信息）。

### M8-5b 调查（让 AP 真正参与调度的阻塞点）

> 结论：**M8-5b 不是“一个小任务”**。让 AP 真正运行用户任务会连锁暴露该内核多个「SMP 未就绪」缺口。
> 已实现过一版（per-CPU idle 任务 + 调度门 `ap_sched_enabled` + BSP-only 周期维护 + `pickNext` 亲和过滤
> + AP 高半区跳转修复），**单核回归通过**，但 `-smp 2` 仍崩溃。已逐一定位根因如下；这一版代码已回退，
> 工作树恢复到稳定的 M8-5a，待与维护者确认方向后再按下面的“推荐路线”重做。

逐个定位到的阻塞点（按发现顺序）：

1. **AP 在低半区身份映射中执行 → 三重故障**（已找到修复法）。
   - 现象：`-d int,cpu_reset` 显示 AP（CPU 1）的 RIP/RSP/GDT/TSS 全在低物理地址（trampoline 身份映射区）。
     一旦 AP 调度到用户任务并加载该任务 CR3，用户页表里**没有**这段低地址的身份映射 → `#PF`→`#DF`→三重故障。
   - 修复法（已验证可编译）：在 `smp.init()` 把 HHDM offset 存到 trampoline 数据区（如 phys `0x7070`）；
     `apEntry` 改成 naked，先把 `RSP`/`RIP` 重定位到 HHDM 高半别名再跳进 `apEntryHigh()`。此后 AP 始终在
     高半区执行——高半区在**所有**进程页表中共享，切到任意用户 CR3 都安全。**此修复是后续一切的前置条件。**

2. **`saved_user_rsp` 是 per-CPU，但语义是 per-task**（迁移致命）。
   - syscall 进入时把用户 `RSP` 存进 `PerCpu.saved_user_rsp`（`%gs:8`），返回时 `movq %gs:8,%rsp; sysretq`。
   - 阻塞型 syscall（`waitpid`/`futex` 等）会 `sti` 后 `hlt` 自旋等待，期间**可被抢占并迁移到另一核**。
     任务在 A 核进 syscall（`saved_user_rsp`写到 A 核 PerCpu），迁移到 B 核恢复并 `sysretq` 时读的是
     **B 核**的 `saved_user_rsp`（可能已被 B 核上别的任务覆盖）→ 返回到错误用户栈 → 用户态 `#UD` / `#GP`。
   - 注：单核下该值“跨任务复用同一 PerCpu”也存在覆盖，但因为单核恢复点严格配对、且 `clone` 用同核值，
     恰好不出错；多核迁移打破了这个隐式不变量。

3. **`exec_result` 是真正的共享全局**（信号返回路径，需 per-CPU 化）。
   - `syscall_entry.exec_result`（3×u64）由信号投递写、由 syscall/中断返回路径消费。多核并发下两核互相踩。
   - （`fork_parent_ret` 经核查**从未被写非零**，恒为 0，并非并发问题，可不动。）

4. **FPU/SSE 状态未随上下文切换保存/恢复**。
   - 上下文切换不保存 FPU/SSE；用户程序默认带 SSE。任务迁移到另一核后会用到别的任务残留的 FPU 状态，
     或 AP 的 `CR4.OSFXSR`/`CR0` 配置与 BSP 不一致时直接 `#UD`。需确认 AP 的 `CR4.OSFXSR`、`CR0.MP/EM`
     与 BSP 对齐，并最终引入按任务的 FXSAVE/FXRSTOR。

5. **缺少跨核 TLB shootdown（M8-6）**。
   - 多核共享地址空间改页表后需广播 `invlpg`；当前无此机制，并行跑会有 TLB 不一致风险（M8-6 专门解决）。

**推荐路线（把 M8-5b 拆成更小、风险可控的步骤）**

- **M8-5b-0｜AP 高半区执行修复**（上面第 1 点）：自洽且必须，先单独落地+多核验证（AP 仅空闲，不调度）。**✅ 已完成**
  （`ap_trampoline` 在分页后直接 `jmp` HHDM 虚拟 `apEntry`；`0x7010`/`0x7030` 存虚拟栈顶/入口；
  `-smp 2`：2 CPUs online + BSP 到 shell，零故障）。
- **M8-5b-1｜全局态 per-CPU 化**：`exec_result` 迁入 `PerCpu`（`%%gs:48/56/64` 相对访问），消除第 3 点。**✅ 已完成**
  （`-smp 2`：hello13 信号/sigreturn 正常，到 shell 零故障）。
- **M8-5b-2｜亲和调度（无迁移）**：所有任务创建时**绑核**（round-robin），`pickNext` 按 `cpu_affinity`
  过滤；fork 继承父核。无迁移 ⇒ 回避第 2 点（`saved_user_rsp` 永不跨核）。**已落地**：
  - `createKernelThreadAffinity` + `smp.init` 为每个 AP 预建绑核 idle；
  - `apBootstrapIdle`：AP 在启用定时器前 `iretq` 进入绑核 idle（`cur_idx` 永不为 null）；
  - `pickBootstrapKernel`：`cur_idx==null` 时优先选本核内核线程；
  - **AP 进用户态**：`commonStub` 假帧 `iretq` 在 AP 切用户 CR3 后失效 → `enterUserOnAp` 直接构造
    `iretq` 帧（与 `user_mode.zig` 同布局）。
  - **验证**：`MOQI_SMP=1` 仍到 shell；`MOQI_SMP=2` BSP 跑 init，AP 可进用户态但 `hello2` 在 AP 上
    `#PF`（`copy_from_user`/syscall 路径，待 5b-2 后续小步）；`hello4` ELF 在 AP 上挂起。
- **M8-5b-3｜FPU/SSE 对齐 + 按任务保存**（第 4 点）：作为迁移的前置。
- **M8-5b-4｜可迁移调度**：在 2/3 之上引入安全迁移（迁移点限定在“非 syscall 持栈”态，或把 `saved_user_rsp`
  随任务保存），并配合 M8-6 的 TLB shootdown。

> 当前进度：**M8 全部完成**（2026-06-21）。
> - **M8-5b-3**：FPU/SSE 按任务 lazy save/restore（CR0.TS + #NM）。
> - **M8-6**：范围 TLB shootdown（`tlb.shootdownRange` + invlpg + 32 页阈值 CR3 回退）。
> - **M8-7**：per-CPU 运行队列 + work-stealing（`PerCpuRunQueue` 256 槽 LIFO + steal_half）。
> - 三者互为前提，同时交付后 AP 首次可真正跨核运行用户任务。
> - 验证：`MOQI_SMP=1` 与 `MOQI_SMP=2` 均完整跑通 `init` 自动序列（至 `hello21 done`）+ `MoQiOS shell`
>   （`init.S` 当前在 hello21 后进入 shell；hello22–28 为手动/后续用例，非自动序列）。

---

## 5. 未实现功能清单与性能优先执行计划（2026-06-07）

### 5.1 分类概览

| 类别 | 代表项 | 状态 | 性能影响 |
|---|---|---|---|
| **SMP 调度** | round-robin@AP、任务迁移、per-CPU 运行队列 | ✅ M8-5b/M8-7 | **极高**（已落地） |
| **SMP 内存** | 范围 TLB shootdown（`invlpg`） | ✅ M8-6 | **高**（已落地） |
| **SMP 浮点** | FXSAVE/FXRSTOR 按任务 | ✅ M8-5b-3 | 中（已落地） |
| **架构抽象** | `kernel/arch/arch.zig` 多 ISA 接口 | ✅ M4；渐进迁移中 | 中（移植效率，非热路径） |
| **riscv64** | M2–M7 ✅；共享内核复用待续 | ✅ M7 blk+net | N/A（第二 ISA） |
| **aarch64** | M9-1…M9-7 ✅（…EL0/SVC + preempt sched） | ✅ M9-7 | N/A（第三 ISA） |
| **未集成脚手架** | `futex`/`select`/`inotify`/`clone`/`mprotect`/SysV IPC/`aio`/`splice`/`dhcp`/`dns` 等 | 🧩 源文件在树中，未 `@import` | 低（按需接入） |
| **缺页恢复** | 内核态 per-instruction fixup | ⚠️ 页表预检替代 | 中 |
| **单元测试** | `zig build test`（host helpers） | ✅ 有基础用例 | 低（质量门） |

### 5.2 性能优先原则

1. **热路径零全局锁**：调度器从单一 `sched_lock` 迁到 per-CPU 就绪队列 + 偷取（M8-7）。
2. **IPI 精确投递**：APIC id 必须来自 MADT/`lapic.id()`，kick 目标用 `wait_cpu` 而非 affinity 猜测。
3. **TLB 最小失效**：共享映射改动用范围 `invlpg` + shootdown 描述符（M8-6），禁止 CR3 全刷热路径。
4. **无迁移直到 FPU 就绪**：亲和绑核（5b-2）回避 `saved_user_rsp` 跨核；迁移（5b-4）在 FXSAVE 之后。
5. **syscall 阻塞不 corrupt anchor**：`waitpid` 等不能在 syscall 栈上调用 `forceReschedule()`；须 timer 中断
   切走（`sti`+`hlt`）或把 `saved_user_rsp` 迁入 `Task`（5b-4 一并解决）。

### 5.3 执行顺序（推荐）

```
Phase A — SMP 稳定基线          ✅ M8-5b-2b（BSP 绑核，MOQI_SMP=2→shell）
Phase B — AP 并行用户态         ✅ M8-5b-2d（round-robin flat@AP + ELF@AP）
Phase C — 浮点与迁移前置        ✅ M8-5b-3（FXSAVE/FXRSTOR）
Phase D — TLB 性能              ✅ M8-6（shootdown 描述符 + invlpg 范围）
Phase E — 调度器扩展性          ✅ M8-7（per-CPU runqueue + work-stealing）
Phase F — 第二 ISA              ✅ M2–M7；✅ SK-1…SK-29
Phase F2 — 第三 ISA             ✅ M9-7；✅ SK-1…SK-29
Phase G — 按需 syscall 脚手架  ⬜ futex/select/clone…（按应用需求逐个接入）
```

### 5.4 历史设计备忘（M8-5b-2d/2c — 已完成）

> 下列步骤在 2026-06 已落地；保留作调查记录，**不再是下一执行项**。
> 当前下一执行项：**SK-30** — 时间片/`preemptFromIrq` 原生用户路径，或继续引导/`main` 收敛；
> SK-1…SK-29 已完成。
> M3–M7（blk+net）与 M9-1…M9-7 已于 2026-07-11 完成。

**原 5b-2d 目标**（已完成）：flat round-robin@AP → ELF@AP；`saved_user_rsp` 入 Task。

**原 5b-2c 根因备忘**：
- `waitpid` 在 syscall 上下文不可调用 `forceReschedule()`（会破坏 anchor）。
- 跨核唤醒依赖 `wait_cpu` / `kickChildCpus` / IPI `force_reschedule` 旁路。

**验证**：`zig build smoke` + `zig build smoke-smp`；riscv64：`zig build -Darch=riscv64 smoke-riscv`。

### 5.5 未集成脚手架接入优先级

仅当 Phase A–E 完成或有明确应用需求时接入；接入模式：`syscall_entry` 分发 → 模块实现 → `hello*` 回归。

| 优先级 | 模块 | 理由 |
|---|---|---|
| P1 | `sync/futex.zig` | 用户态 pthread/同步基础 |
| P1 | `fs/select.zig` / `fs/poll.zig` | 网络/IO 多路复用（hello26 已有 poll 路径） |
| P2 | `arch/x86_64/clone.zig` | 线程库前置 |
| P2 | `mm/mprotect.zig` | W^X / JIT |
| P3 | SysV IPC、`inotify`、`aio`、`splice` | 兼容层，非热路径 |
| P3 | `net/dhcp.zig` / `net/dns.zig` | 网络自动化，非内核热路径 |
