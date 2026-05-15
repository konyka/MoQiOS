# Zigix OS 内核架构文档

> 版本：v45c (2026-03) | 语言：Zig | 许可：项目私有  
> 来源：[Quantum Zig Forge](https://github.com/quantum-encoding/quantum-zig-forge) by QUANTUM ENCODING LTD  
> 路径：`3rd/zigix/`

---

## 1. 项目概览

| 属性 | 值 |
|---|---|
| **项目名** | Zigix |
| **描述** | 双架构操作系统内核，使用 Zig 编写，目标为自举和 Linux 二进制兼容 |
| **语言** | Zig (freestanding, 无标准库) |
| **架构支持** | x86_64, aarch64 (ARM64), riscv64 (仅 linker script) |
| **内核代码量** | 206 个 `.zig` 文件, 88,595 行 |
| **用户空间代码量** | 24 个 `.zig` 文件, 10,724 行 |
| **公开函数数** | 1,163 个 `pub fn` |
| **系统调用数** | 138 个 (aarch64 + x86_64) |
| **自举状态** | 已在 Google Cloud Axion (ARM64) 裸金属上实现自举 |
| **Bootloader** | Limine (x86_64), UEFI (aarch64) |
| **构建系统** | Zig build (`build.zig`) |

### 1.1 代码量分布

| 模块 | 行数 | 占比 |
|---|---|---|
| arch/aarch64/ | 34,767 | 39.2% |
| proc/ (进程管理) | 10,816 | 12.2% |
| fs/ (文件系统) | 8,296 | 9.4% |
| drivers/ (设备驱动) | 4,044 | 4.6% |
| mm/ (内存管理) | 3,554 | 4.0% |
| net/ (网络栈) | 3,141 | 3.5% |
| arch/x86_64/ | 2,192 | 2.5% |
| klog/ (内核日志) | 1,019 | 1.1% |
| acpi/ | 685 | 0.8% |
| safety/ | 665 | 0.8% |
| (root) | 963 | 1.1% |
| lib/ | 594 | 0.7% |
| security/ | 182 | 0.2% |

---

## 2. 构建系统

**文件：** `build.zig` (218 行)

### 2.1 构建配置

```zig
// 架构选择：x86_64 (默认), aarch64, riscv64
const arch = b.option(std.Target.Cpu.Arch, "arch", "...") orelse .x86_64;

// ARM64 CPU 配置文件
const CpuProfile = enum { generic, cortex_a72, neoverse_n1, neoverse_n2, neoverse_v2 };

// 目标：freestanding, none ABI
const target_query = .{ .cpu_arch = arch, .os_tag = .freestanding, .abi = .none };
```

### 2.2 入口点选择

| 架构 | 入口文件 | Linker Script |
|---|---|---|
| x86_64 | `kernel/main.zig` | `linker.ld` |
| aarch64 | `kernel/arch/aarch64/boot.zig` | `linker-aarch64.ld` |
| riscv64 | (未实现) | `linker-riscv64.ld` |

### 2.3 构建命令示例

```bash
# x86_64 (QEMU)
zig build run

# aarch64 (QEMU)
zig build run-aarch64

# aarch64 (Google Cloud Axion, Neoverse-V2)
zig build -Darch=aarch64 -Dcpu=neoverse_v2
```

---

## 3. 内核启动流程

### 3.1 x86_64 启动序列

```
┌─────────────────────────────────────────────────────────┐
│                    Limine Bootloader                     │
│              (加载内核 ELF, 设置 HHDM)                   │
└──────────────────────┬──────────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────────┐
│  _start() [kernel/main.zig:56]                          │
│  ├── enableSSE()          // 启用 SSE/AVX               │
│  ├── serial.init()        // COM1 串口                  │
│  ├── console.init()       // 帧缓冲控制台               │
│  ├── klog.init(...)       // 内核日志子系统              │
│  ├── gdt.init()           // 全局描述符表                │
│  ├── smp.initBsp()        // BSP CPU 状态 + GS_BASE     │
│  ├── idt.init()           // 中断描述符表                │
│  ├── pic.init()           // 8259A PIC                   │
│  ├── pit.init()           // 8254 定时器                  │
│  ├── initMemory()         // PMM → HHDM → VMM           │
│  ├── lapic.init()         // Local APIC 定时器           │
│  ├── ps2_keyboard.init()  // PS/2 键盘                   │
│  ├── sti                  // 启用中断                     │
│  ├── process.initProcessTable()                         │
│  ├── tss.initIst()        // IST1 (双重故障)             │
│  ├── syscall_entry.init() // syscall/sysret MSRs         │
│  ├── syscall_table.init() // 138 个系统调用              │
│  ├── pci.scanBus() → virtio_blk/net.init, nvme.init     │
│  ├── VFS 初始化 → ramfs, ext2 挂载                      │
│  ├── net.init()           // 协议栈初始化                │
│  └── scheduler.startFirst() → 首个用户进程 (zinit)      │
└─────────────────────────────────────────────────────────┘
```

### 3.2 aarch64 启动序列

```
┌─────────────────────────────────────────────────────────┐
│              UEFI Bootloader / FDT                       │
│         (BootInfo 或 Limine 协议)                        │
└──────────────────────┬──────────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────────┐
│  _start() [kernel/arch/aarch64/boot.zig]                │
│  ├── 解析 FDT / BootInfo                                │
│  ├── MMU 初始化 (页表, EL2→EL1 切换)                    │
│  ├── GICv3 初始化                                       │
│  ├── PMM / VMM 初始化                                   │
│  ├── CPU features 探测 (Neoverse-V2, SVE)               │
│  ├── NVMe / gVNIC / virtio 驱动初始化                   │
│  ├── ext4 挂载, 网络栈初始化                             │
│  ├── SMP: bootAPs() → 辅助核启动                        │
│  └── scheduler.startFirst() → zinit (PID 1)             │
└─────────────────────────────────────────────────────────┘
```

---

## 4. 架构抽象层 (arch/)

Zigix 的架构相关代码分布在 `arch/aarch64/` 和 `arch/x86_64/` 中。共享子系统（fs, mm, net, proc 等）通过 `@import()` 引用架构特定实现。

### 4.1 x86_64 架构层 (2,192 行)

| 文件 | 行数 | 公开函数 | 职责 |
|---|---|---|---|
| serial.zig | ~160 | `init`, `writeByte`, `writeString`, `print`, `rxInterrupt`, `readByte`, `hasData` | COM1 串口驱动 |
| gdt.zig | ~120 | `init`, `loadTss`, `initForCpu` | 全局描述符表 (GDT) |
| idt.zig | ~200 | `init`, `loadForAp`, `getTickCount` | 中断描述符表 (IDT) |
| pic.zig | ~80 | `init`, `sendEoi`, `setIrqMask` | 8259A 可编程中断控制器 |
| pit.zig | ~60 | `init` | 8254 可编程间隔定时器 |
| lapic.zig | ~150 | `init`, `initSecondary`, `eoi`, `id`, `sendInitIpi`, `sendSipi`, `sendIpi`, `broadcastIpi` | Local APIC (中断 + 定时器) |
| smp.zig | ~380 | `initBsp`, `bootAPs` | SMP 多核启动 (INIT/SIPI) |
| syscall_entry.zig | ~100 | `init`, `wrmsrPub`, `getLstarAddr` | syscall/sysret MSR 设置 |
| tss.zig | ~100 | `initIst`, `setRsp0`, `checkKstackIntegrity`, `getRsp0`, `getTssPtr` | 任务状态段 (TSS) |
| io.zig | ~40 | `outb`, `inb`, `inw`, `outw`, `inl`, `outl`, `ioWait` | x86 I/O 端口操作 |

### 4.2 aarch64 架构层 (34,767 行)

aarch64 架构层包含完整的硬件抽象，包括独立实现的内存管理、进程管理、文件系统和网络栈。

**关键文件及其公开函数：**

| 文件 | 行数 | 公开函数数 | 核心函数 |
|---|---|---|---|
| boot.zig | 1,159 | 5 | `_start` (入口), MMU 初始化, 测试函数 |
| syscall.zig | 6,876 | 7 | 138 个系统调用分发器 (aarch64 最大文件) |
| exception.zig | 1,483 | 4 | 异常向量表, EL1h 同步/IRQ/FIQ 处理 |
| ext2.zig | 3,788 | 21 | 完整 ext2 文件系统 (读写) |
| gvnic.zig | 1,255 | 7 | Google Cloud gVNIC 驱动 |
| nvme.zig | 1,009 | 5 | NVMe 存储 (PCI, admin + I/O 队列) |
| procfs.zig | 1,053 | 1 | /proc 文件系统 |
| vmm.zig | 1,030 | 19 | 虚拟内存管理 (ARM64 页表) |
| tcp.zig | 915 | 10 | TCP 协议 (含 OOO 重组) |
| process.zig | 573 | 17 | 进程/线程控制块 |
| scheduler.zig | 525 | 12 | 抢占式调度器 (SMP) |
| virtio_blk.zig | 435 | 6 | virtio 块设备 |
| virtio_mmio.zig | 514 | 16 | virtio MMIO 传输层 |
| vma.zig | 515 | 12 | 虚拟内存区域管理 |
| uart.zig | 514 | 19 | PL011 UART 串口 |
| slab.zig | 479 | 10 | SLAB 分配器 |
| fdt.zig | 478 | 3 | Flattened Device Tree 解析 |
| virtio_net.zig | 278 | 6 | virtio 网络设备 |
| pmm.zig | 506 | 16 | 物理内存管理 |
| gicv3.zig | 782 | 11 | GICv3 中断控制器 + ITS |
| gic.zig | 335 | 12 | GIC 中断抽象层 |
| cpu_features.zig | 340 | 3 | CPU 特性探测 (SVE, NEON, LSE) |
| mmu.zig | 389 | 8 | ARM64 MMU (TTBR0/1, TCR_EL1) |
| dhcp.zig | 248 | 1 | DHCP 客户端 |
| net_ring.zig | 378 | 11 | 网络环形缓冲区 |
| runqueue.zig | 203 | 10 | 调度运行队列 |
| epoll.zig | 590 | 4 | epoll I/O 多路复用 |
| futex.zig | 358 | 3 | futex 用户空间互斥 |
| signal.zig | 483 | 7 | POSIX 信号处理 |
| socket.zig | 514 | 9 | BSD socket 抽象 |
| elf.zig | 212 | 2 | ELF64 加载器 |
| timer.zig | 204 | 9 | ARM 通用定时器 |
| watchdog.zig | 149 | 7 | SP805 看门狗 |
| sve.zig | 281 | 8 | 可伸缩向量扩展 (SVE) |
| checksum.zig | 68 | 3 | 网络校验和计算 |

---

## 5. 内存管理子系统 (mm/)

**路径：** `kernel/mm/` (3,554 行)  
**职责：** 物理内存分配、虚拟内存映射、页面缓存、交换空间、缺页处理

### 5.1 模块间调用关系

```
┌──────────┐    ┌──────────┐    ┌──────────┐
│   PMM    │◄───│   VMM    │───►│   HHDM   │
│ 物理内存  │    │ 虚拟内存  │    │ 高半映射  │
└────┬─────┘    └────┬─────┘    └──────────┘
     │               │
     ▼               ▼
┌──────────┐    ┌──────────┐    ┌──────────┐
│Page Cache│◄───│   VMA    │───►│   mmap   │
│  页缓存   │    │ 虚拟内存区│    │ 系统调用  │
└──────────┘    └──────────┘    └──────────┘
                       │
                       ▼
                 ┌──────────┐    ┌──────────┐
                 │  fault   │───►│   swap   │
                 │ 缺页处理  │    │  交换空间  │
                 └──────────┘    └──────────┘
```

### 5.2 文件详解

#### mm/pmm.zig — 物理内存管理器 (858 行, 20 pub fns)

物理页分配器，支持 4KB/2MB/1GB 页面，带引用计数和守护页。

| 函数签名 | 功能 |
|---|---|
| `init(memmap_response: *const limine.MemmapResponse) void` | 从 Limine 内存映射初始化 |
| `initFromBootEntries(entries, count) void` | 从 UEFI BootInfo 初始化 |
| `initRecovery() void` | 恢复模式初始化 |
| `allocPage() ?types.PhysAddr` | 分配单个 4KB 页 |
| `freePage(phys: types.PhysAddr) void` | 释放单个页 |
| `incRef(phys: types.PhysAddr) void` | 增加引用计数 (COW) |
| `decRef(phys: types.PhysAddr) u16` | 减少引用计数 |
| `getRef(phys: types.PhysAddr) u16` | 获取引用计数 |
| `allocPages(count: u64) ?types.PhysAddr` | 分配连续多页 |
| `allocHugePage() ?types.PhysAddr` | 分配 2MB 大页 |
| `allocHugePages(count: u64) ?types.PhysAddr` | 分配连续大页 |
| `freeHugePage(phys: types.PhysAddr) void` | 释放大页 |
| `allocGigaPage() ?types.PhysAddr` | 分配 1GB 巨页 |
| `freeGigaPage(phys: types.PhysAddr) void` | 释放巨页 |
| `freePages(phys, count: u64) void` | 释放连续页 |
| `allocPagesGuarded(count, guard: u64) ?types.PhysAddr` | 带守护页分配 |
| `freePagesGuarded(phys, count, guard: u64) void` | 释放带守护页 |
| `getFreePages() u64` | 获取空闲页数 |
| `getTotalPages() u64` | 获取总页数 |
| `getHighestPhys() u64` | 获取最高物理地址 |

#### mm/vmm.zig — 虚拟内存管理器 (545 行, 18 pub fns)

4 级页表管理 (PML4 → PDPT → PD → PT)，支持用户/内核地址空间隔离。

| 函数签名 | 功能 |
|---|---|
| `init() void` | 初始化内核页表 |
| `mapPage(pml4, virt, phys, flags: MapFlags) !void` | 映射 4KB 页 |
| `mapHugePage(pml4, virt, phys, flags) !void` | 映射 2MB 页 |
| `mapGigaPage(pml4, virt, phys, flags) !void` | 映射 1GB 页 |
| `unmapPage/unmapHugePage/unmapGigaPage(pml4, virt) void` | 取消映射 |
| `createAddressSpace() !types.PhysAddr` | 创建新地址空间 (fork) |
| `destroyUserPages/destroyAddressSpace(pml4) void` | 销毁地址空间 |
| `switchAddressSpace(pml4) void` | 切换 CR3 |
| `translate(pml4, virt) ?types.PhysAddr` | 虚拟→物理地址翻译 |
| `getKernelPML4() types.PhysAddr` | 获取内核 PML4 |
| `getPTE(pml4, virt) ?*PTE` | 获取页表项 |
| `logPageFault(fault_addr, error_code: u64) void` | 记录缺页信息 |
| `invlpg(virt) void` | 刷新单个 TLB 项 |
| `tlbShootdown() void` | TLB 击落 (SMP) |
| `handleTlbShootdown() void` | 处理 TLB 击落 IPI |

#### mm/hhdm.zig — 高半直接映射 (67 行, 4 pub fns)

| 函数签名 | 功能 |
|---|---|
| `init(hhdm_offset: u64) void` | 设置 HHDM 偏移 |
| `physToVirt(phys) types.VirtAddr` | 物理→虚拟地址 |
| `virtToPhys(virt) types.PhysAddr` | 虚拟→物理地址 |
| `physToPtr(comptime T, phys) *T` | 物理地址→类型指针 |

#### mm/mmap.zig — mmap 系统调用 (525 行, 4 pub fns)

| 函数签名 | 功能 |
|---|---|
| `sysMmap(frame: *idt.InterruptFrame) void` | mmap 系统调用处理 |
| `sysMunmap(frame) void` | munmap 系统调用处理 |
| `sysMprotect(frame) void` | mprotect 系统调用处理 |
| `sysMremap(frame) void` | mremap 系统调用处理 |

#### mm/page_cache.zig — 页缓存 (325 行, 7 pub fns)

| 函数签名 | 功能 |
|---|---|
| `lookup(inode_num: u32, page_index: u32) ?types.PhysAddr` | 查找缓存页 |
| `insert(inode_num, page_index, phys) void` | 插入缓存页 |
| `markDirty(inode_num, page_index) void` | 标记脏页 |
| `invalidatePage/invalidateInode(...) void` | 使缓存失效 |
| `readaheadCount(inode_num, page_index) u8` | 预读计算 |
| `evictOne() ?u64` | 淘汰一个缓存页 |

#### mm/vma.zig — 虚拟内存区域 (470 行, 15 pub fns)

管理进程的虚拟内存区域链表（VMA 链表），支持 mmap/munmap 区域查找和合并。

#### mm/swap.zig — 交换空间 (306 行, 9 pub fns)

支持将匿名页面换出到交换设备，实现物理内存回收。

#### mm/fault.zig — 缺页处理 (458 行, 2 pub fns)

处理缺页异常：demand paging、COW (Copy-on-Write)、栈扩展。

---

## 6. 进程管理子系统 (proc/)

**路径：** `kernel/proc/` (10,816 行)  
**职责：** 进程/线程管理、调度、系统调用、信号、同步原语

### 6.1 模块间调用关系

```
┌──────────────┐
│ syscall_table │ ──── 138 个系统调用分发
│  (5,459 行)   │
└──────┬───────┘
       │ dispatch
       ▼
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   syscall    │────►│   process    │────►│  scheduler   │
│  (435 行)    │     │  (536 行)    │     │  (477 行)    │
└──────┬───────┘     └──────┬───────┘     └──────────────┘
       │                    │
       ▼                    ▼
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│    clone     │     │     elf      │     │    signal    │
│  (509 行)    │     │  (240 行)    │     │  (611 行)    │
└──────────────┘     └──────────────┘     └──────────────┘
                                          ┌──────────────┐
┌──────────────┐     ┌──────────────┐     │    futex     │
│   execve     │     │    epoll     │     │  (231 行)    │
│  (788 行)    │     │  (430 行)    │     └──────────────┘
└──────────────┘     └──────────────┘     ┌──────────────┐
                                          │ user_program │
                                          │  (911 行)    │
                                          └──────────────┘
```

### 6.2 文件详解

#### proc/process.zig — 进程控制块 (536 行, 13 pub fns)

| 函数签名 | 功能 |
|---|---|
| `aslrMmapBase() u64` | 获取 ASLR 基地址 |
| `initProcessTable() void` | 初始化进程表空闲链表 |
| `registerPid(pid, idx) void` | 注册 PID → 进程槽位映射 |
| `unregisterPid(pid) void` | 注销 PID |
| `findByPid(pid) ?*Process` | 通过 PID 查找进程 |
| `createFromCode(code: []const u8) !*Process` | 从二进制代码创建进程 |
| `createFromElf(elf_data: []const u8) !*Process` | 从 ELF 数据创建进程 |
| `getProcess(idx) ?*Process` | 获取进程槽位 |
| `clearSlot(idx) void` | 清空进程槽位 |
| `findFreeSlot() ?usize` | 查找空闲槽位 |
| `allocPid() types.ProcessId` | 分配 PID |
| `setSlot(idx, proc) *Process` | 设置进程槽位 |
| `initSlot(idx) *Process` | 初始化进程槽位 |

#### proc/scheduler.zig — 调度器 (477 行, 12 pub fns)

抢占式轮转调度器，支持 SMP 多核。spinlock 保护运行队列。

| 函数签名 | 功能 |
|---|---|
| `isDedicated() bool` | 是否有专用进程 |
| `setDedicated/clearDedicated/clearDedicatedIfOwner(pid) void` | 管理专用进程 |
| `currentProcess() ?*process.Process` | 获取当前运行进程 |
| `currentProcessIndex() ?usize` | 获取当前进程索引 |
| `startFirst(proc) noreturn` | 启动首个进程 (永不返回) |
| `timerTick(frame) void` | 定时器中断调度入口 |
| `schedule(frame) void` | 主调度函数 |
| `blockAndSchedule(frame) void` | 阻塞当前进程并调度 |
| `wakeProcess(pid: u64) void` | 唤醒进程 |
| `makeRunnable(proc) void` | 将进程加入运行队列 |

#### proc/syscall_table.zig — 系统调用表 (5,459 行, 3 pub fns)

包含 138 个 Linux 兼容系统调用的分发逻辑。

| 函数签名 | 功能 |
|---|---|
| `init() void` | 初始化系统调用表 |
| `dispatch(frame: *idt.InterruptFrame) void` | 系统调用分发主函数 |
| `inotifyPostEvent(parent_ino, event_mask, name) void` | inotify 事件投递 |

#### proc/syscall.zig — 系统调用辅助 (435 行, 9 pub fns)

| 函数签名 | 功能 |
|---|---|
| `dispatch(frame) void` | 系统调用分发 |
| `sysWrite/sysRead/sysExit/sysGetpid(frame) void` | 基本系统调用 |
| `validateUserBuffer(buf, len) bool` | 验证用户缓冲区 |
| `copyToUser(page_table, user_addr, data) bool` | 内核→用户空间拷贝 |
| `copyFromUser/copyFromUserRaw(page_table, user_addr, buf, max_len) usize` | 用户→内核空间拷贝 |

#### proc/clone.zig — fork/clone (509 行, 1 pub fn)

| 函数 | 功能 |
|---|---|
| `sysClone(frame) void` | clone 系统调用，支持 CLONE_VM, CLONE_THREAD 等 |

#### proc/execve.zig — execve (788 行, 1 pub fn)

| 函数 | 功能 |
|---|---|
| `sysExecve(frame) void` | execve 系统调用，加载新 ELF 程序替换当前进程 |

#### proc/elf.zig — ELF 加载器 (240 行, 2 pub fns)

| 函数 | 功能 |
|---|---|
| `loadElf(page_table, data) !ElfInfo` | 加载 ELF64 程序头，建立内存映射 |
| `getHeader(data) ?*Elf64Header` | 获取 ELF 文件头 |

#### proc/signal.zig — 信号处理 (611 行, 8 pub fns)

| 函数 | 功能 |
|---|---|
| `postSignal(proc, sig: u6) void` | 向进程投递信号 |
| `checkAndDeliver(frame) void` | 检查并投递待处理信号 |
| `terminateBySignal(frame, sig) void` | 信号终止进程 |
| `sysKill/sysRtSigaction/sysRtSigprocmask/sysRtSigreturn(frame) void` | 信号相关系统调用 |
| `writeSignalName(sig) void` | 调试：输出信号名 |

#### proc/futex.zig — 快速用户空间互斥 (231 行, 2 pub fns)

| 函数 | 功能 |
|---|---|
| `sysFutex(frame) void` | futex 系统调用 (FUTEX_WAIT/WAKE) |
| `wakeAddress(page_table, uaddr, max_wake) u64` | 唤醒等待在地址上的线程 |

#### proc/epoll.zig — I/O 多路复用 (430 行, 4 pub fns)

| 函数 | 功能 |
|---|---|
| `wakeAllWaiters() void` | 唤醒所有等待者 |
| `sysEpollCreate1/sysEpollCtl/sysEpollWait(frame) void` | epoll 系统调用 |

#### proc/user_program.zig — 用户程序辅助 (911 行, 0 pub fns)

提供用户空间程序加载和管理的内部辅助函数。

---

## 7. 文件系统子系统 (fs/)

**路径：** `kernel/fs/` (8,296 行)  
**职责：** VFS 抽象层、磁盘文件系统、伪文件系统、管道

### 7.1 模块间调用关系

```
┌─────────────────────────────────────────────┐
│                  VFS 层                      │
│  vfs.zig — Inode, FileDescription, mount    │
└──────┬──────────┬───────────┬───────────────┘
       │          │           │
  ┌────▼───┐ ┌───▼────┐ ┌───▼────┐
  │  ext2  │ │ ext3/  │ │ ext4/  │
  │ (读写) │ │ (日志) │ │(完整ext4)│
  └────────┘ └────────┘ └────────┘
       │          │           │
  ┌────▼──────────────────────────┐
  │        块设备 I/O              │
  │  virtio_blk / nvme            │
  └───────────────────────────────┘

  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐
  │ ramfs  │ │ tmpfs  │ │ procfs │ │ devfs  │
  │ 内存FS │ │ /tmp   │ │ /proc  │ │ /dev   │
  └────────┘ └────────┘ └────────┘ └────────┘
                                    ┌────────┐
                                    │  pipe  │
                                    │ 管道   │
                                    └────────┘
```

### 7.2 文件详解

#### fs/vfs.zig — 虚拟文件系统 (506 行, 11 pub fns)

VFS 核心：Inode 抽象、FileDescription、挂载点管理。

| 函数签名 | 功能 |
|---|---|
| `checkFlockConflict(target, lock_op: u8) bool` | 文件锁冲突检测 |
| `allocFileDescription() ?*FileDescription` | 分配文件描述 |
| `releaseFileDescription/releaseFileDescriptionNoClose(desc) void` | 释放文件描述 |
| `mount(path: []const u8, root_inode: *Inode) bool` | 挂载文件系统 |
| `getRootInode() ?*Inode` | 获取根 Inode |
| `resolve/resolveNoFollow(path) ?*Inode` | 路径解析 |
| `resolvePath(path) ResolveResult` | 完整路径解析 (带最后分量) |
| `statFromInode(inode, st: *Stat) void` | Inode → stat 结构 |
| `readWholeFile(path, buf: []u8) ?usize` | 读取整个文件 |

#### fs/ext2.zig — ext2 文件系统 (2,254 行, 12 pub fns)

完整的 ext2 读写实现，支持 inode 缓存、块位图、数据块分配。

| 函数签名 | 功能 |
|---|---|
| `init() bool` | 从块设备初始化 ext2 |
| `getRootInode() ?*vfs.Inode` | 获取根目录 Inode |
| `lookup(parent, name) ?*vfs.Inode` | 目录项查找 |
| `pinInode/unpinInode/unpinAllInodes(inode) void` | Inode 缓存管理 |
| `sync/syncFile() void` | 写回脏数据 |
| `deinit() void` | 卸载 |
| `writeInodeMetadata/setInodeMode/setInodeOwner(inode) void` | Inode 元数据操作 |

#### fs/ext3/ — ext3 日志文件系统

支持日志 (journal) 的 ext3 实现，位于 `kernel/fs/ext3/` 子目录。

#### fs/ext4/ — ext4 文件系统

完整 ext4 实现：日志、extents、64-bit、校验和、flex_bg。这是 aarch64 云部署的主要文件系统。

#### fs/ramfs.zig — 内存文件系统 (491 行, 4 pub fns)

| 函数签名 | 功能 |
|---|---|
| `init() *vfs.Inode` | 创建 ramfs 根 Inode |
| `create(parent, name, mode) ?*vfs.Inode` | 创建文件 |
| `unlink(parent, name) bool` | 删除文件 |
| `writeData(inode, data, offset) isize` | 写入数据 |

#### fs/tmpfs.zig — 临时文件系统 (670 行, 2 pub fns)

| 函数签名 | 功能 |
|---|---|
| `init() *vfs.Inode` | 创建 tmpfs 根 |
| `nodeFromInode(inode) ?*TmpfsNode` | 获取内部节点 |

#### fs/procfs.zig — /proc 文件系统 (494 行, 1 pub fn)

| 函数 | 功能 |
|---|---|
| `init() *vfs.Inode` | 创建 /proc 根 (cpuinfo, meminfo, maps, fd, version 等) |

#### fs/pipe.zig — 管道 (298 行, 4 pub fns)

| 函数签名 | 功能 |
|---|---|
| `getPipeIdx(inode) ?usize` | 获取管道索引 |
| `openExistingPipe(idx, access_mode) ?*vfs.FileDescription` | 打开已有管道 |
| `createPipe() ?PipeResult` | 创建管道对 |
| `checkReadiness(inode) u32` | 检查管道就绪状态 |

#### fs/gpt.zig — GPT 分区表 (205 行, 3 pub fns)

| 函数签名 | 功能 |
|---|---|
| `findLinuxRootPartition(...) ` | 查找 Linux 根分区 |
| `findEspPartition(...) ` | 查找 EFI 系统分区 |
| `print(fmt, args) void` | 打印分区信息 |

#### fs/fd_table.zig — 文件描述符表 (143 行, 5 pub fns)

| 函数签名 | 功能 |
|---|---|
| `initStdio(table) void` | 初始化 stdin/stdout/stderr |
| `fdAlloc(table, desc) ?u32` | 分配 fd |
| `fdGet(table, fd) ?*vfs.FileDescription` | 获取 fd |
| `fdClose(table, fd) bool` | 关闭 fd |
| `fdDup2(table, oldfd, newfd) i32` | dup2 |

---

## 8. 网络协议栈 (net/)

**路径：** `kernel/net/` (3,141 行)  
**职责：** 完整的 TCP/IP 网络协议栈

### 8.1 协议栈层次

```
┌─────────────────────────────────────────┐
│        应用层 (socket syscalls)          │
│  socket_syscalls.zig — sysSocket 等     │
├─────────────────────────────────────────┤
│           传输层                         │
│  tcp.zig (769行) │ udp.zig (62行)       │
├─────────────────────────────────────────┤
│           网络层                         │
│  ipv4.zig │ icmp.zig │ dhcp.zig         │
├─────────────────────────────────────────┤
│           链路层                         │
│  ethernet.zig │ arp.zig                 │
├─────────────────────────────────────────┤
│           驱动层                         │
│  nic.zig → virtio_net / gVNIC          │
├─────────────────────────────────────────┤
│           零拷贝                         │
│  zcnet.zig — 共享环形缓冲区             │
└─────────────────────────────────────────┘
```

### 8.2 文件详解

#### net/ethernet.zig — 以太网帧 (140 行, 8 pub fns)

| 函数签名 | 功能 |
|---|---|
| `parse(data) ?struct { hdr, payload }` | 解析以太网帧 |
| `build(buf, dst, src, ethertype, payload) usize` | 构建以太网帧 |
| `putU16BE/getU16BE/putU32BE/getU32BE(buf, val)` | 大端序工具 |
| `writeIpAddr/formatIpAddr(ip, buf)` | IP 地址格式化 |

#### net/arp.zig — 地址解析协议 (199 行, 5 pub fns)

| 函数签名 | 功能 |
|---|---|
| `setOurIp(ip) void` | 设置本机 IP |
| `handleArp(data) void` | 处理 ARP 包 |
| `resolve(ip) ?[6]u8` | 解析 IP → MAC |
| `sendRequest(target_ip) void` | 发送 ARP 请求 |
| `resolveBlocking(ip, timeout) ?[6]u8` | 阻塞式 ARP 解析 |

#### net/ipv4.zig — IPv4 (134 行, 4 pub fns)

| 函数签名 | 功能 |
|---|---|
| `init() void` | 初始化 IPv4 |
| `parse(data) ?struct { src_ip, dst_ip, proto, ttl, payload }` | 解析 IPv4 包 |
| `handleIpv4(data) void` | 处理传入 IPv4 包 (分发给 TCP/UDP/ICMP) |
| `send(proto, dst_ip, payload) bool` | 发送 IPv4 包 |

#### net/icmp.zig — ICMP (164 行, 3 pub fns)

| 函数签名 | 功能 |
|---|---|
| `handleIcmp(src_ip, data, ttl) void` | 处理 ICMP 包 (Echo Reply/Request) |
| `sendEchoRequest(dst_ip, id, seq, payload) bool` | 发送 ping |
| `bootPing(dst_ip) void` | 启动时连通性测试 |

#### net/tcp.zig — TCP 协议 (769 行, 10 pub fns)

完整 TCP 实现，含三次握手、4 槽 OOO 队列重排序、重传、窗口管理。

| 函数签名 | 功能 |
|---|---|
| `allocConnection/allocConnectionForServer(...) ?usize` | 分配 TCP 连接 |
| `getConnection/freeConnection(idx) ` | 连接管理 |
| `handleTcp(src_ip, data) void` | 处理传入 TCP 段 |
| `connect(conn_idx, dst_ip, dst_port) bool` | 发起 TCP 连接 |
| `sendData(conn_idx, data) isize` | 发送数据 |
| `recvData(conn_idx, buf) isize` | 接收数据 |
| `close(conn_idx) void` | 关闭连接 |
| `tcpTimerPoll() void` | TCP 定时器 (RTO 重传) |

#### net/udp.zig — UDP (62 行, 2 pub fns)

| 函数 | 功能 |
|---|---|
| `handleUdp(src_ip, data) void` | 处理 UDP 包 |
| `send(src_port, dst_ip, dst_port, payload) bool` | 发送 UDP 包 |

#### net/dhcp.zig — DHCP 客户端 (253 行, 1 pub fn)

| 函数 | 功能 |
|---|---|
| `discover(timeout) ?DhcpResult` | DHCP Discover → Offer → Request → ACK |

#### net/socket.zig — Socket 抽象 (392 行, 9 pub fns)

| 函数签名 | 功能 |
|---|---|
| `allocSocket(family, sock_type, protocol) ?usize` | 创建 socket |
| `getSocket/getSocketInode/getSocketIndexFromInode(idx)` | socket 查询 |
| `findListeningSocket(port) ?usize` | 查找监听 socket |
| `queueAcceptedConnection/allocSocketWithConn(...)` | accept 连接管理 |
| `checkReadiness(inode) u32` | socket 就绪检查 |
| `deliverIcmpReply(src_ip, data) void` | 投递 ICMP 回复 |

#### net/socket_syscalls.zig — Socket 系统调用 (579 行, 9 pub fns)

| 函数签名 | 功能 |
|---|---|
| `sysSocket/sysConnect/sysAccept/sysBind/sysListen/sysShutdown(frame) void` | Socket 操作 |
| `sysSendto/sysRecvfrom(frame) void` | 数据收发 |
| `getSocketFromInode(inode) ?*socket.Socket` | Inode → Socket 转换 |

#### net/zcnet.zig — 零拷贝网络 (331 行, 6 pub fns)

共享环形缓冲区实现，用户空间直接读取网络包，避免内核拷贝。

#### net/checksum.zig — 校验和 (68 行, 3 pub fns)

| 函数 | 功能 |
|---|---|
| `internetChecksum(data) u16` | Internet 校验和 |
| `pseudoHeaderSum(src, dst, proto, len) u32` | TCP/UDP 伪首部校验和 |
| `checksumWithSeed(seed, data) u16` | 带种子校验和 |

#### net/net.zig — 网络子系统入口 (50 行, 2 pub fns)

| 函数 | 功能 |
|---|---|
| `init() void` | 初始化整个网络栈 |
| `poll() void` | 轮询网卡接收 |

---

## 9. 设备驱动子系统 (drivers/)

**路径：** `kernel/drivers/` (4,044 行)  
**职责：** PCI 总线、存储、网络、输入设备驱动

### 9.1 文件详解

#### drivers/pci.zig — PCI 总线驱动 (276 行, 10 pub fns)

| 函数签名 | 功能 |
|---|---|
| `pciRead32/pciRead16/pciRead8(bus, device, function, offset)` | PCI 配置空间读 |
| `pciWrite32/pciWrite16(bus, device, function, offset, value)` | PCI 配置空间写 |
| `scanBus() void` | 枚举 PCI 总线上的所有设备 |
| `findDevice(vendor, device_id) ?*PciDevice` | 按 VID/DID 查找设备 |
| `findByClass(class, subclass, prog_if) ?*PciDevice` | 按类别查找设备 |
| `enableBusMastering/enableDevice(dev) void` | 启用设备 |

#### drivers/nvme.zig — NVMe 存储 (684 行, 5 pub fns)

| 函数签名 | 功能 |
|---|---|
| `init(dev: *const pci.PciDevice) bool` | 初始化 NVMe 控制器 |
| `readSectors(sector, count, buf) bool` | 读取扇区 |
| `writeSectors(sector, count, buf) bool` | 写入扇区 |
| `getCapacity() u64` | 获取磁盘容量 |
| `isInitialized() bool` | 检查初始化状态 |

#### drivers/virtio_blk.zig — virtio 块设备 (284 行, 5 pub fns)

| 函数签名 | 功能 |
|---|---|
| `init(dev) bool` | 初始化 virtio-blk |
| `readSectors/writeSectors(sector, count, buf) bool` | 块读写 |
| `handleIrq() void` | 中断处理 |
| `getCapacity() u64` | 磁盘容量 |

#### drivers/virtio_net.zig — virtio 网络设备 (392 行, 10 pub fns)

| 函数签名 | 功能 |
|---|---|
| `init(dev) bool` | 初始化 virtio-net |
| `transmit(data) bool` / `receive() ?...` / `receiveConsume() void` | 数据收发 |
| `handleIrq() void` / `isInitialized() bool` | 中断和状态 |
| `switchToZeroCopy(buf_base_phys, buf_size, count) void` | 切换零拷贝模式 |
| `switchToCopyMode() void` | 切换回拷贝模式 |
| `postRxBufferPhys(phys) void` / `transmitFromPhys(phys, len) bool` | 物理地址操作 |

#### drivers/virtio.zig — virtio 核心传输 (265 行, 11 pub fns)

| 函数签名 | 功能 |
|---|---|
| `initDevice(io_base) void` / `finishInit(io_base) void` | virtio 设备初始化 |
| `readFeatures/writeFeatures(io_base, features) void` | 特性协商 |
| `readIsrStatus(io_base) u8` | ISR 状态读取 |
| `initQueue(io_base, queue_idx) ?VirtQueue` | 初始化 virtqueue |
| `allocDescs/freeDescs(vq, head, count) void` | 描述符管理 |

#### drivers/gvnic.zig — Google Cloud gVNIC (1,249 行, 7 pub fns)

| 函数签名 | 功能 |
|---|---|
| `init(dev: *const pci.PciDevice) bool` | 初始化 gVNIC (DQO RDA 模式) |
| `isInitialized() bool` | 状态检查 |
| `transmit(data) bool` | 发送网络包 |
| `receive() ?struct { data }` / `receiveConsume() void` | 接收网络包 |
| `handleIrq() void` | 中断处理 |
| `logRxState() void` | 调试：打印接收状态 |

#### drivers/nic.zig — 网络接口抽象 (69 行, 11 pub fns)

统一网络设备接口，委托给 virtio_net 或 gVNIC。

| 函数签名 | 功能 |
|---|---|
| `registerVirtio/registerGvnic() void` | 注册网卡驱动 |
| `isInitialized() bool` | 检查网卡状态 |
| `transmit(data) bool` | 统一发送接口 |
| `receive() ?Packet` / `receiveConsume() void` | 统一接收接口 |
| `handleIrq() void` | 统一中断处理 |
| `switchToZeroCopy/switchToCopyMode(...) void` | 模式切换 |
| `transmitFromPhys/postRxBufferPhys(phys, ...) void` | 零拷贝接口 |

#### drivers/console.zig — 帧缓冲控制台 (589 行, 3 pub fns)

| 函数签名 | 功能 |
|---|---|
| `init() void` | 初始化 Limine 帧缓冲 + VGA 字体 |
| `write(buf, count) void` | 写入字符到控制台 |
| `isEnabled() bool` | 检查控制台是否可用 |

#### drivers/ps2_keyboard.zig — PS/2 键盘 (236 行, 2 pub fns)

| 函数签名 | 功能 |
|---|---|
| `init() void` | 初始化 PS/2 键盘 (IRQ1) |
| `irqHandler() void` | 键盘中断处理 (Scancode Set 1) |

---

## 10. ACPI 子系统 (acpi/)

**路径：** `kernel/acpi/` (685 行)  
**职责：** ACPI 表解析、I/O 操作

| 文件 | 职责 |
|---|---|
| acpi.zig | ACPI 子系统入口 |
| acpi_parser.zig | RSDP/XSDT/MADT/HPET 表解析 |
| acpi_tables.zig | ACPI 表结构定义 |
| acpi_io.zig | ACPI 寄存器 I/O 操作 |

---

## 11. 安全子系统 (safety/ + security/)

### safety/ (665 行)

编译期和运行时安全保障：
- **类型安全地址**：`PhysAddr` 和 `VirtAddr` 在编译期不可互换
- **comptime 结构体布局断言**：所有硬件描述符在编译期验证
- **恢复处理程序**：demand paging 等关键路径的错误恢复

### security/ (182 行)

- **eBPF 支持**：内核安全策略的 eBPF 扩展

---

## 12. 内核日志 (klog/)

**路径：** `kernel/klog/` (1,019 行)

结构化内核日志系统，支持分级日志 (scoped logging)、缓冲和定时器刷新。

---

## 13. 用户空间工具 (userspace/)

**路径：** `3rd/zigix/userspace/` (10,724 行)

| 工具 | 源文件 | 职责 |
|---|---|---|
| **zsh** | `zsh/main.zig` | Shell：行编辑、内置命令、管道、脚本 (if/for/while) |
| **zinit** | `zinit/main.zig` | init 系统 (PID 1)：fork+exec, respawn |
| **zlogin** | `zlogin/main.zig` | 登录管理器：uid/gid, /etc/passwd |
| **zcurl** | `zcurl/main.zig` | HTTP/1.0 客户端 |
| **zhttpd** | `zhttpd/main.zig` | HTTP 服务器：静态文件、目录列表 |
| **zping** | `zping/main.zig` | ICMP ping 工具 |
| **zgrep** | `zgrep/main.zig` | 文本搜索工具 |
| **zbench** | `zbench/main.zig` + `zcnet.zig` | 网络基准测试 |
| **zsshd** | `zsshd/main.zig` + `ssh.zig` + `crypto.zig` | SSH 服务器：curve25519, chacha20-poly1305, ed25519 |
| **zdpdk** | `zdpdk/main.zig` | DPDK 风格数据面 |
| **lib/sys.zig** | 系统调用库 | write, read, exit, open, close, fork, execve, wait4, getpid, getcwd, chdir, uname, pipe, dup2, mkdir, unlink, kill, setpgid, ioctl, rt_sigaction, setuid, setgid, sync 等 |

### 13.1 sys.zig — 系统调用封装库

为用户空间程序提供 Linux 兼容的系统调用接口：

```
write(fd, buf, len) → isize
read(fd, buf, len) → isize
exit(code) → noreturn
open(path, flags, mode) → isize
close(fd) → isize
fork() → isize
execve(path, argv, envp) → isize
wait4(pid, wstatus, options) → isize
getpid() → u64
getcwd(buf, size) → isize
chdir(path) → isize
uname(buf) → isize
pipe(fds) → isize
dup2(oldfd, newfd) → isize
mkdir(path, mode) → isize
unlink/unlinkat/rmdir(path) → isize
kill(pid, sig) → isize
setpgid/getpgrp() → ...
ioctl(fd, request, arg) → isize
rt_sigaction(sig, act, oldact) → isize
setuid(uid) / setgid(gid) → isize
sync_() → void
... 更多
```

---

## 14. 系统调用表概览

Zigix 实现 138 个 Linux 兼容系统调用（位于 `syscall_table.zig`, 5,459 行），主要分类：

| 类别 | 系统调用 |
|---|---|
| **文件 I/O** | read, write, open, close, lseek, pread64, pwrite64, dup, dup2, dup3 |
| **文件系统** | stat, fstat, lstat, mkdir, rmdir, unlink, rename, chmod, chown, truncate |
| **进程管理** | fork, clone, execve, exit, wait4, getpid, getppid, getuid, getgid, setuid, setgid |
| **内存管理** | mmap, munmap, mprotect, mremap, brk |
| **信号** | kill, rt_sigaction, rt_sigprocmask, rt_sigreturn |
| **网络** | socket, connect, accept, bind, listen, sendto, recvfrom, shutdown, setsockopt, getsockopt |
| **同步** | futex, epoll_create1, epoll_ctl, epoll_wait |
| **管道** | pipe, pipe2 |
| **目录** | getcwd, chdir, fchdir, getdents64 |
| **链接** | link, symlink, readlink |
| **时间** | clock_gettime, clock_nanosleep, nanosleep, gettimeofday |
| **其他** | uname, ioctl, fcntl, pivot_root, mount, umount2, sync, sysinfo |

---

## 15. 硬件目标

| 平台 | 硬件 | 状态 |
|---|---|---|
| **x86_64 QEMU** | virtio-blk, virtio-net | 完整支持 |
| **aarch64 QEMU** | cortex-a72, virtio-mmio | 完整支持 |
| **Google Cloud C4D** | x86_64, virtio | 完整支持 |
| **Google Cloud C4A Axion** | Neoverse-V2, NVMe, gVNIC | 完整支持 (自举验证) |
