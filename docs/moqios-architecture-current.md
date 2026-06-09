# MoQiOS 当前实现架构

> **版本**: v0.16.6
> **日期**: 2026-05-29
> **代码统计**: 内核 30,260 行 Zig / 121 源文件，用户空间 2,244 行 C/ASM
>
> **注意**: 本文档描述 MoQiOS 的**当前实际实现状态**，不是设计目标。
> 长期设计目标请参见 [moqios-design.md](./moqios-design.md)。

---

## 1. 概述

MoQiOS 是一个运行在 x86_64 架构上的**单体内核** (Monolithic Kernel)，使用 Zig 0.16.0 编写，
通过 Limine 引导协议启动，利用 HHDM (Higher-Half Direct Map) 进行内核地址空间映射。

### 关键技术参数

| 项目 | 值 |
|---|---|
| 目标架构 | x86_64 (freestanding) |
| 编译工具链 | Zig 0.16.0, code_model=kernel |
| 引导协议 | Limine Boot Protocol |
| 地址空间模型 | HHDM (Higher-Half Direct Map) |
| 最大进程数 | 64 (MAX_TASKS) |
| 内核栈大小 | 16 页 = 64KB (KERNEL_STACK_PAGES) |
| 用户代码段基址 | 0x00400000 (4MB) |
| 用户栈顶 | 0x00800000 (8MB) |
| 系统调用数量 | 432 (293 独立函数, ENOSYS ~14) |
| 文件系统 | FAT32 + ext2 + tmpfs + procfs + ramdisk + 统一页缓存 |
| 网络设备 | e1000 (中断驱动) + virtio-net (Virtqueue) |
| 内核代码量 | 32,866 行 Zig / 81 文件 |
| 用户代码量 | 2,244 行 C/ASM |

---

## 1.5 引导稳定性修复与已知限制（2026-06 review）

一次完整 review 中发现并修复了若干会导致**内核无法启动**或健壮性不足的缺陷（见下表），随后又
连续查明并修复了三个相互掩盖的深层根因：**TSS 布局错位**（用户态硬件中断投递从未工作，详见
**1.7 节**）、**ext2 inode 越界**（256B 磁盘 inode 写入 128B 结构体）、**中断 stub 寄存器破坏**
（被中断代码 RAX/RCX 遭污染，详见 **1.8 节**）。三者全部修复后，系统首次**完整启动至交互式
`MoQiOS shell`**，依次跑通 `init` + `hello2`–`hello28` 全部用户态测试（含用户态被定时器抢占、
ext2 多级目录读写删，QEMU 串口验证，零异常、零三重故障）。

### 已修复缺陷

| # | 位置 | 问题 | 修复 |
|---|---|---|---|
| 1 | `kernel/smp.zig` | AP（应用处理器）启动后在 `apEntry` 访问 LAPIC MMIO 崩溃，导致 BSP 在 `smp.init()` 内卡死、整机引导卡住 | 先增加 `enable_ap_startup` 开关（默认 `false`）以单处理器模式运行保证可用；LAPIC-on-AP 崩溃根因已查明并修复，详见下文 **1.6 节** |
| 2 | `kernel/proc/task.zig` `allocKernelStack` | 多页内核栈通过 `mapPage` 重映射 HHDM 地址，但 Limine 用大页映射 HHDM，`mapPage`/`ensureTable` 无法下钻大页，导致把假页表写进大页数据帧、破坏内核内存 | 改用 `pmm.allocContiguous` 分配连续物理页，直接返回其 HHDM 基址（连续物理页在 HHDM 中天然连续且已映射，无需改页表） |
| 3 | `kernel/arch/x86_64/paging.zig` `ensureTable` | 遇到 present 的大页项时当作下一级页表返回基址，会静默破坏内存 | 大页项返回 `error.HugePagePresent`，让调用方显式失败而非破坏地址空间 |
| 4 | `kernel/proc/task.zig` + `kernel/fs/vfs.zig` | `Task` 结构体约 62KB（每 fd 内联 readahead 缓存 + env/cwd 缓冲），存于 `?Task` 数组时编译器在内核栈上物化整份 `Task` 临时变量，溢出引导栈触发三重故障 | 任务表改为非可选 `[MAX_TASKS]Task`（占用由已有 `slot_bitmap` 跟踪），就地 `@memset`+逐字段构建，绝不在栈上复制整份 Task；`FdTable.init()` 改用 comptime 默认常量，避免 57KB 栈局部 |
| 5 | `kernel/mm/copy_from_user.zig` | `copyFromUser`/`copyToUser` 仅做地址范围校验便直接 `@memcpy`，用户态传入未映射但范围合法的指针会在内核态触发缺页并使整机崩溃（代码原有 TODO 已坦承缺少缺页恢复） | 访问前遍历用户页表，校验每个目标页 present 且 user 可访问，否则返回 0（EFAULT 语义），不再崩溃 |

> 配套修正：`user/hello13.c` 之前用 `syscall2` 调用 `sigaction`，第三参数 `oldact_ptr` 为未初始化
> 垃圾值，并把 handler 地址直接当 `struct sigaction` 指针传入。已改为传入正确的结构体指针与
> `oldact=0`。

### 已知限制 / 待办

- **SMP 暂为单处理器模式**：`smp.enable_ap_startup = false`。LAPIC-on-AP 崩溃根因已查明并修复
  （见 **1.6 节**），但完整启用仍受更深层问题门控；当前所有逻辑运行于 BSP，功能完整。
- **用户指针缺页恢复**：已通过"访问前页表校验"避免内核崩溃，但仍非真正的 per-instruction
  缺页恢复（RIP fixup）。对 COW 只读页的内核态写入依赖缺页处理器支持。
- ~~**ext2 多级目录写内存破坏**~~（**已修复**）：根因是 ext2 inode 越界与中断 stub 寄存器破坏
  两个相互叠加的 bug，已分别修复，`hello21`/`hello24`/`hello25` 全部通过，系统抵达 shell。
  详见 **1.8 节**。
- **大量未接入源文件**：`kernel/` 下有数十个新增 `.zig`（如 `mm/mprotect.zig`、`proc/clone.zig`、
  `ipc/sysv_*.zig`、`fs/select.zig` 等）未被任何模块 `@import`，因此不会被编译/检查，属未集成
  脚手架，详见构建文档。
- **`zig build test` 为空操作**：`tests/main.zig` 仅对空文件做 `refAllDecls`，未导入内核模块。
  现有"测试"实为 QEMU 中运行的 `hello*` 运行时测试。

---

## 1.6 SMP / AP 启动：LAPIC-on-AP 崩溃根因与修复（2026-06）

### 根因（已查明）

AP trampoline 进入长模式时只设置了 `EFER.LME`（bit 8），**漏设 `EFER.NXE`（bit 11）**。x86-64 规则：
当 `EFER.NXE = 0` 时，页表项的 bit 63（NX/No-Execute）属于**保留位且必须为 0**。内核页表对不可
执行页（如 LAPIC MMIO 映射 `no_execute=true`、HHDM 等）都置了 NX 位。于是：

