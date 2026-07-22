# MoQiOS 跨 CPU 架构移植路线图（2026-06 起）

本文件是 MoQiOS 从「单一 x86_64」走向「多 ISA、性能最优、SMP 可扩展」的总体计划与进度跟踪。
目标第二 ISA 选定 **riscv64**（特权架构最简洁、最易自举，Zig/LLVM 原生支持），第三 ISA
（aarch64）复用同一抽象层。

> 现实预期：完整跨 ISA 移植是**数月级、多轮**工程。本文件按里程碑（M0–M9）分解，每个里程碑
> 都要求「可构建 + 可验证 + x86_64 不回归」。

---

## 0. 现状基线（移植起点 → 2026-07 更新）

- **架构抽象**：`kernel/arch/arch.zig` 已存在（M4）；x86_64 / riscv64 / aarch64 各有 `arch_impl.zig`。
  **SK-8**…**SK-33**：facade、portable mm、时间片原生用户抢占、探针阶梯、slab/page_cache。
  **SK-34**…**SK-46（2026-07-19）**：tmpfs/random、cpu surfaces/symbol_table、
  阶梯收尾、非 x86 BSS 瘦身（readahead 窗口 + 符号表 + env 缓冲 + FdTable
  按架构裁剪；非 x86 Task 62KB→**4.5KB**）、copy_from_user 走 arch facade
  （satp/TTBR0 + SUM），M6/M9-6 用户 `sys_write` 复用共享防护；
  main.zig idle 线程 / boot 尾部 idle 循环收敛进 `sched_boot`；
  共享 ramdisk 解析首次在非 x86 运行；loader ELF64 头/phdr 解析抽出
  共享 `proc/elf.zig`（EM_CURRENT 按 arch 选择）；`buildUserStack`
  （Linux ABI 入口栈）抽出共享 `proc/user_stack.zig`；vfs 写回回调
  注册收敛进 `subsystem_boot`（共享写回缓存首次在非 x86 运行）；
  探针 `[SK-42] shared idle boot fragment: OK`、
  `[SK-43] shared ramdisk parse: OK`、
  `[SK-44] shared elf header parse: OK`、
  `[SK-45] shared user stack build: OK`、
  `[SK-46] shared writeback cache: OK`。
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

### 3.26b 帧驻留修复（2026-07-16 review）

- **隐患**：riscv U-mode IRQ 共用 `u_trap_stack`；仅保存帧指针时，对端下一次 U IRQ
  会覆写上一任务的 TrapFrame（SK-28/29 原探针在 switches=2 就退出，未覆盖此路径）。
- **方案**：`relocateNativeTrapFrame` — 帧已在本任务内核栈则零拷贝；否则 memcpy 到
  `kstack_top - 2*FRAME`（性能最优：aarch64 快路径几乎总是 no-op）。
- **验证**：SK-28/29 要求 `switches >= 4`，确保在共享 trap 栈被复用后仍能正确恢复。

### 3.27 SK-30 完成记录（2026-07-17）

- **`sched.nativeUserTimerPreempt`**：`hardwareTimerTick` 记账；到期则 refill +
  `nativeTrapFramePreempt`（**不**走 `preemptFromIrq`/软件帧）。
- **探针**：双用户 + 时间片；未到期原帧返回；`[SK-30] timeslice native-user preempt: OK`。
- **附带**：SK-6 `SHARE_BYTES` 4→8 MiB，避免探针阶梯耗尽 arena 后 M5/`sk16` 栈 OOM。
- **后续**：SK-31 — 引导/`main` 收敛，或常驻路径把 arch timer 接到 `nativeUserTimerPreempt`。

### 3.28 SK-31 完成记录（2026-07-17）

- **常驻 fallthrough**：trap 在 sk15..sk30 之后调用 `sk31.onDefaultTimer`（**无**
  `isEnabled` 旁路）；M5/M9-7 仍由早期 `sk16.isEnabled` 截获。
- **守卫**：仅 U/EL0 + `currentTaskIndex != null` 时调用 `nativeUserTimerPreempt`，
  避免干扰 M6 裸 `user.enter`。
- **探针**：与生产同路径；`[SK-31] default timer native-user preempt: OK`。
- **后续**：SK-32 — `runSharedSkProbes` 阶梯 / slab 引导收敛。

### 3.29 SK-32 完成记录（2026-07-17）

- **`sk_probes.zig`**：`runEarly`（sk2–4）+ `runPostMm`（sk6…sk32）；riscv/aarch64
  `start.zig` 共用，避免阶梯分叉。
- **`subsystem_boot.initSlab`**：与 `main.zig` M2 slab 调用对齐；`slab.init` 幂等。
- **探针**：`initSlab` + kmalloc/kfree；`[SK-32] shared sk probes+slab boot: OK`。
- **后续**：SK-33 — 继续把非 x86 引导向 `main.zig` 可复用片段收敛（勿整文件搬迁）。

### 3.30 SK-33 完成记录（2026-07-17）

- **`subsystem_boot.initPageCache`**：与 `main.zig` M7 前 `page_cache.init` 对齐；
  `page_cache.init` 幂等；并入 `initAll`。
- **探针**：insertOwned → read hit → invalidate；`[SK-33] shared page_cache boot: OK`。
- **后续**：SK-34 — 继续可移植引导片段（如 `tmpfs` / `random`@`arch.tsc`），勿整文件搬迁。

### 3.31 SK-34 完成记录（2026-07-17）

- **`subsystem_boot.initTmpfs` / `initRandom`**：与 `main.zig` 对齐；二者 init 幂等并入 `initAll`。
- **`random`**：去掉内联 `rdtsc`，改用 `arch.tsc.read`（riscv `rdtime` / aarch64 `cntvct`）。
- **探针**：tmpfs open/write/read/unlink + 两次 getRandom 不相等；
  `[SK-34] shared tmpfs+random boot: OK`。
- **后续**：SK-35 — 继续可移植片段（如 `main` 接 `initCpuSurfaces`、symbol_table），勿整文件搬迁。

### 3.32 SK-35 完成记录（2026-07-17）

- **`main.zig`**：早期 `initCpuSurfaces`（gdt+tsc+GS，在 IDT/FPU 之前）；
  `initSymbolTable` 取代手写 `symbol_table.init`；统一 `subsystem_boot` 导入。
- **`subsystem_boot.initSymbolTable`**：幂等；并入 `initAll`。
- **探针**：tsc 单调 + addSymbol/sort/lookup；
  `[SK-35] shared cpu surfaces+symbol table: OK`。
- **后续**：SK-36 — 探针阶梯收尾防 M6 误抢占。

### 3.33 SK-36 完成记录（2026-07-17）

- **隐患**：sk29/30 成功或 sk31 早期失败可能留下非空 `current` + 已武装 timer；
  SK-31 fallthrough 会在后续 M6/`user.enter`（SPIE）上误抢占。
- **方案**：`disarmSharedPreemptTimer`（riscv 清 STIE + 远 `stimecmp`；aarch64 停 CNTV）；
  `finishUserIrqProbe` 清 `current`；`sk36` 在 `runPostMm` 末尾再清一次并验证。
- **探针**：`[SK-36] probe ladder cleanup: OK`。
- **后续**：SK-37 — 继续可移植片段 / BSS 瘦身（勿整文件搬迁）。

### 3.34 SK-37 完成记录（2026-07-19）

- **动机**：非 x86 `.bss` ~4.8MB，`tasks[64]`（每个 ~62KB，主体是 per-fd
  readahead 缓存数组）+ `symbol_table`（320KB）占绝对大头。
- **方案**：`readahead.MAX_WINDOW` 与 `symbol_table.MAX_SYMBOLS` 按架构 comptime
  裁剪（x86 不变：32 / 4096；非 x86：2 / 64）。x86 布局与行为零变化。
- **效果**：riscv64/aarch64 BSS 4.84→**1.57MB**（−67%）；非 x86 `Task` 62KB→**18.2KB**。
- **探针**：comptime 上限断言 + createKernelThread 往返 + `task_bytes=` 打印；
  `[SK-37] slim task/symbol footprint: OK`。
- **后续**：SK-38 — 继续可移植片段（如 env/cwd 缓冲裁剪或 sched_boot 收敛）。

### 3.35 SK-38 完成记录（2026-07-19）

- **动机**：SK-37 后非 x86 `Task` 仍 18.2KB，`env_vars: [32][128]u8`（4KB/task）
  是剩余大项之一，而非 x86 bring-up 没有 exec/env 系统调用。
- **方案**：`task.ENV_MAX_VARS` / `ENV_VAR_BYTES` 按架构 comptime 裁剪
  （x86 不变：32/128；非 x86：4/64）。`env.zig` / `process_mgmt.getenv` /
  `fork` / `clone` 的硬编码 `32`/`128`/`127` 边界统一改用常量，
  消除行宽变化后的越界隐患；x86 数值不变、行为零变化。
- **效果**：非 x86 `Task` 18224→**14384B**（env 表 4KB→256B）。
- **探针**：comptime `@sizeOf(Task) <= 16KB` 断言 + `task_bytes=` 打印；
  `[SK-38] slim env buffers: OK`。
- **后续**：SK-39 — 继续可移植片段（sched_boot 收敛或 FdTable 裁剪）。

### 3.36 SK-39 完成记录（2026-07-19）

- **动机**：SK-38 后非 x86 `Task` 仍 14.4KB，`fd_table`（64 × FileDescriptor
  ≈ 10KB）是最后的大项；非 x86 bring-up 不走任何 fd 系统调用。
  （sched_boot 已在 SK-19 收敛，无需重复。）
- **方案**：`vfs.MAX_FDS` 按架构 comptime 裁剪（x86 不变：64；非 x86：8）。
  `free_bm` 默认值改为 comptime `FREE_BM_ALL`，把 ≥ MAX_FDS 的位保持清零，
  确保 `allocFd` 在裁剪后不会发出越界槽位。`task.zig` 的 fd 清理循环
  本就以 `vfs.MAX_FDS` 为界，无需改动。
- **效果**：非 x86 `Task` 14384→**4528B**（累计 62KB→4.5KB，−93%）。
- **探针**：comptime `@sizeOf(Task) <= 8KB` 断言 + allocFd/freeFd 位图
  往返 + `task_bytes=` 打印；`[SK-39] slim fd table: OK`。
- **后续**：SK-40 — 继续可移植片段（如 sched/task 剩余 boot 片段或
  copy_from_user 边界防护移植准备）。

### 3.37 SK-40 完成记录（2026-07-19）

- **动机**：`mm/copy_from_user.zig` 内联读 CR3 并直接走 x86 页表
  （`paging.getPageEntry`），是共享内核里最后的硬编码 x86 依赖之一；
  非 x86 一旦引用任何 fd/env 系统调用路径就无法编译。
- **方案**：arch facade 增加三组接口并接入 `copy_from_user`：
  `paging.currentRoot`（x86 CR3 / riscv satp→phys / aarch64 TTBR0_EL1）、
  `paging.isUserAccessible`（x86 走 PTE.user；riscv Sv39 walk 查 V+U 位；
  aarch64 walk 查 AP[1]，块/页均覆盖）、`userAccessBegin/End`
  （riscv 置/清 `sstatus.SUM`，S-mode 才能读写 U 页；x86/aarch64 no-op，
  SMAP/PAN 未启用）。拷贝逻辑与 x86 行为零变化。
