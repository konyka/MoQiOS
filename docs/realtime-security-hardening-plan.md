# MoQiOS 实时性 / 性能 / 安全加固计划（2026-10）

> 优先级：实时性 = 安全 > 性能 > 兼容性。每项改动都走 TDD：先写纯策略模块的
> host 测试（RED）→ 实现（GREEN）→ QEMU 验收程序（先在旧内核上 RED，再 GREEN）→
> 全量门禁（host tests、x86/riscv64/aarch64 构建、SMP=1/2 冒烟）。

## 0. 结论摘要

1. **基线已损坏（P0）**：HEAD 上 `zig build test` 编译失败、x86 内核构建失败，
   QEMU 冒烟有 9 个用户测试失败。7b811ff 之后的提交都没有通过 QEMU 冒烟。
   先恢复基线，后续工作才有可信的回归门禁。
2. **安全**：任意用户可以通过 `clock_nanosleep` 在 IF=0 的 syscall 里忙等，冻结一个
   CPU（SMP=1 时整机冻结）；`nanosleep` 的 `sec*1e9+nsec` 未校验，在 Debug/ReleaseSafe
   内核中会整数溢出 panic（用户态一行代码即可打崩内核）；CPU 未启用 SMEP/UMIP。
3. **实时性**：没有唤醒抢占，同 CPU 上被唤醒的 SCHED_FIFO 任务最长要等一个完整的
   OTHER 时间片（10 tick ≈ 100 ms）；强制调度通道（yield/IPI）与硬件 tick 共用记账，
   导致 RR 时间片被 IPI 反复重置（RR 退化为 FIFO）、FIFO 的 `sched_yield` 不让给同
   优先级任务、TCP/ICMPv6 定时器随 yield 频率加速；futex/mq/epoll/timerfd/POSIX timer/
   alarm 的超时只在 BSP 每 100 ms 的维护块里检查，超时精度只有 100 ms。
4. **最大的关中断来源是控制台**（实施中实测发现）：fbcon 镜像在串口写路径里逐字节
   上移整个帧缓冲，QEMU 下每个换行约 100 ms 关中断，一次 tick 维护里打几行日志就是
   300 ms 以上。写路径改为 O(字节数) 后，单次控制台写入从平均 126 ms 降到 0.3 ms，
   完整冒烟测试从约 3.5 分钟降到约 25 秒。

## 1. 与本计划相关的架构现状

| 子系统 | 现状 | 位置 |
|---|---|---|
| syscall 入口 | `SYSCALL` + `IA32_SFMASK=0x700`：syscall 体 IF=0，内核不可抢占 | `arch/x86_64/syscall_entry.zig` |
| 调度器 | 每 CPU 256 槽 FIFO 环形队列 + RT 感知 O(n) `popRtAware`、work stealing、原子 claim 协议 | `proc/per_cpu.zig`、`proc/sched_claim.zig` |
| tick | LAPIC 周期 100 Hz；`TIMESLICE_TICKS=10`；BSP 每 `REAP_INTERVAL` 次通道运行一次维护块 | `proc/sched.zig: timerTickFg` |
| 强制调度 | yield trap `int 252` 与 reschedule IPI `0xFD` 都走 `forceRescheduleFromIpi → timerTick` | `proc/sched.zig`、`arch/x86_64/idt.zig` |
| 唤醒 | `unblockTask*` 只入队；部分调用点再调 `kickRemoteForTask`（仅远程、无条件 IPI） | `proc/task.zig` |
| 超时 | futex/mq/epoll/alarm/itimer 位图门控；timerfd/POSIX timer 持锁全表扫描；全部在 100 ms 维护块里 | `sync/futex.zig`、`ipc/*.zig`、`net/epoll.zig` |
| CPU 保护 | CR0.WP、NX；无 SMEP/SMAP/UMIP；`userAccessBegin/End` 为空操作 | `arch/x86_64/paging.zig` |

## 2. 审查发现

### 2.1 P0：基线恢复（本轮已修复）

