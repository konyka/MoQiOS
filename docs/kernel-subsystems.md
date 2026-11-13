# MoQiOS 内核子系统详细设计

> **文档定位**: 描述 MoQiOS 内核各子系统的核心数据结构、API、实现状态与依赖关系。
> **修订日期**: 2026-08-01
> **关联文档**: [moqios-architecture-current.md](./moqios-architecture-current.md)
>
> **2026-06-21 更新**: SMP 性能三件套（FPU/SSE 按任务 lazy save、Per-CPU 运行队列 +
> Work-Stealing、范围 TLB Shootdown）已全部实现并集成，本文相关章节（§2.2 调度器、
> §2.7 FPU/SSE 状态管理、§9 SMP 多核）均已更新。代码级审查与历史修复顺序仍见
> [current-code-review-and-fix-plan.md](./current-code-review-and-fix-plan.md)。
>
> **2026-06-21 新增功能**: 调度器 Profiling 基础设施（§2.8）、IPv6 协议栈（§4.10–4.12）、
> POSIX Capability 安全模型（§5.9）、Arch 抽象层（§11）。
>
> **2026-08-12 tmpfs 创建元数据**: `O_CREAT` 和 `mkdir` 新建的 tmpfs 普通文件或目录在
> `tmpfs_lock` 内、发布前设置为调用任务的 `euid:egid`，权限为
> `(requested_mode & 0777) & ~(umask & 0777)`。`umask` 为每任务状态，新任务默认 `022`，
> fork/clone 继承；普通 `O_CREAT` 打开已有对象不修改元数据，`O_CREAT|O_EXCL` 打开已有
> 对象返回 `-EEXIST` 且不执行 DAC、截断或引用计数变更。tmpfs 根目录、默认目录以及非
> tmpfs 文件系统的创建元数据行为不变。

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
12. [调试与日志](#12-调试与日志)

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
    refcount: []u16,      // 每页引用计数（CoW 支持）
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
| `addRef(phys)` / `decRef(phys) u16` | 引用计数（CoW 使用）；`decRef` 返回递减后的新计数值 |
| `allocContiguous(n) ?u64` | 分配 n 个连续页（DMA 用），返回基址物理地址 |
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

**Per-CPU magazine 层 (K2)**

文件: `mm/slab_mag.zig`（纯逻辑，可主机测试）+ `mm/slab.zig` 中的接线。

设计：每个 (CPU, 大小类) 一个 magazine——固定容量 8（`MAG_SIZE=8`）的对象指针 LIFO 栈，位于带锁的 SlabPool 空闲链表之前，使小类分配/释放热路径不再每次抢 pool 锁：

- **kmalloc 快路径**：`arch.irq.saveAndDisable()` 关中断 → 从本 CPU 的 magazine pop；为空则在 pool 锁内批量 refill 4 个对象（`REFILL_BATCH=4`）后再 pop；pool 也空（含 refillPoolLocked 缺页）则返回 null。
- **kfree 快路径**：关中断 → push 到本 CPU 的 magazine；满了则在 pool 锁内批量 flush 一半（`FLUSH_BATCH=4`）回 pool，之后再 push 必然放得下（`FLUSH_BATCH < MAG_SIZE`，有 comptime 断言保证）。
- **allocLarge / 大类 kfree 路径不经过 magazine，保持不变。**

**迁移安全论证**：所有 magazine 操作都在关中断窗口内完成。本 CPU 的上下文切换只能由中断（时钟 tick → `forceReschedule`，或重调度 IPI）或显式阻塞/调度调用触发，而 kmalloc/kfree 不含此类调用——因此关中断期间运行 CPU 不会变，窗口开始时读到的 `getPerCpuOrNull().cpu_id` 在整个操作期间有效。两个 CPU 永不共享同一 magazine；magazine 本身无需锁，pool 锁仍串行化所有 refill/flush。magazine 是纯 CPU 本地状态，与地址空间无关，PCID/CR3 切换无需任何处理。早期启动（GS base 未设置）时 `getPerCpuOrNull()` 返回 null，退化为 CPU 0 的 magazine。

**所有权不变式**：任一时刻每个对象恰好处于三处之一——(a) pool 空闲链表、(b) 恰好一个 CPU 的 magazine、(c) 用户手中。refill 只接收 pool 已从空闲链表摘除的对象；flush 先把对象移出 magazine 再挂回 pool 空闲链表。因此 magazine 持有的对象对 pool 而言视为**已分配**，pool 不会二次发放，对象既不重复也不丢失。

**stats 语义**：`getStats().total_allocs` 在 magazine 开启时统计"已从 pool 空闲链表签出"的对象数 = 活跃用户分配 + 各 CPU magazine 库存（每类每 CPU 至多 `MAG_SIZE`），是活跃分配数的上界；gate 关闭时仍为精确活跃数。`total_pages` 不受影响。

**Gate**：`slab.zig` 中 `pub const slab_magazine_enable: bool = true`；置 false 则 kmalloc/kfree 恢复 K2 之前的逐次 pool 锁行为（旧代码路径原样保留）。

**主机测试**：`tests/main.zig` 末尾 `// ─── slab magazine (K2) ───` 块，以 mock backing store 覆盖 push/pop LIFO、空/满边界、批量 refill/flush、部分 refill，以及模拟 kmalloc/kfree 协议下 20000 步随机混合操作的对象守恒（不重复、不丢失）校验。

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
- MAP_FIXED 的事务化替换目前只支持精确覆盖、完整跟踪的匿名私有 RW 4K 区域，且长度不超过 128 页；这些区域必须由 PMM 所有。替换前的资源检查失败返回 `ENOMEM`，原映射保持不变；成功替换后新页为零填充。其他已占用形状也返回 `ENOMEM` 且保持不变。这是有界资源事务，不是全局地址空间并发安全保证；统一锁、TLB shootdown 和更一般的回滚设计仍属于后续工作。
- 64条VMA表管理用户态映射区
- 配套 munmap 解除映射和 msync 同步脏页
- syscall mmap: 支持匿名映射 + 文件映射 (MAP_PRIVATE/MAP_SHARED)；G2 起文件映射改为
  页缓存支撑的按需分页 + 零拷贝 COW，详见 1.8.1
- mmap ABI 会拒绝未实现的 `flags`/`prot` 位并返回 `EINVAL`；当前支持的 flags
  为 `MAP_SHARED`、`MAP_PRIVATE`、`MAP_FIXED`、`MAP_ANONYMOUS`，
  protection 位为 `PROT_READ`、`PROT_WRITE`、`PROT_EXEC`（`prot=0` 表示 `PROT_NONE`）。
  匿名映射同时支持私有和共享语义；`MAP_SHARED|MAP_ANONYMOUS` 在 fork 后保留同一物理帧
  与可写权限，适合作为进程间共享内存使用。
  映射是否匿名只由 `MAP_ANONYMOUS` 标志决定；未设置该标志时，即使 `fd == -1` 也按
  文件映射处理并返回 `EBADF`，不会把无效文件描述符静默解释为匿名映射。
  该契约由 `mm/mmap_policy.zig` 的 host 测试覆盖，避免未知位被静默解释为已有语义。

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

- `brk`: 可在 `[Mm.brk_start, 天花板]` 内移动。`brk_start` 记录加载器留下的初始
  break（**程序 break 属于地址空间 `Mm`，不属于线程**：`CLONE_VM` 的线程共享同一个 `Mm`，因此共享 break；
  fork 和不带 `CLONE_VM` 的 clone 把父的 break 拷进子的新 `Mm`，loader 与 execve 在新建的 `Mm` 上设置，
  见文末"程序 break 属于 Mm"一节），收缩不能低于它（否则会解除镜像自身的映射）。增长逐页确认未被映射（`mapPage`
  会无声覆写活跃 PTE 并泄漏旧帧）并清零新页（`pmm.allocPage` 返回的帧带有上一使用者的
  数据）；收缩释放让出的页。增长/收缩/原地是三条独立分支——早期实现无条件写
  `for (old_page..new_page)`，收缩时区间反向，直接导致内核整数溢出 panic。
- 非 `MAP_FIXED` 的 `addr` 按 POSIX 视为建议：仅在区间空闲时采纳，否则内核另选地址。
  无条件采纳会让进程用 `mmap(&_start, ...)` 覆盖掉正在执行的代码页。
- 运行时覆盖: `hello30`（brk 增长/清零/收缩 + 匿名 mmap + hint 让位），
  冒烟门禁标记 `hello30: brk/mmap PASS`。
- VMA 扫描基线：`/proc/vma_stats` 输出 instrumented mmap 元数据事件的固定 64 槽
  模型次数、模型槽位总数、平均模型槽位、实际访问槽位总数及平均访问槽位；`hello67` 用 40 页碎片化映射验证历史
  模型契约，`hello73` 验收扩展 telemetry 的保守不变量。计数器是
  无锁诊断原子，不读取时钟、不改变映射决策；完整的动态 VMA 树替换决策见
  `vma-profiling.md`。
- x86 RSS 观测：`/proc/<pid>/rss` 只读统计 target task page table 内 present+user
  的 4 KiB leaf PTE（以及 2 MiB user PDE 的 512 页等价）；它不是 RLIMIT_RSS
  admission limit，也不按物理帧去重。hello68 锁定匿名页映射/解除映射的可观察变化。

用户态验收: `hello65` 映射一页匿名私有 RW 区域，写入哨兵后降低 `RLIMIT_AS`，确认等长
MAP_FIXED 替换以 `ENOMEM` 失败且哨兵仍在；恢复无限制后替换成功并确认新页清零。

### 1.8.1 文件映射按需分页（G2 零拷贝 + COW，H1 起 MAP_SHARED 写透）✅

文件: `mm/filemap.zig`（纯逻辑，host 可测）, `mm/mmap.zig`, `arch/x86_64/idt.zig`（`handleFileFault`）,
`fs/page_cache.zig`（`getPageFrame`/`markDirty`/`flushInode` + 驱逐保护）, `fs/tmpfs.zig`
（`tmpfsGetMapPage`/`tmpfsGetCtime`/`tmpfsEnsureMapPage`）, `fs/vfs.zig`（`flushMappedInode`/`syncAll`/`syncFile`）

G2 之前的文件 mmap 在建映射时把文件内容**即时读入**新分配的物理页；G2 改为真正的按需分页：
`mmap()` 只做校验并把后备元数据记入 `Task.mmap_regions`（`MmapRegion` 新增
`file_kind/prot/file_offset/file_size/file_idx/file_data/inode_id` 字段，全零 = 匿名，老初始化器不受影响；
H1 再加 `shared` 字段记录 MAP_SHARED），不触碰页表；首次访问触发 #PF，由 `handleFileFault`
按 `filemap.planFault` 决定行为。

- **校验**：offset 必须页对齐（否则 EINVAL）；fd 必须是常规文件
  （ramdisk/tmpfs/ext2/fat32，管道/socket/特殊文件 ENODEV）；O_WRONLY 打开返回 EBADF。
  H1 起接受 MAP_SHARED：`MAP_SHARED|PROT_WRITE` 要求 fd 可写（status_flags 低位为只读 →
  EACCES，与 Linux 一致）；ramdisk 不可写，`MAP_SHARED|PROT_WRITE` → EROFS（先于 EACCES
  判定——ramdisk fd 永远不可写，否则 EROFS 不可达）；ramdisk 只读 MAP_SHARED 允许，
  缺页时与 MAP_PRIVATE 一样复制为私有页（安全选择：ramdisk 帧是 Limine 模块内存、不属于
  PMM，直接映射会让 unmap 把它喂给空闲池；只读共享与私有副本字节相同，无观测差异）。
- **EOF 语义**：整页越过 EOF 的访问 → SIGBUS（Linux 语义，§6.55 起；此前为 SIGSEGV）；
  最后一个部分页正常供给，尾部清零。`file_size` 取 mmap 时的快照，判越界前刷新为实际
  大小（含 writeback 暂存），映射后增长的页可访问。
- **零拷贝共享帧**：tmpfs 直接映射其数据页；ext2/fat32 经 page_cache
  （命中 `getPageFrame` 直接拿物理帧；未命中先 `readFile` 填充缓存再取）。
  共享帧一律先 `pmm.addRef` 再以"只读 + COW 位(bit9)"映射——即使 PROT_WRITE，
  首次写入落入既有 `handleCowFault` 复制路径，文件内容永远不被 MAP_PRIVATE 写污染。
- **fault-around 预缺页（6.35）**：文件缺页服务成功后，向前预供给同区域最多
  15 页（64 KiB 窗口，Linux fault-around 同量级）——每页一次 #PF 往返的开销
  对顺序扫描摊薄 16 倍。窗口受区域末端与 EOF 截断；已有 PTE（含 swap 项）跳过；
  预供给失败非致命（页留待按需再缺）。MAP_SHARED 可写映射**不参与**预供给：
  供给即标脏，预供给会为无人写入的数据白付回写。真 2MiB PDE 大页**有意不用于**
  文件映射：零拷贝设计映射的是后备方自己的帧（tmpfs 页、page_cache 帧），它们
  逐 4K 分配、物理不连续，硬件大页要求 2MiB 连续帧——上大页必须复制 512 页进
  连续帧，恰好摧毁 MAP_SHARED 写透语义。
- **引用计数规则（最容易错的记账点）**：帧的所有者（page_cache 槽位 / tmpfs 条目）
  持有一个 ref，每个映射它的地址空间各加一个 ref。`unmapRange`/`destroyUserSpace`
  的 freePage 本质是 decRef，因此**永远不会**把缓存/文件系统仍持有的帧放回空闲池；
  反过来，缓存驱逐（`removePage` 的 freePage）也只是 decRef，映射侧的帧不会被抽走。
  page_cache 的 clock 驱逐**跳过 refcount > 1 的槽位**——否则 `removePageKeepPhys`
  会把仍被用户映射的活帧重复利用给新文件页。
- **ramdisk 例外**：Limine 模块内存不属于 PMM，无法引用计数，直接共享会让 unmap
  把它喂给空闲池，因此 ramdisk 页在缺页时复制为私有页（仍是按需加载，只是非零拷贝）。
- **ext2 打开槽位寿命**：故障路径用 `readFile(file_idx)` 读盘，因此 mmap 成功时
  `ext2.retainFile` 持有一份引用，`untrackMmapRange`（区域撤销/拆分）与
  `mmap.releaseFileRefs`（task 回收、execve 换镜像前）对称释放；fork 为子进程的
  ext2 区域补一次 retain。fat32 槽位 close 后不释放，无需 retain；tmpfs 用
  `ctime` 当代数标签（`tmpfsGetMapPage` 校验），条目被 unlink+回收后旧映射只会
  拿到零页而**不会**拿到复用槽位里别的文件的数据。
- **swap 交互**：`reclaimScanPass` 跳过 refcount > 1 的帧（COW 共享页与文件后备页），
  干净文件页本就可从后备存储重新缺页，无需占用交换槽。
- **MAP_SHARED 写透（H1）**：共享映射缺页时直接以后备帧的可写 PTE 映射（
  `filemap.sharedPte`，无 COW 位），写入直达 tmpfs 数据页或页缓存帧，所有共享者
  立即可见。tmpfs 稀疏空洞用 `tmpfsEnsureMapPage` 分配真实后备页（私有零页会悄悄
  "去共享"）；tmpfs 是内存文件系统，无需脏页跟踪。ext2/fat32 在映射可写时立即
  `page_cache.markDirty`（映射后硬件脏位无法廉价观测，宁可多写回不可漏写）；
  写回点：`untrackMmapRange`/`releaseRegionBacking`（munmap/exit/exec，经
  `vfs.flushMappedInode` → `page_cache.flushInode`）与 msync → `vfs.syncAll`
  （新增 `page_cache.flushAll` 一路，回写回调按 inode 高位标签分发到
  `ext2/fat32.writePageByInode`——按 inode 写盘、不动 i_size、不像 writeFile 那样
  顺手 invalidate 缓存）。写回 staged-writeback 叠加的选择：MAP_SHARED 缺页未命中时
  先 `vfs.syncFile` 把该 inode 的 writeback 暂存区刷到磁盘再读盘填缓存——若只做
  readBuffered 叠加，暂存区仍在，日后写回会用旧数据盖掉映射侧的新写入。
- **页缓存键名空间（H1）**：ext2 按 1KiB 逻辑块、fat32 按簇做缓存键，与 4K 映射页
  不同粒度；mmap 侧一律用 `filemap.mmapCacheKey`（bit63 置位）存取整 4K 页，避免
  撞上读路径只含一个文件系统块有效字节的条目（这一错位在 G2 的 ext2/fat32
  MAP_PRIVATE 路径上同样存在，本轮一并改走带标志的键修复）。
- **fork 与 MAP_SHARED（H1）**：`cloneUserPagesCow` 接收父进程区域表，落在
  MAP_SHARED 文件区域内的页跳过一次 COW 降级（否则子进程首写会被复制成私有页，
  父进程永远看不到），addRef 记账不变；munmap/exit 时各地址空间 decRef 平衡。
- **mremap/mprotect 补齐（H1）**：文件区域允许**原地增长**（新页不预映射，按需缺页；
  越过文件实际大小的页访问即 SIGBUS，与 Linux 允许增长过 EOF 但访问即 SIGBUS 的
  语义一致；移动文件区域仍拒绝——moveMapping 会把未缺页的共享帧换成私有零页）。
  mprotect 在改 PTE 之外同步更新文件区域的 prot 元数据（`filemap.planProtUpdate`
  分类 cover/head/tail/middle，部分覆盖时拆区域、ext2 片各补一次 retain，拆前先做
  槽位容量检查）；对获得 PROT_WRITE 的 MAP_SHARED ext2/fat32 区域，顺手把已缓存页
   markDirty——这些页此前以只读缺入，此后可写但不再经过缺页路径。
- **mprotect 原子事务契约**：先验证地址对齐、长度、保护位、用户边界和完整范围
  覆盖，再预留 VMA 分裂槽位及页表/数据页资源；预检失败返回 `-EINVAL` 或
  `-ENOMEM`，且不改变目标映射。预检成功后才提交 PTE 与保护元数据更新；
  `PROT_NONE` 清除 present 访问但保留帧，部分大页覆盖降级为 4 KiB 且保留数据。
  `user/hello74.c` 验收普通 4 KiB 页的相邻写入、恢复、PROT_NONE 子进程故障后恢复、
  无效参数回滚和 fork/COW 隔离。
- **openat2 严格边界（#320/#437）**：当前 native 与标准别名入口只接受
  `dirfd=AT_FDCWD`、`pathname` 指向有效已有路径、`open_how{flags=0,mode=0,resolve=0}`
  且 `size >= 24`；`size < 24`、无效 `dirfd`、非零 `resolve`、未知 `flags` 和无效
  `how` 指针分别拒绝并返回 `EINVAL`、`EBADF`、`EINVAL`、`EINVAL`、`EFAULT`。成功返回
  的 fd 必须由调用者关闭。`user/hello75.c` 以 raw syscall 同时验收 #320/#437。
- **statfs / fstatfs**：卷内路径或卷内 fd 返回该卷自己的数字（其余路径仍是内置的固定值）。ext4 取
  超级块计数器（总块数、空闲块、保留块 → `bavail`、inode 总数/空闲数），日志未回放的卷空闲数可能略旧；
  NTFS 扫描 `$Bitmap` 得到空闲簇（首次扫描后缓存到挂载槽，只读卷不会变）、扫描 `$MFT` 的 `$BITMAP` 得到
  MFT 记录总数/空闲数，位图上限 64 MiB（约 5.4 亿簇），更大的卷返回 EOPNOTSUPP。`f_flags` 恒带
  `ST_RDONLY`。statfs 只要求路径上各级目录可搜索，不要求目标文件可读（与 Linux 一致）。
- **access(2)**：卷内路径按文件真实 mode/owner 判定而非"能否打开"：`F_OK` 只要求存在；`R_OK`/`X_OK`
  看权限位（普通文件无任何执行位时 `X_OK` 对 root 也是 EACCES）；含 `W_OK` 一律 EROFS（root 亦然）；
  未知 mode 位 EINVAL；路径上目录不可搜索 EACCES，缺失 ENOENT。卷外路径仍只检查存在性。
- **大目录列表**：NTFS 目录是 B 树，getdents 按"第 N 项"恢复。最初实现每次从根重走整棵树（N 项目录
  列完要 O(N²) 次设备读，且全程持 `rofs_lock`；实测 6000 项目录第 5600–5700 项就要 5.6 万次读）。
  现在 `ntfs.Volume.nextDirEntry` 用可复制的 `DirCursor`（每层只存 块号 + 项偏移，不含指针，可在
  scratch 块被别的操作复用后继续）逐项推进，开销是树深而非已返回项数；`fs/dir_cursor_cache.zig` 每挂载
  缓存 4 个位置（LRU，按打开的目录描述符区分所有者，每个读者最多占两个槽）。getdents 在缓冲区装不下下一项时会多探一项，下次调用再要同一位置，因此
  **推进游标时不覆盖原位置**，两次都命中。位置不在缓存里（如 lseek 到任意偏移）退化为从头跳过，
  结果仍正确。ext4 目录按字节偏移恢复，本来就是线性的。
- **并发与锁**：`rofs_lock` 是**睡眠锁**（`sync/sleep_lock.zig`，FIFO 所有权交接，唤醒最老的等待者；
  内核实例化见 `sync/task_sleep_lock.zig`）。原先它是关中断的 `IrqSpinlock`，而 NVMe 读会让任务挂起等
  完成中断：持锁任务被切走后，下一个想用该卷的任务在关中断下自旋，两边都无法前进。用 gdb 抓到的现场：
  CPU0 `IF=0` 停在 `rofs.readAt` 的 ticket 自旋里，CPU1 空闲，`io_in_flight=0 io_done=1`（完成早已到达，
  持锁者无法被调度回来）。`mountFs`/`umountFs` 同理：整次挂载由 `mount_op_lock`（睡眠锁）串行化，路由表
  自旋锁 `mount_lock` 只在短临界区内取放，不包住任何设备 I/O（每个 `open()` 都要过 `rofsRoute`）。
  卸载先在表锁下摘掉路由项，再在无自旋锁的情况下销毁卷。AHCI/virtio-blk 读是轮询、不会挂起任务，
  因此不受影响（并发读在两者上同样验证通过）。睡眠锁只能用在可睡眠的上下文，rofs 的所有调用者都是
  syscall 路径。
- **mmap**：卷内文件可以 `mmap`（之前返回 ENODEV）。语义是"用文件内容初始化的私有映射"：mmap 时先在
  VM 锁**之外**把页读进私有帧（读卷可能睡眠——卷锁、NVMe 完成中断——而缺页路径和持 VM 锁者都不能睡），
  再在锁内一次性装入页表。因此：`MAP_PRIVATE` 可读可写（写只改内存副本，文件不变，fork 后父子互不可见）；
  `MAP_SHARED` 只读可用（内容等同私有副本，不随之后文件变化——卷本身只读也不会变）；`MAP_SHARED|PROT_WRITE`
  返回 EACCES；目录 ENODEV；偏移必须页对齐（EINVAL）；文件尾部的半页补零；映射不依赖原 fd，`close(fd)` 后仍有效，
  也不依赖卷是否仍挂载。上限 32 MiB（超出 ENOMEM，更大的文件仍可 `read`）。映射区域按匿名私有区域记账
  （`munmap`/`mprotect`/`fork`/RLIMIT 走既有路径，没有新的区域种类）。NTFS 稀疏文件的空洞映射为零页。
  纯策略在 `mm/rofs_map_policy.zig`（host 测试：错误顺序、上限、页数、尾页有效字节、溢出）。
- **dirfd 与相对路径**（`fs/at_path.zig`）：`openat`、`statx`、`readlinkat`、`faccessat`、`faccessat2` 的
  `dirfd` 现在对卷内目录描述符生效；`fchdir(fd)` 对卷内目录真正切换 cwd；`statx`、`readlink`、`access`、`statfs` 在 cwd 位于卷内时
  可用相对路径。卷目录 fd 只带（挂载槽、代数、记录号）而没有路径，所以路径是重建的：挂载点 + 卷内路径
  （`pathOf` 逐级向父目录查"哪个名字指向我"，从右往左拼）+ 调用者的相对名，再走常规的绝对路径查找，
  因此符号链接、`..` 出卷、权限检查都沿用既有逻辑。取舍：fd 之上的各级目录会被重新做搜索权限检查，而
  Linux 信任 fd 不再检查；只读卷上权限不会在 fd 打开后变化，所以只有"打开目录后降权"的进程才会看到差异。
  非目录 fd 作 dirfd 返回 ENOTDIR；`openat2` 也接受任意目录 fd。
  **所有文件系统的目录 fd 与 cwd**（hello121）：`at_path.resolve` 现在统一处理 ext2 目录 fd（用打开时的路径）、
  tmpfs 目录 fd（沿父链重建 `/tmp/...`）、`/dev` 目录 fd，空闲 fd 为 EBADF，非目录为 ENOTDIR；`dirfd_name.resolve`
  只是它的薄包装。`AT_FDCWD` 下的相对名在 cwd 不是根时与 cwd 拼接并规范化（`at_join_policy.underCwd`/`absJoin`），
  落在根下的单段名去掉前导斜杠交给平坦文件系统（ramdisk/FAT32 只认裸名），`tmp/`、`dev/`、`proc/` 开头的名字变成绝对路径。
  接入的调用：open/openat/openat2/creat、mkdir/mkdirat、unlink/unlinkat/rmdir、rename/renameat2、chmod/fchmodat(2)、
  chown/lchown、access/faccessat(2)、statx、readlink/readlinkat、link、symlink（只解析链接路径，目标原样保存）、truncate、
  setxattrat/getxattrat/listxattrat/removexattrat（同时支持 `AT_SYMLINK_NOFOLLOW`）。`chdir` 现在校验目标：
  不存在 ENOENT、不是目录 ENOTDIR、不可搜索 EACCES（ext2、tmpfs、/dev；挂载点的上级目录和 /proc 不校验），失败时 cwd 不变；
  `fchdir` 对上述各类目录 fd 都真正切换 cwd。ext2 目录 fd 现在跟随 inode，目录之后被改名或移动也能正确解析（见 hello147；
  这里原先记录的限制已解除）。顺带修复：`/tmpX` 不再被当成 `/tmp/X`（五处 `/tmp` 前缀判断都要求在分量边界）。
  修改类调用（`unlinkat`、`mkdirat`、`fchmodat`、`fchmodat2`、`renameat2` 的两个路径、`setxattrat`、`removexattrat`）
  由分发前的 EROFS 守卫按各自的 dirfd 展开路径再判断（`fs/rofs_guard_policy.zig` 的 `da`/`db` 字段），卷目录 fd
  下的名字一律 EROFS，卷目录 fd 无法解析时直接返回该错误，绝不退回到根盘上的同名文件。`unlinkat` 支持
  `AT_REMOVEDIR`（走 rmdir），其它 flag 位 EINVAL。
- **按描述符的系统调用**：对卷内 fd，`write`/`pwrite`/`ftruncate`/`fchmod`/`fchown`/`fallocate` 都被拒绝，
  `fsync` 返回 EINVAL（没有可同步的内容）。这些处理函数按描述符类型分派，而其它文件系统的描述符里
  ext2/fat32/tmpfs 的下标字段默认是 0；若某个处理函数不检查类型，就会对别的文件系统里 0 号对象动手。
  运行时在可写根盘上放一个"金丝雀"文件，对卷 fd 调用上述全部操作后断言金丝雀字节不变。
  `sendfile`、`splice`（卷文件 → 管道）和 `copy_file_range`（源）可以读卷文件；卷文件不能做 `splice` /
  `copy_file_range` / `sendfile` 的目标（只读）。
- **已知限制**：mremap 文件区域仅支持原地增长/收缩（移动返回 ENOMEM）；
  MAP_SHARED 可写页与随后对同一 inode 的 `write()` 系统调用之间不做一致性保证
  （writeFile 会 invalidate 该 inode 的缓存页，未刷出的映射写入可能丢失——请先
  msync）；MAP_SHARED 映射可写时页缓存 insert 失败（缓存满）会先刷本 inode 脏页
  重试一次，仍失败则缺页失败（SIGSEGV）——绝不退化为会丢写的私有副本；
  内核态 `copy_to_user` 对未缺页的文件映射返回 EFAULT（无内核态按需分页）；
  同一地址空间多线程并发缺同一文件页时后写 PTE 者胜出（与既有匿名按需分页同级竞态）。
- **运行时覆盖**：`user/hello46.c`（tmpfs 文件写模式串 → MAP_PRIVATE 映射 →
  close(fd) 后验证内容 → 尾部清零 → 写穿透后 pread 验证文件不变（COW）→
  fork 子进程缺页继承区域 + 越过 EOF 整页 SIGBUS），
  门禁标记 `hello46: PASS` / `hello46 done`；
  `user/hello48.c`（tmpfs MAP_SHARED fork 后子写父读零系统调用可见 →
  ext2 MAP_SHARED 写透 + msync 后另一 fd pread 验证落盘 →
  ramdisk MAP_SHARED|PROT_WRITE 返回 EROFS、只读共享可用），
  门禁标记 `hello48: PASS` / `hello48 done`。
- **Host 单测**：`tests/main.zig` 末尾 `// ─── file mmap (G2) ───` 块
  （区域查找、EOF 钳制、权限/PTE 合成、offset 校验、head-trim 偏移推进、合并规则）与
  `// ─── MAP_SHARED (H1) ───` 块（sharedPte 合成、共享 planFault 抑制 COW、
  4K 缓存键标志、mprotect 拆分分类、mremap 增长窗口）。

### 1.9 Swap 页面置换 (Clock算法 + u64位图分配 + 256MB swap) ✅

文件: `swap.zig`, `arch/x86_64/paging.zig`

- Clock二次机会算法页面回收
- 65536槽swap位图管理256MB交换空间，u64字级扫描+@ctz O(1)分配
- virtio-blk后端读写swap页
- 水位线自动触发内存回收
- #PF缺页时自动swap-in
- swapon按路径选设备（§6.45准入纯策略拒绝启动盘，EPERM）；swapoff真drain
  （§6.50：draining状态静默新换出、task快照按page_table_phys去重后逐Mm
  vm_lock走查换入、PMM OOM回滚re-arm/全排空才提交解除设备；hello101回归门）

### 1.10 用户态 2MiB 大页匿名 mmap（I1）✅

文件: `mm/huge_user.zig`（纯函数，host 可测）、`mm/huge_user_impl.zig`（arch 门控运行时）、
`mm/mmap.zig`、`mm/mprotect.zig`、`arch/x86_64/paging.zig`、`proc/fork.zig`、
`arch/x86_64/clone.zig`、`mm/user_space.zig`、`mm/swap.zig`、`mm/pmm.zig`

设计要点：

- **分配**：匿名 mmap 且最终选定 base 2MiB 对齐、`num_pages >= 512` 时，
  对前导完整 2MiB 块逐块尝试 `pmm.allocContiguous(512)`，成功则清零并以
  2MiB PDE 映射（user=true、writable 随 prot、**绝不置 global** —— PCID 隔离硬要求，
  `mapHugePage` 内有断言）；失败则该块及区域其余部分回退 4K。
  非 MAP_FIXED 时放置搜索先试 2MiB 对齐空槽（`findFreeRangeAligned2M`），
  找不到再退回普通 4K 粒度搜索（此时整段为 4K 映射）。
- **不变式**：区域的巨大页块永远是其**前** `huge_pages*512` 页
  （首块回退后不再尝试后续块；含巨大页的区域不与邻居合并）。
  `MmapRegion.huge_pages` 仅为信息性计数——所有变更路径都由页表驱动。
- **demote-first 规则**：任何部分变更先把巨大块拆成 512 个 4K PTE
  （`paging.demoteHugePage`：分配一页 PT、按相同物理基址+标志位生成 PTE、
  替换 PDE、本地 invlpg 整个 2MiB 范围）。munmap/mremap shrink 经
  `unmapRange` 预扫描：整块覆盖直接 `unmapHugePage` + 批量 shootdown +
  `pmm.freeContiguous` 释放 512 帧，部分覆盖先 demote；
  mprotect 整块覆盖原地改写 PDE 权限位（保持大页），部分覆盖 demote 后走 4K 改写；
  mremap 移动（`moveMapping`）先 `demoteRange`；fork/clone 的 COW 遍历只认 4K PTE，
  遇到巨大 PDE 先在父进程 demote（两侧同为 4K，COW 语义不变），
  因此巨大页永远不会带 COW 标记，#PF 的 COW 路径无需感知大页。
- **fork COW 降级的 TLB 失效（K4，2026-08-07）**：fork 的降级按页表批量化——
  每张 PT 一次 `shootdownRange`（CR3 过滤，仅命中运行该地址空间的 CPU）；
  clone 末尾的本地 `reloadCR3` 改为对全用户空间的过滤广播 shootdown。
  此前仅本地 invlpg/reload：CLONE_VM 对端 CPU 或 PCID no-flush 重入下的
  迁移父进程会残留可写陈旧项（理论窗口，未触发，属 CR0.WP 同类先修）。当前
  `pcid_alloc.decideSwitch` 默认关闭 no-flush；该优化必须在 per-MM epoch 与 CPU
  quiescence 验证完成后才能重新启用。
- **swap/reclaim 排除**：reclaim 扫描跳过巨大 PDE（`pd[idx] & (1<<7)`），
  巨大页不可换出——内存紧张时 demote 需要分配 PT 页，正是最分配不出的时刻。
- **拆除**：`destroyUserSpace` 对 2MiB PDE 用 `freeContiguous` 释放全部 512 帧
  （此前只 freePage 首帧，会泄漏其余 511 帧——巨大页每帧各有独立 refcount）。
- **读取路径硬化**：`isUserAccessible`/`isUserWritable` 识别巨大 PDE
  （否则 copy_from_user/copy_to_user 会拒绝巨大页上的用户缓冲区）；
  `getPageEntryRaw`/`setPageEntryRaw` 与既有 `getPageEntry`/`unmapPage` 一样
  拒绝下降进巨大页（否则 swap 条目探测、process_vm 会把数据帧当页表解析）。
- **开关**：`mmap.zig` 的 `pub const huge_user_enable: bool = true` 编译期总开关；
  非 x86_64 后端由 `huge_user_impl.zig` 的 stub 恒不启用。
- **Host 单测**：`tests/main.zig` 末尾 `// ─── user huge pages (I1) ───` 块
  （eligible 对齐/尺寸判定、hugeBlocksFor、demotePtes 的 512 PTE 物理/标志镜像与
  huge 位清除、替换 PDE 的表指针语义）。
- **运行时覆盖**：`user/hello49.c`（4MiB 匿名映射写读校验 → mprotect 前 1MiB 只读
  触发 demote 且数据保持、第二 MiB 可写 → munmap 后 2MiB → fork 子进程读回模式 →
  munmap 其余），门禁标记 `hello49: PASS` / `hello49 done`。

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
    kstack: []u8,               // 128KB 内核栈（KERNEL_STACK_PAGES=32 × 4KB，task.zig:23）
    mm: *AddressSpace,
    fdtable: FdTable,           // x86_64 上 128 个 FD（vfs.MAX_FDS；占用位图 free_bm 为 FD_WORDS 个 u64）
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

### 2.1.1 TaskPin 与 slot incarnation

每个任务 slot 都有一个单调递增的 `incarnation`。`reserveSlotLocked` 在 slot
重新发布前递增它；随后 `zeroSlot` 会清空任务结构，但保留这次 incarnation。这个顺序
也覆盖内核栈或 fd table 分配失败后再次使用同一 slot 的情况，因此失败的创建不会把
旧的 deferred 引用与新任务混淆。`TaskPin` 保存 `slot`、`tid` 和 incarnation，释放时
只有三者仍匹配才会减少新任务的 `operation_refs`；这使旧 pin 不能影响 slot 的后续
incarnation。incarnation 溢出时跳过 0，回到 1。

这个保证只用于身份和引用计数校验：`TaskPin` 本身不持有 `task_lock`，也不替调用者
延长其它资源（例如 Mm）的生命周期。调用者必须在访问期间持有 pin，并在处理 deferred
wakeup 前释放 pin；slot 只有在 zombie、无 operation refs 且满足调度器退出静默期后才
会被 reap。

### 2.2 调度器 ✅ Per-CPU 运行队列 + Work-Stealing（2026-06-21 完成）

文件: `proc/sched.zig`, `proc/per_cpu.zig`, `proc/task.zig`

**当前实现（M8-7 已完成 ✅）**

- **Per-CPU 运行队列**：`proc/per_cpu.zig` 定义 `PerCpuRunQueue` 结构，每 CPU 一份；
  256 槽环形缓冲区（`QUEUE_SIZE=256`），由 `IrqSpinlock` 保护。本地操作只持有本队列锁；
  跨队列窃取同时按 CPU ID 升序持有 thief/victim 两把锁，避免并发搬运损坏队列或 ABBA 死锁。
- **本地 FIFO 操作（2026-08-15 由 LIFO 改为 FIFO）**：`push` 在 `head` 端入队、`pop` 在
  `tail` 端取出最老任务，O(1) 轮转公平。原 LIFO（最近压入先出）在一个睡眠/唤醒循环者
  （每次 unblock 都重新压栈顶）加上每次切换都被重新入队的 idle 的组合下，会把第三个就绪
  任务永久压在栈底——两个 nanosleep 循环者即可让另一个就绪任务饿死数千 tick（在阻塞式
  nanosleep 落地后实测复现：hello54 的子进程永远拿不到 CPU）。`popRtAware` 的非 RT 路径
  同步改为 FIFO；RT 任务仍按 rank 选优、平级取最老。SK-17 探针断言同步更新为 FIFO 序。
- **Work-Stealing**：仅当本地队列为空（idle）时触发，`tryStealForCurrent` 以
  TSC 派生的随机 CPU 为起点扫描其他 CPU 的队列，调用 `steal_half` 从对端 `tail`
  端窃取约一半任务（>1 才偷，留 1 给被偷者避免乒乓）。
- **CPU 亲和性尊重**：`Task.cpu_mask: u64`（位 N = 允许 CPU N；`0` = 任意 CPU，可被偷），
  `steal_half` 跳过掩码不含本 CPU 的任务并将其放回原队列；不在掩码内的 `last_cpu` 不作归位提示，
  改用掩码里最低的 CPU（`sched_policy.cpuAllowed` / `homeCpu`）。
- **`Task.last_cpu: u8`**：记录任务最近一次运行的 CPU，作为 enqueue 时的归位提示
  （warm cache hint）。
- **调度入口 `pickNext` 三段式回退**：① 本地 `pop` → ② `tryStealForCurrent` 跨核
  窃取 → ③ 全局位图回退（`task.pickReadyForCpu`，与亲和性扫描兼容）。
- **③ 是安全网，不能当作发现新任务的正常途径（2026-07-26）**：每次上下文切换都会把换下来的
  任务重新入队，因此只要 CPU 上有两个任务来回 ping-pong，①就永远有货，③永远走不到。任务
  必须**显式发布**才可能被调度：`createUserProcess` 建出的任务处于 `.blocked`，由创建者在
  构造完毕后调用 `task.publishRunnable(slot)`（`.blocked → .ready` + `sched.enqueue` +
  跨 CPU kick）。fork、clone、loader 的 ELF/flat 两条路径都走这一步。此前四处都没有入队，
  新任务只在 CPU 恰好跑空时才被捡起；fork 靠父进程随即阻塞在 waitpid 掩盖了这一点，线程
  创建者不阻塞，缺陷即刻显形。
- 时间片 10 个 tick（100ms），LAPIC timer ISR 触发 `schedule()`，调用
  `switchContext(prev, next)`（`arch/x86_64/context.S`）。
- **LAPIC 映射先于驱动**：`lapic.mapEarly` 在 ACPI 解析之后、任何驱动初始化之前映射 LAPIC MMIO（定时器仍在 `lapic.init` 启动）。
  NVMe/AHCI 的启动自测是 MSI 中断驱动的；LAPIC 未映射时 `eoi()` 是空操作，被漏掉 EOI 的向量 242 会一直处于 in-service，
  按优先级挡住 CPU0 的定时器（240），CPU0 从此不再调度（review 第五十四轮）。
- **唤醒抢占（2026-10）**：所有 `.blocked → .ready` 统一经 `task.readyFromBlockedLocked`，
  `unblockTask*` / `publishRunnable` 释放 `task_lock` 后调用 `sched.notifyWake(t)`，由
  `proc/wake_preempt_policy.zig` 决定：本地严格更优 → self-IPI（在 `sysretq`/`iretq` 恢复
  IF 的第一刻切换）；远程不劣于目标 CPU 当前任务 → reschedule IPI；否则不打扰。原先散落的
  `kickRemoteForTask` 已删除——eventfd、unix socket、timerfd、SysV sem、MoqIPC、NVMe 等
  从不通知目标 CPU 的唤醒点自动获得同样语义。验收 `hello104`（同 CPU futex 唤醒 FIFO
  线程，延迟从 200 ms 降到 <1 ms）。
- **调度通道分型**：`proc/sched_pass_policy.zig` 区分 `tick` / `ipi` / `yield`。只有 BSP 的
  硬件 tick 推进维护；强制通道保留 RT 任务原时间片（IPI 不再重置 RR quantum）；RT 任务
  `sched_yield` 让给同级或更优；FIFO 时间片到期时若有严格更优的就绪任务则让出。
- **idle 不再抢走就绪任务的 CPU**：`popRtAware` 的选择规则抽成 `sched_policy.PopChoice`，
  有普通任务时跳过 idle 类（优先级 255）条目；`keepsCpuOverIdle` 保证可运行的当前任务
  不会因为换出者“先选后入队”而被换成 idle（被改绑到别的 CPU 时仍会离开）。
- **超时扫描每 tick 一次**：BSP 每个硬件 tick 运行 `bspTimedWaitTick`（futex / POSIX mq /
  epoll / timerfd / POSIX timer / alarm / itimer / **MoqIPC 超时**——§6.51 起
  timeoutTick 仅由此处驱动，`bspSlowMaintenance` 不再重复扫描），timerfd 与 POSIX timer 用
  `lib/deadline_hint.zig` 无锁门控；timerfd 的到期时间是 `tsc.nanos()` 纳秒（`expiry_ns`），周期 timerfd 按
  `time_policy.forwardPeriodic` 保持相位、补齐错过的到期次数（hello291）；reap、writeback、TCP、ICMPv6 留在
  `bspSlowMaintenance`（100 ms）。epoll 超时改用 TSC 纳秒截止时间，阻塞时立即让出 CPU。
- **RT 带宽限流（2026-10 第二轮）**：每 CPU 每 100 个硬件 tick 允许 RT 类跑 95 tick
  （`rt_bandwidth_policy`）。空转的 SCHED_FIFO 过了预算必须把 CPU 给 OTHER。RR 保持 POSIX：
  同级轮转，没有同级则时间片到期让给更低优先级（hello44 的 OTHER 父进程靠这个 fork 出
  第二个 RR 子进程）。
- **reschedule IPI 去重**：每 CPU `resched_pending`；已有 IPI 在路上则 `kickCpu` 不再发。
- **僵尸回收在独立线程**：BSP tick / waitpid 只做 O(1) 摘链；`proc/reaper.zig`（钉在 CPU0
  的低 RT 优先级内核线程）在开中断下释放地址空间。验收 `hello108`。

**API**：`schedule()` / `yield()` / `wakeup(task)` / `sleep(ms)` / `addTask(task)` /
`per_cpu.enqueueTask(t)` / `per_cpu.tryStealForCurrent()`.

**IPC task lifetime pins**：`send`、`receive`、`reply` 和 `notify` pin a remote
wake target with `allow_exiting=false` while holding IPC authority, then release
authority before `unblockTaskIfIncarnation`. `TaskPin` holds an operation
reference that prevents reap/slot reuse; it does **not** hold `task_lock`.
Every successful pin is released after the deferred wake. If pin acquisition
fails (including operation-reference exhaustion), the IPC registration and
queued message/notification state remain valid and the operation returns
`.not_ready`. These source-contract checks do not replace SMP/QEMU runtime
testing.

**意义**：在此之前 SMP 模式下所有 CPU 共享一把全局 `sched_lock` + 静态任务表的亲和性
扫描，AP 只能跑被显式绑定到自己的任务；现在 AP 通过 work-stealing **真正参与用户任务并行**，
忙 CPU 主动卸载、闲 CPU 主动拉取。

**细粒度调度选取：原子任务认领协议（J2，2026-08-04 完成 ✅）**

文件: `proc/sched_claim.zig`（纯模块，无 arch 依赖，host 单测覆盖）、`proc/sched.zig`、
`proc/task.zig`

- **回滚门**：`sched.sched_fine_grain_enable`（默认 `true`）。为 `false` 时
  `timerTick` 走 `timerTickLegacy`——旧的全局锁路径**逐字节保留**；为 `true` 时走
  `timerTickFg`。门切换两种构型都通过 `zig build` 验证。
- **认领协议**：一个 CPU 只有在 `Task.state` 上赢得 cmpxchg（`.ready → .running`，
  `sched_claim.tryClaim`）之后才允许运行该任务。这取代了旧不变量"持有 `sched_lock`
  就不会被别的 CPU 选中同一任务"。状态机的跨 CPU 转移全部收口在 `sched_claim`：
  `.ready → .running` 只能由 `tryClaim` 完成（唯一出口，故两 CPU 永不重复认领）；
  `.running` 的出口只有运行者自己（阻塞/退出）或属主 CPU 换出时的
  `releaseToReady`（cmpxchg `.running → .ready`）。唤醒路径只在 `.blocked` 任务上
  做 `store(.ready)`，而 `.blocked` 任务按定义不可被认领，因此普通唤醒写永远不会
  与一次**成功**的认领竞争。
- **选取路径改造**：`pickNextFg` 保持三段式回退（本地队列 → 窃取 → 位图），但只在
  认领成功后才返回：① `popRunnableClaim` = 队列锁内 `popRtAware`（RT 语义不变）+
  state/affinity/isCurrentOnOtherCpu 过滤 + cmpxchg 认领，认领失败丢弃该条目继续；
  ③ 位图回退先 `pickReadyForCpu`（task_lock 快照）再 cmpxchg 认领，失败重选——
  `.ready` 的唯一出口是成功认领，故重选不会返回同一任务，循环有界（≤ MAX_TASKS）。
  ② 窃取逻辑不改动（队列锁本来就按 CPU-id 升序成对获取）。
- **换出任务最后发布**：`timerTickFg` 的切换路径把旧任务的 `.running → .ready` +
  重新入队推迟到锚点/current/CR3 全部切换完之后（`releaseOldTask`）。在此之前旧任务
  保持 `.running` 不可认领，任何远程 CPU 都无法在本 CPU 仍运行于其内核栈上时开始执行
  它——旧代码在 `sched_lock` 释放前就重新发布旧任务，整个中断尾声都是双栈窗口。
  后来发现仅推迟到 `releaseOldTask` 仍不够：该函数运行时 CPU 还站在旧任务的内核栈上，
  `interruptDispatch` 的返回与 `commonStub` 尾声都还要用这条栈，他核此时认领旧任务就会
  与之共用同一内核栈（放大实验下稳定 panic）。现在 `releaseOldTask` 只把旧任务索引记入
  per-CPU `pending_release`（`gs:116`），由 `commonStub` 在 `movq %rax,%rsp` 切到新栈之后
  调用 `sched.pendingReleaseFlush()` 才真正 `releaseToReady` + 入队；旧任务因此只在
  本 CPU 已离开其内核栈后才可被认领。没有 per-CPU 数据时回退为直接发布。
  对已阻塞/退出的旧任务（`releaseToReady` 本来就失败），`pending_release` 同时充当"仍在
  本 CPU 栈上"的标记：`recordOldTask` 先于 `setCurrentIdx` 写入它，`task.isCurrentOnOtherCpu`
  / `isCurrentOnAnyCpu` 先读 `current_task_idx` 再读 `pending_release`，所以别的 CPU 的
  选取路径不会在 [setCurrentIdx → 尾声] 之间认领刚被唤醒的旧任务。
  legacy 路径（`sched_fine_grain_enable` 关闭）与 `apBootstrapIdle`/`portableKernelSwitch`
  未审查。cmpxchg 同时兼任旧的 `state == .running` 检查：
  切换窗口内自行阻塞/退出的任务（waitpid 父进程、exitTask、信号杀死）发布失败，
  不会被重新入队。
- **`sched_lock` 还剩什么**：细粒度模式下热路径不再使用它，仅保留给 legacy 回滚体
  与（当前无调用方的）`tryStealTask`。BSP 维护段（reapZombies/writeback/TCP/timerfd/
  futex 等）本来就不需要调度锁——每个被调方自带锁；`reap_counter` 是 BSP 私有。
  快速路径（`countActiveOnThisCpu`、FIFO 无量子守卫、force_pick RT 守卫
  `peekBestRankKey`）全部经原子读，无全局锁。
- **IRQ 屏蔽**：legacy 路径靠 `sched_lock.acquire` 顺带 cli；细粒度路径没有锁，因此
  `timerTickFg` 入口显式 `saveAndDisable`、出口恢复——否则从系统调用上下文（IF=1）
  触发的让出陷阱（int 252）可能在切换中途嵌套第二个定时器 IRQ，在同一内核栈上重入
  调度器。
- **新锁序**：`task_lock → 每 CPU 队列锁`（唤醒路径）；窃取时两把队列锁按 CPU-id
  升序成对获取；选取路径从不同时持有 {队列锁， task_lock} 中的两把。legacy 模式仍为
  `sched_lock → task_lock → 队列锁`。
- **RR/FIFO/force_pick/RT 守卫语义**：全部保留——FIFO 无量子补充、force_pick 只在存在
  严格更优 rankKey 时抢占 RT、`popRtAware` 同级取最老入队者、位图回退
  `MAX_PICK_KEY` 排除 idle（255），逐条与 legacy 同构。
- **验证**：host 单测 `tests/main.zig` "sched claim (J2)" 块（7 个用例：唯一赢家、
  对 blocked/zombie/running 拒绝认领、release 拒绝非 running、释放后可再认领、
  4 线程 × 5000 轮 cmpxchg 竞争独占性不变量）；运行时回归 `qemu_smoke.sh`（SMP=1/4）
  与 `qemu_smoke_stress.sh`（SMP=4 × 10 轮，含 hello50 四 worker 并发
  fs/pipe/udp/mmap 压力），零 AFFDIAG。

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
`ipc`、阻塞的文件锁、`pause`）都走同一条路径，因此修正落在 `forceReschedule` 自身而非调用点。
阻塞的 `flock` 和 `fcntl F_SETLKW` 现在不再只靠让出：冲突时把自己标成 `.blocked` 并发布
`sleep_deadline_ns`，由锁释放或下一个时钟 tick 唤醒（`fs/file_lock.zig`，hello290）。
此前无法触及是因为**没有任何用户程序调用过 `sched_yield`**，`hello31` 是第一个。

**实时调度类 SCHED_FIFO / SCHED_RR（F3，2026-08-02 完成 ✅）**

文件: `proc/sched_policy.zig`（纯策略模块，无 arch 依赖，host 单测覆盖）、`proc/sched.zig`、
`proc/per_cpu.zig`、`proc/task.zig`

- **策略存储**：复用 v37.0 引入的 `Task.sched_policy`（0=OTHER / 1=FIFO / 2=RR，与 Linux
  编号一致），fork 时继承。RT 任务的 `Task.priority` 沿用 sched_setattr 的**保留优先级带**
  约定：sched_priority 1..99 → 内核优先级 98..0（带 0..98，数值越小越优先）；OTHER 任务保持
  nice 带（nice -20..19 → 0..39，默认 20）；idle 仍为 255。
- **类优先比较**：由于 OTHER nice 带与 RT 带数值重叠，选择路径**不跨类比较裸优先级**，而是
  比较 `sched_policy.rankKey(policy, priority)`——RT 键 0..98 恒小于任意 OTHER 键
  （100+priority）。OTHER 内部键序与旧裸优先级比较完全等价，故无 RT 任务时选取结果
  **逐字节不变**（位图回退的 `best_key` 初值 `MAX_PICK_KEY=355` 保持 idle（255）不可选，
  与旧 `best_prio=255` 初值语义一致）。
- **两条选择路径都已 RT 化**：① per-CPU 队列 `popRtAware`——队列无 RT 任务时退化为 FIFO
  `pop`（2026-08-15 起，见 §2.2）；有 RT 任务时扫描选最优 RT 键，**同优先级取最老入队者**，使同级
  SCHED_RR 任务轮转而非反复弹出刚重新入队的任务。③ 位图回退 `task.pickReadyForCpu` 同上
  改用 rankKey 比较。
- **量子**：SCHED_FIFO 无量子——`timerTick` 与 `hardwareTimerTick` 在时间片耗尽时若当前
  任务为运行态 FIFO 则直接补充时间片返回，FIFO 只在阻塞 / yield / 退出时让出 CPU。
  SCHED_RR 量子为 10 tick（≈100ms，与 OTHER 时间片同值），到期重新入队后由同级 RR 对端轮转。
- **IPI 抢占防护（2026-08-02 修订）**：重调度 IPI（`force_pick`）**不再**能单纯为唤醒事件
  抢占运行中的 RT 任务——`timerTick` 先用 `peekBestRankKey()` 只读扫描本核队列与位图回退，
  仅当存在**严格更优** rankKey 的可运行任务时才让 RT 任务让出。此前每个远程唤醒 IPI 都会
  切入 FIFO/RR 的执行（SMP 下 hello44 偶发 "fifo child preempted" 的部分原因）。
- **sched_setaffinity 迁移（2026-08-02 修复）**：对当前正在其它 CPU 上运行的任务设置
  affinity 现在会触发迁移（kick 目标 CPU + 当前 CPU 重调度；切换出时 `enqueueTask` 按
  affinity 入队目标 CPU 的队列）。此前运行中的任务永远停留在原 CPU——hello44 钉 CPU 0
  时实际运行在别的核上，导致"同核 FIFO 压制"测试在 SMP=4 下偶发失败（根因，非调度器缺陷）。
- **nice 正交**：`setNice`/`getNice` 对 FIFO/RR 任务为 no-op / 返回 0（Linux：nice 只影响
  OTHER 类）。
- **系统调用**（MoQiOS 编号，Linux 号 156/157/146/147 在本分发表已被 msgget/msgsnd/
  epoll_create1/epoll_ctl 占用）：#473 `sched_setscheduler(pid, policy, param{sched_priority})`、
  #474 `sched_getscheduler(pid)`、#475 `sched_get_priority_max(policy)`（FIFO/RR→99，OTHER→0）、
  #476 `sched_get_priority_min`（FIFO/RR→1，OTHER→0）。校验：OTHER 要求 priority==0，
  FIFO/RR 要求 1..99，非法返回 `-EINVAL`，pid 不存在 `-ESRCH`。RT→OTHER 迁移时优先级复位为
  默认 nice-0 带值 20。**权限模型**：MoQiOS 无 uid 特权分级（所有任务 uid 0、全 capability），
  任何任务可对任意 pid 设置 RT 策略——与既有 sched_setattr 一致；将来引入 uid 体系时应在
  此处加 CAP_SYS_NICE 门。
- **饥饿警告（starvation caveat）**：可运行的 FIFO/RR 任务会**无条件**压制同 CPU 上所有
  OTHER 任务（包括 shell 与 init）；一个永不阻塞的 FIFO 死循环会永久饿死其 CPU 上的
  OTHER 工作。idle 线程仍保持可调度（其就绪路径不经被压制的比较）。无 RT 任务时调度行为
  与 F3 之前完全一致。
- **验证**：host 单测 `tests/main.zig` “RT scheduling (F3)” 块（类比较 / 量子 / 钳制 /
  校验）；运行时回归 `user/hello44.c`（优先级上下限、FIFO 子任务压制 OTHER 忙循环期间
  父进度计数冻结、两个 RR 子任务互相观察到对方推进、非法参数 EINVAL），经
  `sched_setaffinity` 钉在 CPU 0 使 SMP>1 下亦确定。

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
- **默认动作分类（2026-08-15）**：`signal.defaultAction()` 把每个信号归为
  terminate / ignore / stop / cont 四类；`SIGSTOP/SIGTTIN/SIGTTOU` 默认停（不可捕获、
  不可忽略——SIGSTOP 连 handler 位都被强制忽略）、`SIGCONT` 默认继续。tick 投递路径
  （`sched.deliverSignalToRunningTask`）与 syscall 返回路径
  （`checkSignalsOnSyscallReturn`，已接入 waitpid/read/nanosleep）共用同一分类。
- **投递语义**：阻塞中的任务收到信号会被 `kickIfBlocked` 唤醒，等待循环按惯例复查
  `pendingFatal`（经 `exitTask` 终止）与 `pendingActionable`（返回 -EINTR）。
- **sigreturn 修纲（2026-08-15）**：syscall 出口的 exec 重定向（fork/exec/信号/sigreturn
  共用）此前丢弃已保存的 rax 并把新栈指针留在 rax 里返回用户态——sigreturn 因此把"用户
  栈地址"而非 sigframe 保存的 rax 交还（hello58 实测：read 的 -EINTR 返回值被吞）。现在
  重定向前先弹出原返回值，三种重定向（execve 不在乎 rax、handler 入口参数在 rdi、
  sigreturn 必须还原）全部正确。

### 2.4a 作业控制（job control v1，2026-08-15）✅

文件: `proc/jobctl.zig`, `proc/pgrp.zig`, `proc/signal.zig`, `fs/ioctl.zig`, `fs/vfs.zig`

- **单一终端模型**：一个全局控制终端（ctty），`ctty_owner_sid` 由首个 TIOCSPGRP 调用者
  认领，`foreground_pgid` 记录前台进程组；fd0 的 read 前经 `jobctl.stdinJobCheck` 做前后台
  判定。v1 无 `/dev/tty` 文件节点、无 TOSTOP（后台写不拦）。
- **后台读 SIGTTIN**：后台组读 fd0 → 给全组发 SIGTTIN：已装 handler 的成员走 pending
  投递 + read 返回 -EINTR；默认动作的成员 `stopTask` 置 `Task.stopped` 并内核内等待，
  直到 TIOCSPGRP 把它所在组切为前台 + SIGCONT 解除停止，再进入真正的键盘读。
  SIGTTIN 被阻塞/忽略时按 POSIX 返回 -EIO。
- **停止/继续语义**：`Task.stopped` 是独立于调度 state 的标志；普通 wait-queue 唤醒
  （`unblockTask`/`wakeOne`/`wakeAll`）对 stopped 任务一律抑制，只有 SIGCONT
  （`continueTask`，POSIX：即使被阻塞/忽略也生效）能复活；致命信号先清 stopped 再唤醒
  以保证可杀。
- **进程组/会话权限收紧（2026-08-15）**：syscall 层的 setpgid/setsid/getpgid/getsid 全部
  委托 `proc/pgrp.zig`（此前 syscall 入口内联了一个无任何校验的"简陋版"，任意进程可改写
  任意任务的 pgid）。严格语义：只能改自己或子进程、目标组必须已存在于同会话、会话长不
  可改 pgid、新建组时禁止会话长建组。`syscallWaitpid` 现在透传 options（WNOHANG 此前被
  静默丢弃，是 waitpid(-1,…,WNOHANG) 永久阻塞的根因）。
- **停止/继续报告（hello284）**：`stopTask(t, signum)` 和 `continueTask` 在状态真正改变时调用
  `task.noteChildStateChange`：在 task_lock 下给子进程记下待报告的变化（`Task.wait_report`，
  规则在 `proc/wait_report_policy.zig`：停止报告为 `(sig << 8) | 0x7f`，继续报告为 `0xffff`，
  每次变化只报告一次，新的变化取代未报告的旧变化），并唤醒阻塞在 waitpid 里的父进程；父进程
  的 SIGCHLD 动作没有 `SA_NOCLDSTOP` 时再发 SIGCHLD（`CLD_STOPPED`/`CLD_CONTINUED`）。
  `waitpid` 带 `WUNTRACED`/`WCONTINUED` 时经 `takeWaitReportLocked` 取走报告；阻塞前在同一把
  锁下再检查一次，所以变化不会从检查和阻塞之间漏掉。
- **进程级信号作用于整个线程组（hello286）**：`kill(pid>0, sig)` 经 `signal_syscall.sendToProcess`。
  `proc/group_stop_policy.zig` 的 `actsOnEveryThread` 决定哪些信号发给组里每一个线程：`SIGKILL`、
  `SIGCONT` 和 `SIGSTOP` 总是，`SIGTSTP`/`SIGTTIN`/`SIGTTOU` 只在目标进程对它取默认动作时（装了
  handler 或 `SIG_IGN` 的只发给组长）。其余信号只发给被点名的那个任务。父进程 `waitpid` 看到的
  停止报告不取决于发送顺序：`signal.stopTask` 经 `task.markStopped` 在 `task_lock` 内置 `stopped`
  并扫描同组，只有让整组最后一个活着的成员停下的那一次才经 `groupLeaderOf` 找到组长、由它报告
  （`group_stop_policy.completesStop`）。`tkill` 对这些信号同样改走 `sendToProcess`，作用于整个进程（hello286 H）；其余信号只发给被点名的线程。睡在 `pause`/`sigsuspend` 里的任务遇到未阻塞的默认停止信号时，由 `waitForSignal` 经 `signal.takePendingStop` 停下，`SIGCONT` 后接着等；时钟中断对 `.blocked` 的任务不再自己停止，把位放回（hello286 I）。睡在 futex 等待里的线程同样在那里停下（`signal.stopWhileWaiting`），继续后重新检查等待条件；发送端置位后若发现目标已经睡下，就直接停下它（hello286 J）。成员走 `exit()` 而不是停止、且组里其余成员都已停下时，`exitTask` 补上这次整组停止的报告（`group_stop_policy.exitCompletesStop`，hello286 J）。整组 `SIGCONT` 恢复每个线程，但只给被点名的那个任务排上信号（`group_stop_policy.deliversContinue`，其余成员走 `signal.continueOnly`），handler 只运行一次；`tkill` 走整组路径时带 `SI_TKILL`（hello286 K）。管道读写（`vfs.pipeRead`/`pipeWrite`）和 `waitpid`/`waitid` 的等待也会处理默认停止信号：挂上等待队列后读一次待处理位，有就原地停下，继续后重新检查条件；`clone` 在创建线程之前先处理调用者待处理的停止，有致命信号时返回 `EINTR`，信号在返回路径上投递（hello286 L、M）。单目标的 `SIGKILL` 先把待处理位置上、再清 `stopped`。停止的任务在离开 CPU 之前
  不会回到用户态：系统调用返回路径（`syscall_entry.deliverSignalAt` 的 `.stop` 分支）循环
  `forceReschedule` 直到 `stopped` 被清除，期间来的 `SIGKILL` 在返回用户态前就结束任务；
  `timerTickFg` 对已停止的当前任务即使本 CPU 没有其他就绪任务也切走，不恢复原帧。
  切走需要本 CPU 有自己的 idle 线程可认领：BSP 的 idle 由 `sched_boot.createIdleThread` 绑在 CPU 0
  上（`createKernelThreadAffinity(..., 0)`），`task.idleThreadLocked` 优先取恰好绑在本 CPU 上的 idle。
  此前 BSP idle 不绑定，空闲的 AP 会把它拿走，CPU 0 上被停的任务在 `pickBootstrapKernelPreferIdle`
  返回空时继续跑自己的用户帧（hello286 G）。
- **exit_group（hello287，系统调用 501）**：`lifecycle.exitGroup` → `task.beginGroupExit`：在 `task_lock` 下给线程组每个
  活着的成员记下 `group_exit_code`（`proc/exit_group_policy.zig` 的 `claim`：先记下的保留），再给调用者以外的成员发
  `SIGKILL`；调用者随后走 `exitTask`。`exitTask` 开头用 `finalStatus` 把成员自己的 `128+sig` 换成组的状态并标成正常退出，
  所以组长的 wait 状态就是 `exit_group` 的参数。libc 的 `_exit` 走 501，`pthread_exit` 走 `SYS_exit`（只结束一个线程）。
  进程随最后一个线程退出（hello287 G/H）：组长已是僵尸而组里还有活着的成员时，`reap_policy.verdict` 返回 `.skip`，
  `waitpid`/`waitid` 不报告它；最后一个退出的线程把状态写到组长上并代它发 `SIGCHLD`。
- **rt_tgsigqueueinfo（hello288，系统调用 226）**：`signal_syscall.rtTgsigqueueinfo`。检查顺序在 `proc/proc_id_policy.zig` 的
  `tgsigqueueinfoVerdict` 里（宿主机测试 1 条）：先拷贝 siginfo（读不到是 `EFAULT`），再拒绝非正的 tid/tgid（`EINVAL`），
  再按 `siginfo_policy.queueinfoAllowed` 查 si_code（伪造的 code 是 `EPERM`，这里"发给自己"是调用者的 **tid** 等于目标 tid，
  与 `rt_sigqueueinfo` 按 tgid 判断不同），再查目标线程存在且属于给定的 tgid（否则 `ESRCH`，排在信号号检查前面），
  信号号超过 64 是 `EINVAL`，权限检查对 sig 0 也生效，sig 0 只探测。投递只发给被点名的线程；
  `SIGSTOP`/`SIGCONT`/`SIGKILL` 和取默认动作的 `SIGTSTP`/`SIGTTIN`/`SIGTTOU` 经 `sendToProcessWith` 作用于整个进程。
  `rt_sigqueueinfo`（222）同样按调用者的 tid 判断"发给自己"（非主线程用 `SI_USER` 发给 `getpid()` 是 `EPERM`），检查顺序在
  `proc_id_policy.sigqueueinfoVerdict`（不存在的 pid 是 `ESRCH`，排在信号号前面），停止、继续和 `SIGKILL` 也作用于整个进程（hello288 F/G）。
  进程级的普通信号（`kill(pid)`、`rt_sigqueueinfo`）只投递一次：被点名的线程阻塞它时，改投同一进程里第一个不阻塞它的线程
  （`group_stop_policy.processRecipient`），都阻塞时留在被点名的线程上待处理（hello288 I），同时记进线程组共享的 `GroupState.held_signals`；之后任何线程解除阻塞（`sigprocmask`、`rt_sigsuspend`、`sigreturn`、`ppoll`/`pselect6`/`epoll_pwait` 的临时掩码及其恢复）都经 `signal_syscall.claimHeld` 把它从兄弟线程上接过来，由先解除阻塞的线程处理（`shared_pending_policy`，hello288 J）。实时信号也进这个集合，接手时经 `signal.moveRealtime` 把所有排队实例按发送顺序一起搬过来（hello288 N）。目标线程没有阻塞、且处理方式是忽略的信号在发送时就丢弃，不排队（`signal_action_policy.droppedAtSend`，Linux `sig_ignored`，hello288 O）；POSIX 定时器过期和 `mq_notify` 也走这条发送路径（hello288 P）。`rt_sigpending` 把 held 集合并进报告，所以任何线程都看得到这些进程级信号；`rt_sigtimedwait` 等待其中一位时经 `takeHeldSignal` 从兄弟线程上把它和 siginfo 一起取走（hello288 K）。`tkill` 的线程级信号不进 held，另一个线程的 `sigpending` 看不到。被点名的线程退出时，`signal_syscall.handOffHeld` 把挂在它上面的 held 信号连同 siginfo 交给还活着的兄弟线程，进程级信号不随这个线程消失（hello288 L）。`sigaction` 把一个信号设成忽略（`SIG_IGN`，或默认动作为忽略的 `SIG_DFL`）时经 `signal_syscall.discardForProcess` 清掉 held 位和同一进程里每个线程上的这个信号（hello288 M）。`tkill`、`rt_tgsigqueueinfo` 仍只投给被点名的线程。
- **Linux personality 的调用号别名（hello289）**：`personality(1)` 的进程在进入原生分发表之前先经 `syscall_entry.dispatchLinuxAlias`，
  `rlimit.Policy.linuxAlias` 把 Linux 的号换成原生实现：160→setrlimit、302→prlimit64、231→`exit_group`（原生 501）、247→`waitid`（原生 500）。
  原生 personality 下 231 仍是 `move_pages`、247 仍是 `clock_nanosleep`。其余号仍按原生表解释。
- **waitid（hello285，系统调用 500）**：`proc/waitpid.zig` 的 `waitid`。`idtype` 是 `P_ALL`/`P_PID`/`P_PGID`
  （`proc/waitid_policy.zig` 把它换成 waitpid 的 pid 选择：-1、正 pid、负进程组），`options` 必须含
  `WEXITED`/`WSTOPPED`/`WCONTINUED` 之一，其余位除 `WNOHANG`/`WNOWAIT` 外都是 `EINVAL`。成功返回 0，
  子进程的身份和状态写进 128 字节的 SIGCHLD siginfo（`si_code` 为 `CLD_EXITED`/`CLD_KILLED`/`CLD_STOPPED`/
  `CLD_CONTINUED`，`si_status` 是退出码、致死信号、停止信号或 SIGCONT，`si_pid`/`si_uid` 是子进程的）。
  退出优先于同一子进程未报告的停止或继续；`WNOWAIT` 报告但不回收（`peekZombieLocked`，停止/继续报告也不消费），
  所以同一个僵尸或停止可以再报告一次。`WNOHANG` 没有可报告的变化时返回 0，六个字段写 0（`si_signo` 为 0）；
  写回 siginfo 时只覆盖六个字段（`si_signo`、`si_errno`、`si_code`、`si_pid`、`si_uid`、`si_status`，`siginfo_policy.waitidInfo`），
  其余字节保留调用者原来的内容，报告子进程和 `WNOHANG` 无变化时都一样（hello285 F）。
  infop 为空也允许，照样回收。没有匹配的子进程是 `ECHILD`。阻塞沿用 waitpid 的锁内协议，被信号打断返回 `-EINTR`
  并可按 `SA_RESTART` 重启。第五个参数 rusage 非空时先验证可写（144 字节，否则 `EFAULT`），只在确实报告了
  子进程时写回：utime/stime 是子进程整个线程组加上它已等待过的子孙的 CPU 时间（回收取 `Reaped.usage`，
  `WNOWAIT`、停止和继续取 `task.childUsageLocked`），其余字段为 0；`WNOHANG` 没有可报告的变化时不写。
- **kill(-pgid) 广播**：`lifecycle.kill(pid<0)` → `signal.sendSignalToPgrp`——stop/cont 类
  按默认处置立即生效，其余走 pending + 唤醒；返回发送计数（0 → ESRCH）。停止类里被忽略且未阻塞的信号在发送时丢弃，被忽略但阻塞的仍排队（hello262 F）。
- **孤儿组 SIGHUP（Linux `kill_orphaned_pgrp`）**：任何用户进程退出（线程退出不算）时
  `exitTask → jobctl.onExit`，由 `proc/orphan_pgrp_policy.zig` 决定哪些组新成为孤儿：
  一个组被同会话里、属于另一个组的父进程链接着；init 的子进程不算链接。检查退出进程
  自己的组和每个子进程所在的组。组里有停止成员时，全组成员先收 SIGHUP 再收 SIGCONT；
  没有停止成员、仍被链接、或停止的子进程留在退出会话长自己的组里（该组从未被会话内的
  链接连着），什么都不发。持有控制台的会话长退出时，另外向前台组发 SIGHUP 并释放控制台。
- **验收**：`user/hello58.c`——setsid/getpgid/getsid、后台读两类处置（handler→EINTR、
  默认→停→前台化→SIGCONT 恢复）、kill(-pgid) 全组终止、孤儿组 SIGHUP；`user/hello283.c`
  覆盖上面的六种情形（宿主机 Linux 实测同结果），SMP=1/4 全绿。

### 2.4b nanosleep 阻塞化（2026-08-15）✅

文件: `arch/x86_64/syscall_entry.zig`, `proc/sched.zig`, `proc/task.zig`

- **旧实现是 TSC 忙等**：syscall 入口全程 IF=0（SFMASK 清 IF），忙等期间 LAPIC 定时器
  无法触发，任何其他就绪任务都拿不到 CPU——fork 出的子进程在父/兄进程用 nanosleep
  轮询时会被饿死数秒（hello58 测试 4 实测）。
- **新实现**：`Task.sleep_deadline_ns` + 全局 `sched.sleep_bm` 位图；syscall 里发布
  deadline → 置位 → `blockTask` → `forceReschedule` 让出 CPU；每个 tick（每 CPU，
  位图门控近零开销）由 `sched.sleepTimerTick` 扫描到期者 `unblockTask` 唤醒，唤醒粒度
  一个 tick（10ms）。先发 deadline 再阻塞，丢失唤醒最多 +1 tick 重试，不会永久失醒。
- **信号协议与既有等待原语一致**：致命 pending → `exitTask`；可处理 pending → -EINTR
  并回填 `rem`。
- x86_64 SYSCALL entry 的 `IA32_SFMASK` 同时清除 TF、IF、DF（`0x700`），保持进入
  C/Zig 内核路径时的 SysV ABI direction-flag 契约。
- `sigreturn` 只接受非零、低于 user limit 的恢复 RIP/RSP；非法 signal frame 不会进入
  SYSRET redirect 路径。RFLAGS 按 Linux `FIX_EFLAGS` 清洗而非拒绝：只保留
  CF/PF/AF/ZF/SF/TF/DF/OF/RF/AC/ID，强制 IF 与保留位 1，丢弃 IOPL/NT/VM/VIF/VIP。
  （此前的“拒绝”实现会把故障类异常帧里合法的 RF=1 当作非法，使所有从 #PF 进入的
  SIGSEGV handler 返回时得到 EFAULT 并在 trampoline 后崩溃——hello58/hello99。）
- **槽位复用防护**：`reserveSlotLocked` 在槽位可见前清理旧的 sleep_bm 位 / deadline /
  stopped 标志，杜绝上一租户残留把半建任务误唤醒进就绪队列。
- aarch64/riscv64 的 nanosleep 仍为忙等实现（各自的 syscall 入口），列入后续轮次。
- **`clock_nanosleep` 共用同一阻塞实现（2026-10）**：此前它在 IF=0 的 syscall 里 `pause`
  忙等（非特权 DoS，不可被信号打断，`rem` 恒为 0）。现在 `nanosleep` 与
  `clock_nanosleep` 都经 `proc/sleep_policy.zig` 规划（`planRelative` / `planClock`：
  `nsec ∉ [0,1e9)`、负 `sec`、未知时钟、未知 flags → EINVAL；截止时间饱和加法，超大
  请求等价于“睡到被信号打断”，不再整数溢出 panic），再进入 `sleepUntil(deadline, rem)`。
  `TIMER_ABSTIME` 不回写 `rem`；返回路径调用 `checkSignalsOnSyscallReturn`。
- **alarm / ITIMER_REAL 唤醒阻塞者**：到期置 SIGALRM 后调用 `signal.kickIfBlocked`，
  `alarm()` 能以 -EINTR 打断睡眠与阻塞等待。
- **中断耗时计量（`/proc/irqtime`，x86_64）**：`interruptDispatch` 在分发前后按 CPU 累计 TSC 周期
  （`arch/x86_64/irq_time_policy.zig`，只计最外层；从用户态进入时把嵌套深度清零，因为有些从中断进入的内核路径
  不经原路返回——例如在异常处理里结束任务——否则深度会卡在非零、计数从此停止）。每行
  `cpu<N> total_us=… max_us=… count=… depth=… max_vec=… max_at_ms=…`（最长一次中断的向量号及其开始时刻，
  用于判断长中断来自哪个处理程序，例如向量 14 即缺页处理中的同步 I/O）。hello108 用它在测量窗口前后取差值，区分时间是被中断处理拿走的
  还是被宿主机拿走的。
- **`getrusage` 报真实 CPU 时间**：`RUSAGE_SELF/THREAD` 返回 `utime_us`（含当前这一段
  运行的 TSC 增量）与 `stime_us`；`RUSAGE_CHILDREN` 返回 0；其他 `who` → EINVAL，坏指针
  → EFAULT（纯函数 `proc/rusage_policy.zig`）。验收程序 `hello102`。
  `ru_nvcsw`/`ru_nivcsw`（偏移 128/136）：上下文切换时出让方仍是 `.running` 记为非自愿（被抢占），
  否则（阻塞、睡眠、退出）记为自愿（`rusage_policy.switchKind`）。此前两个字段恒为 0，`nivcsw` 还把所有切换都算成非自愿。

### 2.5 clone() 线程 (CLONE_VM/THREAD + FS_BASE TLS) ✅

文件: `task.zig`, `syscall_entry.zig`, `arch/x86_64/clone.zig`

- syscall #56，Phase-0 只接受已实现的 `CLONE_VM`、`CLONE_FILES`、`CLONE_THREAD`、
  `CLONE_SETTLS` 与 `CLONE_PARENT_SETTID`/`CLONE_CHILD_CLEARTID`；`CLONE_THREAD` 与 TID
  标志必须与 `CLONE_VM` 同时出现。`CLONE_SIGHAND`/`CLONE_FS` 的共享对象（信号处理表、
  fs_struct）尚未实现，接受它们会静默退化为拷贝语义，因此返回 `EINVAL`。
  （2026-10：7b811ff 的门禁曾把 `CLONE_THREAD` 一并拒绝，导致 moqi_libc pthread 与
  hello35/36/57/69/96/98/101 全部失败；现恢复为“仅随 `CLONE_VM` 接受”。）
- `CLONE_VM`：共享地址空间路径仅作为生命周期迁移中的受控能力，完整线程组语义仍待启用。
- 独立内核栈，FS_BASE TLS指针配置
- per-CPU runnable entry 保存 task incarnation；slot 复用后的 stale entry 会在 pop、RT pop、purge 和 steal 前被丢弃。
- 同一 task incarnation 在同一 runqueue 只允许一个 entry；重复 wake/enqueue 是幂等操作，不会消耗 queue capacity 或造成同一 task 的并发调度。
- `sched_setaffinity` 按 TID 获取 `TaskPin`，在 task lock 下更新 affinity 并快照迁移状态；释放 task lock 后再执行迁移入队和 CPU kick，pin 生命周期覆盖整个过程，避免 reaping 或 slot reuse 将迁移目标替换为另一 task。
- SysV SHM exit detach 在 `Mm.beginVmMutation` 失败时保持明确的未完成状态；当前不在无 `vm_lock` 或已释放的 PML4 上重试，完整 attachment/MM 生命周期设计仍是后续项。
- flat binary loader 当前最多接受 256 个 code pages；`sched_setaffinity` 修改 ready task 时也会迁移其 runnable entry，避免旧 CPU 队列因 affinity 过滤而丢失该任务。
- `pipe2` 只接受 `O_CLOEXEC`/`O_NONBLOCK`；`O_CLOEXEC` 设置 close-on-exec，`O_NONBLOCK` 设置在读写两端并由 pipe I/O 返回 `EAGAIN`，未知 flags 返回 `EINVAL`。
- `ioctl(FIONBIO)` 同样修改 descriptor 的 `status_flags` 中的 `O_NONBLOCK`，不会触碰 `fd_flags` 的 close-on-exec 状态；非零参数启用，零参数清除。
- pipe 写端同样遵守 `O_NONBLOCK`：满 pipe 且零进度时返回 `EAGAIN`，读端关闭时仍优先返回 `EPIPE`。阻塞模式下的行为见下一条。
- **管道写阻塞与原子性（hello229 F/G 组）**：`vfs.pipeWrite` 在管道满、还有字节没写时睡在每管道的写者队列 `pipe_write_waiters` 上（节点是任务自带的 `pipe_write_wait_node`，致命退出时由 `detachPipeWriteWaiter` 摘除），`pipeRead`、`pipeCommitRead`、`pipeTransfer` 腾出空间时、`pipeClose` 关闭最后一个读者时 `wakeAll` 写者。睡之前和醒来后检查信号：致命信号 `exitTask`，可处理的信号返回已写字节数，一个字节没写返回 `-EINTR`。读者全部关闭：已写部分非零返回字节数（并发 `SIGPIPE`），否则 `-EPIPE`。管道容量是 4095 字节，不超过它的写是原子的（整块放得下才写，阻塞则等管道读空，非阻塞放不下返回 `EAGAIN`），更大的写分段放入。
- **`SA_RESTART`（hello229）**：`proc/syscall_restart_policy.zig` 定义可重启的调用（`read/write/waitpid/wait4/readv/writev/accept/accept4/sendto/recvfrom/sendmsg/recvmsg`，含 Linux 编号），`syscallDispatch` 把调用号记进 `Task.syscall_nr`；`deliverSignalOnSyscallReturn` 在写信号帧之前，对 `-EINTR` 且处理函数带 `SA_RESTART` 的情形把保存的 rax 改回调用号、rip 退回 2 字节，`sigreturn` 后重新执行 `syscall`。这些调用的分发分支都在返回前调用 `checkSignalsOnSyscallReturn`。`pendingActionable` 对 `SIG_IGN` 的信号不再视为可打断。`connect`、`flock`、`futex`、睡眠、`pause`、`sigsuspend`、poll/epoll/select 不重启。只有 x86_64 实现。
- splice 的 pipe→file/socket reservation 路径在阻塞模式下等待 live pipe 数据；`SPLICE_F_NONBLOCK` 或 descriptor `O_NONBLOCK` 返回零进度 `EAGAIN`，写端关闭保持 EOF。pipe→pipe 的完整阻塞 transfer 仍是后续项。
- pipe→pipe splice 在零进度时返回 `EAGAIN`，避免 destination-full 或空源 pipe 被伪报为 EOF/成功；完整阻塞 source/destination wait queue 语义仍是后续项。
- `fsync`/`fdatasync` 仅接受 ext2/FAT32 regular-file descriptors；pipe、socket、eventfd 等非文件描述符返回 `EINVAL`。
- TCP `recv`/`recvfrom`/`recvmsg` 三态：有数据返回字节数；空接收环且对端仍可发送（syn_*/established/fin_wait_*）返回 `-EAGAIN`；对端已关闭（close_wait/closing/last_ack/time_wait/closed）返回 0（EOF）。尚无阻塞 recv（不论 O_NONBLOCK 均为 EAGAIN）。FIONREAD 对 TCP 报可读字节数、对 UDP 报队首数据报长度。（§6.53）
- ext2 最后一个链接被 unlink/rename 覆盖时，若 inode 仍被打开则只摘目录项并持久化 links_count=0，回收延迟到最后一次 close（tmpfs/FAT32 同语义）；fstat/statx 对 ext2 fd 报真实 inode 号、mode、nlink、uid/gid 与 `max(盘上, fd 缓存)` 尺寸。（§6.53）
- epoll 注册在 fd 关闭时迁移到仍存活的同资源副本（同表 dup，或 fork 后其它进程的表——经 FdTable 分配代数 + 钉住计数保证表不被复用），无副本才删除；unix_socket 报 IN/OUT/HUP/ERR 并在收发/连接/关闭时通知。TCP close/SHUT_WR 先冲刷发送环、环排空后才发 FIN；被对端 RST 的连接空读返回 `-ECONNRESET`；临时端口跳过已占用端口。MoqIPC call 的 reply 走独立 `reply_msg` 槽，不与入站 send 的 `pending_msg` 互相覆盖。moqi_libc malloc 检测同线程重入（malloc 返回 NULL、free 延迟），free 拒绝 double free 与非堆指针。（§6.54）
- 信号：sigaction 遵守 `sa_mask`/`SA_NODEFER`/`SA_RESETHAND`，信号帧保存 FXSAVE 并跳过 red zone；sigsuspend、epoll_pwait 的临时掩码在返回用户态后才恢复；rt_sigtimedwait 阻塞并支持超时；同步 SIGSEGV 被阻塞/忽略时强制默认动作；Ctrl+C 只发前台进程组。kill 遵守 POSIX 权限（同 uid/root）、`kill(pid,0)` 探测、`kill(0,sig)` 发本组、`kill(-1,sig)` 发除 init 与自身外的全部进程、`-ESRCH`/`-EPERM`。子进程退出投递 SIGCHLD，父进程 SIG_IGN SIGCHLD 时自动回收。waitpid 返回 Linux 状态编码；孤儿 getppid 返回 1；会话首进程退出只向前台组与含停止成员的孤儿组发 SIGHUP。SA_ONSTACK 处理程序在 sigaltstack 上运行（在栈上修改为 EPERM，CLONE_VM 线程与 exec 清空）；信号帧无法写入时进程以 SIGSEGV 终止而非丢弃信号。（§6.55）
- TCP recv 在环空时阻塞到数据/EOF/RST/信号/`SO_RCVTIMEO`；madvise(MADV_DONTNEED) 真实丢页（匿名页清零或换零页，文件页重读）；futex 在关中断锁外预取用户字，超时以节点是否被 timerTick 摘链为准（不依赖等待者 CPU 的本地时钟，epoll 同）；所有 block+forceReschedule 路径返回前修复 `.blocked` 状态；COW 写故障遇到已被换出的页重试而非 SIGSEGV；pmm 引用计数饱和后钉住不再递减（泄漏优先于 UAF）；只读 fd 的 MAP_SHARED 映射不能经 mprotect 获得 PROT_WRITE（EACCES）；SysV SHM 附着按地址空间登记、映射页持有自己的 PMM 引用，mprotect/munmap/mmap/brk 都拒绝触及附着区；semop 在任何数值变化时唤醒全部等待者并由各自重检；msgctl(IPC_RMID) 立即删除队列；exec 加载器按 `segment_copy_policy` 逐页拷贝（非页对齐段不越页）；clone 拒绝不可用的 new_stack/tls；syscall 的 fd 参数用饱和转换；exec 路径/argv/envp 逐页读至 NUL；文件映射整页越过 EOF 的访问投递 SIGBUS，越界判定前刷新文件实际大小（含 writeback 暂存），映射后文件增长的页可正常访问。msync 校验 flags（MS_SYNC|MS_ASYNC 互斥）；mincore 按页表报告驻留；brk 增长不越过 mmap 区域与 SHM 附着（含尚未缺页的）。mmap 容量预判与实际合并共用 `anonMergeSide`，区域表满时不可合并的映射返回 ENOMEM。ext2 维护 atime/mtime/ctime（创建、写、truncate），fstat 报告真实 st_blocks 与时间戳；FAT32 目录项维护创建/修改时间（DOS 2 秒精度，UTC）。（§6.55）
- SysV msgrcv 按入队单调 seq 选择（msgtyp=0 严格 FIFO）；shmctl(IPC_STAT) 按 mode 读权限裁决；timerfd/eventfd 阻塞读写以槽位 generation 识别 close+复用，返回 EBADF。（§6.53）
- `ftruncate`/`truncate` 接受全部有真实截断后端的可写 regular-file fd（ext2/FAT32/tmpfs），RLIMIT_FSIZE 的 SIGXFSZ/EFBIG 门先于后端分发；c76438a 曾误把 fsync 的类型门套到 ftruncate 上使 tmpfs 无法截断（§6.51 修复，hello42/hello66 锁定）。
- epoll pool 生命周期采用 slot generation + transient active borrow；persistent `ref_count` 仅表示 fork/clone fd ownership，pool metadata 到 instance payload 遵守 `pool_lock -> inst.spin`。
- epoll registration 额外捕获 fd slot incarnation；readiness probe 持有 transfer hold，并校验 live descriptor 的 generation、类型和 resource index，避免 close/reuse 后把旧注册绑定到新 fd。
- nested epoll 在 child ready transition 后于既有 `pool_lock` 临界区内向父实例传播 ready 状态并唤醒 waiter；传播使用 visited bitmap，避免循环 epoll 图递归获取锁或无限传播。
- nested propagation 只接受目标 child generation 仍匹配、父 registration 关注 `EPOLLIN` 的项，并遵守 ET 的 `last_reported` 抑制；EPOLL_CTL_DEL 按 ready-list slot 删除，避免 fd 数字复用误删节点。
- `EPOLL_CTL_ADD` 拒绝已经关闭或 generation 失效的 nested epoll target；collect 阶段也持有 child borrow 并再次校验 generation，stale child 不会被伪报为 `EPOLLERR`。
- `EPOLL_CTL_ADD/MOD` 在 registration 发布后重新探测 readiness，避免 probe 与加锁之间的通知 TOCTOU；child queue drain 后会清除父 nested ET 的 `last_reported`，允许下一次 ready transition 重新唤醒。
- `EPOLL_CTL_MOD` 推进 registration incarnation，避免旧 probe 修改新配置；LT 的 HUP/ERR 事件保持可重复 ready；self-epoll registration 返回 `ELOOP`。
- fd close/dup2 replacement 在 descriptor teardown 前按 `(FdTable, fd, generation)` 精确清理 epoll registration，避免 close/reuse 反复创建不可删除的 stale item 耗尽 registration pool。
- UDP 数据报入队（`udp_lock` 释放后）调用 `epollNotify(.udp_socket, port, EPOLLIN)`——到达即边，空队列时注册的 `epoll_wait` 不再依赖 ctl/collect 的反应式探测。（§6.51）
- ET 事件交付时清零该 item 的 `last_reported`：下一个同 mask notify 是新边并重新入队，"读尽 EAGAIN 后阻塞"的 ET 读者不会被连续同 mask 通知饿死。（§6.51）
- collectEvents drain 结束时 ready list 非空则唤醒 waiter（Linux `ep_done_scan` 语义）：封住 drain 与回插之间并发 `epoll_wait` 安装 waiter 的 lost-wakeup 窗口。（§6.51）
- `EPOLL_CTL_ADD` 沿 child epoll 链（`nestedChainReaches`，visited bitmap 有界）检测间接环，构成环返回 `ELOOP`——环上就绪互相传播会使 `epoll_wait` 永久 busy-loop。（§6.51）
- MoqIPC receive 被信号/`moqipc_notify` 踢醒时统一清理 `waiting_receiver` 注册并按唤醒来源分类返回：endpoint 失效才报 `invalid_endpoint`，存活 endpoint 的无投递唤醒报 EINTR（信号）/EAGAIN（notify）——注册残留曾让 endpoint 对所有 sender 永久报废。（§6.51）
- `alarm`/`itimer` deadline 字段与 per-CPU run-queue 的 `nr_running` 计数全部原子访问（tick 扫描器跨 CPU 与 syscall 上下文并发）。（§6.51）
- **moqi_libc 的 `gethostbyname_ipv4` / `ipv4_to_text`（hello196）**：`include/netdb.h` + `src/netdb.c`。`gethostbyname_ipv4(name, out4)` 是 `dns_resolve` 的薄包装，内核的 `-errno` 原样返回，成功才写输出；NULL 的名字或输出由包装器自己拒绝为 `-EINVAL`，不进内核。`ipv4_to_text(addr, buf, len)` 把地址格式化成 `a.b.c.d`，成功返回文本长度，缓冲区放不下文本加结尾的 NUL 时返回 `-ERANGE`（-34）且不写缓冲区。没有实现 `getaddrinfo`/`struct hostent`/`h_errno`（需要 `errno`、`AF_*`、`sockaddr` 等 libc 其余部分，目前不在 moqi_libc 里），也不做 IPv6。测试：宿主机上 `test_netdb_abi.c`（系统调用号、参数顺序、错误原样透传、NULL 拒绝、格式化的边界与缓冲区长度的精确边界，用桩替换系统调用），QEMU 上 `hello196` 经真实的 `dns_resolve` 验证 localhost、gateway、非法名字、空名字、NULL 参数。  另有 `ipv4_from_text(text, out)`：`inet_pton(AF_INET)` 语义（严格四段十进制、0..255、无前导零、无空白、无尾随文本；成功 1，否则 0，失败时不写输出），宿主机测试 27 个用例的期望值都取自 glibc 的 `inet_pton`。  再加 `ipv4_sockaddr(addr, port, out16)`（造 Linux 布局的 16 字节 `sockaddr_in`：family=2 小端 u16、端口网络序、4 字节地址、8 字节零）和 `resolve_ipv4_sockaddr(host, port, out16)`（点分十进制字面量直接解析、不进内核；其他名字走 `dns_resolve`；失败是内核的 `-errno`，NULL 参数是 `-EINVAL`，失败时不写输出）。hello196 用 `resolve_ipv4_sockaddr("0.0.0.0", 9196)` 造出的地址对一个 UDP socket 调真实的 `bind`，由内核验证布局。  `include/byteorder.h`（仅头文件）提供 `htons/ntohs/htonl/ntohl`；三个目标架构都是小端，所以实现是字节交换，遇到大端目标会 `#error` 拒绝编译而不是悄悄排错字节序；`ipv4_sockaddr` 用它写端口。宿主机测试 `test_byteorder.c` 的期望值取自 glibc。  `tcp_connect_host(host, port)`：`resolve_ipv4_sockaddr` + `socket(AF_INET, SOCK_STREAM)` + `connect`，返回已连接的描述符或 `-errno`（解析失败/`NULL` 主机是解析层的错误，socket 创建失败原样返回）；`connect` 尚未完成时按 netpoll 驱动的栈语义重试最多 20 次（`EISCONN` 视为之前的尝试已完成），最终失败会关闭 socket，不泄漏描述符。宿主机测试用脚本化的 socket 桩覆盖调用序列、重试界限、关闭行为；hello196 在目标上用自己开的回环监听器验证真实的 connect/accept。  `gethostbyname(name)`：glibc 兼容的 `struct hostent`（32 字节，偏移 0/8/16/20/24；`h_name` 是所问的名字，一个地址，无别名）和 `h_errno`（`HOST_NOT_FOUND`=1、`TRY_AGAIN`=2、`NO_RECOVERY`=3、`NO_DATA`=4）；结果在静态存储里，下一次调用覆盖（非线程安全，和 glibc 一样）。字面量不查询；名字不存在、格式错、过长（内核 `-ENOENT/-EINVAL/-ENAMETOOLONG`，即 -2/-22/-36）是 `HOST_NOT_FOUND`，超时和其它失败是 `TRY_AGAIN`，成功把 `h_errno` 清零；`NULL` 名字在 glibc 里会段错误（实测），这里干净地返回 `NULL`/`HOST_NOT_FOUND`。已知偏差：不做大小写规范化，`1.2.3` 这类 `inet_aton` 宽松写法被当作名字去解析。 **`getaddrinfo` / `freeaddrinfo` / `gai_strerror`（IPv4 only）**：`struct addrinfo` 按 glibc 实测布局（48 字节，flags 0、family 4、socktype 8、protocol 12、addrlen 16、`ai_addr` 24、canonname 32、next 40）；`getaddrinfo(node, service, hints, &res)` 返回 malloc 的链表，`freeaddrinfo` 逐项释放（含 `ai_addr`、`ai_canonname`）。支持 `AI_PASSIVE`/`AI_CANONNAME`/`AI_NUMERICHOST`/`AI_NUMERICSERV`；服务可以是数字（按 strtol 风格解析，65536 回绕成 0，负数或尾随垃圾是 `EAI_SERVICE`）或 11 个内置服务名（echo/ftp/ssh/telnet/smtp/domain/http/pop3/ntp/imap/https）；hints 没给 socktype 时依次返回 STREAM(6)、DGRAM(17)、RAW(0) 三项，只有首项带 `ai_canonname`；`node` 为 NULL 时默认回环，`AI_PASSIVE` 为 0.0.0.0；`hints == NULL` 时回显 flags=0x40。错误码：`EAI_BADFLAGS`(-1)、`EAI_NONAME`(-2)、`EAI_AGAIN`(-3)、`EAI_FAIL`(-4)、`EAI_FAMILY`(-6)、`EAI_SOCKTYPE`(-7)、`EAI_SERVICE`(-8)、`EAI_MEMORY`(-10)；解析层 -2/-22/-36 映射为 `EAI_NONAME`，其它失败为 `EAI_AGAIN`。已知偏差：`AI_V4MAPPED/ALL/ADDRCONFIG` 接受但忽略；`AF_INET6` 返回 `EAI_FAMILY`（glibc 对 v4 名字会返回 -9）；没有 IPv6、`getnameinfo`；服务名表只有 11 项；不做大小写规范化。 **`getnameinfo`（IPv4 only）**：`getnameinfo(sa, salen, host, hostlen, serv, servlen, flags)`，参数按 glibc 实测：`host`/`serv` 为 NULL 或长度 0 表示不返回该部分；主机名只有 `127.0.0.1` → `localhost`（没有反向 DNS），其余是点分十进制，`NI_NUMERICHOST` 强制数字，`NI_NAMEREQD` 在没有名字时返回 `EAI_NONAME`（但只在要求返回主机时检查）；服务名与 `getaddrinfo` 共用 11 项表，`NI_NUMERICSERV` 或表里没有就是十进制端口；`NI_NOFQDN`、`NI_DGRAM` 和 0x20/0x40/0x80（IDN 位）接受但无效果，其它位是 `EAI_BADFLAGS`，且先于地址检查；NULL、短于 16 字节或非 `AF_INET` 的地址是 `EAI_FAMILY`，更长的 sockaddr 可以；缓冲区放不下文本加 NUL 是 `EAI_OVERFLOW`(-12)，主机先于服务写入。新增 `NI_*`、`NI_MAXHOST`(1025)、`NI_MAXSERV`(32)、`EAI_OVERFLOW`，`gai_strerror` 补上 -11/-12。已知偏差：没有反向 DNS（glibc 对 `127.0.0.2` 之类会查 /etc/hosts 得到主机名），`sa` 的类型是 `const uint8_t *` 而不是 `struct sockaddr *`，没有 IPv6。
- **`dns_resolve`（系统调用 495）：DNS 解析器第一次对用户态可用（hello195）**：文档里 4.16 一节把 DNS 解析器标成"✅"，有静态主机表的 host 测试，但我核对后发现**内核里没有任何地方调用 `dns.resolve`**（只有 `shared/sk60.zig` 一个"链接是否通过"的检查引用它），用户态也没有任何接口能解析主机名：解析器是写好了、测过了、但接不到任何东西上。现在新增系统调用 `dns_resolve(name, out4)`（编号 495，`lib/moqi_libc/include/moqi_syscalls.h` 里有 `SYS_dns_resolve`）：先检查输出指针可写（`EFAULT`，在可能的网络等待之前），再用共用的路径读取函数取名字（`EFAULT`/`ENAMETOOLONG`），再按 `net/hostname_policy.zig` 校验主机名语法（RFC 1035/1123：由字母、数字、连字符、下划线组成的非空标签，用单个点分隔，标签不以连字符开头或结尾，标签最长 63、整个名字最长 253，允许一个结尾的点），空名字 `ENOENT`、过长 `ENAMETOOLONG`、语法不对 `EINVAL`；然后调 `dns.resolve`（静态表 → 点分十进制 → 缓存 → 网络查询），解析失败是 `ENOENT`；只有成功才写输出的 4 字节。**顺带发现并修了解析器里的一个真实缺陷**：`queryDns` 对 `udp.sendTo` 只试一次，而 `sendTo` 在 ARP 缓存里没有目标时只广播 ARP 请求就返回 `false`，所以**冷 ARP 缓存下的第一次查询必然失败**（日志里 `[DNS] Failed to send query`）。我用一个临时的探针程序在 QEMU 用户网络下解析 `example.com`，修之前返回 `ENOENT`，修之后拿到 `198.18.0.245`（QEMU slirp 内建 DNS 代理的应答）；修法是发送失败时泵一次网卡接收（让 ARP 应答被处理）再重试，直到发出或超过原有的 ~2 秒期限。**局限**：只支持 IPv4 的 A 记录（没有 AAAA、CNAME 跟随、也不读 `/etc/hosts` 或 `/etc/resolv.conf`）；解析会在内核里忙等最多约 2 秒（泵网卡 + `pause`），期间同一 CPU 上其他任务靠定时器抢占；`hello195` 只测内核自己能回答的名字（静态表、点分十进制）和错误码，真实网络查询只做过一次手工探针，没有放进自动测试，因为它依赖 QEMU 的上游 DNS 可达。 **后续修复（解析不到的名字会永久卡死）**：`dns.zig` 的两个等待循环（发送重试、等应答）原来按定时器节拍计时，但它们跑在系统调用里，而系统调用入口会屏蔽中断（`SFMASK` 清 IF），推进节拍的定时器中断不会在里面执行，节拍计数不动，所以“约 2 秒”超时永远不会到期，没有可达 DNS 服务器时解析一个不存在的名字会一直卡住。现在改用 TSC 真实时间（`dns_policy.QUERY_TIMEOUT_NS` = 2 s），加迭代次数上限作后备（`MAX_POLL_ITERS`，覆盖 TSC 未校准读数为 0 的情况），判断是纯函数 `dns_policy.waitExpired`（对计数器回绕也正确）；缓存 TTL 仍用节拍。DHCP 早就为同一个原因加过迭代上限，DNS 之前没有。
- **第四轮扫描：多线程并发的有状态调用链（hello193）**：在 hello192 的基础上，每个子进程用 `clone(CLONE_VM | CLONE_FILES | CLONE_THREAD | CLONE_SIGHAND)` 起 3 个线程，4 个线程共享同一份地址空间和描述符表，同时对同一批对象做随机调用；其中一个线程是"搅局者"：反复 `close`、`dup2` 覆盖、用新管道替换其他线程正在用的描述符，让别的线程在调用中途遇到被关掉或被换掉的描述符。每个线程的随机序列由（序列号，线程号）决定，所以仍可复现。**结果：提交里跑 400 个序列（6400 次调用），手工跑过 2500 个序列（40000 次调用）和 4000 个序列（64000 次调用，加了搅局线程之后），SMP=8，没有 panic、没有内核异常、没有挂死，只有 1 次阻塞并被杀；没有发现缺陷，也就没有内核修复。** **一个需要如实记下的意外**：第二次手工运行（4000 个序列）里，已有的 hello176 的 D 项（"有一个不绑核的自旋线程时，反复 20 ms 小睡不应被计入 CPU 时间"）失败了一次，被计入 247 ms（阈值 60 ms）。这和 hello170/176 那一节里记录的"观察到一次、未复现"的现象是同一个——当时就在 SMP=8、有自旋线程的场景里，被计入的是 210 ms。那次失败发生在 hello193 开始**之前**（日志里 hello176 的输出在 hello193 的输出之前约 3.2 万行），所以不是 hello193 造成的；之后我把整套冒烟在 SMP=8 下再跑了 4 次，hello176 的 D 项每次都是 4 ms，三个门禁里的 SMP=8 运行也都过了。也就是说，这个现象已经出现过 2 次（hello170 那次和这次），每次都是 SMP=8、有不绑核自旋线程的同一个场景；我没有逐次统计过 SMP=8 的总运行次数（hello170 那一节写的是 12 次里抓到 1 次，之后又有十几次通过），所以"2 次出现"的分母只是一个大致的数量级，不是精确的失败率。**我没有找到原因，也没有修**：在 hello176 里有一个已写明的猜测（`forceReschedule` 在本 CPU 没有可运行同伴时没有切走，任务以 `.blocked` 继续跑，`sched_in_tsc` 没有在阻塞时结算，后面读取线程 CPU 时间时就把睡眠算进去了），但我没有用任何手段验证过它，不应当写成结论。这是目前最值得继续追的问题，因为它现在有两次独立的出现。**局限**：搅局线程只做 `close`/`dup2`/建管道/让出 CPU，没有 `munmap`/`mprotect` 当前正在被别的线程访问的地址；每个线程的调用链仍然只有 4 个调用；3 个线程在 SMP=8 上不一定真的同时运行；参数仍是伪随机的。
- **第三轮扫描：对真实对象的有状态调用链（hello192）**：hello190、hello191 的每个调用都跑在刚 fork 出来的子进程里，子进程只有标准输入输出，所以没有一次调用碰到过管道、套接字、epoll、eventfd、timerfd、inotify、文件或映射。hello192 让每个子进程先建好一套真实对象——管道、AF_UNIX 流和数据报套接字对、已 `bind` 并 `listen` 的 TCP 套接字、UDP 套接字、eventfd、timerfd、inotify、登记了前几个对象的 epoll 集合、一个写过 4 KiB 的文件、一个文件共享映射和一个匿名映射——全部设为非阻塞，然后连续做 4 个随机系统调用，第一个参数 60% 是这些对象之一，其余参数 20% 是，所以调用会走到处理真实对象的代码，后面的调用会遇到前面留下的状态（被关掉的描述符、已取消的映射、被改过的 epoll 注册……）。序列完全由编号决定，日志里的 `fz 编号` 与 `c 调用号` 能复现出问题的那一次。**结果：提交里跑 1200 个序列（4800 次调用），手工跑过 5000 个序列（20000 次调用，覆盖 455 个不同的系统调用，每个 21–67 次），没有 panic、没有内核异常、没有用户态缺页、没有阻塞到需要杀掉以外的情况（1 次阻塞并被杀）；没有发现任何缺陷，也就没有修复。** 这是一个如实的"没有发现"：它说明在这种覆盖下，前两轮修掉的几类缺陷（NULL 用户指针、整数溢出、对 128 TiB 范围的逐页遍历）没有同类的遗漏，但不能证明没有问题。**局限**：序列只有 4 个调用，深层状态机（比如 TCP 连接建立、半关闭、重传）几乎不会被随机调用链推进到；只有一个线程，没有并发；参数仍是伪随机的，不是覆盖率引导；59 个会故意结束运行的调用没测；子进程是 `setsid` 后的单进程，没有 fork 后的 COW、`clone` 线程共享地址空间或描述符表的情形——这些是下一步最可能有收获的方向。
- **第二轮扫描：参数能通过校验的恶意调用（hello191）**：hello190 给的指针全是坏的，大多数调用在参数校验这一步就返回 `EFAULT`，根本没走到真正的实现。hello191 用同一份系统调用清单，但参数换成"能通过校验"的：指向一块已映射、预先填好内容的缓冲区的指针、小整数（0、1、2、…、65536）、可能合法的文件描述符（0–7）、以及少量边界值，用 xorshift 伪随机混合，种子由调用号和轮次决定，所以日志里的 `fz 调用号/轮次` 就能完整复现出问题的那一次；缓冲区前半是可打印字符（不含换行），写到控制台也无害。每个调用在 fork 出的子进程里运行，子进程先 `setsid`，以免读控制台（fd 0）时触发的 `SIGTTIN` 把父进程一起停住。提交里每个调用号跑 8 轮（约 3600 次）；另外手工跑过 40 轮、共 18200 次，没有 panic、没有内核异常、没有挂死，阻塞并被杀的 6 个都是预期的（`select`/`ppoll`/`pselect6` 等）。**发现并修复 1 个 panic 和 1 个类别的隐患**：①**`setitimer` 的整数溢出 panic**：`new_value` 里的秒数和微秒数是无符号乘法加无符号加法，`it_value.sec` 很大时 `sec * 1_000_000_000` 溢出，内核停机；更糟的是 `it_interval` 很大时，`setitimer` 本身可能没事，但调度器之后在定时器到期时用 `now + interval` 重新装填，会在**时钟中断里**溢出，把整个内核打停机。`alarm(0xffffffff)` 也走同样的无检查加法。对照真实 Linux：`it_value`/`it_interval` 必须满足 `tv_sec >= 0 && 0 <= tv_usec < 1000000`，否则 `EINVAL`；极大的秒数合法（等价于"永不到期"）；检查顺序是先读新值（`EFAULT`）、再验证新值（`EINVAL`）、再检查定时器编号（`EINVAL`）、最后写旧值（`EFAULT`）；`new_value == NULL` 被当作全 0（解除定时器）；`getitimer` 的 NULL/坏指针是 `EFAULT`，编号越界是 `EINVAL`。新增 `proc/itimer_policy.zig`（`timevalValid`、饱和的 `timevalNs`/`deadlineNs`/`alarmNs`、`whichValid`），`syscallSetitimer`/`syscallGetitimer`/`alarm` 使用它，`sched.zig` 的两处重新装填改成饱和加法 `+|`。②作为隐患扫了一遍其余把用户值乘进纳秒的位置：`timerfd` 已有保护，`userdrv` 的等待已有上限，没有别的。**一个看起来像 bug、其实不是的发现**：第一次跑 40 轮时，`recvfrom(fd 0, …)` 之后内核两个 CPU 都停在 `hlt`，看起来像丢失唤醒。用 GDB 看任务表：任务表里三个用户任务（tid 5、3727、3984，父子相连）都是 `stopped=1`，其中 tid 3727 的待处理信号是 `0x10000`（第 17 位，即 `SIGTTIN`）。原因是子进程读 fd 0 触发了作业控制：后台进程组读控制台收到 `SIGTTIN` 被停止，`sendSignalToPgrp` 把整个进程组（包括父进程）都停了，这和 Linux 对后台进程组读终端的行为一致，不是内核缺陷；是 hello191 自己的问题，已让子进程先 `setsid`。**局限**：伪随机而非覆盖率引导；只能发现"不设防"类缺陷；59 个会故意结束运行的调用没有测。
- **对每个系统调用做"恶意参数"扫描（hello190）**：hello188、hello189 各发现了一个用户态一行调用就能让内核 panic 的缺陷，说明逐个系统调用对照 Linux 的办法会漏掉"根本没人想到去测"的路径。hello190 换了思路：把全部 512 个系统调用号（去掉会故意结束运行的 59 个：`exit`、`kill`、`mount`、`reboot`、`fork`/`clone`/`execve`、`swapon`、`clock_settime` 等）逐个放进子进程里，每个用 7 组恶意参数（全 0、全 1、内核地址、小的坏指针、"一个合法 fd + 内核指针"、"一个合法 fd + 超大长度"、用户空间顶端）调用一遍，共 3185 次；内核必须给出结果或 errno，不能 panic、不能死机，阻塞的调用必须能被 `kill` 杀掉（`select`/`ppoll`/`pselect6` 在没有超时、没有可等的事件时本来就阻塞，Linux 也一样，共 4 个）。每次调用前子进程先打印"系统调用号/参数组"，所以一旦 panic，日志里最后一行就指出元凶。**发现并修复 3 个缺陷**：①**`copyFromUser`/`copyToUser` 对 NULL 用户指针 panic**：约 300 处调用点写成 `copyFromUser(buf, @ptrFromInt(user_value), n)`，用户值为 0 时 `@ptrFromInt(0)` 在调用点就触发 Zig 的 `cast causes pointer to be null` 安全 panic，根本没机会进入函数里的 `validateUserRange`（它本来会拒绝 0）；首发是 `sendto(0, 0, 0, …)`。hello189 的 `rt_sigqueueinfo(NULL)` 是同一类，当时只补了那一处；现在把两个辅助函数的指针形参改成 `[*]allowzero`，NULL 能走到范围检查并被拒绝，一处修改覆盖所有调用点。②**`munmap`/`mprotect`/`madvise`/`msync` 对整个用户空间（128 TiB）的范围要在一次系统调用里逐页（343 亿页）遍历**：`munmap(0, 0x7fffffff0000)` 要 12.7 秒，带 `mprotect` 的类似调用实际上不会返回，期间不可抢占地占着 VM 锁。原因是逐页循环对没有页表的区域也一页页调 `isPageOccupied`/`unmapPage`。现在新增 `mmap.skipHole`：缺页目录指针表则跳到下一个 1 GiB 边界，缺页目录则跳到下一个 2 MiB 边界，需要同时统计按需缺页映射时（`mprotect` 的洞计数）不越过已记录区域的起点；`unmapRange`、`firstMappedPage`、`fixedReplaceable`、`mprotect` 的四个循环，以及 `huge_user_impl` 的 `prescanHuge`/`demoteRange`/`protectHugeOverlaps*`（以 2 MiB 步长遍历，6700 万步）都使用它。结果：四个调用对 128 TiB 的范围分别用 207/75/75/75 毫秒。③hello188 里已经修的 `mmap(len=-4096)` 溢出 panic 也是这一类（扫描前就发现）。hello190 同时把"128 TiB 范围调用必须在 2 秒内返回"作为断言，防止回退。**局限**：参数模式是固定的 7 组而不是随机/覆盖率引导，所以只能发现"对这类恶意输入不设防"的缺陷；不会发现逻辑错误；会故意结束运行的 59 个调用没有测；阻塞型调用只检查"能被杀"，不检查醒来后的语义。
- **信号系统调用的错误码与检查顺序，对照真实 Linux（hello189）**：先在宿主机取 76 项真实 Linux 返回值（`rt_sigaction`、`rt_sigprocmask`、`kill`、`tkill`、`rt_sigpending`、`rt_sigsuspend`、`rt_sigtimedwait`、`rt_sigqueueinfo`、`sigaltstack` 的各种错误输入与组合），再写 hello189 逐项对照；其中 70 项本来就一致，**5 处检查顺序偏差和 1 个用户可触发的内核 panic** 已修（5 项 FAIL，外加一项把内核打停机）。panic：`rt_sigqueueinfo` 的 siginfo 指针为 NULL 时，`@ptrFromInt(0)` 触发 `cast causes pointer to be null`，内核停机；现在先检查指针（NULL 或不可读为 `EFAULT`），并且和 Linux 一样先读 siginfo、后查信号号（`EFAULT` 压过 `EINVAL`）。顺序偏差：①`rt_sigprocmask`：Linux 先读新集合（`EFAULT`），再拒绝未知的 `how`（`EINVAL`），最后才写出旧掩码，所以 `EINVAL` 的调用不会碰调用者的旧掩码缓冲区；以前先写旧掩码，缓冲区不可写时报 `EFAULT`。②`kill`：先找目标（不存在 `ESRCH`），之后才查信号号（超过 64 为 `EINVAL`）；以前信号号先查，对不存在的进程报 `EINVAL`；`kill(-1, sig)` 仍先查信号号。③`tkill`：tid 不是正数 `EINVAL` → 线程不存在 `ESRCH` → 信号号 `EINVAL`，以前信号号排在最前。④`rt_sigtimedwait`：集合指针为 NULL 或不可读是 `EFAULT`（以前 `EINVAL`）；`info` 指针只在真正要取走一个信号时才检查（检查发生在消费之前，所以缓冲区坏时信号仍留在待处理集合里），以前一进来就检查，没有信号时也报 `EFAULT`。其余 70 项（`sigaction` 的 `SIGKILL`/`SIGSTOP`、信号 0/65、`EFAULT`，`kill` 的组与自己，`sigaltstack` 的各种参数等）无需改动。**未对照**：`sigsetsize` 参数——这个内核仍接受旧的 4 字节形式（旧程序在用），Linux 一律要求 8，所以 `sigsetsize` 的错误没有进探测；~~`rt_tgsigqueueinfo` 的 tid 参数被忽略~~（已实现，见 hello288）；`pidfd_send_signal` 的 `info`/`flags`。
- **内存管理系统调用的错误码，对照真实 Linux（hello188）**：先在宿主机取 102 项真实 Linux 返回值（`mmap` 的长度/标志/保护位/偏移/各类描述符/`MAP_FIXED`/`MAP_FIXED_NOREPLACE`，`munmap`、`mprotect`、`madvise`、`msync`、`mincore`、`mlock` 系列、`mremap`），再写 hello188 逐项对照；旧内核 **36 项不一致，另有一个内核 panic**。修复：①**`mmap` 长度接近 2^64（如 `-4096`）会让内核 panic**（`integer overflow`：页数取整溢出）；现在长度超过用户空间上限直接 `ENOMEM`。②`mmap`：未知保护位被忽略（Linux 不报错，以前 `EINVAL`）；偏移必须按页对齐，匿名映射也一样（以前只查文件映射）；`MAP_FIXED_NOREPLACE`（与已有映射重叠为 `EEXIST`）、`MAP_STACK`/`MAP_POPULATE`/`MAP_NORESERVE`/`MAP_GROWSDOWN` 等提示类标志现在被接受（`MAP_GROWSDOWN` 只接受不向下生长）；`MAP_LOCKED` 仍 `EINVAL`；`MAP_FIXED` 的范围越出用户空间是 `ENOMEM`，之后才查对齐（`EINVAL`）；`MAP_FIXED` 压在已有映射上现在像 Linux 一样先拆掉旧映射（以前只有"整块私有匿名读写区域"才行，其余 `ENOMEM`），先做完所有可能失败的检查再动手；文件映射：写入描述符是 `EACCES`（以前 `EBADF`），已关闭的描述符是 `EBADF`，"负"偏移是 `EOVERFLOW`，目录是 `EACCES`（实测，以前 `ENODEV`，包括 ext4/NTFS 卷上的目录）。③`munmap`：长度向上取整（以前非页倍数的长度是 `EINVAL`，会拒绝合法调用）。④`mprotect`：越出用户空间或长度取整溢出是 `ENOMEM`（以前 `EINVAL`）。⑤`madvise`：检查顺序是建议值（`EINVAL`）→ 范围（对齐/溢出 `EINVAL`、零长度成功、越出用户空间 `ENOMEM`）→ 映射（有洞 `ENOMEM`）；`MADV_FREE` 作为提示被接受；`MADV_DONTFORK`/`MADV_DOFORK` 仍 `EINVAL`（没有实现，不假装生效）。⑥`msync`、`mincore`：范围里有洞是 `ENOMEM`（以前成功）；`mincore` 的向量检查在范围检查之后。⑦`mlock`/`munlock`/`mlockall`/`munlockall`：以前一律 `ENOSYS`；现在参数检查与 Linux 一致（零长度成功、有洞 `ENOMEM`、`mlockall` 的标志必须有 `MCL_CURRENT` 或 `MCL_FUTURE`），有效的 `mlock`/`mlockall` **仍然是 `ENOSYS`**（内核无法固定用户页，假装成功会让调用者误以为敏感数据不会进交换区），`munlock`/`munlockall` 成功（因为什么都没锁）。⑧`mremap`：大小取整溢出是 `EINVAL`（以前 `ENOMEM`）。其余规则在新文件 `mm/range_policy.zig`（host 可测）。已有的 hello71/74/114/131 里四处断言的是旧的非 Linux 行为（`munlock` 的 `ENOSYS`、`mprotect` 内核地址的 `EINVAL`、目录映射的 `ENODEV`、未知保护位的 `EINVAL`），按实测改成 Linux 的值。
- **fcntl 与 `open` 标志，对照真实 Linux（hello187）**：先在宿主机取 77 项真实 Linux 返回值（`F_GETFD/SETFD/GETFL/SETFL/DUPFD/DUPFD_CLOEXEC` 在各种描述符类型上，坏 fd、坏命令、坏指针、`F_GETLEASE`、`F_GETPIPE_SZ/SETPIPE_SZ`），再写 hello187 逐项对照；旧内核 21 项不一致。修复（纯规则在 `fs/fcntl_policy.zig`）：①**`open(O_CLOEXEC)` 根本没有生效**：`openAt` 不看这个位，用 `O_CLOEXEC` 打开的文件在 `execve` 后依然开着（会泄漏给被执行的程序）；现在 `openAt` 在打开成功后设置 `FD_CLOEXEC`。②`F_SETFD` 把参数整个存起来（`F_SETFD, 0xff` 之后 `F_GETFD` 返回 255），Linux 只保留 `FD_CLOEXEC` 一位。③`F_GETFL` 只保留访问模式、`O_APPEND`、`O_NONBLOCK`：`open` 时的 `O_SYNC`/`O_DSYNC`/`O_DIRECT`/`O_DIRECTORY`/`O_NOFOLLOW`/`O_NOATIME` 都丢了（`OPEN_STATUS_MASK`），`F_SETFL` 也只能改 `O_APPEND`/`O_NONBLOCK`，Linux 还允许改 `O_DIRECT` 和 `O_NOATIME`（`SETFL_MASK`）；访问模式与 `O_CREAT`/`O_TRUNC`/`O_EXCL` 之类仍然改不动。④套接字、`epoll`、`eventfd`、`timerfd` 的 `F_GETFL` 在 Linux 上是 `O_RDWR`（值 2），这里没有存访问模式所以是 0；`F_GETFL` 现在对这些类型补上 `O_RDWR`（管道的读端是 0、写端是 1，本来就对）。⑤`F_GETLEASE` 以前是 `EINVAL`，现在返回 `F_UNLCK`（2，没有租约）。⑥`F_GETPIPE_SZ`/`F_SETPIPE_SZ` 以前是 `EINVAL`；管道缓冲区固定一页，`F_GETPIPE_SZ` 返回 4096，`F_SETPIPE_SZ` 请求不超过一页时取整到 4096，更大返回 `ENOMEM`（Linux 默认 64 KiB 且可增长到 1 MiB，这里不能；非管道描述符是 `EBADF`，与 Linux 相同）。
- **epoll 的错误码与 `struct epoll_event` 布局，对照真实 Linux（hello186）**：先在宿主机用 `gcc` 取 67 项真实 Linux 返回值（`epoll_ctl` 的 ADD/MOD/DEL 在坏 epfd、坏目标、不可轮询目标、自己、重复、坏事件指针、未知操作、`EPOLLEXCLUSIVE` 各种组合下的结果，`epoll_wait` 在坏 epfd、非 epoll 的 epfd、`maxevents` 边界、坏缓冲区下的结果），再写 hello186 逐项对照；旧内核上约 33 项不一致。修复：①**`struct epoll_event` 布局**：内核把它当成 16 字节（`events` 后面补 4 字节再放 8 字节 `data`），Linux x86_64 是 packed 的 12 字节、`data` 在偏移 4；改为 `align(1)` 并用 `comptime` 断言大小与偏移（此前内核与 glibc/musl 用户程序对 `epoll_wait` 返回的多个事件会错位）。②**检查顺序按 Linux**（`epoll_policy.ctlPrecheck`）：先读事件（ADD/MOD 与未知操作要读，只有 DEL 不读；读不到是 `EFAULT`），再 `EBADF`（epfd 或目标没打开），再 `EPERM`（目标没有 poll 操作：普通文件、目录、`/proc` 文件、只读卷文件），再 `EINVAL`（epfd 不是 epoll、目标是 epfd 自己或它的 `dup`、未知操作、`EPOLLEXCLUSIVE` 滥用）。③`EPOLLEXCLUSIVE`：不能用于 MOD，不能用于目标是 epoll 的 ADD，不能与 `IN|OUT|ERR|HUP|WAKEUP|ET` 之外的位组合（`EPOLLONESHOT`、`EPOLLRDHUP`、`EPOLLPRI` 都是 `EINVAL`）；一个用 `EPOLLEXCLUSIVE` 注册的项之后 MOD 也是 `EINVAL`。④"把 epoll 加进自己"以前返回 `ELOOP`，Linux 是 `EINVAL`（`ELOOP` 只用于更长的环）；拿一个 epoll 的 `dup` 加进它自己同理。⑤`epoll_wait`（`epollWaitFd`，`epoll_pwait`/`epoll_pwait2` 共用）：非 epoll 的 epfd 以前是 `EBADF`，现在是 `EINVAL`；检查顺序是 epfd 是否打开（`EBADF`）→ `maxevents`（`<= 0` 或 `> INT_MAX/12 = 178956970` 为 `EINVAL`）→ 缓冲区是否落在用户空间（只做范围检查，`NULL` 或小的坏地址在没有事件时不报错；越界为 `EFAULT`）→ epfd 是否 epoll；`maxevents` 现在可以大于内核的 128 个槽位（以前 129 以上直接 `EINVAL`，Linux 接受），内核按 128 截断后返回。
- **文件描述符与路径的错误码，对照真实 Linux（hello185）**：沿用 hello184 的方法，先在宿主机上用 `gcc` 写对照程序取真实 Linux 的返回值（约 55 种“用错了”的调用：`open` 的 `EEXIST`/`ENOENT`/`EISDIR`/`ENOTDIR`，按打开模式的读写权限，目录上的 `read`/`write`，`lseek`、`close`、`dup`、`dup2`、`fcntl`、管道、`ftruncate`、`fstat`、`mkdir`/`rmdir`/`unlink`/`rename`/`chdir`），再写 hello185 逐项对照。其中 51 项本来就与 Linux 一致，4 处偏差已修：①`read` 在越界或未打开的描述符上返回 `-1`（用户态看到 `EPERM`），应为 `EBADF`（`vfs.read`/`readInner` 的三处 `-1`）；②对已经关闭的描述符再 `close` 返回 `-1`，应为 `EBADF`（正在关闭中的那种情况仍是静默成功）；③`lseek` 在管道上返回 0（把位置当成可移动），Linux 返回 `ESPIPE`；现在管道、套接字、`eventfd`/`timerfd`/`epoll`/`inotify`/`pidfd` 和 `devfs_ctrl` 都是 `ESPIPE`（规则在 `fs/fd_seek_policy.zig`，按 `FdType` 标签名判断，所以可以在不依赖架构代码的 host 测试里验证）；④`open("")` 打开了当前目录（空路径经 `at_path.resolve` 被当作 cwd），Linux 是 `ENOENT`，现在在解析之前就拒绝空路径。
- **TCP 套接字状态错误码，及 `sockaddr_in` 地址族的字节序（hello184）**：用真实 Linux（`gcc` 写的对照程序）当标准，对 TCP 在“不该调用的状态”下调用的错误码做了一次一致性检查，发现 8 处偏差并修正（现在 `tcp_recv_policy` 里有对应的纯规则）。`accept` 在不是监听状态的套接字上：`EINVAL`（此前 `-1`）；`listen` 在已连接的套接字上：`EINVAL`（此前已被拒绝，但返回 `-1`）；`shutdown`：监听者可以，从未连接过的套接字对任何 `how` 都是 `ENOTCONN`（此前成功），连接过或正在建立的正常；`getpeername`：没有对端（新套接字、监听者）是 `ENOTCONN`（此前成功并返回全零地址）；`send` 在监听套接字、从未连接的套接字上：`EPIPE`（Linux 这样，`recv` 才是 `ENOTCONN`；此前 send 在从未连接的套接字上给 `ENOTCONN`，与 Linux 不符，hello154 的旧断言本来就同时接受两者）；`bind` 的地址族不是 `AF_INET`：`EAFNOSUPPORT`（此前直接忽略地址族）。**更重要的是发现了一处地址族字节序错误**：`sockaddr_in.sin_family` 是 16 位**小端**整数（Linux 程序存的是字节 `02 00`），而内核 TCP/UDP 的 `connect` 却按**大端**读它，只接受字节 `00 02`；所以任何真正的 Linux 程序（字节 `02 00`）对 TCP `connect` 会得到 `EAFNOSUPPORT`。内核自己的探测程序从一开始就按错误的字节序写地址（一直是 `a[1] = 2`），两边一起错所以一直通过，而写 `getsockname` 回去的地址（`sockaddr_util` 里已经是小端）与 `connect` 读取的字节序不一致。现在 TCP `connect`/`bind`、UDP `connect` 都按小端读取（共 3 处），23 个旧探测程序、hello22/26/27/85 里的地址也改成真实的 `02 00`。同一 socket 上第二次 `listen` 复用第一次的监听槽：此前每次 `listen` 都新占一个槽，`close` 只释放找到的第一个，剩下的槽继续应答这个端口的 SYN，后来占用同一 TCB 槽位的监听者 `accept` 还会先找到这个空槽而永远拿不到连接（hello184 F，也是 hello267 第三个监听者偶发一个连接都接不到的原因）。
- **TCP `bind` 的错误码与 `SO_REUSEADDR`（hello183）**：TCP 的 `bind` 此前无论什么原因失败都返回 `-1`（被用户态看成 `EPERM`），端口被占用、没有权限、套接字已绑定全是同一个值，而 UDP 的 `bind` 早就返回 `EADDRINUSE`。现在 `tcp_port_policy` 定义规则：端口已被另一个套接字占用返回 `EADDRINUSE`（-98）；对已经绑定过地址（`bound_explicitly`）或不在 CLOSED 状态的套接字再 `bind` 返回 `EINVAL`（-22）；绑定 1024 以下端口而没有 `CAP_NET_BIND_SERVICE` 返回 `EACCES`（-13，此前是 `-1`），IPv4 与 IPv6 两条路径一致。`SO_REUSEADDR` 的共享规则收紧并集中到 `reuseMayShare`：只有新套接字设置了 `SO_REUSEADDR` **并且**占用者只是 TIME_WAIT 残留时才可以共享端口（所以监听中的端口即使双方都设了 `SO_REUSEADDR` 也不能再绑）；端口 0（让内核选）从不冲突；扫描时跳过套接字自己的槽位，槽位里上一个占用者留下的端口号不再造成自己和自己冲突。
- **`poll`/`select` 被事件唤醒，而不是等睡眠片结束（hello182）**：`poll`/`select`/`ppoll`/`pselect6` 此前每次扫描一遍描述符就睡一个 5 ms 的片再扫，所以另一个进程让描述符就绪后，`poll` 要等到当前睡眠片结束才发现。实测在 AF_UNIX 套接字对上做一问一答，`epoll` 一个来回约 0.8 ms，`poll` 约 26 ms（SMP=2）/ 9 ms（SMP=8），相差一个数量级；一个依赖 `poll` 的事件循环的延迟因此比 `epoll` 差得多。现在 `fs/poll_wake.zig` 与 `poll_wake_policy.zig` 实现唤醒协议：每次就绪变化本来就会调用 `epollNotify`，它现在先调用 `poll_wake.notify()`——全局代数加一，并唤醒登记在等待位图里的所有 `poll`/`select` 等待者（没有等待者时只是一次原子加和一次读）。等待者**先**记下代数、**再**扫描描述符；睡眠前把自己登记进位图并置 `.blocked`，随后重新读代数，若扫描之后又有通知就不睡了（`mustSkipSleep`），所以扫描和睡眠之间发生的通知不会丢。5 ms 的睡眠片仍然保留为上限：不经过 `epollNotify` 的就绪来源仍然能被发现，只是延迟与以前一样。结果：同样的一问一答，`poll` 一个来回约 0.75–0.9 ms，与 `epoll` 相当；另一个进程在 60 ms 后写入时，3 秒超时的 `poll`/`select` 在约 60–100 ms 返回（不再依赖超时），无事件时仍按请求的 120 ms 超时返回 0。
- **AF_UNIX 数据报的 `sendto`/`sendmsg` 带目的地址，及 `EMSGSIZE`（hello181）**：此前 AF_UNIX 的 `sendto` 与 `sendmsg` 会**忽略**目的地址，只能发给 `connect` 过的对端，所以 `syslog` 风格的“未连接的数据报套接字向路径发送”（以及 `sendto` 到另一个路径）根本不能用。现在 `unixSendRightsTo` 是唯一实现（`unixSendRights` 只是不带地址的包装）：数据报套接字带地址时，目标是**此刻绑定在该路径上的套接字**（`findBoundLocked`），没人绑定是 `ECONNREFUSED`、绑定者的类型不同是 `EPROTOTYPE`；已 `connect` 的数据报套接字带了地址也发给该地址而不是已连接的对端；`sendto` 不会把发送方变成已连接。流式套接字带地址：已连接是 `EISCONN`，未连接是 `EOPNOTSUPP`；seqpacket 已连接时忽略地址（Linux 同）。`sendto`/`sendmsg` 的地址经同一个解析函数 `unixDestPath`：先查地址族（不是 AF_UNIX 为 `EAFNOSUPPORT`）、长度、路径非空。满的接收环对非阻塞发送者是 `EAGAIN`；阻塞发送者在 `unixSendToBlocking` 里以短睡眠重试（地址发送不使用发送方自己的对端等待链），遵守 `SO_SNDTIMEO`，被信号打断则返回 `EINTR`。另一个**既有缺陷**：一个比整个接收环（8192）还大的数据报，非阻塞发送返回 `EAGAIN`（让人以为稍后能成功），阻塞发送则在 `unixSendBlocking` 里**永远等下去**；现在两条路径都先判断 `dgramFits`，装不下直接 `EMSGSIZE`。第三个既有缺陷：`write()` 把 AF_UNIX 数据报/seqpacket 套接字上的大写入按 4096 字节分块，一次 `write` 变成多个数据报、记录边界丢失；现在消息套接字（`!unixIsStream`）的 `write` 作为**一条**消息整块发送（上限 8192，更大 `EMSGSIZE`）。
- **AF_UNIX 的 `getsockname` / `getpeername`（hello180）**：此前这两个调用对 AF_UNIX 套接字一律 `ENOTSOCK`，绑定了路径的服务拿不到自己的名字，连接方也问不到对端是谁（`systemd` 风格的服务、很多 IPC 库、`ss`/`lsof` 类工具都会问）。现在：`unixSockName` 返回套接字自己的地址——绑定过的是 `sockaddr_un{AF_UNIX, 路径}`，长度 = 2 + 路径 + 结尾 NUL（短缓冲区截断，但报告完整长度，与 `getsockname` 一贯的约定相同），没有绑定的是“未命名地址”，只有 2 字节的地址族（`socketpair` 的两端、没绑定的客户端都是这样）；**accept 出来的套接字**回答监听者的路径，但并不拥有这个地址，所以对它再 `bind` 仍是 `EINVAL`（`name_only` 标志，不参与“路径已被占用”的检查，也不会被后面的 `connect` 当作目标）。`unixPeerName` 返回对端的地址，没有存活对端时 `ENOTCONN`：流式套接字沿用互指的反向引用检查（槽位被复用时不会把无关套接字当对端）；已 `connect` 但监听者还没 `accept` 的客户端，对端地址就是它连接的路径（`connect` 现在把解析出的路径存进 `peer_path`）；数据报套接字的 `connect` 是单向的，只有目标槽位仍然绑定在当初解析的那个路径上才应答，否则（目标已关闭、槽位被别的套接字占用）`ENOTCONN`。地址编码在 `socket_address_policy.unixNameEncode`。
- **`SO_PRIORITY`、`SO_MARK`、`SO_OOBINLINE`、`SO_BINDTODEVICE`、`SO_SNDLOWAT`（hello179）**：这些 `SOL_SOCKET` 选项此前对所有套接字都是 `ENOPROTOOPT`，`systemd`、`iproute2` 风格的工具、`dhclient`/`ping` 一类程序启动时会设置它们。`sockopt_policy` 新增：`SO_OOBINLINE` 是普通布尔标志（第 6 位）；`SO_PRIORITY` 存 `i32`，0..6 任何人可设，更大或为负要 `CAP_NET_ADMIN`（`EPERM`）；`SO_MARK` 存 `u32`，设置要 `CAP_NET_ADMIN`；`SO_SNDLOWAT` 读回 1、不可设（`ENOPROTOOPT`，Linux 同）；`SO_BINDTODEVICE` 接受接口名（`lo` 一直有，`eth0` 仅在网卡存在时有，名字在第一个 NUL 处截断），空名字解除绑定，不存在的名字 `ENODEV` 且保持旧绑定，读回带结尾 NUL 的名字（未绑定时长度 0），AF_UNIX 套接字没有设备可绑（`ENOPROTOOPT`）。TCP、UDP、AF_UNIX 三种套接字都走同一入口 `applySetPriv`，TCP 经 `storedOnly` 与 REUSEPORT/BROADCAST/DEBUG 共用往返路径，值保存在 `SocketOptions.priority/mark/bound_if`。`capability_profile` 给 hello179 一个“uid 0 + `cap_net_admin` + `cap_setuid`”的启动档案，使子进程 `setuid(1000)` 后能观察到非特权拒绝。**限制**：这些选项目前只存取和校验，不影响发出的报文（没有按 `SO_PRIORITY` 排队，`SO_MARK` 不参与路由，`SO_BINDTODEVICE` 不限制收发接口）；`SO_RCVLOWAT` 故意不提供（接受却忽略会让等待者永远等不到唤醒条件）；Linux 5.7 起 `SO_BINDTODEVICE` 需要 `CAP_NET_RAW`，这里的网络栈是单一命名空间，凡能说出接口名的都可以绑定。
- **IP 层套接字选项：`IP_TTL`、`IP_TOS`、`IPV6_UNICAST_HOPS`、`IPV6_TCLASS`、`IPV6_V6ONLY`（hello178）**：`setsockopt(SOL_IP/SOL_IPV6, …)` 此前直接 `ENOPROTOOPT`（因为 `sysSetSockopt` 在分发前就拒绝了 `SOL_SOCKET`/`SOL_TCP` 之外的层）。服务质量标记（`IP_TOS`/`IPV6_TCLASS`）、TTL 探测、`traceroute` 风格的工具都依赖它们。现在 `net/ip_opt_policy.zig` 定义校验、读回和报头补丁规则；值存在 TCP 的 `SocketOptions.ip` 与 UDP 端口的 `sockopt_policy.Stored.ip` 里。规则：`IP_TTL` 取 1..255，`-1` 恢复默认 64，其它 `EINVAL`；`IP_TOS`/`IPV6_TCLASS` 的低两位属于 ECN（TCP 自己管理），用户设置时被清掉；`IPV6_UNICAST_HOPS` 0..255（0 按 1 记，以便和“未设置”区分），`-1` 恢复默认；`IPV6_V6ONLY` 读回恒为 1（本栈没有 IPv4 映射的双栈，AF_INET6 套接字天然只收发 IPv6），把它设为 0 返回 `EINVAL`（无法兑现）。每个套接字只响应与其地址族匹配的层（IPv4 套接字用 `SOL_IP`，IPv6 套接字用 `SOL_IPV6`），否则 `ENOPROTOOPT`；其它描述符（AF_UNIX、原始套接字）也是 `ENOPROTOOPT`。发送路径：TCP 与 UDP 在 IPv4/IPv6 报头建好之后、ECN 标记之前调用 `patchIpv4`/`patchIpv6`——IPv4 写 TTL（字节 8）和 TOS（字节 1，保留已有 ECN 位）并重算头校验和，IPv6 写跳数限制（字节 7）和跨字节 0/1 的流量类别（保留 ECN 位）；两个值都没设置时完全不动报头。TCP 的 `SOL_SOCKET` 选项往返（REUSEPORT/BROADCAST/DEBUG）也携带 `ip`，不会把它们清掉。
- **`TCP_INFO`、`TCP_MAXSEG`、`TCP_CONGESTION` 与几个“接受但无事可调”的 TCP 选项（hello177）**：监控工具、HTTP 库、`ss` 风格的程序会对 TCP 套接字调用这些 `getsockopt`/`setsockopt`，此前全部 `ENOPROTOOPT`。`net/tcp_info_policy.zig` 定义选项号（取 Linux 值）、`struct tcp_info` 头部的编码和状态映射。`TCP_INFO`：写出 104 字节（状态、重传次数、选项位 TS/SACK/WSCALE/ECN、窗口缩放因子——后声明的位域在高半字节、`rto`、`snd_mss`/`rcv_mss`、`unacked`、`pmtu`、`rtt`/`rttvar`（微秒）、`snd_ssthresh`、`snd_cwnd`（按 MSS 折成段数）、`rcv_space`），其余清零；用户缓冲区更短时截断复制，`optlen` 回写实际写出的长度；连接状态映射到 Linux 编号（ESTABLISHED=1 … CLOSING=11，本内核的 closed 报 TCP_CLOSE=7）。`TCP_MAXSEG`：`getsockopt` 报告当前发送 MSS，`setsockopt` 只接受 88..1460，且只能在连接建立之前（`closed/listen/syn_sent`）设置，其余 `EINVAL`；设置值作为上限参与 `mssForTcb`（只会降低路径 MSS，不会抬高）。`TCP_CONGESTION`：读回 `cubic`，设置时只接受 `cubic`，其它名字 `ENOENT`。`TCP_USER_TIMEOUT`/`TCP_DEFER_ACCEPT`/`TCP_SYNCNT`/`TCP_LINGER2`/`TCP_NOTSENT_LOWAT`：接受并读回 0（本栈没有对应行为），负值 `EINVAL`（`TCP_LINGER2` 允许负值）。
- **网络接口 ioctl（hello175）**：`ifconfig`、`ip`、`getifaddrs` 的老路径、很多网络库启动时都用 `SIOCGIFCONF`/`SIOCGIFADDR`/`SIOCGIFFLAGS`/`SIOCGIFMTU`/`SIOCGIFHWADDR` 等 `netdevice(7)` 请求列举网卡，此前这些全部返回 `ENOTTY`。现在 `net/ifreq_policy.zig` 定义请求号（取 Linux 值）、40 字节 `struct ifreq` 的编码和 `SIOCGIFCONF` 的分块规则，`fs/ioctl.zig` 的 `netdeviceIoctl` 把它们接到内核状态：接口有 `lo`（索引 1，`127.0.0.1/8`，MTU 65536，`UP|LOOPBACK|RUNNING`，硬件地址族 `ARPHRD_LOOPBACK`，无广播地址）以及网卡存在时的 `eth0`（索引 2，地址/掩码/MAC/MTU 取自 `netif`，`UP|BROADCAST|RUNNING|MULTICAST`，广播地址 = 地址 | ~掩码）。名字必须在 16 字节内以 NUL 结尾，否则视为不存在（`ENODEV`），前缀不匹配；`SIOCGIFNAME` 按索引反查；`SIOCGIFCONF` 的 `ifc_buf` 为 NULL 时只回需要的字节数，否则只写完整的记录并把 `ifc_len` 改成实际写入量，`ifc_len` 为负 `EINVAL`；这些请求只在套接字描述符上有意义，其它描述符 `ENOTTY`，空/坏指针 `EFAULT`。
- **TCP 的 `SO_SNDBUF` / `SO_RCVBUF` 真正限定缓冲，及两处速率采样修复（hello174）**：此前 TCP 把用户给的原始值存下来原样返回（Linux 返回“翻倍后的值”：请求 8192 读回 16384，最小 4608/2304，上限 2×`rmem_max`=425984），而且这两个选项完全不起作用，发送环和接收窗口永远是整个环。现在 `socket_opt` 存 `bufferValue` 翻倍夹取后的值并记下“已设置”（`snd_buf_set`/`rcv_buf_set`，未设置的套接字保持原有行为，使用整个环）；`tcp_util.bufferLimit(set, stored, ring)` 把它换算成载荷上限（存储值的一半，不超过环，保留一个槽）。发送侧：`tcpSend`、`tcpSendFromUser`、`waitSendSpace`、`tcpSendSpace`、`tcpReadiness` 的剩余空间全部走 `roomUnder(used, sendLimit(tcb))`（饱和减法，上限被调低到已排队数据以下时剩余为 0 而不是回绕），所以 `SO_SNDBUF=8192` 时对端不读，发送方最多排队约 8 KiB；接收侧：通告窗口取 `min(TCP_WINDOW, bufferLimit)`，`SO_RCVBUF=16384` 时接收方最多缓冲约 16 KiB。写这个探测还顺带暴露了两个**既有缺陷**：①`sockopt_policy.bufferValue` 在 `@min(请求, RMEM_MAX)` 之后乘 2，`@min` 对编译期常量会把结果类型收窄到常量所需的位数（18 位），于是 `RMEM_MAX*2` 溢出，**请求值超过 212992 的 `setsockopt(SO_SNDBUF/SO_RCVBUF)` 会让内核 panic**（hello143 用的 65536 刚好没触发）；现在先扩成 `u32` 再饱和乘。②TCP 速率采样的“距上次采样的时间”在连接空闲期间仍在累计：一次写入、停顿、再写入，第二次确认会按“整个停顿时间”算出极低的速率，被发送节拍当成路径带宽，连接被节拍到几乎不动（hello173 只修了“小样本/长间隔”，这里是“连接已空闲后的第一个样本”）。现在 `tcp_util.sampleBaseAfterAck(all_acked, now)`：所有数据都被确认后采样基准清零，下一次确认只负责重新建立基准、不产生样本。 **后续修复（hello174 的多核偶发失败）**：接收方 `processIncomingData` 原来只按 64 KiB 环截断，不按自己通告的窗口截断，多核下发送方在窗口更新到达前多发的数据会被照单全收，缓冲超出 `SO_RCVBUF`。现在拷贝长度取 `tcp_util.acceptableBytes(len, 已缓冲, rcvWindowCap)`，超出的部分不接收（`rcv_nxt` 只前进已收的字节，发送方按 ACK 重发）。
- **`SIGSTOP`/待处理信号立刻踢目标所在的 CPU（hello259 末项）**：目标在另一颗 CPU 上运行时，`kill` 只置待处理位，目标要等那颗 CPU 的下一次时钟节拍（约 10 ms）才停下。`signal.kickRunningCpu` 按各 CPU 的 `current_task_idx` 找到该 CPU 并发重调度 IPI；`stopTask` 和 `sendSignalInfo`（目标为运行态或就绪态——换出中的任务先被标成就绪、上下文仍在原 CPU 上——且信号可执行或默认动作为停止）都会调用；`sched.deliverSignalToRunningTask` 的默认停止分支返回 `false`，让本次中断接着做调度而不是沿帧恢复用户态。
- **`bind()` 对本机没有的地址返回 `EADDRNOTAVAIL`（hello183 F 段）**：此前 `bind(192.0.2.1:port)` 会成功。新增纯策略 `net/bind_addr_policy.zig`：IPv4 放行 `0.0.0.0`、`127/8`、组播、`255.255.255.255` 和网卡存在时的本机地址与子网广播；IPv6 放行 `::`、`::1`、`ff00::/8`、IPv4 映射地址（按其 IPv4 部分）、网卡链路本地地址和 NDP 已配置的地址。`socket_syscall.bind` 的 TCP/UDP × IPv4/IPv6 四条路径都在端口规则（`EACCES`、`EADDRINUSE`）之前先问这个策略，与 Linux 的检查顺序一致。未实现 `IP_FREEBIND`/`IP_TRANSPARENT`。
- **`ioctl(TIOCOUTQ / SIOCOUTQ)` 与 TCP 速率采样修复（hello173）**：`TIOCOUTQ`（0x5411）此前对套接字返回 `ENOTTY`（被当成终端请求之外的未知命令）。现在套接字回答“已发送但对端还没消费的字节数”：TCP 是发送环里的全部数据（未发送加未被确认，`tcpSendQueued`），AF_UNIX 是对端接收环里的内容（`unixSendQueued`，先校验反向引用，对端槽位被复用时返回 0），UDP 恒为 0，其它描述符仍 `ENOTTY`；结果夹到非负 `int` 再写出。写这个探测时发现一个**真实的 TCP 缺陷**：交付速率采样（`noteDelivery`）把任何“距上次采样有时间流逝”的确认都当成带宽样本，包括一次 100 字节小写入在 100 ms 延迟 ACK 之后才被确认（样本约 250 B/s）或空闲很久之后的第一次确认。该低速率随后被 BBR 式的发送节拍（`bbrPacedRate`/`probePaceIntervalMs`）当成路径速率，一个 1460 字节的段要隔约 5 秒才发出，而发出的段又产生下一个同样低的样本，**连接再也恢复不了**：实测 64 KiB 的传输在对端持续读取的情况下约 1.3 秒才送出一个段，20 秒只传了约 25 KiB。现在 `tcp_util.deliverySampleUsable(delivered, smss, elapsed)` 只接受“超过一个 MSS 且距上次采样不超过 1 秒”的样本（应用受限的小写入和空闲间隔都不代表链路带宽），同样的传输在约 13 ms 内完成。 之后补上 `SIOCOUTQNSD`（0x894B，hello173 E 段）：只有 TCP 回答发送环里还没发出的字节数（`tcpSendUnsent`，发送游标到写入位置），UDP、AF_UNIX 与其他描述符都是 `ENOTTY`（与 Linux 一致，和 `SIOCOUTQ` 不同）。
- **IPv6 回环上 UDP 的 ICMPv6 端口不可达与 `ECONNREFUSED`（hello172）**：hello161 只给 IPv4 做了端口不可达，`::1` 上发往无人绑定端口的 UDP 数据报仍被静默丢弃，已 `connect` 的 IPv6 UDP 套接字永远不知道。现在 `udp.handlePacketV6` 发现目的端口没有绑定者且源、目的都是 `::1` 时，经 `lo` 回 ICMPv6 目的不可达/端口不可达（type 1 code 4，引用原 IPv6 头加 UDP 头前 8 字节，校验和用回复自己的伪首部，即源=目的方向互换）；`icmp_unreach_policy.shouldReplyV6` 把规则固定为“仅 `::1`→`::1`、端口未绑定”（对外部主机的未请求流量回应是反射途径，且需要邻居发现）。`icmpv6.handlePacket` 新增 `DEST_UNREACHABLE` 分发：`parseQuoteV6` 校验类型/代码、IP 版本为 6、下一头为 UDP、长度足够后取出端口，交给与 IPv4 共用的 `udp.notifyUnreachable`，之后的表现与 hello161 完全一致（下一次 `recvfrom` 返回一次 `ECONNREFUSED`、下一次发送失败一次、`SO_ERROR` 读后清零、poll/epoll 报错误，未 `connect` 的套接字不受影响）。
- **IPv6 回环上 TCP `connect` 到无人监听的端口立即 `ECONNREFUSED`（hello171）**：hello160 只给 IPv4 加了“回环 RST”，IPv6 的 `handlePacketV6` 对没有连接也没有监听者的 SYN 直接丢弃，`connect(::1)` 只能等 SYN 重传超时（阻塞 connect 一直挂着，非阻塞 connect 的 `POLLERR` 迟迟不来）。现在 `handlePacketV6` 与 IPv4 同一规则：SYN 没有产生新连接（积压没增加）且该端口没有 IPv6 监听者时，调用 `sendLoopbackResetV6` 回 RST（有 ACK 则 `seq=ack`、无 ACK 则 `RST|ACK` 且 `ack=seq+长度+SYN/FIN`，沿用 `tcp_util.resetReply`），**只对 `::1` 到 `::1`**（回环不需要 NDP；对外部地址主动回 RST 可能被用作反射，且需要邻居解析），从不回应 RST，经 `lo` 设备送回，IPv6 伪首部校验和。收到 RST 后沿用 hello160 的路径：阻塞 `connect` 返回 `ECONNREFUSED`、`poll` 报 `POLLERR`、`SO_ERROR` 读一次后清零。
- **进程 CPU 时间覆盖所有线程与已回收的子进程（hello170）**：此前 `getrusage(RUSAGE_SELF)` 与 `CLOCK_PROCESS_CPUTIME_ID` 只统计调用线程，`RUSAGE_CHILDREN` 恒为 0，`wait4` 的 `rusage` 恒为 0。现在 `proc/cpu_time_policy.zig` 定义汇总规则，`task.zig` 里 `groupTimesLocked` 按线程组累加：每个成员（线程按 `parent_tid`、组长按 `tid`）的 `utime_us/stime_us`，加上正在运行的成员尚未计入的当前时间片，加上组长保存的“已回收线程”时间（`dead_utime_us/dead_stime_us`）。线程槽被回收（`freeSlotLocked`/`detachLocked`）前由 `foldThreadTimeLocked` 把它的时间并入组长，避免回收后进程时间倒退。`waitpidScanLocked` 回收子进程时，把该子进程整组时间加上它自己已回收的孙进程时间（`reapedUsage`）并入等待者组长的 `child_utime_us/child_stime_us`，所以孙进程的时间会沿 wait 链向上累计；`wait4` 把同一份数据写进调用者给的 `rusage`（只有真正回收了子进程才写）。`RUSAGE_THREAD` 与 `CLOCK_THREAD_CPUTIME_ID` 仍只统计调用线程。已知问题（**未能复现**）：hello170 的 D 段在一次 SMP=8 运行中，主线程睡眠期间它的线程时钟涨了约 210 ms；从代码看，阻塞任务如果在 `forceReschedule` 没有真正切走（`repairCurrentAfterBlock` 注释描述的情形）就仍是当前任务，读 CPU 时间时的“当前时间片”（`now - sched_in_tsc`）不区分它是否在睡眠，所以有可能多算睡眠时间。但 hello176 专门构造了睡眠场景（单次 300 ms、20 ms 与 1 ms 的反复小睡、有自旋线程时的小睡）在 SMP=1/2/8 上共 9 次运行，睡眠期间线程时钟只涨 1~16 ms，没有一次复现，所以没有改动内核记账；hello176 作为回归保护保留。另一处真缺陷：`exitTask` 在置为僵尸前不折算当前时间片，而切出时的统计又因任务已是僵尸而跳过，结果任务最后一次运行的时间片丢失；现在退出时先折算（并把 `sched_in_tsc` 清零）。
- **`socket(AF_UNIX, SOCK_SEQPACKET)` 与 `listen/connect/accept`（hello169）**：hello168 只有 `socketpair` 能建 seqpacket，`socket()` 仍是 `EINVAL`。现在 `namespace_policy.socketArgs` 放行类型 5（只对 AF_UNIX；AF_INET/AF_INET6 仍 `EINVAL`，AF_UNIX 的 RAW 仍 `EINVAL`，非 0 协议仍 `EPROTONOSUPPORT`），`unixSocket` 接受 `SOCK_SEQPACKET`。`unixListen`/`unixAccept` 改为接受任何 `connectionOriented` 类型；`unixConnect` 先比较对端类型，**类型不同返回 `EPROTOTYPE`**（Linux 同），面向连接的类型都走“排进监听者积压队列”那一支（此前 seqpacket 会落进数据报的“直接设默认对端”分支）；`unixAccept` 新建的套接字沿用监听者的类型，且只接受同类型的排队连接者。**connect 之后、accept 之前就发送**：流套接字原本就把字节放进 `pending` 缓冲，seqpacket 现在把“2 字节长度前缀 + 数据”整条记录放进同一个缓冲（单条超过缓冲上限 `EMSGSIZE`，放不下 `EAGAIN`），accept 时原样搬进接收环，所以记录边界保持；携带描述符（SCM_RIGHTS）在 accept 之前仍是 `ENOTCONN`。半关闭（`shutdown`）、发送余量判断（`sendRoomLocked`）、EOF 判断与 epoll 的断开/半关闭状态都从“仅 STREAM”改成 `connectionOriented`，seqpacket 与流一致。
- **`socketpair(AF_UNIX, SOCK_SEQPACKET)`（hello168）**：此前只支持 STREAM 与 DGRAM，`SOCK_SEQPACKET` 得 `EINVAL`（systemd/D-Bus 风格的“有连接又保留消息边界”的通道用它）。现在 `socketpair_policy` 与 `unixSocketPair` 接受 `SOCK_SEQPACKET`（连同 `SOCK_NONBLOCK|SOCK_CLOEXEC`），实现复用数据报的“2 字节长度前缀 + 数据”环形缓冲，所以消息边界、短缓冲截断（余下丢弃）、`MSG_TRUNC` 返回真实长度、`MSG_PEEK` 全部沿用已有路径；与数据报不同的是它**面向连接**：新增 `connectionOriented(sock_type)`（STREAM 或 SEQPACKET），对端关闭后空环 `read` 返回 0（EOF，而不是数据报的 `EAGAIN`），阻塞读被对端关闭唤醒，向已消失的对端发送得到 `EPIPE`（数据报是 `ENOTCONN`），epoll 就绪走“已断开 → `IN|OUT|HUP`”；epoll 对 seqpacket 的可写判断要求有“长度前缀 + 1 字节”的余量（`msg_boundaries`）。`getsockopt(SO_TYPE)` 报告 5（`sockopt_policy.Kind.unix_seqpacket`）。
  已知差异：只有 `socketpair` 能创建 seqpacket；`socket(AF_UNIX, SOCK_SEQPACKET)` 加 `bind/listen/connect/accept` 仍然返回 `EINVAL`（`socketArgs` 只放行 STREAM/DGRAM/RAW），下一个切片再做。
- **`recvmsg` 的 `MSG_PEEK`、`MSG_WAITALL`、`MSG_TRUNC`（hello167）**：hello165 只把这三个标志接到了 `recvfrom`；`recvmsg` 上 AF_UNIX 忽略它们（`MSG_PEEK` 会消费数据），TCP 的 `recvmsg` 对任何标志都返回 `EINVAL`。现在：
  - AF_UNIX `recvmsg`：`MSG_PEEK` 走 `unixPeek`（阻塞套接字会睡到有数据可看，不交付也不释放描述符集，凭据照常带回）；`MSG_WAITALL`（流）循环读到所有 iovec 装满，中途再到的描述符集第一个交付、其余释放并置 `MSG_CTRUNC`；数据报被缓冲区截断时 `msg_flags` 带 `MSG_TRUNC`，调用时传 `MSG_TRUNC` 则返回真实长度。
  - TCP `recvmsg`：只接受 `MSG_PEEK | MSG_DONTWAIT | MSG_WAITALL`，其它位仍然 `EINVAL`。先校验全部 iovec 并汇总可用空间（此前是边校验边消费），再一次性读入再散布到各 iovec；`MSG_PEEK` 不消费，`MSG_WAITALL` 阻塞到装满或流结束。
  已知差异：TCP `recvmsg` 单次最多 4096 字节、最多 16 个 iovec 段；AF_UNIX 数据报的 `MSG_PEEK` 不带描述符集。
- **`fork`/`clone` 的子进程继承父进程的 SSE/x87 寄存器（hello166）**：ABI 规定系统调用保留向量寄存器，`fork` 返回后的子进程应当看到和父进程调用 `fork` 时相同的 xmm0–15。此前新任务的 `fpu_state` 是全零、`fpu_initialized=false`，子进程首次被调度时 `onSwitchIn` 对它做 `fninit`，**xmm 寄存器内容变成了全零/初始状态**。编译器在 `fork` 前后把常量或中间值放在 xmm 里（典型的是用 `movaps` 一次写 16 字节的 `sockaddr`/结构体初始化）是很常见的，所以子进程读到全零。现在 `context_switch.inheritFpuState(parent, child)` 在 `fork` 与 `clone` 里调用：若当前 CPU 持有父进程的活跃 FPU 状态，先 `fxsave` 到父进程的区域，再把整块 512 字节复制到子进程并置 `fpu_initialized=true`、`fpu_owned=false`、`fpu_home_cpu=0`，子进程首次切入时从自己的区域 `fxrstor`。
- **TCP / AF_UNIX 的 `MSG_PEEK`、`MSG_WAITALL` 与 AF_UNIX 数据报的 `MSG_TRUNC`（hello165）**：此前这几个 `recv` 标志只在 UDP 上生效。TCP 与 AF_UNIX 的 `MSG_PEEK` 把数据**消费掉**（协议解析器先 peek 报文头再决定读多少的做法因此全部读丢数据）；`MSG_WAITALL` 在第一个数据块到达就返回；AF_UNIX 数据报的 `MSG_TRUNC` 不报告真实长度。现在：
  - `MSG_PEEK`：新增不改状态的 `unixPeek`（流：看队列前 n 字节；数据报：看下一条消息头部并给出真实长度）与 `tcpPeek`，不动读指针/`rx_pos`/窗口/ACK、不交付也不释放描述符集；阻塞套接字上的 peek 会睡到有东西可看（`unixWaitReadable`/`tcpWaitReadable`，后者不消费数据，也每个切片泵一次回环队列）。
  - `MSG_WAITALL`（`recv_flags_policy.waitAll`：仅流套接字、仅阻塞、不与 `MSG_PEEK` 同用）：循环读到缓冲区装满；中途遇到 EOF、错误或信号就返回已读到的字节（`waitAllStep`）。
  - `MSG_TRUNC`：AF_UNIX 数据报读取时 `RightsOut.full_len` 带回消息真实长度，缓冲区更小则返回真实长度。
  已知差异：（`recvmsg` 的这三个标志见 hello167）`MSG_TRUNC` 对流套接字无意义。
- **AF_UNIX 的 `SO_PASSCRED` 与 `SCM_CREDENTIALS`（hello164）**：此前 `setsockopt(SO_PASSCRED)` 返回 `ENOPROTOOPT`，`recvmsg` 永远不带凭据，`sendmsg` 带 `SCM_CREDENTIALS` 直接 `EINVAL`；依赖它识别对端的守护进程（D-Bus、systemd 风格的 socket 激活服务）无法工作（只有连接时快照的 `SO_PEERCRED` 可用）。现在：
  - `SO_PASSCRED`（16）是普通布尔选项（`sockopt_policy.flagBit` 新增位 32），可 set/get。
  - 每个 AF_UNIX 套接字记录写入其环的**最近一个发送者**的凭据（`sender_cred`：线程组 id、真实 uid/gid；`sendmsg` 带显式 `SCM_CREDENTIALS` 时记录经校验的那组），`unixRecvRights` 读出时随数据一并取走。
  - `recvmsg` 在接收端设置了 `SO_PASSCRED` 时，把 `SCM_CREDENTIALS`（`scm_policy.buildCredentials`：CMSG_LEN 28 / CMSG_SPACE 32，`{pid,uid,gid}`）放在控制数据最前面，之后才是 `SCM_RIGHTS`；控制缓冲区放不下整条凭据就一点也不写并置 `MSG_CTRUNC`（凭据不会被截成一半），描述符的可用空间扣除凭据占用。控制数据拷贝失败时已安装的描述符会被关闭，不泄漏。
  - `sendmsg` 的显式 `SCM_CREDENTIALS` 只允许声明调用者自己的 pid/uid/gid，声明别人的需要对应能力（pid 需 `cap_sys_admin`，uid 需 `cap_setuid`，gid 需 `cap_setgid`，`scm_policy.credsAcceptable`），否则 `EPERM`。
  已知差异：凭据按“环里最近一次写入”而不是逐条消息记录（流套接字里先后两个发送者的数据混在一个环里时，读到的是最后一个发送者；数据报套接字因为一次一条所以是逐条准确的）；`SO_PASSCRED` 对 TCP/UDP 没有意义。
- **`socketpair(AF_UNIX, SOCK_DGRAM)`（hello163）**：此前 `socketpair` 只接受 `SOCK_STREAM`，数据报式的进程间消息通道（常见于“一问一答”的小协议、`sd_notify` 风格）拿到 `EINVAL`。现在 `socketpair_policy.validate` 接受 `SOCK_STREAM` 与 `SOCK_DGRAM`（连同 `SOCK_NONBLOCK|SOCK_CLOEXEC`），`unixSocketPair(sock_type)` 建立两个互为 `peer_idx` 的已连接数据报套接字，消息边界、短缓冲截断（余下丢弃）、空队列 `EAGAIN`、阻塞读被对端数据报唤醒、对端关闭后发送失败，都沿用既有 AF_UNIX 数据报路径。`SOCK_SEQPACKET`、`SOCK_RAW` 等仍然 `EINVAL`。
  - 顺带修的一个死锁：`unixSendBlocking` 的数据报分支在持有 `unix_lock` 的块里，遇到没有对端（`sendRoomLocked` 返回 null）时直接 `return unixSendRights(...)`，而后者自己要取 `unix_lock`，对已关闭对端的数据报发送因此自旋死锁（单核）。改为在块里只算出“能放下/让真正的发送去报错”，锁释放后再调用 `unixSendRights`。
- **`ppoll`/`pselect6`/`select` 写回剩余超时（hello162）**：Linux 的这三个调用在返回时把没用完的超时写回调用者的 `timespec`/`timeval`（`pselect6` 的 glibc 包装隐藏了这一点，裸系统调用和 `select` 会暴露），依赖它做“累计剩余时间”的循环（先 `poll` 一会儿、被事件打断后继续等剩下的时间）此前每次都从头再等。现在 `poll.beginTimeout` 在等待前记录调用者的超时和起始时刻，`finishTimeout` 在返回后写回 `原超时 − 已用时间`（纯函数 `poll_policy.remainingNs/splitNs/timeoutNs`，下限为 0，`timespec` 单位 ns，`select` 的 `timeval` 单位 µs）；信号中断（`EINTR`）也写回，参数错误（`EFAULT`/`EINVAL`/`EBADF`，从未等待）不动；空指针（永久等待）什么也不写。`poll(2)` 的超时是整数毫秒，不涉及。
- **UDP 的 ICMP 端口不可达与 `ECONNREFUSED`（hello161）**：此前发往没有绑定者的回环端口的 UDP 数据报被静默丢弃，已 `connect` 的 UDP 套接字永远不知道对端不存在（Linux 在下一次调用时返回 `ECONNREFUSED`，`poll` 报 `POLLERR`，`SO_ERROR` 可读）。现在：`udp.handlePacket` 发现目的端口没有绑定者且数据报来自回环时发 ICMP 目的不可达/端口不可达（type 3 code 3，引用原 IP 头和 UDP 头前 8 字节；`icmp_unreach_policy.shouldReply` 只对回环、非广播、端口未绑定的数据报回复，因为回环不需要 ARP，而对外部网络主动回应未请求的数据报是反射放大的途径）；`icmp.handlePacket` 解析引用（`parseQuote`）后调用 `udp.notifyUnreachable`，只有 `connect` 过且对端端口正是被引用的目的端口的套接字（`matchesConnected`）记录 `ECONNREFUSED`；该错误在下一次 `recvfrom` 返回一次（先于排队数据）、`getsockopt(SO_ERROR)` 可读且读后清零、poll/epoll 报 `POLLERR`/`EPOLLERR`，并唤醒 epoll 等待者。未 `connect` 的套接字不受影响（与 Linux 一致）。 同一个待决错误也让**下一次 `sendto`/`send`** 失败一次（`ECONNREFUSED`），之后恢复正常发送。
- **TCP `connect()` 的完成与失败语义（hello160）**：此前 `connect` 发出 SYN 就返回 0，不等握手，也不告诉你结果：连到没人监听的端口，阻塞套接字拿到“成功”，随后第一次 `send` 才失败；非阻塞套接字拿不到 `EINPROGRESS`，`poll` 不会报 `POLLERR`，`SO_ERROR` 恒为 0；SYN 被拒绝（RST）或超时的原因没有任何地方记录。现在：
  - **拒绝**：回环上没有监听者的 SYN 由 `sendLoopbackReset` 立刻回 RST（RFC 9293 §3.10.7.1，`tcp_util.resetReply` 计算 SEQ/ACK）；只对回环做，因为它不需要 ARP，对外部网络不回应主机并不监听的端口也是常见的防反射做法。`SYN_SENT` 收到有效 RST 时记录 `so_error = ECONNREFUSED`，SYN 重传超限记录 `ETIMEDOUT`。
  - **阻塞 connect**：`tcpWaitConnected` 等到握手结束，成功返回 0，失败返回记录的 errno 并清除 `SO_ERROR`；等待期间每个切片泵一次回环队列，信号可以打断（`EINTR`，握手继续）。
  - **非阻塞 connect**：返回 `EINPROGRESS`；完成时 `POLLOUT`，失败时 `POLLERR|POLLHUP`（`tcp_ready_policy` 的 `so_error` 报 `ERR`），原因在 `SO_ERROR`，读取后清零。
  - 在已连接或正在握手的套接字上 `connect`：`EISCONN`/`EALREADY`（此前是裸 `-1`）。
  hello27（连 SLIRP 网关 10.0.2.2:80，那里没有 TCP 服务）改为非阻塞 connect，否则阻塞 connect 会等完整的 SYN 重传（约两分钟）。已知差异：对非回环目标不发 RST（IPv4 与 IPv6 一样：回环 `127/8` 和 `::1` 上无连接匹配的段由 `sendLoopbackReset`/`sendLoopbackResetV6` 回 RST）；`connect` 的超时没有 `SO_SNDTIMEO` 控制。
- **AF_UNIX 的 `EPOLLRDHUP` / `POLLRDHUP`（hello159）**：`unix_epoll_policy.events` 新增 `peer_shut_wr`：对端 `shutdown(SHUT_WR)` 或对端已断开（关闭）时流套接字报 `EPOLLRDHUP`（断开时与 `IN|OUT|HUP` 一起）；本端自己的 `SHUT_RD`/`SHUT_WR`、数据报套接字和监听套接字都不报；`EpollWake`（`shutdown`/`close` 的通知）带上 `EPOLLRDHUP`，所以阻塞在 `epoll_wait` 的任务会被唤醒。poll 与 epoll 共用 `unixEpollEvents`，同样只在调用者请求时返回。
- **`EPOLLRDHUP` / `POLLRDHUP`（hello158）**：事件循环靠它检测“对端关闭了写方向”（半关闭）而不必先 `read` 到 0。`tcp_ready_policy.events` 在对端已发 FIN（`CLOSE_WAIT`、`LAST_ACK`、`CLOSING`、`TIME_WAIT`）或连接已关闭时置 `RDHUP`（0x2000），**只在调用者请求时**才返回（epoll 的兴趣掩码、poll 的 `events` 过滤）；本端自己的 `SHUT_RD`/`SHUT_WR` 不触发它；收到对端 FIN 时 `driveTcbStateMachine` 用 `EPOLLIN | EPOLLHUP | EPOLLRDHUP` 唤醒 epoll 等待者。AF_UNIX 的 `RDHUP` 见上一条（hello159）。
- **TCP 套接字的 poll/epoll 就绪状态（hello157）**：此前 epoll 对**每一个** TCP 套接字都无条件加 `EPOLLERR`（空闲、健康的连接也一样），`CLOSE_WAIT`（对端已 `SHUT_WR`，本端仍可回复）既不可写，本端 `SHUT_RD` 之后也不报可读（此时 `read` 立即返回 EOF），而 poll 与 epoll 各用一套互相不一致的判断。现在 `net/tcp_ready_policy.events` 是同一个纯函数（`tcp.tcpReadiness` 取快照），poll 与 epoll 共用，规则取 Linux `tcp_poll`：可读 = 有数据，或读会返回 EOF（对端 FIN、本端 `SHUT_RD`、连接已关闭）；可写 = 发送环有空位，或本端已关闭写方向（写会立即失败，不应让轮询者阻塞）；`HUP` = 两个方向都结束（或连接已关闭）；`ERR` 只在对端 RST 时出现；握手中的连接什么也不报，监听套接字有待接受连接时可读。`file_io.read` 判断后续数据块是否可读（hello152）用的也是这套 poll 就绪，所以 `read` 在 EOF 连接上的行为也随之正确。
- **TCP `shutdown(SHUT_RD)`（hello156）**：此前 `SHUT_RD` 只清空当时的接收环，之后 `read` 仍会返回后来到达的数据，也不会读到 EOF。现在 `TcpTcb.shut_rd` 记录它（`SHUT_RDWR` 同样）：`recvLocked` 和阻塞 `recv` 的等待循环都先看 `tcp_recv_policy.shutRdEof`，读到 EOF（0），阻塞读者被 `markRecvWake` 唤醒；之后到达的数据在 `processIncomingData` 里只推进 `rcv_nxt` 并回 ACK、不入环（对端不会重传，也不会收到“读端已关闭”的任何通知，与 Linux 的 TCP 行为一致）。
- **套接字发送遇到 EPIPE 时发 SIGPIPE，`MSG_NOSIGNAL` 可抑制（hello155）**：此前 TCP/AF_UNIX 的 `write`、`sendto`、`sendmsg` 在对端已关闭或本端已 `SHUT_WR` 时只返回 `-EPIPE`，不发 `SIGPIPE`（管道的 `write` 早已按 Linux 发信号），所以不处理返回值的程序会无声地继续写，而按惯例依赖 `SIGPIPE` 终止的程序（如 `producer | head` 之类的套接字版本）永远不会被终止。现在 `namespace_policy.sendResult(result, flags)` 统一包装：结果是 `-EPIPE` 且调用没有 `MSG_NOSIGNAL`（0x4000）时对当前任务 `raiseSelf(SIGPIPE)`；`vfs.write`（TCP、AF_UNIX）、`sendto`、`sendmsg`（TCP、AF_UNIX）和 `sendmsg` 多段写都经过它。信号在系统调用返回时才投递，所以 `sendto`（121）和 `sendmsg`（129）的分发补上了 `checkSignalsOnSyscallReturn`（`write` 原来就有）。UDP 不会 `EPIPE`，不受影响。
- **TCP 写错误码与半关闭（hello154）**：此前对已 `shutdown(SHUT_WR)`、对端已关闭或从未连接的 TCP 套接字写，`write`/`sendto` 返回裸 `-1`（`EPERM`），`SHUT_WR` 之后对端的 `CLOSE_WAIT` 连接还被禁止发送（对端发了 FIN 之后“回复”被拒），从未连接的套接字 `read` 报 EOF 而不是 `ENOTCONN`。现在：`tcp_recv_policy.canQueueSend` 允许 `ESTABLISHED` 和 `CLOSE_WAIT`（对端只关了它的发送方向）排队发送；`sendErrno` 把不能发送的情形映射为 `ECONNRESET`（对端 RST）、`EPIPE`（本端已 `SHUT_WR`/已发 FIN/曾经连接过）或 `ENOTCONN`（从未连接）；`TcpTcb.was_established` 记录握手是否完成过；`recvNeverConnected` 让从未连接的 `read` 返回 `ENOTCONN`。对端已 `close()` 的孤儿连接（`FIN_WAIT_1/2`，引用计数为 0）收到新数据时回 `RST`（RFC 9293 §3.10.7.4，`tcp_util.orphanRejectsData`），所以写者在下一次写得到 `EPIPE`，而不是把数据写进无人接收的连接。
- **AF_UNIX `shutdown(2)` 的半关闭语义（hello153）**：此前 `unixShutdown` 不记录任何状态，只是唤醒对端的读者，所以 `SHUT_WR` 之后对端读空缓冲区得到 `EAGAIN`（阻塞读者醒来又睡下），本端写仍然成功，`SHUT_RD` 完全无效。现在每个套接字端记录 `shut_rd`/`shut_wr`：`SHUT_WR` 让本端发送失败（`EPIPE`），对端在排空已发送的数据后读到 EOF（0）；`SHUT_RD` 让本端读到 EOF，对端发送失败（`EPIPE`）；`SHUT_RDWR` 两者兼有；反方向仍然正常工作。判定在纯策略 `namespace_policy.halfCloseReadEof/halfCloseSendBroken`，接收、发送、`parkOn`（读等待条件）、`sendRoomLocked` 和 epoll 就绪（`read_eof` 使其可读、`send_broken` 使其可写）共用；`shutdown` 同时唤醒本端和对端的读/写等待者。数据报套接字不记录半关闭状态。
- **`read()` 返回当前可读的数据，不为凑满缓冲区而阻塞（hello152）**：`file_io.read` 以 4 KB 为一块循环，第一块读满后就会对描述符再发一次读；对管道、套接字这类流，下一块可能还没有数据，阻塞读者就会一直等到调用者根本不需要的数据（例如 `read(fd, buf, 8192)` 而对端只写了 4096 字节，会永远挂住）。现在 `namespace_policy.readContinues(regular, ready)` 决定是否继续：普通文件（ramdisk/FAT32/ext2/tmpfs/rofs/proc）总是继续，其它描述符只有在 `poll.descEvents` 报告 `POLLIN` 时才取下一块。
- **TCP 套接字的 `read`/`write`、阻塞发送与 `SO_SNDTIMEO`（hello151）**：此前 `read(2)`/`write(2)` 作用在 TCP 套接字描述符上直接返回 -1（只有 `sendto`/`recvfrom` 可用），发送环（64 KB）满时 `sendto` 返回短写或 0 而不阻塞。现在 `tcp.tcpSendBlocking` 统一承担 `write`/`sendto`/`sendmsg`：循环入环，`namespace_policy.writeProgress` 决定下一步，环满时 `waitSendSpace` 睡在 `send_waiters[tcb]` 上，ACK 推进 `send_head` 的三处（正常 ACK、`absorbDataAckBeforeFin`、FIN 被确认）调用 `markSendWake`，`TcpLock.release` 在放锁后统一唤醒（与接收等待者同一条延迟唤醒链，连接拆除/状态变化也唤醒写者）；`SO_SNDTIMEO` 用与接收超时相同的睡眠截止时间机制，超时返回已入环的字节数，一个字节没写则 `EAGAIN`。`read` 走 `tcpRecvBlocking`，读到数据后立即泵一次 lo 队列，让对端尽快收到窗口更新。`MSG_DONTWAIT`/`O_NONBLOCK` 立即返回。
- **hello151 顺带暴露并修复的六个 TCP 缺陷**（都在大块数据传输下才出现，之前的测试从未发送过超过一个窗口的数据）：
  1. **带时间戳的满 MSS 段永远发不出去**：`flushSendBuffer` 按 MSS（1460）切段，但 `sendSegment` 的路径 MTU 门禁把 TCP 选项（时间戳 12 字节）算在同一个 MTU 里，1460+12 超过 1500-40，段被拒绝，发送环永远排不空。现在按 `tcp_util.dataSegmentCap(mss, opt_len)` 切段，Nagle/CORK 的“满段”判断也用它。
  2. **重复 ACK 计数器溢出导致内核 panic**：`dup_ack_count` 是 `u3`，对端持续发重复 ACK（零窗口探测的应答等）时 `+= 1` 在第 8 次溢出 panic。改为饱和加法 `tcp_util.bumpDupAck`。
  3. **PRR 把拥塞窗口算成 0**：恢复期里 `cwnd = pipe + sndcnt`，管道空且 `sndcnt` 为 0 时窗口为 0，既发不出段、也没有 RTO 定时器（没有在途数据），连接永久停住。`tcp_util.prrCwnd` 保证管道空时至少一个 SMSS。
  4. **`snd_max` 初值为 0**：空闲连接的“有未确认数据”判断 `seqLt(snd_una, snd_max)` 在 ISS ≥ 2^31 时恒为真（序号回绕比较），空闲连接不停触发伪 RTO（cwnd 复位、RTO 退避），六次后被关闭。七处把 `snd_nxt` 设为 ISS 的位置现在同时设置 `snd_max`，判断集中到 `tcp_util.unackedPending`。
  5. **接收方对“丢弃的乱序段”发 SACK**：接收路径没有乱序队列，段被丢弃，却把它作为 SACK 块报告给发送方；发送方认为这段已送达，等空洞补上后不再重发，连接停住直到 RTO 放弃（hello151 B 段约 1/3 概率出现）。现在只对真正收到的数据发 DSACK（`tcp_util.oooReport`），领先于 `rcv_nxt` 的段不报告；RTO 时清空发送方的 SACK 记分板（RFC 2018 §8：接收方可以反悔）。
  6. **BDP 窗口过小**：回环上带宽时延积只有几个字节，BBR 各退出路径直接把它写进 `cwnd`/`ssthresh`，发送方只能一次发几个字节。`tcp_util.bdpWindow` 给下限两个 SMSS。
- 已知差异：接收方仍没有乱序队列（乱序段被丢弃，靠重传恢复，吞吐低于 Linux）；`TCP` 的 `SO_SNDBUF` 仍不改变发送环大小。
- **AF_UNIX `SO_SNDTIMEO`（hello150 E 段）**：`unixSendBlocking` 现在读取套接字的 `snd_ms`，在第一次需要等待时算出绝对截止时间，`parkOn(…, deadline)` 带截止时间睡眠（与接收超时共用同一条睡眠定时器路径，原来的 `parkTimed` 合并进 `parkOn`）；超时后返回已写入的字节数，一个字节也没写则 `EAGAIN`（`namespace_policy.sendTimeoutResult`）。超时是整个写调用的总时限，不是每次睡眠重新计时。UDP 的发送不会阻塞，所以不需要发送超时；TCP 的发送超时不在本次范围。
- **AF_UNIX 阻塞写等待空间（hello150）**：此前 `write`/`sendto` 对 AF_UNIX 调用的 `unixSend` 是非阻塞的：8 KB 环形缓冲满了就返回短写或 `EAGAIN`，阻塞套接字也不等，所以 `write(fd, buf, 30000)` 不能像 Linux 一样阻塞到读者读完。现在 `unixSendBlocking` 负责：流套接字循环写，`fs/namespace_policy.writeProgress` 决定下一步（全部写完 / 继续 / 非阻塞短写返回 / 失败 / 等待），环满时 `parkOn(.write, 1)` 睡在对端的写等待队列上，读者 `unixRecv` 腾出空间时唤醒；数据报要整条放得下（`dgramFits`，长度加 2 字节前缀不超过环大小）才发送，放不下且非阻塞返回 `EAGAIN`，阻塞则等到有足够空间。`MSG_DONTWAIT` 与 `O_NONBLOCK` 仍然立即返回；`vfs.write` 与 `sendto` 共用这条路径。`unixClose` 现在也唤醒对端的写等待者，否则读者关闭后阻塞的写者会永远睡着（它醒来后得到 `EPIPE`，或在已写入部分字节时返回短写）。已知差异：AF_UNIX 的 `SO_SNDTIMEO` 见下一条；超过环大小的数据报直接 `EAGAIN`/`EMSGSIZE` 的细节与 Linux 的 `sk_sndbuf` 计算不同。
- **fstat 对各类描述符报告正确的文件类型（hello148）**：此前 `fstat` 对管道之外的所有“非磁盘文件”描述符都落到 `S_IFREG`——socket、eventfd、epoll、`/dev/null`、`/dev` 目录都被报告成普通文件，`st_ino` 是 fd 号本身（不同进程里同一对象的号码不同，复用 fd 号会撞车），`st_nlink` 为 0，`st_blksize` 为 0；程序用 `S_ISSOCK`/`S_ISFIFO`/`S_ISCHR` 判断描述符类型（`isatty` 之外的另一条常见路径，例如 systemd 的 socket 激活、`sd_is_socket`）就判断错。现在 `fs/fd_stat_policy.zig` 给没有目录项的描述符一个统一的元数据：管道 `S_IFIFO|0600`，套接字（TCP/UDP/AF_UNIX/raw）`S_IFSOCK|0600`，控制台与 `/dev` 设备节点 `S_IFCHR`（可写时 0666，否则 0444），`/dev` 目录 `S_IFDIR` 且 nlink=2，eventfd/epoll/timerfd/inotify/pidfd 与 devfs 控制 fd 是匿名 inode：和 Linux 一样报告 `S_IFREG|0600`；`st_ino` 是“类型标签 + 资源下标”合成出的稳定号码（管道 3 与套接字 3 不同），`st_nlink` 至少为 1，`st_blksize` 为 4096。ext2/tmpfs/FAT32/只读卷仍用文件系统自己的元数据覆盖这些字段。`statx(AT_EMPTY_PATH)` 描述描述符本身时共用同一套推导（`dir_ops.descriptorKind/descriptorIno`），所以与 `fstat` 一致（此前 TCP socket 之外的 `statx` 一律是 `S_IFREG|0644`）。
- **ext2 目录描述符跟随 inode（hello147）**：此前 ext2 目录 fd 作 `dirfd`/`fchdir` 时用的是**打开它时的路径**（`open_file_paths`），目录之后被改名或移走，`openat(dirfd, "f")` 找不到文件、`fchdir` 去了旧路径（Linux 跟随 inode）；这是 hello121 起记录的已知限制。现在 `ext2.dirPathOfInode` 从 inode 重建路径：读该目录的 `..` 得到父目录，再在父目录里找指向该 inode 的条目名，逐级上溯到根（inode 2），用 `ext2_dirpath.zig` 的纯函数拼接（深度上限 32、路径上限 255、遇到环或 `..` 自指/为 0 视为损坏）。目录已被删除（`links_count==0`）时返回 null，回退到打开时记录的路径，所以对已删除目录的创建仍然失败。`at_path.dirFdBase` 因此对改名、移动都正确。顺带修了一个从第一版 ext2 起就存在的缺陷：`open("/", O_RDONLY)` 返回 EISDIR（`walkPathFollow` 把“路径没有离开起始目录”一律当作错误），现在返回目录描述符，写方式打开仍由 `namespace_policy.openExisting` 给 EISDIR，`read` 目录也是 EISDIR。
- **/proc/irqwindow：窗口内最长中断（hello108 的诊断）**：`/proc/irqtime` 里的 `max_us`/`max_vec`/`max_at_ms` 是自开机以来的最大值，hello108 曾拿它当“测量窗口内”的读数，所以每个窗口都显示同一个 89 ms（开机早期缺页路径关中断读盘）——无法判断窗口里真正长的中断是什么。`irq_time_policy.Acc` 新增一个窗口最大值（`win_cycles/win_vector/win_start_tsc`），`/proc/irqwindow` 每次读取返回每个 CPU 自上次读取以来最长的一次中断（`win_max_us`、`win_vec`、`win_at_ms`）并开始新窗口；这个文件是“读即消费”的，所以 `procfs.consumesOnRead` 让 `vfs.read` 只在描述符的第一次读（偏移 0）生成内容，EOF 那次读不会吞掉下一个窗口。`hello108` 在每个测量窗口前后读它，并打印 `cpu0_win_irq_max_us` 与 `vec`，下次再出现 RT 间隙超标时能直接看到是哪个向量造成的。
- **sendmmsg / recvmmsg（hello146）**：此前两者只是 TCP 路径的包装——`vlen` 超过 16 直接 EINVAL（Linux 是截断到上限），`flags` 只接受 0、`recvmmsg` 的超时指针必须是 NULL，`msg_len` 只在 `recvmmsg` 里写、`sendmmsg` 不写，`MSG_WAITFORONE`/`MSG_DONTWAIT` 不认识，且因为底层的 `sendmsg`/`recvmsg` 之前只支持 TCP，UDP 与 AF_UNIX 一律 ENOTSOCK。现在规则集中在 `message_batch_policy.zig`：`vlen` 截断到 16；接收标志允许 `MSG_PEEK/MSG_TRUNC/MSG_DONTWAIT/MSG_WAITFORONE/MSG_CMSG_CLOEXEC`，发送标志允许 `MSG_DONTWAIT/MSG_NOSIGNAL`，其余 EINVAL；`MSG_WAITFORONE` 让第一条之后的消息变成非阻塞（该标志本身不下传）；`recvmmsg` 的 `struct timespec` 超时按毫秒向上取整，批次在两条消息之间到期就结束，`tv_nsec` 越界或负数 EINVAL；批次中途出错时返回已成功的条数，没有成功过才返回错误；`sendmmsg` 也写每条消息的 `msg_len`。每条消息先整体预检（头、iovec、缓冲区可读/可写），预检失败不会留下半个批次。因为 `sendmsg`/`recvmsg` 已经覆盖 TCP/UDP/AF_UNIX（hello142/145），批量调用对这三类套接字都可用。`hello81` 里“`vlen=17` 返回 EINVAL”的旧断言按新语义改为“被截断后遇到 NULL 向量得到 EFAULT”。
- **UDP sendmsg/recvmsg 与 AF_UNIX 接收超时（hello145）**：此前 `sendmsg`/`recvmsg` 只支持 TCP 与 AF_UNIX，UDP 返回 ENOTSOCK（`recvfrom`/`sendto` 能用，说明只是缺这一层），AF_UNIX 的 `SO_RCVTIMEO`（hello143 起可设置）不生效。现在 UDP 的 `sendmsg` 把 iovec 聚成一个数据报，目的地取 `msg_name`（没有则用 `connect` 过的对端，否则 `EDESTADDRREQ`）；`recvmsg` 与 `recvfrom` 共用等待逻辑（阻塞/EAGAIN/`SO_RCVTIMEO`），把数据报分散到 iovec，写 `msg_name`（IPv4 `sockaddr_in` 的 `sa_family` 是小端 `02 00`、端口大端）和 `msg_namelen`，`msg_controllen` 写 0，数据报比缓冲区长时 `msg_flags` 带 `MSG_TRUNC`，调用带 `MSG_TRUNC` 时返回数据报的完整长度。AF_UNIX 的阻塞接收改为：没有超时则照旧挂在读等待栈上；有 `SO_RCVTIMEO` 则同样挂起，同时把截止时间交给睡眠定时器，到期醒来后返回 EAGAIN。
- **UDP 接收：阻塞、超时、非阻塞（hello144）**：此前 UDP `recvfrom` 在队列为空时一律立即返回 0——数据报套接字没有 EOF，所以调用方分不清“暂时没数据”和“对端关闭”，阻塞套接字也不会等待，`O_NONBLOCK`/`MSG_DONTWAIT` 得不到 EAGAIN，`SO_RCVTIMEO`（hello143 起 UDP 才能设置）完全不生效，同一台机器上另一个进程发来的回环数据报要靠调用方自己 `netpoll`。现在 `net/udp_recv_policy.zig` 决定一次接收：队列有数据 → 交付；没有且（`O_NONBLOCK`/`MSG_DONTWAIT` 或 `SO_RCVTIMEO` 已到）→ EAGAIN；否则等待。等待是 5 ms 一片的 `sleepUntil`（让出 CPU，信号可打断 → EINTR），每片之前会 `lo.drain()` 把回环队列里的数据报投递给本机的套接字，所以另一个进程在 127/8 上发来的数据报不需要显式 `net_poll` 也能唤醒阻塞的接收者。`hello50` 里“队列已空后立即 recv 返回 0”的旧期望改为非阻塞 recv 返回 EAGAIN。
- **socket 选项覆盖所有套接字类型（hello143）**：此前 `setsockopt`/`getsockopt` 只认 TCP，UDP、AF_UNIX、raw 套接字一律 ENOTSOCK，已关闭的 fd 也是 ENOTSOCK 而不是 EBADF，并且缺少 `SO_TYPE`/`SO_DOMAIN`/`SO_PROTOCOL`/`SO_ACCEPTCONN`/`SO_PEERCRED`/`SO_REUSEPORT`/`SO_BROADCAST`/`SO_DEBUG`（很多库在 `socket()` 后立刻 `getsockopt(SO_TYPE)` 或设置 `SO_REUSEPORT`）。现在 `net/sockopt_policy.zig` 定义所有 SOL_SOCKET 选项的语义：`Stored`（布尔位、`SO_RCVBUF/SO_SNDBUF`、`SO_RCVTIMEO/SO_SNDTIMEO`、`SO_LINGER`）与只读事实 `Facts`（类型/协议族/协议、是否在监听、`SO_ERROR`、对端凭据）。缓冲区大小按 Linux 的规则：请求值上限 `rmem_max`、乘 2、不低于最小值；只读选项用 `setsockopt` 是 ENOPROTOOPT；`optlen` 太短 EINVAL，`optval` 为 NULL EFAULT，未知选项/协议层 ENOPROTOOPT；`getsockopt` 把实际长度写回 `optlen`（缓冲区较小时被截断）。存放位置：TCP 沿用 TCB 的 `SocketOptions`（新增 `extra_flags`），UDP 随端口槽（`udp.port_opts`），AF_UNIX 在套接字里（`opts`，并在创建/accept/socketpair 时记录创建者的 pid/euid/egid，`SO_PEERCRED` 取对端的），raw 套接字只接受不保存。
- **SCM_RIGHTS 传递文件描述符（hello142）**：此前 `sendmsg`/`recvmsg` 只支持 TCP，AF_UNIX 套接字得到 ENOTSOCK，没有任何传递描述符的办法（`msg_control` 被完全忽略）。现在 AF_UNIX 的 `sendmsg` 收集 iovec 并解析 `SCM_RIGHTS`（`net/scm_policy.zig`：最多 8 个描述符，类型/层级/长度不对返回 EINVAL，描述符关闭或为 -1 返回 EBADF，没有数据字节则 EINVAL）。每个描述符用 `vfs.snapshotForPassing` 复制一份并**各自持有一次引用**（管道/文件/套接字/eventfd/epoll/timerfd/tmpfs 等；共享偏移槽也 +1，所以接收端与发送端共享文件偏移），整组挂到对端套接字的“在途集合池”（`unix_socket.rights_pool`，8 组）上，位置是消息首字节在流中的序号 `rx_pos`。`recvmsg` 的一次读取不会跨越集合边界（`scm_policy.readPlan`）：前面有普通数据时先只返回这些数据，轮到携带集合的字节时才把整组描述符 `vfs.installPassed` 进接收方的描述符表，写出 `SCM_RIGHTS` 控制消息（`msg_controllen` = CMSG_SPACE，`MSG_CMSG_CLOEXEC` 置 `FD_CLOEXEC`）；控制缓冲区放不下时只装得下的那部分，其余释放并置 `MSG_CTRUNC`，没有控制缓冲区时整组释放并置 `MSG_CTRUNC`，普通 `read`/`recv` 经过带集合的字节时静默释放。接收端套接字关闭时它的在途集合被标记为僵尸并在锁外释放（释放描述符可能再次关闭套接字，所以不能在 `unix_lock` 内做）。
- **ioctl 请求（hello141）**：此前 `ioctl` 对任何描述符都回答终端请求（`TCGETS`/`TIOCGWINSZ`/`TIOCGPGRP` 在管道、文件、套接字、`/dev/null` 上都返回成功），所以 libc 的 `isatty()` 永远为真，程序会在非终端上输出转义序列或进入行缓冲；`FIONREAD` 对 AF_UNIX 套接字和普通文件恒为 0；`FIOCLEX`/`FIONCLEX` 不存在（ENOTTY），而 `fd` 为已关闭描述符的请求要看请求种类才可能是 EBADF。现在 `fs/ioctl_policy.zig` 把请求分类：终端请求（`TCGETS/TCSETS(W/F)/TIOCGPGRP/TIOCSPGRP/TIOCGWINSZ/TIOCSWINSZ`）只对终端成功——stdio 的 `special` 描述符与 `/dev/tty`——其余一律 ENOTTY；已关闭的 fd 先报 EBADF；`FIONREAD` 对 AF_UNIX 返回流的排队字节数或下一个数据报的长度，对普通文件返回偏移之后剩余的字节数（先同步共享偏移），`FIOCLEX`/`FIONCLEX` 置位/清除 `FD_CLOEXEC`。
- **ppoll / pselect6（原生 #493 / #494，hello140）**：此前两者都是 ENOSYS，使用信号掩码版本的程序（现代 libc 的 `poll`/`select` 默认就走它们）无法工作。现在 `ppoll(fds, nfds, tmo_p, sigmask, sigsetsize)` 与 `pselect6(nfds, r, w, e, timespec, {sigmask, size})` 复用 `poll`/`select` 的核心（`pollWait`/`selectWait`），区别只有两点：超时是 `struct timespec`（NULL=一直等，`tv_nsec` 越界或负数 EINVAL，亚毫秒向上取整，`poll_policy.timespecWait`），以及等待期间安装临时信号掩码——`sigsetsize` 必须为 8（EINVAL），SIGKILL/SIGSTOP 去除；被信号打断（EINTR）时旧掩码在 handler 跑完之后才恢复（沿用 `saved_sigmask`/`restore_sigmask_pending` 机制，与 `epoll_pwait` 一致），否则调用返回时立即恢复。没有掩码参数时被阻塞的信号不会打断等待。
- **poll/select 就绪与超时（hello139）**：此前 `poll`/`select` 自带一份简化的就绪判断（只认 TCP/pipe/eventfd/timerfd，其余一律“永远就绪”，所以 AF_UNIX 套接字永远 `POLLIN`），超时用 `pause` 忙等（`poll(-1)` 被当成 30 秒上限、`timeout` 当作无符号数），`poll(NULL,0,ms)` 是 EINVAL 而不是睡眠，关闭的 fd 在 `select` 里被静默跳过，已排空且写端关闭的管道在 `select` 里不算可读（EOF 应可读）。现在两者共用 `epoll.descriptorEvents`（与 epoll 同一套按类型的就绪函数，TCP 保留自己的规则），等待改为 5 ms 一片的 `sleepUntil`（让出 CPU，信号可打断 → EINTR），规则集中在 `fs/poll_policy.zig`：poll 的 timeout 取低 32 位按有符号数解释（负数=一直等，0=只查一次），`nfds` 上限为 `RLIMIT_NOFILE`，`revents` 总是带上 `POLLERR/POLLHUP/POLLNVAL`、只带请求的数据事件，负 fd 清零 `revents`；select 的 timeval 非法（负数、`usec>=1e6`）为 EINVAL，亚毫秒向上取整，`nfds` 超出表大小时按表大小截断（Linux 行为），集合里出现已关闭的 fd 为 EBADF，到期时清空集合。
- **uname 与主机名（hello138）**：`uname` 此前返回写死的 `moqios`/空域名，不反映 `sethostname`/`setdomainname`（两者各自存了一份只有 `gethostname`/`getdomainname` 看得到的全局变量），坏指针返回 `-1`（EPERM）而不是 EFAULT。现在主机名与域名集中在 `proc/uts.zig`（`hostname`/`domainname` + 纯函数 `unameBytes`，每个字段 65 字节，名字最长 64），`uname` 从同一份状态生成 390 字节镜像，`uname(NULL)`/内核指针返回 EFAULT；允许设置空主机名（`ensureInit` 只在首次使用时填默认名，不会把显式设置的空名覆盖回默认值）。`getrlimit/setrlimit/prlimit64`（含 `RLIM_INFINITY`、`cur>max`、硬限制提升的 EPERM、坏指针、未知资源）与 `sysinfo`（`freeram<=totalram`、`procs`、`mem_unit`、uptime 单调）经探测未发现偏差。
- **siginfo_t 与 ucontext_t（hello137）**：此前 SA_SIGINFO 处理函数收到的 `rsi`/`rdx` 是垃圾值（信号帧里只有自定义的寄存器快照，`rt_sigqueueinfo` 丢弃 `uinfo`，`rt_sigtimedwait` 忽略 `info`），handler 无法获知发送者、`sigqueue` 的值、故障地址或子进程状态，也无法通过修改上下文改变恢复点。现在 `siginfo_policy.zig` 定义 Linux x86-64 的 128 字节 siginfo_t 与 432 字节 ucontext_t（`gregs`@40、`sigmask`@296），信号帧改为 `{signum, fpu, info, uc}`：handler 以 `rdi=signo, rsi=&info, rdx=&uc` 进入，sigreturn 从 `uc.gregs`/`uc.sigmask` 恢复，所以 handler 修改 `REG_RIP` 等即可改变恢复点。发送端在置 pending 位前记录 `Task.sig_info[signo-1]`：`kill` → `SI_USER`(pid,uid)，`tkill` → `SI_TKILL`，`rt_sigqueueinfo` → 用户给定的 code/pid/uid/value（对他人只允许负 code 且不能是 `SI_TKILL`，否则 EPERM），SIGCHLD → `CLD_EXITED`/`CLD_KILLED` + pid + 退出状态/信号，SIGSEGV/SIGBUS → `SEGV_MAPERR`/`SEGV_ACCERR`/`BUS_ADRERR` + 故障地址（同时写入 `uc.gregs[REG_CR2]`）；`rt_sigtimedwait` 把取走的信号信息写入 `info`。同号重复发送合并，只保留最后一次的 info。
- **实时信号 32–64（hello136）**：此前内核只有信号 1–31：`sigaction`/`kill`/`tkill`/`rt_sigtimedwait`/POSIX 定时器与消息队列通知都把上限卡在 31，`pending_signals` 是 `u32`，处理函数/`sa_mask`/`sa_flags` 数组各 31 项，pthread 与 `SIGRTMIN` 家族无法使用（`sigaction(34)` 得到 EINVAL）。现在 `signal.MAX_SIGNAL = 64`，`pending_signals` 为 `u64`，三个数组各 64 项（fork/clone 复制 64 项），`dequeueSignal` 等用 `u6` 位号取最低位，`sigpending` 原子读取完整 64 位，`rt_sigtimedwait` 使用完整 64 位集合；`pidfd_send_signal` 与 mq/timer 通知同样接受 1–64。实时信号默认动作为终止。实时信号排队（hello274）：每次发送是一个实例，带自己的 siginfo，存在 `Task.rt_queue`（`proc/sigqueue_policy.zig`，32 项，按到达顺序）；`dequeueSignal`/`rt_sigtimedwait` 每次取一个实例，同一信号还有实例时待处理位保持；队列满或该 uid 已排队的实例达到 `RLIMIT_SIGPENDING` 软上限时 `rt_sigqueueinfo` 返回 `EAGAIN`，`kill` 仍置位只丢 siginfo（hello288 Q）；装 `SIG_IGN` 丢弃全部实例；`sigreturn` 之后立即投递下一个待处理信号。标准信号仍合并为一次。
- **tkill 参数（hello135）**：`tkill(tid, sig)` 此前把 `sig==0` 当作 EINVAL（Linux 里 0 是存在性/权限探测），并把 `tid` 当 `u32`，负数 tid 被截成巨大的正数而得到 ESRCH。现在 tid 按有符号 `pid_t` 解析（`proc_id_policy.tkillTargetTid`：≤0 或 >0x7fffffff → EINVAL），顺序为 EINVAL → ESRCH → EPERM → `sig==0` 返回 0 → 投递。sigaction/kill/sigprocmask/sigpending 等其余信号调用经 hello135 探测未发现偏差。
- **AF_UNIX 与 socket() 参数（hello134）**：(1) `socket()` 此前把 `type` 整个当作类型，`SOCK_STREAM|SOCK_CLOEXEC|SOCK_NONBLOCK`（现代 libc 的默认写法）得到 EINVAL，且无视 `protocol`、未知族返回 `-38`。现在
  `namespace_policy.socketArgs` 拆出类型与 `SOCK_CLOEXEC`/`SOCK_NONBLOCK`（作用在新描述符上），未知族 `EAFNOSUPPORT`，未知类型或未知标志位 `EINVAL`，AF_UNIX 的非零 protocol、AF_INET 的 TCP/UDP 与类型不符的 protocol
  `EPROTONOSUPPORT`。(2) **AF_UNIX 流套接字的阻塞语义**：`read/recv/accept` 在没有数据/连接时此前直接返回 EAGAIN（`unixRecv/unixAccept` 只有非阻塞路径，等待队列有消费者却没有生产者）。新增
  `unixRecvBlocking/unixAcceptBlocking`：在对应等待栈上阻塞，被 `send/connect/close` 唤醒后重检，`O_NONBLOCK` 或 `MSG_DONTWAIT` 才返回 EAGAIN，信号返回 EINTR；对端已关闭或从未连接是 EOF 而不是等待。(3) **connect 之后、accept 之前**
  发送的数据此前被 ENOTCONN 拒绝：现在暂存在客户端的 `pending` 缓冲（1 KiB），`accept` 时移进服务端新套接字的环形缓冲，客户端此时阻塞的 read 也被唤醒；这种“排队中”的客户端读会等待而不是 EOF。(4) 对端关闭之后的 send 是 EPIPE，
  从未连接过的是 ENOTCONN（`was_connected`）。(5) 坏 fd（空槽）给 `listen/shutdown/accept/bind` 是 EBADF，非套接字是 ENOTSOCK（此前一律 ENOTSOCK）；`shutdown` 现在支持 AF_UNIX（`SHUT_WR` 让对端读到 EOF，未连接 ENOTCONN）。
  数据报套接字的消息边界、`EADDRINUSE`、`listen` 前未 `bind` 的 EINVAL、重复 `bind` 的 EINVAL、非阻塞 accept 的 EAGAIN 等已核对无误。限制：`socketpair` 仍只支持 `SOCK_STREAM`；`SHUT_WR` 目前只唤醒对端，没有给流打 EOF 标记。
- **进程生命周期：wait 选项、选择规则、初始进程组（hello133）**：(1) `wait4`/`waitpid` 的 options 只允许定义过的位（`WNOHANG`、`WUNTRACED`、`WCONTINUED`、`__WNOTHREAD`、`__WALL`、`__WCLONE`），其余 EINVAL
  （此前任何值都被接受，`wait4(pid, 0, 0x4, 0)` 会被当成阻塞等待，进程在那里无限挂住）。(2) **子进程选择规则统一**（`proc_id_policy.waitMatches`）：`pid > 0` 指定的子进程、`-1` 任意子进程、`0` 与调用者同组的子进程、`< -1` 属于组 `-pid` 的子进程；
  扫描（`waitpidScanLocked`）与“有没有可能等到”的判断（`task.hasMatchingChild`）用同一条规则。此前 `pid == 0` 和 `pid < -1` 被当成“任意子进程”，而“有子进程”只看有没有任何子进程，
  所以等一个不存在的 pid 会阻塞而不是 ECHILD。(3) **spawn 出的程序的进程组与会话**：`createUserTask` 此前把 `pgid`/`sid` 留成 0，`getpgid(0)` 返回 0（没有任何进程组可以是 0）。现在继承 spawn 它的父任务的组和会话（与 fork 一致；
  `setsid` 拒绝已是组长的进程，所以 init 启动的程序不能一开始就是组长），第一个没有父任务的任务才以自己的 tid 为组长。已核对无误：退出码低 8 位、`exit(137)` 与 SIGKILL 的区分、`WTERMSIG`、`WNOHANG`、
  对已回收子进程再等是 ECHILD、`waitpid(-1)` 先返回先退出者、`getppid`、`setsid` 的组长/会话长语义、`setpgid` 的 ESRCH/EINVAL。
- **时钟 id 与睡眠（hello132）**：`clock_gettime`/`clock_getres`/`clock_nanosleep` 此前只认 `CLOCK_REALTIME`(0) 与 `CLOCK_MONOTONIC`(1)，其余全是 EINVAL，而 glibc/musl/运行时普遍会读
  `CLOCK_MONOTONIC_RAW`、`CLOCK_BOOTTIME`、`CLOCK_*_COARSE` 与 CPU 时间时钟。现在 `proc/clock_ids.zig`（纯，host 测试）给出映射：`REALTIME` 与 `REALTIME_COARSE` 读墙钟（RTC 起点 + TSC），
  `MONOTONIC`、`MONOTONIC_RAW`、`MONOTONIC_COARSE`、`BOOTTIME` 读单调时钟（本内核不做时间校正也不挂起，所以彼此一致），`PROCESS_CPUTIME_ID`/`THREAD_CPUTIME_ID` 读调用任务的 CPU 时间
  （utime + stime + 当前时间片）；未知 id、负的动态时钟 id 是 EINVAL。`clock_getres`：COARSE 时钟报 1 ms，其余 1 ns。`clock_nanosleep` 只接受 `sleepable` 的时钟（墙钟族、单调族），
  CPU 时间时钟 EINVAL。`gettimeofday(NULL, tz)` 此前是 EFAULT，现在成功（没有要写的东西）。`tz` 指针（第二个参数）原来被完全忽略；现在与 Linux 一致：坏的 `tz`（含 `tv` 为 NULL 时）是 EFAULT，成功时写 `{tz_minuteswest=0, tz_dsttime=0}`（内核不保存时区，即 UTC），两个指针都先做范围检查再写，hello197 覆盖。限制：进程 CPU 时钟只统计调用任务，不汇总同进程其它线程。
- **mprotect / mremap 的参数与错误码（hello131）**：`mprotect(addr, 0, prot)` 此前是 EINVAL，Linux 里是成功的空操作（先检查对齐，再看长度，最后才检查 `prot` 位；`mprotect_policy.early`）。
  范围里有未映射的洞时，`mprotect` 应返回 ENOMEM（已有页仍按请求修改，所以在提交之后才报告；`mprotect_policy.coverageErrno`），原先对不存在的页直接静默跳过、返回 0。
  `mremap` 的源地址对齐但根本没有映射时是 EFAULT（`remapSourceErrno`），原先是 EINVAL；不是区域起点的地址仍是 EINVAL。`mmap` 的参数校验（长度 0、`MAP_SHARED|MAP_PRIVATE` 同时/都没有、未知 `PROT` 位、
  `MAP_FIXED` 未对齐、坏 fd、过大长度、文件偏移未对齐、不可映射设备）、`munmap` 的对齐与长度 0、对已卸载范围再次 `munmap`、`brk` 增长/收缩/拒绝过低地址已核对无误。
  `hello74` 里“mprotect 长度 0 是 EINVAL”的断言记录的是旧行为，改为“成功的空操作”。
- **fcntl / dup / pipe 的描述符语义（hello130）**：(1) `dup2`/`dup3` 的副本此前整个拷贝源描述符，把源的 `FD_CLOEXEC` 也带过去（`dup3(.., 0)` 本应清零）；现在副本的描述符标志恰好是调用者要求的（`namespace_policy.dupFdFlags`，
  `dup`/`dup2`/`F_DUPFD` 为 0，`dup3(O_CLOEXEC)`/`F_DUPFD_CLOEXEC` 为 `FD_CLOEXEC`）。(2) 源描述符未打开时 `dup*` 返回 EBADF（原先裸 `-1`，`rlimit.Policy.dupExplicitErrno`）。(3) **文件状态标志属于打开文件描述**：
  `O_NONBLOCK`/`O_APPEND` 与偏移一起存在共享池的同一个槽里（`shared_offset.Pool.flags/setFlags`），`F_SETFL` 经 `vfs.setStatusFlags` 写入共享值、`F_GETFL` 经 `vfs.statusFlagsOf` 读，所以通过 dup 修改对原描述符可见；
  读写路径在 `syncOffsetIn` 里取到最新标志。(4) 管道两端用 `pipeStatusFlags` 报告访问模式（读端 `O_RDONLY`，写端 `O_WRONLY`），`F_GETFL` 不再对两端都返回 0。管道语义（空管道非阻塞读 EAGAIN、写端全关后读 EOF、读端全关后写 EPIPE、
  满管道非阻塞写 EAGAIN、`pipe2` 标志）已核对无误。
- **ext2 读写一致性与偏移语义（hello129）**：ext2 的写先暂存在 writeback 缓冲里，读只在**读起点恰好等于某个暂存区起点**时才能命中；`pread` 读刚写入的数据（起点落在暂存区中间）
  于是读到旧的磁盘内容或 0，洞里的字节也不是 0。现在读路径统一走 `FdTable.ext2ReadMerged`：先读磁盘（缓冲预清零，洞读 0），再用 `writeback.overlayStaged` 把所有相交的暂存区叠上去
  （纯算术在 `fs/writeback_overlap.zig`：起点在区内、区前伸入、越过区尾、完全不相交、不回绕），`read` 与 `pread` 共用。`pread`/`pwrite` 的偏移是有符号 off_t，最高位为 1 是 EINVAL
  （`namespace_policy.positionedOffsetErrno`）。`truncate`/`ftruncate` 缩小后，保留的最后一块里超出新大小的字节现在会清零（`namespace_policy.truncateTail` + `ext2.zeroTruncatedTail`），
  否则之后再扩大会把已“删除”的数据读回来。`lseek`（SEEK_SET/CUR/END、负位置/非法 whence EINVAL、坏 fd EBADF）、`O_APPEND`、`O_TRUNC`、只读描述符 `ftruncate` 失败在 ext2 与 tmpfs 上都已核对无误。
  **dup/fork 共享打开文件描述的偏移（已补）**：`dup`、`dup2/3`、`fcntl(F_DUPFD)` 与 `fork`/`clone`（复制 fd 表）之后，两端读写同一个位置。实现为 `fs/shared_offset.zig` 的带引用计数的偏移池（512 项，
  池满时退回各自私有偏移）：描述符第一次被复制时，它的 `offset` 被“升格”进池，原件与副本都带上同一个 `offset_slot`；`read`/`write`/`lseek`/`getdents` 在操作前后用 `syncOffsetIn/Out`
  与池同步，`close` 释放持有；`aio`、`splice`、`copy_file_range` 通过 `offsetOf/setOffsetOf` 读写。适用的描述符种类：ramdisk、FAT32、ext2、tmpfs、只读卷、procfs 文件；管道/套接字没有偏移。
  同时 `ftruncate` 不再把文件偏移截到新长度内（POSIX 不改偏移）。限制：同一个描述被两个进程在两个 CPU 上同时读写时，读-改-写不是原子的（与本内核其它描述符状态一致）。
- **read/write/rename/readlink 与超长路径的错误码（hello128）**：`write()`/`pwrite()` 对不可写描述符（含只读打开的目录）现在是 EBADF（原先裸 `-1`=EPERM），`FdTable.write`
  入口统一经 `namespace_policy.writeGate`；`read()` 目录是 EISDIR（ext2 之前会返回 8 字节目录内容，tmpfs 返回 0）；`readlink` 对存在但不是符号链接的名字是 EINVAL
  （`ext2.readlinkPath` 区分 `not_symlink`/`missing`，tmpfs 存在的条目也是 EINVAL）；`rename` 源不存在是 ENOENT（原先被改写成 EXDEV，现在只有 FAT32 根下的名字才保留 EXDEV），
  tmpfs 的 `rename` 路径经过文件是 ENOTDIR；路径超过 255 字节时 open/mkdir/unlink/rmdir/statx/readlink/chdir 返回 ENAMETOOLONG，而不是截断后对截断的名字操作
  （`namespace_policy.pathCopyErrno` 判断“拷满窗口且没有结尾 NUL”，`pathFromCopy` 返回名字切片或 errno）。**所有**读用户路径的调用点都经过它：syscall_entry.zig 里统一的 `userPath`/`userPathResult`
  （chmod/chown/lchown/fchmodat(2)/link/symlink/symlinkat/linkat/fchownat/rename/renameat2/truncate/access/utimensat/xattr-at/chroot/swapon/swapoff）、mount/umount2 的目标与来源（窗口 127/63/15）、
  inotify_add_watch、execve。仍直接调用的只有 `PR_SET_NAME`（comm 就是 15 字节，截断是规定行为）、memfd 名字（随后显式检查长度）与 `userPathResult` 本身；源码守卫测试数着这个清单。
  `hello41` 原先断言 `copy_file_range` 写入只读目标得 `-1`，Linux 的答案是 EBADF，断言随之更正。
- **命名空间调用在 ext2/tmpfs 上返回 Linux 错误码（hello127）**：此前 unlink、rmdir、mkdir、open 的大多数失败都是裸 `-1`（用户态看到 EPERM）。
  纯策略 `fs/namespace_policy.zig` 给出规则，两个文件系统共用：`unlink` 目录 EISDIR；`rmdir` 非目录 ENOTDIR、非空 ENOTEMPTY；`mkdir` 已存在
  EEXIST（原先对已存在的目录“幂等成功”，对文件则创建失败为 EPERM）；缺失 ENOENT；`open`：`O_CREAT|O_EXCL` 已存在 EEXIST，`O_DIRECTORY` 对文件 ENOTDIR，
  `O_NOFOLLOW` 遇符号链接 ELOOP（与 `O_DIRECTORY` 同用则 ENOTDIR），目录以写/`O_TRUNC` 打开 EISDIR，路径中间分量是文件 ENOTDIR（`ParentError.NotDir`、
  `walkPathFollow`），槽位用尽 ENFILE，分配失败 ENOSPC/ENOMEM/EIO。tmpfs 的 `tmpfsRemove(.file/.dir)` 区分 unlink 与 rmdir；`resolveErrno` 区分 ENOENT/ENOTDIR/ENAMETOOLONG。
  `unlinkName` 只在 ext2 报“没有这个名字”时才继续找 FAT32。顺带修复：vfs 把 `O_DIRECTORY` 写成 `0o100000`（那是 `O_LARGEFILE`），正确值 `0x10000`；
  ramdisk 文件数上限 128→256（`ramdisk.MAX_FILES` 与 `tools/mkramdisk.sh` 同步，`tools/tests/test_mkramdisk.sh` 守卫一致性与余量，之前第 129 个测试程序根本打不进镜像）。
  行为变化：`hello23` 的 `mkdir("testdir")` 在镜像已有该目录时现在是 EEXIST，该测试的前置步骤随之改为接受 EEXIST。
- **access / faccessat / faccessat2 在 ext2 与 tmpfs 上判定权限位（hello126）**：此前只有只读卷按文件真实 mode 判定，ext2/tmpfs 只回答“能否打开”，
  `X_OK` 对 0640 文件也成功、非法 mode 位不报错。现在 `fs/access_policy.zig` 统一规则：`F_OK` 只要存在；R/W/X 按属主/属组/其他类判定（补充组参与）；
  `CAP_DAC_OVERRIDE` 放行 R/W，但 X 仍要求至少一个执行位（目录除外）；mode 含 R/W/X 之外的位 EINVAL。**身份**：`access`/`faccessat` 按**真实** uid/gid 判定，
  而特权来自有效身份，所以真实≠有效时丢掉 DAC 特权；`faccessat2(AT_EACCESS)` 改用有效 id。flags：`AT_SYMLINK_NOFOLLOW`、`AT_EACCESS`、`AT_EMPTY_PATH`
  （空名字检查 dirfd 本身），其它位 EINVAL。ext2 取 `ext2.statPath`，tmpfs 取 `tmpfsMetadataByPath`；其它文件系统（FAT32、ramdisk、devfs）仍只判断存在。
  顺带：分发层传入 faccessat2 的 flags（原先 flags 被丢弃）。
- **statx 的字段与标志（hello125）**：此前 `statx` 的 mask 声称 `STATX_BASIC_STATS`，却不写 blocks 和任何时间戳（全是 0），还忽略 flags 与 mask。
  现在 `stat_info.packStatx` 按 struct statx 偏移精确打包，mask 只包含真正填写的字段：ext2、只读卷报告 atime/mtime/ctime 与 blocks，FAT32 只有一个写入时间
  （三者同值），tmpfs 没有时间戳和块数所以 mask 不含它们、字节为 0（不伪造 1970 年）。flags：`AT_EMPTY_PATH`（空名字描述 dirfd 本身，含目录 fd；不带该标志的空名字 ENOENT，坏 fd EBADF）、
  `AT_SYMLINK_NOFOLLOW`（ext2 上描述符号链接 inode 本身，`ext2.statPathNoFollow`；默认跟随）、`AT_NO_AUTOMOUNT` 与同步类型位接受；未知 flags 或保留的 mask 最高位 EINVAL。
  限制：NOFOLLOW 对 /tmp、/dev、/proc 与只读卷路径按默认方式处理（这些文件系统里没有可描述的符号链接）。
- **linkat / symlinkat / fchownat（原生 #490 / #491 / #492，hello124）**：补上 dirfd 版本，路径一律经 `at_path.resolve`（cwd 与任意目录 fd）。
  纯策略在 `fs/at_flags_policy.zig`：`linkat` 只认 `AT_SYMLINK_FOLLOW`（未带时链接 symlink 本身，`ext2.createHardlinkMode(follow=false)`；
  传统 `link` 仍跟随），`AT_EMPTY_PATH` 需要 CAP_DAC_READ_SEARCH（无人持有）所以空名字是 ENOENT，其它位 EINVAL；跨 `/tmp` 边界 EXDEV，
  tmpfs 内部没有硬链接/符号链接（EPERM）；只读卷 EROFS。`symlinkat` 只解析链接路径，目标原样保存。`fchownat` 认 `AT_SYMLINK_NOFOLLOW`
  与 `AT_EMPTY_PATH`（路径为 NULL 即 fchown(dirfd)，ext2/tmpfs fd 均可），授权沿用 chown 的 `mayChownIn`。顺带修复：硬链接目录项的
  file_type 现在用 `direntType`（链接一个 symlink 时记为 7，而不是 1）。
- **utimensat / futimens（原生 #489，hello123）**：此前内核没有任何改时间戳的调用。`utimensat(dirfd, path, times, flags)`，
  `path == NULL` 即 futimens（dirfd 就是文件）；flags 只认 `AT_SYMLINK_NOFOLLOW`，其它 EINVAL。纯策略在 `fs/utimens_policy.zig`：
  `times == NULL` 两项都是现在；`UTIME_NOW` / `UTIME_OMIT`；`tv_nsec` 超界 EINVAL；显式时间必须落在磁盘的 32 位秒数内，
  否则 EOVERFLOW（不静默回绕）；两项都 OMIT 是成功的空操作。授权在 `ext2.setTimes` 里持 `fs_lock` 判定：显式时间需要属主或
  CAP_FOWNER（EPERM，只有写权限不够），仅“现在”还接受写权限（否则 EACCES）；设置后 ctime 记为现在，并同步所有指向该 inode 的打开槽。
  只有 ext2 保存时间戳：tmpfs/FAT32 路径返回 EPERM（文件无法记录），只读卷 EROFS。路径经 `at_path.resolve`，所以 cwd 与任意目录 fd 都可用。
- execve/execveat（hello122）：两者共用 `execve.prepareExecAt` → `prepareExecName`（此前 execveat 有一份复制的实现，
  漏掉了 `posix_mq.closeCloexecForTask`，带 O_CLOEXEC 的消息队列描述符会穿过 execveat 留下来）。名字经 `dirfd_name.resolve`
  按 cwd 或 dirfd 解析（任意文件系统的目录 fd；空闲 fd EBADF，非目录 ENOTDIR），再由 `proc/exec_policy.programName` 映射到
  ramdisk：程序只存在于平坦的 ramdisk，解析结果是根下的单段名（带不带前导斜杠）才可执行，更深的路径 ENOENT。
  失败返回 Linux 错误码而不是一律 EPERM：找不到 ENOENT、不是 ELF ENOEXEC、地址空间分配失败 ENOMEM、路径指针坏 EFAULT、
  execveat 未知 flags EINVAL；EPERM 只留给多线程 exec 和仍有 SysV SHM 附着的情况。`AT_EMPTY_PATH` 被接受但空名字
  得到 ENOENT（程序不能以描述符形式打开）。
- execve 初始栈与 spawn 路径一样携带 AT_PHDR/AT_PHNUM（PT_PHDR 段地址优先、`e_phoff` 回退）；栈 16 字节对齐 pad 位于 AT_NULL 之上——envp 终止符与第一个 auxv 项之间不允许出现零字（crt0 从 `envp+1` 开始扫描 auxv，先见零即终止，TLS 初始化随之失效）。行为级 host 测试锁定两种奇偶组合。（§6.51）
- moqi_libc `struct ksigaction` 为 Linux 字段序 {handler, flags, restorer, mask}（`_Static_assert` 锁定 mask@24/handler@0）：内核在完整结构可寻址时从 offset 24 读 `sa_mask` 应用，字段序错位曾使每次 `sigaction()` 把 restorer 当掩码写入并静默清零信号掩码。（§6.51）
- FAT32 open descriptors now hold per-slot references; unlink tombstones the directory entry but defers cluster reclamation and slot reuse until the final inherited/duplicated fd closes.
- FAT32 namespace lookup excludes `unlink_pending` slots; open+retain is atomic under the FAT32 lock, duplicate descriptors retain the shared slot, and directory rescan refuses to overwrite slots with live references.
- Pending FAT32 unlink is finalized by the last close through a separate reclaim path; writeback and complete FAT-chain I/O are required before the slot is recycled.
- Failed FAT32 reclaim remains explicitly pending and can be retried; failed FAT writes invalidate the FAT cache rather than publishing stale in-memory entries.
- FAT32 truncate/unlink flush dirty mmap page-cache data before staged writeback and cluster reclamation; reclaim rechecks fd references after dropped-lock I/O and rejects malformed FAT links.
- FAT32 truncate revalidates the file size/chain snapshot after unlocked flush I/O, uses widened size arithmetic, preserves old metadata on directory-update failure, and O_TRUNC propagates truncate failure instead of publishing a stale fd. (§6.51: the O_TRUNC failure path releases the retained slot via `closeFile` + `freeFd` — `close()` rejects a still-INITIALIZING slot and used to leak both the fd slot and the reference; the create path holds exactly one reference per fd.)
- FAT32 partial truncate zeros the retained cluster tail and detaches the live chain before freeing tail clusters, preventing retry after FAT I/O failure from traversing reclaimed clusters. (§6.51 reorder: the new size is published to memory and the on-disk directory entry BEFORE the EOC detach — a directory-update failure now rolls back to a fully consistent (size, chain) pair; a failure after the EOC write leaves the legal shrunk-size-with-slack-chain state and never rolls the size back.)
- FAT32 mmap-backed regions retain the open slot exactly like ext2 (create success, split, fork copy, and release balance the reference) — since slots ARE reclaimed once the last reference drops after unlink, an unreferenced mapping could otherwise fault on or write into a reused slot after close(fd)+unlink+create. (§6.51)
- The FAT32 driver only knows root-directory entries, so `open`/`create` refuse any name with a `/` after its first character (`fat32_util.isRootName`); such a path falls through to ext2. Before this, `testdir/x` was created as a FAT32 root entry literally named `testdir/x` (invalid on FAT) and the ext2 file of the same path was unreachable.
- ext2 `truncateFile` compares the new length with the largest of the slot's inode copy, the on-disk inode and the end of the data staged in the shared writeback buffer (same rule as FAT32), and re-reads the on-disk inode after flushing before deciding which blocks to free.
- FAT32 `zeroFileTail` handles sectors-per-cluster > 8 with per-sector RMW instead of whole-cluster I/O through the single 4 KiB bounce buffer, which overwrote adjacent physical pages. (§6.51)
- FAT32 utility parsers reject undersized/invalid BPB geometry, out-of-range MBR entries, invalid root/cluster arithmetic, and surrogate UTF-8; these contracts are exercised by host tests.
- FAT32 utility arithmetic returns checked/sentinel results for invalid cluster and FAT-entry offsets; LFN assembly requires reserved fields and exact forward sequence order.
- FAT32 driver callers reject invalid utility sentinels before sector I/O, including malformed FAT-chain clusters that would otherwise target MBR sector zero.
- mmap file-cache 命中使用 `getPageFramePinned`：在 `cache_lock` 内先增加映射引用，再把物理帧交给 page-table fault path，避免 eviction 在 lookup 与 `addRef` 之间释放/复用帧。
- page-cache insertion 在 `cache_lock` 内二次检查 `(inode_id, page_offset)`；并发 miss 不会创建 duplicate key，owned insertion 遇到已存在页面返回 null 并保留 incoming frame 由调用方释放。
- AArch64 paging facade 的 `isPageMapped` 现在读取真实 user mapping；AArch64/RISC-V `unmapPage` 返回被移除的物理帧，保持 shared paging API 的回收/验证 contract。
- `isPageMapped` 表示任意有效 present mapping（包括 kernel-only mapping），不应复用 user-accessible predicate。
- 非 x86 `isUserAccessible` 与 `isUserWritable` 分离：只读 user 页不能通过 kernel copy-to-user 写入检查；AArch64 timer service 由 trap 单一拥有者驱动，GIC 只负责 acknowledge/EOI。
- AArch64 `isUserWritable` 同时要求页表 AP 的 EL0 access bit（AP[1]）和 RW 状态（AP[2] 清零）；EL1-only RW（AP=00）不能作为用户写目标。
- RISC-V Sv39 在 map/unmap 修改 PTE 后执行本地 `sfence.vma`，避免旧 invalid/old translation 在重映射后继续生效。
- virtio-net advertised queue size 必须是 `1..256` 的 2 的幂（`virtio_queue_layout.sizeSupported`）；驱动拒绝超过静态存储的设备值，避免 DMA/ring 数组越界。QEMU 的 virtio-net-pci 默认就是 256（只允许 256..1024），所以旧的上限 128 让驱动在 QEMU 下永远初始化失败。
- AArch64/RISC-V `initIdentity` 失败是 fatal no-retry 契约：boot caller 立即 halt/shutdown，失败前分配的 root/中间页表帧有意不释放；不给早期启动失败路径添加表遍历 teardown。
- AArch64/RISC-V 尚未实现 2 MiB huge-page backend 时，`mapHugePage` 显式返回 `UnsupportedHugePage`，不会静默只映射一个 4 KiB base page。
- mmap fault 使用 `insertPageOwnedOrGet` 区分 cache full、刚插入和已存在 frame；duplicate 命中返回已在锁内 pin 的现有物理帧，incoming scratch frame 由 fault path 释放，不会误判为 cache full。
- full `syncAll`/`syncFile` 现在消费 page-cache `FlushResult.failed`；dirty MAP_SHARED 页面写回失败会向 `sync`/`fsync`/`msync` 传播为 `EIO`，失败页面保持 dirty 供后续重试。
- MAP_SHARED cache-full fault recovery also checks mapped flush failure and refuses the fault after freeing scratch; teardown callers intentionally discard the bool because unmap/exit/exec are irreversible, while later `sync*` calls remain the reportable EIO path.
- `splice(pipe_read, ..., file, ..., len, SPLICE_F_NONBLOCK)` 在空但仍有写端时以零进度返回 `-EAGAIN`；所有写端关闭时的空读是 EOF，返回 0。负错误保持不变，已有部分传输优先返回正的部分字节数；显式和隐式文件偏移都沿用原有更新规则。
- MoqIPC timeout 仍保持 30 秒语义，但 x86 由正常 BSP timed-wait tick 驱动过期扫描，不再依赖约 100ms slow-maintenance 扫描；authority lock、TaskPin 和 incarnation 校验保持不变。
- clone 的失败路径会撤销尚未发布的 child，并在 fd-table 分配失败时释放非 x86 内核栈；parent-TID copyout 失败发生在 runnable publication 之前。
- 其余 Linux clone 标志不再静默忽略；完整 ThreadGroup、clear-TID 和共享 FD 语义仍待实现。

### 2.5a pthread 子集（moqi_libc，v1，2026-08-14）✅

文件: `lib/moqi_libc/{include/pthread.h,src/pthread.c,src/crt0.c}`、`kernel/arch/x86_64/clone.zig`、`kernel/proc/{task,process_mgmt}.zig`

- **线程模型**：每线程独立 malloc 分配区，头部放 TCB（FS:0 直读），栈区其后；子线程 FS 由内核 `CLONE_SETTLS` 安装，主线程由 crt0 `arch_prctl(ARCH_SET_FS)` 安装。
- **API**：`pthread_create/join/exit/self`、`pthread_mutex_*`（glibc 风格 0/1/2 futex 状态机，无竞争零系统调用）、`pthread_once`（0/1/2 状态机）、`pthread_key_create/getspecific/setspecific`（32 keys）、每线程 `errno`（TCB 内）。
- **内核配合**：`Task.is_thread`（CLONE_THREAD 置位）；`getpid()` 对线程汇报 tgid（创建者 tid）；`waitpidScanLocked`/`hasChildrenLocked` 跳过线程（线程经 pthread_join 汇合而非 waitpid）。
- **性能设计**：mutex 快路径一次 `lock cmpxchg`；join 单次 futex 唤醒；TLS 一次安装后纯内存访问。
- **private futex 边界（2026-08）**：内核只支持带 `FUTEX_PRIVATE_FLAG` 的基本
  `FUTEX_WAIT`/`FUTEX_WAKE`。wait queue key 是 `(page_table_phys, uaddr)`，所以
  同页不同 word、不同进程相同虚拟地址都不会互相唤醒；pthread 的慢路径均使用
  private flag。PI 锁、PI requeue、bitset、普通 requeue 和 WAKE_OP 当前返回
  `ENOSYS`，不再成功 no-op 或修改用户 word；完整共享 futex/PI donation 需独立状态
  模型后再实现。`futex_waitv` 同样返回 `ENOSYS`，直到每个 vector entry 都可携带
  address-space-qualified private key；不再将第一个匹配项错误地入队到 bucket。
- **memory-lock（`mlock`/`munlock`/`mlockall`/`munlockall`/`MAP_LOCKED`，hello198、hello199）**：`mm/mlock.zig` + `mm/mlock_policy.zig`。每个 `Mm` 有一张最多 24 段的锁定页表（`Mm.locks`，页号区间，`vm_lock` 保护；exec 与 fork 子进程从空表开始，和 Linux 一样不继承；CLONE_VM 线程共享）。检查顺序对照真实 Linux：RLIMIT_MEMLOCK 为 0 且没有 `CAP_IPC_LOCK` 时先 `EPERM`（长度 0 也是），然后范围/映射（含 `PROT_NONE` 页）`ENOMEM`，然后配额（已锁页 + 新增页 > 限额按页数向下取整）`ENOMEM`；已锁页不重复计费；非对齐的零长度 `mlock(p+100, 0)` 会锁住起始页。`munlock` 不需要权限，解锁没锁的页成功。锁定页的效果：swap 回收（`swap.zig`）跳过；`MADV_DONTNEED`/`MADV_FREE` 对锁定范围整体 `EINVAL`（Linux 同）。`munmap`、`MAP_FIXED` 覆盖（通用路径与原子替换路径）、`mremap` 缩小会释放对应的锁（表满导致无法记录切分时丢掉右半段，即解锁，方向安全）；`mremap` 移动会把锁随页搬到新地址（先算好新表，移动成功才提交）。`mlock2`（MoQiOS 编号 496，`mm/mlock.zig:mlock2`）：flags 先按 32 位截断校验，只接受 `MLOCK_ONFAULT`（1），其余位 `EINVAL`，且先于权限/范围检查（限额为 0 时有效 flags 才是 `EPERM`，坏 flags 仍是 `EINVAL`，对照真实 Linux）；之后与 `mlock` 完全相同。匿名内存本来就 eager 填充，所以 `MLOCK_ONFAULT` 与普通锁无可观察差别，只是被接受。**`mlockall`/`MAP_LOCKED`（hello199，`mm/mlock.zig:mlockall`、`mm/mlock_gate.zig`）**：`mlockall(flags)` 先校验 flags（`EINVAL`），再过权限门（限额为 0 且无 `CAP_IPC_LOCK` 是 `EPERM`），然后 `MCL_CURRENT` 把地址空间里现有的页全部记入锁表——已跟踪的映射整段加入（含还没被访问的文件映射页和已换出的页，`PROT_NONE` 映射也算），再遍历页表补上区域表不知道的部分（程序映像、栈、brk，只扫到 `USER_MMAP_MAX`）；设备/`no_free` 映射不锁（Linux 的 VM_IO）；现有页总数超出限额是 `ENOMEM`（无 `CAP_IPC_LOCK` 时），失败时什么都不改。`MCL_FUTURE` 只在 `Mm.lock_future` 记一个标志：此后 `mmap`、`brk` 增长、`mremap` 增长都会锁住新页并计入 `RLIMIT_MEMLOCK`。不带 `MCL_FUTURE` 的 `mlockall` 会清掉之前的 `MCL_FUTURE`（Linux 重写 def_flags），`munlockall` 同时清掉锁表和该标志，失败的 `MCL_CURRENT` 不改变 `MCL_FUTURE`；fork 子进程和 exec 都从没有标志、没有锁开始。`MAP_LOCKED`（0x2000）不再被当成未知标志：先 `can_do_mlock`（限额为 0 且无能力是 `EPERM`；顺序对照真实 Linux：长度为 0 的 `EINVAL` 和 `MAP_FIXED_NOREPLACE` 撞上已占用页的 `EEXIST` 都排在它前面），再检查已锁页 + 新页是否在限额内，超出是 **`EAGAIN`**（不是 `ENOMEM`，和 mlock 不同；`MCL_FUTURE` 单独从不报 `EPERM`）；`MAP_FIXED` 的替换页不被抵扣，门在碰旧映射之前运行，被拒绝的替换不改动任何东西；`mremap` 增长一个尾页已锁的映射时先过同一个门（`EAGAIN`），成功后把新增的尾部也锁上；`brk` 在 `MCL_FUTURE` 下增长超限时返回不变的 break（和 Linux 的 `check_brk_limits` 一致），缩小时释放那部分页的锁。`MCL_ONFAULT` 被接受，效果与普通锁无可观察差别（匿名页本来就 eager 填充）。**限制**：锁表现在最多 24 段（原来 16，`Mm` 仍在 1024 字节的 slab 档内，`tests/main.zig` 有断言），超过返回 `ENOMEM`，`MCL_CURRENT` 在页面碎成超过 24 段时失败；`MCL_CURRENT` 对 24 段以内的情形是精确的，但要求已跟踪区域加页表遍历得到的段数合起来放得进表；brk 的堆页、程序映像和栈不在区域表里（`madvise` 对它们本来就拒绝，所以 hello199 用配额而不是 `madvise` 来观察堆页是否被锁，没有在目标上验证栈/映像页被 `MCL_CURRENT` 记入锁表后的 `MADV_DONTNEED` 行为）；SysV SHM 附着在 `USER_MMAP_MAX` 以上的页不被 `MCL_CURRENT` 锁；锁的实际效果仍只有"不被换出、不被 DONTNEED"；`MmapRegion.locked` 仍只表示设备/no-free 映射。
- **moqi_libc 的 mman 封装（`include/mman.h`、`src/mman.c`、`include/errno.h`，hello200）**：`mmap`、`munmap`、`mprotect`、`madvise`、`msync`、`mincore`、`mremap`（可变参数，只有带 `MREMAP_FIXED` 时才读第五个参数）、`mlock`、`mlock2`、`munlock`、`mlockall`、`munlockall`，常量全部是 Linux x86_64 的值（先在宿主机用 glibc 头文件取过）。约定与 glibc 一致：成功返回 0（`mmap`/`mremap` 返回地址），失败返回 -1（`MAP_FAILED`）并把内核的 `-errno` 存进 `errno`；内核返回值在 [-4095, -1] 内才算错误，所以高地址的映射不会被误判，成功时不改 `errno`。`errno.h` 新增，列出 Linux 的 errno 值（`EPERM`…`EOVERFLOW`），`errno` 经 `__errno_location()`（每线程，在 TCB 里，pthread.c）。`resource.h` 补齐 Linux 的 `RLIMIT_CPU`/`MEMLOCK`/`LOCKS`/`SIGPENDING`/`MSGQUEUE`/`NICE`/`RTPRIO`/`RTTIME` 编号。**注意**：其它 libc 函数（`unistd.h` 里的包装）仍然是"直接返回 -errno"的旧约定，只有 mman.h 遵循 glibc 约定。没有 `mmap` 的文件映射便利封装、没有 `posix_madvise`/`shm_open`。 这层封装把一个内核缺陷暴露了出来：`mremap(MREMAP_FIXED)` 在新大小不大于旧大小时原本只是原地缩小并返回旧地址，没有搬移；现在 `MREMAP_FIXED` 无论大小都走搬移路径（文件映射仍 `ENOMEM`）。`MREMAP_FIXED` 搬到已有映射之上会替换它们（和 `MAP_FIXED` 同样的拒绝条件，先检查后改动，锁跟着搬、被替换目标的锁释放）。对映射**中间子范围**的 `mremap`（移动、增长、缩小，带或不带 `MREMAP_FIXED`）现在也支持：`mm/mremap_policy.zig` 的纯函数 `plan` 把区域切成头、中、尾三段（huge 块只留在头部或从头开始的中段），`mremapRegion` 先做空槽预检（头/尾各占一个新区域记录，不够就在改动任何东西之前 `ENOMEM`），切开后中段成了一个整区域，交给原有的整区域逻辑；之后无论成功失败都用 `canCoalesce`（原型一致才合并：prot、共享、`may_write` 相同，非文件、非设备、未标 locked、非 huge）把相邻的片重新合回去，避免区域表被碎片占满。文件映射和设备映射不切（它们的后端引用和缺页元数据是整区域的），仍走原来的整区域路径。已知差异：搬到低于 `mmap_min_addr` 的地址 Linux 是 `EPERM`，这里不是；`old_size` 超出所在映射的末尾时 Linux 允许（会跨到后面的映射），这里拒绝；跨越两个相邻独立映射的范围这里不支持。
- **moqi_libc 的 time API（`include/time.h`、`src/time.c`，hello201）**：`clock_gettime`、`clock_getres`、`gettimeofday`、`time`、`nanosleep`、`clock_nanosleep`、`sleep`、`usleep`，`struct timespec`/`struct timeval`（16 字节，偏移 0/8）和 `CLOCK_*`/`TIMER_ABSTIME` 常量都是 Linux x86_64 的（宿主机 glibc 取过值）。约定与 glibc 一致：成功 0、失败 -1 加 `errno`；**`clock_nanosleep` 例外，像 POSIX 一样返回错误号本身且不碰 `errno`**。`time()` 取 `CLOCK_REALTIME` 的秒（纳秒截断），读不到时返回 -1、设 `errno`、不写 `*t`；`sleep(0)` 不进内核，被中断时返回没睡够的秒数（向上取整），因其它原因失败时返回全部秒数；`usleep` 接受任意微秒数。内核错误窗口同 mman：[-4095,-1]。`timespec` 和 `nanosleep` 原来在 `unistd.h`（返回裸 `-errno`），现在搬到 `time.h`，`unistd.h` 包含它；调用者都不看返回值，所以行为变化没有影响。**内核改动**：`clock_nanosleep` 对 `CLOCK_MONOTONIC_RAW`、两个 `COARSE` 时钟和 `CLOCK_THREAD_CPUTIME_ID` 返回 `EOPNOTSUPP`（95，Linux 实测），未知时钟仍 `EINVAL`；`clock_ids.zig` 用 `sleepVerdict`/`sleepErrno` 取代布尔的 `sleepable`（它只有这一个调用者）。已知差异：`CLOCK_PROCESS_CPUTIME_ID` 在 Linux 上真的会睡（等到该进程用掉那么多 CPU 时间，睡着的进程永远等不到），这里是 `EINVAL`；没有 `localtime`/`strftime`/`gmtime`，没有 `timer_create` 的封装。
- **moqi_libc 的日历与 strftime（`include/time.h`、`src/timeconv.c`，hello202）**：`struct tm`（glibc 布局，56 字节，`tm_gmtoff` 在 40、`tm_zone` 在 48）、`gmtime_r`/`gmtime`/`localtime_r`/`localtime`、`timegm`、`mktime`、`difftime`、`strftime`。**本地时区固定为 UTC，没有时区数据库，没有 DST**，`localtime` 与 `gmtime` 的区别只在 `tm_zone`（"UTC" 对 "GMT"）。`gmtime_r` 在年份装不进 `int` 时返回 NULL 并设 `errno = EOVERFLOW`（可表示范围正好是 `tm_year` 的 ±2^31，即 time_t 约 ±6.78×10^16）。`timegm`/`mktime` 对越界字段做规范化（月 12 是下一年一月、秒 -1 是上一分钟，`tm_mday` 为 0 是上月最后一天），写回 `tm_wday`/`tm_yday`，`tm_isdst` 变 0；溢出返回 -1 加 `EOVERFLOW`：`timegm` 只把 `tm_isdst` 清 0，`mktime` 完全不动 `*tm`；范围检查先检查"日期+时+分"这一中间值再加秒（`tm_isdst > 0` 的 `mktime` 先减一小时再检查，glibc 在这个 UTC 区里也这样做，所以 isdst 为 1 的 2000-01-01 05:00 得到的是 04:00 对应的时间）。`strftime` 是 C locale，支持 glibc 的全部转换（`%aAbBcCdDeFgGhHIjklmMnpPrRsStTuUVwWxXyYzZ%`），标志 `_ - 0 ^ #`，宽度，`E`/`O` 修饰符（只对 glibc 接受的转换有效，否则原样输出），未知转换原样输出，放不下（含结尾 NUL）返回 0。**正确性依据**：不只是几个手算用例；写了差分测试程序（不进仓库，在 `/tmp/cmp`）把同一份 `timeconv.c` 与宿主机真实 glibc 逐个比较——`strftime` 随机 1600 万个用例（随机字段包括越界值、`INT_MIN/INT_MAX` 年、各种 `tm_gmtoff`/`tm_zone`/`tm_isdst`、随机标志宽度修饰符、随机缓冲区大小）、日历函数 3600 万个用例，最终 0 差异；ISO 周数 (`%G %V %g`) 另外单独对 670 万个 (年, wday, yday) 点比较过。已知差异：没有 `tzset`/`TZ`，没有本地化（`%Ec` 等和普通转换相同，这在 C locale 里就是 glibc 的行为）；`gmtime`/`localtime` 共用一个静态缓冲区，非线程安全（和 glibc 一样）。 **`asctime`/`asctime_r`/`ctime`/`ctime_r`（hello203）**：格式 `"%.3s %.3s%3d %.2d:%.2d:%.2d %d\n"`，越界的星期/月名是 `???`；静态形式与 `gmtime`/`localtime` 的缓冲区分开但 `ctime` 与 `asctime` 共用一个缓冲区；`_r` 形式最多写 26 字节，更长的文本（5 位年份等）写前 25 个字符加 NUL 后返回 NULL 并设 `EOVERFLOW`；`tm_year + 1900` 溢出 `int` 是 `EOVERFLOW`，NULL 的 `tm` 是 `EINVAL`；`ctime` 对不能分解的时间返回 NULL 加 **`EINVAL`**（不是 `localtime` 的 `EOVERFLOW`，因为 glibc 此时是 `asctime(NULL)`）。差分测试 300 万个用例 0 差异。 **`strptime`（hello203）**：C locale，按 glibc 的 `__strptime_internal` 的行为实现（结构上紧贴它，见许可证说明）：全部转换 `aAbBcCdDeFgGhHIjklmMnprRsStTuUVwWxXyYzZ%`，`E`/`O` 修饰符（只接受 glibc 接受的组合，否则失败），strftime 的标志和宽度被丢弃；`%y` 以 69 为界，`%C` 与 `%y` 可任意顺序组合，`%j`/`%U`/`%W` 配合星期和年份回推月日（包括 glibc 对非闰年第 366 天读过 `__mon_yday` 数组末尾的怪行为，按 glibc 的数据布局扁平读取）；组合转换（`%T %R %r %F %D %c %x %X`）在一份临时副本里解析，整个展开成功才提交，所以失败的 `%T` 不会留下半个 `%H`；`%s` 用 `localtime_r`，年份溢出时失败并留下 glibc 一样的部分写入（`tm_hour/min/sec/wday/year` 已写、`yday/mon/mday` 未写）；`%z` 接受 `Z`、`±hh`、`±hhmm`、`±hh:mm`，分钟 ≥60 失败。**C locale 里 glibc 的"选择状态"也被复刻**：一次调用里第一个数字型 `%O` 转换（`%Od %OH ...`，名字型 `%Ob/%OB/%Oh` 除外）成功并把调用标记为"备用数字"，之后任何数字型 `%O` 和 `%E` 的年/世纪转换（`%Ey %EY %EC`）都失败；`%Ey` 先读一个最多四位的数字存进 `tm_year`（C locale 没有纪元），再落进普通 `%y` 读第二个数字；星期/月份名匹配也受这个状态影响（一次调用里已处于"普通"状态时 glibc 的缩写匹配不前进输入指针）。`day_of_the_week` 用 glibc 的闭式公式并按 32 位 `int` 回绕计算，年份到几百万时结果依赖这个回绕。**许可证**：这一段在结构上紧贴 glibc 的 `time/strptime_l.c`（LGPL-2.1-or-later），而仓库的 LICENSE 是 GPLv3、README 写 MIT，见 `current-code-review-and-fix-plan.md` 的说明，需要所有者决定。**正确性依据**：`test_strptime_abi.c` 里 367 行 glibc 实测的表（每行从同一个"脏"`struct tm` 出发，所以没改的字段、重算的字段、失败时已写的字段都被钉住），另外写了 strptime 差分测试（随机格式串和输入，随机组合转换、修饰符、标志、宽度，含越界数字、名字、符号），最终代码上约 1800 万个用例 0 差异；差分里还发现了 8 类表里原本没有的行为，都已补进表。已知差异：不支持纪元（C locale 没有）、没有 `strptime_l`、`%Z` 只读不转换。
- **moqi_libc 的数值转换、随机数和 string.h 其余部分（`src/numconv.c`、`src/strfunc.c`，hello204）**：`strtol`/`strtoul`/`strtoll`/`strtoull`（`long` 与 `long long` 同宽，所以 ll 形式与普通形式逐位相同）、`atol`/`atoll`、`abs`/`labs`/`llabs`（最小负值取绝对值得它自己，同 glibc）、`div`/`ldiv`/`lldiv`（向零截断）、`rand`/`srand`/`RAND_MAX`；`strncat`、`stpcpy`、`strnlen`、`strstr`、`memchr`、`memrchr`、`strspn`、`strcspn`、`strpbrk`、`strcasecmp`、`strncasecmp`、`strdup`、`strndup`、`strtok`、`strtok_r`、`strerror`。**`strtol` 家族**按 glibc 实测：前导空白（含 `\v \f`）、可选符号、`base 0` 按 `0x`/`0b`/`0` 前缀选 16/2/8/10；只有后面跟着该进制的数字时前缀才算数（所以 `"0x"` 是数字 0、结束指针在 `0` 之后）；溢出返回类型极值加 `ERANGE`；`base` 不在 0 和 2..36 是 `EINVAL` 且**不写**结束指针；无数字时结束指针等于起点；`errno` 成功时不动；无符号形式接受负号并按 2^64 取模，但幅度太大仍是 `ERANGE`（`strtoul("-18446744073709551616")` 是 `ULONG_MAX`/`ERANGE`，`"-18446744073709551615"` 是 1）。**`rand`** 是 glibc 的 TYPE_3 加法反馈发生器（34 个字，31 个由 Lehmer LCG 播种，`r[i]=r[i-31]+r[i-3]`，丢弃前 310 个，输出右移一位），所以同一个种子得到与 glibc 完全相同的序列；未播种等于 `srand(1)`，种子 0 当作 1。**`strerror`** 是 glibc 对 0..135 的文本表（从实测生成，不是手抄），其余是 `"Unknown error N"`（含负数，放在静态缓冲区）。**`strtok`** 用静态状态，不是线程安全；`strtok_r` 用调用者的指针。**正确性依据**：`test_numconv_abi.c` 有 105 行 glibc 实测的 strtol/strtoul 表（含 `ll` 形式必须与普通形式一致）、12 个种子各 40 个 `rand` 值和两个 10 万项求和；`test_strfunc_abi.c` 对 `{a,b,B}` 字母表上长度到 5 的全部字符串与长度到 3 的全部针做穷举比较，并有逐 errno 的 `strerror` 表；另外写了差分程序（用 `objcopy --prefix-symbols` 把仓库里这份目标文件原样与宿主机 glibc 放进同一个进程，不是改写过的副本）：`strtol`/`strtoul` 300 万个随机用例（随机拼接前缀、符号、进制、溢出边界）、`rand` 4000 个种子各 200 个值、string 函数约 900 万个随机用例（含高位字节 `\xff\x80`），全部 0 差异。已知差异：没有 `strtod`/`atof`、`strcoll`/`strxfrm`；`strerror` 只有英文；`strtok` 的静态状态不是线程私有的。
- **moqi_libc 的 `qsort`/`bsearch`/`rand_r`、`memmem`/`strcasestr`/`strsignal`（`src/algo.c`、`src/strfunc.c`，hello205）**：`qsort` 是**稳定**的归并排序（glibc 的也是），申请一份同样大小的临时拷贝（`malloc`），申请失败时退回到原地的稳定插入排序（O(n²) 但不分配），`nmemb * size` 溢出同样走这条路；`nmemb < 2` 或 `size == 0` 不调用比较函数也不分配。`bsearch` 先探中点 `lo + (hi - lo) / 2`，所以有重复元素时返回的是和 glibc 同一个（实测 `{1,3,5,5,7,9}` 找 5 得下标 3）。`rand_r` 是 glibc 的三步 LCG 组合（11、10、10 位），种子 0 不特殊处理（不同于 `srand`），`*seed` 被推进到最后一步的状态。`memmem` 空针返回草堆起点、针比草堆长返回 NULL、可含 NUL；`strcasestr` 逐字节折叠大小写；`strsignal` 是 glibc 对 1..31 的文本表（从实测生成），34..64 是 `Real-time signal N`（N 从 SIGRTMIN=34 起数），其余 `Unknown signal N`。**正确性依据**：`test_algo_abi.c` 对长度 0..7、三值字母表的**全部**数组做排序（有序、稳定、是排列），对 400 个随机大数组做同样检查，对元素大小 1/2/3/5/7/8/9/12/16/24/33/100 做稳定性检查，对每个长度 1..7 的有序数组和每个键做 bsearch 并与按 glibc 探测顺序的参考实现比较，另有一个可控失败的 `malloc` 来覆盖退回路径和"只申请一次"的约束；`rand_r` 8 个种子各 12 个值加最终状态；`test_strfunc_abi.c` 加 `memmem` 对长度 0..6/0..4 全部二进制串的穷举、`strcasestr`、`strsignal` 的 -2..70 表。差分测试（仓库里这份目标文件用 `objcopy --prefix-symbols` 原样与 glibc 放进同一进程）：`qsort`/`bsearch`/`rand_r`/`memmem`/`strcasestr` 约 90 万个随机用例，`strsignal` -300..300 加 2 万个随机值，全部 0 差异。已知差异：`qsort` 在 `size` 极大导致 `nmemb * size` 溢出时走插入排序而不是报错；没有 `qsort_r`/`bsearch` 的 GNU 变体。
- **v1 限制**：~~CLONE_FILES 真共享 fd 表未实现（创建时复制）~~（6.27 已实现）；~~`__thread`（PT_TLS）未实现~~（6.28 已实现）；线程私有数据仍可用 getspecific；~~detached 线程不 join 时栈描述符泄漏~~（v2 已回收，见下）。
- **v2（2026-08-13）**：`pthread_detach` + detached 栈惰性回收——退出线程把 TCB+栈块压入无锁死栈链（CAS push），下一次 `pthread_create` 排空。join-detached 与重复 detach 返回 EINVAL；join 与并发 detach 竞速时复见 detached 即放弃 free（所有权归死栈链，杜绝 double-free）。malloc/free 增加 test-and-set 自旋锁，多线程并发 create/join 不再竞争堆空闲链。验收：hello57 增加 8 detached + double-detach/join-detached EINVAL + 排空触发的断言组。
- **线程块的回收以内核为准（hello228）**：`state=1` 只说明线程函数已返回，线程此刻还在 `pthread_exit` 里、跑在这块内存上。`pthread_create` 的 clone 带 `CLONE_CHILD_CLEARTID`，指向 TCB 的 `tid_word`；内核在 `exitTask` 里、任务不再执行用户代码之后才把这个字清零并唤醒它的 futex。`pthread_join` 等它归零才 `free`；`dead_drain` 只 `free` 已归零的块，其余重新压回死栈链（判据是 `dead_reap.h` 的 `dead_block_released`）。hello228 的 4000 线程金丝雀风暴是回归守卫。
- **v2 续（2026-08-13，CLONE_FILES）**：FdTable 从 Task 内嵌（约 57KB/任务）移入静态池（64 槽 + 原子位图），`Task.fd_table` 改为指针；表带原子引用计数，`clone(CLONE_FILES)` 共享指针（跳过复制与 retainSharedResources），`exitTask` 仅在末引用时关闭全部 fd 并归还池。fd 位图操作原子化（allocFdAtLeast 抢位循环 / freeFd 原子 Or），无表级锁；close 与并发使用的描述符内容竞态为记录的弱语义。pthread_create 加传 CLONE_FILES，线程组获得真共享 fd 表与共享 NOFILE 上限。验收：hello57 新增跨线程 fd 共享读 + close 后 EBADF 断言。
- **v2 续（2026-08-14，PT_TLS/`__thread`）**：x86-64 TLS variant II——FS（tp）指向 TCB，程序 PT_TLS 模板的每线程副本位于 tp 正下方（编译器 LE 模型负偏移访问）。crt0 经 auxv（AT_PHDR/AT_PHENT/AT_PHNUM）发现 PT_TLS（`__moqi_tls_setup`），主线程改用动态 [TLS][TCB] 布局；pthread_create 按 [TLS 块][TCB][栈] 分配并逐线程复制模板。无 PT_TLS 的程序保持原布局。验收：hello57 的 .tdata/.tbss 隔离断言（3 线程写不同值读回 + 主线程原值不变）。
- **验收**：hello57（4 线程 × 25000 次互斥自增 = 100000 全对、once 恰好一次、getspecific/errno 隔离、tgid 一致），SMP=1/4 smoke 通过。

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

**用户态线程真正可用（2026-07-26）**

在此之前 `CLONE_VM` 只有内核侧代码，用户态从未创建过线程；第一个线程示例 `user/hello35.c`
一写出来就暴露了调度器的任务发布缺陷：`clone` 返回子 TID，子线程却永不被调度（详见
`current-code-review-and-fix-plan.md` 5.2r）。修复后 `hello35` 在 mmap 出的栈上启动线程、
由线程写共享变量、创建者读到 42，`hello35: PASS` 已是 x86_64 冒烟必需标记。

`clone` 现在还会设置 `child.saved_user_rsp`（取新栈顶），与 fork 对齐。

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

**`sync_file_range`（有界范围同步）**：按调用者提供的 `[offset, offset + nbytes)` 范围
处理回写；`nbytes == 0` 是有界空操作，不隐式扩展为直到文件末尾。范围先做溢出和标志位
校验，未知 flags 或 `offset + nbytes` 溢出返回 `EINVAL`；无效描述符返回 `EBADF`，不支持
范围同步的管道/设备描述符返回 `EINVAL`。当前成功路径复用 `syncFile`/writeback 机制，
`hello76` 覆盖 regular-file/range、零长度、边界错误、错误传播和 fd close；验收只声明这些
语义，不作 wall-clock 或持久化性能结论。

**`readahead`（有界 ext2/FAT32 预取）**：syscall #291 只接受 ext2 或 FAT32 regular-file 描述符，按
`[offset, offset + count * 4096)` 做有界、best-effort page-cache 预取；`count == 0` 返回
成功且不改变 fd offset。offset/字节范围溢出、超过 32 页、无效 fd 返回 `EINVAL`/`EBADF`，
管道和设备等不支持的描述符返回 `EINVAL`。该契约只保证验证与后续 read 的语义正确性，
不作 wall-clock、吞吐或预取命中率结论。

**`fallocate`（严格模式边界）**：syscall #274 只在可写 ext2 regular-file 描述符上保留现有
`mode == 0` 路径；FAT32、ramdisk、管道、设备和其它非 ext2 描述符在目标修改前返回
`EOPNOTSUPP`。所有非零 mode 必须在目标查找和修改前返回 `EOPNOTSUPP`，并且不得改变文件大小；
无效 fd 返回 `EBADF`，只读 ext2 描述符返回 `EACCES`。`hello79` 验证模式校验、非 ext2/只读
错误传播和大小不变性；该验收不作 wall-clock、吞吐、分配速度或持久化性能结论。

**显式不支持 syscall 边界（hello80）**：acct（#281）、unshare（#282）、process_madvise
（memfd_create #285、chroot #280、#440）、mount_setattr（#442）、quotactl_fd（#443）、memfd_secret（#447）、process_mrelease（#448）、set_mempolicy_home_node（#450）、map_shadow_stack（#453）、statmount/listmount（#457-#458）、LSM self-attribute/module calls（#459-#461）、listns（#470）、rseq_slice_yield（#471）及 Landlock（#444-#446）若没有对应的 anonymous memfd、root isolation、跨进程内存、mount 属性、quota、secret memfd、跨进程内存回收、NUMA、CET shadow stack、mount metadata、namespace 列表、rseq 或 LSM
实现，必须在任何目标查找、状态变更或用户缓冲区访问前返回 `ENOSYS`。hello80 用 raw syscall
和 sentinel buffer 验证错误码及 no-mutation 保证；它是 ABI acceptance gate，不是这些子系统的
实现，也不接受 no-op 成功作为替代证据。

**挂载管理** (v18.0): `mountFs` / `umountFs`，16 挂载点表，支持 tmpfs/ext2/vfat/proc/ramfs 类型。系统调用 #165 (mount), #166 (umount2)。

**只读 ext4 / ext3 / ext2 与 NTFS 卷**（§6.56，`fs/ext4.zig`、`fs/ntfs.zig`、`fs/rofs.zig`、
`fs/fs_reader.zig`、`fs/rofs_guard_policy.zig`）：

- **分层**：`ext4.zig` / `ntfs.zig` 是纯解析器——无 I/O、无分配、无全局状态，只通过
  `fs_reader.Reader`（`read(offset, buf)`）取字节，因此可在 host 上直接对真实 `mke2fs` /
  `mkntfs` 镜像做测试。`rofs.zig` 是内核胶水：挂载表（4 槽）、每挂载 16×4 KiB 直接映射页
  缓存、一把 `rofs_lock` 串行化全部操作（只读 + 小卷，锁内做设备 I/O 可接受）。
- **挂载**：`mount(source, target, "ext4"|"ext3"|"ntfs"|"ntfs3", flags)`，`source` 为
  `/dev/<块设备名>[p<N>]`（`vblk1`、`vblk1p2`、`nvme0`、`sda`）。分区表先试 **GPT**
  （`fs/gpt.zig`：保护性 MBR + 头部 CRC32 + 条目数组 CRC32，仅接受主表在 LBA 2、数组 ≤32 扇区的
  布局，最多 128 个分区；备份表不使用），保护性 MBR 后若没有有效 GPT 则**拒绝**而不退回 MBR；
  否则按 MBR 主分区 1-4 解析。始终只读（flags 强制置 `MS_RDONLY`）。同一设备+起点不能重复
  挂载（EBUSY）；类型与内容不符返回 EINVAL，设备/分区不存在 ENODEV。第二块 virtio-blk 盘注册
  为 `vblk1`。
- **挂载目标规则**（`fs/mount_path_policy.zig`，纯函数，host 测试）：`target` 必须是绝对
  路径并先做规范化（`//`、`.`、`..` 折叠，存储的是规范形式，`umount` 接受等价拼写）；拒绝
  `/`、`/dev`、`/proc`、`/tmp`、`/sys` 及其子路径（EBUSY，否则卷会遮蔽设备节点/内核伪文件系统）；
  与已有挂载相同或嵌套（任一方向）同样 EBUSY；相对路径 EINVAL。挂载表由 `mount_lock`
  保护，`rofsRoute`、mount、umount 都在锁内。
- **权限（DAC）**（`fs/rofs_access_policy.zig`）：open 时对路径上**每一级目录**要求搜索（x）
  权限，对目标要求读（r）权限（符号链接自身不检查，目标照常检查）；owner/group/other 只匹配
  其中一类，root 与 `cap_dac_override` 绕过读写检查但不绕过"没有任何 x 位"的目录/文件；
  不跟踪补充组。目录列表（getdents）的权限由 open 时的读权限覆盖。**NTFS 没有 POSIX 权限
  信息，内核报告固定的 0o555/0o444、uid 0，因此 NTFS 上 DAC 实际恒允许读取。**
- **路径路由**：`vfs.rofsRoute` 对绝对路径做最长前缀匹配（按路径分量边界，`/mnt` 不匹配
  `/mntx`）；相对路径在 `openWithMode` 里用任务 cwd 拼接后再路由（cwd 在卷内时）。
  `chdir` 到卷内目标必须存在且是目录。
- **fd 与代数**：新 fd 类型 `rofs_file`（`rofs_mount`、`rofs_gen`、`rofs_ref`）。每次挂载
  分配新的 generation；卸载后槽位被复用时，旧 fd 带着旧 generation，读取返回 ENODEV，
  不会读到占用该槽位的另一个卷（即使 inode 号相同）。umount 不等待 fd 关闭。
- **支持的 syscall**：open（O_NOFOLLOW 打开符号链接本身）、read、pread、lseek、fstat、
  statx、getdents64（`.`/`..` 合成，恢复游标由 rofs 管理，目录上只允许 `lseek(0)` 倒带）、
  readlink、chdir、epoll（恒可读）。
- **只读保证**：写打开 / `O_CREAT` / `O_TRUNC` 返回 EROFS；fd 上 write/pwrite 返回 EROFS；
  路径型修改类 syscall（rename、mkdir、rmdir、link、unlink、symlink、chmod、chown、
  truncate、mkdirat、fchmodat、renameat2、setxattrat、removexattrat 等）由 dispatch 层的
  `rofsGuard` 统一拦截——`rofs_guard_policy.zig` 是（syscall 号 → 路径参数寄存器）表，
  对每个路径参数做 cwd 拼接、规范化、前缀路由，命中卷即 EROFS。rename 的**任一**端在卷内
  都拒绝。
- **ext4 能力**：extent 树（任意深度、未初始化 extent 读零）与经典直接/间接块映射（ext3/
  ext2）、32/64 位组描述符、flex_bg、任意块大小、htree 目录（线性扫描——内部 dx 节点看起来
  像空目录项，线性遍历能看到所有叶子项）、快/慢符号链接、稀疏文件。**不支持**（挂载返回
  EOPNOTSUPP 级错误）：meta_bg、日志设备、MMP、压缩、dirdata；inline_data / 加密 / casefold
  的 inode 读取时返回 Unsupported。需要日志恢复的卷以只读方式挂载并**不回放日志**
  （打印警告），可能显示比最后一次提交更旧的状态。元数据校验和不验证。
- **NTFS 能力**：任意扇区/簇/记录大小、碎片化 $MFT、所有 MFT 记录与索引块的 update
  sequence fixup、常驻与非常驻 $DATA（含稀疏 run 与 initialized_size）、
  $INDEX_ROOT + $INDEX_ALLOCATION B 树目录（整树遍历）、8.3 别名隐藏、UTF-16→UTF-8、
  symlink / junction 重解析点。文件名匹配仅 ASCII 大小写不敏感（NTFS 本身经 $UpCase），
  非 ASCII 名字只匹配相同拼写——可能漏匹配大小写不同的拼写，但不会匹配错文件。**不支持**：
  压缩/加密数据、靠 $ATTRIBUTE_LIST 跨扩展记录的文件。根目录会列出 `$MFT`、`$Bitmap` 等
  系统文件（它们是真实的目录项）。$LogFile 被忽略，未干净卸载的卷按原样读取。
- **已知限制**：dup 在本内核复制描述符（各自 offset），与 POSIX 共享 offset 不同，对 rofs 同
  样适用；ext4 inode 的 uid/gid 由低 16 位与高 16 位合并；NTFS 不提供 xattr/ADS；卷内不能再挂载别的文件系统。
- **验证**：host 测试（ext4 20、NTFS 19、GPT 5、挂载路径 5、DAC 7、目录游标缓存 7、睡眠锁 6、mmap 策略 5、EROFS 守卫表 1；含 bigalloc 镜像 `ext4_bigalloc.img`、statfs 数值与 `dumpe2fs` / `$Bitmap` popcount 交叉核对；真实
  `tools/fsfixtures/mkfixtures.sh` 生成的镜像，`debugfs` / `ntfsls` 交叉核对；含敌对超级块/
  引导扇区/损坏 extent 树/fixup 撕裂）；`hello114` 运行时检查 302 项（含并发读，另有 NVMe 4 项、AHCI 4 项仅在手动提供镜像时运行）（另有 NVMe、AHCI 两段默认 skip）（SMP=1/2/8，MBR 与 GPT 两种
  数据盘镜像，`MOQI_DATA_IMG=tests/fixtures/fs/datadisk_gpt.img`），变异验证——去掉 EROFS 守卫
  则 7 项失败，忽略挂载代数则过期 fd 检查失败，关掉挂载规则则 7 项失败，关掉 DAC 检查则 7
  项失败。NVMe（中断驱动）与 AHCI 上的真实挂载读取（I/J 段）需要手动提供带 ext4 的镜像
  （`MOQI_SMOKE_NVME_IMG`、`MOQI_SMOKE_AHCI_IMG`），**默认 smoke 中这两段是 skip**；手动运行时
  两者均读取 300000 字节通过。

**/dev 设备节点**：全部由 devfs 注册表提供（见 3.8），`open` 的 `/dev/` 分支
查表分发到节点 ops；未注册名字返回 `-ENOENT`。

### 3.2 Ramdisk ✅

文件: `ramdisk.zig`，格式: MRD（自定义）

- Header: 32 字节（magic + entry_count + ...）
- Entry: 80 字节/文件（名称、偏移、长度）
- Data: 串接所有文件原始数据

只读，由内核启动时一次性加载到内存，存放所有用户测试程序。

### 3.3 FAT32 ✅ 单扇区 FAT 缓存 + DMA 安全写缓冲

文件: `fat32.zig`

- MBR 分区表解析
- Boot Sector (BPB)；FSInfo metadata is not currently implemented.
- FAT 表读写：单扇区 FAT 缓存（`fat_cache_sector`，v53.36，顺序读 I/O 减少约 128 倍）
- 空闲簇扫描游标（`last_free_cluster`，v53.38，O(N) 分配扫描）
- 8.3 短文件名 + LFN（长文件名）支持；挂载扫描遇到带“最后一片”标记的 LFN 片段即重新开始一条链
  （`fat32_util.LfnAccumulator`），已删除文件遗留的孤立片段不会吞掉下一个文件的长名
- 根目录只有一层：带 `/`（首字符之后）的名字不是 FAT32 名字（`isRootName`），交给 ext2
- 新建文件预分配一个首簇，首次写入复用它（`ownedClusters`）；FAT 更新写入每一份 FAT（`fatCopySectors`，按 BPB_NumFATs）
- 与 ext2 同盘：BPB 声明整盘，但 ext2 从 LBA 32768 开始；ext2 挂载后分配器上界收紧到 ext2 起点之前（`allocLimitCluster`，`shared_disk_foreign_lba`）
- 操作: 读/写/创建/删除/目录列表
- 全局 `fs_lock`（IrqSpinlock）串行化文件系统操作；文件数据写回经 `fs/writeback.zig`
  按稳定 inode 标识（而非打开文件句柄）缓冲，多毫秒级延迟刷盘由专用 writeback 内核线程
  （`vfs.zig` `writebackThreadMain`，调度 tick 唤醒等待队列）执行
- TRIM (G5)：`deleteFile` / `truncateFile` 的簇链释放循环把每个释放的簇记入
  discard 积攒缓冲，循环结束后经 `trim_ranges.coalesce` 合并为最大连续范围
  批量调用 `block_dev.discard`

### 3.4 Ext2 ✅ 64 条目块缓存 + 哈希加速 + 间接块缓存

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
- 块缓存：64 条目（`CACHE_ENTRIES=64`）+ 哈希桶加速查找，dirty write-back
- 间接块指针缓存：16 条目，避免重复读取间接块
- 截断释放：`truncateFile` / `truncateByInode` 共用单/双/三级间接块 tail-trim helper，缩小时释放尾部数据块和空的间接树并失效 inode 页缓存
- 目录条目读写
- 多级路径解析（`resolveParent`）
- **DAC 与创建者**：打开已有文件在截断/发布 fd 前按 inode owner/mode 判定（`dac.decideExistingOpen`）；
  `chmod`/`chown` 族按属主与 CAP_FOWNER/CAP_CHOWN 授权。新建文件、目录、符号链接记录 euid/egid（含 osd2 高 16 位），
  文件/目录权限为 `(requested & 0777) & ~umask`。命名空间修改（create/mkdir/symlink/unlink/rmdir/rename/hardlink）
  在 fs_lock 内检查中间目录 search 与父目录 write+search，拒绝返回 EACCES，不再回落到 FAT32 的同名文件。
  `user.*` xattr 的 set/remove 需要文件写权限、get/list 需要读权限，拒绝返回 EACCES 且先于属性是否存在的判断。
  打开（含 statx/access/truncate(path)）的路径遍历对每级目录检查 search，拒绝为 EACCES。粘滞位目录（S_ISVTX）中删除、rmdir、rename 移走或覆盖别人的条目返回 EPERM（`stickyRefuses`，条目属主、目录属主、CAP_FOWNER 例外）；补充组参与组类判定（见 `proc/group_policy.zig`）。
- 操作: `readFile` / `writeFile` / `createFile` / `createDir` / `unlinkFile` / `listDirInode` / `truncate`
- TRIM (G5)：`freeBlock` 把释放的数据块记入 discard 积攒缓冲（非批量时立即
  下发；`batch_free_depth` 批量释放时在 defer 收尾统一经 `trim_ranges.coalesce`
  合并后批量 `block_dev.discard`），覆盖 `unlinkFile` / `truncateFile` /
  `truncateByInode` 的全部直接块与间接树释放路径

### 3.4.1 目录项缓存 dcache (K1) ✅

文件: `dcache.zig`（纯核心 + 内核胶水）；接入点: `ext2.zig`、`fat32.zig`

- **键结构**：`(fs_kind, parent_id, name)` → `child_id` 的正向缓存（只缓存
  查找成功的项）。ext2: parent_id = 父目录 inode 号，child_id = 子 inode；
  fat32: parent_id = 所属目录簇（只有固定根簇被缓存——`fat32.openFile` 只解析
  根目录项），child_id = `files[]` 槽位索引，命中跳过线性扫描。
- **结构**：512 条目（`CAPACITY`），按哈希直接映射、冲突直接替换（首版
  无链无 LRU）。条目存完整名字节做全名比较，哈希冲突不会误命中。
- **命中路径**：ext2 `findDirEntryCached`（`walkPathInner` / `resolveParent` /
  `walkPathToInodeResolve*` 等所有按名查目录项的调用点）先查缓存，命中即跳过
  目录块读取；未命中走原慢路径，成功后回填。fat32 `openFile` 同理，且命中后
  防御性复核槽位（active + 非目录 + 全名比较），失效条目退化为慢路径而不是
  打开错误文件。
- **失效策略（保守——错误命中即数据损坏）**：
  - ext2 `addDirEntry` / `removeDirEntry`（覆盖 create/unlink/rename/
    hardlink/symlink 全部目录内容变更）：defer 无条件失效该父目录 inode 的
    全部条目，并失效子 inode 作为 parent 的条目（子项可能是被抛弃的目录，
    且其 inode 号之后可能被复用）。失败路径同样失效——多失效只损失一次
    重扫。
  - fat32 `createFile` / `deleteFile`：`createFile` 可能把 tombstone 槽位
    复用于不同名字，按条目跟踪槽位不可靠，故**整体失效全部 fat32 条目**
    （fat32 本就只缓存根目录，代价极小）。
- **锁序**：整张表一把 `IrqSpinlock`（叶子锁），只在 `lookup` / `fill` /
  `invalidate*` 胶水函数内短暂持有，绝不跨 I/O 或 FS 调用。锁序
  `fs_lock → dcache.lock`（dcache 只在 fs_lock 临界区内被短暂获取，反向
  不成立）。
- **测试**：纯核心 host 测试（`tests/main.zig` "K1" 块，经
  `kernel/host_test.zig` 导出）：命中/未命中/回填/按 parent 失效/按 fs 整体
  失效/冲突替换/容量上限/超长名不缓存/统计计数。

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
- rename 路由（`fs/rename_policy.zig`）：`/tmp`↔`/tmp` 走 `tmpfs.tmpfsRename`（文件与目录、覆盖、`RENAME_NOREPLACE`、
  `RENAME_EXCHANGE`、粘滞目录规则、禁止移入自身子树），跨 `/tmp` 边界为 EXDEV，其余走 ext2（普通 rename 与
  `RENAME_NOREPLACE`；覆盖已有文件时原地改写目标目录项的 inode 号；文件覆盖目录为 EISDIR；`RENAME_EXCHANGE` 为 EINVAL）。
  renameat2 的未知位、`RENAME_WHITEOUT`、NOREPLACE|EXCHANGE 为 EINVAL。FAT32 没有 rename：根目录下的裸文件名
  （O_CREAT 时落在 FAT32）改名仍返回 EXDEV。hello119 验收。
- 调度 IPI 合并（`ipi_kick_policy`）：`kickCpuX86` 先把目标 CPU 的 `resched_pending` 置 1 再发 IPI；若 LAPIC 没接受
  （ICR 超时），立即清回 0（`resetAfterSend`），否则此后发给该 CPU 的所有 kick 都会被合并掉。发送成功时发送方不碰该标志。
- 目录读取只对 tmpfs 可达：VFS 目前没有返回 ext2 目录描述符的路径，
  所以 `getdents64` 的 ext2 分支从用户态触达不到

### 3.6.1 写回错误传播（SK-155 约束）

- `ext2.writeFile` / `fat32.writeFile` 遇到设备写失败即停止，返回值只覆盖真正
  落盘的字节；文件大小按实际写入量增长，而非按请求量
- 刷盘回调只有在全长被接受时才算成功，否则脏位保留、数据不被丢弃
- `flushFile` / `flushAllByType` 返回是否全部写出，经
  `syncFile` / `syncAll` / `invalidateFile` 上报至 `sync` / `fsync` / `msync` / `close`（`EIO`）
- `fsync` 按描述符类型选择 `ext2_file_idx` 或 `fat32_file_idx`：两个文件系统的
  索引空间独立，用错会刷到别的文件（通常是没有）却报告成功

### 3.7 Linux AIO ✅ (v18.1)

文件: `aio.zig` (267 行)

- 8 个 AIO 上下文上限，32 事件/上下文
- io_setup: 创建上下文，写入 ctx_id 到用户空间
- io_destroy: 销毁上下文
- io_submit: 提交 I/O 请求 (简化: 同步执行 PREAD/PWRITE，立即标记完成)
- io_getevents: 获取完成事件 (环形缓冲)
- io_cancel: 当前 `io_submit` 在返回前同步完成请求，因此没有 pending request 可取消；
  io_cancel 返回 `ENOSYS` 且不读取 IOCB/不写 result。真实异步取消需独立 pending-request
  生命周期与取消所有权模型后再实现；hello70 锁定该无副作用 contract。
- 系统调用: #213 (io_setup), #214 (io_destroy), #215 (io_submit), #216 (io_getevents), #217 (io_cancel)

### 3.8 devfs 设备节点注册框架 ✅

文件: `devfs.zig`（纯核心，host 可测）、`devfs_nodes.zig`（内建节点实现）；
接入点: `vfs.zig`（open/read/write/pread/pwrite）、`getdents.zig`、`epoll.zig`

- **注册表**：定长 32 槽（`MAX_NODES`），名字 ≤ 24 字节。槽位稠密
  （0..nodeCount()-1），fd 直接缓存槽位索引，getdents 用索引作目录游标。
  `unregister(idx)` 打墓碑（tombstone）：lookup/nameAt/getdents 跳过，
  名字可重新注册；`opsAt` 对墓碑槽位仍返回 ops，让存量 fd 在 op 内拿到干净
  的 `-EIO`。**v1.1 起墓碑槽位可复用**：register 优先取最老墓碑（最小索引），
  无墓碑才追加，反复注册/注销不再耗尽表。复用由**每槽 generation** 兜底：
  每次注册递增 `entries[idx].generation`，vfs 在 open 时把它缓存进
  `FileDescriptor.devfs_generation` 并随 `IoCtx.generation` 传给 op，
  proxy op 对不匹配的 fd 返回 `-EIO`——旧 fd 缓存的槽位索引即使指向新节点
  也只会稳定失败，绝不误中新节点。每次注册/注销递增单调
  `changeCounter()`（seq-cst 原子），并触发 `change_hook`（由 devfs_nodes
  安装，唤醒 /dev/devfs-watch 读者）。
  运行时注册（devfs_register 系统调用）由 devfs_proxy 的 alloc_lock 串行化，
  表本身保持无锁：register 先发布条目再（仅追加时）递增 count。
- **ops 结构**（`NodeOps`）：
  ```zig
  open:  ?*const fn () i64,                                  // 0 成功 / 负 errno（如 /dev/pci 的 CAP_SYS_RAWIO 门）
  read:  ?*const fn (ctx: *IoCtx, buf: [*]u8, count: usize) i64,
  write: ?*const fn (ctx: *IoCtx, buf: [*]const u8, count: usize) i64,
  poll:  ?*const fn (ctx: *const IoCtx) u32,                 // POLL_IN|POLL_OUT（与 EPOLLIN/EPOLLOUT 同值）
  flags: packed struct { no_pread: bool = false },
  ```
  `IoCtx { offset, status_flags, generation }` 镜像 fd 的游标、O_NONBLOCK 位
  与 devfs 槽位 generation：vfs 调用前从描述符播种、成功后写回 offset（pread
  则用显式 offset 播种并丢弃，且强制 O_NONBLOCK 使 kmsg pread 永不睡眠）；
  generation 供 proxy op 识别复用槽位的陈旧 fd。read 返回负 errno / 0 EOF /
  字节数。
- **锁与上下文契约**：表仅在内核 init（`devfs_nodes.init()`，main.zig 在
  任何用户任务打开 /dev 之前）单线程注册，之后只读、无需锁。ops 在调用者
  的系统调用上下文执行，不持有 devfs 内部锁（也没有）；可以阻塞（kmsg
  read 走 J3 等待队列）并可以使用各子系统自己的 IRQ 安全锁，但不得假定
  中断上下文；`open`/`poll` 不得阻塞。
- **节点清单**（注册顺序 = getdents 枚举顺序）：
  | 节点 | read | write | 备注 |
  |---|---|---|---|
  | null | 立即 EOF | 丢弃，返回 count | 纯核心（host 测试） |
  | zero | 全零填充 | 同 null | 纯核心 |
  | full | 立即 EOF | -ENOSPC | 纯核心 |
  | random / urandom | ≤256 字节 PRNG | 无（-1） | no_pread |
  | kmsg | 日志环，阻塞读（J3 语义不变，游标在 fd offset） | 无 | epoll 电平触发 EPOLLIN |
  | pci | PCI 枚举快照 | 无 | open 需 CAP_SYS_RAWIO（L1） |
  | tty | x86_64: PS/2 键盘输入环；其他架构 -ENOTTY（无串口 RX 路径） | 串口输出 | no_pread |
  | devfs-watch | devfs 变更计数器（u64 LE），计数器未越过本 fd 上次读到的游标时阻塞 | 无 | no_pread；devmgr 的事件源 |
- **打开语义**：`vfs.open` 的 `/dev/` 分支先查 devfs 表；未注册的名字一律
  `-ENOENT`（不再有硬编码节点）。`/dev` 本身可打开为目录 fd
  （`devfs_idx == DIR_IDX`），`getdents64` 对其枚举全部注册节点
  （DT_CHR）；对目录 fd 的 read/write 返回 `-EISDIR`。
- **epoll 集成**：fd 类型统一为 `.devfs`（旧的 `.random/.kmsg/.pci` 已删除），
  `resource_idx = devfs 槽位`；就绪事件由节点 poll op 计算。klog 追加日志后
  用 `epollNotify(.devfs, kmsgNodeIdx(), EPOLLIN)` 唤醒等待者。
- **测试**：纯核心 host 测试（`tests/main.zig` "devfs" 块）：注册/查找/枚举、
  非法名/重名/满表拒绝、null/zero/full 语义、IoCtx O_NONBLOCK 解码；
  端到端见 `user/hello53.c`。

### 3.9 devfs proxy：用户态设备节点 + devfs 变更事件（P1）✅

文件: `fs/devfs_proxy.zig`（纯核心 + 内核胶水）、`fs/devfs.zig`（墓碑与
变更计数器）、`fs/devfs_nodes.zig`（/dev/devfs-watch）；接入点:
`vfs.zig`（FdType.devfs_ctrl、read/write/close）、`getdents.zig`（跳过
墓碑槽）、`epoll.zig` / `poll.zig` / `select.zig`（就绪分支）、
syscall #484、task reap 双站点 cleanup。

- **devfs_register(name_ptr, flags) → ctrl_fd（syscall 484，x86_64）**：
  需要 CAP_SYS_RAWIO；名字 ≤ 24 字节；flags 必须为 0（保留）。内核以
  comptime 展开的每槽 ops 创建 devfs 节点（每槽一个 `nodes[i]` 闭包，
  NodeOps 无 userdata），并返回新 fd 类型 `.devfs_ctrl` 的控制 fd。
  同一时刻最多 `MAX_USER_NODES = 8` 个用户态节点；owner 已死的槽位可
  复用（见下），重名 `-EEXIST`，8 槽全存活时 `-ENFILE`。
- **协议字节布局**（全部小端）：
  - 请求（owner 从 ctrl_fd `read`，一次性返回完整一条）：
    `u32 seq @0 | u32 op @4（1=read, 2=write）| u64 offset @8 | u32 len @16 |
    u8 payload[len] @20`（仅写请求携带；读请求止于偏移 20，头部共 20 字节）。
    缓冲区放不下最老请求时 `-EINVAL`，请求不出队。
  - 响应（owner 向 ctrl_fd `write`）：`u32 seq @0 | i32 ret @4 |
    u8 data[ret] @8`。读响应 ret>0 时恰为 `8+ret` 字节（ret ≤ 请求的 len，
    ≤ 4096）；写响应与错误响应恰为 8 字节，ret 为已消费字节数或负 errno。
    未知/状态不符的 seq、畸形响应一律 `-EINVAL`。
- **请求生命周期**：客户端 read/write 入队 `{seq, op, offset, len[, payload]}`
  （seq 单调不复用；并发上限 `MAX_PENDING = 4`），随后在
  **节点私有等待队列**上阻塞；owner `read(ctrl_fd)` 出队最老 queued 请求
  （转 inflight，空则阻塞，EINTR 协议）；owner `write(ctrl_fd, response)`
  按 seq 完成并唤醒客户端。队列满时：阻塞式客户端睡在专门的 `space_wq`
  上直到某槽释放（collect/cancel/drain 时唤醒）；`O_NONBLOCK` 客户端立即
  `-EAGAIN`——**O_NONBLOCK 只门控入队接受**，入队后的往返等待两种 fd 都
  阻塞（pipeRead 同样先睡后读；pipeWrite 现在也会在管道满时睡到读者腾出空间，
  见 vfs.zig 与下文“管道写阻塞”）。客户端阻塞遵循 pendingFatal/pendingActionable
  协议（致命信号走 exitTask，可处理信号 `-EINTR` 并取消请求：queued 直接
  释放，inflight 标记 cancelled、迟到的响应被接受但丢弃）。阻塞期间**不持
  有任何 vfs/devfs 锁**——锁序：`alloc_lock → node.lock（IrqSpinlock）→
  task/runqueue 锁`（wakeOne/wakeAll 在 node.lock 内调用，同 klog 的
  ring_lock 嵌套）；检查+入队、检查+阻塞各在同一段 node.lock 临界区内，
  完成方也在同一把锁下唤醒，无丢失唤醒。node.lock 绝不跨
  forceReschedule 持有。
- **owner 死亡语义**（ctrl_fd close，或任务退出——exitTask 关 fd 触发
  close；另有 reap 双站点的 `devfs_proxy.cleanupTask` 兜底，与
  `userdrv.cleanupTask` 并列）：所有未完成请求以 `-EIO` 完成并唤醒全部
  等待者；devfs 节点打墓碑（`devfs.unregister`）——此后按名 open 得
  `-ENOENT`，已打开客户端 fd 的读写得 `-EIO`。**v1.1 起槽位可复用**：
  devfs 侧 register 优先回收最老墓碑槽（最小索引），proxy 侧优先回收
  最小索引的已死槽（`used && !owner_alive`）；复用前在 node.lock 下做
  全量重置（core 请求队列、三条等待队列、owner、generation），陈旧请求
  与等待者不会漏进新节点。防误中靠**generation**：devfs 每次注册递增槽
  位 generation，proxy 注册时快照进 `node.generation`；客户端 fd 经
  `IoCtx.generation`、ctrl fd 经 `FileDescriptor.devfs_generation` 携带
  open 时的值，op 内不匹配即 `-EIO`——墓碑未复用时稳定 `-EIO`（owner_alive
  检查），复用后也不会把旧 fd 静默重定向到新节点。客户端往返等待循环
  另在每次醒来时复查 generation，复用发生即 `-EIO` 退出。
- **性能权衡**：每次客户端 I/O 都是一次完整的用户态往返（客户端阻塞
  → 调度 owner → owner 读写 ctrl_fd → 唤醒客户端），至少两次上下文
  切换加两次拷贝，吞吐与延迟远逊于内核内节点。热路径设备（kmsg、
  tty、random、磁盘后端）必须留在内核；devfs proxy 面向低频、原型
  验证与策略在用户态的伪设备。payload ≤ 4 KiB/请求，大 I/O 被截为
  4 KiB 短读/短写。
- **poll v1.1 语义**：proxy 读写是同步往返，不存在经典意义的"有数据可读/
  有缓冲可写"，因此就绪定义为**新请求能否不阻塞地被接受**（`Core.pollMask`
  纯谓词）：owner 存活且有空闲请求槽 → `EPOLLIN|EPOLLOUT`；队列饱和
  （MAX_PENDING 占满，注意 queued→inflight 不释放槽位，只有 collect/cancel
  释放）→ 双向都不报就绪；owner 已死 → 恒报 `EPOLLIN|EPOLLOUT`（op 立即
  `-EIO`，若报不就绪 poller 会在死节点上永远睡下去）。ctrl fd 侧在
  epoll/poll/select 三个多路复用器里语义一致：有排队请求 →
  `EPOLLIN/POLLIN/read-ready`，写恒就绪（响应按 seq 匹配、从不阻塞）。
  pread/pwrite 仍经 `no_pread` 拒绝 `-ESPIPE`。
- **devfs 变更事件**：`devfs.register/unregister` 递增 seq-cst 原子
  `change_counter` 并触发 `change_hook`（devfs_nodes 安装）。只读节点
  `/dev/devfs-watch` 的 read 返回当前计数器 u64 LE（8 字节）；计数器未
  越过本 fd 上次读到的游标（`IoCtx.offset`）时阻塞直到变化（O_NONBLOCK
  则 `-EAGAIN`）。新 fd 游标为 0，init 期注册已把计数器推过 0，首次读
  立即返回。等待/唤醒走 watch_lock 保护的等待队列（kmsg J3 同款：
  读者持锁做 检查+入队，hook 持锁 wakeAll，无丢失唤醒）；poll 按
  `counter != cursor` 报 EPOLLIN。
- **测试**：纯核心 host 测试（`tests/main.zig` "devfs proxy (P1)" 块）：
  入队形状校验与 seq 单调、请求/响应线格式逐字节、complete 匹配与拒绝、
  cancel 语义、owner 死亡 drain（-EIO）、devfs 墓碑与计数器/钩子；
  "v1.1 finishing" 块：墓碑槽最老优先复用、change_counter 单调、
  generation 识别注册代次（陈旧 fd 可判定）、pollMask/canAccept 就绪
  谓词（饱和/死亡/释放槽位）；端到端见 `user/hello54.c`。

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

### 4.14 Loopback (lo) 设备 ✅（F2）

文件: `kernel/net/lo.zig`；集成点: `netif.zig` / `udp.zig` / `tcp.zig` / `raw_net.zig` / `socket_syscall.zig` / `e1000.zig` / `mod.zig`

127.0.0.0/8 的流量不出硬件网卡、不做 ARP：TX 路径把组好的 L2 帧排入 lo 环形队列，下一次 drain 将其送回 `net.handleRxPacket`，完成本机协议栈全回路。

- **路由判定**：`netif.isLoopback(ip)`（`ip[0] == 127`，RFC 1122 §3.2.1.3 整个 127/8 块）；纯逻辑版本 `lo.isLoopback` 供 host 单测
- **TX 注入点**：`udp.sendTo` 与 `tcp sendSegmentSeq`（IPv4 127/8）；IPv6 由 K3 补全——`sendToV6`/`sendSegmentV6Seq` 对 `::1`（`netif.isLoopbackV6`：仅末字节为 1）同样绕过 NDP 直投 lo，源地址取 ::1（双向对称）。命中 loopback 时跳过 `arp.resolve`/NDP（不产生地址解析请求），dst MAC 填本机 MAC，v4 源地址填 127/8 目的地址——回复自然回到 lo
- **RX 环形队列**：`LoopbackQueue` 为纯数据结构（16 槽 × 2048 字节，enqueue/dequeue/wrap/dropped 计数），无任何 arch 依赖，host 单测覆盖（`tests/main.zig` 的 `// ─── loopback (F2) ───` 块）；内核全局实例外加 `IrqSpinlock`
- **drain 泵点**：`raw_net.netPoll`、`socket_syscall.netPoll`（无硬件 NIC 时也运行）与 `e1000.handleInterrupt` 末尾。出队持锁、协议处理不持锁（TCP 处理会重入 `lo.sendPacket`，锁顺序恒为 tcp_lock → lo_lock）；单次 drain 上限 4×QUEUE_DEPTH
- **TCP 校验和**：RX 验证的伪首部 dst 在 loopback 段必须使用线上的 127/8 地址而非 `netif.getOurIp()`（`tcp.handlePacket`）
- **getOurIp 语义不变**：DHCP/10.0.2.15 不受影响；loopback 源地址由 TX 路径就地替换
- 运行时验证：`hello43`（单进程 TCP client+server over 127.0.0.1 + UDP 自收发）

### 4.15 DHCP 客户端与启动时租约 ✅（G3）

文件: `kernel/net/dhcp.zig`；集成点: `kernel/main.zig`（启动接线）、`netif.zig`（地址来源选择）

- **四次握手**：DISCOVER → OFFER → REQUEST → ACK，UDP 67/68 端口；先 `udp.ensurePort(68)` 注册客户端端口，否则 UDP 分用会把 OFFER/ACK 丢掉
- **启动时获取**：`kernel/main.zig` 在 `net_mod.init()` 之后（NIC 驱动就绪、定时器 IRQ 尚未使能）尝试一次 `dhcp.discover()`，前提 `nic.isActive()`
- **有界性**：等待循环以 500 tick（~5s）为截止，另有 `MAX_POLL_ITERS` 迭代兜底——启动早期 tick 计数不递增（IRQ 未开），纯 tick 截止永远不会触发，迭代上限保证 boot 不会挂在 DHCP 上；RX 由 `pumpRx()` 轮询驱动，不依赖中断
- **结果标记**：恰好一行大写 `[DHCP] ` 结果日志——成功 `[DHCP] lease: a.b.c.d`，失败 `[DHCP] no lease, static 10.0.2.15`（无 NIC 也走失败分支）；内部进度日志一律小写 `[dhcp] `，供 smoke 门确定性匹配
- **回退语义**：`netif.getOurIp()` 仅在 `dhcp.isConfigured()` 为真时返回 DHCP 地址，否则保持 QEMU user-net 静态地址 10.0.2.15——DHCP 失败不影响 hello14/15/22/27 等静态路径
- **host 单测**：租约状态默认值（未配置 / IP 0.0.0.0 / netmask 255.255.255.0）在 `tests/main.zig` 的 `// ─── DHCP boot (G3) ───` 块覆盖（纯全局量，无 arch 依赖）

### 4.16 DNS 解析器与静态主机表 ✅

文件: `kernel/net/dns.zig`（解析器）、`kernel/net/static_hosts.zig`（纯静态表，host 可测）

- **解析顺序**（`dns.resolve()`）：静态主机表 → 点分十进制直解 → 16 槽
  LRU 缓存（TTL 过期）→ 真实 DNS 查询（DHCP 提供的 DNS，缺省回退 8.8.8.8，
  UDP 53，~2s tick 超时，等待期间 `pumpRx()` 轮询驱动 RX）。
- **静态主机表**：内核可权威回答、不应依赖网络可达性的名字——
  `localhost` → 127.0.0.1，`gateway` → 10.0.2.2（QEMU slirp 默认网关/宿主机
  地址）。匹配为全名、ASCII 大小写不敏感（DNS 名字本就不区分大小写）。
- **环境限制**：真实 DNS 路径要求 NIC 活跃、slirp/上游 DNS 可达且 ARP/UDP
  出栈正常；无 NIC 或无租约时非静态名字一律解析失败（返回 0.0.0.0）——
  静态表保证 localhost/gateway 在任何网络环境下可解。公网域名的真实
  查询在 QEMU user-net 下走 slirp 内建 DNS 代理（10.0.2.3），DHCP 租约
  通常即返回该地址。
- **host 单测**：静态表查询（含大小写不敏感、未知名/空前缀不命中）在
  `tests/main.zig` "v1.1 finishing" 块覆盖（`static_hosts.zig` 无内核依赖）。

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
- **`socketpair` 验收边界（hello78）**：raw syscall #53 只声明支持
  `AF_UNIX` + `SOCK_STREAM` + protocol `0`，返回一对 pipe-backed descriptors，且两端可用
  `write`/`read` 双向传输。其他 domain/type/protocol 返回 `EINVAL`；空或无效 `sv` 指针返回
  `EFAULT`，失败路径不得留下 fd；成功返回的两个 fd 都必须由调用者 `close`。这份验收只证明
  syscall 参数、数据方向和资源清理语义，不宣称完整 Unix-domain socket 兼容性、wall-clock
  性能、吞吐或持久化行为。

---

## 5. IPC 引擎

源码: `kernel/ipc/`

### 5.1 消息传递 ✅

文件: `ipc.zig`

```zig
const Message = extern struct {
    sender: u64,
    reply_to: u64,
    msg_type: u32,
    flags: u32,
    payload: [232]u8,
}; // exactly 256 bytes
```

操作：

| 操作 | 描述 |
|---|---|
| `send(dst, msg)` | 同步发送，目标未 receive 则阻塞 |
| `moqipc_recv(endpoint, message_ptr)` | 按 endpoint ID 阻塞接收消息；当前 ABI 不提供 PID/ANY 来源筛选 |
| `call(dst, msg)` | send + receive 复合 |
| `reply(dst, msg)` | 应答 call |
| `notify(dst, type)` | 异步通知（事件位图） |

死锁检测：最大嵌套深度 8，30 秒超时自动解除。

### 5.2 能力系统 ✅

文件: `capability.zig`

```zig
const Capability = packed struct {
    endpoint: u32,
    generation: u64,        // endpoint incarnation, checked atomically
    rights: CapRights,      // send=1, receive=2, notify=4, manage=8
    valid: bool,
};
const CapTable = [32]Capability; // 每任务

`moqipc_grant_cap_to` 使用 syscall #486：`(target_tid, endpoint, rights)`。
只有 endpoint owner 可以授予，目标 TID 在 authority lock 下解析并写入其 capability table；
endpoint 重建会递增 64 位 generation，旧 capability 不能操作新 endpoint。#311 的旧自授予 ABI
保持不变。send/recv/notify/get_notify 的 endpoint 状态和 capability generation/rights 在同一
authority 临界区检查，避免先检查后使用的竞态；owner 只绕过 receive/get_notify，send/notify
仍必须具备对应 capability。capability 清理与 endpoint owner exit cleanup 是同一生命周期事务。
```

### 5.3 eventfd (64位计数器 + EFD_SEMAPHORE) ✅

文件: `eventfd.zig`

- 64位计数器事件通知机制
- EFD_SEMAPHORE：信号量模式，读后递减1
- EFD_NONBLOCK：非阻塞标志
- 配套读写等待队列
- poll集成：支持POLLIN/POLLOUT事件检测
- 系统调用：#290 (eventfd2)

### 5.2.1 Capability redesign and atomic authorization (v54)

Native IPC endpoints are reclaimed when their owner task exits; blocked senders/receivers are
woken after the endpoint is invalidated, preventing slot exhaustion and stale task-slot ownership.
Explicit destroy is owner-authorized and returns an error for foreign task indices.
Blocked send/call operations awakened by endpoint teardown return `invalid_endpoint` rather than
reporting successful delivery of a discarded message.
Capability grants are owner-authorized: a task cannot mint send/receive/notify/manage rights for
an endpoint it does not own or request unknown rights bits. #486 (`moqipc_grant_cap_to`) permits
an owner to grant the capability to a different live TID.
Capability entries also bind the endpoint slot generation; destroying and recreating an endpoint
invalidates old capabilities instead of allowing a stale numeric ID to authorize the new owner.
The runtime enforces `send` and `notify` rights for foreign callers, and `receive` rights for
non-owners; endpoint owners retain receive/get-notify authority. Capability operations are
linearized with endpoint generation checks under the shared authority lock.
Foreign `get_notify` reads use the same `notify` right and cannot clear another endpoint's bitmap
without authorization.
`moqipc_call` requires the caller's `send` capability on the target endpoint. The kernel assigns
an opaque, one-shot call token in `Message.reply_to`; reply lookup uses that token and validates
the bound callee slot plus TID, rather than trusting a reusable endpoint number. Callee exit
invalidates outstanding transactions and wakes the caller with `invalid_endpoint`, while an
immediate reply is consumed before the caller blocks. `moqipc_reply` remains ABI-compatible with
its endpoint argument but authorizes and routes by the opaque token carried in the reply message.

The native `Message` ABI is an exactly 256-byte extern struct: `sender:u64`, `reply_to:u64`,
`msg_type:u32`, `flags:u32`, and `payload[232]`. Host tests assert these offsets and size.

### 5.4 SysV 共享内存 ✅ (v18.0, v28.0优化)

文件: `sysv_shm.zig`

- 32 个共享内存段上限，256 页/段 (1MB)
- shmget: 创建/查找段，分配物理页并清零
- shmat: 4 级页表映射到进程地址空间 (0x70000000 基址)，支持 SHM_RDONLY
- shmdt: 解除映射，isMappedAt() 4级页表walk验证物理地址匹配，支持延迟删除 (IPC_RMID 标记)
- shmctl: IPC_STAT/IPC_RMID/IPC_SET（mode 与属主 uid/gid，见下）
- `IPC_STAT` 元数据先在 `shm_lock` 内快照，再在锁外 copyout；`IPC_SET` 先锁外 copyin，再锁内校验权限并提交，避免用户页访问运行在 IRQ 关闭状态。负 `key` 以原始 i64 位模式写入 ABI 缓冲区。
- task exit 只有在存在 `Mm` 且成功取得 VM mutation guard 时才执行 SHM detach；guard 获取失败或任务无 `Mm` 时跳过该 detach，但继续完成其余退出清理，避免无保护修改页表。
- `mlock/munlock/mlockall/munlockall` 已实现（per-Mm 锁表、`RLIMIT_MEMLOCK`、swap 排除、`munmap`/`MAP_FIXED`/`mremap` 交互，见上文 memory-lock 一节）；`mlockall`（`MCL_CURRENT`/`MCL_FUTURE`/`MCL_ONFAULT`）和 `MAP_LOCKED` 也已实现（hello199）。
- findFreeRegion: next_free_hint O(n) 扫描，freeSegment 自动重置 hint
- 系统调用: #29 (shmget), #30 (shmat), #31 (shmctl), #67 (shmdt)

### 5.5 SysV 信号量 ✅ (v18.0, v28.0 IPC_SET)

文件: `sysv_sem.zig`

- 16 个信号量集上限，32 信号量/集
- semget: 创建/查找信号量集，IPC_CREAT/IPC_EXCL
- semop: P/V 操作，P 操作用 sched.sleepOn 阻塞等待，V 操作用 wakeOne 唤醒等待者，IPC_RMID 用 wakeAll 通知
- semctl: IPC_RMID/IPC_STAT/IPC_SET（arg ≤ 0777 为 mode；更大的值是 IPC_SET 缓冲区指针）/SETVAL/GETVAL
- 系统调用: #64 (semget), #65 (semop), #66 (semctl)

### 5.5b SysV 消息队列 ✅ (v18.1, v28.0 IPC_SET)

文件: `sysv_msg.zig`

- 16 个队列上限，8 消息/队列，512 字节/消息
- msgget: 创建/查找消息队列
- msgsnd: 发送消息 (含 mtype 类型字段)
- msgrcv: 接收消息，支持按类型过滤 (正/负/零)
- msgctl: IPC_STAT/IPC_RMID/IPC_SET（mode 与属主 uid/gid）
- IPC_SET 缓冲区（`sysv_policy.readSetRequest`）：一个 u64 = 只改 mode（原有 ABI）；首字带 bit 63（`IPC_SET_EXTENDED`）时为
  三个 u64 `{mode|EXT, uid, gid}`，uid/gid 为 0xFFFFFFFF 表示不改。属主、创建者或 CAP_SYS_ADMIN 可以设置；创建者 uid/gid 不变，
  因此把对象交给别人后创建者仍可管理（与 Linux 一致）。
- 系统调用: #68 (msgget), #69 (msgsnd), #70 (msgrcv), #71 (msgctl)

### 5.6 POSIX 消息队列 ✅ (v18.0)

文件: `posix_mq.zig` (519 行)

- 16 个队列上限，8 消息/队列，512 字节/消息
- mq_open: 创建/打开队列，O_CREAT/O_EXCL/O_NONBLOCK/O_CLOEXEC；每次成功调用都分配独立的 open description 和 mqd token（当前 token 范围为 300..331）。描述符不属于 VFS `FdTable`，每个 task 最多持有 32 个 MQ handle，系统最多同时保留 256 个 open descriptions；耗尽时返回 `EMFILE`。
  `O_CREAT` 创建时传入的非空 `mq_attr` 必须完整可读；`mq_maxmsg`/`mq_msgsize` 必须为正且不超过
  内核上限（8/512），否则分别返回 `EFAULT`/`EINVAL`，不会静默回退到默认属性。未带
  `O_CREAT` 时 `mode/attr` 按 POSIX 约定忽略。
- mq_timedsend/timedreceive: 发送/接收消息 (带优先级；阻塞在 `task.WaitNode` 等待队列上，
  支持超时唤醒和按优先级出队（同优先级保持先入先出）。绝对超时的 `NULL` 表示不设截止时间；`{tv_sec=0,tv_nsec=0}` 是
  已到期的合法截止时间，非法指针或 timespec 返回 `EFAULT`/`EINVAL`，不会静默变成无限等待。
  接收缓冲区小于消息长度时返回 `EMSGSIZE` 并保留消息，不会静默截断后出队。
  发送和接收阶段都在 IRQ 自旋锁外执行用户空间拷贝；锁内只完成槽位 reservation，用户拷贝失败时取消 reservation 并保留队列状态。
- mq_unlink: 只删除名字空间查找项；已有 token 继续访问原 queue generation，直到所有 open descriptions 关闭且队列排空。之后 slot 才回收；同名 reopen 创建新的 queue generation，旧 token 不会通过 ABA 复用访问新队列。
- MQ descriptor 按 task handle 解析到带 queue slot、单调 queue generation、访问模式、`O_NONBLOCK`、`O_CLOEXEC` 的 open description；因此同一名字的两次 `mq_open` 有独立 mqd、访问权限和非阻塞状态。send/receive 分别检查 `O_WRONLY`/`O_RDONLY`，发送超过 `mq_msgsize` 返回 `EMSGSIZE`。
- 只有持有该 task handle 的 task 才能执行 MQ 操作或 `mq_close`。fork/clone 复制 handle 并共享同一个 open description（关闭任一引用只减少该 description 的引用计数）；这保持现有 inheritRefs 行为，但不声称实现 VFS `CLONE_FILES` 的完整跨表语义。task 退出时自动释放其 handles。
- `mq_getsetattr` 报告调用者自己的 `mq_flags`，坏的 newattr 指针返回 `EFAULT`，只允许改变 `O_NONBLOCK`。`O_CLOEXEC` 在 exec 地址空间切换前关闭当前 task 标记的 MQ handles；未标记的 handles 跨 exec 保留。
- mq_notify: 注册/注销通知
- mq_getsetattr: 获取/设置队列属性
- 系统调用: #186-191（与 x86_64 dispatcher 一致）

### 5.7 timerfd ✅

文件: `timerfd.zig`

### 5.8 POSIX 定时器 ✅ (v18.2)

文件: `posix_timer.zig` (374 行)

`TIMER_ABSTIME` 使用 timer 创建时选定的 clock domain：`CLOCK_REALTIME` 按墙上时钟
（RTC/`clock_settime` offset）解释，`CLOCK_MONOTONIC` 按启动后单调时间解释。到期时间以
`tsc.nanos()` 纳秒保存（`expiry_ns`），BSP 每个时钟中断按当前纳秒检查，所以定时器在到期后
一个 tick（约 10 ms）内触发，`timer_gettime` 报告精确到纳秒的剩余时间（hello288 R）。timerfd
同样按纳秒到期（hello291）。周期定时器按 `time_policy.forwardPeriodic` 保持相位。

定时器信号（hello292）：每个定时器同一时间只排一个信号（`posix_timer_policy.SigState`，Linux 每个定时器一个 sigqueue）。
siginfo 是 `SI_TIMER`，`si_timerid` 为定时器 id，`si_value` 为 `sigev_value`；信号被取走之前的到期都算作它的
`si_overrun`，在投递时（`signal.finishTimerInfo` → `posix_timer.takeSignal`）填入，同时成为 `timer_getoverrun`
的返回值（读取不清零，`timer_settime` 重新设定或解除时清零）。排队时 siginfo 的 overrun 位置暂存槽位代数，
定时器被删除后残留的信号报告 overrun 0。信号被忽略且未阻塞时不发送，到期继续计数，等不再忽略时的下一次到期补发。
`sigevent` 为空等同 `SIGEV_SIGNAL` + `SIGALRM`，`si_value` 是定时器 id。

- 16 个定时器上限，BSP 时钟中断驱动 (100Hz)
- timer_create: 创建定时器，支持 SIGEV_NONE/SIGEV_SIGNAL
- `timer_create` 在分配槽位前要求非空且可写的 `timerid` 用户指针；无效指针返回
  `EFAULT`，不会消耗 16 个定时器槽位中的任何一个。
  非空 `sigevent` 指针也必须完整可读；无效输入返回 `EFAULT`，不会静默降级为
  `SIGEV_NONE`。
- POSIX timer ownership 按进程/线程组记录；`CLONE_THREAD` 工作线程退出不会删除线程组定时器，只有线程组 leader 退出时才清理。

Clone Phase-0 safety gate：当前只接受已实现的 flags；`CLONE_THREAD` 必须与 `CLONE_VM`
  同时出现，`CLONE_SIGHAND`/`CLONE_FS` 仍返回 `EINVAL`；`CLONE_PARENT_SETTID` 在 child publish 前写回 child TID，`CLONE_CHILD_CLEARTID` 在 exit 时清零用户 word 并 wake private futex。其他未实现 flags 仍返回 `EINVAL`。

`clock_settime` 仅允许持有 `CAP_SYS_TIME` 的任务调用；它接受 `CLOCK_REALTIME`，要求
`tv_nsec < 1_000_000_000`，并拒绝纳秒总数无法表示为有符号 64 位值的输入。非法权限返回
`EPERM`，非法 clock ID、非法 timespec 或溢出返回 `EINVAL`。
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
| `computeExecCaps(parent, child)` | 旧接口，execve 不再使用；execve 走 `cred_policy.afterExec`（见下） |

**syscall 检查点集成**

- `kill`：要求 `CAP_KILL`
- `bind`（特权端口 <1024）：要求 `CAP_NET_BIND_SERVICE`
- `setuid`/`setgid`/`setreuid`/`setregid`/`setresuid`/`setresgid`（`proc/cred_policy.zig`）：设成任意 ID 要求 `CAP_SETUID`/`CAP_SETGID`；
  没有时只能在自己现有的 real/effective/saved ID 之间切换（euid 为 0 本身不授权）。uid 变化后 capability 按 capabilities(7) 调整：
  r/e/s 中原本有 0、变化后都不为 0 → 清空 permitted 和 effective；euid 0→非 0 → 清空 effective；euid 非 0→0 → effective 恢复为
  permitted。real uid 变化时 RLIMIT_NPROC 的按 uid 计数随之迁移。
- 特权只看 capability，不看 uid：文件 DAC（ext2/tmpfs/只读卷，`fs/dac.zig`、`fs/rofs_access_policy.zig`）用 `CAP_DAC_OVERRIDE`，
  chmod/sticky 目录删除用 `CAP_FOWNER`，chown 用 `CAP_CHOWN`，SysV IPC 用 `CAP_SYS_ADMIN`，POSIX MQ unlink 用 `CAP_DAC_OVERRIDE`，
  nice/调度用 `CAP_SYS_NICE`，kcmp 用 `CAP_SYS_PTRACE`。root 启动时持有全部 capability，因此行为不变；用 `capset` 或降权丢掉
  capability 的 uid 0 进程与普通用户一样受权限位约束。
- execve（`cred_policy.afterExec`）：saved uid/gid 改为有效 uid/gid；程序没有 set-user-ID 位和文件 capability，所以按 capabilities(7)
  的 root 规则：real 或 effective uid 为 0 时 permitted 保留、effective 在 euid 为 0 时等于 permitted，否则为空；两者都不为 0 时
  permitted 和 effective 都清空。
- mseal(2)（#462，`mm/mseal.zig`、纯规则 `mm/mseal_policy.zig`）：封印记录在地址空间对象 `Mm.seals`（最多 32 段，CLONE_VM 兄弟共享，
  fork 复制给子进程，exec 新建地址空间时清空）。被封印范围内 munmap、mprotect、mremap（源或 MREMAP_FIXED 目标）及 MAP_FIXED 覆盖
  一律 EPERM（与封印部分重叠的请求整体拒绝），读写不受影响；MADV_DONTNEED 对封印的私有匿名只读页 EPERM，可写页照常丢弃。参数：flags 非 0 或地址未对齐为 EINVAL，len=0 为空操作，
  范围中有未映射页或封印表满为 ENOMEM。hello120 回归门。
- memfd_create(2)（`fs/memfd_policy.zig`、`tmpfs.tmpfsCreateAnonymous`）：无目录项、出生即 unlinked 的 tmpfs 普通文件，最后一次 close
  释放；flags 只接受 MFD_CLOEXEC/MFD_ALLOW_SEALING；名字 ≤ 249 字节。fcntl F_ADD_SEALS/F_GET_SEALS：SEAL/SHRINK/GROW/WRITE
  （FUTURE_WRITE 同 WRITE），在 tmpfs 写入/截断内部执行；无 MFD_ALLOW_SEALING 的 memfd 与普通 tmpfs 文件为 F_SEAL_SEAL。
  有 WRITE 封印时新的共享可写 mmap 为 EPERM；存在共享可写映射时加 F_SEAL_WRITE 为 EBUSY。mprotect 不能把写封印文件的共享映射改成可写（EACCES；封印在映射前后加上都一样，按条目代号实时读取）。
- syslog(2)（`proc/syslog_policy.zig`）：读 64 KiB kmsg 环；READ_ALL 从上次 CLEAR 后读、READ 消费全局未读游标、READ_CLEAR/CLEAR/
  SIZE_UNREAD/SIZE_BUFFER；除 SIZE_BUFFER 外需 CAP_SYS_ADMIN；console 动作接受但无作用。
- prctl（`proc/prctl_policy.zig`）：`PR_SET_PDEATHSIG` 取 0 或 1..31，父进程退出时向非线程子进程发送（`exitTask` 收集、解锁后发送），
  fork 的子进程清零；`PR_SET_NO_NEW_PRIVS` 只能置 1（参数必须为 1,0,0,0），fork/clone 继承、exec 保留，目前不改变 execve 结果
  （没有 set-user-ID 程序和文件 capability）。
- 补充组（`proc/group_policy.zig`）：`getgroups`(#487)/`setgroups`(#488，本系统编号；需要 `CAP_SETGID`，最多 32 个)。
  fork/clone 继承、execve 保留。属于有效 gid 或任一补充组即选中权限位的组类（ext2/tmpfs/只读卷 DAC、SysV IPC）；文件属主可把文件的组改成
  自己所属的任一组。
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
- 操作：READ / WRITE / FLUSH / DISCARD
- TRIM/discard (G5)：特性协商时检查 `VIRTIO_BLK_F_DISCARD`（bit 13），
  设备提供则在 driver features 中回写并接受；`discard(lba, count)` 经同一
  `io_lock` 提交路径下发 `VIRTIO_BLK_T_DISCARD`(8) 请求（desc0=头部，
  desc1=16 字节 `virtio_blk_discard_write_zeroes` 段，desc2=状态字节）。
  设备不提供该特性时 `discard()` 为 no-op（返回 0）。QEMU 需给
  virtio-blk 设备加 `discard=on` 才会提供该特性，默认不开启。

### 6.2b Virtio-net ✅ TX single-flight 锁契约（2026-08-15）

文件: `virtio_net.zig`, `virtio_net_queue.zig`

- Legacy virtio PCI（I/O port 基），RX/TX 两条独立 virtqueue（队列 0/1），
  中断驱动 RX + 同步 TX（submit + poll 完成）
- **TX single-flight（6.36）**：`sendPacket` 从任意 CPU 进入（用户任务 TX vs.
  写回/定时器 TX），同时改写共享 TX free list/描述符链/avail 环/完成索引。
  现以 `tx_lock: IrqSpinlock` 覆盖整笔事务（alloc → publish → notify →
  同步 reclaim），`defer` 释放；失败路径在持锁下回滚队列状态。同
  virtio-blk 的 `io_lock`（全请求串行）与 NVMe 的每队列 `io_locks`。
- **RX 无锁（审计结论）**：`processRxQueue` 仅由 ISR 单所有者调用，且操作
  独立 rx_queue；与 TX 加锁只引入假依赖并让整笔 TX poll 关中断。若未来引入
  多队列或非 ISR RX 拉取，需先补 per-queue 锁/所有权契约（review §6.36）。
- **队列记账纯模块**：`virtio_net_queue.zig` 承载
  `init`/`allocDescriptor`/`freeDescriptor`/`publishAvail`/
  `recordCompletion`/`recycleRx` 与 single-flight 不变量，host 可测
  （8 个测试锁定唯一性/边界/单步进/回滚），经 `host_test.zig`/`tests/main.zig`
  接入 `zig build test`

### 6.4 AHCI/SATA ✅

文件: `ahci.zig`

- HBA 寄存器 / 端口寄存器框架、命令列表 / FIS 框架
- 实际 I/O 路径已验证（6.32）：NCQ 读写（READ/WRITE FPDMA QUEUED）+
  legacy DMA 轮询回退、TRIM、FLUSH CACHE；MSI 中断（向量 241）加速 +
  寄存器轮询兜底（丢中断/启动早期退化为轮询，不会挂死，同 NVMe 哲学）
- boot 自测：qemu_run.sh 挂 ich9-ahci + scratch SATA 盘并盖戳
  `MoQiAHCI`；内核读 sector 0 验模式，匹配才继续写 sector 1 + flush +
  读回（真机外来盘永不写）。smoke 门禁标记
  `[ahci] boot write+readback verified`
- 6.32 修复：NCQ FIS 寄存器映射错误（扇区数应在 Features cfis[3]/[11]、
  tag 在 Count cfis[12]，原代码写反导致设备按 65536 扇区解释被 QEMU
  拒绝）；`io_sched` 软件电梯层删除（submit/dispatch 从未接线属死代码，
  tryMerge 合并后 DMA 范围超出缓冲区的缺陷随层移除；NCQ 硬件队列已
  取代软件排序）

### 6.5 PS/2 键盘 ✅

文件: `keyboard.zig`

- IRQ1 中断
- Scancode set 1 → ASCII
- 修饰键（Shift/Ctrl/Alt）状态

### 6.6 NVMe SSD (Admin/IO Queue + PRP + MSI-X) ✅

文件: `nvme.zig`, `pci_msix.zig`, `pci.zig` (MSI-X 部分)

- PCI枚举发现NVMe设备
- Admin Queue + IO Queue初始化（Admin 保持轮询，仅初始化期使用）
- Doorbell机制通知控制器
- PRP（Physical Region Page）分散/聚集
- readSectors / writeSectors / flush 接口；flush 使用 NVM opcode `0x00`，completion status 非零返回失败。
- MSI-X 中断驱动完成（I/O 队列）：每队列一个向量（242..245），向量不足时
  多队列共享；MSI-X 不可用时回退到原有的轮询模式（行为完全不变）
- 提交路径：获取队列通道（channel，保证每队列最多一个命令在飞，PRP 页在
  DMA 期间不被重建）→ 提交 + 敲 Doorbell → 释放锁后在 WaitNode 上睡眠，
  ISR 收割 CQ 并唤醒提交者；等待有界（NVME_WAIT_TIMEOUT_MS=500ms），每次
  唤醒直接收割 CQ 作为丢中断回退，不会挂死
- 锁序：`io_locks[q]` → `task_lock`（经 unblockTask）。`io_locks[q]` 保护
  SQ/CQ 指针、PRP 重建、通道所有权与等待链表；睡眠前必释放，ISR 只取
  `io_locks[q]`，IRQ-off 临界区短，不会与被阻塞的提交者死锁
- 丢失唤醒防护：WaitNode 在持有 `io_locks[q]` 时挂链（ISR 在同一锁下收割
  并唤醒），模式同 sysv_sem
- I/O 队列选择（I3：per-CPU 绑定）：纯策略函数 `nvme_queue.pickQueue`
  （`kernel/drivers/nvme_queue.zig`，主机可测）。优先选提交者所在 CPU 的
  队列 `cpu_id % num_io_queues`——同一任务的连续提交落在同一队列上，
  避免跨 CPU 的 `io_locks[q]` 竞争，MSI-X 中断也打在提交 CPU 的向量上；
  首选队列通道被占用（`io_in_flight`，无锁快照 `busyChannelMask`，只是
  启发式提示，通道所有权仍由 acquireChannel 串行化）时回退到轮询计数器
  `io_queue_rr`，提交者因此散开而非停在一个队列上其余队列闲置。CPU id
  经 `arch.syscall.getPerCpuOrNull()` 读取（x86_64 早期启动 GS 未安装时
  回退 CPU 0 → 队列 0；aarch64/riscv64 端口恒为 CPU 0）。内核线程——主要
  是 writeback 守护线程（vfs.startWritebackThread，其 flush 经
  writeback.flushExpiredByFs → FS 写回调 → block_dev → writeSectors 到达
  本驱动）——显式绑定到队列 0：单线程绑定可避免它随调度落在不同 CPU 上
  扰乱用户任务的 per-CPU 分布；队列 0 忙时回退逻辑仍允许它使用其他队列
- 启动自检：MSI-X 启用后做一次中断驱动的扇区 0 读取，并校验 qemu_run.sh
  写入镜像首扇区的 "MoQiNVMe" 模式串
- TRIM/discard (G5)：Identify Controller 的 ONCS（byte 520）bit 2 检测
  Dataset Management 支持，支持时启动打印 `[NVMe] TRIM supported`；
  `trimSectors(lba, count)` 在普通 I/O 队列上下发 DSM 命令（opcode 0x09，
  CDW10=NR(0-based)、CDW11 bit2=AD/deallocate），单个 16 字节 range
  （cattr/len/slba）放在 PMM 页内经 PRP1 传给控制器，走与读写完全相同的
  通道所有权（acquireChannel/submitIoCmd）路径

### 6.7 PCI MSI/MSI-X (Capability List + 向量分配) ✅

文件: `pci.zig`, `pci_msix.zig` (纯解析，可主机测试)

- Capability List遍历发现MSI/MSI-X能力（`pci.findCapability`）
- MSI 32bit/64bit配置（AHCI 使用，向量 241）
- MSI-X：能力解析（表 BIR/偏移、PBA）、表 BAR 经 HHDM 映射、按向量编程
  表项（地址=LAPIC base 0xFEE00000 固定投递，数据=IDT 向量）、去掩码、
  使能 MSI-X 并禁用 INTx（`pci.msixLocate/msixProgramVector/msixEnable`）
- `pci_msix.zig` 为无 MMIO 依赖的纯解析模块（capability 遍历、N-1 表大小
  解码、消息地址/数据组合），由 `tests/main.zig` 经 `kernel/host_test.zig`
  做主机单元测试

### 6.8 virtio-net 网卡 ✅ Virtqueue RX/TX + 轮询接收

文件: `virtio_net.zig`, `virtio_queue_layout.zig`（环布局算术）, `virtio_net_queue.zig`（TX 记账）

- Virtio Legacy PCI 接口 (vendor 0x1AF4, device 0x1000)
- RX 队列 (queue 0) 与 TX 队列 (queue 1)：按设备报告的大小（QEMU 默认 256，驱动最大 256）
- 环内存是**一块物理连续内存**（`pmm.allocContiguous`）：legacy 设备只拿到一个 PFN，按自己报告的队列大小在固定偏移找 avail 环（紧跟描述符表）和 used 环（avail 之后的下一个 4 KiB 边界）。256 项 = 描述符 4096 B、avail 偏移 4096、used 偏移 8192、共 3 页；偏移由 `virtio_queue_layout.zig` 按 `vq.num` 计算，不再写死
- RX：每个缓冲 = 头描述符 + 数据描述符两个描述符，所以 N 项队列预置 N/2 个缓冲
- 接收走**轮询**：`virtio_net.receivePacket(buf, max)` 取一帧、拷出、回收描述符并通知设备，`net/nic.zig:receivePacket` 对 e1000 和 virtio-net 都调用它（`pumpRx`/raw socket 都经 `nic.zig`）。PIC 上 NIC 的中断线是屏蔽的，所以中断路径（`handleInterrupt`，同样用 `receivePacket`）实际上不是帧的来源
- TX 同步发送，`tx_lock` 保护整个事务；RX 用 `rx_lock`（ISR 与轮询点可能同时进入）
- virtio_net_hdr: 10 字节头部 (flags, gso_type, checksum)
- 内存屏障: `asm volatile("" ::: .{ .memory = true })` 替代 @fence
- PCI 配置: Bus Master + INTx 启用
- 选用：`MOQI_NIC=e1000`（默认）| `virtio` | `both`（`tools/qemu_run.sh`）；两块卡都在时 e1000 优先

**API**: `init()` / `isActive()` / `getIrqLine()` / `handleInterrupt()` / `sendPacket()` / `receivePacket()`

### 6.9 块设备抽象层 (block_dev) + TRIM 路由 ✅ (G5)

文件: `block_dev.zig`, `lib/trim_ranges.zig`

- `discard(lba, count)`：路由到文件系统实际所在的活动设备（virtio-blk
  disk 0，fat32/ext2 唯一直接寻址的磁盘；无 virtio-blk 注册时回退到第一个
  活动设备，NVMe/AHCI 路径保持可达）。目标驱动不支持 TRIM 时 no-op
  （返回 0），I/O 错误返回 -1
- AHCI 分支把单个范围编码为现有 `trim()` 的 8 字节打包格式（低 2 字节
  扇区数、高 6 字节起始 LBA），超过 65535 扇区自动拆分
- `lib/trim_ranges.zig`：纯逻辑模块（无依赖，主机可测），把文件系统
  释放路径产出的零散 extent 排序合并成最大连续 discard 范围
  （相邻/重叠合并、零长度丢弃），fat32/ext2 各用 64 槽静态缓冲积攒后
  批量下发
- 锁序：discard 与现有 FAT/位图 I/O 一样在 `fs_lock` 下执行（
  `fs_lock` → 驱动 `io_lock`，单向）；writeback flush 规则（writeback
  调用前释放 `fs_lock`）不适用，因为 discard 不会重入文件系统

### 6.10 用户态驱动框架 v1（L1）✅

文件: `kernel/drivers/userdrv.zig`（内核胶水）、`kernel/drivers/userdrv_core.zig`
（纯逻辑，主机单测）、`user/hello51.c`（端到端运行时验证）

持有 `CAP_SYS_RAWIO`（`SysCap` bit 16，`ALL_CAPS` 默认包含）的任务可以把
PCI 设备完全搬到用户态驱动。系统调用号 #477–#482（MoQiOS 自定义，接在
F3 的 #473–#476 之后）：

| 号 | 调用 | 语义 |
|----|------|------|
| 477 | `dev_map_mmio(phys, size)` | 映射设备 MMIO 窗口到调用者地址空间，返回用户 VA |
| 478 | `dev_irq_register(gsi)` | 认领一条 legacy IRQ 线（GSI 0–15） |
| 479 | `dev_irq_wait(gsi, timeout_ms)` | 阻塞等待中断沿；返回沿计数增量，超时 `-ETIMEDOUT`，信号 `-EINTR` |
| 480 | `dev_irq_unregister(gsi)` | 释放并重新屏蔽该 IRQ 线 |
| 481 | `dev_dma_alloc(size, out_ptr)` | 分配物理连续 DMA 缓冲并映射到用户态，向用户结构体写 `{user_va, phys}` |
| 482 | `dev_dma_free(user_va)` | 释放 DMA 缓冲（解除映射 + `dma.freeCoherent`） |

`/dev/pci`（新 `FdType.pci=19`）提供只读 PCI 枚举快照，procfs 风格每次
read 重新生成：`00:03.0 8086:100e class=02:00 irq=11 bar0=febc0000+00020000`
（BAR 为 `<物理地址>+<大小>` 十六进制，0 值 BAR 省略）。open 处检查
`CAP_SYS_RAWIO`。

**MMIO-vs-RAM 校验设计**：`pmm.isRamPhys(phys)` 是无锁启发式谓词——命中
启动 memmap 记录的 RAM 类范围（usable / kernel_and_modules /
bootloader_reclaimable / acpi_reclaimable，`pmm.init` 时录入最多 48 条）
或位图内空闲/已分配帧即判为 RAM。MMIO 空洞（PCI BAR、LAPIC/IOAPIC 窗口）
在 memmap 中是保留区、从不进入位图管理，因此判为非 RAM 放行。
`dev_map_mmio` 先过 `validateMmioRequest`（size ∈ (0, 16MiB]、phys 页对齐、
phys+size 不回绕），再逐页 `isRamPhys` 拒绝（`-EACCES`）。已知限制：
framebuffer 若被 Limine 报为 usable 则同样被拒绝（v1 不接受）；
谓词对「memmap 未如实报告」的 RAM 无能为力。

**no_free 记账（最危险的账目点）**：MMIO 帧不是 PMM 帧，绝不能进空闲池。
`MmapRegion` 新增 `no_free` 标志，`dev_map_mmio`/`dev_dma_alloc` 经
`mmap.trackNoFreeRegion` 登记（同时 `locked=true` 防换出）；
`unmapRange` 对 no_free 区域的页只解映射不 `freePageBatch`；
`trackMmapRegion` 的匿名合并跳过 no_free 邻居；`untrackMmapRange`
分裂时向两侧传播该标志。fork 的 COW 克隆对 `!isRamPhys` 帧跳过
addRef 与 COW 降级（原样复制 PTE，父子共享设备映射）。退出/exec 时
`userdrv.cleanupTask(t, pml4)`（挂在两个 reap 点与 execve 换址前）
解映射全部 no_free 页、释放 IRQ 注册与 DMA 缓冲，因此
`destroyUserSpace` 的页表遍历永远看不到设备帧；即便漏网，
`freePageBatch` 对 refcount==0 的帧静默跳过兜底。

**IRQ 路径**：GSI 0–15 走 PIC 路由（向量 32+gsi），行为与 v1 完全一致；
GSI ≥ 16 经 IOAPIC 路由到用户向量窗口 100–127（见 6.11）。内核占用线
（键盘 1、级联 2、活动 e1000/virtio-net 的 IRQ）拒绝注册（`-EBUSY`）。
`idt.handleIrq`（PIC）与 100–127 分发分支（IOAPIC）都先查 userdrv 表：
命中则计边沿 + EOI + 跳过内核驱动处理程序。等待用 TSC 纳秒截止 +
`sti; hlt` 轮询（沿用 waitpid 模式），信号走
`pendingFatal`/`pendingActionable` 协议。

运行时证明 `hello51`：读 `/dev/pci` 找到 e1000 → 映射 BAR0 → 读
STATUS(0x0008) 非零、RAL/RAH(0x5400/0x5404) 回读 MAC ==
52:54:00:12:34:56（内核启动时打印的值）→ 内核占用 GSI 注册返回
`-EBUSY`、空闲 GSI 10 注册/50ms 超时（`-ETIMEDOUT`）/注销语义 →
DMA 分配/校验/释放 → munmap MMIO。标记：`hello51: PASS` / `hello51 done`。

### 6.11 IOAPIC ✅

文件: `kernel/arch/x86_64/ioapic.zig`（MMIO 胶水）、
`kernel/arch/x86_64/ioapic_core.zig`（REDTBL 项编码/解码纯逻辑，主机单测）

初始化在 `main.zig` 中 ACPI 解析之后、`smp.init` 之前：用 MADT 记录的
`ioapic_address`/`ioapic_gsi_base`（`acpi_parser.zig`）经 HHDM 映射 MMIO
窗口，读 ID/VER 取得重定向项数（VER[23:16]+1），全部项初始屏蔽，启动
日志 `[IOAPIC] initialized (N entries)`。`ioapic_address == 0` 时记
`[IOAPIC] not present (PIC-only)` 并保持不可用，所有调用方回退 PIC
行为。

- 寄存器接口：IOREGSEL(0x00)/IOWIN(0x10) 间接寻址；REDTBL 项 i 在
  0x10+2i（低 32 位）/0x11+2i（高 32 位）。
- `routeGsi(gsi, vector, dest_apic_id)` / `maskGsi` / `unmaskGsi`：
  固定投递、物理目标、边沿触发、高电平有效。**MADT ISO（type 2 中断源
  覆盖）未解析**——`acpi_parser` 只存 IOAPIC 地址与 GSI 基址，不存覆盖
  表，因此所有线按边沿/高电平编程；GSI 0–15 仍走 8259A PIC 路径不受
  影响。
- userdrv 扩展：`dev_irq_register` 的可路由上限从 16 提升到
  `min(gsi_base + 重定向项数, 44)`（`maxRoutableGsi`）；GSI ≥ 16 映射到
  向量 `100 + (gsi - 16)`（窗口 100–127，与 LAPIC 定时器 240、AHCI
  241、NVMe MSI-X 242–245、yield 252、IPI 253/254 均不冲突），目标为
  BSP LAPIC。IDT 对向量 100–127 的分发调用
  `userdrv.handleUserIrq(gsi)` 计边沿后向 LAPIC 发 EOI（绝不写 PIC
  端口）。注销/任务退出时在 IOAPIC 侧重新屏蔽。

### 6.12 ioperm（TSS I/O 位图）✅

文件: `kernel/proc/ioperm.zig`（系统调用胶水）、
`kernel/proc/ioperm_core.zig`（位图纯逻辑，主机单测）、
`kernel/arch/x86_64/gdt.zig`（每 CPU TSS 块内 IOPB 存储与切换时拷贝）、
`user/hello52.c`（端到端运行时验证）

系统调用 **#483 `ioperm_set(port, count, enable)`**：校验
`port+count ≤ 65536` 且 `count ≥ 1`（`-EINVAL`），`CAP_SYS_RAWIO` 门控
（`-EPERM`），置位/清除调用者 I/O 位图中的对应位（位=1 表示拒绝，
硬件语义）。编译期开关 `ioperm_enable: bool = true`（置 false 时系统
调用返回 ENOSYS，所有 TSS IOPB 保持全 1 默认，行为与引入本特性前完全
一致）。

**安全模型**：

- 默认拒绝：无位图的任务对任何端口 I/O 触发 #GP（每 CPU TSS 块内 IOPB
  初始化为全 1，含末尾 0xFF 哨兵字节；用户 rflags=0x202，IOPL=0，位图
  是唯一授权机制）。
- 位图惰性分配：首次 `ioperm_set` 时分配 2 个 PMM 页（8192 字节），
  存于 `Task.io_bitmap`。
- **切换时加载点**：硬件 iomap_base 是 TSS 基址的 u16 偏移，无法指向
  PMM/HHDM 分配的任务位图，因此 IOPB 固定在每 CPU TSS 块内
  （`gdt.zig` 的 `tss_blocks`，iomap_base=104），每次上下文切换把
  传入任务的位图**拷贝**进去（`ioperm.loadForTask` →
  `gdt.loadIoBitmap`，仿 Linux `tss_copy_io_bitmap`）。加载与 TSS
  RSP0 更新严格同点：`sched.setupUserCpuState`、`sched.tryStealTask`、
  `execve`（execve 与 execveat 共用 `prepareExecName`）、`waitpid` 唤醒恢复、
  `syscall_entry.prepareSyscallCpu`（惰性再同步）。漏掉任何一处都会把
  前一个任务的端口权限泄漏给下一个任务。`ioperm_set` 本身在改完位图后
  立即刷新当前 CPU 的活副本。
- fork 语义：子进程继承位图的**独立副本**（`inheritForFork`，分配失败
  时子进程回退全拒绝并告警，不阻塞 fork）。
- 退出语义：任务收割分两段——`reapZombies` / waitpid 在 `task_lock` 下 O(1) 摘链，
  地址空间、驱动状态和内核栈由 `proc/reaper.zig` 内核线程在开中断下释放（`freeBitmap`
  仍与 `userdrv.cleanupTask` 并列，只是改在 `teardownResources` 里调用）；execve 保留位图
  （同 Linux ioperm 语义）。

运行时证明 `hello52`：授予 0x70/0x71 → 读 RTC 秒寄存器并验证合法 BCD
（≤0x59、低半字节 ≤9）→ fork 子进程继承权限读成功（退出码 0）→ 撤销
后 fork 的子进程访问 0x71 被 #GP 杀死，waitpid 状态 == 141（本内核
`exitTask(128+向量号)`，#GP 为向量 13）。标记：`hello52: PASS` /
`hello52 done`。

### 6.13 /dev/fb0 + /dev/fbinfo（帧缓冲设备节点 + mmap）✅

文件: `kernel/fs/devfs_nodes.zig`（节点注册与 ops）、
`kernel/drivers/fbdev.zig`（mmap 路径）、
`kernel/drivers/framebuffer.zig`（getPhysBase/getSize/rawBuffer/present
访问器）、`kernel/mm/mmap.zig`（fb0 fd 分支）、
`user/hello56.c`（端到端运行时验证）

- `/dev/fb0`：read = 按 fd 偏移读帧缓冲字节（上界 pitch×height）；
  write = 按偏移写像素；poll 恒就绪（POLL_IN|POLL_OUT）。无 Limine
  帧缓冲时 open/read/write/poll 全部返回 `-ENODEV`。
- `/dev/fbinfo`：几何查询。devfs 没有 ioctl 通道，故选用一个只读小
  节点而非 ioctl 式 op（更简单的方案）：read 返回一行 ASCII
  `"WxH pitch bpp\n"`（如 `1024x768 4096 32\n`），按偏移服务，同
  /dev/pci 快照模式。
- **mmap 集成点**：`mmap()` 在校验 fd 类型时识别 devfs fd 且
  `devfs_idx == devfs_nodes.fb0NodeIdx()`，转 `fbdev.mmapFb`。
  **不走 dev_map_mmio**——Limine 帧缓冲位于可用 RAM，`pmm.isRamPhys`
  会拒绝。fbdev 路径：要求 MAP_SHARED（私有映射无意义）、偏移页对齐、
  长度不越界；把 fb 物理帧**急切**共享可写映射进调用者（write-through），
  每帧 `pmm.addRef` 钉住（分配器跳过 ref>0 的帧），区域以
  `trackNoFreeRegion` 登记——munmap/退出时 unmapRange 跳过 no_free 页，
  帧永不归还 PMM；addRef 是刻意的永久设备内存钉（unmap 既不 free 也不
  decRef，PMM 记账保持平衡）。

### 6.14 fbcon（帧缓冲文本控制台）✅

文件: `kernel/drivers/fbcon.zig`（帧缓冲 + 锁的胶水）、
`kernel/drivers/fbcon_core.zig`（纯单元格/光标/滚屏逻辑，主机单测）、
`kernel/drivers/fbcon_render.zig`（纯渲染器：增量绘制 + 延迟重绘，主机单测）、
`kernel/drivers/fbcon_font.zig`（内嵌 VGA 8x16 字体，ASCII 32-127，
数据源自 XFree86 vga.bdf，经 ReactOS FreeLoader，GPL-2.0-or-later）、
`kernel/arch/x86_64/serial.zig`（挂接点）

- **挂接点**：x86_64 `serial.writeString`/`writeByte` 在 UART 输出之后
  调 `fbcon.writeString`——纯增量，串口仍是主控制台；锁序
  serial → fbcon，fbcon 绝不回调串口。`fbcon_enable` 运行期开关。
- 渲染路径零分配（IrqSpinlock，IRQ 安全：klog 可在中断上下文经串口
  路径到达）；无帧缓冲或非 32bpp → init 置 no-op。
- **写路径 O(字节数)（2026-10）**：只绘制变化的单元格（只写显存）；滚屏只置
  `repaint_pending`，从不在帧缓冲内搬移像素。原实现每个换行都在关中断的串口路径里
  把整屏（1280x800 约 4 MB）逐字节上移，读回显存是 CPU 对它最慢的访问——QEMU 下
  每行约 100 ms，所有内核日志和 `write(1)` 都要付这笔账，还会算进当前任务的 CPU 时间。
- **延迟重绘**：内核 idle 循环调用 `fbcon.idleFlush()`，每持一次锁按单元格网格重绘
  一行文本，行间开中断，被唤醒的任务可在行间抢占；两次重绘之间的任意次滚屏合并为
  一次。控制台安静 20 ms（`fbcon_render.QUIET_NS`）后才重绘，写入期间 idle 重绘让路，
  不与写者争锁。`requestRepaint()` 供 fb0 映射者退出后恢复镜像；panic 路径用无锁的
  `panicFlush()` 立即补画（idle 不会再运行）。
- 双缓冲可用时渲染进 back_buffer，写入/重绘完成时 `present()` 交换。光标为两条
  扫描线的下划线。
- 语义：`\n` 含回车（串口输出从不发 `\r`）、`\t` 以空格填到下一个 8 列制表位（或
  行尾），满行则折行，并以 `Effect.rows` 报告被清空的行、`0x08` 退格不擦除、
  行尾自动折行、末行滚屏。

### 6.15 PS/2 鼠标（IRQ12 + /dev/mouse）✅

文件: `kernel/drivers/mouse.zig`（纯 PacketAssembler/decodePacket 主机
单测 + 驱动胶水）、`kernel/drivers/ps2.zig`（0x60/0x64 端口共享锁）、
`kernel/drivers/keyboard.zig`（init 改用 ps2 锁）、
`kernel/arch/x86_64/idt.zig`（IRQ12 分发）、
`kernel/fs/devfs_nodes.zig`（/dev/mouse 节点）

- **端口协调**：i8042 的 0x60/0x64 由键盘与鼠标（aux）通道共享。
  `ps2.zig` 提供 IrqSpinlock + 有界 waitWrite/waitRead + 控制器命令/
  aux 命令（0xD4 前缀 + ACK）助手；keyboard.init 与 mouse.init 的命令
  序列都在锁内完成——持锁期间本 CPU 屏蔽 IRQ，键盘 IRQ 处理器不可能
  在序列中途抢走鼠标的 ACK 字节。
- init 序列：使能 aux 口（0xA8）→ 读配置字节（0x20），置 bit1
  （IRQ12 使能）、清 bit5（aux 时钟运行），写回（0x60）→ aux 设默认
  （0xF6）→ 采样率 100（0xF3）→ 使能数据上报（0xF4）；全部有界等待，
  无设备时记录日志并退出（IRQ12 保持屏蔽）。成功后解除 PIC 屏蔽：
  主片 bit2（级联）+ 从片 bit4（IRQ12）。
- IRQ12 字节经 PacketAssembler 组 3 字节包（首字节 bit3 必置位，
  否则丢弃重同步——协议唯一的带内帧界），decodePacket 解出
  {buttons, dx, dy}（bit4/5 符号扩展为 9 位后钳入 i8；Y 轴取反，
  向上为正），入 64 项定长环（满则丢）。
- `/dev/mouse`：read 出队 4 字节事件记录 `[buttons, dx, dy, 0]`；
  空队列时 O_NONBLOCK 返回 0，否则短暂有界阻塞（≤100 次
  forceReschedule 让出循环，无等待队列——最简阻塞镜像）；poll 报
  POLL_IN；未探测到鼠标返回 `-ENODEV`。

### 6.16 RTC 墙上时钟（gettimeofday/CLOCK_REALTIME 真时间）✅

文件: `kernel/drivers/rtc.zig`（BCD→epoch 纯逻辑主机单测 + CMOS 读取）、
`kernel/proc/time_syscall.zig`（wall_clock_offset 播种、clock_gettime
按 clockid 分流）、`kernel/arch/x86_64/syscall_entry.zig`（228 号调用
传入 clockid）

- 启动时经 0x70/0x71 读 RTC 寄存器（有界等待 update-in-progress 清除；
  卡死则保持启动相对时钟）。寄存器 B bit2 区分 BCD/二进制，bit1 区分
  24/12 小时制（12 小时制按 PM 位换算）。
- **世纪规则**：RTC 年份为两位 BCD；00-69 → 2000-2069，70-99 →
  1970-1999（Unix 经典支点）。不信任 CMOS 世纪寄存器 0x32（QEMU 与
  多数固件不设置）。
- epoch 基准 = `dateTimeToEpoch`（Howard Hinnant days_from_civil），
  随后 `wall_clock_offset = epoch_ns - tsc.nanos()`——与 clock_settime
  同一形状，此后 gettimeofday / clock_gettime(CLOCK_REALTIME) =
  epoch 基准 + TSC 单调内插，不再触碰 RTC。
- `clock_gettime` 现在按 clockid 分流：CLOCK_REALTIME(0) 走墙上时钟；
  其余 id（含 CLOCK_MONOTONIC）保持原始 TSC 启动相对时间，行为与
  引入 RTC 基准前一致。

运行时证明 `hello56`（6.13-6.16 联合）：fbinfo 解析几何 → fb0 mmap
写 40×40 可识别像素块并经 pread 逐字节校验 → /dev/mouse 空读
O_NONBLOCK 返回 0 → gettimeofday tv_sec > 1577836800（2020-01-01）且
gettimeofday 与 CLOCK_MONOTONIC 各 10000 次循环单调不减。标记：
`hello56: PASS` / `hello56 done`。

---

## 7. 同步原语

源码: `kernel/sync/`

### 7.1 IrqSpinlock ✅（2026-10 起为公平 ticket 锁）

文件: `irq_spinlock.zig`、核心 `ticket_lock.zig`

```zig
const Ticket = struct { next: u32 = 0, serving: u32 = 0 }; // 空闲 ⇔ next == serving
const IrqSpinlock = struct { ticket: Ticket = .{} };
```

`acquire` 先关中断再取号（同 CPU 的中断不可能排在被它打断的持有者后面），
按号 FIFO 等待；`release` 只由持有者写 `serving`（load + release store，不会向
`next` 进位），再还原 RFLAGS.IF。`tryAcquire` 只在锁空闲（`next == serving`）时
用一次 CAS 取号，永远不会插队。32 位回绕计数，Debug 构建对释放未持有的锁断言。

同一核心也用于 `ServicingSpinlock`（`Mm.vm_lock`，等待时代为处理 TLB shootdown）
和 x86 `TlbLock`（shootdown 发起者串行化）。旧实现是 test-and-set：谁的 Xchg 先
到缓存行谁赢，SMP 争用下等待时间无上界；ticket 锁把最坏等待限定为排在前面的持有者。
代价：虚拟化环境下被宿主抢占的排队者会挡住后面的人（lock-waiter preemption），
QEMU/TCG 的 SMP=2 冒烟中未观察到影响（`hello107`）。

### 7.2 TicketSpinlock ✅

文件: `ticket_spinlock.zig` —— 现为 `IrqSpinlock` 的别名（原独立实现无树内使用者）。

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

验证：`MOQI_SMP=1` 与 `MOQI_SMP=2` 均完整跑通 `init` 自动序列（至 `hello42 done`）+ `MoQiOS shell`。

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
pub fn shootdownRange(addr_start: u64, page_count: u32, target_cr3: u64) void
```

`target_cr3` 是目标（受害者）地址空间的 `page_table_phys`；传 0 表示「未知 / 内核半区」，
向所有在线 CPU 发送。逐 CPU 读取 `PerCpu.current_cr3`
（`syscall_entry.percpu_array[cpu].current_cr3`），凡已记录且与 `target_cr3` 不同的 CPU
整体跳过——不发 IPI、不 flush、不占 `completion` 名额。被跳过的 CPU 之后切入该 CR3 也安全：
上下文切换时的 CR3 加载会失效全部非 global TLB 项（用户页从不 global）。

**结构**

- 单一全局请求槽 `shootdown_req: TlbShootdownReq`（`addr_start` / `page_count` /
  `target_cr3` / `target_mask` / `generation` / `completion` 原子计数器 / `active` 标志）。
- 多发起方串行化通过自定义 **`TlbLock`**（不是 `IrqSpinlock`）：等待时**保持关中断**（页故障
  处理路径可安全使用），并循环调用 `servicePendingShootdown` 手动服务在途广播，避免两个 CPU
  互相等对方接收 IPI 导致的跨核死锁。
- 向量号沿用既有 `TLB_SHOOTDOWN_VECTOR = 0xFE`。

**算法（发起方）**

1. 本地 `flushLocal(addr, n)`（≤32 页 → invlpg 循环；>32 页 → CR3 reload）。
2. 按 CR3 过滤构建 `target_mask`（见上）；无目标远端 CPU 时直接返回。
3. 持 `shootdown_lock`，发布请求到全局槽（含 `target_cr3` / `target_mask` / 递增的
   `generation`），把 `completion` 设为目标远端 CPU 数。
4. 按 `target_mask` 逐 CPU `lapic.sendIpi(apic_id, 0xFE)` 定向发送（不再全广播）。
5. 保持调用方 IF 状态不变，`pause` 自旋等 `completion == 0`（**不** `sti`：调用方含页故障
   处理路径，中断窗口会破坏 iretq 状态；在 `TlbLock` 中等待的 CPU 会经
   `servicePendingShootdown` 手动服务本次广播，故关中断等待不会死锁），随后释放锁。

**算法（IPI 接收方）**

1. 内联 EOI（直接写 LAPIC EOI 寄存器，避免在 IPI 快路径上拉入 lapic helpers）。
2. 不在 `target_mask` 内的 CPU 直接返回（不 flush 也不 ack）；按 `generation` 幂等去重。
3. acquire 加载 `addr_start` / `page_count`，调用 `flushLocal`。
4. `cmpxchg` 递减 `completion`（仅在非零时，防止重复/过期向量把计数绕回 UINT_MAX）。
5. **不获取任何锁**，仅原子，对中断重入安全。

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

## 12. 调试与日志

### 12.1 klog 与 kmsg 环形缓冲区 ✅（G4）

`kernel/klog.zig` 提供带级别前缀的日志接口（`log()` / `logHex()`，`setLevel()` 过滤）。
G4 之前仅输出到串口；现在每条通过级别过滤的日志行在写串口的同时，
追加到一个 **64 KiB 静态环形缓冲区**（`KMSG_CAP`），作为 `/dev/kmsg` 的数据源。

**环形设计**（`kernel/lib/kmsg_ring.zig`，纯逻辑、无 arch 依赖、可宿主测试）：

- 字节环 + 绝对流游标：`total` 记录历史追加总字节数，读游标是该流上的绝对位置；
  过期游标（`< total - len`）自动前移到最旧可用字节。
- 覆盖策略保留整行语义：追加放不下的行时，逐条丢弃最旧的完整行（含其 `'\n'`）
  直到放得下；单行超过整个缓冲区时只保留尾部（必然从行中间开始）。
- 物理回绕处 `read()` 返回短读，调用方按 `new_pos` 循环续读。

**ISR 安全性**：与 `serial.zig` 同一模式 —— 环形缓冲区由 `IrqSpinlock` 保护
（acquire 时屏蔽中断），中断上下文调用 `log()` 不会撕裂环状态；全程无分配。

**阻塞唤醒（J3）**：klog 持有一个 kmsg 等待队列（`kmsg_waiters`，`task.WaitNode`
单链表头，由 `ring_lock` 保护）。每次追加（`ringAppend`）在写入环之后、同一临界区内
`sched.wakeOne()` 唤醒一个阻塞读者。该唤醒是 ISR 安全的：`wakeOne`/`unblockTask`
只做标记 + 入队 per-CPU 运行队列（无分配），与回写线程 tick 在定时器 ISR 中唤醒
（`fs/vfs.zig` `writebackTimerTick`）是同一条已验证路径；锁序为
`ring_lock → task_lock/运行队列锁`，`proc/` 不回调 klog，无循环。
追加在释放 `ring_lock` 之后再调 `epoll.epollNotify(.kmsg, 0, EPOLLIN)`：
epoll 的 `collectEvents` 会在持有 `inst.spin` 时经 `kmsgHasUnread` 取 `ring_lock`，
若反向嵌套会构成锁序环。

### 12.2 /dev/kmsg ✅（G4；J3 阻塞读）

VFS 新增 `FdType.kmsg`（只读特殊文件，镜像 `/dev/urandom` 的接法）：

- `open("/dev/kmsg", O_RDONLY)`：fd 的 `offset` 即绝对环游标，0 = 从最旧可用字节开始。
- `read()`：从 fd 游标拷贝并推进（per-fd 独立游标）。**J3 起为阻塞语义**：
  追到最新字节（0 字节可读）且 fd 未设 `O_NONBLOCK`（`status_flags & 0x800`）时，
  读线程经 `klog.kmsgReadOrBlock()` 睡在 kmsg 等待队列上 —— 空检查与入队在
  `ring_lock` 同一临界区内完成，追加不会丢失唤醒（sysv_sem/posix_mq 同款模式）。
  被信号打断时按 waitpid 协议处理：`pendingFatal` 走 exit-by-signal
  （`exitTask(128 + sig)`），`pendingActionable` 返回 `-4`（-EINTR）让处理函数先跑；
  信号唤醒后必须用 `kmsgUnlinkWaiter()` 摘除仍在队列上的栈节点。
  `O_NONBLOCK` 保持旧行为：追到最新字节返回 0。
- `pread()`：按给定游标读，不动 fd 自身 offset，永不阻塞；`write()`/`pwrite()` 拒绝（只读）。
- epoll（J3）：`.kmsg` 的 `EPOLLIN` 不再恒报，而是按**该 fd 的游标**判定 ——
  `klog.kmsgHasUnread(cursor)`（底层是纯函数 `kmsg_ring.bytesAvailable(total, cursor)`，
  宿主可测）。游标从属 fd 的 `desc.offset`；`collectEvents` 经 epoll 实例属主的
  fd 表恢复游标，fd 已关闭/复用时按「无未读数据」处理。配合追加时的
  `epollNotify`，LT epoll 在追平后不再空转，新数据到达即醒。
- 运行时验证：`user/hello47.c`（读取全量并校验 `[INF] ` 前缀与
  `=== MoQiOS scheduler active ===` 启动行、二次打开游标独立、写入被拒）。
  注意：hello47 以「读到 0 为止」的方式 drain，阻塞语义下它需要在 open 时
  带 `O_NONBLOCK` 才能在追平后拿到 0。

### 12.3 syslogd ✅（J3 起事件驱动）

`servers/syslogd` 是 kmsg 消费者：打开 `/dev/kmsg` 循环**阻塞读**，追加写入
`/tmp/kern.log`（tmpfs，2.25 MiB 上限前单代轮换；2026-08-14 起旧 256 KiB 硬顶随一级
间接页扩容移除）。J3 之前内核不会阻塞，
daemon 以 `nanosleep(100ms)` 轮询；现在读本身在最新字节处睡眠，日志行追加即醒，
投递完全事件驱动，无轮询、无空转。

---

## 参考

- [moqios-architecture-current.md](./moqios-architecture-current.md)
- [build-and-toolchain.md](./build-and-toolchain.md)
- [user-space.md](./user-space.md)
- [moqios-design.md](./moqios-design.md)
**`sendmmsg/recvmmsg` bounded TCP contract**：当前仅支持既有 TCP `sendmsg/recvmsg` 路径，`vlen=0` 返回 0，单批最多 16 条；超限或非零 flags/timeout 返回 `EINVAL`，首条失败返回 errno，已有成功条目返回 partial count。Unix/UDP 不宣称由该批处理支持；`hello81` 锁定验证边界。

**`sched_getaffinity` current-pid-only contract**：raw syscall #227 仅接受 `pid == 0` 或当前 TID；
其他/不存在的 pid 必须在用户缓冲区访问前返回 `ESRCH`，因此失败不得改写 sentinel。空指针返回
`EFAULT`。当前系统为单 CPU 边界：成功调用复制 `min(cpusetsize, 128)` 字节并返回复制长度，
CPU 0 仅置 bit 0（第一个字节为 `1`，其余为 `0`）；`cpusetsize == 0` 成功但不写入，129 字节
请求仍只复制/返回 128。hello82 锁定这些 ABI/边界语义，不修改 kernel core 或宣称 SMP affinity 支持。
  **2026-11 修订**：上述“单 CPU、复制 `min(cpusetsize,128)`”已被取代（见 `docs/current-code-review-and-fix-plan.md` §5.2y 的修订说明）：现在大小须是 8 的倍数且不小于掩码长度（否则 `EINVAL`、不写缓冲区），成功只写并返回掩码长度（8 字节，超过 64 个 CPU 时更多）；未固定的任务报告全部已配置 CPU，固定的只报告自己。
**`epoll_create1` flags boundary**：raw syscall #146 接受 `flags == 0` 或
`EPOLL_CLOEXEC (0x80000)`，其它 flags 在 fd 分配前返回 `EINVAL`，不创建 epoll fd。
`hello83` 覆盖零 flags 与非法 flags；`hello84` 覆盖零 flags/CLOEXEC 创建后关闭，以及非法
flags 的 `EINVAL`。本验收不宣称 CLOEXEC 跨 `execve` 的生命周期行为；该边界由现有 exec
fd 清理路径单独维护。
**`accept4` strict flags/backlog boundary**：raw syscall #131 first validates flags; unrelated
bits (for example `0x40000000`) return `EINVAL` before dequeuing a pending TCP connection.
`hello85` establishes one loopback connection, verifies the rejected call leaves it pending, then
accepts it with `SOCK_CLOEXEC|SOCK_NONBLOCK` and closes the resulting fd. This is a bounded flag,
backlog, and cleanup contract, not a claim of general socket compatibility or throughput.
**`readlink` procfs fd-target boundary**：raw syscall #182 resolves `/proc/self/exe` to the current
shell target and `/proc/self/fd/N` to the existing descriptor's bounded type string. Invalid path or
output pointers, and zero `bufsiz`, return `EFAULT`; unused/invalid fd paths return `EINVAL`.
`hello86` covers ordinary-fd output, bounded truncation, error precedence, and no performance claim.
**`statx` temporary-fd/output boundary**：raw syscall #183 accepts a valid path and fills the
bounded statx output record. It validates the complete 144-byte writable output buffer before opening
the temporary lookup fd; bad output pointers return `EFAULT` without any fd-table mutation. The
normal metadata path closes its temporary descriptor before the final copyout. `hello87` repeats the
bad-output case beyond `MAX_FDS`, then opens/closes a normal file to lock the no-leak contract.
**`copy_file_range` bounded offsets/errors**：raw syscall #184 accepts regular-file pairs and
`flags == 0`; explicit offset pointers are copied back while descriptor offsets are restored,
whereas null pointers use and advance descriptor positions. `hello88` covers copied contents/size,
invalid fd/nonregular/offset pointers, zero or oversized lengths, and pre-I/O no-mutation errors.
This is an ABI/rollback contract only, not a throughput claim.

**libc 环境变量写接口（hello206）**：`lib/moqi_libc/src/env.c` 提供 `setenv`/`unsetenv`/`putenv`/`clearenv`，
行为与 glibc 对齐（实测表见 `host_tests/test_env_abi.c`）。启动时栈上的 `environ` 数组首次插入时被拷贝到堆上，
被替换的字符串和旧数组不释放以保证 `getenv` 返回的指针持续有效；写操作之间用自旋锁，`getenv` 不加锁。
`hello206` 验证 `execve(path, argv, environ)` 后子进程看到父进程修改后的环境。

**libc 堆分配器接口（hello207）**：`lib/moqi_libc/src/malloc.c` 在 `malloc`/`free`/`calloc` 之外提供 `realloc`、
`reallocarray`、`posix_memalign`、`aligned_alloc`、`memalign`；分配失败设 `ENOMEM`（线程指针未装好时不写 errno）。
`realloc` 缩小就地切分并合并、增长优先吞并后继空闲块或向系统要更多、最后才搬移，失败保持原块；对齐分配切分第一块
够大的空闲块，前部保持空闲。`hello207` 在真实堆（brk）和多线程下验证。

**libc printf 家族（hello208）**：`lib/moqi_libc/src/format.c` 是共享格式化引擎（宽度/精度/标志/长度修饰符，
语法对齐 glibc，由 `host_tests/test_printf_abi.c` 对 2473 行 glibc 实测值验证），`stdio.c` 在其上提供
`printf/dprintf/vprintf/puts/putchar/asprintf`。输出经 512 字节分块的 `write(2)`，不缓冲；无位置参数。浮点转换见 hello218，`FILE` 流（`fopen`/`fgets`/`fread`/`fprintf`…，
`src/stdio_file.c`，与 `printf` 的直写 fd 1 互相独立）见 hello219 与 current-code-review-and-fix-plan.md 末节。

**libc scanf 家族（hello220）**：`src/scan.c` 是共享的扫描引擎 `__moqi_vscan`，从一个“带一级回退的字节源”读输入；`sscanf`/`vsscanf`（`scanf.c`）、`fscanf`/`vfscanf`（`stdio_file.c`，源是流的读窗口）、`scanf`/`vscanf`（`stdio_streams.c`，源是 `stdin`）只是传不同的源。语法与 glibc 在 C locale 下逐项一致（`host_tests/test_scanf_abi.c` 对 8235 行 glibc 实测值、`gen/diff_scanf.c` 对 glibc 的随机差分验证）；只有 `m` 修饰符会分配内存，浮点文本交给 `strtod`/`strtof`。

**TCP 发送节拍下限**：`bbrPacedRate` 经 `tcp_util.pacedRate` 把节拍速率限制在 `cwnd/srtt` 以上，防止一个偏低的交付速率估计（例如被延迟 ACK 拉低）把连接锁在每 RTT 一个段的速度上而无法恢复；无估计时不节拍。依据与不确定性见 `current-code-review-and-fix-plan.md` 的 hello174 一节。

**pause() 阻塞与 gettid（hello225）**：`pause()` 此前让出一次 CPU 就无条件返回 `-EINTR`，不等信号；现在与 `sigsuspend` 共用 `signal_syscall.waitForSignal`（睡到出现可处理的信号），返回 `-EINTR` 前由分发器投递信号，默认动作为终止的信号直接结束进程。新增 `gettid()`（497），返回调用任务自己的 tid（`getpid()` 是线程组 id），多线程程序因此能对自己 `tkill`。

**/proc/lostats：回环队列的计数（hello224）**：`net/lo.zig` 的 16 帧环形队列此前满了就丢帧、只在内部累加 `dropped`，没有任何地方读它，所以无从知道 TCP/UDP 的某次停滞是不是因为回环丢了帧。现在队列记录 `queued`（接受的帧）、`delivered`（交给接收路径的帧）、`dropped`（队列满而拒绝的帧）、`high_water`（同时排队的最大帧数），`/proc/lostats` 以 `queued=N delivered=N dropped=N high_water=N depth=N` 一行给出（`lo.snapshot()` 在队列锁下取一份一致的拷贝）。空帧和超长帧被拒绝但不算拥塞丢帧。`hello174` 在排空断言之后打印这一行，下次 CI 里它失败时能直接看到丢帧是否发生。

**当前目录的读写在锁下（hello222）**：`FsContext`（`mm/group_state.zig`）带一把 `IrqSpinlock`，读只通过 `snapshot()`、写只通过 `set()`，两者只在拷贝期间持锁；`getcwd`、相对路径查找、`chdir`、`fchdir` 与 `fork`/`clone` 复制目录都走这两个入口。此前 `chdir` 分几步写一个 256 字节数组，同时有别的线程读它时会读到半新半旧的路径。

**libc 的 ctype 与 math（hello223）**：`include/ctype.h` 补全到 glibc C locale 的全部 13 个分类函数加 `toupper`/`tolower`/`toascii`，并对 glibc 在 `EOF` 和 -128..255 的全部 384 个定义域做了逐一比对；`include/math.h` + `src/math.c` 提供结果有精确定义的双精度函数，全部用整数运算在位型上实现（不依赖舍入模式或 x87/SSE），`sqrt` 正确舍入，取整、`fmod`/`remainder`/`remquo`、`nextafter`、`ldexp`/`scalbn`/`frexp`/`modf`、`lround` 族与 glibc 逐位一致（含 errno 和 NaN 传播规则）。没有超越函数。

**libc setjmp 家族（hello221）**：`include/setjmp.h`、`src/setjmp.c`（x86-64 汇编，四个函数共用一个实现；`jmp_buf` 保存 rbx/rbp/r12–r15、rsp、返回地址，外加是否保存了信号掩码的标志和掩码）。`setjmp` 与 `sigsetjmp(env, 0)` 不碰信号掩码，`sigsetjmp(env, 非零)` 读一次掩码、`siglongjmp`（以及对这种缓冲区调用 `longjmp`，glibc 的 `longjmp` 就是 `siglongjmp`）写回一次；读掩码失败则什么也不保存、也不恢复；`longjmp(env, 0)` 使 `setjmp` 返回 1。不保存 x87 控制字、MXCSR 与浮点寄存器（与 glibc 一致）。只有 x86-64 实现，aarch64/riscv64 的用户态 libc 没有这几个函数。

**程序 break 属于 `Mm`（hello209）**：`brk_current`/`brk_start` 原来在 `Task` 里，`CLONE_VM` 线程创建时只拷了 `brk_current`
（没拷 `brk_start`，`brk` 因 `brk_start == 0` 对该线程直接拒绝移动），即使两个字段都拷了，每个线程也会各持一个
会过期的 break，一个线程增长堆之后另一个线程仍按旧值算页，增长到别人已映射的页上而失败（`isPageOccupied`）。
现在这两个字段在 `Mm`（`vm_lock` 保护），`brk` 与页故障里的栈增长检查都读写它；`Mm.setBreak`（loader、execve）和
`Mm.inheritBreak`（fork、不带 `CLONE_VM` 的 clone）负责初始化，`CLONE_VM` 的 clone 因共享 `Mm` 什么也不拷。
`hello209` 覆盖线程增长、创建者看到线程的增长、之后创建的线程看到当前 break、六轮交替增长。

**映射表属于 `Mm`（hello210）**：`mm/vma_table.zig` 定义 `MmapRegion` 和 `VmaTable`（区域数组一页 + 计数 + 活动位图），挂在 `Mm.vma_tab`，`vm_lock` 保护；
`Task.vma()` 取所属 `Mm` 的表。`CLONE_VM` 线程共享同一张表；fork 与不带 `CLONE_VM` 的 clone 在克隆页表的同一临界区里拍快照并在子 `Mm` 里 `adopt`；
文件区域后备引用与设备（`no_free`）映射在 `Mm` 终结器（`user_space.destroyMm`）里释放一次。

**信号处置属于线程组（hello211）**：`mm/sigact_table.zig` 定义 `SigActions`（handlers/masks/flags），挂在 `Mm.sig`；`Task.sigact()` 取它。
`CLONE_VM` 线程共享，fork 与不带 `CLONE_VM` 的 clone 拷贝，exec 从旧 `Mm` 读出再重置（捕获的还原为默认，`SIG_IGN` 保留）。

**RLIMIT_AS / RLIMIT_DATA 的已用计数属于 `Mm`（hello212）**：`Mm.as_used`/`Mm.data_used`；`Task.asUsed()`/`dataUsed()` 取所属 `Mm` 的计数器。
fork 与不带 `CLONE_VM` 的 clone 用 `inheritCharges` 继承，`CLONE_VM` 线程共享，exec 的新 `Mm` 从 0 开始。限额本身仍在 `Task` 里（见 current-code-review-and-fix-plan.md 的剩余缺口）。

**线程组状态页（hello213）**：`mm/group_state.zig` 的 `GroupState { sig, lim }`（信号处置 + RLIMIT_* 限额，一页）挂在 `Mm.grp`，`Task.sigact()`/`Task.lim()` 取用。
`CLONE_VM` 线程共享，fork 与不带 `CLONE_VM` 的 clone 复制（`inheritLimits` + 信号表拷贝），exec 把限额从旧 `Mm` 带到新 `Mm`、信号处置按 exec 规则重置。

**文件系统上下文属于线程组（hello214）**：`GroupState.fs`（`cwd`、`cwd_len`、`umask`）与信号处置、限额同在 `Mm.grp` 的一页里；`Task.fsctx()` 取用。
`CLONE_VM` 线程共享（`CLONE_FS`），fork 与不带 `CLONE_VM` 的 clone 复制（`inheritFs`），exec 带到新 `Mm`。

**libc 浮点解析（hello217）**：`lib/moqi_libc/src/strtod.c` 提供 `strtod`/`strtof`/`atof`，转换用定长大整数做精确的最近偶数舍入，内部无浮点运算；
行为按 glibc 逐位对照（1321 行表 + 4000 万随机串差分）。无 `strtold`，无 printf 浮点转换。

**libc printf 浮点转换（hello218）**：`lib/moqi_libc/src/fpfmt.h` 把 double 精确展开为十进制数字串再做十进制舍入，`format.c` 的 `f F e E g G a A` 用它输出，
与 glibc 逐位一致（9067 行表 + 500 万随机格式差分）。无 `long double`。
- **UDP 端口共享与 TCP 监听者迁移（hello183 H/I）**：UDP 槽位键为 32 位（低 16 位端口，高 16 位区分同端口的套接字，`udp_disc`/`udpKey()`），`udp.rebind` 原位移动注册并保留 `bind` 之前设置的选项；`udp_port_policy` 规定两个都设 `SO_REUSEADDR`、或都设 `SO_REUSEPORT` 且 uid 相同才能共享，数据报在 `SO_REUSEPORT` 全员时按发送方哈希分发，否则交给最新绑定者。TCP 监听者关闭时，未 `accept` 的连接迁移到同端口还有空位的兄弟监听者，无处可去才复位。详见 current-code-review-and-fix-plan.md 文末两节。
- **TCB 表满时的处理与 `/proc/tcpstats`（hello269）**：`allocTcb` 在 64 个槽全满时把等得最久、没有描述符引用的 TIME_WAIT 槽让给新连接（`tcp_port_policy.pickTimeWaitVictim`），活跃连接、监听者和仍被引用的 TCB 不会被拿走。`/proc/tcpstats` 报告各状态的槽数、无引用的槽数、容量、因没有空槽丢弃的 SYN 总数（`syn_dropped`）和让出的 TIME_WAIT 槽总数（`time_wait_evicted`）。

