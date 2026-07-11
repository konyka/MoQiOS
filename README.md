# MoQiOS

一个使用 Zig 实现的 x86_64 操作系统内核，采用 Limine 启动协议，支持多进程、文件系统读写、网络协议栈、信号处理和交互式 Shell。

## 项目状态

**当前进度**: M11+ 及多项扩展 (TCP、ext2、AHCI/NVMe、tmpfs/procfs、SMP 尝试)。
系统可正常引导至调度器并跑通 `init` + `hello2`–`hello26` 全部用户态测试 (QEMU 串口验证)。

| 里程碑 | 功能 | 状态 |
|---|---|---|
| M1 | 内核启动 + 串口输出 + GDT/IDT | ✅ |
| M2 | 物理内存管理 + 分页 + HHDM | ✅ |
| M3 | 调度器 + 上下文切换 (轮转调度) | ✅ |
| M4 | 用户空间进程 + syscall 入口 (syscall/sysret) | ✅ |
| M5 | 多进程 + spawn + ELF 加载器 | ✅ |
| M6 | PCI 设备枚举 | ✅ |
| M7 | virtio-blk / AHCI / NVMe 驱动 + FAT32 文件系统 (读写) | ✅ |
| M8 | e1000 / virtio-net 网卡 + ARP/IPv4/ICMP/UDP/TCP 协议栈 | ✅ |
| M9 | 管道 (pipe) + dup2 + 交互式 Shell | ✅ |
| M10 | fork + execve + 进程地址空间克隆 | ✅ |
| M11+ | 信号处理、环境变量、目录操作、chdir/getcwd、fstat/unlink | ✅ |
| 扩展 | ext2 (读写)、tmpfs、procfs、统一页缓存、TCP socket API | ✅ |
| 扩展 | SMP / AP 启动 + Per-CPU 调度队列 + Work-Stealing | ✅ |
| 扩展 | FPU/SSE 任务状态保存（Lazy FPU，CR0.TS + #NM） | ✅ |
| 扩展 | 范围 TLB Shootdown（IPI + invlpg + 32 页 CR3 阈值回退） | ✅ |
| 扩展 | IPv6 协议栈（ICMPv6 + NDP 邻居发现） | ✅ |
| 扩展 | POSIX Capability 安全模型（16 个 capability 位 + 三组掩码） | ✅ |
| 扩展 | Arch 抽象层（M4 里程碑，x86_64 + riscv64 双实现） | ✅ |
| 扩展 | 调度器 Profiling 基础设施（SchedStats + /proc/sched_stats） | ✅ |

> **2026-06-21 SMP 性能三件套完成**：FPU/SSE 按任务保存 (`kernel/arch/x86_64/context_switch.zig`)、
> Per-CPU 运行队列 + Work-Stealing (`kernel/proc/per_cpu.zig`, 256 槽 LIFO)、
> 范围 TLB Shootdown (`kernel/arch/x86_64/tlb.zig`) 同时交付。三者互为前提，AP 首次
> 可**真正**跨核运行用户任务。
>
> **2026-06-21 新增功能**：IPv6 协议栈（ICMPv6 + NDP 邻居发现）、POSIX Capability 安全模型、
> Arch 抽象层（M4 完成，x86_64 + riscv64 双实现）、调度器 Profiling 基础设施。
> 详见 [docs/moqios-architecture-current.md](docs/moqios-architecture-current.md) §1.9–1.10 节。

> **2026-06 引导稳定性修复**：修复了 4 个会导致内核无法启动或健壮性不足的缺陷
> (SMP AP 启动死锁、内核栈多页映射破坏大页 HHDM、`Task` 巨型结构体导致引导栈溢出、
> 用户态坏指针拖垮内核)。详见 [docs/moqios-architecture-current.md](docs/moqios-architecture-current.md)
> 第 1.5 节。
>
> **2026-06 SMP 进展**：查明并修复了长期存在的 "LAPIC-on-AP 崩溃" 根因——AP trampoline 未启用
> `EFER.NXE`，导致 AP 冷 TLB walk 到内核 NX 页时触发保留位缺页→三重故障。修复后 AP 可稳定上线
> (`2 CPUs online`)。v27.0 进一步修复 AP 栈物理连续性、BSP reap 调度间隙、TLB shootdown EOI
> 顺序、sleepOn 阻塞延迟等 SMP 基础设施问题。
>
> **2026-06-21 SMP 性能三件套**：FPU/SSE 任务状态保存、Per-CPU 调度队列 + Work-Stealing、
> 范围 TLB Shootdown 同时完成。三者互为前提，完成后用户任务可跨核迁移，AP 参与负载均衡。