- BSP 在启动早期已设置 NXE，访问这些页正常；
- AP 冷 TLB 首次 walk 到任一带 NX 位的页表项时，bit 63 被当作保留位 → **保留位缺页（#PF，错误码
  bit3=RSVD）** → 缺页处理本身又触发 → **#DF → Triple fault**。

QEMU `-d int` 决定性证据：AP 故障 `CR2=0xffff8000fee000f0`（LAPIC SVR 的 HHDM 地址），故障 PD 项
`e2=0x80000000fee001fb`（bit 63 NX=1），AP `EFER=0x500`（仅 LME|LMA，**无 NXE**）。
"页表是否映射"软件检查返回 Y（`isPageMapped` 不校验保留位），印证 BSP 靠 TLB 命中从不重 walk、
AP 冷 walk 才暴露。

> 此前模块注释中"LAPIC MMIO access crashes on AP，根因未知"的猜测就此澄清——与 HHDM 映射本身
> 无关，纯粹是 AP 的 EFER.NXE 未启用。

### 修复（已实现）

1. `kernel/arch/x86_64/ap_trampoline_src.S`：启用长模式时 `EFER` 同时置 LME 与 **NXE**
   （`or $((1<<8)|(1<<11)), %eax`）。
2. `kernel/smp.zig` `apEntry`：补上 **`idt.loadOnThisCpu()`**（每个 CPU 必须各自 `lidt` 共享 IDT，
   否则首个异常/中断即三重故障——这是 NXE 之后的下一个必然崩溃点）。
3. AP 仅启用 LAPIC 而**不开定时器**（`lapic.enableApNoTimer()`），并进入 `sched.apParkLoop()`
   安全驻留，**不参与调度**——因为现调度器使用 BSP 全局状态（`current_idx` 等）且 TSS 绑定 BSP，
   尚不能在 AP 上跑用户任务。

修复后实测：AP 稳定走完 `BCDEFGHIJ` 标记 → `[SMP] AP 1 initialized` → `[SMP] 2 CPUs online`，
不再崩在 LAPIC 访问。

### SMP 当前状态（2026-06，M8 进行中）

历史阻塞点（TSS 错位、中断 stub 寄存器破坏、调度器全局状态）均已修复。**`enable_ap_startup=true`**，
`-smp 2` 下 AP 稳定上线并参与 timerTick。M8-5b-2b（2026-06-07）：用户任务暂绑 BSP 以保证
`MOQI_SMP=2` 全量 init 稳定到 shell；AP 基础设施（APIC id、IPI reschedule、`wait_cpu` 跨核唤醒）
已就绪。round-robin 亲和 + AP ELF 并行（M8-5b-2c）为下一项。

| 子里程碑 | 状态 | 说明 |
|---|---|---|
| M8-1 | ✅ | 通用 IPI + reschedule/TLB-shootdown 向量 |
| M8-2~M8-4 | ✅ | per-CPU 运行任务/时间片/anchor/TSS RSP0 |
| M8-5a | ✅ | AP 上线 + 定时器，BSP-only 调度 |
| M8-5b-0 | ✅ | AP 高半区执行（trampoline 直跳 HHDM `apEntry`） |
| M8-5b-1 | ✅ | `exec_result` 迁入 `PerCpu`（`%%gs:48/56/64`） |
| M8-5b-2a | ✅ | AP commonStub 用户入口 + 跨核 IPI/`waitpid` 可见性 |
| M8-5b-2b | ✅ | APIC id、`wait_cpu`/`kickChildCpus`；用户暂绑 BSP |
| M8-5b-2d | ✅ | `Task.saved_user_rsp` + 上下文切换同步；3/3 `MOQI_SMP=2`→shell |
| M8-5b-2e | ⬜ | flat round-robin@AP |
| M8-5b-3 | ⬜ | FPU/SSE 按任务 |
| M8-6 | ⬜ | 范围 TLB shootdown |
| M8-7 | ⬜ | per-CPU 运行队列 + work-stealing |

详见 `docs/cross-arch-port-plan.md` M8 节。

> 复现/诊断辅助：`tools/qemu_run.sh` 现支持 `MOQI_SERIAL`（串口目标）、`MOQI_SMP`（核数）、
> `MOQI_EXTRA_QEMU`（如 `-d int,cpu_reset -D /tmp/qint.log`）三个环境变量覆盖。

---

## 1.7 TSS 布局错位：用户态硬件中断投递从未工作（2026-06，根因+修复）

### 症状

单核模式下，系统稳定跑过 `hello2`–`hello25`，但一到 **`hello26`（TCP echo server）** 必然
**三重故障**（QEMU `-d int` 显示 `#SS → #DF → Triple fault`，故障用户 RIP 落在 hello26 的
`delay(500000)` 忙等循环内）。

### 决定性诊断

用 `-d int,cpu_reset` 统计整个启动期的中断特权级分布：

| 中断来源 | 计数 | 结果 |
|---|---|---|
| LAPIC 定时器，`cpl=0`（内核态：syscall / idle 期间） | 156 | 全部正常 |
| LAPIC 定时器，`cpl=3`（**纯用户态**） | **1** | **立即 #SS → #DF → Triple** |

即：**整个内核从未成功投递过一次"用户态硬件中断"**。此前所有中断都恰好发生在内核态
（syscall 用 `SYSCALL`/MSR 切栈、走 `PerCpu.kernel_rsp`，**不读 TSS**；只有 `cpl=3→0` 的硬件中断
才需要 CPU 从 **TSS.RSP0** 加载内核栈并压栈）。`hello26` 是第一个长时间纯用户态忙等的程序，于是
成为第一个真正触发"用户态被定时器中断"的程序，立刻暴露此前从未走通的代码路径。

`#SS`（错误码 0）= 中断投递时 CPU 从 TSS 加载的 RSP/IST 是**非规范地址**。但代码里 `setRsp0` 写入的
是合法 canonical 的 HHDM 内核栈顶，且校验显示 TSS、IST、内核栈在用户页表中**均已映射**——矛盾点
指向"CPU 从 TSS 读到的值"与"我们写入的值"不一致。

### 根因

```zig
// 错误：extern struct
const Tss = extern struct {
    reserved0: u32,   // offset 0
    rsp0: u64,        // C ABI 把 u64 对齐到 8 → 实际落在 offset 8（offset 4-7 被填充）
    ...
};
```

x86-64 的 64 位 TSS 要求 **RSP0 位于字节偏移 4**（紧跟一个 u32），即所有 u64 栈指针是
**4 字节对齐而非 8 字节对齐**。`extern struct` 遵循 C ABI，会在 `reserved0:u32` 后插入 4 字节填充
把 `rsp0` 对齐到 offset 8，**导致 RSP0/RSP1/RSP2 与全部 IST 项整体后移 4 字节**。