| ID | 问题 | 根因 | 修复 |
|---|---|---|---|
| B1 | host 测试门禁编译失败 | `host_test.zig` 重复导出 `posix_mq_descriptor_policy`；`tests/main.zig` 使用未声明别名；`@embedFile` 越出模块根目录 | 去重、补别名；`moqi_syscalls.h` 以匿名 import 交给 host 模块 |
| B2 | 3 个过期 host 测试 | `tokenBindsCallee` 参数过期、IPC 唤醒源码计数过脆、`absoluteDeltaNs` 用例写错 | 按代码语义修正；唤醒检查改为“每个 wake 前必有 pin”的不变量 |
| B3 | x86 内核构建失败 | `posix_mq.zig` 依赖的 `MAX_DESCRIPTORS`/`decodeToken` 丢失 | 恢复描述符编码（`DESCRIPTOR_BASE + slot`）并补 round-trip 测试 |
| B4 | pthread/CLONE_THREAD 全部失败（hello35/36/57/69/96/98/101） | 7b811ff 的 clone 门禁把已实现的 `CLONE_THREAD`（`Task.is_thread`）一并拒绝 | `CLONE_THREAD` 仅随 `CLONE_VM` 接受；`CLONE_SIGHAND`/`CLONE_FS` 继续 `EINVAL`；测试去掉多余的 `CLONE_FS` |
| B5 | 从 #PF 进入的信号 handler 返回即崩溃（hello58/99） | `sigreturn` 拒绝 RF 位，而故障类异常帧里 RF=1 合法；EFAULT 后 trampoline 继续执行到 `add %al,(%rax)` | 按 Linux `FIX_EFLAGS` 清洗 RFLAGS（保留用户位，强制 IF，丢弃 IOPL/NT/VM/VIF/VIP） |

### 2.2 本轮实施项

