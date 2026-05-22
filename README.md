# MoQiOS

一个使用 Zig 实现的 x86_64 操作系统内核，采用 Limine 启动协议，支持多进程、文件系统读写、网络协议栈、信号处理和交互式 Shell。

## 项目状态

**当前进度**: M11+ (已完成 M1–M10 全部里程碑及多项扩展功能)

| 里程碑 | 功能 | 状态 |
|---|---|---|
| M1 | 内核启动 + 串口输出 + GDT/IDT | ✅ |
| M2 | 物理内存管理 + 分页 + HHDM | ✅ |
| M3 | 调度器 + 上下文切换 (轮转调度) | ✅ |
| M4 | 用户空间进程 + syscall 入口 (syscall/sysret) | ✅ |
| M5 | 多进程 + spawn + ELF 加载器 | ✅ |
| M6 | PCI 设备枚举 | ✅ |
| M7 | virtio-blk 驱动 + FAT32 文件系统 (读写) | ✅ |
| M8 | e1000 网卡驱动 + ARP/IPv4/ICMP/UDP 网络协议栈 | ✅ |
| M9 | 管道 (pipe) + dup2 + 交互式 Shell | ✅ |
| M10 | fork + execve + 进程地址空间克隆 | ✅ |
| M11+ | 信号处理、环境变量、目录操作、chdir/getcwd、fstat/unlink | ✅ |

**内核代码**: ~11,600 行 Zig | **用户程序**: ~2,300 行 C/ASM | **测试**: 18 个自动化测试 + Shell

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
- **ICMP**: Echo Reply (ping 响应)
- **UDP**: sendto/recvfrom，5 个网络 syscall
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
├── docs/                # 设计文档
├── build.zig            # 构建配置
└── kernel/linker.ld     # 内核链接脚本
```

## 技术细节

- **启动**: Limine Boot Protocol，HHDM 直接映射
- **调度**: 轮转调度，16 页 (64KB) 内核栈，支持用户/内核线程
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
