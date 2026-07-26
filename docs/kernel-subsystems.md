# MoQiOS 内核子系统详细设计

> **文档定位**: 描述 MoQiOS 内核各子系统的核心数据结构、API、实现状态与依赖关系。
> **修订日期**: 2026-06-21
> **关联文档**: [moqios-architecture-current.md](./moqios-architecture-current.md)
>
> **2026-06-21 更新**: SMP 性能三件套（FPU/SSE 按任务 lazy save、Per-CPU 运行队列 +
> Work-Stealing、范围 TLB Shootdown）已全部实现并集成，本文相关章节（§2.2 调度器、
> §2.7 FPU/SSE 状态管理、§9 SMP 多核）均已更新。代码级审查与历史修复顺序仍见
> [current-code-review-and-fix-plan.md](./current-code-review-and-fix-plan.md)。
>
> **2026-06-21 新增功能**: 调度器 Profiling 基础设施（§2.8）、IPv6 协议栈（§4.10–4.12）、
> POSIX Capability 安全模型（§5.9）、Arch 抽象层（§11）。

---

## 目录

1. [内存管理](#1-内存管理)
2. [进程管理](#2-进程管理)
3. [文件系统](#3-文件系统)
4. [网络协议栈](#4-网络协议栈)
5. [IPC 引擎](#5-ipc-引擎)
6. [设备驱动](#6-设备驱动)
7. [同步原语](#7-同步原语)
8. [ACPI 子系统](#8-acpi-子系统)
9. [SMP 多核](#9-smp-多核)
10. [子系统依赖关系](#10-子系统依赖关系)
11. [Arch 抽象层](#11-arch-抽象层)

实现状态图例: ✅ 完整 / ⚠️ 部分 / 🧩 框架

---

## 1. 内存管理

源码: `kernel/mm/`

### 1.1 PMM（物理页帧分配器） ✅ 两级位图 + allocHugePages

文件: `pmm.zig`, `page_frame.zig`

**核心数据结构**

```zig
const Pmm = struct {
    bitmap_l1: []u64,     // L1: 1 bit / 4KB 页
    bitmap_l2: []u64,     // L2: 每 64 页一个汇总位（加速空闲扫描）
    refcount: []u8,       // 每页引用计数（CoW 支持）
    total_pages: usize,
    free_pages: usize,
    base_phys: usize,     // 跳过前 2MB
    lock: IrqSpinlock,
};
```

**主要 API**

| 函数 | 描述 |
|---|---|
| `allocPage() ?usize` | 分配单个 4KB 物理页（两级位图加速） |
| `freePage(phys)` | 释放，并递减引用计数；同步更新 L2 汇总位 |
| `incRef(phys)` / `decRef(phys)` | 引用计数（CoW 使用） |
| `allocContig(n) ?usize` | 分配 n 个连续页（DMA 用） |
| `totalPages() u64` | ✅ 返回总物理页数 (sysinfo 使用) |
| `freePages() u64` | ✅ 返回空闲物理页数 (sysinfo 使用) |
| `allocHugePages(n) ?usize` | 分配 n 个连续 2MB 大页对齐物理页 |

**特性**：基于 Limine memory map 初始化；首 2MB 物理内存保留以避开 BIOS/低端区；两级位图（L2 每 64 页一个汇总位）将分配延迟降低约 50%。

### 1.2 Slab 分配器 ✅

文件: `slab.zig`

**核心数据结构**

```zig
const SlabClass = struct {
    obj_size: usize,            // 32/64/128/256/512/1024
    free_list: ?*FreeNode,      // 侵入式空闲链表
    pages: ArrayList(usize),    // 后备页面
    lock: IrqSpinlock,
};
```

**API**

| 函数 | 描述 |
|---|---|
| `kalloc(size) ?[]u8` | 在合适大小类分配 |
| `kfree(ptr)` | 归还到对应大小类空闲链表 |

**大分配 (v26.2)**: >1024 字节走 allocLarge 路径，单页用 pmm.allocPage，多页用 pmm.allocContiguous，header._pad 存页数供 kfree 释放。

### 1.3 分页 ✅ mapPages()/unmapPages() 批量接口，flushTlbAll()

文件: `arch/x86_64/paging.zig`

- 4 级页表（PML4 → PDPT → PD → PT）
- 支持 4KB 页与 2MB 大页（PS=1 PDE 直接指向 2MB 物理帧）
- HHDM 映射优先使用 2MB 大页减少 TLB 压力
- 标志位：P / RW / US / PWT / PCD / A / D / PS / G / NX

**API**

| 函数 | 描述 |
|---|---|
| `mapPage(pml4, va, pa, flags)` | 映射单个 4KB 页 |
| `mapPages(pml4, va, pa, n, flags)` | ✅ 批量映射 n 个页；>32 页时使用 CR3 重载批量刷新 TLB |
| `mapPage2M(pml4, va, pa, flags)` | 映射 2MB 大页（HHDM 使用） |
| `unmapPage(pml4, va) ?u64` | 解除映射并 invlpg，返回物理地址 |
| `unmapPages(pml4, va, n)` | ✅ 批量解除映射；>32 页时调用 `flushTlbAll()` |
| `flushTlbAll()` | CR3 重载，整页 TLB 刷新 |
| `tlbShootdown(va, n)` | ✅ IPI 向量 `0xFE` + 原子同步 + 超时保护，跨核 TLB 一致性 |
| `walk(pml4, va) ?*Pte` | 查找 PTE |
| `getPagePhysAddr(pml4, va) ?u64` | ✅ 获取虚拟地址的物理页地址 (mincore使用) |
| `clonePml4(src) -> *Pml4` | fork 时复制 + CoW 标记 |

### 1.4 HHDM ✅

文件: `mm/hhdm.zig`

```zig
pub fn physToVirt(p: usize) usize { return p + hhdm_offset; }
pub fn virtToPhys(v: usize) usize { return v - hhdm_offset; }
```

内核虚拟地址空间起始 `0xFFFFFFFF80000000`；`hhdm_offset` 由 Limine 提供。

### 1.5 地址空间 ✅

文件: `mm/address_space.zig`

```zig
const AddressSpace = struct {
    pml4_phys: usize,
    vmas: ArrayList(Vma),     // 用户态映射区
    brk_start: usize,
    brk_end: usize,
};
```

**API**: `create()` / `destroy()` / `mmap(addr, len, flags)` / `munmap(...)` / `clone(cow=true)`。

### 1.6 CoW Fork (PTE bit9 + ref_count + #PF handler) ✅

- fork 时父子页表共享 PT。**仅可写页**降级：清写位并用 PTE bit9 标记 CoW；只读页原样共享
  （`cow_pte.sharedPte`）。这条区分是必须的：bit9 是 handler 判断"可以授予写权限"的唯一
  依据，给只读页打上它等于让 text/rodata/`PROT_READ` 在子进程首次写入后变成可写——3.160
  之前正是如此
- 写入触发 #PF → handler 检查引用计数：
  - refcount == 1 → 直接置位 W
  - refcount > 1 → 分配新页 + 复制 + 引用计数递减

### 1.7 copy_from_user 页表预验证安全访问 ✅

文件: `copy_from_user.zig`

- 页表预验证方案：访问用户空间前通过walk页表确认地址可访问
- 写方向额外校验**可写性**（`paging.isUserWritable`）：仅"已可写"或"带 CoW 标记"的页放行，
  后者会故障并由缺页处理器的内核态 CoW 路径解开。只看 `user` 位是不够的——`mmap(PROT_READ)`
  的页会通过校验，随后内核自己的 `@memcpy` 在 `CR0.WP=1`（实测）下触发内核态写保护故障，
  落入无恢复的致命分支，任何非特权进程据此即可停机（3.160）
- **不可逆操作前用 `validateUserBufferWritable`**：从管道/套接字/定时器取数据是单向的，取完
  才发现目的地只读，字节就丢了（3.161）。按方向选用：输出缓冲区走可写校验，纯输入参数
  （如 `select` 的 timeout、`timerfd_settime` 的 new_value）仍走 `validateUserBuffer`，否则
  会误拒放在 rodata 里的常量参数
- UserAccessError返回而非panic，保证内核鲁棒性
- 接口：copyFromUserChecked / copyToUserChecked / getUser / putUser / copyStringFromUser

### 1.8 mmap 文件映射 (MAP_PRIVATE/SHARED/FIXED + munmap + msync) ✅

文件: `address_space.zig` (mmap/munmap/msync), `syscall_entry.zig`

- 支持 MAP_PRIVATE / MAP_SHARED 文件映射
- 支持 MAP_FIXED 强制指定地址
- 64条VMA表管理用户态映射区
- 配套 munmap 解除映射和 msync 同步脏页
- syscall mmap: 支持匿名映射 + 文件映射 (MAP_PRIVATE)，读取文件内容到物理页

**用户地址空间布局**（两种镜像不同，范围校验必须区分）:

| 区域 | 平坦二进制 | ELF 镜像（全部 C 用户程序） |
|---|---|---|
| 代码 | `USER_CODE_BASE` = 4MB | 镜像自带，链接在 16MB |
| 栈 | 单页在 `USER_STACK_TOP - PAGE` = 0x7FF000，按需向下增长至 64KB | 同左（**在代码之下**） |
| 堆（brk） | 从代码之上向栈生长，天花板 0x7FF000 | 从镜像之上向上生长，天花板 `USER_HEAP_MAX` = 4GB |
| 内核选址的 mmap | `USER_MMAP_BASE` = 8GB 起，上限 16GB | 同左 |

两种布局中代码/堆/栈的相对次序相反，因此"堆必须低于 `USER_STACK_TOP`"这类静态窗口
校验对 ELF 是反的——它曾使 `brk` 增长和匿名 `mmap` 对所有 C 程序无条件失败。正确做法是
判断目标页是否空闲，再用 `USER_ADDR_MAX`/`USER_HEAP_MAX` 兜底。mmap 选址窗口刻意置于堆
天花板与栈增长区间之上，使 `mmap` 不会把堆封住；`mmap` 也不再推进 `brk_current`。

- `brk`: 可在 `[Task.brk_start, 天花板]` 内移动。`brk_start` 记录加载器留下的初始
  break，收缩不能低于它（否则会解除镜像自身的映射）。增长逐页确认未被映射（`mapPage`
  会无声覆写活跃 PTE 并泄漏旧帧）并清零新页（`pmm.allocPage` 返回的帧带有上一使用者的
  数据）；收缩释放让出的页。增长/收缩/原地是三条独立分支——早期实现无条件写
  `for (old_page..new_page)`，收缩时区间反向，直接导致内核整数溢出 panic。
- 非 `MAP_FIXED` 的 `addr` 按 POSIX 视为建议：仅在区间空闲时采纳，否则内核另选地址。
  无条件采纳会让进程用 `mmap(&_start, ...)` 覆盖掉正在执行的代码页。
- 运行时覆盖: `hello30`（brk 增长/清零/收缩 + 匿名 mmap + hint 让位），
  冒烟门禁标记 `hello30: brk/mmap PASS`。

### 1.9 Swap 页面置换 (Clock算法 + u64位图分配 + 256MB swap) ✅

文件: `swap.zig`, `arch/x86_64/paging.zig`

- Clock二次机会算法页面回收
- 65536槽swap位图管理256MB交换空间，u64字级扫描+@ctz O(1)分配
- virtio-blk后端读写swap页
- 水位线自动触发内存回收
- #PF缺页时自动swap-in

---

## 2. 进程管理

源码: `kernel/proc/`

### 2.1 Task 结构体 ✅

文件: `task.zig`

```zig
const Task = struct {
    pid: u32, ppid: u32,
    state: enum { Ready, Running, Sleeping, Zombie, Stopped },
    priority: u8,
    time_slice: u32,
    regs: SavedRegs,            // r15..rax, rip, rsp, rflags, cr3
    kstack: []u8,               // 16KB 内核栈
    mm: *AddressSpace,
    fdtable: FdTable,           // 16 个 FD
    sigmask: u64, sigpending: u64,
    sigactions: [32]SigAction,
    cwd: [256]u8,
    env: ArrayList(KeyValue),
    name: [32]u8,
    // POSIX 凭证 (v18.0)
    uid, gid, euid, egid, suid, sgid: u32,
};
```

最多 64 个任务（静态数组）。凭证字段在 fork/clone 时继承，默认值 0 (root)。

### 2.2 调度器 ✅ Per-CPU 运行队列 + Work-Stealing（2026-06-21 完成）

文件: `proc/sched.zig`, `proc/per_cpu.zig`, `proc/task.zig`

**当前实现（M8-7 已完成 ✅）**

- **Per-CPU 运行队列**：`proc/per_cpu.zig` 定义 `PerCpuRunQueue` 结构，每 CPU 一份；
  256 槽环形缓冲区（`QUEUE_SIZE=256`），由 `IrqSpinlock` 保护。本地操作只持有本队列锁；
  跨队列窃取同时按 CPU ID 升序持有 thief/victim 两把锁，避免并发搬运损坏队列或 ABBA 死锁。
- **本地 LIFO 操作**：`push` / `pop` 在 `head` 端 O(1) 操作（最近压入的任务先出，
  最大化 L1/L2 缓存复用）。
- **Work-Stealing**：仅当本地队列为空（idle）时触发，`tryStealForCurrent` 以
  TSC 派生的随机 CPU 为起点扫描其他 CPU 的队列，调用 `steal_half` 从对端 `tail`
  端窃取约一半任务（>1 才偷，留 1 给被偷者避免乒乓）。
- **CPU 亲和性尊重**：`Task.cpu_affinity: i8`（`-1` = 不绑定，可被偷；`>=0` = 绑定到
  指定 CPU），`steal_half` 跳过被绑定到其他 CPU 的任务并将其放回原队列。
- **`Task.last_cpu: u8`**：记录任务最近一次运行的 CPU，作为 enqueue 时的归位提示
  （warm cache hint）。
- **调度入口 `pickNext` 三段式回退**：① 本地 `pop` → ② `tryStealForCurrent` 跨核
  窃取 → ③ 全局位图回退（`task.pickReadyForCpu`，与亲和性扫描兼容）。
- 时间片 10 个 tick（100ms），LAPIC timer ISR 触发 `schedule()`，调用
  `switchContext(prev, next)`（`arch/x86_64/context.S`）。

**API**：`schedule()` / `yield()` / `wakeup(task)` / `sleep(ms)` / `addTask(task)` /
`per_cpu.enqueueTask(t)` / `per_cpu.tryStealForCurrent()`.

**意义**：在此之前 SMP 模式下所有 CPU 共享一把全局 `sched_lock` + 静态任务表的亲和性
扫描，AP 只能跑被显式绑定到自己的任务；现在 AP 通过 work-stealing **真正参与用户任务并行**，
忙 CPU 主动卸载、闲 CPU 主动拉取。

**主动让出必须走中断返回路径（x86_64，2026-07-25 修正）**

调度器交接 CPU 的方式是改写 per-CPU 栈锚点（`%gs:16`）并加载下一个任务的 CR3，而**只有中断
返回路径**会消费这个锚点：中断入口在进入时写锚点，返回时 `movq %gs:16, %rsp` 再 `iretq`。

原先 `forceReschedule()` 在 x86 上直接 `call` 进 `timerTick(getAnchor())`。从系统调用里调用时，
交接只完成了一半：CR3 已经换成下一个任务的，而系统调用仍在自己的内核栈上通过 `sysretq` 返回，
于是调用方**带着别人的地址空间回到了自己的用户 RIP**——当下一个任务是内核任务时更是加载了内核
页表，用户侧一条指令都取不到。

现在 `forceReschedule()` 触发同步让出陷阱（向量 252），让切换发生在真实的中断帧上：当前任务的
帧被调度器妥善保存，等它再被调度时从该帧 `iretq` 回到 `int` 之后继续，系统调用才正常返回用户态。
向量 252 的门 DPL=0，用户态执行同样的 `int` 得到 `#GP`；其处理函数刻意不发 LAPIC EOI，因为
并没有任何中断被投递。

这不是 `sched_yield` 独有的问题：`forceReschedule` 的所有调用方（futex 等待、SysV 信号量、
`ipc`、阻塞 `flock`、`pause`）都走同一条路径，因此修正落在 `forceReschedule` 自身而非调用点。
此前无法触及是因为**没有任何用户程序调用过 `sched_yield`**，`hello31` 是第一个。

### 2.8 调度器 Profiling 基础设施 ✅（2026-06-21 完成）

文件: `proc/per_cpu.zig`, `fs/procfs.zig`

**SchedStats 结构体**

```zig
const SchedStats = struct {
    local_enqueues: u64,      // 本地入队次数
    local_dequeues: u64,      // 本地出队次数
    steal_attempts: u64,      // 窃取尝试次数
    steal_successes: u64,     // 窃取成功次数
    tasks_stolen: u64,        // 被窃取的任务总数
    idle_cycles: u64,         // 空闲周期计数
    schedule_calls: u64,      // schedule() 调用次数
    queue_depth_sum: u64,     // 队列深度累加（用于计算平均）
    sample_count: u64,        // 采样次数
};
```

**关键路径自动计数**

- `push`：递增 `local_enqueues`
- `pop`：递增 `local_dequeues`
- `steal_half`：递增 `steal_attempts`；成功时递增 `steal_successes` + 累加 `tasks_stolen`
- `tryStealForCurrent`：窃取扫描入口统计
- `pickNext`：递增 `schedule_calls`，累加当前 `queue_depth_sum` / `sample_count`

**procfs 导出**

- 虚拟文件路径：`/proc/sched_stats`
- 格式：每 CPU 一行，包含所有 10 个计数器的当前值
- 用途：性能调优、负载均衡行为可观测性

**公共 API**

| 函数 | 描述 |
|---|---|
| `getStats() SchedStats` | 获取当前 CPU 的调度统计快照 |
| `resetStats()` | 重置当前 CPU 的所有统计计数器 |

### 2.3 ELF 加载器 ✅

文件: `loader.zig`

- 解析 `Elf64_Ehdr` / `Elf64_Phdr`，按 PT_LOAD 段映射
- 段权限遵守 `p_flags`：`PF_W` 决定可写位、`PF_X` 决定 NX。段内容通过 HHDM 别名写入物理页，
  不走用户映射，因此 text/rodata 从一开始就能按只读映射，无需"先可写再收紧"的第二遍
  （3.160 之前正是丢弃了 `PF_W`、一律按可写映射）
- 构造 SysV x86_64 ABI 栈帧：`[argc][argv...][NULL][envp...][NULL][auxv...][AT_NULL]`
- 设置入口寄存器 `rip = e_entry`，`rsp = stack_top`

**API**: `loadElf(buf, mm) -> EntryInfo`。

### 2.4 信号 ✅

文件: `signal.zig`

- 1-31 号信号
- `sigaction(signum, act, oldact)` / `sigprocmask` / `sigreturn`
- 内核在返回用户态前检查 `sigpending & ~sigmask`，若有待处理信号：
  1. 在用户栈构造 `siginfo` + saved context
  2. 注入 trampoline（执行 `sigreturn` 系统调用）
  3. 跳转到用户 handler

### 2.5 clone() 线程 (CLONE_VM/THREAD + FS_BASE TLS) ✅

文件: `task.zig`, `syscall_entry.zig`

- syscall #56，支持CLONE_VM/CLONE_THREAD/CLONE_SETTLS；CLONE_FILES当前复制FD表，尚未实现共享FD表语义
- CLONE_VM：共享地址空间创建轻量级线程
- 独立内核栈，FS_BASE TLS指针配置
- 其余Linux clone标志按当前实现范围处理，完整CLONE_FILES语义仍待实现

**TLS 基址是任务私有状态（2026-07-25 修正）**

原先 `CLONE_SETTLS` 直接 `wrmsr(FS_BASE, tls)`，写的是**当前运行父进程的那个 CPU**。由于
`Task` 没有 TLS 字段、上下文切换从不保存/恢复 `FS_BASE`、内核也没有 `arch_prctl`，这条 `wrmsr`
是内核里唯一的用户 `FS_BASE` 写入点，于是 TLS 基址实际上成了 **CPU 的属性而非线程的属性**：

- 父进程的 `%fs` 从此指向子线程的 TLS 块，而 `CLONE_SETTLS` 本该服务的子线程反而拿不到自己的基址
- 这个错误的基址会一直留在该 CPU 上，被之后调度到该 CPU 的**任意**任务继承（包括不同地址空间的
  任务）。分页仍然隔离各自的内存，所以后果是在攻击者可影响的偏移上发生内存破坏，而非跨进程泄漏

现在 `Task` 增加 `tls_base` 字段：

- `clone`：`CLONE_SETTLS` 时记到**子任务**上，否则沿用父进程的
- `fork`：直接继承（子进程是地址空间的副本，TLS 块地址相同）
- `execve`：清零，并同时把 CPU 上的 `FS_BASE` 写 0——`execve` 不经过调度器就返回用户态，
  否则旧基址会残留进新镜像
- `setupUserCpuState`：每次切到用户任务时安装 `t.tls_base`，因此没有 TLS 的任务拿到 0
  而不是继承前一个任务的基址

安装动作是一个 arch 钩子 `syscall.setUserTlsBase`，并按 CPU 缓存已加载值：绝大多数任务没有
TLS，常见路径只是一次比较，不付 `wrmsr` 的代价。riscv64/aarch64 目前是空实现（尚无用户线程）。

**新增 `arch_prctl(code, addr)`（syscall 472）**：支持 `ARCH_SET_FS`/`ARCH_GET_FS`。此前用户程序
根本无法建立 TLS。`ARCH_SET_GS`/`ARCH_GET_GS` 返回 `EINVAL`——`GS` 存放本内核的 per-CPU 指针，
若允许用户设置，下一次 `swapgs` 就会把内核自身的基址交给用户态。

运行期验证：`user/hello31.c`。父子进程各自指向自己的 TLS 块、写入不同值，在对方运行过之后再读回，
`hello31: TLS PASS` 与 `hello31: child TLS ok` 均为 x86_64 冒烟必需标记。

### 2.6 poll() I/O多路复用 (TCP/管道/文件) ✅

文件: `poll.zig`, `syscall_entry.zig`

- syscall #125，单线程监听多fd
- 支持TCP socket / 管道 / 文件描述符
- 事件类型：POLLIN / POLLOUT / POLLHUP / POLLNVAL
- 带超时机制（毫秒级）

### 2.7 FPU/SSE 任务状态管理（Lazy FPU） ✅（2026-06-21 完成 / M8-5b-3）

文件: `arch/x86_64/context_switch.zig`, `proc/task.zig`, `arch/x86_64/idt.zig`

**目标**：让 FPU/SSE 寄存器作为任务私有状态，使任务可在 CPU 间安全迁移（解锁 work-stealing
中的用户任务跨核搬运），同时对**从不**触碰 FPU 的内核线程零开销。

**Task 字段扩展**

```zig
fpu_state: [512]u8 align(16) = ...,  // FXSAVE 区，16 字节对齐
fpu_initialized: bool = false,        // 是否曾经触发过 #NM（有效 fpu_state）
fpu_owned: bool = false,              // 当前是否在某 CPU 上"持有" FPU
```

**Per-CPU 状态**：`context_switch.fpu_owners: [MAX_CPUS]?*Task` 追踪每个 CPU 当前
FPU 持有者（仅本地 CPU 在自己的 #NM handler 中读写，无锁）。

**初始化（per CPU）**：`context_switch.initCpu()` 设置 CR4.OSFXSR | CR4.OSXMMEXCPT，
清 CR0.EM、置 CR0.MP | CR0.TS。BSP 在 `main.zig`、AP 在 `smp.zig` `apEntry` 各自调用一次。

**Lazy 切换流程**

1. **上下文切换出**（`onContextSwitch(old)`）：若 `old.fpu_owned`，eager `fxsave` 到
   `old.fpu_state`；然后 `setTs()` 置 CR0.TS，给即将上 CPU 的新任务下一道"如果敢碰
   FPU 就 #NM"的安全网。
2. **新任务首次访问 FPU** → CPU 抛 `#NM`（vector 7） →
   `idt.handleException` 路由到 `context_switch.handleDeviceNotAvailable()`：
   - `clts` 清 CR0.TS；
   - 若该 CPU 的 `fpu_owners[cpu]` 不是当前任务，将旧 owner `fpu_owned = false`；
   - 当前任务 `fpu_initialized` ? `fxrstor` 还原 : `fninit` 重置；
   - 标记当前任务 `fpu_owned = true`，更新 `fpu_owners[cpu]`。

**正确性要点**：`#NM` 处理路径**绝不获取调度器/任务锁**——它可能在内核临界区中被触发
（如某段内核代码恰好用了 SSE）。所有状态都通过"本 CPU 独占的 fpu_owners 槽 + 任务自身字段"
避免锁。

---

## 3. 文件系统

源码: `kernel/fs/`

### 3.1 VFS ✅

文件: `vfs.zig`

```zig
const Fd = struct {
    kind: enum { Ramdisk, Fat32, Ext2, Pipe, TcpSocket },
    pos: u64,
    flags: u32,
    inner: union { ... },
};

const FdTable = struct {
    fds: [16]?Fd,
};
```

**统一 API**: `open` / `read` / `write` / `close` / `lseek` / `listdir` / `mkdir` / `unlink` / `truncate` / `syncAll` / `syncFile`。

**挂载管理** (v18.0): `mountFs` / `umountFs`，16 挂载点表，支持 tmpfs/ext2/vfat/proc/ramfs 类型。系统调用 #165 (mount), #166 (umount2)。

### 3.2 Ramdisk ✅

文件: `ramdisk.zig`，格式: MRD（自定义）

- Header: 32 字节（magic + entry_count + ...）
- Entry: 80 字节/文件（名称、偏移、长度）
- Data: 串接所有文件原始数据

只读，由内核启动时一次性加载到内存，存放所有用户测试程序。

### 3.3 FAT32 ✅ 256 扇区 FAT 表 LRU 缓存，write-back

文件: `fat32.zig`

- MBR 分区表解析
- Boot Sector (BPB)、FSInfo
- FAT 表读写：256 扇区 LRU 缓存（128KB），write-back 策略
- 空闲簇提示指针（next-free hint）加速分配
- 8.3 短文件名 + LFN（长文件名）支持
- 操作: 读/写/创建/删除/目录列表

### 3.4 Ext2 ✅ 256 条目块缓存 + 哈希加速 + 间接块缓存

文件: `ext2.zig`

- Superblock、Block Group Descriptor
  - `Ext2GroupDesc` 必须保持磁盘上的 **32 字节**步长（含 `bg_pad`/`bg_reserved`），
    尺寸由 `GROUP_DESC_SIZE` 与 SK-153 约束。描述符表按真实大小用
    `allocContiguous` 分配（单页只放得下 128 个），读取经 `readSectorRun` 拆成
    驱动允许的 128 扇区分段。
  - 来自磁盘的 inode 号与块号一律经 `groupForInode`/`groupForBlock` 校验后
    才用于索引描述符表。
- 目录项解析统一走 `eu.readDirEntry`（SK-154 约束）：按小端字节读字段以适配任意
  对齐，并拒绝头部越过块尾、`pos`/`rec_len` 非 4 对齐、`rec_len` 装不下自身名字、
  记录越过块尾的记录。新增目录项时的可拆间隙也从校验后的记录计算，避免 u16 下溢
  导致越界写。
- Inode（直接块 + 单级间接块）
- 块缓存：256 条目 + 64 桶哈希表加速查找，dirty write-back
- 间接块指针缓存：16 条目，避免重复读取间接块
- 截断释放：`truncateFile` / `truncateByInode` 共用单/双/三级间接块 tail-trim helper，缩小时释放尾部数据块和空的间接树并失效 inode 页缓存
- 目录条目读写
- 多级路径解析（`resolveParent`）
- 操作: `readFile` / `writeFile` / `createFile` / `createDir` / `unlinkFile` / `listDirInode` / `truncate`

### 3.5 管道 ✅ 阻塞读写 + SIGPIPE + O_NONBLOCK + poll集成

文件: `pipe.zig`

```zig
const Pipe = struct {
    buf: [4096]u8,
    head: u32, tail: u32,
    readers: u32, writers: u32,
    read_wait: WaitQueue,
    write_wait: WaitQueue,
};
```

- `pipe(fds)` 系统调用返回 [read_fd, write_fd]
- 阻塞读写语义：空管读阻塞、满管写阻塞
- SIGPIPE：无读者时写者收到SIGPIPE信号
- O_NONBLOCK：非阻塞模式支持
- 读写等待队列：基于WaitQueue的睡眠等待
- poll集成：支持POLLIN/POLLOUT/POLLHUP事件检测
- fork引用计数：多进程共享管道生命周期管理

### 3.6 目录操作: mkdir/rmdir/unlink/rename/getdents64 ✅

文件: `vfs.zig`, `ext2.zig`

- mkdir / rmdir / unlink / rename / getdents64
- Ext2完整实现：目录项创建/删除/重命名/枚举
- 系统调用：#82(rename), #84(mkdir), #111(unlink), #123(mkdir旧号), #217(getdents64)
- 多级路径解析支持
- 目录读取只对 tmpfs 可达：VFS 目前没有返回 ext2 目录描述符的路径，
  所以 `getdents64` 的 ext2 分支从用户态触达不到

### 3.6.1 写回错误传播（SK-155 约束）

- `ext2.writeFile` / `fat32.writeFile` 遇到设备写失败即停止，返回值只覆盖真正
  落盘的字节；文件大小按实际写入量增长，而非按请求量
- 刷盘回调只有在全长被接受时才算成功，否则脏位保留、数据不被丢弃
- `flushFile` / `flushAllByType` 返回是否全部写出，经
  `syncFile` / `syncAll` / `invalidateFile` 上报至 `fsync` / `msync` / `close`（`EIO`）
- `fsync` 按描述符类型选择 `ext2_file_idx` 或 `fat32_file_idx`：两个文件系统的
  索引空间独立，用错会刷到别的文件（通常是没有）却报告成功

### 3.7 Linux AIO ✅ (v18.1)

文件: `aio.zig` (267 行)

- 8 个 AIO 上下文上限，32 事件/上下文
- io_setup: 创建上下文，写入 ctx_id 到用户空间
- io_destroy: 销毁上下文
- io_submit: 提交 I/O 请求 (简化: 同步执行 PREAD/PWRITE，立即标记完成)
- io_getevents: 获取完成事件 (环形缓冲)
- io_cancel: 取消请求 (stub: 返回 EINVAL)
- 系统调用: #206 (io_setup), #207 (io_destroy), #208 (io_getevents), #209 (io_submit), #210 (io_cancel)

---

## 4. 网络协议栈

源码: `kernel/net/`

### 4.1 分层

```
应用 (socket API: sendto/recvfrom/sendmsg/recvmsg/shutdown)
   ↓
TCP (Reno/SACK/WS/TS) / UDP
   ↓
ICMP / IPv4
   ↓
ARP
   ↓
Ethernet (eth.zig)
   ↓
e1000 (中断驱动) / virtio-net (Virtqueue)
```

### 4.2 Ethernet ✅

文件: `eth.zig`

- 14 字节帧头（dst MAC + src MAC + ethertype）
- ethertype: 0x0800 (IPv4) / 0x0806 (ARP) / 0x86DD (IPv6)

### 4.3 ARP ✅

文件: `arp.zig`

- ARP 缓存（哈希表）
- 请求/应答
- 老化机制

### 4.4 IPv4 ✅

文件: `ipv4.zig`

- 头部校验和
- TTL、协议字段（1=ICMP, 6=TCP, 17=UDP）
- 不支持分片/重组（MTU 1500，单帧）

### 4.5 ICMP ✅

文件: `icmp.zig`

- Echo Request / Reply（ping）

### 4.6 UDP ✅

文件: `udp.zig`

- 端口绑定表
- 校验和
- 收发缓冲

### 4.7 TCP ✅ Reno + SACK + Window Scaling + Timestamps + CORK + QUICKACK + TIME_WAIT优化

文件: `tcp.zig`

- 64 个并发连接 (MAX_CONNECTIONS=64)，64KB 发送/接收缓冲区，32KB 窗口
- 完整 11 状态机：CLOSED / LISTEN / SYN_SENT / SYN_RCVD / ESTABLISHED / FIN_WAIT_1 / FIN_WAIT_2 / CLOSE_WAIT / CLOSING / LAST_ACK / TIME_WAIT
- 序列号 / ACK / 窗口
- Reno 拥塞控制：慢启动 / 拥塞避免 / 快速重传（3 个重复 ACK）/ 快速恢复
- 自适应 RTO（RFC 6298）：`RTO = SRTT + 4 * RTTVAR`
- SACK 选择性确认（RFC 2018）：SYN 阶段 SACK Permitted 协商；接收端乱序队列 + 自动合并；ACK 最多附带 4 个 SACK 块；发送端记分板跟踪已 SACK 段，dupACK 触发选择性重传仅丢失段；序列号环绕安全（seqLT/seqLE/seqMin/seqMax）
- Window Scaling (RFC 7323)：SYN阶段协商窗口缩放因子（shift=7，最大窗口4MB）
- Timestamps + PAWS：精确RTT测量，防止序列号环绕误判
- Keepalive + Nagle 算法
- TCP_CORK：合并小写入为满MSS段，uncork时flushSendBuffer发送所有待发数据 (v29.0)
- TCP_QUICKACK：禁用延迟ACK，每个收到段立即发送ACK (v29.0)
- SO_LINGER：linger=0时tcpClose发RST替代FIN（abortive close）(v29.0)
- @memcpy批量环形缓冲区I/O：tcpSend/flushSendBuffer/processIncomingData/tcpRecv 4处逐字节→ringWrite/ringRead (v29.0)
- 发送路径零弹跳缓冲：`tcpSendFromUser` 直接把用户数据拷入 send_buf（跨界拆两段），不再在 128KB 内核栈上开整窗中转缓冲，整窗写入的批量拷贝由 2 次降为 1 次；tcpSend 系统调用与 sendto/sendmsg 共用该路径，单次上限即发送窗口 (SK-151)
- TIME_WAIT 优化：30s→15s，新连接可复用 TIME_WAIT TCB (若序号更大)
- 窗口更新ACK：应用读取数据后发送窗口更新ACK (超过 1 MSS 时)
- 延迟ACK：every-other-segment规则 + 100ms超时 + ACK捎带
- TCB（Transmission Control Block）数组 + active_bitmap位图查找；发送构包使用栈上缓冲，避免全局包缓冲锁串行化
- 公开 API: `tcpGetAddrInfo()` (getsockname/getpeername), `tcpIsClosing()`, `tcpFlushCork()`, `tcpFlushAck()`

### 4.9 poll() 多路复用 ✅

文件: `poll.zig`, `socket.zig`

- 支持TCP socket事件检测（POLLIN/POLLOUT/POLLHUP）
- 集成poll()系统调用，单线程监听多连接

### 4.10 IPv6 协议栈 ✅（2026-06-21 完成）

文件: `kernel/net/ipv6.zig`

- 40 字节固定头部构建与解析（Version/Traffic Class/Flow Label/Payload Length/Next Header/Hop Limit）
- 伪首部校验和计算（供 ICMPv6/TCP/UDP over IPv6 使用）
- `mod.zig` `handleRxPacket` 增加 IPv6（ETHERTYPE_IPV6 = 0x86DD）分发路径
- `eth.zig` 新增 `ETHERTYPE_IPV6 = 0x86DD` 常量

### 4.11 ICMPv6 ✅（2026-06-21 完成）

文件: `kernel/net/icmpv6.zig`

- Echo Request / Echo Reply（IPv6 ping）
- Neighbor Solicitation（邻居请求）
- Neighbor Advertisement（邻居通告）
- ICMPv6 校验和（含 IPv6 伪首部）

### 4.12 NDP 邻居发现协议 ✅（2026-06-21 完成）

文件: `kernel/net/ndp.zig`

- 64 项邻居缓存表（IPv6 地址 → MAC 地址映射）
- link-local 地址自动生成（EUI-64 从 MAC 地址派生）
- Neighbor Solicitation 发送与处理
- Neighbor Advertisement 响应
- 缓存老化机制

### 4.13 AF_INET6 Socket 支持 ✅（2026-06-21 完成）

文件: `socket_syscall.zig`

- `AF_INET6 = 10` 地址族支持
- SOCK_STREAM（TCP over IPv6）与 SOCK_DGRAM（UDP over IPv6）创建
- 与现有 socket API（bind/connect/send/recv）集成

### 4.8 Socket API ✅ 完整 BSD-like Socket 接口

文件: `socket.zig`, `syscall_entry.zig`

封装到 FD 层：`socket` / `bind` / `listen` / `accept` / `accept4` / `connect` / `sendto` / `recvfrom` / `sendmsg` / `recvmsg` / `shutdown` / `getsockname` / `getpeername` / `setsockopt` / `getsockopt` / `close`。

- shutdown: SHUT_RD(0) / SHUT_WR(1) / SHUT_RDWR(2)，发送 FIN 半关闭
- sendmsg/recvmsg: 解析 msghdr，遍历 msg_iov 收发数据
- getsockname/getpeername: 从 TCB 构造 sockaddr_in
- accept4: 带 SOCK_NONBLOCK/SOCK_CLOEXEC 标志的 accept

### 4.9 Unix Domain Socket ✅ (AF_UNIX, v28.0 @memcpy优化)

文件: `unix_socket.zig`

- SOCK_STREAM (连接可靠字节流) + SOCK_DGRAM (数据报)
- 32 个套接字上限，8KB 环形缓冲区/套接字
- bind/listen/accept/connect/send/recv 完整操作
- @memcpy 批量环形缓冲区 I/O：ringWrite/ringRead 处理环形缓冲区边界，逐字节循环替换为 2 段 @memcpy（STREAM/DGRAM 读写各 2 处）
- 阻塞 I/O：read_waiters/write_waiters 等待队列
- 系统调用: socket(AF_UNIX) / socketpair

---

## 5. IPC 引擎

源码: `kernel/ipc/`

### 5.1 消息传递 ✅

文件: `ipc.zig`

```zig
const Message = struct {
    sender: u32,
    type: u32,
    payload: [256]u8,
};
```

操作：

| 操作 | 描述 |
|---|---|
| `send(dst, msg)` | 同步发送，目标未 receive 则阻塞 |
| `receive(from)` | 阻塞等待消息（from = ANY 或具体 PID） |
| `call(dst, msg)` | send + receive 复合 |
| `reply(dst, msg)` | 应答 call |
| `notify(dst, type)` | 异步通知（事件位图） |

死锁检测：最大嵌套深度 8，30 秒超时自动解除。

### 5.2 能力系统 ✅

文件: `capability.zig`

```zig
const Capability = struct {
    target: u32,            // 目标端点 PID
    rights: u32,            // 权限位
    cookie: u64,            // 防伪
};
const CapTable = [32]Capability; // 每任务
```

### 5.3 eventfd (64位计数器 + EFD_SEMAPHORE) ✅

文件: `eventfd.zig`

- 64位计数器事件通知机制
- EFD_SEMAPHORE：信号量模式，读后递减1
- EFD_NONBLOCK：非阻塞标志
- 配套读写等待队列
- poll集成：支持POLLIN/POLLOUT事件检测
- 系统调用：#290 (eventfd2)

### 5.4 SysV 共享内存 ✅ (v18.0, v28.0优化)

文件: `sysv_shm.zig`

- 32 个共享内存段上限，256 页/段 (1MB)
- shmget: 创建/查找段，分配物理页并清零
- shmat: 4 级页表映射到进程地址空间 (0x70000000 基址)，支持 SHM_RDONLY
- shmdt: 解除映射，isMappedAt() 4级页表walk验证物理地址匹配，支持延迟删除 (IPC_RMID 标记)
- shmctl: IPC_STAT/IPC_RMID/IPC_SET (权限mode更新)
- findFreeRegion: next_free_hint O(n) 扫描，freeSegment 自动重置 hint
- 系统调用: #29 (shmget), #30 (shmat), #31 (shmctl), #67 (shmdt)

### 5.5 SysV 信号量 ✅ (v18.0, v28.0 IPC_SET)

文件: `sysv_sem.zig`

- 16 个信号量集上限，32 信号量/集
- semget: 创建/查找信号量集，IPC_CREAT/IPC_EXCL
- semop: P/V 操作，P 操作用 sched.sleepOn 阻塞等待，V 操作用 wakeOne 唤醒等待者，IPC_RMID 用 wakeAll 通知
- semctl: IPC_RMID/IPC_STAT/IPC_SET (权限mode更新)/SETVAL/GETVAL
- 系统调用: #64 (semget), #65 (semop), #66 (semctl)

### 5.5b SysV 消息队列 ✅ (v18.1, v28.0 IPC_SET)

文件: `sysv_msg.zig`

- 16 个队列上限，8 消息/队列，512 字节/消息
- msgget: 创建/查找消息队列
- msgsnd: 发送消息 (含 mtype 类型字段)
- msgrcv: 接收消息，支持按类型过滤 (正/负/零)
- msgctl: IPC_STAT/IPC_RMID/IPC_SET (权限mode更新)
- 系统调用: #68 (msgget), #69 (msgsnd), #70 (msgrcv), #71 (msgctl)

### 5.6 POSIX 消息队列 ✅ (v18.0)

文件: `posix_mq.zig` (373 行)

- 16 个队列上限，8 消息/队列，512 字节/消息
- mq_open: 创建/打开队列，O_CREAT/O_EXCL/O_NONBLOCK
- mq_timedsend/timedreceive: 发送/接收消息 (带优先级, v18.2 支持超时等待)
- mq_unlink: 删除队列 (延迟释放)
- mq_notify: 注册/注销通知
- mq_getsetattr: 获取/设置队列属性
- 系统调用: #240-245 (标准号), #214/215/219 (备用号)

### 5.7 timerfd ✅

文件: `timerfd.zig`

### 5.8 POSIX 定时器 ✅ (v18.2)

文件: `posix_timer.zig` (318 行)

- 16 个定时器上限，复用 timerfd 的 tick 驱动机制 (100Hz)
- timer_create: 创建定时器，支持 SIGEV_NONE/SIGEV_SIGNAL
- timer_settime: 设置/解除定时器 (支持 TIMER_ABSTIME)
- timer_gettime: 读取剩余时间和间隔
- timer_getoverrun: 读取超时计数
- timer_delete: 删除定时器
- 系统调用: #222-226 (x86_64 标准编号)

### 5.9 POSIX Capability 安全模型 ✅（2026-06-21 完成）

文件: `kernel/ipc/capability.zig`, `kernel/proc/cap_check.zig`, `kernel/proc/task.zig`, `kernel/arch/x86_64/syscall_entry.zig`

**SysCap packed struct（16 个 POSIX capability 位）**

```zig
const SysCap = packed struct {
    cap_chown: bool,
    cap_dac_override: bool,
    cap_fowner: bool,
    cap_kill: bool,
    cap_setgid: bool,
    cap_setuid: bool,
    cap_net_bind_service: bool,
    cap_net_raw: bool,
    cap_sys_boot: bool,
    cap_sys_admin: bool,
    cap_sys_resource: bool,
    cap_sys_time: bool,
    cap_mknod: bool,
    cap_audit_write: bool,
    cap_setfcap: bool,
    cap_mac_admin: bool,
};
```

**Task 字段扩展**

- `effective_caps: SysCap`：当前有效 capability 集
- `permitted_caps: SysCap`：允许持有的 capability 上限
- `inheritable_caps: SysCap`：可继承给子进程的 capability 集

**cap_check.zig 核心 API**

| 函数 | 描述 |
|---|---|
| `capable(task, cap) bool` | 检查任务是否持有指定 capability |
| `requireCap(task, cap) !void` | 要求 capability，缺失则返回 EPERM |
| `dropCap(task, cap)` | 从 effective 集中移除指定 capability |
| `computeExecCaps(parent, child)` | execve 时计算子进程 capability（继承规则） |

**syscall 检查点集成**

- `kill`：要求 `CAP_KILL`
- `bind`（特权端口 <1024）：要求 `CAP_NET_BIND_SERVICE`
- `setuid` / `setgid`：要求 `CAP_SETUID` / `CAP_SETGID`
- `reboot`：要求 `CAP_SYS_BOOT`
- `mount`：要求 `CAP_SYS_ADMIN`

**继承与初始化**

- init 进程默认 `ALL_CAPS`（所有位为 1），向下兼容现有行为
- `fork.zig`：子进程继承父进程三组 capability
- `capget` / `capset` 系统调用：读写真实三组掩码（effective/permitted/inheritable）

---

## 6. 设备驱动

源码: `kernel/drivers/`

### 6.1 PCI ✅

文件: `pci.zig`

- 通过 ACPI MCFG 表得到 ECAM 基址
- 总线/设备/功能号枚举
- 读取 BAR、Class Code、Vendor/Device ID

### 6.2 e1000（Intel 82540） ✅ 中断驱动 + IRQ 分发

文件: `e1000.zig` (453 行)

- MMIO 寄存器（CTRL, STATUS, IMS, ICR, RDBAL/RDBAH, TDBAL/TDBAH 等）
- RX/TX 描述符环（连续 DMA 缓冲）
- TX ring 提交路径使用 `IrqSpinlock` 保护 descriptor 与 `tx_tail`，允许上层协议并发构包，仅硬件队列提交串行化
- 中断驱动模式：INTx 启用，IMASK 配置 (RXT0/RXO/TXQE/TXDW/LSC)
- IRQ handler: 读取 ICR 清除 pending，循环处理 RX 队列
- IDT 中注册 IRQ 分发，动态读取 PCI IRQ line
- 保留轮询 fallback（兼容无中断环境）

**API**: `init()` / `isActive()` / `getIrqLine()` / `handleInterrupt()` / `sendPacket()` / `receivePacket()`。

### 6.3 Virtio-blk ✅ 中断驱动 + 原子完成标志

文件: `virtio_blk.zig`

- Virtio 1.0 现代接口
- 队列：avail/used/desc 三环
- 中断驱动：ISR 寄存器自动清除，原子完成标志（`AtomicBool`），唤醒等待方
- 超时 fallback：中断丢失时回退到轮询
- 操作：READ / WRITE / FLUSH

### 6.4 AHCI/SATA 🧩

文件: `ahci.zig`

- HBA 寄存器 / 端口寄存器框架
- 命令列表 / FIS 框架就位
- **未完成**: 实际 I/O 路径

### 6.5 PS/2 键盘 ✅

文件: `keyboard.zig`

- IRQ1 中断
- Scancode set 1 → ASCII
- 修饰键（Shift/Ctrl/Alt）状态

### 6.6 NVMe SSD (Admin/IO Queue + PRP) ✅

文件: `nvme.zig`

- PCI枚举发现NVMe设备
- Admin Queue + IO Queue初始化
- Doorbell机制通知控制器
- PRP（Physical Region Page）分散/聚集
- readSectors / writeSectors / flush 接口
- 轮询完成模式

### 6.7 PCI MSI/MSI-X (Capability List + 向量分配) ✅

文件: `pci.zig`, `msi.zig`

- Capability List遍历发现MSI/MSI-X能力
- MSI 32bit/64bit配置
- MSI-X表映射和向量配置
- 向量分配器（从0x40起分配中断向量）

### 6.8 virtio-net 网卡 ✅ Virtqueue RX/TX + 中断驱动

文件: `virtio_net.zig` (548 行)

- Virtio 1.0 Legacy PCI 接口 (vendor 0x1AF4, device 0x1000)
- RX 队列 (queue 0): 128 描述符，中断驱动
- TX 队列 (queue 1): 128 描述符，同步发送
- virtio_net_hdr: 10 字节头部 (flags, gso_type, checksum)
- 中断处理: ISR 读取 + 清除，调用 net.handleRxPacket
- 内存屏障: `asm volatile("" ::: .{ .memory = true })` 替代 @fence
- PCI 配置: Bus Master + INTx 启用

**API**: `init()` / `isActive()` / `getIrqLine()` / `handleInterrupt()` / `sendPacket()` / `receivePacket()`

---

## 7. 同步原语

源码: `kernel/sync/`

### 7.1 IrqSpinlock ✅

文件: `irq_spinlock.zig`

```zig
const IrqSpinlock = struct {
    locked: AtomicBool,
    saved_rflags: u64,
};
```

`acquire` 关中断 + 自旋；`release` 还原 RFLAGS.IF。

### 7.2 TicketSpinlock ✅

文件: `ticket_spinlock.zig`

```zig
const TicketSpinlock = struct {
    next_ticket: AtomicU32,
    serving: AtomicU32,
};
```

公平自旋锁（FIFO），用于多核高争用场景。

### 7.3 Mutex 睡眠互斥锁 ✅

文件: `mutex.zig`

- 基于等待队列的睡眠互斥锁
- 直接交接（handoff）：解锁时直接唤醒下一个等待者，避免Thundering Herd
- 优先级继承：防止优先级反转
- granted原子标志：防止虚假唤醒

### 7.4 RwLock 读写锁 ✅

文件: `rwlock.zig`

- 多读者共享 / 单写者独占
- 写者偏好策略：防止写者饥饿
- 批量唤醒读者：减少上下文切换开销

### 7.5 无锁MPMC队列 (Vyukov bounded) ✅

文件: `mpmc_queue.zig`

- Vyukov bounded MPMC ring buffer
- CAS操作head/tail指针
- per-cell sequence号实现零ABA问题
- 适用于多生产者多消费者高并发场景

---

## 8. ACPI 子系统

源码: `kernel/acpi/`

### 8.1 表解析 ✅

文件: `acpi.zig`, `tables.zig`

| 表 | 用途 |
|---|---|
| RSDP | 由 Limine 提供，定位 RSDT/XSDT |
| RSDT/XSDT | 表索引 |
| MADT | 枚举 LAPIC、IO APIC、CPU 拓扑 |
| MCFG | PCI ECAM 基址 |
| FADT | （框架，部分字段读取） |

**API**: `acpi.init()` / `acpi.findTable("MADT")` / `acpi.iterMadtEntries(cb)`。

---

## 9. SMP 多核

源码: `kernel/smp.zig`, `kernel/proc/{sched,task,waitpid}.zig`, `kernel/arch/x86_64/{gdt,idt,lapic,syscall_entry}.zig`

### 9.1 当前状态（2026-06-21） ✅ SMP 性能三件套全部完成

| 能力 | 状态 |
|---|---|
| AP 启动 + LAPIC 定时器 | ✅ |
| per-CPU 调度状态（idx/slice/anchor/TSS RSP0） | ✅ |
| reschedule IPI（0xFD）+ `force_reschedule` fast-path 旁路 | ✅ |
| APIC id 来自 MADT + `lapic.id()` 刷新 | ✅ |
| 跨核 `waitpid`（`wait_cpu` + `kickChildCpus`） | ✅ |
| `Task.saved_user_rsp` + 切换同步 | ✅ 5b-2d |
| AP 栈 allocContiguous + BSP reap setSlice(1) + TLB EOI + sleepOn forceReschedule | ✅ v27.0 |
| AP 上 ELF 用户任务并行（通过 work-stealing 真正生效） | ✅ 5b-2c |
| FPU/SSE 按任务（lazy save/restore via CR0.TS + #NM） | ✅ 5b-3（2026-06-21）|
| 范围 TLB shootdown（IPI + invlpg loop + 阈值 CR3 回退） | ✅ M8-6（2026-06-21）|
| per-CPU 运行队列 + work-stealing | ✅ M8-7（2026-06-21）|

验证：`MOQI_SMP=1` 与 `MOQI_SMP=2` 均完整跑通 `init` 自动序列（至 `hello21 done`）+ `MoQiOS shell`。

### 9.2 集中配置 ✅

文件: `kernel/config.zig`

- `MAX_CPUS = 256`：系统支持的最大 CPU 数，集中定义
- `gdt.zig` / `syscall_entry.zig` / `sched.zig` 统一引用 `config.MAX_CPUS`，避免多处常量不一致

### 9.3 AP 完整初始化 ✅

文件: `smp.zig`, `arch/x86_64/{gdt,idt,lapic}.zig`

- 启动序列：BSP 通过 LAPIC 发送 INIT IPI + SIPI 启动每个 AP
- AP Trampoline：16 位实模式 → 32 位保护模式 → 64 位长模式
- AP 进入 long mode 后：
  1. 加载 IDT（共享中断处理表）
  2. 初始化 RSP0（per-CPU 内核栈，用于中断/系统调用）
  3. 配置 LAPIC 定时器（带 QEMU TCG 安全检测，TCG 下跳过定时器避免 MMIO 异常）
- Per-CPU 数据：每 CPU 独立 GDT/TSS/idle task

### 9.4 运行时 CPU 核心数保护 ✅

- `apEntry()` 越界保护：检测到 `cpu_id >= MAX_CPUS` 时打印警告并 halt
- `stealTask()` / `dequeueTask()` 改用运行时 `activeCpuCount()`，避免越界访问 Per-CPU 数组
- 优雅降级：MADT 报告超出 `MAX_CPUS` 的核心被截断而非崩溃

### 9.5 范围 TLB Shootdown ✅（2026-06-21 完成 / M8-6）

文件: `arch/x86_64/tlb.zig`, `idt.zig`, `lapic.zig`, `mm/mprotect.zig`, `mm/mmap.zig`

**目标**：替换原来的 "广播 IPI → 远端 CR3 全刷" 粗粒度方案为按页范围 invlpg
精确无效化，避免 mprotect / munmap 单页操作导致整张 TLB 报废，同时保证多核共享地址
空间下的页表修改一致性。

**核心 API**

```zig
pub fn shootdownRange(addr_start: u64, page_count: u32) void
```

**结构**

- 单一全局请求槽 `shootdown_req: TlbShootdownReq`（`addr_start` / `page_count` /
  `completion` 原子计数器 / `active` 标志）。
- 多发起方串行化通过自定义 **`TlbLock`**（不是 `IrqSpinlock`）：等待时**主动
  开中断**，避免两个 CPU 互相等对方接收 IPI 导致的跨核死锁。
- 向量号沿用既有 `TLB_SHOOTDOWN_VECTOR = 0xFE`。

**算法（发起方）**

1. 本地 `flushLocal(addr, n)`（≤32 页 → invlpg 循环；>32 页 → CR3 reload）。
2. SMP 未上线（`smp.cpu_count <= 1`）直接返回。
3. 持 `shootdown_lock`，发布请求到全局槽，把 `completion` 设为远端 CPU 数。
4. `lapic.sendIpiAllButSelf(0xFE)` 广播。
5. `sti` 后 `pause` 自旋等 `completion == 0`；`cli` 后释放锁。

**算法（IPI 接收方）**

1. 内联 EOI（直接写 LAPIC EOI 寄存器，避免在 IPI 快路径上拉入 lapic helpers）。
2. acquire 加载 `addr_start` / `page_count`，调用 `flushLocal`。
3. `@atomicRmw(.Sub, 1)` 递减 `completion`。
4. **不获取任何锁**，仅原子，对中断重入安全。

**阈值策略**：`FLUSH_THRESHOLD = 32`。超过 32 页改用 CR3 reload（用户页面非 global，
语义等价但比长串 invlpg 快）。

**集成点**：
- `mm/mprotect.zig` 修改 PTE 标志后调用 `tlb.shootdownRange`。
- `mm/mmap.zig` 的 unmap 路径在解映射后调用 `tlb.shootdownRange`。

---

## 10. 子系统依赖关系

```
                    ┌────────────┐
                    │  main.zig  │
                    └──────┬─────┘
            ┌──────────────┼──────────────┐
            ▼              ▼              ▼
       ┌────────┐    ┌──────────┐   ┌──────────┐
       │ arch/  │    │   acpi   │   │  klog    │
       │ x86_64 │    └────┬─────┘   └──────────┘
       └───┬────┘         │
           │              ▼
           │         ┌────────┐
           │         │  pci   │
           │         └───┬────┘
           ▼             ▼
       ┌────────┐  ┌──────────────┐
       │  mm    │  │   drivers/   │
       │ (PMM,  │  │ e1000, virtio│
       │ Slab,  │  │ ahci, kbd    │
       │ paging)│  └──────┬───────┘
       └───┬────┘         │
           │              ▼
           │         ┌──────────────┐
           │         │     net      │
           │         │ eth/arp/ip/  │
           │         │  icmp/udp/   │
           │         │     tcp      │
           │         └──────┬───────┘
           ▼                │
       ┌────────┐           │
       │  proc  │◄──────────┘
       │ (task, │       ┌────────┐
       │ sched, │──────►│   fs   │
       │ loader,│       │ (vfs,  │
       │ signal)│       │ fat32, │
       └───┬────┘       │  ext2, │
           │            │ramdisk,│
           │            │ pipe)  │
           ▼            └────────┘
       ┌────────┐
       │  ipc   │
       │ (msg,  │
       │  cap)  │
       └────────┘
```

**关键依赖说明**

- 所有子系统都依赖 `mm`（堆分配）和 `arch/x86_64`（中断、上下文切换）。
- `drivers` 依赖 `pci`（设备发现）和 `mm/dma`（DMA 缓冲）。
- `net` 依赖 `drivers/e1000` 和 `mm`。
- `fs` 依赖 `drivers/virtio_blk` 或 `ramdisk`。
- `proc` 依赖 `mm`、`fs`（FD 表 / ELF 文件读取）。
- `ipc` 在 `proc` 之上构建。

---

## 11. Arch 抽象层

源码: `kernel/arch/arch.zig`, `kernel/arch/x86_64/arch_impl.zig`, `kernel/arch/riscv64/arch_impl.zig`

### 11.1 统一接口入口 ✅（2026-06-21 完成 / M4 里程碑）

文件: `kernel/arch/arch.zig`

- `comptime` 根据 `builtin.cpu.arch` 自动选择对应架构实现
- 当前支持 x86_64 和 riscv64 两种架构
- 内核上层代码通过 `@import("arch/arch.zig")` 引入，无需关心具体 ISA
- 首步迁移：`main.zig` 串口通过 `arch.zig` 引入（渐进式迁移策略）

### 11.2 x86_64 实现 ✅

文件: `kernel/arch/x86_64/arch_impl.zig`

- 重导出现有模块（serial、gdt、idt、paging、lapic、tsc 等）
- 与现有代码完全兼容，零回归

### 11.3 riscv64 实现 ✅

文件: `kernel/arch/riscv64/arch_impl.zig`

- **串口**：UART16550 直驱（QEMU virt `0x10000000`；M2）
- **中断**：`stvec` 向量 + `TrapFrame`（breakpoint / page-fault 自测）
- **分页**：Sv39 恒等映射 + map/unmap（M3）；完整 HHDM/共享内核复用待后续
- **定时器**：Sstc `stimecmp` 周期 tick（M5）
- **上下文切换**：骨架内双线程抢占切换（M5）；完整 `proc/sched.zig` 复用待后续
- **设备**：virtio-mmio blk 读扇区 + net MAC 探测（M7）；TX/RX/FS 待共享内核

### 11.4 设计原则

- **渐进迁移**：不做大爆炸重构，每次迁移一个模块到 `arch.zig` 接口后面
- **x86_64 不回归**：每步保持可构建、x86_64 启动到 shell
- **薄接口**：仅抽象「硬件相关、其余内核必须调用」的能力
- **下一步**：逐步迁移 gdt/idt/paging 等深度模块到 arch 接口后面

---

## 参考

- [moqios-architecture-current.md](./moqios-architecture-current.md)
- [build-and-toolchain.md](./build-and-toolchain.md)
- [user-space.md](./user-space.md)
- [moqios-design.md](./moqios-design.md)