- **探针**：映射真实用户页后 `copyFromUser`/`copyToUser` 往返，
  并验证未映射用户地址与内核区指针均被拒绝返回 0；
  `[SK-40] portable copy_from_user: OK`。
- **后续**：SK-41 — 继续可移植片段（sched/task 剩余 boot 片段，
  或将用户 IRQ 探针之外的 M6 user.enter 复用共享 copy 防护）。

### 3.38 SK-41 完成记录（2026-07-19）

- **动机**：riscv64 M6 / aarch64 M9-6 的 `sys_write` 手写边界检查后经物理
  地址别名读用户页，绕过了 SK-40 刚移植的共享防护——语义与 x86 syscall
  路径不一致，也无法拒绝"越界但仍在用户页内"的坏指针形态。
- **方案**：两个 arch 的 `handleWrite` 改为 `copy.copyFromUser` 进内核栈
  缓冲再输出（范围检查 + 用户位页表 walk + riscv SUM 括号），删除
  phys 别名路径；长度上限 256 保持不变。
- **探针**：首次成功走共享防护时打印
  `[SK-41] user write via shared copy: OK`（在 `hello from U` 之后），
  两个非 x86 冒烟脚本断言该标记。
- **随行修复（x86 正确性）**：同提交包含 ext2 open-file 跨进程引用计数——
  `Ext2File.ref_count` + `retainFile`；fork/clone 复制 fd 表时对每个不同的
  ext2 open-file index retain 一次（进程内 dup 仍由 `hasSharedRef` 兜底），
  `closeFile` 归零才释放槽位。修复父进程 close 后子进程 fd 悬垂
  （use-after-close）的 v53.44 遗留问题之一。门禁另加 `smoke-smp` 验证。
- **随行修复补全（v53.44 收尾）**：tcp/epoll/unix_socket/timerfd 四类共享
  资源同样补上 `ref_count` + retain/teardown-at-zero（`tcpRetain`、
  `epollRetain`、`unixRetain`、`timerfdRetain`）；fork/clone 统一走
  `vfs.retainSharedResources`（对每进程每类每个不同 index retain 一次，
  与 `hasSharedRef` 的"每进程只 teardown 一次"语义配对）。TCP 语义与
  Linux 对齐：仅最后一个引用 close 才发 FIN/RST。v53.44 TODO 至此关闭。

### 已知问题（P1）：SMP=2 压力冒烟间歇性失败（2026-07-19 记录）

- **现象**：`zig build smoke-smp-stress` 多轮连跑约每 2–4 轮出一次失败；
  单轮 `smoke-smp` 与三门禁稳定全绿。
- **证据**：基线 `f89e971`（refcount 修复之前）同样复现（6 轮第 2 轮
  在 hello27 `connect=0` 后挂死超时），**非** `cf0372a` 引入。
- **失败形态**（多样，指向 SMP 时序竞争而非单点 bug）：
  1. hello27（TCP connect/sendto）后挂死；
  2. hello27 sendto 中内核 #PF：`RIP == CR2 = 0xffffffff80ae1f90`
     （野跳转到不可执行地址，疑似栈/函数指针被并发覆写）；
  3. hello4 退出后 `RSP=0x...900dffd8`（内核栈顶附近）#GP —— 疑似
     task 槽复用/退出路径与 AP 调度竞争。
- **下一步**：专轮排查——先在 tcp timerTick（AP 上跑）与 sendto/close
  的并发面找共享可变状态；再查 task exit 后 kstack 复用窗口。
- **2026-07-19 追加证据与加固**：
  1. 已落地加固：reap（`reapZombies`/`waitpid`）现在跳过仍是某 CPU
     `current_task_idx` 的僵尸（`isCurrentOnAnyCpu`），waitpid 以释放锁的
     pause 循环等待宿主 CPU 切走——消除"exit 后整整一个 tick 内 kstack
     被复用"的窗口。
  2. 但同形态崩溃仍复现：`iretq` #GP(0)，帧位于 `TSS.RSP0`（kstack top
     − 0x28）即 **from-user** IRQ 帧，而 cur task（idx 3）此时已打印
     `[exit]` 走完 exit 系统调用——一个 CPU 在内核 exit 路径上，另一个
     CPU 仍以用户态运行同一任务并在其 kstack 顶收 IRQ 帧；exit 系统调用
     入口（`kernel_rsp = kstack_top`）会覆写同一栈顶区域 → 帧损毁 →
     iretq #GP。指向**同一任务同时是两个 CPU 的 current**（疑似
     work-stealing / 唤醒路径 double-enqueue），而非单纯 reap 时序。
  3. 专轮方向：审计 enqueue/steal/kick 全部路径，确保任务不可能同时
     位于两个 per-CPU 队列或"队列 + current"双重身份；考虑给 Task 加
     `on_cpu: i8` 断言字段在 debug 构建里捕获双跑。
- **✅ 已修复（2026-07-19 专轮）——root cause: 唤醒即入队 + 拾取无双跑检查**：
  1. 根因：`unblockTask`/`wakeOne`/`wakeAll` 在任务转 `.ready` 的**瞬间**
     就 `enqueueTask` 入 per-CPU 队列，而此刻任务可能仍是宿主 CPU 的
     `current_task_idx`（blocked 任务要等宿主 CPU 下一次 tick 才切走，
     期间 cur_idx 不变）。另一 CPU 经队列 pop / steal / 位图扫描把它拾起
     并置 `.running` → **同一任务、同一 kstack 同时活在两个 CPU 上**，
     与追加证据 2 的 iretq #GP 形态完全吻合。
  2. 修法（拾取侧统一设卡，唤醒侧语义不动）：
     - `task.isCurrentOnOtherCpu(idx, my_cpu)`：扫 `percpu_array`，
       判断任务是否仍是**其他** CPU 的 current；
     - 位图路径 `considerReady` 跳过此类任务；
     - 队列路径新增 `sched.popRunnable`：pop 循环中丢弃非 `.ready` 的
       陈旧表项与仍双跑的任务（不回插——任务仍 `.ready`，宿主切走后
       位图回退路径自然重拾），steal 后的本地 pop 也走同一函数。
  3. 验证：三门禁 + `smoke-smp` + `smoke-smp-stress` 连续 6 轮
     （= 30 次 SMP=2 全测试启动）零失败；修复前约每 2–4 轮必现一次。
     形态 1/2（hello27 挂死 / 野跳 #PF）与形态 3 同根：双跑任务互相
     覆写 kstack 上的返回地址与 IRQ 帧。P1 降级关闭。
- **后续**：SK-42 — 继续可移植片段（sched/task 剩余 boot 片段收敛）。

### 3.39 SK-42 完成记录（2026-07-19）

- **动机**：main.zig 仍保留两处本地 x86 boot 片段——私有 `idleThread`
  （裸 `hlt`，且不与共享 `sched.kernelIdleLoop` 同体）和 `_start` 尾部的
  内联 `sti`+`hlt` 循环；与非 x86 引导路径不共享。
- **方案**：`sched_boot` 收敛两个片段：
  1. `createIdleThread()` 去掉 entry 参数，固定使用共享
     `sched.kernelIdleLoop`（enableIrq + waitForInterrupt，SK-12 起即为
     可移植 idle 体，AP idle 也早已用它）；探针阶梯里自带 idle stub 的
     旧里程碑（sk19/20/22/23/24）改走 `createIdleThreadWith(entry)`。
  2. 新增 `bootIdleLoop()`：可移植的 `_start` 尾部（enableIrq + wfi 循环），
     main.zig 删除内联 `sti`/`hlt` 与私有 `idleThread`。
- **探针**：非 x86 上按 main.zig 完全相同的片段序列
  `initBspRunQueue()` → `createIdleThread()`，校验 BSP 队列已 prime、
  优先级 255、`prepareTaskFrame` 后 frame.rip == `kernelIdleLoop`；
  `[SK-42] shared idle boot fragment: OK`（x86 仅打印标记，main.zig
  路径本身即验证）。
- **验证**：三门禁 + `smoke-smp` + `smoke-smp-stress` 1 轮全绿。
- **后续**：SK-43 — 继续可移植片段（ramdisk/loader 或 vfs 写回回调等
  main.zig 剩余可共享块），或 Phase G 按需 syscall。

### 3.40 SK-43 完成记录（2026-07-19）

- **动机**：`fs/ramdisk.zig`（MRD 扁平归档解析，main.zig M5.3 片段的
  可移植主体）本身已 arch-clean——serial 走 arch facade、无 Limine 类型
  ——但从未在非 x86 上编译/运行过。
- **方案**：`subsystem_boot.initRamdisk(base, size)` 作为收敛入口
  （与 initSlab/initTmpfs 等片段目录一致），main.zig 与探针调用同一
  函数；main.zig 只保留 Limine module 迭代这一 bootloader 专属部分，
  顶部 `ramdisk` 直连 import 移除。新增 `sk43` 探针在非 x86 上合成最小
  MRD 归档（header + 2 entries + data；blob 用静态存储——`ramdisk` 全局
  state 在 init 后持有其指针，不能放探针栈帧），走与 main.zig 相同的
  `initRamdisk` → `findFile` → `getFileCount` / `getFileName` 序列，
  校验两个文件的 size/内容、缺失名返回 null。
- **探针**：`[SK-43] shared ramdisk parse: OK`（x86 仅打印标记，
  main.zig 每次启动即真实验证）。两个非 x86 冒烟脚本断言该标记。
- **验证**：三门禁 + `smoke-smp` + `smoke-smp-stress` 1 轮全绿。
- **后续**：SK-44 — 继续可移植片段（loader ELF 头解析或 vfs 写回回调
  等 main.zig 剩余可共享块），或 Phase G 按需 syscall。

### 3.41 SK-44 完成记录（2026-07-19）

- **动机**：`proc/loader.zig` 的 ELF64 解析核心（magic/class/endian/
  machine/type 校验 + 有界、对齐安全的 phdr 读取）在三处内联重复
  （`loadProgram` / `loadElf` / `loadProgramForExec`），且 e_machine
  写死 EM_X86_64，非 x86 无法复用。
- **方案**：抽出共享 `proc/elf.zig`：`hasMagic` / `parseHeader`
  （拷贝到对齐缓冲 + 全部校验，返回值语义）/ `readPhdr`（越界返回
  null；短 phentsize 零扩展，与 loader 历史行为一致）；`EM_CURRENT`
  按 comptime arch 选 EM_X86_64 / EM_RISCV / EM_AARCH64。loader 三处
  内联全部替换（净 -87 行），页映射等 x86 专属部分不动。语义收紧一处：
  带 ELF magic 但校验失败的文件现在直接报错，不再落入 flat-binary
  回退。
