# MoQiOS 实施计划

> **版本**: v0.8
> **日期**: 2026-05-25
> **说明**: 本文档记录 MoQiOS 的实际实施进度和已完成里程碑。
> 长期设计目标参见 [moqios-design.md](./moqios-design.md)，当前架构参见 [moqios-architecture-current.md](./moqios-architecture-current.md)。

---

## 当前状态

- **内核**: 15,400 行 Zig, 54 个源文件
- **系统调用**: 49 个
- **自动化测试**: 28 个 (hello2-hello26, init.S) + 交互式 Shell
- **测试稳定性**: 28/28 通过 (KVM -smp 1)
- **最大进程数**: 64
- **文件系统**: FAT32 (virtio-blk) + ramdisk + ext2 (读写)
- **网络**: e1000 (ARP/IPv4/ICMP/UDP/TCP + Socket API)
- **多核**: SMP 支持 (BSP + AP, 2 CPUs online, 内核自旋锁)

---

## 已完成里程碑

### M1: 内核启动 + 串口输出

**状态**: 完成

- Limine 引导协议，HHDM 映射
- GDT 设置 (代码/数据/TSS 段)
- IDT 设置 (异常 + IRQ 中断)
- 串口 COM1 调试输出
- VGA 文本模式输出

**关键文件**: main.zig, gdt.zig, idt.zig, serial.zig, limine.zig, boot_info.zig, hhdm.zig, vga.zig

---

### M2: 物理内存管理 + 分页

**状态**: 完成

- 基于位图的物理页帧分配器 (PMM)
- 4 级页表 (PML4 → PDPT → PD → PT → Page)
- HHDM 物理内存直接映射
- 用户/内核地址空间隔离

**关键文件**: pmm.zig, paging.zig, page_frame.zig, user_space.zig

---

### M3: 调度器 + 上下文切换

**状态**: 完成

- 轮转调度 (Round-Robin)
- `switch_to` 汇编上下文保存/恢复
- 定时器中断驱动的抢占式调度
- 内核线程 + 用户进程支持
- Task 结构体 (pid, ppid, state, 寄存器, fds, cwd, env, signals)

**关键文件**: sched.zig, task.zig, exception.zig

---

### M4: 系统调用

**状态**: 完成

- `syscall`/`sysret` 通过 MSR LSTAR
- SyscallFrame 寄存器保存
- 初始 syscall: write(1), exit(2), getpid(4), spawn(5), waitpid(6), brk(7), mmap(8), read(10), close(11), munmap(12)

**关键文件**: syscall_entry.zig (2069 行)

---

### M5: 多进程 + ELF 加载器

**状态**: 完成

- ELF64 可执行文件加载
- 用户栈构建 (argc/argv/envp/auxv)
- 16 字节 RSP 对齐 (含 padding)
- copy_from_user 安全数据拷贝

**关键文件**: loader.zig (686 行), user_mode.zig, copy_from_user.zig

---

### M6: PCI 设备枚举

**状态**: 完成

- PCI 配置空间读写 (ECAM)
- 设备扫描 (vendor/device ID)
- Capability 链遍历
- BAR 映射 (MMIO)

**关键文件**: pci.zig (465 行), capability.zig, io.zig

---

### M7: 存储与文件系统

**状态**: 完成

- virtio-blk 块设备驱动 (VirtIO Queue)
- AHCI/SATA 驱动 (已实现)
- FAT32 文件系统 (读/写/创建/删除)
- Ramdisk 内存文件系统 (只读，存放可执行文件)
- VFS 抽象层 (统一 ramdisk/FAT32/pipe/device)

**关键文件**: virtio_blk.zig (522 行), ahci.zig (638 行), fat32.zig (771 行), ramdisk.zig, vfs.zig (308 行)

---

### M8: 网络协议栈

**状态**: 完成

