# MoQiOS 第三方依赖概览

> 路径：`3rd/`  
> 总大小：约 3.5GB

---

## 依赖总览

| 项目 | 版本 | 大小 | 语言 | 许可证 | 用途 |
|---|---|---|---|---|---|
| **Zigix** | v45c | 73MB | Zig | 项目私有 | 核心操作系统内核 |
| **Linux** | 7.0.6 | 1.7GB | C + Rust + ASM | GPL-2.0 | 系统调用/协议栈参考 |
| **ReactOS** | 0.4.15 | 1.2GB | C + ASM | GPL-2.0 | Windows NT 设计参考 |
| **QNX Neutrino** | (SVN 导出) | 79MB | C + ASM | QNX EULA | 微内核 RTOS 架构参考 |
| **Dim-Sum** | (Gitee) | 422MB | C + ASM | GPL | 简化 Linux 风格内核参考 |
| **MINUX 3** | (学习版) | 2.5MB | C + ASM | - | MINIX 3 微内核教学参考 |

---

## Zigix — 核心 OS 内核

**详细文档：** [zigix-architecture.md](./zigix-architecture.md)

| 属性 | 值 |
|---|---|
| **来源** | [Quantum Zig Forge](https://github.com/quantum-encoding/quantum-zig-forge) |
| **作者** | QUANTUM ENCODING LTD |
| **描述** | 双架构 (x86_64 + aarch64) 操作系统内核 |
| **特性** | Linux 二进制兼容, 自举, 138 个系统调用, 完整 TCP/IP |
| **代码量** | 内核 88,595 行 + 用户空间 10,724 行 |
| **Git 历史** | 3 commits |
| **在 MoQiOS 中的角色** | 核心内核代码, 直接编译使用 |

### 关键能力

- 已在 Google Cloud Axion (ARM64) 裸金属上实现自举
- BusyBox 1.36.1 完全兼容 (10/10 测试通过)
- 完整 ext4 文件系统 (日志, extents, 64-bit)
- 完整 TCP/IP 协议栈 + TLS 1.3
- SMP 多核调度 (2 CPUs)
- 零拷贝网络 (zcnet)
- SSH 服务器 (zsshd)
- HTTP 服务器 (zhttpd)

---

## Linux 7.0.6 — 参考实现

**详细文档：** [linux-7.0.6-architecture.md](./linux-7.0.6-architecture.md)

| 属性 | 值 |
|---|---|
| **来源** | kernel.org |
| **描述** | Linux 内核源码 |
| **支持架构** | 23 种 (x86, arm64, riscv, ...) |
| **Git 历史** | 完整 Linux 历史 |
| **在 MoQiOS 中的角色** | 纯参考，不参与编译 |

### 主要参考领域

| 领域 | 参考目录 | 参考内容 |
|---|---|---|
| 系统调用 | `kernel/`, `init/` | 138 个系统调用的语义规范 |
| 调度器 | `kernel/sched/` | CFS/RT/Deadline 算法 |
| 内存管理 | `mm/` | 伙伴系统、slab、页回收 |
| 文件系统 | `fs/ext4/`, `fs/` | ext4 日志、VFS 设计 |
| 网络栈 | `net/ipv4/`, `net/tcp/` | TCP 状态机、拥塞控制 |
| 驱动 | `drivers/virtio/`, `drivers/pci/` | PCI/virtio/NVMe 接口 |
| 同步 | `kernel/futex/`, `kernel/locking/` | futex、mutex、RCU |
| IO_uring | `io_uring/` | 异步 I/O 设计 |

---

## ReactOS 0.4.15 — Windows NT 参考

**详细文档：** [reactos-architecture.md](./reactos-architecture.md)

| 属性 | 值 |
|---|---|
| **来源** | reactos.org |
| **描述** | Windows NT 兼容操作系统 |
| **目标兼容** | Windows Server 2003 |
| **构建系统** | CMake |
| **在 MoQiOS 中的角色** | 纯参考，不参与编译 |

### 主要参考领域

| 领域 | 参考目录 | 参考内容 |
|---|---|---|
| NT 内核架构 | `ntoskrnl/` | 执行体分层 (Ke/Ex/Ps/Mm/Io/Ob/Se) |
| 驱动模型 | `drivers/wdm/`, `drivers/` | WDM/NDIS 驱动框架 |
| 文件系统 | `drivers/filesystems/ext2/` | ext2 驱动实现 |
| 网络驱动 | `drivers/network/` | TCP/IP 栈, NDIS |
| 对象管理 | `ntoskrnl/ob/` | 命名空间、引用计数 |
| 安全 | `ntoskrnl/se/` | 安全引用监控器 |
| PE 加载器 | `dll/ntdll/ldr/` | DLL 加载和解析 |
| 注册表 | `ntoskrnl/config/` | 配置管理器 |

---

## QNX Neutrino — 微内核 RTOS 参考

**详细文档：** [qnx-neutrino-architecture.md](./qnx-neutrino-architecture.md)

| 属性 | 值 |
|---|---|
| **来源** | QNX 官方 SVN 库导出 |
| **描述** | 微内核实时操作系统 |
| **支持架构** | ARM, MIPS, PPC, SH, x86 |
| **代码量** | 2,773 .c + 894 .h + 262 .asm = 394,653 行 |
| **在 MoQiOS 中的角色** | 纯参考，不参与编译 |

### 主要参考领域

| 领域 | 参考目录 | 参考内容 |
|---|---|---|
| 微内核架构 | `services/system/ker/` | 最小内核设计 (190 .c 文件) |
| 消息传递 IPC | `ker/nano_message.c`, `ker/ker_message.c` | MsgSend/Receive/Reply |
| 实时调度 | `ker/nano_sched.c`, `ker/ker_sched.c` | SCHED_FIFO/RR 实现 |
| 内存管理 | `services/system/memmgr/` | 用户空间内存管理器 (108 .c) |
| 资源管理器 | `lib/c/iofunc/`, `lib/c/dispatch/` | QNX 驱动/服务模型 |
| 内核调用 | `lib/c/kercalls/` | 用户空间→微内核系统调用桩 |

---

## Dim-Sum — 简化 Linux 风格内核

**详细文档：** [dim-sum-architecture.md](./dim-sum-architecture.md)

| 属性 | 值 |
|---|---|
| **来源** | Gitee (谢宝友) |
| **描述** | 自研 OS 内核，Linux 风格但大幅简化 |
| **支持架构** | ARM64 (Cortex-A53), RISC-V 64 |
| **代码量** | ~272,683 行, 633 个 .c 文件 |
| **在 MoQiOS 中的角色** | 纯参考，不参与编译 |

### 主要参考领域

| 领域 | 参考目录 | 参考内容 |
|---|---|---|
| 简化内核 | `kernel/`, `init/` | Linux 风格但可读的内核实现 |
| 自研 ext3 | `fs/lext3/` + `fs/journal/` | 从零实现的日志文件系统 |
| 内存管理 | `mm/` | 蜂巢分配器、伙伴系统 |
| ARM64 启动 | `arch/arm64/` | QEMU virt 启动流程 |
| RISC-V | `arch/riscv64/` | Sv39 页表实现 |
| klibc | `adapter/klibc/` | 266 个精简 C 库函数 |
| lwIP 网络栈 | `net/lwip-1.4.1/` | 嵌入式 TCP/IP 集成 |

---

## MINUX 3 — MINIX 3 微内核教学参考

**详细文档：** [minux3-architecture.md](./minux3-architecture.md)

| 属性 | 值 |
|---|---|
| **来源** | 自研学习项目 (参考《操作系统设计与实现(第三版)》) |
| **描述** | MINIX 3 学习版，加入中文注释 |
| **支持架构** | x86 (8088 实模式 + 80386 保护模式) |
| **代码量** | 91 .c + 107 .h + 7 .s = 30,395 行 |
| **在 MoQiOS 中的角色** | 纯参考，不参与编译 |

### 主要参考领域

| 领域 | 参考目录 | 参考内容 |
|---|---|---|
| 微内核架构 | `kernel/` | 最经典教学微内核 (~5,000 行) |
| 消息传递 IPC | `kernel/proc.c`, `kernel/ipc.h` | send/receive/sendrec 同步消息 |
| 进程管理 | `servers/pm/` | fork/exec/exit/signal 完整实现 |
| 文件系统 | `servers/fs/` | Inode + buffer cache + 块设备分层 |
| 用户空间驱动 | `drivers/`, `drivers/libdriver/` | 驱动框架 + 消息驱动模型 |
| x86 保护模式 | `kernel/protect.c`, `kernel/mpx386.s` | GDT/LDT/IDT 段式内存保护 |

---

## 文档索引

| 文档 | 内容 |
|---|---|
| [zigix-architecture.md](./zigix-architecture.md) | Zigix 内核完整架构（模块 → 文件 → 函数调用） |
| [linux-7.0.6-architecture.md](./linux-7.0.6-architecture.md) | Linux 7.0.6 子系统架构（子系统 → 模块 → 关键文件） |
| [reactos-architecture.md](./reactos-architecture.md) | ReactOS 子系统架构（子系统 → 模块 → 关键文件） |
| [dim-sum-architecture.md](./dim-sum-architecture.md) | Dim-Sum 简化内核架构（模块 → 文件 → 功能） |
| [qnx-neutrino-architecture.md](./qnx-neutrino-architecture.md) | QNX Neutrino 微内核架构（服务→模块→文件） |
| [minux3-architecture.md](./minux3-architecture.md) | MINUX 3 微内核教学架构（内核→服务→驱动→头文件） |
| [3rd-party-overview.md](./3rd-party-overview.md) | 本文档：依赖概览和参考价值 |