后果：CPU 在 offset 4 读 RSP0 时，取到 `[4 字节填充][rsp0 低 32 位]` 拼成的**错位垃圾值**
（高位非符号扩展 → 非规范）→ 用户态中断投递切栈即 `#SS`；投递 `#SS` 仍读错位 IST/RSP0 → 再次
`#SS` → `#DF` → 三重故障。

旁证：修复前硬件 TSS 描述符 `limit=0x6f=111`（即 `@sizeOf(Tss)=112`），而正确的 64 位 TSS 应为
**104 字节**——多出的 8 字节正是对齐填充，坐实布局被破坏。

### 修复

`kernel/arch/x86_64/gdt.zig`：将 `Tss` 改为 **`packed struct`**（保证 `rsp0` 在 offset 4、无填充），
IST 项改用具名字段 `ist1..ist7`；TSS 描述符 limit 与 IOPB base 改用硬件常量 `TSS_HW_SIZE = 104`
（不再用可能被 packed 背景整数对齐放大的 `@sizeOf`）。

### 配套健壮性改进

- **IST 专用栈**（`gdt.zig`）：为 `#DF→IST1`、`#SS/#GP→IST2`、`NMI/#MC→IST3` 各配一段固定内核栈
  （`kernel/arch/x86_64/idt.zig` 的门按此设 `ist` 字段）。即使 RSP0 异常，关键异常也能在干净栈上
  投递、上报诊断，而非直接三重故障。
- **用户态 CPU 异常非致命**（`idt.zig` `handleException`）：源自用户态（`CS.RPL=3`）的 `#GP/#SS/#UD`
  等不再停机，改为打印后 `exitTask` 杀掉出错进程并重新调度（镜像既有 `#PF` segfault 路径）；仅
  内核态故障或 `#DF` 才停机。
- **内核态 `#PF` 栈回溯**（`idt.zig` `handlePageFault` 致命路径）：转储内核栈上形似返回地址的值
  （`0xffffffff8…`/`0xffff8000…`）以便 `llvm-addr2line` 还原调用链。
- **`setRsp0` 非规范检测**（`gdt.zig`）：写入非规范 RSP0 时打印告警，作为低成本安全网。

### 实测结果（单核）

- **零三重故障**；
- **63+ 个 `cpl=3`（用户态）定时器中断全部成功投递并返回**（修复前为 0）；
- `hello26`（TCP echo server，含多段 50 万次忙等）与 `hello27`（connect）**完整通过**；
- 用户态抢占式上下文切换（定时器在用户态触发→切到内核栈→调度→返回用户态）**首次真正可用**。

> 影响面：这是一个**长期潜伏**的根因。它意味着在本次修复前，任何被硬件中断打断于纯用户态的
> 程序都会三重故障——只是过去的测试程序大多 syscall 密集、几乎不在用户态停留足够久，才长期未被
> 触发。修复后用户态时间片抢占、（未来）信号在中断返回路径的投递等都获得正确基础。

### 修复后新暴露的独立问题（已在 1.8 节修复）

越过 `hello26` 后，`hello24`/`hello25`（ext2 目录写）会触发内核态控制流损坏与垃圾返回值
（`0xffffffff80033xxx`）。该现象由两个相互叠加的 bug 造成——**ext2 inode 越界**与**中断 stub
寄存器破坏**——均在 **1.8 节**查明并修复。

---

## 1.8 ext2 inode 越界 + 中断 stub 寄存器破坏（2026-06，根因+修复）

TSS 修复（1.7）越过 `hello26` 后，`hello24`/`hello25`（ext2 `create`/`write`/`unlink`，含多级
路径 `testdir/subfile.txt`）出现两类现象：(a) 内核态 `#PF`、控制流跳到垃圾地址，故障 RIP 在多次
运行间变化（非确定性内存破坏）；(b) 操作其实成功（如 `unlink` 已删文件）却返回垃圾值
`-2147272016 = 0xFFFFFFFF80033AB0`。排查发现是**两个独立 bug 叠加**。

### Bug A：ext2 inode 越界读写（`kernel/fs/ext2.zig`）

磁盘镜像为 ext2 rev1，**每个 inode 占 256 字节**（`s_inode_size=256`），但内核 `Ext2Inode`
结构体只建模 **128 字节**的基础 inode。`readInode`/`writeInode` 却用磁盘步长 `inode_size=256`
作为拷贝长度：

```zig
// 错误：把 256 字节写入 128 字节的栈上结构体 → 溢出 128 字节，砸毁调用方栈
@memcpy(@as([*]u8, @ptrCast(out))[0..inode_size], buf[offset_in_block..][0..inode_size]);
```

`readInode` 每次都把相邻 128 字节栈（保存的寄存器、返回地址、其它局部）覆盖；`writeInode`
则反向越界**读** 128 字节，把相邻栈泄漏写进磁盘 inode 表。破坏是否致命取决于各调用点栈布局，
故表现为非确定性，且在调用链最深、`Ext2Inode` 局部最多的目录写路径（`createFile`/`createDir`/
`unlinkFile`）集中爆发。

**修复**：拷贝长度钳制为 `@min(inode_size, @sizeOf(Ext2Inode))`，`inode_size` 仅用于计算磁盘内
偏移（步长）；写时只覆盖前 128 字节，**保留磁盘上扩展 inode 的后半部分**（read-modify-write）。

### Bug B：中断 stub 破坏被中断代码的 RAX/RCX（`kernel/arch/x86_64/idt.zig`）

垃圾返回值 `0xFFFFFFFF80033AB0` 经符号化恰为 **`idt.interruptDispatch` 函数自身的地址**。反汇编
`commonStub` 一眼看穿：

```asm
lea    0x72(%rip),%rax        # &interruptDispatch  ← "r" 输入被提前物化进 RAX
push   %rax                   # ← 把 &interruptDispatch 当作"被中断的 RAX"保存！
push   %rbx
...
```

`commonStub` 用 `[handler] "r" (handler)`、`[anchor] "r" (anchor)` 传地址，编译器在 asm 模板
**执行前**就把它们 `lea` 进 RAX/RCX——而这正发生在 `pushq %%rax` 保存被中断寄存器**之前**。于是
被中断代码的 RAX 被存成 `&interruptDispatch`、RCX 被存成 `&saved_stack_anchor`，恢复时原样写回。
同样的隐患还藏在每向量 stub `makeStub` 的 `jmp *%[stub]`（`&commonStub` 提前进 GPR）。

后果：**任何被硬件中断打断的内核代码，其 RAX/RCX 都被悄悄篡改**。这是又一个被 TSS bug 长期
掩盖的隐患——此前用户态中断从不投递、且内核 idle 循环不在意 RAX；TSS 修复后定时器开始在
syscall 执行期间触发，于是 ext2 syscall 的返回值 RAX 被改成 `&interruptDispatch` 泄漏给用户。

**修复**（仿 `syscallEntry` 既有正确写法）：