- e1000 千兆网卡驱动 (PCI, MMIO, DMA)
- TX/RX 描述符环 (Legacy 格式, 128 entries)
- Ethernet 帧封装/解析
- ARP 地址解析 (请求/应答/缓存)
- IPv4 协议 (校验和, 封装)
- ICMP 协议 (Echo Reply / ping)
- UDP 协议 (sendto/recvfrom, 端口复用)
- QEMU SLIRP 验证通过

**关键文件**: e1000.zig (413 行), eth.zig, arp.zig, ipv4.zig, icmp.zig, udp.zig, netif.zig, mod.zig, dma.zig

---

### M9: 管道 + Shell

**状态**: 完成

- `pipe()` 系统调用 (环形缓冲区, 4096 字节)
- `dup2()` 文件描述符复制
- 交互式 Shell (sh.c, ~460 行)
  - 命令执行 (spawn)
  - 管道 `|`
  - 内置命令: echo, ls, cd, pwd, export, env, help, pid, exit
  - 环境变量展开 ($VAR)
  - Ctrl+C 信号处理

**关键文件**: ipc.zig (443 行), sh.c (~460 行)

---

### M10: fork + execve

**状态**: 完成

- `fork()` — COW 地址空间克隆
  - 复制父进程页表，设置所有页为 Read-Only
  - 缺页中断时复制物理页
  - 继承文件描述符表、环境变量、cwd
- `execve()` — 进程地址空间替换
  - 释放旧页表
  - 加载新 ELF
  - 重建用户栈 (argc/argv/envp)
  - 支持路径查找

**关键文件**: addr_space.zig, syscall_entry.zig (fork/execve 部分)

---

### M11+: 扩展功能

**状态**: 完成

| 功能 | 系统调用 | 说明 |
|---|---|---|
| 信号处理 | kill(62), sigaction(13), sigprocmask(14), sigreturn(15) | Ctrl+C 投递, 自定义处理函数 |
| 环境变量 | getenv(105), setenv(106) | fork 继承, Shell export/env |
| 目录操作 | chdir(108), getcwd(109), listdir(107) | 路径规范化, Shell cd/pwd |
| 文件元数据 | fstat(110), uname(63) | mode/size/type, 系统信息 |
| 文件删除 | unlink(111) | ext2: freeBlock + freeInode + removeDirEntry + unlinkFile; FAT32: 目录项标记 0xE5, FAT 簇链释放 |
| 时间 | gettimeofday(96), clock_gettime(228) | TSC 高精度计时 |

**关键文件**: signal.zig (199 行), syscall_entry.zig (新增处理函数)

---

### M12: TCP 协议

**状态**: 完成

- 三次握手 (SYN/SYN-ACK/ACK)
- 数据传输 (序列号, 滑动窗口 4096 bytes)
- 四次挥手 (FIN 关闭)
- 超时重传 (2 秒超时, 指数退避)
- 环形缓冲区 (发送 8KB, 接收 8KB)
- 最大 8 个并发连接
- 系统调用: tcp_connect(112), tcp_send(113), tcp_recv(114), tcp_close(115), tcp_poll(116)

**关键文件**: tcp.zig (687 行)

---

### M13: ext2 文件系统

**状态**: 完成 (只读)

- Superblock 解析
- Block Group Descriptor 表
- Inode 读取 (直接块 + 单级间接块)
- 目录项解析
- 文件读取
- 1024 字节块大小 (revision 0)

**关键文件**: ext2.zig (478 行)

---

### M14: SMP 多核支持

**状态**: 基本完成

- ACPI MADT 解析 (CPU LAPIC IDs)
- AP 启动: INIT IPI + SIPI
- 3 阶段 AP 引导代码 (实模式 → 保护模式 → 长模式)
- 身份映射 (identity mapping) 覆盖全部 512MB RAM
- Per-CPU GDT/TSS 初始化
- Per-CPU 数据 (cpu_id, apic_id, current_tid)
- GS Base MSR 配置
- AP 空闲循环 (sti + hlt)
- BSP/AP 串行输出确认
- QEMU `-smp 2` 验证通过, 23/23 测试通过