| ID | 优先级 | 问题 | 影响 |
|---|---|---|---|
| S1 | P1 安全+实时 | `clock_nanosleep` 在 IF=0 的 syscall 中 `pause` 忙等 | 非特权 DoS：冻结 CPU、屏蔽 tick/IPI；不可被信号打断；`rem` 恒为 0 |
| S2 | P1 安全 | `nanosleep` 未校验 timespec：负值、`nsec>=1e9` 被接受，`sec*1e9+nsec` 溢出 | Debug/ReleaseSafe 内核 panic（任意用户可打崩内核）；ReleaseFast 回绕成近似立即返回 |
| S3 | P1 正确性 | `getrusage` 返回“系统运行时间 × 70%/30%”，忽略 `who` | 用户态 CPU 计量完全失真；`Task.utime_us` 累计后从未被读取 |
| S4 | P1 安全 | 未启用 SMEP/UMIP | 内核可执行用户页（ret2usr）；用户态 `sgdt/sidt/sldt/smsw/str` 泄露内核描述符表地址 |
| S5 | P1 安全 | xAPIC `sendIpi` 两次写 ICR 之间不关中断 | IF=1 的内核线程被同样发 IPI 的中断打断时，第一个 IPI 发往错误目标 |
| R1 | P2 实时 | yield/IPI 强制通道推进 BSP 维护计数；维护通道直接 `return` | TCP RTO/TIME_WAIT、ICMPv6 NS 重传随 yield 频率加速；落在维护 tick 上的 yield/IPI 抢占被吞掉 |
| R2 | P2 实时 | IPI 路径上的 RT 守卫 `setSlice(TIMESLICE_TICKS)`；yield 与 IPI 共用“严格更优才让出” | RR 时间片被每次远程唤醒重置 → RR 退化为 FIFO；FIFO 任务 `sched_yield` 不让给同优先级（违反 POSIX） |
| R3 | P2 实时 | 无唤醒抢占；远程 IPI 不看目标 CPU 正在运行什么 | 同 CPU 唤醒的 RT 任务最长延迟 100 ms；远程唤醒低优先级任务也会打断正在运行的 RT 任务 |
| R4 | P2 实时 | 超时只在 100 ms 维护块里检查 | futex/mq/epoll/timerfd/POSIX timer/alarm/itimer 超时最多晚 100 ms |
| R5 | P2 正确性 | x86 细粒度 tick（`timerTickFg`，默认路径）从不调用 `ipc.timeoutTick`；host 测试只数到 legacy 路径里的那一次 | MoqIPC 阻塞等待的超时在 x86 上永远不会触发 |
| R6 | P2 正确性 | alarm/ITIMER_REAL 到期只置 pending 位，不唤醒阻塞中的任务 | `alarm()` 打断不了睡眠/阻塞等待，SIGALRM 要等任务自己醒来才投递 |
| R7 | P2 实时 | eventfd、unix socket、timerfd 读者、SysV sem、MoqIPC、NVMe 完成等唤醒点只调 `unblockTask`，从不通知目标 CPU；空闲 CPU 上的被唤醒任务要等当前时间片耗尽 | 这些路径的唤醒延迟最长一个时间片（100 ms） |
| R8 | P2 实时 | 时间片到期时运行中的 FIFO 任务无条件保留 CPU，不检查是否有更高优先级任务就绪 | 漏发通知的唤醒（如提升就绪任务的优先级）造成无界优先级反转 |
| R9 | P2 性能+实时 | `popRtAware` 的非 RT 路径按 FIFO 取条目，不区分 idle 类（优先级 255）；时间片到期时换出者“先选后入队”，队列里可能只剩 idle | idle 线程 `hlt` 掉整整一个时间片，而普通/RR 任务就绪排队。原先被“维护 tick 把时间片截成 1”掩盖，修 R1 后由 `hello44` 的 RR 共享用例暴露 |
| R10 | P2 实时+性能 | `epoll_wait` 阻塞时置 `.blocked` 后在 syscall 里 `sti; hlt` 原地等待，直到下一个 tick 才被换下；超时按 tick 计数（`elapsed_ticks*10ms`）判定 | 每次阻塞白占 CPU 至多一个 tick；超时与 futex 的纳秒截止时间不同源，误差为整 tick |
| R11 | P2 实时+性能 | fbcon 镜像滚屏时在关中断的串口写路径里把整个帧缓冲（1280x800x32 ≈ 4 MB）逐字节上移一行（读回显存） | QEMU 下每个换行约 100 ms 关中断：每条内核日志、每次 `write(1)` 都付这笔账；落在 tick 维护里的日志把 IRQ-off 窗口拉到 300 ms 以上；耗时被记到当前任务的 CPU 时间（`hello102` 的 getrusage 因此超过进程寿命）。冒烟测试 3.5 分钟基本都花在这里 |

### 2.3 记录但本轮不实施（P3 路线）

- 可抢占内核（syscall 体 IF=1 + preempt count）：需要逐个审计持有 IrqSpinlock 的路径。
- TSC-deadline 高精度定时器 / tickless idle：策略模块 `deadline_timer_policy` 已落地，
  内核仍用 100 Hz 周期时钟——要把 wait 的纳秒截止时间汇总成全局最早 deadline 才能改编程。
- O(1) 优先级位图运行队列：替换 RT 感知的 O(n) `popRtAware`。
- PI futex / 优先级继承：消除 RT 任务经锁发生的优先级反转。
- `CLONE_SIGHAND`/`CLONE_FS` 共享对象与 `exit_group` 线程组语义。

## 3. 重新设计

### 3.1 统一阻塞睡眠路径（S1/S2/S3）

- 新增纯策略 `kernel/proc/sleep_policy.zig`：
  - `planRelative(sec, nsec, now)` / `planClock(clock, flags, sec, nsec, now, wall_offset)` 返回
    `invalid | immediate | sleep(monotonic_deadline)`；非法 timespec → `invalid`（EINVAL）；
    截止时间饱和加法（`+|`），超大请求等价于“睡到被信号打断”，与 Linux 的 `KTIME_MAX` 一致。
  - `remaining(deadline, now)` 饱和减法；`TIMER_ABSTIME` 不回写 `rem`（POSIX）。