1. `commonStub`：**先**压栈全部 GPR，**再**经 RIP 相对加载 handler 与 anchor——
   `leaq saved_stack_anchor(%rip), %r12`、`call *interrupt_handler_ptr(%rip)`，彻底取消 `"r"` 输入。
   新增 `export var interrupt_handler_ptr`（C 链接）指向 `interruptDispatch`；
   `sched.saved_stack_anchor` 改 `pub export var` 以便跨模块 RIP 相对引用。
2. `makeStub`：`jmp *%[stub]` 改为直接 `jmp commonStub`（`commonStub` 为 `export fn`，RIP 相对
   相对跳转，PIC 安全），不再经寄存器。

修复后反汇编确认 `commonStub` 首条即 `push %rax`（真实被中断 RAX）、向量 stub 为
`push $0; push $vec; jmp commonStub`，零寄存器破坏。

### 实测结果（单核）

修复 A+B 后系统**首次完整启动至 `MoQiOS shell`**：

- `hello21`（ext2 写）：`create=3 write=22`，回读校验 `verify=1`；
- `hello24`（ext2 unlink）：`unlink=0`（不再是垃圾值）、`verify gone fd=-1`、**PASS**；
- `hello25`（ext2 多级路径 `testdir/subfile.txt`）：`create/write/reopen/unlink` 全部正确、**PASS**；
- 全程零 `EXCEPTION`、零 `PANIC`、零三重故障，`init` 跑完 `hello2`–`hello28` 后进入 shell。

> 经验：Zig `naked` 函数中**绝不能用 asm `"r"`/`"i"` 输入**传递在"保存现场"之前就需稳定的值——
> 编译器会把输入物化在模板首条指令之前。中断/syscall 入口一律改用"先保存 GPR，再 RIP 相对
> 引用 `export` 全局"的模式（`commonStub`、`syscallEntry` 现已统一遵循）。

---

## 2. 启动流程

```
QEMU / 真机
  │
  ├─ Limine Bootloader (BIOS/UEFI)
  │    ├─ 加载内核 ELF 至内存
  │    ├─ 设置 HHDM 映射
  │    └─ 跳转至 kernel_main
  │
  ├─ kernel_main() [kernel/main.zig]
  │    ├─ 解析 Limine 启动信息 (boot_info.zig)
  │    ├─ 初始化 GDT (gdt.zig) — 代码/数据/TSS 段
  │    ├─ 初始化 IDT (idt.zig) — 异常 + IRQ 中断
  │    ├─ 初始化串口 (serial.zig) — COM1 调试输出
  │    ├─ 初始化物理内存管理器 (pmm.zig)
  │    ├─ 初始化页表 (paging.zig)
  │    ├─ 初始化 TSC 时钟 (tsc.zig)
  │    ├─ 初始化键盘驱动 (keyboard.zig)
  │    ├─ 初始化 PCI 设备枚举 (pci.zig)
  │    ├─ 初始化 virtio-blk 块设备 (virtio_blk.zig)
  │    ├─ 初始化 FAT32 文件系统 (fat32.zig)
  │    ├─ 创建 ramdisk 设备 (ramdisk.zig)
  │    ├─ 创建内核线程: init 任务
  │    └─ 启动调度器 (sched.zig) — sti + hlt 循环
  │
  └─ init 任务 (内核线程)
       ├─ 延迟初始化网络模块 (net/mod.zig) — 不能在 boot 阶段初始化
       └─ 加载并执行 /init (user/init.S)
            ├─ 启动 hello3, hello4, hello5, hello7, hello8
            ├─ 启动 hello12, hello13, hello14, hello15, hello16
            ├─ 启动 hello9, hello10 (fork 测试)
            └─ 启动 shell (sh.c)
```

### 关键启动细节

- **HHDM**: Limine 在启动时将全部物理内存映射到高地址区域，内核通过 HHDM 偏移访问物理页
- **网络延迟初始化**: `net_mod.init()` 不能在 boot 阶段调用（会导致未解释的死锁），而是在第一个 init 内核线程中执行
- **init.S**: 用户空间第一个进程，通过 `spawn` 系统调用启动所有测试程序和 shell

---

## 3. 内存管理

### 3.1 物理内存管理 (PMM)

**源文件**: `kernel/mm/pmm.zig` (347 行)

- 基于位图的物理页帧分配器
- 从 Limine 提供的内存映射中获取可用物理页
- 提供 `allocPage()` / `freePage()` 接口
- 使用 HHDM 将物理地址转换为内核可访问的虚拟地址

### 3.2 虚拟内存 (分页)

**源文件**: `kernel/arch/x86_64/paging.zig`

- 4 级页表: PML4 → PDPT → PD → PT → Page
- 页表标志: Present, Read/Write, User/Supervisor, No-Execute
- `mapPage(pml4, virt, phys, flags)`: 映射单个虚拟页
- `unmapPage(pml4, virt)`: 取消映射
- COW fork 时使用写保护 (Read-Only + COW 标志)

### 3.3 用户地址空间

**源文件**: `kernel/mm/user_space.zig`

```
用户空间布局:
0x00400000 ───────────  代码段 (ELF 加载地址)
              │
              │  (brk/mmap 堆区域)
              │
0x00800000 ───────────  栈顶 (栈向下增长)
```

- **代码段**: 0x400000，ELF 程序头直接映射
- **栈**: 从 0x800000 向下增长，初始 4 页 (16KB)
- **brk**: 程序断点，通过 `brk()` 系统调用扩展
- **mmap**: 通过 `mmap()` 系统调用映射匿名内存

### 3.4 内核栈

每个任务分配 KERNEL_STACK_PAGES=16 页 (64KB) 内核栈。
64KB 是必要的，因为网络系统调用链中的缓冲区可达 2048 字节，
嵌套调用会超过 32KB 栈空间。

---

## 4. 进程管理

### 4.1 Task 结构体

**源文件**: `kernel/proc/task.zig` (464 行)

Task 结构体约 6000 字节，包含：

| 字段 | 类型 | 说明 |
|---|---|---|
| state | enum | ready / running / blocked / zombie |
| pid | u32 | 进程 ID |
| ppid | u32 | 父进程 ID |
| pml4 | u64 | 页表物理地址 |
| kernel_stack | u64 | 内核栈虚拟地址 |
| rsp0 | u64 | 内核栈顶 (TSS 用) |
| rip | u64 | 恢复执行地址 |
| rsp | u64 | 恢复时的栈指针 |
| rflags | u64 | 恢复时的标志寄存器 |
| fds | [32]?Fd | 文件描述符表 |
| brk_base | u64 | brk 基地址 |
| brk_current | u64 | 当前 brk 位置 |
| cwd | [256]u8 | 当前工作目录 |
| cwd_len | u32 | cwd 长度 |
| envp | ?[*:null]?[*:0]u8 | 环境变量数组 |
| env_count | u32 | 环境变量数量 |
| signal_handler | ?*const fn | 信号处理函数 |
| signal_mask | u64 | 信号掩码 |
| waiting_for_child | bool | 是否在等待子进程 |
| exit_status | u32 | 退出状态码 |

