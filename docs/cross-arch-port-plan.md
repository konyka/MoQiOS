# MoQiOS 跨 CPU 架构移植路线图（2026-06 起）

本文件是 MoQiOS 从「单一 x86_64」走向「多 ISA、性能最优、SMP 可扩展」的总体计划与进度跟踪。
目标第二 ISA 选定 **riscv64**（特权架构最简洁、最易自举，Zig/LLVM 原生支持），第三 ISA
（aarch64）复用同一抽象层。

> 现实预期：完整跨 ISA 移植是**数月级、多轮**工程。本文件按里程碑（M0–M9）分解，每个里程碑
> 都要求「可构建 + 可验证 + x86_64 不回归」。

---

## 0. 现状基线（移植起点）

- **架构耦合**：内核 100% x86_64，`kernel/arch/` 下仅 `x86_64/`；约 60+ 源文件直接
  `@import("arch/x86_64/...")`（其中相当一部分是未集成脚手架）。无任何 `arch` 抽象接口。
- **SMP**：AP 启动链路已打通（到达 `[SMP] AP N initialized` 并停泊），但 `enable_ap_startup=false`。
  原门控根因（TSS 错位 + 中断 stub 寄存器破坏）**已修复**（见架构文档 1.7/1.8），SMP 重新可推进。
- **per-CPU 半成品**：`PerCpu` 结构体已含 `kernel_rsp/saved_stack_anchor/slice_remaining/
  current_task_idx`，但调度器仍用全局变量；`IrqSpinlock` 已是 SMP 安全自旋锁。
- **引导**：x86_64 经 Limine（提供 HHDM、memmap、framebuffer）。Limine 亦支持 riscv64/aarch64
  （UEFI 引导）；riscv64 另有更轻的 OpenSBI `-kernel` 直引导路径，适合骨架阶段。

### 环境约束（影响验证手段）

- 本开发机仅有 `qemu-system-x86_64`，**无 `qemu-system-riscv64`/`aarch64`，且无 root 安装**。
- 因此 riscv64/aarch64 在本机只能做**构建级 + 静态验证**（交叉编译成合法 ELF，`readelf`/`objdump`
  核对）。**运行时启动验证需安装** `qemu-system-riscv`（Fedora：`sudo dnf install qemu-system-riscv`）。
  运行脚本已备好（`tools/qemu_run_riscv64.sh`），emulator 可用后即可一键运行时验证。

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
| **M1** | `-Darch` 多目标构建；riscv64 内核**骨架**（`_start`+SBI 控制台+`kmain`+linker.ld）启动并打印 | 交叉编译成合法 riscv64 ELF（readelf/objdump）；x86_64 不回归（构建+启动到 shell）；运行时验证待 emulator | ✅ 完成（构建/静态）；⏳ 运行时待 emulator |
| **M2** | riscv64 早期 init：**改 soft-float ABI（lp64，禁用 F/D，内核不应用 FP 寄存器）**；解析 a0(hartid)/a1(DTB)，UART16550 直驱（不依赖 SBI），异常向量 `stvec` + trap 帧 | QEMU virt 启动打印 + 触发非法指令陷入被捕获 | ⬜ 待办 |
| **M3** | riscv64 物理内存管理：从 DTB/Limine memmap 建 PMM；Sv39 分页 map/unmap + HHDM | 映射/取消映射自测；缺页陷入 | ⬜ 待办 |
| **M4** | **抽取 `arch` 接口**：定义 `kernel/arch/arch.zig`（comptime 选择实现）；把内存/控制台/陷入/定时器迁到接口后；x86_64 改为通过接口 | x86_64 仍启动到 shell；riscv64 复用同一上层代码 | ⬜ 待办 |
| **M5** | riscv64 定时器 + 上下文切换 + 调度器接入（复用 `proc/sched.zig` 上层逻辑） | riscv64 跑多内核线程轮转 | ⬜ 待办 |
| **M6** | riscv64 用户态：U-mode 进入、syscall（`ecall`）入口、地址空间隔离 | riscv64 跑 `hello*` 用户程序 | ⬜ 待办 |
| **M7** | riscv64 驱动：virtio-blk/virtio-net（virtio 与 ISA 无关，复用大部分逻辑）+ 块/网/FS 上线 | riscv64 跑 ext2 读写、网络自测 | ⬜ 待办 |
| **M8** | **SMP（先 x86_64，后 riscv64）**：per-CPU 调度器（per-CPU 运行队列+work-stealing+per-CPU TSS/anchor）、通用 IPI、TLB shootdown；启用 `enable_ap_startup` | QEMU 多核：用户任务真正并行；零崩溃 | 🚧 进行中（见 §4） |
| **M9** | aarch64 后端（复用 M4 抽象 + Limine 引导 + GIC/generic timer/PL011） | QEMU aarch64 启动 → 用户态 | ⬜ 待办 |