- **探针**：`sk44` 在非 x86 上合成最小 ELF64 镜像（Ehdr + PT_LOAD +
  PT_PHDR），走 `parseHeader` → `readPhdr` 序列校验字段，并验证
  wrong-machine / 截断 header / 越界 phdr index 均被拒绝；
  `[SK-44] shared elf header parse: OK`（x86 仅打印标记，init 加载
  路径即真实验证）。两个非 x86 冒烟脚本断言该标记。
- **验证**：三门禁 + `smoke-smp` + `smoke-smp-stress` 1 轮全绿。
- **后续**：SK-45 — 继续可移植片段（vfs 写回回调注册、buildUserStack
  的 auxv 部分等），或 Phase G 按需 syscall。

### 3.42 SK-45 完成记录（2026-07-19）

- **动机**：`loader.zig` 的 `buildUserStack`（Linux ABI 进程入口栈：
  argc/argv/envp/auxv + 16 字节对齐）布局在 x86_64/riscv64/aarch64 的
  Linux ABI 中完全一致，但实现内联在 x86 专属的 loader 里。
- **方案**：抽出 arch-clean 的 `proc/user_stack.zig`（经 `hhdm.physToVirt`
  写物理页——非 x86 上 HHDM 偏移为 0 即恒等映射；AT_* 常量与 `StackInfo`
  一并迁移），loader 以 `pub const buildUserStack = user_stack.buildUserStack`
  再导出，行为零改动。
- **探针**：`sk45` 在非 x86 上取一页真实内存，令 stack_top == 页尾使
  用户 VA 可直接解引用，构建假进程入口栈后回读校验：argc/argv 字符串、
  argv/envp 终止符（含对齐 pad 兼容）、auxv 的 AT_ENTRY/AT_PHNUM/
  AT_PAGESZ 值、SP 16 字节对齐与页内边界；
  `[SK-45] shared user stack build: OK`。
- **随行修复**：`task.waitpid` 的自旋提示从内联 x86 `pause` 改为
  `arch.cpu.pause()`（riscv64 baseline 无 Zihintpause，直接编译失败；
  此前该函数未被非 x86 引用故未暴露）。

### 3.43 SK-46 完成记录（2026-07-19）

- **动机**：main.zig v53.33 片段 `vfs.initWritebackCallbacks()`（ext2/
  fat32 驱逐时写回回调注册）为最后几个未收敛的可移植 boot 片段之一；
  共享写回缓冲缓存（`fs/writeback.zig`）此前从未在非 x86 编译/运行。
- **方案**：`subsystem_boot.initWritebackCallbacks()` 收敛入口，
  main.zig 改调。注意该入口只在 x86 被调用：注册 vfs 回调会把
  `ext2.writeFile`/`fat32.writeFile` 及其下游 x86 块驱动（含大量内联
  `pause` 汇编）拉进非 x86 编译，riscv64 baseline 直接编译失败——
  所以非 x86 探针不走 vfs 注册，改用探针本地回调。
- **探针**：`sk46` 直接练共享写回缓存：`writeBuffered`/`readBuffered`
  脏缓冲往返、fs_type/offset 键控命中与未命中、脏计数非零；再以
  probe-local 回调走 `flushFile`（与 `vfs.syncFile` 同一 comptime
  回调路径）校验回调收到正确的 file_idx/offset/内容且脏计数清零；
  `[SK-46] shared writeback cache: OK`。
- **验证**：三门禁 + `smoke-smp` + `smoke-smp-stress` 1 轮全绿。
- **后续**：见 3.44 收敛复盘。

### 3.44 可移植 boot 片段收敛复盘（2026-07-19 review）

- **结论**：`main.zig` 中**架构无关**的 boot 片段已基本收敛完毕
  （SK-1…SK-46）。idle 线程/boot 尾部、ramdisk 解析、ELF 头/phdr 解析、
  用户入口栈构建、写回缓存等均已抽为共享模块并在非 x86 探针中验证。
- **剩余 `main.zig` 初始化均为硬件/x86/Limine 专属，非探针可收敛**：
  - ACPI（`rsdp_request` + MADT 解析）、PCI 枚举（端口 `0xCF8/0xCFC`
    或 MCFG）、AHCI/virtio-blk/NVMe 块驱动、e1000/virtio-net、
    `block_dev` 设备注册、fat32/ext2 挂载。
  - 网络协议表（`arp.init`/`ndp.init`/`tcp.initTcbs`）**本身**可移植，
    但 `net/*.zig` 在文件级 import `drivers/e1000.zig` → `drivers/pci.zig`
    → `acpi/acpi_parser.zig`，整条链 x86 耦合；非 x86 引入即触发端口 I/O
    / ACPI 依赖。要在非 x86 复用需先做 **NIC/PCI 驱动抽象层**（把协议表
    初始化与 e1000 收发路径解耦），属 Phase 级重构而非单步探针。
- **最高价值健壮性缺口**：`mm/copy_from_user.zig` 仍无逐指令缺页恢复
  （见文件头 TODO）——坏但在范围内的用户指针目前靠预先 page-walk 校验
  拦截，缺少异常表/fixup 兜底。三架构统一实现需链接段 + 各自 trap
  handler 集成，是独立里程碑。
- **下一执行项建议**：Phase G（按需 syscall：futex/select/clone…按应用
  需求接入），或启动上述 NIC/PCI 抽象层 / copy_from_user fixup 两个
  中型专项之一。

### 3.45 NIC 发送 facade（2026-07-19，NIC 抽象层第一步）

- **背景**：3.44 复盘点名网络栈的 x86 驱动耦合是非 x86 复用协议表的
  前置障碍。第一个具体缺口是**发送路径**：`arp`/`ipv4`/`icmp`/`icmpv6`/
  `tcp`/`udp`/`netif` 七处全部直接 `@import("drivers/e1000.zig")` 发帧，
  即使机器只有 virtio-net（x86 上 `virtio_net.init()` 已跑）也永远发不
  出——协议栈只认 e1000。
- **方案**：新增 `net/nic.zig` 发送 facade（`sendPacket`/`getMAC`/
  `isActive`），按 `isActive()` 分发到当前活动 NIC，e1000 优先、
  virtio-net 兜底。六个协议文件的 TX 调用改走 facade（`arp`/`tcp`/`udp`/
  `netif`/`icmp`/`icmpv6`）。RX 仍按驱动区分（e1000 由 raw_net/
  socket_syscall `receivePacket` 轮询；virtio-net 自身路径直推
  `net.handleRxPacket`），本步不动。
- **效果**：x86 多 NIC 发送（仅 virtio-net 的机器现在也能发帧）；协议栈
  发送路径不再硬绑单一驱动，为后续把协议表初始化与 e1000 收发彻底解耦、
  在非 x86 复用共享网络栈铺路。仅 e1000 在场时（冒烟配置）行为完全不变。
- **验证**：三门禁 + `smoke-smp` + `smoke-smp-stress`（hello27 TCP 经
  facade 收发）全绿。
- **后续**：见 3.46（RX facade，已完成）。

---

### 3.46 NIC 接收 facade（2026-07-19，NIC 抽象层第二步）

- **背景**：3.45 收敛了发送路径，但接收侧仍有两处直连 `drivers/e1000.zig`
  ——`raw_net.zig`（`netSend`/`netRecv`/`udpSend`/`netPoll`）与
  `socket_syscall.zig` 的 `netPoll`，直接调 `e1000.isActive/receivePacket`。
  只要协议栈里还有任何文件级 `@import("drivers/e1000.zig")`，非 x86 就无法
  链接共享网络栈。
- **方案**：`net/nic.zig` 增加 `receivePacket(buf, max_len)` facade，活动
  NIC 为 e1000 时轮询其 RX 环，virtio-net 返回 0（它走自身路径直推
  `net.handleRxPacket`，无可轮询队列）。`raw_net.zig` 与
  `socket_syscall.zig` 的收发/轮询/`isActive` 全部改走 `nic`。
- **效果**：`net/*` 目录内**仅剩 `nic.zig` 一处**直连驱动
  （`e1000` + `virtio_net`），协议栈其余文件对具体 NIC 驱动零 import。RX
  语义不变：e1000 轮询、virtio-net 推送两条投递路径保持原样。
- **验证**：三门禁 + `smoke-smp` + `smoke-smp-stress` 全绿（hello27 TCP
  经 facade 收发）。
- **后续**：见 3.47（协议表首块搬上非 x86，已完成）。

---

### 3.47 共享 IPv4 头/校验和搬上非 x86（SK-47，2026-07-19）

- **背景**：3.45/3.46 把 `net/*` 对具体 NIC 驱动的直连收敛到 `nic.zig` 一处
  后，协议表里**纯逻辑**部分理论上已可移植，但从未在非 x86 编译过——整个
  `net/*` 只在 x86 被 `net/mod.zig` 初始化路径拉起，非 x86 从不触及，无从
  验证「协议逻辑真的架构无关」。
- **观察**：`net/ipv4.zig` 仅依赖 `lib/byte_order.zig`，两者皆 std-free、
  无任何 arch/驱动依赖，`buildHeader`/`parseHeader`/`checksum`（RFC 1071）
  是纯字节运算，天然可移植。
- **方案**：新增 `shared/sk47.zig` 探针，把 `net/ipv4.zig` 编入非 x86 镜像
  并实跑：(1) `buildHeader` 产出的头对自身 20 字节做校验和须为 0(RFC 1071
  自校验)；(2) `parseHeader` 回读 src/dst/protocol/长度一致；(3) 翻转一位
  后校验和必须非 0(能抓损坏)。这是**协议表第一块真正编译并运行在
  riscv64/aarch64 上**,同时作为回归护栏,防止日后往 ipv4.zig 里塞进 x86
  依赖。
- **验证**：三门禁 + `smoke-smp` + `smoke-smp-stress` 全绿,riscv64/aarch64
  串口打印 `[SK-47] shared ipv4 header/checksum: OK`。
- **后续**：见 3.48（ipv6 头/伪头,已完成）。

---

### 3.48 共享 IPv6 头/伪头校验和/地址判定搬上非 x86（SK-48,2026-07-19）

- **背景**：SK-47 之后继续按依赖洁净度推进。`net/ipv6.zig` 同样只依赖
  `lib/byte_order.zig`(std-free、arch-clean),含固定 40 字节头构建/解析、
  RFC 8200 §8.1 伪头部分校验和,以及一批地址判定(link-local/multicast/
  unspecified/solicited-node),纯字节运算,天然可移植。
- **方案**：新增 `shared/sk48.zig` 把 `ipv6.zig` 编入非 x86 镜像并实跑。核
  心验证 `pseudoHeaderChecksum` 的**契约**——它返回*未折叠*的 32 位累加器,
  供上层(TCP/UDP/ICMPv6)继续累加自身字节后再统一折叠取反。探针照该用法
  复现:以伪头播种累加器 → 累加 payload → 折叠取反得校验和写回 → 再整体
  重算,须折叠为 0(RFC 1071 自校验)。另验 header 往返、link-local/组播/
  unspecified 判定、solicited-node 组播地址构造与匹配。