### 4.2 进程状态

```
                    spawn / fork
    [不存在] ──────────────────→ [ready]
                                    │
                          scheduler ──→ [running]
                                    │       │
                    preempt / yield │       │ exit
                                    │       ↓
                                    │   [zombie] ──→ waitpid ──→ [不存在]
                                    │
                          I/O wait  │
                                    ↓
                                [blocked]
                                    │
                          I/O done  │
                                    └──→ [ready]
```

### 4.3 进程创建

- **createKernelThread()**: 分配内核栈，设置入口函数，标记为 ready
- **createUserProcess()**: 分配用户地址空间，加载 ELF，构建用户栈 (argc/argv/envp/auxv)
- **fork()**: COW 克隆父进程地址空间，复制文件描述符表和环境变量，继承 cwd
- **execve()**: 替换进程地址空间，重新加载 ELF，重建用户栈

### 4.4 用户栈构建

**源文件**: `kernel/proc/loader.zig` (686 行)

`buildUserStack()` 构建如下栈布局：

```
低地址 ←─────────────────────────────── 高地址
│ ... │ envp[0] │ ... │ envp[n] │ NULL │
│ padding (可选，对齐用) │
│ argv[0] │ ... │ argv[n] │ NULL │
│ argc (8 bytes) │
│ auxv entries │
                        ← RSP (16 字节对齐)
```

关键：padding 位于 envp-NULL 和 argv-NULL 之间，
确保 RSP 在 argc 之前为 16 字节对齐。

---

## 5. 调度器

**源文件**: `kernel/proc/scheduler.zig`

- **算法**: O(1) 优先级位图调度器
- **优先级**: 32 级，每级一个双向链表
- **调度**: `pickNext() = @ctz(bitmap) + popFront() = O(1)`
- **Per-CPU 队列**: 每 CPU 独立优先级位图 + 队列
- **Work Stealing**: 空闲 CPU 从其他 CPU 队列尾部窃取任务
- **时间片**: 10 个 tick (100ms)，抢占式
- **上下文切换**: 通过 `switchContext` 汇编实现

### 调度流程

```
LAPIC Timer 中断
  │
  ├─ 保存当前任务寄存器
  ├─ 将当前任务标记为 ready
  ├─ pickNext(): O(1) 位图扫描
  ├─ 切换页表 (PML4) 如果需要
  ├─ 更新 TSS.rsp0
  └─ switchContext(new_task) → 恢复新任务寄存器
```

---

## 6. 系统调用

**源文件**: `kernel/arch/x86_64/syscall_entry.zig` (9691 行)

### 6.1 系统调用机制

- 使用 `syscall` / `sysret` 指令 (通过 MSR LSTAR 设置入口点)
- 用户态通过 `syscall` 指令进入内核，syscallDispatch 根据 rax 分发
- SyscallFrame 结构保存所有寄存器
- 返回值通过 rax 传递，错误通过 rax = -errno 表示

### 6.2 系统调用表 (263 个 dispatch, 220 个独立函数)

| 编号 | 名称 | 功能 |
|---|---|---|
| 0 | read | 读取文件描述符 |
| 1 | write | 写入文件描述符 |
| 2 | exit | 终止当前进程 |
| 3 | diag | 内核诊断 dump |
| 4 | getpid | 获取进程 ID |
| 5 | spawn | 创建新进程执行程序 |
| 6 | waitpid | 等待子进程退出 (阻塞式) |
| 7 | brk | 调整程序断点 |
| 8 | mmap | 映射内存 (匿名+文件 MAP_PRIVATE) |
| 9 | open | 打开文件 |
| 10 | mprotect | 修改内存保护属性 |
| 11 | close | 关闭文件描述符 |
| 12 | munmap | 取消内存映射 |
| 13 | sigaction | 设置信号处理函数 |
| 14 | sigprocmask | 修改信号掩码 |
| 15 | sigreturn | 从信号处理函数返回 |
| 16 | ioctl | 设备控制 |
| 17 | pread64 | 定位读取 (不修改fd offset) |
| 18 | pwrite64 | 定位写入 (不修改fd offset) |
| 19 | readv | 向量读取 (scatter I/O) |
| 20 | writev | 向量写入 (gather I/O) |
| 22 | pipe | 创建管道 |
| 27 | mincore | 查询页面是否在内存中 |
| 28 | madvise | 内存建议 (MADV_DONTNEED等) |
| 33 | dup2 | 复制文件描述符 |
| 35 | nanosleep | 高精度睡眠 |
| 40 | sendfile | 零拷贝文件传输 |
| 42 | connect | TCP连接 |
| 44 | sendto | 发送数据 |
| 46 | sendmsg | 发送消息 (msghdr+iov) |
| 47 | recvmsg | 接收消息 (msghdr+iov) |
| 48 | shutdown | 半关闭TCP连接 |
| 51 | getsockname | 获取本地socket地址 |
| 52 | getpeername | 获取远端socket地址 |
| 54 | setsockopt | 设置socket选项 |
| 55 | getsockopt | 获取socket选项 |
| 56 | clone | 克隆线程 (CLONE_VM/FILES/THREAD) |
| 57 | fork | 克隆当前进程 (COW) |
| 59 | execve | 执行新程序 |
| 62 | kill | 发送信号 |
| 63 | uname | 获取系统信息 |
| 72 | fcntl | 文件控制 |
| 73 | flock | 文件锁 |
| 74 | fsync | 同步文件数据到磁盘 |
| 75 | fdatasync | 同步数据到磁盘 |
| 79 | getcwd | 获取当前工作目录 |
| 96 | gettimeofday | 获取当前时间 |
| 100 | net_send | 发送原始网络帧 |
| 101 | net_recv | 接收原始网络帧 |
| 102 | udp_send | 发送 UDP 数据报 |
| 103 | udp_recv | 接收 UDP 数据报 |
| 104 | net_poll | 轮询网络事件 |
| 105 | getenv | 获取环境变量 |
| 106 | setenv | 设置环境变量 |
| 107 | listdir | 列出目录内容 |
| 108 | chdir | 改变工作目录 |
| 109 | setpgid | 设置进程组ID |
| 110 | fstat | 获取文件状态信息 |
| 111 | unlink | 删除文件 |
| 112 | setsid | 创建新会话 |
| 113 | tcp_send | TCP 发送数据 |
| 114 | tcp_recv | TCP 接收数据 |
| 115 | tcp_close | TCP 关闭连接 |
| 116 | tcp_poll | TCP 轮询事件 |
| 117 | socket | 创建 socket |
| 118 | bind | 绑定 socket 到端口 |
| 119 | listen | 监听连接 |
| 120 | accept | 接受连接 |
| 121 | getpgid | 获取进程组ID |
| 122 | recvfrom | 接收数据 |
| 123 | mkdir | 创建目录 |
| 124 | getsid | 获取会话ID |
| 140 | getpriority | 获取进程优先级 |
| 141 | setpriority | 设置进程优先级 |
| 202 | futex | 快速用户空间互斥锁 |
| 213 | epoll_create1 | 创建epoll实例 |
| 228 | clock_gettime | 获取高精度时间 |
| 230 | clock_nanosleep | 时钟睡眠 |
| 232 | epoll_wait | 等待epoll事件 |
| 233 | epoll_ctl | 控制epoll监视集 |
| 271 | poll | I/O多路复用 |
| 275 | splice | 管道数据拼接 |
| 283 | timerfd_create | 创建定时器fd |
| 286 | timerfd_settime | 设置定时器 |
| 287 | timerfd_gettime | 获取定时器 |
| 288 | accept4 | 接受连接 (带标志) |
| 290 | eventfd2 | 创建eventfd |
| 292 | dup3 | 复制fd (带O_CLOEXEC) |
| 293 | pipe2 | 创建管道 (带O_NONBLOCK/O_CLOEXEC) |
| 300 | tcp_connect | TCP socket连接 |
| 318 | getrandom | 获取随机数 |
| 158 | arch_prctl | 架构相关 (ARCH_SET_FS TLS) |
| 186 | gettid | 获取线程 ID |
| 217 | getdents64 | 目录枚举 |
| 257 | openat | 打开文件 (相对 dirfd) |
| 262 | newfstatat | 文件状态 (*at 版本) |
| 263 | unlinkat | 删除文件/目录 |
| 281 | epoll_pwait | epoll等待 (带信号掩码) |
| 302 | prlimit64 | 资源限制 (64位) |
| 309 | getcpu | 获取当前 CPU/NUMA 节点 |
| 400 | stat | 文件状态查询 |
| 401 | lstat | 文件状态 (不跟踪符号链接) |
| 402 | lseek | 文件定位 (SEEK_SET/CUR/END) |
| 403 | access | 检查文件可访问性 |
| 405 | sched_yield | 让出 CPU |
| 408 | wait4 | 等待子进程 (扩展) |
| 410 | ftruncate | 截断文件 (fd) |
| 413 | umask | 设置文件创建掩码 |
| 414 | getrlimit | 获取资源限制 |
| 416 | sysinfo | 系统信息 |
| 419 | getppid | 获取父进程 ID |
| 420 | getuid | 获取用户 ID |
| 421 | getgid | 获取组 ID |
| 422 | geteuid | 获取有效用户 ID |
| 423 | faccessat | 检查文件可访问 (*at) |