**已知限制**:
- LAPIC MMIO 在 AP 上不可用 (QEMU TCG 限制), AP 无定时器中断
- APIC 定时器仅在 BSP 上运行
- 内核锁未实现 (当前仅 BSP 调度)

**关键文件**: smp.zig (455 行), ap_trampoline_src.S, ap_trampoline.bin, gdt.zig (per-CPU), lapic.zig

---

## 系统调用完整列表

| 编号 | 名称 | 功能 | 里程碑 |
|---|---|---|---|
| 1 | write | 写入文件描述符 | M4 |
| 2 | exit | 终止进程 | M4 |
| 4 | getpid | 获取进程 ID | M4 |
| 5 | spawn | 创建并执行新进程 | M4 |
| 6 | waitpid | 等待子进程退出 | M4 |
| 7 | brk | 调整程序断点 | M4 |
| 8 | mmap | 映射匿名内存 | M4 |
| 9 | open | 打开文件 | M7 |
| 10 | read | 读取文件 | M4 |
| 11 | close | 关闭文件描述符 | M4 |
| 12 | munmap | 取消内存映射 | M4 |
| 13 | sigaction | 设置信号处理函数 | M11+ |
| 14 | sigprocmask | 修改信号掩码 | M11+ |
| 15 | sigreturn | 信号处理返回 | M11+ |
| 22 | pipe | 创建管道 | M9 |
| 33 | dup2 | 复制文件描述符 | M9 |
| 57 | fork | 克隆进程 (COW) | M10 |
| 59 | execve | 执行新程序 | M10 |
| 62 | kill | 发送信号 | M11+ |
| 63 | uname | 获取系统信息 | M11+ |
| 96 | gettimeofday | 获取当前时间 | M11+ |
| 100 | net_send | 发送原始网络帧 | M8 |
| 101 | net_recv | 接收原始网络帧 | M8 |
| 102 | udp_send | 发送 UDP 数据报 | M8 |
| 103 | udp_recv | 接收 UDP 数据报 | M8 |
| 104 | net_poll | 轮询网络事件 | M8 |
| 105 | getenv | 获取环境变量 | M11+ |
| 106 | setenv | 设置环境变量 | M11+ |
| 107 | listdir | 列出目录内容 | M11+ |
| 108 | chdir | 改变工作目录 | M11+ |
| 109 | getcwd | 获取当前工作目录 | M11+ |
| 110 | fstat | 获取文件状态 | M11+ |
| 111 | unlink | 删除文件 | M11+ |
| 112 | tcp_connect | TCP 连接 | M12 |
| 113 | tcp_send | TCP 发送 | M12 |
| 114 | tcp_recv | TCP 接收 | M12 |
| 115 | tcp_close | TCP 关闭 | M12 |
| 116 | tcp_poll | TCP 轮询 | M12 |
| 117 | socket | 创建 TCP socket | Phase 5 |
| 118 | bind | 绑定 socket 到端口 | Phase 5 |
| 119 | listen | 监听连接 | Phase 5 |
| 120 | accept | 接受连接 | Phase 5 |
| 121 | sendto | 发送数据 | Phase 5 |
| 122 | recvfrom | 接收数据 | Phase 5 |
| 123 | mkdir | 创建目录 | Phase 6 |
| 124 | connect | TCP socket 连接 | Phase 6 |
| 228 | clock_gettime | 高精度时间 | M11+ |

---

## 测试覆盖

### 自动化测试 (init.S, 18 个, 稳定通过)

| 程序 | 测试内容 |
|---|---|
| hello3 x2 | ramdisk 文件读写 |
| hello4 | 多进程 spawn |
| hello5 | ELF 加载 + 参数传递 |
| hello7 x2 | FAT32 文件创建/写入/读取 |
| hello8 x2 | 网络 ARP 请求/应答 |
| hello12 | 信号处理 (sigaction/sigreturn) |
| hello13 | UDP 收发 |
| hello14 | 环境变量 (getenv/setenv) |
| hello15 | fork + 信号传递 |
| hello16 | execve + argv |
| hello9 x2 | fork 系统调用 |
| hello10 x2 | execve + 管道 |
| shell | 交互式 Shell |