- **效果**：协议表第二块纯逻辑在 riscv64/aarch64 实编实跑,伪头校验和契约
  得到端到端验证;与 SK-47 一道覆盖了 tcp/udp/icmpv6 校验和所依赖的两个底
  层原语(`ipv4.checksum` + `ipv6.pseudoHeaderChecksum`)。
- **验证**：三门禁 + `smoke-smp` + `smoke-smp-stress` 全绿,riscv64/aarch64
  打印 `[SK-48] shared ipv6 header/pseudo-csum: OK`。
- **后续**：见 3.49（eth 帧构造 + L2/L3 组合,已完成）。

---

### 3.49 共享 Ethernet 帧构造 + L2/L3 组合验证搬上非 x86（SK-49,2026-07-19）

- **背景**：SK-47/48 分别单测了 L3 原语(ipv4/ipv6 头 + 校验和)。`net/eth.zig`
  是最后一个 L2 帧构造原语,同样只依赖 `lib/byte_order.zig`,arch-clean。
- **方案**：新增 `shared/sk49.zig`,不仅把 `eth.zig` 编入非 x86,更做**首个
  组合(composition)测试**——按真实 TX 路径把原语叠起来:`eth.buildFrame`
  造 14 字节以太头,`ipv4.buildHeader` 在 offset 14 铺 IPv4 头,然后验证分层
  结果:(1) ethertype 回读为 IPv4;(2) DST/SRC MAC 顺序正确;(3) IPv4 头在
  **非零偏移**处仍自校验和为 0(证明 `buildHeader` 与偏移无关、可在帧内组
  合);(4) `parseHeader` 能透过组合帧读回 L3 字段。
- **效果**：出站帧的 L2 + L3 头构造链路在 riscv64/aarch64 实编实跑,且验证了
  可移植原语之间能正确互操作(不只是各自单测通过)。这三块(eth/ipv4/ipv6)
  合起来覆盖了非有状态 TX 头构造的全部纯逻辑。
- **验证**：三门禁 + `smoke-smp` + `smoke-smp-stress` 全绿,riscv64/aarch64
  打印 `[SK-49] shared eth framing + L2/L3 compose: OK`。
- **后续**：见 3.50（nic facade 架构条件化,已完成）。

---

### 3.50 nic facade 驱动 import 架构条件化（SK-50,2026-07-20）

- **背景**：SK-47/48/49 把 arch-clean 的协议*逻辑*(eth/ipv4/ipv6)搬上了非
  x86,但更外层的 `net/*`(arp/udp/tcp/netif 等经 `nic` 转发)仍无法在非 x86
  链接,卡点正是 `nic.zig`:它**无条件** import `drivers/e1000.zig` +
  `drivers/virtio_net.zig`,二者经 `drivers/pci.zig` → ACPI → 端口 I/O,全不
  可移植。
- **方案**：把两个驱动 import 收进 `const drivers = if (arch==x86_64) struct
  {…} else struct {};`,四个 facade 入口(`isActive`/`getMAC`/`sendPacket`/
  `receivePacket`)用 `if (comptime arch==x86_64)` 包住驱动分支——非 x86 走
  comptime 裁剪后的 no-op 路径,零驱动/PCI/ACPI 依赖。新增 `shared/sk50.zig`
  把 `nic.zig` 编入非 x86 镜像并逐个调用 facade,断言:未链接驱动时 NIC 非
  active、MAC 全零、TX 安全拒绝、RX 返回 0(不触发缺失驱动的调用)。
- **效果**：`nic.zig` 现在在非 x86 干净可编且行为安全;`net/*` 里唯一直连驱
  动的文件已完成架构解耦。这是整体在非 x86 链接协议栈(而不止是单块纯逻辑)
  的关键一步——上层 arp/udp/netif 的驱动侧依赖至此被 no-op facade 兜住。
- **验证**：三门禁 + `smoke-smp` + `smoke-smp-stress` 全绿,riscv64/aarch64
  打印 `[SK-50] nic facade non-x86 no-op: OK`;x86 收发路径经 facade 完全不变
  (hello27 TCP、smp-stress 全过)。
- **后续**：见 3.51（netif 上移,已完成）。

---

### 3.51 网络接口配置（netif）搬上非 x86（SK-51,2026-07-20）

- **背景**：SK-50 把驱动 import 关进 `nic.zig` 的 comptime arch gate 后,第一
  个受益的上游消费者就是 `netif.zig`——它现在只 import `nic`(已 arch-clean)
  + `arch.serial`(可移植),不再间接拖 pci/acpi。
- **方案**：新增 `shared/sk51.zig` 把 `netif.zig` 编入非 x86 镜像并实跑:静态
  接口配置(IP/网关/掩码为编译期常量,各架构一致)、以及惰性 MAC 缓存——无
  NIC 时 `getMac()` 经 `nic.getMAC()` 解析为全零,且 `ensureInit()` 多次调用
  幂等。
- **效果**：证明 SK-50 的 nic 架构解耦确实**向上传导**——nic 的消费者(而非仅
  nic 自身)也能在非 x86 链接运行。协议栈"配置层"至此可移植。
- **验证**：三门禁 + `smoke-smp` + `smoke-smp-stress` 全绿,riscv64/aarch64
  打印 `[SK-51] netif config non-x86: OK`。
- **后续**：见 3.52（arp 状态机上移,已完成）。

---

### 3.52 ARP 缓存/请求-应答状态机搬上非 x86（SK-52,2026-07-20）

- **背景**：SK-51 之后的下一环。`arp.zig` 只 import `nic`/`netif`/`eth`/`bo`
  (均已 arch-clean),且其缓存**无 aging、不耦合定时器**,整块(报文解析、缓
  存增改查、请求/应答帧构造)可在非 x86 编译运行。
- **方案**：新增 `shared/sk52.zig`,**首个在非 x86 驱动真实*有状态*协议模块**
  的探针(此前都是纯头部数学)。场景:`init()` 清缓存 → 喂一个目标为本机 IP
  的合成 ARP 请求帧给 `handlePacket()`(缓存 sender 并尝试应答,TX 落到 nic
  非 x86 no-op)→ `resolve()` 命中缓存 MAC、未知 IP 返回 null → 同 IP 换新
  MAC 的第二帧就地更新条目 → 过短帧被忽略不崩 → `sendArpRequest()` 经 no-op
  facade 构帧不崩。
- **效果**:ARP 层(L2/L3 地址解析)在 riscv64/aarch64 实编实跑,解析与缓存逻
  辑全程真实执行,仅发送落到 no-op。证明架构解耦已支撑起带状态的协议模块。
- **验证**:三门禁 + `smoke-smp` + `smoke-smp-stress` 全绿,riscv64/aarch64
  打印 `[SK-52] arp cache/state machine non-x86: OK`。
- **后续**:见 3.53（udp 端口/队列上移,已完成）。

---

### 3.53 UDP 端口绑定表/接收队列/发送路径搬上非 x86（SK-53,2026-07-20）

- **背景**:SK-52 之后的下一环。`udp.zig` 依赖 `nic`/`netif`/`eth`/`ipv4`/
  `arp`/`bo`(均已 arch-clean),状态是静态端口表 + 每端口接收队列,**无定时
  器**,整块可编译运行于非 x86。
- **方案**:新增 `shared/sk53.zig` 驱动**可观测的接收路径**:`ensurePort` 绑
  定且幂等;向已绑定端口投递数据报 → `recvFrom` 读回负载/源 IP/源端口且长度
  正确;队列排空后返回 0;未绑定端口的数据报被丢弃(接收不自动建表);队列
  深度溢出(压 `QUEUE_DEPTH+1` 只保留 `QUEUE_DEPTH`)。`sendTo` 跑两条分
  支——未解析 ARP → 返回 false 并发 ARP 请求(no-op);预置 ARP 缓存后 → 跑完
  整 eth+ipv4+udp 整帧构造经 nic no-op,不崩(TX 在非 x86 尚不可观测,故仅验
  无故障)。
- **效果**:UDP 传输层(端口多路复用 + 收队列 + 发送封装)在 riscv64/aarch64
  实编实跑,接收侧逻辑全程真实验证。至此 L2(eth/arp)+ L3(ipv4/ipv6)+ L4
  无连接(udp)的非定时器逻辑均已可移植。
- **验证**:三门禁 + `smoke-smp` + `smoke-smp-stress` 全绿,riscv64/aarch64
  打印 `[SK-53] udp ports/queues non-x86: OK`。
- **后续**:见 3.54（tcp 纯逻辑抽出,已完成）。

---

### 3.54 TCP 纯逻辑抽出 `tcp_util.zig` 并搬上非 x86（SK-54,2026-07-20）

- **背景**:`tcp.zig` 是耦合 idt/调度/锁的大型状态机,整体暂不能编入非 x86;
  但其中环形缓冲数学、RFC 793 模序号比较、IPv4 伪头 TCP 校验和是**纯逻辑**,
  不需要任何状态/定时器。
- **方案**:抽出 `net/tcp_util.zig`(仅依赖 `bo`+`ipv4`,arch-clean):
  `ringDataLen`/`ringAvailable`、`seqLt`/`seqGt`/`seqLeq`/`seqInWindow`、
  `checksum`。`tcp.zig` 保留薄委托(13 处调用点不动),并把 `isSacked` 的
  "序号在窗口内"判断改用 `tcp_util.seqInWindow`。新增 `shared/sk54.zig` 在非
  x86 实跑:环形占用(含 tail 落后 head 的回绕)、序号比较(跨 32 位回绕边
  界)、TCP 校验和自校验(填入 checksum 字段后整体重算须为 0)。
- **效果**:TCP 的可移植纯逻辑(校验和 + 序号 + 环形数学)在 riscv64/aarch64
  实编实跑并独立验证;剩余状态机部分被隔离,后续引入网络定时器 facade 时可继
  续拆。x86 TCP 经委托后行为不变(hello27 + smp-stress 全过)。
- **验证**:三门禁 + `smoke-smp` + `smoke-smp-stress` 全绿,riscv64/aarch64
  打印 `[SK-54] tcp_util helpers non-x86: OK`。
- **后续**:见 3.55（icmp echo 回复构造上移,已完成）。

---

### 3.55 ICMP echo 回复帧构造抽出并搬上非 x86（SK-55,2026-07-20）

- **背景**:`icmp.zig` 依赖 `nic`/`netif`/`eth`/`ipv4`/`arp`/`bo`(全 arch-clean)
  且无定时器,可编入非 x86;但其回复逻辑埋在 `handlePacket` 里(写本地缓冲后
  接 arp/nic 副作用),不可观测、难验证。
- **方案**:按既有模式把**回复帧构造**抽成纯函数 `icmp.buildEchoReply`
  (无 arp/nic 副作用),`handlePacket` 委托它。新增 `shared/sk55.zig` 端到端
  验证构造出的帧:帧长、ethertype、MAC 互换(dst=请求方/src=本机)、offset 14
  的 IPv4 头自校验为 0 且协议=ICMP、地址=本机→对端、offset 34 的 ICMP 类型翻
  为 0(reply)、ICMP 校验和有效(整体折叠为 0)、id/seq/payload 原样回显。