**用户程序**: ~2,300 行 C/ASM | **测试**: `init` 自动跑 `hello2`–`hello21` + Shell；`hello22`–`hello28` 可手动运行
(注: `zig build test` 当前为占位，实测以 QEMU 运行 `hello*` 为准)

## 功能特性

### 进程管理
- 多进程调度 (轮转调度，优先级支持)
- `fork()` — 完整地址空间 COW 克隆
- `execve()` — ELF 加载，支持 argv 参数传递
- `waitpid()` — 父进程等待子进程退出
- `spawn()` — 从 ramdisk 加载并启动程序
- 信号机制: kill、sigaction、sigreturn、sigprocmask
- Ctrl+C (SIGINT) 键盘中断，Shell 忽略 SIGINT

### 文件系统
- **Ramdisk**: 启动时加载的只读文件系统
- **FAT32**: virtio-blk 磁盘读写支持
  - 文件创建、读取、写入 (任意大小 I/O)
  - 文件删除 (unlink)，FAT 簇链释放
  - 目录列表 (listdir)
- 管道 (pipe) + dup2 实现 I/O 重定向
- 每进程文件描述符表

### 网络协议栈
- **e1000** 千兆网卡驱动 (PCI, MMIO, 中断)
- **ARP**: 地址解析，ARP 缓存表
- **IPv4**: 校验和计算，数据包封装
- **IPv6**: 40 字节固定头构建/解析 + 伪首部校验和
- **ICMPv6**: Echo Request/Reply + Neighbor Solicitation/Advertisement
- **NDP**: 64 项邻居缓存 + link-local EUI-64 地址生成
- **ICMP**: Echo Reply (ping 响应)
- **UDP**: sendto/recvfrom，5 个网络 syscall
- **AF_INET6**: socket 支持 IPv6 地址族 (SOCK_STREAM/SOCK_DGRAM)
- QEMU SLIRP 网络已验证 (ARP 回复 + ICMP ping)

### 内存管理
- PMM (物理内存管理器) — 页级分配/释放
- 分页 — 4 级页表 (PML4)，用户/内核地址空间隔离
- HHDM (高半区直接映射) — 物理内存直接访问
- `mmap` / `munmap` — 用户空间内存映射
- `brk` — 堆管理

### Shell 特性
- 命令执行 (fork + execve)
- 管道 (`|`) 和 I/O 重定向 (`>`, `<`)
- 内置命令: `echo`、`ls`、`cd`、`pwd`、`export`、`env`、`help`、`pid`、`exit`
- 环境变量: `export VAR=value`、`$VAR` 展开
- Ctrl+C 信号处理

### 调度与 SMP（2026-06-21 三件套完成）
- **Per-CPU 运行队列 + Work-Stealing**：256 槽环形缓冲区/CPU，本地 LIFO 保证缓存局部性，
  idle 时从其他 CPU `tail` 端窃取一半任务；尊重 `cpu_affinity`
- **FPU/SSE 按任务保存**：Lazy FPU 制度，CR0.TS + #NM 驱动，仅在任务首次碰 FPU 时 fxrstor；
  从不使用 FPU 的内核线程零开销
- **范围 TLB Shootdown**：`tlb.shootdownRange(addr, n)` 驱动 IPI + invlpg 精确无效化；
  超过 32 页阈值回退到 CR3 reload；集成到 mprotect/munmap 路径
- **调度器 Profiling**：SchedStats 10 个计数器 + `/proc/sched_stats` 虚拟文件 +
  `getStats()`/`resetStats()` 接口

### 安全模型
- **POSIX Capability**：16 个 capability 位（CAP_KILL/CAP_SETUID/CAP_NET_BIND_SERVICE 等）
- 三组掩码：effective / permitted / inheritable
- syscall 检查点：kill/bind/setuid/setgid/reboot/mount
- init 默认 ALL_CAPS，fork 继承父进程 capability
- capget/capset 系统调用读写真实三组掩码

### 跨架构支持（M4 已完成）
- **Arch 抽象层**：`kernel/arch/arch.zig` 统一接口入口（comptime 选择 ISA）
- **x86_64 实现**：`arch_impl.zig` 重导出现有模块，零回归
- **riscv64 实现**：UART16550 serial + `stvec` trap（M2）；paging/timer/context_switch stub（M3/M5）
- **迁移进度**：`main.zig`/`klog.zig` 已走 `arch.zig`；门禁含 `smoke-riscv`

## 系统调用列表