- `syscall_entry.zig` 抽出 `sleepUntil(deadline, rem_ptr)`：发布 `sleep_deadline_ns` + `sleep_bm`
  → `blockTask` → yield trap；致命信号走 `exitTask`，可处理信号返回 `-EINTR` 并写 `rem`。
  `nanosleep` 与 `clock_nanosleep` 共用这一实现，删除忙等。
- `getrusage`：`RUSAGE_SELF/THREAD` 返回 `utime_us`（+当前正在运行这一段的 TSC 增量）与
  `stime_us`；`RUSAGE_CHILDREN` 返回 0（尚无子进程累计）；其他 `who` 返回 EINVAL。
  纯函数 `rusage_policy.classify` / `runtimeUs` / `timeval` 可在 host 上测试。
- alarm/ITIMER_REAL 到期后调用 `signal.kickIfBlocked`（R6）。

### 3.2 CPU 保护位（S4/S5）

- 纯策略 `kernel/arch/x86_64/cpu_protect_policy.zig`：`features(max_leaf, leaf7_ebx, leaf7_ecx)`
  解析 CPUID.(7,0)。第一轮 `cr4Bits` 只返回 `CR4.SMEP(20)` / `CR4.UMIP(11)`；第二轮在
  CPUID 报告 SMAP 时再置 `CR4.SMAP(21)`（§8.5）。
- `cpu_protect.zig`：BSP 在 `pcid.init` 之后调用 `init()`（打印
  `[CPU] SMEP on|off UMIP on|off SMAP on|off`），每个 AP 在 `pcid.initThisCpu` 之后调用
  `initThisCpu()` 复制同样的 CR4 位。
- `tools/qemu_run.sh` 的 `MOQI_CPU` 默认 `qemu64,+smep,+umip,+smap`，冒烟要求出现
  `[CPU] SMEP on UMIP on SMAP on`。
- `lapic.zig` 所有 ICR 发送（INIT/SIPI/fixed/NMI/广播）收敛到 `icrSend(high, low)`：两次写入
  加投递等待整体在关中断下完成。

### 3.3 调度通道分型（R1/R2）

- 纯策略 `kernel/proc/sched_pass_policy.zig`：
  - `PassKind = tick | ipi | yield`（`fromForceFlag` 解码 `PerCpu.force_reschedule`）；
    只有 `tick` 推进维护计数（`isTimeTick`）。
  - `rtKeepsCpu(kind, cur_key, best_key)`：`tick`（FIFO 时间片到期）与 `ipi` 要求“严格更优”
    才让出，`yield` 让给“同级或更优”（POSIX `sched_yield`）。
  - `sliceAfterKeep(saved_slice, full)`：强制通道保留原时间片，不再重置 RR quantum。
- `timerTickFg`：维护只在 BSP 的 `tick` 通道运行且不再 `return`（跑完维护照常做调度决策）；
  `forceRescheduleFromIpi` / `forceRescheduleFromYield` 共用 `forcedPass`：先关中断再发布通道
  类型（yield trap 是 trap gate，IF 可能为 1），并在每 CPU 数组中保存进入前的时间片。
- FIFO 时间片到期时用 `peekBestRankKey` 检查是否有严格更优的就绪任务（R8），每 100 ms 一次。
- legacy 路径保持字节不变（回滚用）。

### 3.4 唤醒抢占（R3）

- 纯策略 `kernel/proc/wake_preempt_policy.zig`：`decide(woken_key, target_cur_key, local)`
  - 本地：被唤醒者严格优于当前任务 → `preempt_local`；同级不抢占（避免唤醒者/被唤醒者乒乓）；
  - 远程：被唤醒者不劣于目标 CPU 当前任务（或目标没有运行中的任务）→ `kick_remote`；
    目标正在运行严格更优的任务 → `none`（不再白白打断 RT）。同级仍然 kick：被唤醒的可能
    正是远程当前任务本身（信号投递）。
