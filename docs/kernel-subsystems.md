# MoQiOS 内核子系统详细设计

> **文档定位**: 描述 MoQiOS 内核各子系统的核心数据结构、API、实现状态与依赖关系。
> **修订日期**: 2026-05-29
> **关联文档**: [moqios-architecture-current.md](./moqios-architecture-current.md)

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

- fork 时父子页表共享 PT，PTE 写位清除，PTE bit9 标记 CoW
- 写入触发 #PF → handler 检查引用计数：
  - refcount == 1 → 直接置位 W
  - refcount > 1 → 分配新页 + 复制 + 引用计数递减

### 1.7 copy_from_user 页表预验证安全访问 ✅

文件: `copy_from_user.zig`

- 页表预验证方案：访问用户空间前通过walk页表确认地址可访问
- UserAccessError返回而非panic，保证内核鲁棒性
- 接口：copyFromUserChecked / copyToUserChecked / getUser / putUser / copyStringFromUser

### 1.8 mmap 文件映射 (MAP_PRIVATE/SHARED/FIXED + munmap + msync) ✅

文件: `address_space.zig` (mmap/munmap/msync), `syscall_entry.zig`

- 支持 MAP_PRIVATE / MAP_SHARED 文件映射
- 支持 MAP_FIXED 强制指定地址
- 64条VMA表管理用户态映射区
- 配套 munmap 解除映射和 msync 同步脏页
- syscall mmap: 支持匿名映射 + 文件映射 (MAP_PRIVATE)，读取文件内容到物理页

### 1.9 Swap 页面置换 (Clock算法 + 16MB swap + 水位线) ✅

文件: `swap.zig`, `arch/x86_64/paging.zig`

- Clock二次机会算法页面回收
- 4096槽swap位图管理16MB交换空间
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

### 2.2 调度器 ✅ O(1) 优先级位图 + Per-CPU 队列 + Work Stealing

文件: `scheduler.zig`

- O(1) 优先级位图调度：32 级优先级，每级一个双向链表
- `pickNext() = @ctz(bitmap) + popFront() = O(1)`
- Per-CPU 运行队列：每 CPU 独立优先级位图 + 队列
- 任务窃取（Work Stealing）：空闲 CPU 从其他 CPU 队列尾部窃取任务，平衡负载
- 时间片 10 个 tick（100ms），抢占式
- LAPIC timer ISR 触发 `schedule()`，调用 `switchContext(prev, next)`（`arch/x86_64/context.S`）

**API**: `schedule()` / `yield()` / `wakeup(task)` / `sleep(ms)` / `addTask(task)` / `stealTask(cpu)`。

### 2.3 ELF 加载器 ✅

文件: `loader.zig`

- 解析 `Elf64_Ehdr` / `Elf64_Phdr`，按 PT_LOAD 段映射
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

### 2.5 clone() 线程 (CLONE_VM/FILES/THREAD + FS_BASE TLS) ✅

文件: `task.zig`, `syscall_entry.zig`

- syscall #56，支持CLONE_VM/CLONE_FILES/CLONE_THREAD/CLONE_SETTLS
- CLONE_VM：共享地址空间创建轻量级线程
- 独立内核栈，FS_BASE TLS指针配置
- 兼容Linux clone语义

### 2.6 poll() I/O多路复用 (TCP/管道/文件) ✅

文件: `poll.zig`, `syscall_entry.zig`

- syscall #125，单线程监听多fd
- 支持TCP socket / 管道 / 文件描述符
- 事件类型：POLLIN / POLLOUT / POLLHUP / POLLNVAL
- 带超时机制（毫秒级）

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
- Inode（直接块 + 单级间接块）
- 块缓存：256 条目 + 64 桶哈希表加速查找，dirty write-back
- 间接块指针缓存：16 条目，避免重复读取间接块
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
- ethertype: 0x0800 (IPv4) / 0x0806 (ARP) / 0x86DD (IPv6, 未实现)

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

### 4.7 TCP ✅ Reno + SACK + Window Scaling + Timestamps + TIME_WAIT优化 + 扩容

文件: `tcp.zig` (1630 行)

- 16 个并发连接 (MAX_CONNECTIONS=16)，32KB 发送/接收缓冲区，32KB 窗口
- 完整 11 状态机：CLOSED / LISTEN / SYN_SENT / SYN_RCVD / ESTABLISHED / FIN_WAIT_1 / FIN_WAIT_2 / CLOSE_WAIT / CLOSING / LAST_ACK / TIME_WAIT
- 序列号 / ACK / 窗口
- Reno 拥塞控制：慢启动 / 拥塞避免 / 快速重传（3 个重复 ACK）/ 快速恢复
- 自适应 RTO（RFC 6298）：`RTO = SRTT + 4 * RTTVAR`
- SACK 选择性确认（RFC 2018）：SYN 阶段 SACK Permitted 协商；接收端乱序队列 + 自动合并；ACK 最多附带 4 个 SACK 块；发送端记分板跟踪已 SACK 段，dupACK 触发选择性重传仅丢失段；序列号环绕安全（seqLT/seqLE/seqMin/seqMax）
- Window Scaling (RFC 7323)：SYN阶段协商窗口缩放因子（shift=7，最大窗口4MB）
- Timestamps + PAWS：精确RTT测量，防止序列号环绕误判
- Keepalive + Nagle 算法
- TIME_WAIT 优化：30s→15s，新连接可复用 TIME_WAIT TCB (若序号更大)
- 窗口更新ACK：应用读取数据后发送窗口更新ACK (超过 1 MSS 时)
- 8 个并发连接，每连接 8KB 收发缓冲
- TCB（Transmission Control Block）数组
- 公开 API: `tcpGetAddrInfo()` (getsockname/getpeername), `tcpIsClosing()`