- **效果**:一个完整的 L4 协议处理器(ICMP echo/ping 回复)在 riscv64/aarch64
  实编实跑并被完整验证——覆盖 eth+ipv4+icmp 三层构造 + 双校验和。x86 ping 行
  为不变(经委托)。
- **验证**:三门禁 + `smoke-smp` + `smoke-smp-stress` 全绿,riscv64/aarch64
  打印 `[SK-55] icmp echo reply builder non-x86: OK`。
- **后续**:见 3.56（ndp 邻居缓存上移,已完成)。

---

### 3.56 IPv6 邻居发现缓存 + EUI-64 搬上非 x86（SK-56,2026-07-20）

- **背景**:icmpv6 依赖 `ndp`。查明 `ndp.zig` 只依赖 `ipv6`(arch-clean)+
  `IrqSpinlock`,而后者是 **arch-neutral** 的(用 `arch.irq`/`arch.cpu.pause`
  facade,SK-4 已中立化),且无定时器——整块邻居缓存可编译运行于非 x86。
- **方案**:新增 `shared/sk56.zig`(IPv6 版的 SK-52 ARP 探针)在非 x86 实跑:
  空缓存未命中 → `update`→`lookup` 命中 → 地址键控(异 IP 未命中)→
  `markIncomplete` 占位态**不被 lookup 返回** → 再 `update` 解析为 reachable →
  modified EUI-64 链路本地地址生成(fe80:: 前缀、插入 0xFFFE、翻 U/L 位)。
- **效果**:IPv6 邻居发现的缓存层(带 IrqSpinlock 临界区)在 riscv64/aarch64
  实编实跑并验证,顺带确认 `IrqSpinlock` 在非 x86 可用——为后续更多带锁网络
  模块上移扫清顾虑。
- **验证**:三门禁 + `smoke-smp` + `smoke-smp-stress` 全绿,riscv64/aarch64
  打印 `[SK-56] ndp neighbor cache/eui64 non-x86: OK`。
- **后续**:见 3.57（icmpv6 校验和/NA 构造上移,已完成)。

---

### 3.57 ICMPv6 校验和 + 邻居通告构造搬上非 x86（SK-57,2026-07-20）

- **背景**:SK-56 让 `ndp` 就绪后,`icmpv6.zig` 依赖(nic/netif/eth/ipv6/ndp/
  bo)全部 arch-clean 且无定时器,可编入非 x86;但其 NA 回复埋在
  `sendNeighborAdvertisement`(ndp.lookup + netif + nic 副作用),校验和为私有。
- **方案**:按 SK-55 模式把 `checksum` 设为 `pub`、抽出纯的
  `buildNeighborAdvertisement`(MAC 由调用方传入,无 ndp/netif/nic 副作用),
  `sendNeighborAdvertisement` 委托它。新增 `shared/sk57.zig` 在非 x86 验证:
  (1) ICMPv6 伪头校验和自校验(填入 csum 后整体重算为 0);(2) 完整 NA 帧——
  ethertype、MAC 互换、IPv6 头(next=ICMPv6、src=target、dst=requester)、NA
  类型/标志(S|O=0x60)、目标地址、Target-LL 选项=本机 MAC、以及 NA 消息的
  ICMPv6 校验和有效。
- **效果**:一个完整的 IPv6 邻居发现应答构造器(含伪头校验和)在 riscv64/
  aarch64 实编实跑并被完整验证。至此 ICMPv4/ICMPv6 两个 echo/NDP 处理器的可移
  植构造路径均已覆盖。x86 NDP 经委托后不变。
- **验证**:三门禁 + `smoke-smp` + `smoke-smp-stress` 全绿,riscv64/aarch64
  打印 `[SK-57] icmpv6 checksum/NA builder non-x86: OK`。
- **后续**:见 3.58（tcp 时间源去 x86 化,已完成)。

---

### 3.58 TCP 时间源改走 arch facade（去掉最后的 rdtsc,SK-58,2026-07-20）

- **背景**:排查 `tcp.zig` 距离编入非 x86 还差什么,发现两处时间相关的 x86 耦
  合:`generateIss()` 用裸 `asm ("rdtsc")` 生成初始序号(ISS),`nowMs()` 读
  tick 计数。前者是硬 x86 汇编,后者的 `idt.getTickCount()` 其实三架构都已实现。
- **方案**:`generateIss()` 改用 `arch.tsc.read()`(x86 `rdtsc` / riscv
  `rdtime` / aarch64 `cntvct_el0`,facade 早已三架构齐备),去掉 tcp 里最后一
  处裸 x86 汇编。新增 `shared/sk58.zig` 在非 x86 验证 tcp 新依赖的两个时间源确
  实可用:`arch.tsc.read()` 跨忙等单调不减、`getTickCount()` 可调用不崩,并按
  `generateIss` 的方式折叠取 ISS 不崩。
- **效果**:TCP 的时间路径完全去 x86 化。`tcp.zig` 现存的非可移植阻塞收敛为
  `socket_opt`(→sched/task/copy_from_user)这一条依赖链,为后续拆分/条件化
  该链后整体编译 tcp 铺平了时间源这一块。x86 TCP 行为不变(ISS 仍由 TSC 低位
  生成,hello27+smp-stress 全过)。
- **验证**:三门禁 + `smoke-smp` + `smoke-smp-stress` 全绿,riscv64/aarch64
  打印 `[SK-58] portable tcp time sources non-x86: OK`。
- **后续**:见 3.59（整机 tcp 引擎在非 x86 链接,已完成)。

---

### 3.59 整个 TCP 引擎在非 x86 链接（SK-59,2026-07-20）

- **背景**:SK-58 曾把 `tcp.zig` 的剩余阻塞记为 `socket_opt`(→sched/task/
  copy_from_user)这条依赖链。复查发现 `socket_opt.zig` 里 sched/task/
  copy_from_user 全是**函数体内的惰性 `@import`**(在 `resolveTcpIdx` /
  `sysSetSockopt` / `sysGetSockopt` 内),而 `tcp.zig` 只引用了
  `socket_opt.SocketOptions` 这个纯结构体(顶层只 import `byte_order`)。
  Zig 只分析被引用到的 decl,因此 tcp 引用 `SocketOptions` **不会**拖入
  sched/copy_from_user——那条依赖链只有 x86 侧的 socket_syscall 走 setsockopt/
  getsockopt 时才被实例化。也就是说,SK-58 去掉 rdtsc 后,tcp 引擎理论上已可在
  非 x86 编译,阻塞判断本身过时了。
- **方案**:用经验法直接证伪/证实。新增 `shared/sk59.zig`,在非 x86 用
  `comptime { _ = &tcp.<fn>; }` 强制分析 `tcp.zig` 的**全部 28 个 pub 入口**
  (handlePacket/tcpConnect/tcpSend/tcpRecv/timerTick/tcpListen/tcpAccept/
  tcpShutdown/...),等价于把整台 TCP 状态机、重传、拥塞控制、SACK、选项路径
  都编进 riscv64/aarch64;再在一张全新(全 inactive)的 TCB 表上实跑若干安全只读
  路径:越界 `getTcbIdx` 返回 null、新 TCB `recvAvailable/sendSpace=0` 且
  `isClosed`、越界 `tcpIsClosing` 视为关闭、`tcpGetAddrInfo` 对 inactive 返回
  null、一个 4 字节 runt 包喂给 `handlePacket` 被安全忽略、`timerTick` 空表不崩。
- **效果**:**整个 TCP 引擎(约 1800 行)在 riscv64/aarch64 干净全量编译并链接
  通过**,非 x86 网络栈从 L2(eth)/L3(ipv4/ipv6/arp/ndp)/L4-无连接(udp/icmp/
  icmpv6)一路打通到 **L4-有连接(tcp)** 的可编译面。x86 TCP 行为零改动(仅新增
  一个 x86 侧直接打印 OK 的探针分支)。剩下真正与 x86/内核耦合的只有 syscall
  胶水层(socket_syscall/socket_opt 的 copy_from_user + sched 解析 fd),属
  Phase G「按需 syscall」范畴,而非协议逻辑本身。
- **验证**:三门禁 + `smoke-smp` + `smoke-smp-stress` 全绿,riscv64/aarch64
  打印 `[SK-59] tcp engine links non-x86: OK`。
- **后续**:见 3.60（DNS/DHCP 上非 x86,已完成)。

---

### 3.60 DNS 解析器 + DHCP 客户端搬上非 x86（含潜藏 bug 修复,SK-60,2026-07-20）

- **背景**:清点 `net/` 剩余未上非 x86 的模块,`dns.zig`/`dhcp.zig` 依赖全是
  已可移植的 udp/netif/byte_order + serial/getTickCount facade,唯一 x86 耦
  合是忙等提示用的裸 `asm volatile ("pause")`(dns 一处、dhcp 两处)。
- **方案**:三处 `pause` 改走 `arch.cpu.pause()`(x86 `pause` / riscv/aarch64
  各自 hint,facade 早已齐备)。新增 `shared/sk60.zig`,用 `comptime _ = &fn`
  强制分析两模块**全部 pub 入口**(DHCP DISCOVER/REQUEST 构造 + OFFER/ACK
  选项解析、DNS 查询编码 + 响应解析 + LRU/TTL 缓存),并实跑非阻塞路径:点分
  十进制字面量走纯 `isIpV4/parseIpV4`(无网络)、空名被拒为全零、DHCP 未配置时
  DNS 回退 8.8.8.8、DHCP 默认全零 IP + /24 掩码。走网络轮询的 `queryDns`/
  `discover`(会 poll getTickCount)只编译验证不实跑,避免 boot 探针里死等。
- **潜藏 bug**:强制分析立刻暴露 `dns.zig` 的 `addToCache` 里
  `cache[s].ttl = expiry`——`expiry` 是 u64(getTickCount 域),而 `ttl` 字段
  声明为 u32,类型不匹配。此前 x86 从未有人引用 `dns.resolve`,整个 `dns.zig`
  是死代码从未被类型检查,故该 bug 一直潜伏。将 `ttl` 字段改为 u64 修正(tick
  计数本就是 u64 域,`lookupCache` 里的 `now > ttl` 比较也随之正确)。
- **效果**:DNS/DHCP 两个应用层网络客户端在 riscv64/aarch64 实编实链,并顺带
  修掉一个从未编译过的真实类型 bug。至此 `net/` 里的**协议逻辑 + 应用客户端**
  纯逻辑面已全部搬上非 x86,剩下的只有 socket/tcp 的 syscall 胶水(copy_from_
  user + sched 解析 fd),属 Phase G。x86 行为不变(pause 语义等价)。
- **验证**:三门禁 + `smoke-smp` + `smoke-smp-stress` 全绿,riscv64/aarch64
  打印 `[SK-60] dns/dhcp link non-x86: OK`。
- **后续**:见 3.61（FAT32 纯解析/几何抽出上非 x86,已完成)。

---

### 3.61 FAT32 纯解析/几何抽出 `fat32_util.zig` 并搬上非 x86（SK-61,2026-07-20）