- `target_cur_key` 来自 `percpu_array[cpu].current_task_idx` 的无锁读取，只作提示：读到旧值
  最多多一次调度通道或晚一个时间片，不影响正确性。
- 本地抢占用 self-IPI（`kickCpu(自己)`）：syscall 体 IF=0，IPI 在 `sysretq` / `iretq` 恢复
  IF 的第一刻送达，于是切换总发生在安全边界，不需要在唤醒点直接调用调度器。
- 唤醒统一在 `task.readyFromBlockedLocked` 完成 `.blocked → .ready` + 入队；`unblockTask*` 与
  `publishRunnable` 在释放 `task_lock` 之后调用 `sched.notifyWake(t)`。原来散落在 futex/signal/
  epoll/posix_mq 的 `kickRemoteForTask` 删除（否则远程会收到两次 IPI），R7 中从不通知的路径
  自动获得同样的抢占语义。

### 3.5 截止时间驱动的到期扫描（R4）

- 纯模块 `kernel/lib/deadline_hint.zig`：无锁 “最早截止时间” 提示
  （`arm` = 原子取 min，`due(now)` O(1)，扫描者 `beginScan` 后按剩余项重新 `arm`）。
- timerfd / POSIX timer 在 `settime` 时 `arm`，tick 先查提示，未到期不取锁。
- futex/mq/epoll/timerfd/POSIX timer/alarm/itimer 的到期检查移出 100 ms 维护块，改为 BSP
  每个硬件 tick 运行（`bspTimedWaitTick`，精度 10 ms）；reap/writeback/MoqIPC 超时/TCP/ICMPv6
  留在 `bspSlowMaintenance`，按 100 ms 节拍（TCP/ICMPv6 的 `100` 增量正好对得上）。

### 3.6 实施中暴露的缺陷（R9/R10）

- **idle 不得抢走就绪任务（R9）**：`popRtAware` 的选择规则抽成纯函数
  `sched_policy.PopChoice`——有 RT 时取最优 RT（同级取最老）；否则取最老的普通条目，
  跳过 idle 类（rank key = `MAX_PICK_KEY`）；只剩 idle 时才返回 idle。`pickNextFg` 之后再加
  `keepsCpuOverIdle` 守卫：当前任务仍 `.running`、允许在本 CPU 运行、而候选是 idle 时，
  把候选释放回就绪队列，当前任务继续运行。
- **epoll 阻塞改为让出 CPU、纳秒截止时间（R10）**：`epollWait` 用
  `epoll_policy.timeoutDeadlineNs(tsc.nanos(), timeout_ms)` 计算截止时间（与 futex 同源）；
  `blockOnEpoll` 先在 `inst.spin` 下检查授予/超时/可处理信号/实例有效性，仍需等待时才
  `rescheduleAfterBlock()`。“先检查再让出”保证等待开始前已经挂起的信号立即返回 `EINTR`
  （`hello89` 覆盖），未经授予离开时由 `unblockTask` 撤销自己的 `.blocked`。

### 3.7 控制台写路径 O(字节数)（R11）

- 纯模块 `kernel/drivers/fbcon_render.zig`：`Renderer.write` 只画变化的单元格（只写），
  滚屏只置 `repaint_pending`；`repaintStep` 按单元格网格重绘一行文本，最后一步补画光标。
  任何像素都不在帧缓冲内搬移，因此写路径不再读显存。
- `fbcon.idleFlush()` 挂在 `sched.kernelIdleLoop`：每持一次锁重绘一行，行间开中断；
  多次滚屏合并成一次重绘。控制台安静 `QUIET_NS`（20 ms）后才开始重绘，写者在取锁前
  发布时间戳、重绘者在行间检查并退让——`IrqSpinlock` 不公平，否则 SMP 下另一颗 CPU 的
  idle 重绘会让写者连输多轮（实测 hello106 最大 16 ms）。`panicFlush()` 无锁补画（其他 CPU 已被 NMI 停住，可能停在
  持锁状态）；fb0 映射者退出时 `requestRepaint()`。
