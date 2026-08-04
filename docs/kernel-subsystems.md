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
- 64条VMA表管理用户态映射区
- 配套 munmap 解除映射和 msync 同步脏页
- syscall mmap: 支持匿名映射 + 文件映射 (MAP_PRIVATE/MAP_SHARED)；G2 起文件映射改为
  页缓存支撑的按需分页 + 零拷贝 COW，详见 1.8.1

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
- **EOF 语义**：整页越过 EOF 的访问 → SIGSEGV（Linux 是 SIGBUS，本内核统一 SEGV，状态码 139）；
  最后一个部分页正常供给，尾部清零。`file_size` 取 mmap 时的快照。
- **零拷贝共享帧**：tmpfs 直接映射其数据页；ext2/fat32 经 page_cache
  （命中 `getPageFrame` 直接拿物理帧；未命中先 `readFile` 填充缓存再取）。
  共享帧一律先 `pmm.addRef` 再以"只读 + COW 位(bit9)"映射——即使 PROT_WRITE，
  首次写入落入既有 `handleCowFault` 复制路径，文件内容永远不被 MAP_PRIVATE 写污染。
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
  越过记录文件大小的页访问即 SIGSEGV，与 Linux 允许增长过 EOF 但访问即 SIGBUS 的
  语义对应；移动文件区域仍拒绝——moveMapping 会把未缺页的共享帧换成私有零页）。
  mprotect 在改 PTE 之外同步更新文件区域的 prot 元数据（`filemap.planProtUpdate`
  分类 cover/head/tail/middle，部分覆盖时拆区域、ext2 片各补一次 retain，拆前先做
  槽位容量检查）；对获得 PROT_WRITE 的 MAP_SHARED ext2/fat32 区域，顺手把已缓存页
  markDirty——这些页此前以只读缺入，此后可写但不再经过缺页路径。
- **已知限制**：mremap 文件区域仅支持原地增长/收缩（移动返回 ENOMEM）；
  MAP_SHARED 可写页与随后对同一 inode 的 `write()` 系统调用之间不做一致性保证
  （writeFile 会 invalidate 该 inode 的缓存页，未刷出的映射写入可能丢失——请先
  msync）；MAP_SHARED 映射可写时页缓存 insert 失败（缓存满）会先刷本 inode 脏页
  重试一次，仍失败则缺页失败（SIGSEGV）——绝不退化为会丢写的私有副本；
  内核态 `copy_to_user` 对未缺页的文件映射返回 EFAULT（无内核态按需分页）；
  同一地址空间多线程并发缺同一文件页时后写 PTE 者胜出（与既有匿名按需分页同级竞态）。
- **运行时覆盖**：`user/hello46.c`（tmpfs 文件写模式串 → MAP_PRIVATE 映射 →
  close(fd) 后验证内容 → 尾部清零 → 写穿透后 pread 验证文件不变（COW）→
  fork 子进程缺页继承区域 + 越过 EOF 整页 SIGSEGV(139)），
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
  迁移父进程会残留可写陈旧项（理论窗口，未触发，属 CR0.WP 同类先修）。
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
    fdtable: FdTable,           // 64 个 FD（MAX_FDS=64，vfs.zig:24）
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
- **③ 是安全网，不能当作发现新任务的正常途径（2026-07-26）**：每次上下文切换都会把换下来的
  任务重新入队，因此只要 CPU 上有两个任务来回 ping-pong，①就永远有货，③永远走不到。任务
  必须**显式发布**才可能被调度：`createUserProcess` 建出的任务处于 `.blocked`，由创建者在
  构造完毕后调用 `task.publishRunnable(slot)`（`.blocked → .ready` + `sched.enqueue` +
  跨 CPU kick）。fork、clone、loader 的 ELF/flat 两条路径都走这一步。此前四处都没有入队，
  新任务只在 CPU 恰好跑空时才被捡起；fork 靠父进程随即阻塞在 waitpid 掩盖了这一点，线程
  创建者不阻塞，缺陷即刻显形。
- 时间片 10 个 tick（100ms），LAPIC timer ISR 触发 `schedule()`，调用
  `switchContext(prev, next)`（`arch/x86_64/context.S`）。

**API**：`schedule()` / `yield()` / `wakeup(task)` / `sleep(ms)` / `addTask(task)` /
`per_cpu.enqueueTask(t)` / `per_cpu.tryStealForCurrent()`.

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
  它——旧代码在 `sched_lock` 释放前就重新发布旧任务，整个中断尾声都是双栈窗口；现在
  该窗口收窄到 [release → iretq]。cmpxchg 同时兼任旧的 `state == .running` 检查：
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
`ipc`、阻塞 `flock`、`pause`）都走同一条路径，因此修正落在 `forceReschedule` 自身而非调用点。
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
- **两条选择路径都已 RT 化**：① per-CPU 队列 `popRtAware`——队列无 RT 任务时退化为原 LIFO
  `pop`（逐字节一致）；有 RT 任务时扫描选最优 RT 键，**同优先级取最老入队者**，使同级
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