- **背景**:网络栈纯逻辑收官后转向 `fs/`。`fat32.zig` 把 MBR 分区表解析、BPB
  几何计算、簇→LBA / FAT 表项定位、簇分类等**纯逻辑**与 virtio_blk I/O、全局
  挂载状态、DMA 缓冲混在一起(内联在 `parseMBR`/`tryMountFAT32`/`clusterToLBA`/
  `getFATEntry`),既不可单测也无法上非 x86。
- **方案**:仿 `tcp_util` 抽出 `fs/fat32_util.zig` 纯模块,无 driver/allocator/
  全局依赖:`parsePartition`(MBR 分区项)、`isFat32Type`、`parseBpb`(校验 +
  派生 fat_start/data_start/sector_mask/total_data_clusters 全套几何)、
  `clusterToLba`、`fatEntryLocation`、`fatEntryValue`(28-bit 掩码)、
  `isEndOfChain/isFreeCluster/isBadCluster/isValidDataCluster`。FAT32/MBR 均
  小端,三架构也都小端,故用 `@bitCast([N]u8→uN)` 直读磁盘字段可移植。
  `fat32.zig` 的四处内联逻辑改为 1:1 委托该模块(`Partition` 亦别名过去),
  x86 行为逐字节等价。新增 `shared/sk61.zig` 在非 x86 用内存合成 MBR(一个
  0x0C FAT32 分区 @LBA 2048)+ BPB(spc=8/reserved=32/2 FAT/fat_size=1009/
  total=131072),精确校验:分区字段、空槽返回 null、BPB 几何
  (fat_start=2080、data_start=4098、sector_mask=7、total_data_clusters=16127)、
  非法 BPB 返回 null、`clusterToLba`、跨扇区 `fatEntryLocation`、带高位噪声的
  28-bit `fatEntryValue`、以及 EOC/bad/free/valid 四个谓词。
- **效果**:FAT32 的磁盘解析与几何数学从 I/O 层剥离,成为可单测、可移植的纯
  模块,并在 riscv64/aarch64 实编实跑逐值验证。x86 FAT32 驱动经委托后行为不变
  (smoke 全过)。这是 `fs/` 方向可移植化的第一块基石。
- **验证**:三门禁 + `smoke-smp` + `smoke-smp-stress` 全绿,riscv64/aarch64
  打印 `[SK-61] fat32 parse/geometry non-x86: OK`。
- **后续**:见 3.62（FAT32 8.3/LFN 目录项纯解析,已完成)。

---

### 3.62 FAT32 8.3/LFN 目录项纯解析抽出并搬上非 x86（SK-62,2026-07-22）

- **背景**:SK-61 抽出几何/簇数学后,`fat32.zig` 仍内联 8.3 编解码、目录项
  size/cluster 字段读写、LFN/卷标属性判定。这些路径无 I/O，却无法在非 x86
  单测，也阻碍后续真正装配长文件名。
- **方案**:在 `fs/fat32_util.zig` 追加纯助手：`decode83Name`/`encode83Name`、
  `dirEntryFirstCluster`/`dirEntrySize` 及 setter、`isLfnAttr`/
  `isVolumeLabelAttr`/`isDirectoryAttr`、Microsoft `lfnChecksum`、
  `decodeLfnEntryChars` + `lfnSequence`/`isLastLfnSlot`。x86 `fat32.zig` 的
  `listRootDir`/`createFile`/`updateDirEntry`/`deleteFile` 改为 1:1 委托。
  新增 `shared/sk62.zig`：固定 `readme.txt`/`Makefile` 编解码往返、
  0x12345678 簇号与 size 字段、属性谓词、手算对照的 LFN checksum、以及合成
  last-slot LFN（`"hello"` UCS-2）提取。
- **效果**:目录项命名层与块设备解耦，可移植可单测；为后续完整 LFN 装配铺路，
  且不增加热路径开销（仍是内联数学，无额外分配）。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-62] fat32 8.3/LFN helpers non-x86: OK`。
- **后续**:见 3.63（ext2 超级块/几何/inode 定位纯解析,已完成)。

---

### 3.63 ext2 超级块/几何/inode 定位抽出 `ext2_util.zig` 并搬上非 x86（SK-63,2026-07-22）

- **背景**:FAT32 纯层（SK-61/62）收官后转向 `ext2.zig`。超级块 magic/几何、
  inode 表寻址、mode 谓词、逻辑块分类与 I/O/缓存缠在一起，无法在非 x86 单测。
- **方案**:新增 `fs/ext2_util.zig`：公开 on-disk 结构体、`parseSuperblock`/
  `deriveGeometry`/`bgdtBlock`/`ptrsPerBlock`、`inodeLocation`、
  `classifyLogicalBlock`、`isDirectory`/`isSymlink`/`isRegular`、目录项名
  切片比较。`ext2.zig` 的 `init`/`readInode`/`writeInode`/mode 判定/
  `findDirEntry` 名比较改为委托；I/O 与缓存路径不动。新增 `shared/sk63.zig`：
  合成 1KiB/rev1/256-byte-inode 超级块，校验几何（groups=1、bgdt=2）、
  非法 magic/零 bpg 拒绝、inode 3/5 跨块定位、mode 谓词、direct/single/
  double/triple 分类，以及目录项 `"foo"` 名切片。
- **效果**:ext2 解析与寻址成为可移植纯模块；x86 驱动行为保持等价且无额外
  热路径分配。为后续把 `resolveBlock` 整段切到分类器铺路。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-63] ext2 parse/geometry non-x86: OK`。
- **后续**:见 3.64（`resolveBlock` 消费 classify + 纯 resolve,已完成)。

---

### 3.64 ext2 `resolveBlock` 消费 `classifyLogicalBlock`（SK-64,2026-07-22）

- **背景**:SK-63 抽出分类器后,驱动里的 `resolveBlock` 仍手写四套
  direct/single/double/triple 边界与索引算术,与 util 双份维护,且 cache
  miss 路径复制了六段几乎相同的 `allocPage`+`readBlock` 样板。
- **方案**:`resolveBlock` 改为 `switch (classifyLogicalBlock)` + 共享
  `loadIndirectPtr`(cache 命中零拷贝,miss 读盘入缓存)。新增
  `resolveLogicalPure`——同样 compose 路径,指针表由调用方提供,供非 x86
  探针在无 I/O 条件下验证。`shared/sk64.zig` 用 ppb=4 的微型表覆盖
  direct/single/double/triple、空洞与越界。
- **效果**:寻址数学单点维护;热路径 cache 命中次数不变,去掉重复样板;
  纯 resolve 可在 riscv64/aarch64 实跑断言。`ensureBlock` 仍用旧边界
  (分配副作用更大,留待后续对称改造)。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-64] ext2 resolve via classify non-x86: OK`。
- **后续**:见 3.65（`ensureBlock` 对称消费 classify,已完成)。

---

### 3.65 ext2 `ensureBlock` 对称消费 `classifyLogicalBlock`（SK-65,2026-07-22）

- **背景**:SK-64 让读路径 `resolveBlock` 走分类器后,写路径 `ensureBlock`
  仍手写四套边界/索引与重复的「确保 root → 子间接块 → 数据块」样板,双份
  维护风险高。
- **方案**:`ensureBlock` 改为 `switch (classifyLogicalBlock)`；抽出
  `ensureIndirectRoot` / `ensureChildIndirect` / `ensureDataPtr` 三个共享
  助手(保留 v53.25 间接块强制清零、v53.30 cache 可变引用与
  revalidate/flush 语义)。util 增加 `indirectRootSlot`(12/13/14)。
  `shared/sk65.zig` 锁定 classify→root-slot→resolve 索引契约。
- **效果**:读写寻址同一分类器;分配热路径行为逐字节等价,样板删除后更易审
  核。x86 smoke 覆盖 `writeFile`→`ensureBlock` 实路径。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-65] ext2 ensure via classify non-x86: OK`。
- **后续**:见 3.66（FAT32 多槽 LFN→UTF-8 装配,已完成)。

---

### 3.66 FAT32 多槽 LFN→UTF-8 纯装配（SK-66,2026-07-22）

- **背景**:SK-62 抽出单槽 LFN 字符/校验和后,长文件名仍无法从多槽链还原;
  `listRootDir` 直接跳过 `0x0F` 项,只暴露 8.3 短名。
- **方案**:`fat32_util.assembleLfnUtf8`——按正向扫描序(首槽带 `0x40|N`)校验
  Microsoft checksum、补齐 1..N 槽、拼接 UCS-2/UTF-16(含代理对)并编码
  UTF-8。`listRootDir` 收集 pending LFN 链,短项到达时优先装配;失败或无链
  时回退 `decode83Name`。删除项/卷标清空孤儿链。`shared/sk66.zig` 覆盖
  双槽 `hello-world.txt`、单槽、坏校验和、缺 last 标记、以及 😀 代理对。
- **效果**:长名解析零 I/O 纯函数可移植验证;x86 列表路径在有 LFN 时直接给
  UTF-8,无额外分配(栈上 pending 缓冲)。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-66] fat32 LFN assemble UTF-8 non-x86: OK`。
- **后续**:见 3.67（LFN 编码/别名 + createFile 写回,已完成)。

---

### 3.67 FAT32 UTF-8→LFN 编码与 createFile 长名写回（SK-67,2026-07-22）

- **背景**:SK-66 可装配长名,但 `createFile` 仍限制 `name.len<=12` 且只写
  8.3 短项,无法创建长文件名。
- **方案**:`fat32_util` 增加 `utf8ToUtf16`/`fits83Name`/`make83Alias`/
  `encodeLfnEntry`/`buildLfnEntries`。`createFile`：短名走原路径;长名生成
  `XXXXXX~N.EXT` 别名(避开扇区内冲突)、`buildLfnEntries` 后写入连续目录
  槽(LFN 链 + 短项)。`shared/sk67.zig` 覆盖 fits/alias、双槽 round-trip、
  😀 代理对与 `utf8ToUtf16`。
- **效果**:读写对称的纯 LFN 编解码;创建热路径仅在长名时多写有界槽位,无堆
  分配。短名行为保持兼容。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-67] fat32 LFN encode/alias non-x86: OK`。
- **后续**:见 3.68（跨扇区/簇目录槽分配,已完成)。

---

### 3.68 FAT32 跨扇区/簇连续目录槽分配（SK-68,2026-07-22）

- **背景**:SK-67 的 `createFile`/`listRootDir` 只读根目录首扇区,长名 LFN
  链与位于后续扇区/簇的文件会被漏列或无法创建;`findConsecutiveFree`/
  `shortNameTaken` 仍内联在驱动里。
- **方案**:两函数 + `sectorHasDirEnd` 迁入 `fat32_util`。`listRootDir` 遍历
  每簇全部扇区;`createFile` 全链扫描别名冲突与连续空槽,满则
  `growRootDir` 追加清零簇后重试。`shared/sk68.zig` 锁定空扇区/部分占用/
  间隙 run、短名占用与 LFN 跳过规则。