### 6.3 设计细节

- **write**: 支持三种 fd — stdout/stderr (VGA+串口), stdin (键盘), 文件 fd
- **fork**: COW 克隆地址空间，设置所有页为 Read-Only，缺页时才复制
- **execve**: 完全替换地址空间，释放旧页表，加载 ELF，构建新栈
- **waitpid**: 阻塞式等待，使用 WaitNode 睡眠唤醒机制
- **mmap**: 支持匿名映射 (MAP_ANONYMOUS) 和文件映射 (MAP_PRIVATE)
- **readv/writev**: scatter-gather I/O，复用 VFS read/write 路径
- **pread64/pwrite64**: 定位 I/O，不修改 fd offset
- **shutdown**: SHUT_RD/SHUT_WR/SHUT_RDWR，发送 FIN 半关闭 TCP
- **sendmsg/recvmsg**: 解析 msghdr，遍历 msg_iov 收发数据
- **madvise**: MADV_DONTNEED 释放物理页面，其他 advice 返回成功
- **fsync/fdatasync**: 调用 vfs.syncFile 刷新 dirty buffer 到磁盘
- **nanosleep**: 基于 TSC 的精确睡眠
- **dup3/pipe2**: 支持 O_CLOEXEC/O_NONBLOCK 标志
- **eventfd2**: 复用已有 eventfd 模块，支持 EFD_NONBLOCK/EFD_SEMAPHORE
- **lseek**: SEEK_SET/SEEK_CUR/SEEK_END 三种定位模式
- **stat/lstat**: 路径查询文件状态，填充 stat 缓冲区 (ino/mode/size)
- **openat/newfstatat/unlinkat**: *at() 系列 glibc 必备 syscall
- **getrlimit/prlimit64**: RLIMIT_NOFILE/STACK/AS 资源限制查询
- **arch_prctl**: ARCH_SET_FS 设置 TLS 基址 (wrmsr MSR_FS_BASE)
- **sysinfo**: 内存总量/空闲量查询 (PMM totalPages/freePages)
- **epoll_pwait**: 委托 epoll_wait，忽略信号掩码
- **setuid/setgid/setreuid/setregid/setresuid/setresgid/getresuid/getresgid**: 完整 POSIX 凭证模型 (uid/gid/euid/egid/suid/sgid)，fork/clone 继承，权限检查 (扩展号 450-457)
- **shmget/shmat/shmdt/shmctl**: SysV 共享内存，32 段上限，256 页/段，4 级页表映射，IPC_STAT/RMID/SET
- **semget/semop/semctl**: SysV 信号量，16 集上限，32 信号量/集，P/V 操作 (EAGAIN 非阻塞)
- **mount/umount2**: VFS 挂载表 (16 挂载点)，支持 tmpfs/ext2/vfat/proc/ramfs 类型
- **mq_open/unlink/timedsend/timedreceive/notify/getsetattr**: POSIX 消息队列，16 队列，环形缓冲区，优先级支持
- **recvmmsg/sendmmsg**: 批量消息收发，委托 sendmsg/recvmsg 实现
- **rt_tgsigqueueinfo**: 跨进程信号发送，委托 rt_sigqueueinfo
- **msgget/msgsnd/msgrcv/msgctl**: SysV 消息队列，16 队列，8 消息/队列，512 字节/消息，按类型过滤
- **io_setup/io_destroy/io_submit/io_getevents/io_cancel**: Linux AIO 基础，8 上下文，同步执行+完成事件队列

---

## 7. 文件系统

### 7.1 VFS 层

**源文件**: `kernel/fs/vfs.zig` (708 行)

虚拟文件系统抽象层，统一管理不同类型的文件：
- **ramdisk 文件**: 启动时从内核嵌入的 ramdisk 镜像加载
- **FAT32 文件**: 通过 virtio-blk 块设备访问
- **管道**: 进程间通信的环形缓冲区
- **设备文件**: stdin/stdout/stderr

文件描述符表 (fds) 每进程 32 个槽位。

### 7.2 FAT32 文件系统

**源文件**: `kernel/fs/fat32.zig` (771 行)

- 基于 virtio-blk 块设备驱动
- 支持: open, read, write, create, delete, stat, listdir
- `deleteFile()`: 标记目录项为 0xE5，遍历 FAT 簇链释放所有簇
- 缓存: 在内存中维护打开文件数组，避免频繁磁盘 I/O
- 路径解析: 支持绝对路径和相对路径 (相对于 cwd)

