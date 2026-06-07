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
| **M8-2** | per-CPU 当前任务/时间片状态：`current_idx`/`slice_remaining` 迁入 `PerCpu`（单核等价 BSP） | ✅ 完成（单核回归一致，386 行启动到 shell） |
| **M8-3** | per-CPU 上下文切换 anchor：`commonStub` 经 `%gs` 取 per-CPU anchor（无需 swapgs） | ✅ 完成（单核回归一致，386 行启动到 shell） |
| **M8-4** | per-CPU TSS RSP0：`setRsp0` 作用于当前 CPU 而非固定 BSP | ✅ 完成（单核回归一致，386 行启动到 shell） |
| **M8-5a** | AP 上线 + 开定时器 + `enable_ap_startup=true`，但仍 BSP-only 调度（AP 空闲取中断） | ✅ 完成（`-smp 2`：2 CPUs online，BSP 跑完全部测试到 shell，零故障） |
| **M8-5b-2** | 亲和调度（无迁移）+ AP 参与 `timerTick` + AP 绑核 idle 引导 | 🚧 AP 用户态已通（hello2@AP）；跨核 spawn/waitpid 同步仍偶发挂起（hello4+） |
| **M8-5b** | （父项）AP 真正并行调度 | 🚧 5b-0/5b-1 ✅；5b-2 进行中；5b-3 FPU 待办 |
| **M8-6** | 跨核 TLB shootdown：per-CPU shootdown 描述符 + 范围 `invlpg`（取代 M8-1 的 CR3 全刷回退） | ⬜ 待办 |

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
  `hello2`–`hello28`（含 hello26 TCP echo、fork/execve、ext2）到 `MoQiOS shell`，**零故障/零非规范 RSP0**
  （串口 395 行，比单核多 9 行 SMP bring-up 信息）。

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

> 当前进度：**M8-5b-0/5b-1 已提交**；**M8-5b-2a**（AP syscall MSR、commonStub 用户入口、跨核
> reschedule IPI、`waitpid` 内存可见性、`pickReadyForCpu` 快照）已落地；`-smp 2` 下 hello2@AP
> 稳定，`init` 全量测试到 shell 仍偶发超时（M8-5b-2b 待办）。
> 下一小步：修 AP 上 `copy_from_user`/syscall 使 `-smp 2` 完整到 shell，再推进 5b-3 FPU。