- **效果**:根目录列表与创建覆盖完整簇链;槽位搜索纯函数可移植验证;满目录
  可增长而非静默失败。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-68] fat32 dir slot placement non-x86: OK`。
- **后续**:见 3.69（跨扇区单条 LFN 链,已完成)。

---

### 3.69 FAT32 跨扇区 LFN 链写入（SK-69,2026-07-22）

- **背景**:SK-68 的连续空槽搜索与写入仍以「扇区内」为隐含单位时,长名
  LFN 链若从扇区尾部起跨入下一扇区/簇会放不下或写坏;`findConsecutiveFree`
  只看单扇区窗口。
- **方案**:`fat32_util` 增加 `splitDirIndex` / `findConsecutiveFreeMulti`(线性
  下标跨多扇区,`0x00` EOF 延展到窗口末)。驱动侧 `DirPlace` 改为
  `(cluster, sector_in_cluster, entry_index)`,`findFreeRunInRoot` 跨扇区/簇
  累计 free run;`writeRootEntryRun` + `advanceRootPos` 流式写入整条链。
  `shared/sk69.zig` 锁定跨界 start/end 拆分、间隙拒绝与 EOF 延展。
- **效果**:单条 LFN+短项可跨越扇区与簇边界落盘;放置规则可在非 x86 纯验证。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-69] fat32 cross-sector dir run non-x86: OK`。
- **后续**:见 3.70（UDP over IPv6 栈层,已完成)。

---

### 3.70 UDP over IPv6 接收/发送（SK-70,2026-07-22）

- **背景**:`mod.zig` 对 IPv6 `PROTO_UDP` 仍为空 TODO;AF_INET6 套接字在
  syscall 层回落到 IPv4 UDP 机器,栈层无法投递或发出 IPv6 UDP。
- **方案**:新增 `udp_util`(头解析 + 强制 IPv6 UDP 校验和)。`udp.zig` 队列项
  扩为 `[16]u8` + `is_v6` 标志;`handlePacketV6`/`recvFromV6`/`sendToV6`
  (NDP lookup,缺邻则 `markIncomplete`;源地址用 link-local)。`mod.zig` 接线
  RX。`shared/sk70.zig` 锁定校验和、零校验拒绝、v4/v6 队列隔离与 NDP TX。
- **效果**:内核可收发 IPv6 UDP(链路本地 + 已解析邻居);IPv4 路径与 SK-53 不回归。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-70] udp over ipv6 non-x86: OK`。
- **后续**:见 3.71（`sockaddr_in6` syscall 接线,已完成)。

---

### 3.71 sockaddr_in6 与 AF_INET6 UDP syscall（SK-71,2026-07-22）

- **背景**:SK-70 提供了栈层 `sendToV6`/`recvFromV6`,但 `socket(AF_INET6)`
  创建的 fd 未标记 IPv6,bind/sendto/recvfrom/connect 仍按 `sockaddr_in` 解析。
- **方案**:`sockaddr_util` 锁定 Linux `sockaddr_in`/`sockaddr_in6` 布局。
  `FileDescriptor` 增加 `udp_is_v6` + `udp_dst_ip6`;AF_INET6/SOCK_DGRAM 置位。
  bind/connect/sendto/recvfrom 按标志分支到 V6 API 与 28 字节地址写出。
  `shared/sk71.zig` 锁定编解码 round-trip 与族不匹配拒绝。
- **效果**:用户态可用标准 `sockaddr_in6` 对 IPv6 UDP 套接字 bind/connect/
  sendto/recvfrom;IPv4 UDP 路径保持兼容。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-71] sockaddr inet6 util non-x86: OK`。
- **后续**:见 3.72（NDP Neighbor Solicitation TX,已完成)。

---

### 3.72 NDP Neighbor Solicitation 发送（SK-72,2026-07-22）

- **背景**:SK-70 `sendToV6` 在 NDP 未命中时只 `markIncomplete`,从不发出 NS,
  对端无法以 NA 填充邻居缓存,首包到新邻居永远失败。
- **方案**:`ipv6.multicastMac`;`icmpv6.buildNeighborSolicitation`(纯函数:
  solicited-node L3/L2、type 135、Source-LL 选项)+`sendNeighborSolicitation`。
  `udp.sendToV6` 在 miss 路径调用 NS。`shared/sk72.zig` 锁定帧布局与校验和。
- **效果**:IPv6 UDP 首发可主动解析邻居(对称于 ARP request);NA RX 路径复用
  既有 `handleNeighborAdvertisement`。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-72] ndp neighbor solicitation non-x86: OK`。
- **后续**:见 3.73（UDP getsockname/getpeername,已完成)。

---

### 3.73 UDP getsockname / getpeername（SK-73,2026-07-22）

- **背景**:`getsockname`/`getpeername` 仅接受 TCP,且错误地用 `fd >= 16`
  截断;`AF_INET6` UDP 套接字无法查询本地/对端地址。
- **方案**:`sockaddr_util.encodeUdpName`;UDP 分支写出本机 IPv4/`link-local`
  或已 connect 的对端;`getpeername` 未连接返回 `ENOTCONN`。fd 上界改为
  `MAX_FDS`。TCP 路径改走 `writeInet4`。`shared/sk73.zig` 锁定编解码长度与字段。
- **效果**:用户态可对 IPv4/IPv6 UDP 查询 sockname/peername;高编号 TCP fd 不再被误拒。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-73] udp getsockname encode non-x86: OK`。
- **后续**:见 3.74（TCP over IPv6 checksum/RX 门控,已完成)。

---

### 3.74 TCP over IPv6 校验和与 RX 门控（SK-74,2026-07-22）

- **背景**:`mod.zig` 对 IPv6 `PROTO_TCP` 仍为空 TODO;TCB 全为 IPv4 四元组,
  完整 listen/connect 需扩地址字段与 `sendSegmentV6`。
- **方案**:`tcp_util.checksumV6`(伪首部 + 跳过 checksum@16);`tcp.handlePacketV6`
  强制校验后暂丢弃(不 demux)。`mod.zig` 接线 RX。`shared/sk74.zig` 锁定
  校验和与坏包/零校验门控。
- **效果**:错误的 IPv6 TCP 段不再静默落入空分支;为后续 TCB/v6 TX 铺路。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-74] tcp over ipv6 checksum/rx gate non-x86: OK`。
- **后续**:见 3.75（TCB IPv6 demux / listen SYN,已完成)。

---

### 3.75 TCP IPv6 TCB demux 与 listen SYN（SK-75,2026-07-22）

- **背景**:SK-74 校验通过后直接丢弃;TCB 无 IPv6 地址字段,listen 不区分族,
  `AF_INET6` SOCK_STREAM 未标记 IPv6。
- **方案**:TCB/`ListenSlot` 增加 `is_v6` + `remote_ip6`;`findTcbByTupleV6`;
  IPv4 demux 跳过 v6 项。`handlePacketV6` 校验后 demux(命中清 `idle_ms`)或
  `handleIncomingSynV6`。`tcpSetIpv6` + syscall 置位;`sendSegment` 对 v6 暂返回
  false(TX 留给 SK-76)。`tcp_util.tupleMatchV6` + `shared/sk75.zig`。
- **效果**:IPv6 TCP 可匹配已有连接并接受 listen SYN 入 SYN_RECEIVED;SYN-ACK
  发送与完整状态机共享为下一步。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-75] tcp ipv6 tcb demux non-x86: OK`。
- **后续**:见 3.76（`sendSegmentV6` + 握手完成,已完成)。

---

### 3.76 TCP IPv6 sendSegmentV6 与握手（SK-76,2026-07-22）

- **背景**:SK-75 在 listen SYN 后 `sendSegment` 对 v6 直接返回 false,无法发出
  SYN-ACK;established 数据路径仍未共享。
- **方案**:抽出 `fillTcpSegment`/`advanceSndNxt`;`sendSegment` 按 `is_v6` 分发到
  `sendSegmentV6`(NDP lookup/NS、tcp@54、`checksumV6`、`ETHERTYPE_IPV6`)。
  `handlePacketV6` 完成 `syn_sent`/`syn_received` 三次握手。`shared/sk76.zig`
  锁定无 NDP 不推进、有 NDP 则 SYN-ACK + 第三 ACK → established。
- **效果**:IPv6 TCP 服务端/客户端可完成握手;数据面与 IPv4 状态机完全共享留待后续。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-76] tcp sendSegmentV6 handshake non-x86: OK`。
- **后续**:见 3.77（established 数据/关闭共享,已完成)。

---

### 3.77 TCP IPv6 established 路径共享（SK-77,2026-07-22）

- **背景**:SK-76 仅在 `handlePacketV6` 内手写握手分支,established 数据、FIN/
  关闭状态机仍只跑在 IPv4 `handlePacket` 里。
- **方案**:抽出 `driveTcbStateMachine`(RST、握手、established、FIN 各态);
  IPv4/IPv6 RX 在 demux 后共用。`shared/sk77.zig` 锁定握手 → 收 1 字节 →
  FIN → `close_wait`。
- **效果**:IPv6 TCP 数据面与关闭路径与 IPv4 同构;后续 syscall/`connect` 可直接复用。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-77] tcp ipv6 established path non-x86: OK`。
- **后续**:见 3.78（TCP `sockaddr_in6` bind/connect/accept,已完成)。

---

### 3.78 TCP sockaddr_in6 bind/connect/accept（SK-78,2026-07-22）

- **背景**:IPv6 TCP 数据面已通,但 syscall 仍按 IPv4 解析 `connect`/`getsockname`/
  `getpeername`,且 `accept` 丢弃 peer 地址回填。
- **方案**:`tcpConnectSocketV6` + `AddrInfo.is_v6`/`remote_ip6`/`local_ip6`;
  `encodeInetName` 统一 TCP/UDP 名字编码;bind/connect/accept/name 查询走
  `sockaddr_in6`。`shared/sk78.zig` 锁定 connect→`syn_sent` 与名字 round-trip。
- **效果**:用户态可用 `AF_INET6` TCP 完成 bind/connect 与 peer/local 地址查询。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-78] tcp sockaddr_in6 connect name non-x86: OK`。
- **后续**:见 3.79（NDP NS 重传,已完成)。

---

### 3.79 NDP Neighbor Solicitation 重传（SK-79,2026-07-22）

- **背景**:SK-72 在 cache miss 时只发一次 NS;`incomplete` 条目若丢包会永久卡住。
- **方案**:`NeighborEntry.retrans_ms`/`solicit_count`;`ndp.timerTick` 按
  RetransTimer=1s、MAX_MULTICAST_SOLICIT=3 产出待重发目标;`icmpv6.neighborTimerTick`
  发送并挂到调度维护路径。`shared/sk79.zig` 锁定重传计数与耗尽删除。
- **效果**:丢失的 NS 会按 RFC 4861 默认节奏重试,失败后清理 incomplete 槽位。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-79] ndp ns retransmit non-x86: OK`。
- **后续**:见 3.80（reachable→stale 老化,已完成)。

---

### 3.80 NDP reachable→stale 老化（SK-80,2026-07-22）

- **背景**:邻居一经 NA/`update` 即永久 `reachable`,不符合 NUD;长期无确认的
  映射不会降级。