### 7.3 Ramdisk

**源文件**: `kernel/fs/ramdisk.zig`

- 启动时由 Limine 模块加载的内存文件系统
- 存储: init, hello2-hello18, shell 等用户程序
- 只读，用于存放可执行文件

### 7.4 块设备驱动

| 驱动 | 文件 | 行数 | 说明 |
|---|---|---|---|
| virtio-blk | kernel/drivers/virtio_blk.zig | 522 | 主存储设备 |
| AHCI | kernel/drivers/ahci.zig | 638 | SATA 控制器 (已实现，未为主要文件系统) |

---

## 8. 网络协议栈

**源文件**: `kernel/net/` 目录

### 8.1 网络层次

```
用户程序
  │
  ├─ syscall: socket/bind/listen/accept/connect/sendto/recvfrom/sendmsg/recvmsg/shutdown
  │
  ├─ TCP 层 (tcp.zig, 1630 行)
  │   ├─ Reno 拥塞控制 (慢启动/拥塞避免/快速重传/快速恢复)
  │   ├─ SACK 选择性确认 (RFC 2018)
  │   ├─ Window Scaling (RFC 7323, shift=7, 最大窗口4MB)
  │   ├─ Timestamps + PAWS (精确RTT测量)
  │   ├─ Keepalive + Nagle 算法
  │   ├─ 11 状态机 + TIME_WAIT 优化 (15s + TCB复用)
  │   └─ 8 并发连接, 8KB 收发缓冲
  │
  ├─ UDP 层 (udp.zig) — 端口复用，校验和计算
  ├─ ICMP 层 (icmp.zig) — Echo Reply 响应
  ├─ IPv4 层 (ipv4.zig) — 校验和，路由
  ├─ ARP 层 (arp.zig) — 地址解析缓存
  ├─ Ethernet 层 (eth.zig) — 帧封装
  │
  ├─ 网络接口层 (netif.zig) — 接口管理
  ├─ e1000 驱动 (drivers/e1000.zig, 453 行)
  │   ├─ 中断驱动模式 (INTx + IMASK/ICR + IRQ handler)
  │   ├─ TX/RX 描述符环
  │   └─ DMA 缓冲区管理
  └─ virtio-net 驱动 (drivers/virtio_net.zig, 548 行)
       ├─ Virtqueue RX/TX 队列 (各128描述符)
       ├─ 中断驱动接收
       └─ Legacy virtio PCI
```

### 8.2 e1000 驱动关键点

- 中断驱动模式: 启用 INTx，配置 IMASK (RXT0/RXO/TXQE/TXDW/LSC)
- IRQ handler: 读取 ICR 清除 pending，循环处理 RX 队列
- IDt 中注册 IRQ 分发，动态读取 PCI IRQ line
- 保留轮询 fallback (兼容无中断环境)

### 8.3 virtio-net 驱动

- Virtio 1.0 Legacy PCI 接口
- RX 队列 (queue 0): 128 描述符，中断驱动
- TX 队列 (queue 1): 128 描述符，同步发送
- virtio_net_hdr: 10 字节头部 (flags, gso_type, checksum)
- 中断处理: ISR 读取 + 清除，调用 net.handleRxPacket

### 8.4 TCP 增强特性

- **SACK (RFC 2018)**: SYN 阶段协商 SACK-Permitted；接收端记录乱序段，ACK 附带最多 4 个 SACK 块；发送端记分板跟踪已 SACK 段，dupACK 触发选择性重传仅丢失段
- **Window Scaling**: shift=7，最大窗口 4MB，突破 64KB 限制
- **Timestamps + PAWS**: 精确 RTT 测量，防止序列号环绕误判
- **TIME_WAIT 优化**: 30s→15s，新连接可复用 TIME_WAIT TCB (若序号更大)

---

## 9. 信号处理

**源文件**: `kernel/proc/signal.zig` (199 行)

- 支持信号: SIGINT (2), SIGILL (4), SIGFPE (8), SIGKILL (9), SIGSEGV (11), SIGTERM (15), SIGUSR1 (10), SIGUSR2 (12), SIGPIPE (13), SIGCHLD (20) 等
- `sigaction()`: 注册信号处理函数
- `sigprocmask()`: 阻塞/解除阻塞信号
- `sigreturn()`: 从信号处理函数返回，恢复原始上下文
- `kill()`: 向指定进程发送信号
- **Ctrl+C**: 键盘中断处理中检测，向前台进程发送 SIGINT
- **信号投递**: 仅在 `waitpid` 系统调用返回时检查 (`checkSignalsOnSyscallReturn`)

---

## 10. 管道与 I/O

**源文件**: `kernel/ipc/ipc.zig` (443 行)

- `pipe()`: 创建一对文件描述符 (读端 + 写端)
- 内部使用环形缓冲区 (4096 字节)
- `dup2()`: 复制文件描述符，用于 I/O 重定向
- Shell 使用管道连接进程: `cmd1 | cmd2`

---

## 11. 用户空间

### 11.1 init 进程

**源文件**: `user/init.S` (~540 行)

启动时第一个用户进程，按顺序 spawn:
- hello3 (ramdisk 读写) x2
- hello4 (多进程)
- hello5 (ELF 加载验证)
- hello7 (FAT32 写入) x2
- hello8 (网络 ARP)
- hello12 (信号处理)
- hello13 (UDP 网络)
- hello14 (环境变量)
- hello15 (fork+信号)
- hello16 (execve)
- hello9 (fork) x2
- hello10 (execve+pipe) x2
- shell

共 18 个输出检查点，全部稳定通过。

### 11.2 测试程序

| 程序 | 测试内容 |
|---|---|
| hello2 | 基本串口输出 |
| hello3 | ramdisk 文件读写 |
| hello4 | 多进程 spawn |
| hello5 | ELF 加载 + 参数传递 |
| hello7 | FAT32 文件创建/写入 |
| hello8 | 网络 ARP 请求 |
| hello9 | fork 系统调用 |
| hello10 | execve + 管道 |
| hello12 | 信号处理 (sigaction/sigreturn) |
| hello13 | UDP 收发 |
| hello14 | 环境变量 (getenv/setenv) |
| hello15 | fork + 信号传递 |
| hello16 | execve + argv |
| hello17 | fork+execve 自身 + argv 验证 + uname |
| hello18 | chdir/getcwd/fstat |

注: hello17 和 hello18 位于 ramdisk 中但不包含在 init.S 自动测试中
(加入后导致其他测试间歇性挂起，原因疑为调度器时序敏感)。

### 11.3 Shell

**源文件**: `user/sh.c` (~460 行)

交互式命令行 Shell，支持:
- 基本命令执行 (从 ramdisk/FAT32 加载程序)
- `cd [path]` — 改变工作目录
- `pwd` — 显示当前工作目录
- `ls` — 列出目录内容
- `echo` — 输出文本
- `export VAR=val` — 设置环境变量
- `env` — 显示所有环境变量
- 管道: `cmd1 | cmd2`
- Ctrl+C 中断