**挂载管理** (v18.0): `mountFs` / `umountFs`，16 挂载点表，支持 tmpfs/ext2/vfat/proc/ramfs 类型。系统调用 #165 (mount), #166 (umount2)。

### 3.2 Ramdisk ✅

文件: `ramdisk.zig`，格式: MRD（自定义）

- Header: 32 字节（magic + entry_count + ...）
- Entry: 80 字节/文件（名称、偏移、长度）
- Data: 串接所有文件原始数据

只读，由内核启动时一次性加载到内存，存放所有用户测试程序。

### 3.3 FAT32 ✅ 单扇区 FAT 缓存 + DMA 安全写缓冲

文件: `fat32.zig`

- MBR 分区表解析
- Boot Sector (BPB)、FSInfo
- FAT 表读写：单扇区 FAT 缓存（`fat_cache_sector`，v53.36，顺序读 I/O 减少约 128 倍）
- 空闲簇扫描游标（`last_free_cluster`，v53.38，O(N) 分配扫描）
- 8.3 短文件名 + LFN（长文件名）支持
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

文件: `posix_mq.zig` (519 行)

- 16 个队列上限，8 消息/队列，512 字节/消息
- mq_open: 创建/打开队列，O_CREAT/O_EXCL/O_NONBLOCK
- mq_timedsend/timedreceive: 发送/接收消息 (带优先级；阻塞在 `task.WaitNode` 等待队列上，
  支持超时唤醒)
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
- 操作：READ / WRITE / FLUSH / DISCARD
- TRIM/discard (G5)：特性协商时检查 `VIRTIO_BLK_F_DISCARD`（bit 13），
  设备提供则在 driver features 中回写并接受；`discard(lba, count)` 经同一
  `io_lock` 提交路径下发 `VIRTIO_BLK_T_DISCARD`(8) 请求（desc0=头部，
  desc1=16 字节 `virtio_blk_discard_write_zeroes` 段，desc2=状态字节）。
  设备不提供该特性时 `discard()` 为 no-op（返回 0）。QEMU 需给
  virtio-blk 设备加 `discard=on` 才会提供该特性，默认不开启。

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

### 6.6 NVMe SSD (Admin/IO Queue + PRP + MSI-X) ✅

文件: `nvme.zig`, `pci_msix.zig`, `pci.zig` (MSI-X 部分)

- PCI枚举发现NVMe设备
- Admin Queue + IO Queue初始化（Admin 保持轮询，仅初始化期使用）
- Doorbell机制通知控制器
- PRP（Physical Region Page）分散/聚集
- readSectors / writeSectors / flush 接口
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
  `execve`（两处）、`waitpid` 唤醒恢复、
  `syscall_entry.prepareSyscallCpu`（惰性再同步）。漏掉任何一处都会把
  前一个任务的端口权限泄漏给下一个任务。`ioperm_set` 本身在改完位图后
  立即刷新当前 CPU 的活副本。
- fork 语义：子进程继承位图的**独立副本**（`inheritForFork`，分配失败
  时子进程回退全拒绝并告警，不阻塞 fork）。
- 退出语义：任务收割（reapZombies）与 waitpid 回收两处拆解点释放位图
  页（`freeBitmap`，与 `userdrv.cleanupTask` 并列）；execve 保留位图
  （同 Linux ioperm 语义）。

运行时证明 `hello52`：授予 0x70/0x71 → 读 RTC 秒寄存器并验证合法 BCD
（≤0x59、低半字节 ≤9）→ fork 子进程继承权限读成功（退出码 0）→ 撤销
后 fork 的子进程访问 0x71 被 #GP 杀死，waitpid 状态 == 141（本内核
`exitTask(128+向量号)`，#GP 为向量 13）。标记：`hello52: PASS` /
`hello52 done`。

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
`/tmp/kern.log`（tmpfs，256 KiB 硬顶前单代轮换）。J3 之前内核不会阻塞，
daemon 以 `nanosleep(100ms)` 轮询；现在读本身在最新字节处睡眠，日志行追加即醒，
投递完全事件驱动，无轮询、无空转。

---

## 参考

- [moqios-architecture-current.md](./moqios-architecture-current.md)
- [build-and-toolchain.md](./build-and-toolchain.md)
- [user-space.md](./user-space.md)
- [moqios-design.md](./moqios-design.md)