> SMP（M8）与第二 ISA（M2–M7）相对独立，可并行；M8 的 per-CPU 改造也会反哺 riscv64/aarch64 的
> 多核。M4 的 `arch` 接口是二者共同地基。

---

## 3. 本轮（Round 1）交付 = M0 + M1

- ✅ M0：本路线图 + 选型 riscv64。
- ✅ M1：
  - `build.zig` 增加 `-Darch=x86_64|riscv64`（默认 x86_64，行为与之前完全一致）。
  - `kernel/arch/riscv64/start.zig`：S-mode `_start` → 设栈 → `kmain`，经 SBI legacy 控制台打印，
    SBI shutdown/`wfi` 停机。
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

## 4. M8 进度（x86_64 SMP）

把 M8 拆成可单独验证、可单独提交的小步；每步保持 **x86_64 单核不回归**（构建 + 启动到
`MoQiOS shell`），多核相关行为在 AP 上线（M8-5）后用 `-smp N` 验证。

| 子步 | 内容 | 状态 |
|---|---|---|
| **M8-1** | 通用 IPI 基础设施：`lapic.sendIpi(apic_id, vector)` + `sendIpiAllButSelf`；reschedule(0xFD)/TLB-shootdown(0xFE) 向量与 `interruptDispatch` 分发 + 处理器 | ✅ 完成（单核休眠态，未改调度行为） |
| **M8-2** | per-CPU 当前任务/时间片状态：`current_idx`/`slice_remaining` 迁入 `PerCpu`（单核等价 BSP） | ⬜ 待办 |
| **M8-3** | per-CPU 上下文切换 anchor：`commonStub` 按来源 CS `swapgs` + 经 `%gs` 取 per-CPU anchor | ⬜ 待办 |
| **M8-4** | per-CPU TSS RSP0：`setRsp0` 作用于当前 CPU 而非固定 BSP | ⬜ 待办 |
| **M8-5** | AP 参与调度：per-CPU 运行队列 / work-stealing + AP 开定时器 + `enable_ap_startup=true` | ⬜ 待办 |
| **M8-6** | 跨核 TLB shootdown：per-CPU shootdown 描述符 + 范围 `invlpg`（取代 M8-1 的 CR3 全刷回退） | ⬜ 待办 |

### M8-1 设计要点

- **向量选择**：`0xFD`（reschedule）、`0xFE`（TLB shootdown），避开 PIC 重映射区（32–47）、LAPIC
  定时器（240）、AHCI（241），且低于 spurious（`0xFF`）。256 个 IDT stub 在 `idt.init()` 已全部安装，
  因此无需新增门，只需在 `interruptDispatch` 增加分发分支。
- **`sendIpi`**：Fixed 投递（000）、物理目的、assert（bit14）、edge；轮询 ICR delivery-status（bit12）。
  允许 self-IPI（目标为自身 APIC ID），用于强制本核 reschedule。
- **休眠态安全**：单核下无人发送 IPI，两个处理器分支不会触发，调度行为与之前逐字节一致；故
  本步唯一验证目标是「仍构建并启动到 shell」。后续 M8-5 上线 AP 后这些原语才真正被驱动。