- `fbcon_core` 的 `\t` 以 `Effect.rows` 报告被清空的行（原来返回 `.none`，屏幕残留旧
  字形），并修正行尾制表符一路清空后续整行直到滚屏的问题。

## 4. TDD 落地步骤

| 阶段 | host 测试（RED → GREEN） | QEMU 验收程序 | 冒烟标记 |
|---|---|---|---|
| P0 | clone 标志组合、sigreturn RFLAGS 清洗、MQ 描述符 round-trip | 既有 hello35/36/57/58/69/96/98/99/101 | 既有标记 |
| P1-1 | `sleep_policy`、`rusage_policy` | `hello102`：钉在 CPU0 的 spinner 在 `clock_nanosleep` 期间必须有进展；`alarm` 能以 `EINTR` 打断 `clock_nanosleep` 且 `rem` 合理；`TIMER_ABSTIME`；非法参数 EINVAL；超大 `nanosleep` 不 panic、可被信号打断；`getrusage` 不超过进程寿命 | `hello102: PASS` |
| P1-2 | `cpu_protect_policy` | `hello103`：子进程执行 `sgdt` 必须被 #GP 杀死（状态 141） | `hello103: PASS`、`[CPU] SMEP on UMIP on SMAP on` |
| P2-1/2 | `sched_pass_policy`、`wake_preempt_policy` | `hello104`：同钉 CPU0，OTHER 线程 futex 唤醒 SCHED_FIFO 线程，唤醒延迟上限 | `hello104: PASS` |
| P2-3 | `deadline_hint`（含随机 arm/scan 模型测试）、`epoll_policy.timeoutDeadlineNs` | `hello105`：futex/epoll 超时的平均超出量 | `hello105: PASS` |
| P2-4 | `sched_policy.PopChoice`、`keepsCpuOverIdle` | 既有 `hello44`（RR 共享） | `hello44: PASS` |
| P2-5 | `fbcon_render`（写路径零回读、每步一行、随机写入/重绘交错收敛到网格）、`fbcon_core` 制表符 | `hello106`：屏幕已满时 24 次整行 `write(1)` 的最大/平均延迟；`hello89` 覆盖“等待前已挂起的信号” | `hello106: PASS` |

验收程序在修复前的内核上必须失败（RED 证据记录在 review 文档条目里）。

## 5. 验证门禁

1. `zig build test --summary all`（host 单元 + libc + shell/python 契约测试）
2. `zig build`、`zig build -Darch=riscv64`、`zig build -Darch=aarch64`
3. `zig build smoke`（SMP=1）与 `zig build smoke-smp`（SMP=2）
4. 全部通过后按逻辑分组提交并推送 `origin main`

## 6. 风险与回滚

- SMEP/UMIP：如果某条内核路径执行了用户页，SMEP 会把它变成 #PF（本来就是漏洞）；
  `MOQI_CPU=qemu64` 可在 QEMU 中关闭，内核按 CPUID 自动降级。
- 唤醒抢占会增加上下文切换次数；本地只在严格更优时抢占，OTHER 对 OTHER 维持原行为。
- 维护块不再提前返回：维护和调度在同一次 IRQ-off 通道里完成，IRQ-off 时间略增，
  但换来了不再每 100 ms 跳过一次调度决策。

## 7. 结果（RED → GREEN）