### 4.9 poll() 多路复用 ✅

文件: `poll.zig`, `socket.zig`

- 支持TCP socket事件检测（POLLIN/POLLOUT/POLLHUP）
- 集成poll()系统调用，单线程监听多连接

### 4.8 Socket API ✅ 完整 BSD-like Socket 接口

文件: `socket.zig`, `syscall_entry.zig`

封装到 FD 层：`socket` / `bind` / `listen` / `accept` / `accept4` / `connect` / `sendto` / `recvfrom` / `sendmsg` / `recvmsg` / `shutdown` / `getsockname` / `getpeername` / `setsockopt` / `getsockopt` / `close`。

- shutdown: SHUT_RD(0) / SHUT_WR(1) / SHUT_RDWR(2)，发送 FIN 半关闭
- sendmsg/recvmsg: 解析 msghdr，遍历 msg_iov 收发数据
- getsockname/getpeername: 从 TCB 构造 sockaddr_in
- accept4: 带 SOCK_NONBLOCK/SOCK_CLOEXEC 标志的 accept

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

### 5.4 SysV 共享内存 ✅ (v18.0)

文件: `sysv_shm.zig` (426 行)

- 32 个共享内存段上限，256 页/段 (1MB)
- shmget: 创建/查找段，分配物理页并清零
- shmat: 4 级页表映射到进程地址空间 (0x70000000 基址)，支持 SHM_RDONLY
- shmdt: 解除映射，支持延迟删除 (IPC_RMID 标记)
- shmctl: IPC_STAT/IPC_RMID/IPC_SET
- 系统调用: #29 (shmget), #30 (shmat), #31 (shmctl), #67 (shmdt)

### 5.5 SysV 信号量 ✅ (v18.0)

文件: `sysv_sem.zig` (179 行)

- 16 个信号量集上限，32 信号量/集
- semget: 创建/查找信号量集，IPC_CREAT/IPC_EXCL
- semop: 简化 P/V 操作，会阻塞时返回 EAGAIN
- semctl: IPC_RMID/IPC_STAT/SETVAL/GETVAL
- 系统调用: #64 (semget), #65 (semop), #66 (semctl)

### 5.5b SysV 消息队列 ✅ (v18.1)

文件: `sysv_msg.zig` (350 行)

- 16 个队列上限，8 消息/队列，512 字节/消息
- msgget: 创建/查找消息队列
- msgsnd: 发送消息 (含 mtype 类型字段)
- msgrcv: 接收消息，支持按类型过滤 (正/负/零)
- msgctl: IPC_STAT/IPC_RMID/IPC_SET
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

### 9.1 当前状态（M8-5b-2d，2026-06-07） ✅ 双核 3/3 稳定到 shell

| 能力 | 状态 |
|---|---|
| AP 启动 + LAPIC 定时器 | ✅ |
| per-CPU 调度状态（idx/slice/anchor/TSS RSP0） | ✅ |
| reschedule IPI（0xFD）+ `force_reschedule` fast-path 旁路 | ✅ |
| APIC id 来自 MADT + `lapic.id()` 刷新 | ✅ |
| 跨核 `waitpid`（`wait_cpu` + `kickChildCpus`） | ✅ |
| `Task.saved_user_rsp` + 切换同步 | ✅ 5b-2d |
| round-robin flat@AP | ⬜ 5b-2e |
| AP 上 ELF 用户任务并行 | ⬜ 5b-2c |
| FPU/SSE 按任务 | ⬜ 5b-3 |
| 范围 TLB shootdown | ⬜ M8-6 |
| per-CPU 运行队列 + work-stealing | ⬜ M8-7 |

验证：`MOQI_SMP=1` 与 `MOQI_SMP=2` 均完整跑通 `init` + `hello2`–`hello28` 到 `MoQiOS shell`。

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

### 9.5 TLB shootdown IPI ⚠️（CR3 全刷，M8-6 待范围 invlpg）

文件: `idt.zig`, `lapic.zig`, `paging.zig`

- 向量号 `0xFE`（高端未占用，避免与设备 IRQ 冲突）
- 发起方：`lapic.sendIpiAllExcludingSelf(0xFE)` 广播
- 同步：原子计数器（`AtomicU32`），主 CPU 等待所有 AP 完成（最多 1M 次 pause 超时保护，防止单核挂死整个系统）
- 接收端 ISR：CR3 重载（整页 TLB 刷新）+ `fetchSub` 递减计数 + EOI
- `idt.zig` 中向量 `0xFE` 分发到 `handleTlbShootdown()`

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

## 参考

- [moqios-architecture-current.md](./moqios-architecture-current.md)
- [build-and-toolchain.md](./build-and-toolchain.md)
- [user-space.md](./user-space.md)
- [moqios-design.md](./moqios-design.md)