- **方案**:`NeighborEntry.age_ms` + `REACHABLE_TIME_MS`(30s);`ndp.timerTick`
  将超时 `reachable` 降为 `stale`;`lookup` 仍返回 MAC。`shared/sk80.zig` 锁定
  老化与 refresh 重置。
- **效果**:NUD 第一步落地;后续可在 stale 使用路径上接 DELAY/PROBE 单播 NS。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-80] ndp reachable stale aging non-x86: OK`。
- **后续**:见 3.81（stale→delay→probe 单播 NS,已完成)。

---

### 3.81 NDP stale→delay→probe 单播 NS（SK-81,2026-07-22）

- **背景**:SK-80 仅老化到 `stale`;首次使用后不会进入 DELAY/PROBE,也无法发
  单播 NS 做不可达探测。
- **方案**:`lookup` 将 `stale`→`delay`;`timerTick` 经 DELAY_FIRST_PROBE_TIME
  进入 `probe` 并产出单播 `Solicit`;`buildNeighborSolicitationUnicast` +
  `neighborTimerTick` 发送。耗尽 `MAX_UNICAST_SOLICIT` 后删除。`shared/sk81.zig`
  锁定帧布局与状态迁移。
- **效果**:NUD 主路径完整(reachable/stale/delay/probe/incomplete)。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-81] ndp delay probe unicast non-x86: OK`。
- **后续**:见 3.82（RS/RA 默认路由,已完成)。

---

### 3.82 Router Solicitation/Advertisement 默认路由（SK-82,2026-07-22）

- **背景**:NUD 已齐,但主机无默认路由器;ICMPv6 常量有 RS/RA 却未实现。
- **方案**:`buildRouterSolicitation`→ff02::2;`parseRouterAdvertisement` +
  `handleRouterAdvertisement` 学习 Source LL 与 Router Lifetime;
  `ndp.setDefaultRouter`/`getDefaultRouter`。`shared/sk82.zig` 锁定 RS 帧与
  RA→默认路由/清除。
- **效果**:可主动探测并缓存默认路由器(前缀学习留待后续)。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-82] ndp router solicit advert non-x86: OK`。
- **后续**:见 3.83（Prefix Information / on-link 表,已完成)。

---

### 3.83 RA Prefix Information 与 on-link 前缀表（SK-83,2026-07-22）

- **背景**:SK-82 只学默认路由器,忽略 PIO;无法判断目的地址是否 on-link。
- **方案**:解析 type=3 Prefix Information;`ndp.setPrefix`/`isOnLink`;
  `ipv6.prefixMatch`。link-local 恒为 on-link。`shared/sk83.zig` 锁定
  `/64` 匹配、RA 安装与 lifetime=0 清除。
- **效果**:可据 RA 前缀做 on-link 判定(SLAAC 地址生成留待后续)。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-83] ndp prefix on-link non-x86: OK`。
- **后续**:见 3.84（SLAAC 地址生成,已完成)。

---

### 3.84 SLAAC 从 A-flag /64 生成全球地址（SK-84,2026-07-22）

- **背景**:SK-83 有前缀表但未形成主机地址;无法作为全球 IPv6 源地址。
- **方案**:`formSlaacAddress`(prefix||EUI-64);`installSlaac` 在 A-flag /64
  且 lifetime>0 时安装,lifetime=0 时删除;RA 处理路径自动调用。
  `shared/sk84.zig` 锁定形态与安装/清除。
- **效果**:主机可从 RA 获得全球单播地址(DAD 与源地址选用留待后续)。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-84] ndp slaac address non-x86: OK`。
- **后续**:见 3.85（DAD → preferred,已完成)。

---

### 3.85 SLAAC DAD 后标记 preferred（SK-85,2026-07-22）

- **背景**:SK-84 安装地址后立即可用,无重复地址检测,违背 RFC 4862。
- **方案**:地址先 `tentative`;`buildDadNeighborSolicitation`(src=::,无 SLLA);
  `dadTimerTick` 经 RetransTimer×DupAddrDetectTransmits 后改 `preferred`;
  收到针对 tentative 的 NS/NA 则 `dadConflict` 丢弃。`getGlobalAddress` 仅返回
  preferred。`shared/sk85.zig` 锁定帧、晋升与冲突。
- **效果**:SLAAC 地址在 DAD 通过前不可作源地址选用。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-85] ndp slaac dad preferred non-x86: OK`。
- **后续**:见 3.86（源地址选用,已完成)。

---

### 3.86 IPv6 源地址选用（SK-86,2026-07-22）

- **背景**:SLAAC preferred 地址已有,但 UDP/TCP IPv6 TX 仍固定用 link-local。
- **方案**:`ndp.selectSourceAddress` — LL 目的用 LL 源;否则优先同 /64 的
  preferred 全球地址,再退回任意 preferred,最后 LL。接入 `sendToV6`/
  `sendSegmentV6`/`tcpGetAddrInfo`/UDP `getsockname`。`shared/sk86.zig` 锁定
  三类目的选择结果。
- **效果**:有 SLAAC 地址后,发往全球目的时使用正确全球源地址。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-86] ipv6 source select non-x86: OK`。
- **后续**:见 3.87（off-link 经默认路由器,已完成)。

---

### 3.87 IPv6 off-link 下一跳经默认路由器（SK-87,2026-07-23）

- **背景**:源地址已可选全球地址,但 TX 仍对 L3 目的做 NDP;off-link 主机
  无法解析,报文发不出去。
- **方案**:`ndp.resolveNextHop` — on-link/LL 解析目的本身;multicast 推导
  MAC;off-link 解析默认路由器并在未命中时对其发 NS。接入 `sendToV6`/
  `sendSegmentV6`。`shared/sk87.zig` 锁定四类解析结果。
- **效果**:有默认路由器后,可向 off-link IPv6 目的发送(L3 目的不变)。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-87] ipv6 nexthop router non-x86: OK`。
- **后续**:见 3.88（启动时自动 RS,已完成)。

---

### 3.88 启动时自动 Router Solicitation（SK-88,2026-07-23）

- **背景**:RS/RA 与默认路由已齐,但主机从不主动发 RS,只能被动等 RA。
- **方案**:`startRouterSolicit` 在 `net.init` 立即发首个 RS;`routerSolicitTimerTick`
  按 RTR_SOLICITATION_INTERVAL 最多重试 `MAX_RTR_SOLICITATIONS` 次;收到
  lifetime>0 的 RA 或已有默认路由则 `stopRouterSolicit`。`shared/sk88.zig`
  锁定重试与早停。
- **效果**:启动后可自动发现路由器/前缀,无需人工注入 RS。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-88] ndp auto router solicit non-x86: OK`。
- **后续**:见 3.89（默认路由器 Router Lifetime 老化,已完成)。

---

### 3.89 默认路由器 Router Lifetime 老化（SK-89,2026-07-23）

- **背景**:RA 写入 `default_router_lifetime_sec` 后从不递减,过期路由仍被
  `resolveNextHop` 使用。
- **方案**:`ndp.routerLifetimeTimerTick` 按秒老化剩余 lifetime;归零时清除默认
  路由器。`icmpv6.neighborTimerTick` 在过期时调用 `startRouterSolicit` 重新发现。
  RA 刷新会重置 age 累加器。`shared/sk89.zig` 锁定秒级老化、刷新与 RS 重启。
- **效果**:过期默认路由不再劫持离链路下一跳;可再次发 RS 学习新路由器。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-89] ndp router lifetime aging non-x86: OK`。
- **后续**:见 3.90（前缀 Valid Lifetime 老化,已完成)。

---

### 3.90 前缀 Valid Lifetime 老化（SK-90,2026-07-23）

- **背景**:RA PIO 写入 `valid_lifetime` 后从不递减,过期前缀仍被 `isOnLink`
  视为在链路,对应 SLAAC 地址也不失效。
- **方案**:`ndp.prefixLifetimeTimerTick` 按秒老化各前缀剩余 lifetime;`0xffffffff`
  表示无穷不老化;归零时清除前缀并 `clearSlaacForPrefix`。RA 刷新重置 age。
  接入 `icmpv6.neighborTimerTick`。`shared/sk90.zig` 锁定老化、刷新、无穷与
  SLAAC 清除。
- **效果**:过期前缀不再误判 on-link;SLAAC 地址随前缀失效。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-90] ndp prefix lifetime aging non-x86: OK`。
- **后续**:见 3.91（Preferred Lifetime / 地址弃用,已完成)。

---

### 3.91 Preferred Lifetime 老化与地址弃用（SK-91,2026-07-23）

- **背景**:PIO 已解析 `preferred_lifetime`,但 SLAAC 在 DAD 后永远保持
  `preferred`,`selectSourceAddress` 会一直选用过期地址。
- **方案**:`installSlaac` 携带 Preferred Lifetime(钳制 ≤ Valid);`preferredLifetimeTimerTick`
  按秒老化;`0` 时 `preferred→deprecated`(仍 `hasLocalAddress`,但新 TX 跳过);
  RA 刷新可恢复 `preferred`。`0xffffffff` 不老化。接入 `neighborTimerTick`。
  `shared/sk91.zig` 锁定老化、弃用、源选跳过与刷新恢复。
- **效果**:弃用地址不再作新连接源地址;Valid 未到期前仍可收包。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-91] ndp preferred lifetime aging non-x86: OK`。
- **后续**:见 3.92（多默认路由器选择,已完成)。

---

### 3.92 多默认路由器列表与选择（SK-92,2026-07-23）

- **背景**:仅保留单一默认路由器,后到的 RA 会覆盖先到的;一路由器过期即空窗。
- **方案**:`MAX_DEFAULT_ROUTERS` 列表;`setDefaultRouter` 按 IP 增删改;`getDefaultRouter`
  粘性选择,优先有邻居 MAC 缓存的路由器;部分过期时切到剩余项,列表空时才重启 RS。
  `shared/sk92.zig` 锁定多条目、可达优先、回退与部分/全部过期。
- **效果**:多路由器环境可保留备选;离链路下一跳可在路由器间故障转移。
- **验证**:三架构构建 + `smoke`/`smoke-smp` + riscv64/aarch64 smoke 全绿，
  打印 `[SK-92] ndp multi default router non-x86: OK`。
- **后续**:默认路由器可达性探测(主动 NUD);或 RA 路由信息选项(RIO)。

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
Phase F — 第二 ISA              ✅ M2–M7；✅ SK-1…SK-46
Phase F2 — 第三 ISA             ✅ M9-7；✅ SK-1…SK-46
Phase G — 按需 syscall 脚手架  ⬜ futex/select/clone…（按应用需求逐个接入）
```

### 5.4 历史设计备忘（M8-5b-2d/2c — 已完成）

> 下列步骤在 2026-06 已落地；保留作调查记录，**不再是下一执行项**。
> 当前下一执行项：可移植 boot 片段已收敛（SK-1…SK-46，见 3.44 复盘）；
> 下一步为 **Phase G 按需 syscall** 或 NIC/PCI 抽象层 / copy_from_user
> fixup 两个中型专项之一。
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