| 指标 | 修复前 | 修复后 | 证据 |
|---|---|---|---|
| host 测试 | 编译失败 | 378/378 | `zig build test --summary all` |
| QEMU 冒烟（SMP=1） | 9 个用户程序失败，约 3.5 分钟 | 全部 PASS，24 s | `tools/qemu_smoke.sh 1` |
| QEMU 冒烟（SMP=2） | — | 全部 PASS，27 s | `tools/qemu_smoke.sh 2` |
| `nanosleep({-1,0})` | 内核整数溢出 panic | `-EINVAL` | `hello102` |
| 300 ms 自旋后 `getrusage` cpu_us / 存活 us | 534 679 885 / 502 550 | 301 528 / 301 750 | `hello102` |
| 用户态 `sgdt/sidt/sldt/smsw/str` | 退出码 0（泄漏内核地址） | #GP，状态 141 | `hello103` |
| 同 CPU futex 唤醒 SCHED_FIFO 延迟 | 最大 ≈ 200 000 µs | SMP=1 最大 554 µs / SMP=2 最大 480 µs | `hello104` |
| futex 20 ms 超时的平均超出量 | ≈ 217 ms | 6.7 ms / 8.0 ms | `hello105` |
| epoll 20 ms 超时的平均超出量 | ≈ 243 ms | 6.5 ms / 7.6 ms | `hello105` |
| RR 两子进程共享 CPU | （修 R1 后）一方饿死 | 双方均观察到对方进展 | `hello44` |
| 屏幕已满时整行 `write(1)` 延迟 | 最大 365 750 µs，平均 126 163 µs | SMP=1 最大 460 µs，平均 272 µs；SMP=2 最大 788 µs，平均 437 µs | `hello106` |

剩余约 6 ms 的超出量来自 100 Hz tick 粒度（扫描在 tick 边界进行，平均落后半个 tick
加一次调度）；高精度单次定时器（LAPIC TSC-deadline 按最早截止时间编程）列在 P3 路线。

## 8. 第二轮：P3 路线落地（2026-10）

方法与第一轮相同：每项先写纯策略 / 数据结构模块的 host 测试（RED），再接入内核
（GREEN），再用 QEMU 验收程序（`hello107` 起）覆盖真实路径，最后跑全部门禁
（host 测试、riscv64/aarch64/x86_64 构建、SMP=1/2 冒烟）后按项提交。
测试集中在 `tests/rt_round2_test.zig`。

### 8.1 公平 ticket 自旋锁

问题：`IrqSpinlock`、`ServicingSpinlock`（`vm_lock`）和 `TlbLock` 都是 test-and-set，
争用时谁的 Xchg 先到缓存行谁赢——没有排队，某个 CPU 可以被无限期饿死，锁等待
时间没有上界，RT 抖动无法界定。

设计：纯核心 `kernel/sync/ticket_lock.zig`（`next`/`serving` 两个 32 位回绕计数，
空闲 ⇔ 相等）。三个锁只是外壳：先关中断再取号，等待回调分别是 `pause` 和
“处理 shootdown + `pause`”。`tryLock` 只在空闲时对 `next` 做一次 CAS，不会插队；
`unlock` 只由持有者执行（load + release store，不会向 `next` 进位），Debug 构建
断言不会释放未持有的锁。API 不变，151 处调用点无需修改。

验证：
- host（RED：模块不存在 → GREEN）：FIFO 交接模型、`tryLock` 不插队、计数回绕、
  4 线程 × 2 万次非原子计数互斥、真实线程按到达顺序获得锁（50 轮）。
- `hello107`：主任务与 CLONE_VM 线程（SMP≥2 时分别钉在 CPU0/1）在 400 ms 窗口内
  并发 mmap / 缺页 / mprotect / munmap（vm_lock + TLB shootdown）、futex、
  sched_yield；检查页内容、双方进度比 ≥ 1/4、SMP≥2 时单次迭代 ≤ 30 ms。
  旧 TAS 内核在 QEMU/TCG 下同样通过（两次：846/855、942/938 次迭代，最大 1.3 ms）——
  两个模拟 CPU 不足以复现饿死，所以 `hello107` 是 SMP 压力回归门禁，公平性本身
  由 host 测试证明。新内核：SMP=2 863/871 次，最大 1.7 ms；SMP=1 629/625 次。

### 8.2 僵尸回收移出中断

问题：`reapZombies` / waitpid 在 `task_lock` + IRQ-off 下走完地址空间、驱动清理和内核栈
释放，QEMU 下一次 7–15 ms，BSP 上任何优先级的任务都跑不了。死掉的非 leader 线程还占着
槽位直到整个进程组退出，64 槽任务表会被 64 次 `clone` 耗尽。

