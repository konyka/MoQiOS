# MoQiOS 实施计划

> **版本**: v0.4
> **日期**: 2026-05-22
> **说明**: 本文档记录 MoQiOS 的实际实施进度和已完成里程碑。
> 长期设计目标参见 [moqios-design.md](./moqios-design.md)，当前架构参见 [moqios-architecture-current.md](./moqios-architecture-current.md)。

---

## 当前状态

- **内核**: 11,623 行 Zig, 52 个源文件
- **用户空间**: 2,244 行 C/ASM
- **系统调用**: 35 个
- **自动化测试**: 18 个 (hello2-hello18) + 交互式 Shell
- **测试稳定性**: 5/5 次连续通过 (hello17/18 手动运行)
- **最大进程数**: 64
- **文件系统**: FAT32 (virtio-blk) + ramdisk
- **网络**: e1000 (ARP/IPv4/ICMP/UDP)

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
| 文件删除 | unlink(111) | FAT32 目录项标记 0xE5, FAT 簇链释放 |
| 时间 | gettimeofday(96), clock_gettime(228) | TSC 高精度计时 |

**关键文件**: signal.zig (199 行), syscall_entry.zig (新增处理函数)

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
| TCP 协议 | 未设计详细方案 | 未开始 |
| SMP 多核支持 | 未设计详细方案 | 未开始 |
| ext4 文件系统 | 未设计详细方案 | 未开始 |
| 交换分区 (swap) | 未设计详细方案 | 未开始 |
| 用户权限/安全模型 | 未设计详细方案 | 未开始 |
| 栈自动扩展 | 未设计详细方案 | 未开始 |
| 阻塞式 I/O | 尝试过 waitpid 阻塞，不稳定 | 需要调试 |
| Windows PE 二进制兼容 | 设计文档中有方案 | 未开始 |
| 微内核服务化改造 | 设计文档中有方案 | 未开始 |
| 真机硬件支持 | 未设计 | 仅在 QEMU 验证 |

---

## 下一步方向

### Phase 1: 稳定化

- 调查 hello17/18 init.S 不稳定根因 (调度器时序)
- 实现可靠的阻塞式 waitpid
- 修复网络延迟初始化问题

### Phase 2: 网络扩展

- 实现 TCP 协议 (可靠传输)
- Socket 抽象层
- 网络服务器 (echo/http)

### Phase 3: 文件系统扩展

- ext2/ext4 只读支持
- 文件系统缓存优化
- 虚拟文件系统增强

### Phase 4: 多核

- LAPIC/APIC 支持
- 多核调度
- 内核锁细化 (per-CPU 数据)

---

## 修订历史

| 版本 | 日期 | 说明 |
|---|---|---|
| v0.4 | 2026-05-22 | 重写：反映实际实现状态，移除未实现的微内核/Windows 计划 |
| v0.3 | 2026-05-22 | 添加 M11+ 进度，更新系统调用表 |
| v0.2 | 2026-05-20 | 更新 M1-M10 完成状态 |
| v0.1 | 2026-05-15 | 初始版本 |