### ext2/网络测试 (init.S, KVM -smp 1 通过)

| 程序 | 测试内容 |
|---|---|
| hello20 | ext2 文件读取 |
| hello21 | ext2 文件创建+写入+读取验证 |
| hello22 | TCP socket API (socket/bind/listen/accept) |
| hello23 | ext2 mkdir (createDir + mkdir syscall #123) |
| hello24 | ext2 unlink (create→write→verify→unlink→verify gone) |
| hello25 | ext2 多级路径 (testdir/subfile.txt) |
| hello26 | TCP echo server (socket/bind/listen/accept/sendto/recvfrom) |

### 手动测试 (从 shell 运行, 功能验证通过)

| 程序 | 测试内容 | 不在 init.S 中的原因 |
|---|---|---|
| hello17 | fork+execve 自身 + argv 验证 + uname | 导致其他测试间歇性挂起 |
| hello18 | chdir/getcwd/fstat | 导致其他测试间歇性挂起 |

---

## 已知问题

| 问题 | 严重程度 | 说明 |
|---|---|---|
| waitpid 忙等待 | 中 | 使用 hlt 循环而非阻塞唤醒。阻塞版本曾实现但导致不稳定，已回退 |
| hello17/18 init.S 不稳定 | 中 | 加入自动测试后 hello9/hello10/shell 间歇性挂起 (~60% 失败率)，疑为调度器时序敏感 |
| 网络延迟初始化 | 低 | net_mod.init() 不能在 boot 阶段调用，原因不明 |

---

## 未完成功能

以下功能在设计文档 (moqios-design.md) 中有描述但尚未实现：

| 功能 | 设计状态 | 实施状态 |
|---|---|---|
| TCP 协议 | 完整实现 | ✅ 三次握手/数据传输/四次挥手 + Socket API (M12 + Phase 5) |
| SMP 多核支持 | 基本实现 | ✅ AP 启动/Per-CPU 数据/空闲循环/内核自旋锁 (M14 + Phase 5) |
| ext2 文件系统 | 读写实现 | ✅ Superblock/Inode/目录/文件读写 (M13 + Phase 5) |
| 内核锁 (SMP 安全) | 已实现 | ✅ IrqSpinlock: serial/PMM/task/sched (Phase 5) |
| ext2 创建文件 | 完整实现 | ✅ createFile + writeFile + unlinkFile + createDir (Phase 6) |
| 交换分区 (swap) | 未设计详细方案 | 未开始 |
| 用户权限/安全模型 | 未设计详细方案 | 未开始 |
| 栈自动扩展 | 未设计详细方案 | 未开始 |
| 阻塞式 I/O | 尝试过 waitpid 阻塞，不稳定 | 需要调试 |
| Windows PE 二进制兼容 | 设计文档中有方案 | 未开始 |
| 微内核服务化改造 | 设计文档中有方案 | 未开始 |
| 真机硬件支持 | 未设计 | 仅在 QEMU 验证 |

---

## 下一步方向

### Phase 1: 稳定化 ✅

- ~~调查 hello17/18 init.S 不稳定根因~~ → 已修复，23/23 通过
- ~~实现可靠的阻塞式 waitpid~~ → 使用 hlt 循环，稳定
- ~~修复网络延迟初始化问题~~ → 已解决

### Phase 2: 网络扩展 ✅

- ~~实现 TCP 协议~~ → M12 完成
- ~~Socket 抽象层~~ → Phase 5 完成 (syscalls 117-122)
- 网络服务器 (echo/http) → 待实现

### Phase 3: 文件系统扩展 ✅

- ~~ext2 只读支持~~ → M13 完成
- ~~ext2 写入支持~~ → Phase 5 完成 (writeBlock/writeInode/allocBlock/writeFile)
- ext2 创建文件 (createFile) → 进行中
- 文件系统缓存优化 → 待实现

### Phase 4: 多核 ✅ (基本)

- ~~LAPIC/APIC 支持~~ → BSP LAPIC 定时器完成
- ~~多核启动~~ → AP 引导 + Per-CPU 数据完成
- ~~内核锁细化~~ → Phase 5 完成 (IrqSpinlock: serial/PMM/task/sched)
- AP LAPIC 定时器 → QEMU 限制, 待解决

### Phase 5: 内核完善 ✅

- ~~内核自旋锁~~ → IrqSpinlock 保护 serial/PMM/task/sched, 锁序: sched→task→pmm
- ~~TCP socket 系统调用~~ → socket(117)/bind(118)/listen(119)/accept(120)/sendto(121)/recvfrom(122)
- ~~ext2 写入支持~~ → writeBlock, writeInode, allocBlock, ensureBlock, writeFile
- 多核调度 → PerCpu 字段已添加, AP 无定时器中断, 需要 KVM 或真机

### Phase 6: 下一步

- ~~ext2 创建文件 (createFile)~~ → hello21 测试通过 (24/24)
- ~~TCP socket API 验证~~ → hello22 测试通过: socket/bind/listen/accept 全部正确 (25/25)
- ~~TCP echo server 测试~~ → hello26 测试通过: socket/bind/listen/accept/sendto/recvfrom 完整服务端 API 验证 (28/28)
- ~~connect() syscall~~ → syscall #124: TCP socket 连接, tcpConnectSocket() 实现复用现有 TCB
- ~~ext2 mkdir~~ → hello23 测试通过: createDir + mkdir syscall #123 (26/26)
- ~~ext2 unlink~~ → hello24 测试通过: freeBlock + freeInode + removeDirEntry + unlinkFile, syscall #111 ext2 支持 (27/27)
- ~~ext2 多级路径支持~~ → resolveParent 辅助函数, createFile/createDir/unlinkFile 支持子目录操作, hello25 测试
- ~~文件系统缓存~~ → 64 条目写穿缓冲区, readBlockCached/writeBlockCached, 时钟替换策略
- 网络服务器 (echo server / HTTP server) → 待实现
- 多核调度 (需要 AP 定时器) → 阻塞
- 真机硬件支持 → 未开始

---

## 修订历史

| 版本 | 日期 | 说明 |
|---|---|---|
| v1.3 | 2026-05-25 | Phase 6: connect() syscall #124 (TCP socket 连接), tcpConnectSocket() 复用现有 TCB, 49 syscalls |
| v1.2 | 2026-05-25 | Phase 6: TCP echo server 测试 (hello26), socket/bind/listen/accept/sendto/recvfrom 完整服务端 API, 28/28 tests |
| v1.1 | 2026-05-25 | Phase 6: ext2 块缓存 (64条目写穿缓冲区, readBlockCached/writeBlockCached, 时钟替换策略) |
| v1.0 | 2026-05-25 | Phase 6 进展: ext2 多级路径支持 (resolveParent), createFile/createDir/unlinkFile 支持子目录, hello25 测试 |
| v0.9 | 2026-05-25 | Phase 6 进展: ext2 unlink (freeBlock + freeInode + removeDirEntry + unlinkFile), syscall #111 ext2 支持, hello24 测试通过, 27/27 测试, 48 syscalls |
| v0.8 | 2026-05-25 | Phase 6 进展: ext2 mkdir (createDir + syscall #123), hello23 测试通过, 26/26 测试, 47 syscalls |
| v0.7 | 2026-05-25 | Phase 6 进展: ext2 createFile 修复完成 (hello21), TCP socket API 验证 (hello22), 25/25 测试通过 |
| v0.5 | 2026-05-24 | 添加 M12 (TCP), M13 (ext2), M14 (SMP); 更新统计数据; 更新下一步方向 |
| v0.4 | 2026-05-22 | 重写：反映实际实现状态，移除未实现的微内核/Windows 计划 |
| v0.3 | 2026-05-22 | 添加 M11+ 进度，更新系统调用表 |
| v0.2 | 2026-05-20 | 更新 M1-M10 完成状态 |
| v0.1 | 2026-05-15 | 初始版本 |