| # | 名称 | 说明 |
|---|---|---|
| 1 | write | 写入文件描述符 |
| 2 | exit | 退出进程 |
| 4 | getpid | 获取进程 ID |
| 5 | spawn | 从 ramdisk 启动程序 |
| 6 | waitpid | 等待子进程 |
| 7 | brk | 调整堆顶 |
| 8 | mmap | 映射内存 |
| 9 | open | 打开文件 |
| 10 | read | 读取文件描述符 |
| 11 | close | 关闭文件描述符 |
| 12 | munmap | 取消内存映射 |
| 13 | sigaction | 设置信号处理器 |
| 14 | sigprocmask | 设置信号掩码 |
| 15 | sigreturn | 从信号处理器返回 |
| 22 | pipe | 创建管道 |
| 33 | dup2 | 复制文件描述符 |
| 57 | fork | 克隆进程 |
| 59 | execve | 替换进程映像 |
| 62 | kill | 发送信号 |
| 63 | uname | 获取系统信息 |
| 96 | gettimeofday | 获取时间 |
| 100-104 | net_* | 网络操作 (send/recv/udp_send/udp_recv/poll) |
| 105 | getenv | 获取环境变量 |
| 106 | setenv | 设置环境变量 |
| 107 | listdir | 列出目录内容 |
| 108 | chdir | 改变工作目录 |
| 109 | getcwd | 获取当前工作目录 |
| 110 | fstat | 获取文件元数据 |
| 111 | unlink | 删除文件 |
| 228 | clock_gettime | 获取高精度时间 |

## 测试程序

| 测试 | 功能 |
|---|---|
| hello2 | 最简用户程序 (串口输出) |
| hello3 | ramdisk 文件读取 |
| hello4 | 多进程 spawn |
| hello5 | 命令行参数 (argc/argv) |
| hello7 | ELF 加载 |
| hello8 | 管道通信 |
| hello9 | fork 父子进程 |
| hello10 | fork + execve 组合 |
| hello11 | execve 目标程序 (最小 ELF) |
| hello12 | FAT32 文件写入 |
| hello13 | 信号处理 (SIGUSR1) |
| hello14 | ARP 网络通信 |
| hello15 | UDP 数据发送 |
| hello16 | 环境变量 (setenv/getenv/fork 继承) |
| hello17 | execve argv 传递验证 |
| hello18 | chdir/getcwd/fstat/uname |
| hello19 | TCP 连接 (connect + SYN) |
| hello20 | ext2 文件读取 |
| hello22 | TCP socket API (socket/bind/listen/accept) |
| hello23–25 | ext2 多级路径 / unlink / mkdir |
| hello26–27 | TCP echo server / connect() |
| hello28 | ext2 目录列举 (listdir) |

## 快速开始

### 前置条件

- Zig 0.16.0+
- QEMU (qemu-system-x86_64)
- xorriso (用于创建 ISO)

### 构建 & 运行

```bash
zig build run
```

### 仅构建

```bash
zig build
```

### 项目结构

```
MoQiOS/
├── kernel/
│   ├── arch/x86_64/     # 架构相关 (GDT, IDT, syscall, paging)
│   ├── drivers/         # 驱动 (e1000, virtio_blk, keyboard)
│   ├── fs/              # 文件系统 (VFS, FAT32, ramdisk)
│   ├── mm/              # 内存管理 (PMM, paging, HHDM, user_space)
│   ├── net/             # 网络协议栈 (ARP, IPv4, ICMP, UDP)
│   ├── proc/            # 进程管理 (task, sched, loader, signal)
│   └── debug/           # 调试 (serial, kernel_diag)
├── user/                # 用户程序
│   ├── init.S           # init 进程 (启动所有测试)
│   ├── sh.c             # 交互式 Shell
│   └── hello*.c         # 测试程序
├── tools/
│   ├── qemu_run.sh      # QEMU 启动脚本
│   └── mkramdisk.sh     # ramdisk 打包工具
├── boot/                # Limine 引导配置
├── docs/
│   ├── moqios-architecture-current.md  # 当前实现架构 (中文)
│   ├── moqios-design.md                # 长期设计目标 (中文)
│   └── moqios-implementation-plan.md   # 实施计划 (中文)
├── build.zig            # 构建配置
└── kernel/linker.ld     # 内核链接脚本
```

## 技术细节

- **启动**: Limine Boot Protocol，HHDM 直接映射
- **调度**: 轮转调度，32 页 (128KB) 高半区虚拟内核栈，支持用户/内核线程
- **内存**: 4 级页表，用户空间 0x0000000000–0x7FFFFFFFFFFF，内核高半区映射
- **中断**: IDT 256 向量，定时器/键盘/网卡中断，syscall via MSR (LSTAR)
- **网络**: e1000 legacy 描述符，Rx/Tx 环形缓冲区，中断驱动
- **编译**: `zig build` 编译内核 + 用户程序，`zig cc` 交叉编译用户 C 程序

## 许可证

MIT License

## 致谢

- [Limine](https://github.com/limine-bootloader/limine) — 启动加载器
- [Zig](https://ziglang.org/) — 系统编程语言
- [OSDev Wiki](https://wiki.osdev.org/) — 操作系统开发参考