---

## 12. 中断与异常

**源文件**: `kernel/arch/x86_64/idt.zig` (553 行)

- IDT 设置: 异常 (0-31) + IRQ (32-47) + 系统调用 (0x80)
- 键盘 IRQ1: 读取扫描码，检测 Ctrl+C 发送 SIGINT
- 定时器 IRQ0: 触发调度器时间片轮转
- 异常处理: 缺页 (#PF) 用于 COW，通用保护错误 (#GP) 输出诊断信息

---

## 13. 内核模块依赖图

```
kernel/main.zig
  ├── arch/x86_64/
  │   ├── gdt.zig          — GDT/TSS 设置 (Per-CPU)
  │   ├── idt.zig          — IDT/中断处理 + e1000/virtio-net IRQ分发
  │   ├── paging.zig       — 页表管理 + getPagePhysAddr
  │   └── syscall_entry.zig — 系统调用入口 + 240 个处理函数 + COW fork
  │   ├── tsc.zig          — TSC 时钟
  │   └── exception.zig    — 异常处理器
  │
  ├── mm/
  │   ├── pmm.zig          — 物理内存分配器 (两级位图)
  │   ├── slab.zig         — Slab 分配器
  │   ├── user_space.zig   — 用户地址空间常量
  │   ├── addr_space.zig   — COW 地址空间克隆
  │   ├── swap.zig         — Swap 页面置换 (Clock算法)
  │   └── copy_from_user.zig — 用户空间安全访问
  │
  ├── proc/
  │   ├── task.zig         — Task 结构体 + 进程管理
  │   ├── scheduler.zig    — O(1) 位图调度器 + Work Stealing
  │   ├── loader.zig       — ELF 加载器 + 栈构建
  │   └── signal.zig       — 信号投递
  │
  ├── fs/
  │   ├── vfs.zig          — 虚拟文件系统 + syncFile
  │   ├── fat32.zig        — FAT32 实现
  │   ├── ext2.zig         — ext2 实现
  │   ├── tmpfs.zig        — 内存文件系统
  │   ├── procfs.zig       — 进程文件系统 (11种虚拟文件)
  │   ├── ramdisk.zig      — ramdisk 设备
  │   ├── eventfd.zig      — eventfd 事件通知
  │   ├── writeback.zig    — 写回缓存
  │   └── page_cache.zig   — 统一页缓存
  │
  ├── drivers/
  │   ├── pci.zig          — PCI 配置空间枚举
  │   ├── virtio_blk.zig   — virtio 块设备
  │   ├── virtio_net.zig   — virtio-net 网卡 (548行)
  │   ├── ahci.zig         — AHCI/SATA
  │   ├── nvme.zig         — NVMe SSD
  │   ├── e1000.zig        — e1000 网卡 (中断驱动)
  │   └── keyboard.zig     — PS/2 键盘
  │
  ├── net/
  │   ├── mod.zig          — 网络模块初始化
  │   ├── netif.zig        — 网络接口
  │   ├── eth.zig          — Ethernet 帧
  │   ├── arp.zig          — ARP 协议
  │   ├── ipv4.zig         — IPv4 协议
  │   ├── icmp.zig         — ICMP 协议
  │   ├── udp.zig          — UDP 协议
  │   ├── tcp.zig          — TCP 协议 (1630行, Reno/SACK/WS/TS)
  │   ├── socket.zig       — Socket 抽象层
  │   └── dhcp.zig / dns.zig — DHCP/DNS 客户端
  │
  ├── sync/
  │   ├── irq_spinlock.zig — 中断自旋锁
  │   ├── ticket_spinlock.zig — 公平自旋锁
  │   ├── mutex.zig        — 睡眠互斥锁
  │   ├── rwlock.zig       — 读写锁
  │   └── mpmc_queue.zig   — 无锁MPMC队列
  │
  └── ipc/
      ├── ipc.zig          — 消息传递 + 能力系统
      └── pipe.zig         — 管道实现
```

---

## 14. 已知限制

1. **AP 定时器**: AP 无 LAPIC 定时器中断 (QEMU TCG 限制)，需要 KVM 或真机
2. **调度器时序敏感**: 增加进程数量会导致其他进程间歇性挂起
3. **无安全模型**: 无用户权限、capability 等安全机制
4. **e1000/virtio-net 仅 QEMU**: 未测试真实硬件
5. **无 Windows 兼容**: 当前仅支持 Linux ELF 二进制格式
6. **无 IPv6**: 网络协议栈仅支持 IPv4
7. **TCP 连接数限制**: 最大 16 个并发 TCP 连接 (32K 发送/接收缓冲)
8. **无分片重组**: IPv4 不支持分片重组 (MTU 1500 单帧)

---

## 15. 源文件清单

### 内核源文件 (主要文件)

| 文件 | 行数 | 功能 |
|---|---|---|
| kernel/arch/x86_64/syscall_entry.zig | 7,082 | 系统调用入口 + 240 个处理函数 (薄 wrapper 模式) |
| kernel/net/tcp.zig | 1,630 | TCP 协议 (Reno/SACK/WS/TS) |
| kernel/fs/vfs.zig | 708 | 虚拟文件系统 + MAX_FDS=64 + procfs 路由 + inotify + allocFd |
| kernel/arch/x86_64/idt.zig | 672 | 中断描述符表 + IRQ 分发 + COW #PF 处理 |
| kernel/drivers/virtio_net.zig | 548 | virtio-net 网卡驱动 |
| kernel/drivers/e1000.zig | 453 | e1000 网卡驱动 (中断驱动) |
| kernel/main.zig | 329 | 内核主函数 |
| kernel/arch/x86_64/paging.zig | 293 | 页表管理 + getPagePhysAddr |
| kernel/fs/ext2.zig | ~900 | ext2 文件系统 |
| kernel/fs/fat32.zig | ~900 | FAT32 文件系统 |
| kernel/proc/scheduler.zig | ~500 | O(1) 位图调度器 |
| kernel/proc/task.zig | ~600 | Task 结构体 + 进程管理 |
| kernel/drivers/virtio_blk.zig | ~550 | virtio-blk 块设备驱动 |
| kernel/drivers/nvme.zig | ~400 | NVMe SSD 驱动 |
| kernel/mm/pmm.zig | 347 | 物理内存管理 (两级位图 + refcount + COW API) |
| kernel/mm/slab.zig | ~200 | Slab 分配器 |
| kernel/mm/swap.zig | ~300 | Swap 页面置换 (Clock算法) |
| kernel/fs/eventfd.zig | 165 | eventfd 事件通知 |
| kernel/fs/procfs.zig | 333 | procfs 11种虚拟文件 |
| kernel/sync/ | ~600 | IrqSpinlock/TicketLock/Mutex/RwLock/SeqLock/MPMC |

**总计: 102 个 .zig 文件, 35,899 行**