设计：纯模块 `reap_policy.zig` 把“可否摘链”和“谁来收”从 teardown 里拆出来。
`reapZombies` / waitpid 只做 O(1) `detach`（置 `reap_pending`、断开 parent、入队）；
`proc/reaper.zig` 内核线程（钉在 CPU0、SCHED_FIFO 优先级 1）在开中断、不持 `task_lock`
的情况下 `teardownDetached`。waitpid 在 `finishReap` 里等到 teardown 完成，观察语义不变。
`pickReadyForCpu` 的槽扫描抽成 `sched_policy.SlotCursor`，满表 + 非 0 起点不再把移位计数
溢出成 panic。

验证：host 决策/队列/SlotCursor 测试；`hello108`：SCHED_FIFO 任务在孤儿退出窗口的时钟
间隙 ≤ 4 ms，128 MB 匿名页仍被回收，连续 100 个 CLONE_THREAD 都能创建。
SMP=1 回收窗口最大间隙 553 µs；SMP=2 451 µs；100/100 线程。

### 8.3 迟到 reschedule IPI 去重

问题：每次 `notifyWake` 都 `sendIpi`，已经在路上的 IPI 再来一次只会切掉 OTHER 当前任务
多剩的时间片。

设计：`ipi_kick_policy` + 每 CPU `resched_pending`。kick 时 Xchg 置位，已为 1 则不发；
IPI 通道入口清掉，下一次 kick 可以再发。

### 8.4 RT 带宽限流

问题：空转的 SCHED_FIFO 可以永远占着 CPU。POSIX RR 在没有同级 peer 时时间片到期本就该
把 CPU 交给更低优先级（hello44 的 OTHER 父进程靠这个 fork 出第二个 RR 子进程），所以
“RR 绝不让给 OTHER”不能做——在 QEMU 上 40 轮 RR 忙等短于 1 s 限流窗口，父进程来不及 fork。

设计：`rt_bandwidth_policy.Bucket` 每 CPU 每 100 个硬件 tick 允许 RT 跑 95 tick（Linux
默认 95%）；FIFO 的 keep-CPU 还要 `mayKeep(!throttled, rank_keeps)`。RR 保持 POSIX：
同级轮转，没有同级则让给更低优先级。

### 8.5 SMAP

`copy_from_user` / `copy_to_user` 早已用 `userAccessBegin/End` 括住拷贝。
`cpu_protect_policy.cr4Bits` 现在在 CPUID 报告 SMAP 时置 CR4.SMAP；`stac`/`clac` 在
x86 `paging.userAccessBegin/End`；syscall `SFMASK` 加 AC 位（0x40700）；`interruptDispatch`
入口 `clac`，嵌套中断不会顶着 AC=1 跑内核。QEMU 默认 `qemu64,+smep,+umip,+smap`。
冒烟要求 `[CPU] SMEP on UMIP on SMAP on`。

### 8.6 截止时间策略（未接 LAPIC）

`deadline_timer_policy.nextDeadlineTsc`：取剩余时间片与可选 wait deadline 的较早者。
内核仍用 100 Hz 周期时钟；要接到 LAPIC TSC-deadline，需要各等待子系统导出“下一个截止
时间”的全局最小值。

### 8.7 本轮结果

| 指标 | 修复前 | 修复后 | 证据 |
|---|---|---|---|
| host 测试 | 378 | 393/393 | `zig build test` |
| 冒烟 SMP=1 / 2 | — | 全部 PASS，约 26 s | `qemu_smoke.sh` 1 和 2 |
| CR4 | SMEP+UMIP | +SMAP | `[CPU] SMEP on UMIP on SMAP on` |
| FIFO 任务看孤儿回收的最大时钟间隙 | 数毫秒级 IRQ-off | 553 / 451 µs | `hello108` |
| 连续 CLONE_THREAD | 槽位耗尽（&lt;64） | 100/100 | `hello108` |
| hello44 RR 共享 | — | PASS（POSIX RR，不做“不让给 OTHER”） | `hello44` |
