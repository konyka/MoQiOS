# MoQiOS 当前实现架构

> **版本**: v0.1
> **日期**: 2026-05-22
> **代码统计**: 内核 11,623 行 Zig / 52 源文件，用户空间 2,244 行 C/ASM
>
> **注意**: 本文档描述 MoQiOS v0.1 的**当前实际实现状态**，不是设计目标。
> 长期设计目标请参见 [moqios-design.md](./moqios-design.md)。

---

## 1. 概述

MoQiOS 是一个运行在 x86_64 架构上的**单体内核** (Monolithic Kernel)，使用 Zig 0.16.0 编写，
通过 Limine 引导协议启动，利用 HHDM (Higher-Half Direct Map) 进行内核地址空间映射。

### 关键技术参数

| 项目 | 值 |
|---|---|
| 目标架构 | x86_64 (freestanding) |
| 编译工具链 | Zig 0.16.0, code_model=kernel |
| 引导协议 | Limine Boot Protocol |
| 地址空间模型 | HHDM (Higher-Half Direct Map) |
| 最大进程数 | 64 (MAX_TASKS) |
| 内核栈大小 | 16 页 = 64KB (KERNEL_STACK_PAGES) |
| 用户代码段基址 | 0x00400000 (4MB) |
| 用户栈顶 | 0x00800000 (8MB) |
| 系统调用数量 | 35 |
| 文件系统 | FAT32 (virtio-blk 后端) + ramdisk |
| 网络设备 | e1000 (QEMU SLIRP) |
| 内核代码量 | 11,623 行 Zig |
| 用户代码量 | 2,244 行 C/ASM |

---

## 2. 启动流程

```
QEMU / 真机
  │
  ├─ Limine Bootloader (BIOS/UEFI)
  │    ├─ 加载内核 ELF 至内存
  │    ├─ 设置 HHDM 映射
  │    └─ 跳转至 kernel_main
  │
  ├─ kernel_main() [kernel/main.zig]
  │    ├─ 解析 Limine 启动信息 (boot_info.zig)
  │    ├─ 初始化 GDT (gdt.zig) — 代码/数据/TSS 段
  │    ├─ 初始化 IDT (idt.zig) — 异常 + IRQ 中断
  │    ├─ 初始化串口 (serial.zig) — COM1 调试输出
  │    ├─ 初始化物理内存管理器 (pmm.zig)
  │    ├─ 初始化页表 (paging.zig)
  │    ├─ 初始化 TSC 时钟 (tsc.zig)
  │    ├─ 初始化键盘驱动 (keyboard.zig)
  │    ├─ 初始化 PCI 设备枚举 (pci.zig)
  │    ├─ 初始化 virtio-blk 块设备 (virtio_blk.zig)
  │    ├─ 初始化 FAT32 文件系统 (fat32.zig)
  │    ├─ 创建 ramdisk 设备 (ramdisk.zig)
  │    ├─ 创建内核线程: init 任务
  │    └─ 启动调度器 (sched.zig) — sti + hlt 循环
  │
  └─ init 任务 (内核线程)
       ├─ 延迟初始化网络模块 (net/mod.zig) — 不能在 boot 阶段初始化
       └─ 加载并执行 /init (user/init.S)
            ├─ 启动 hello3, hello4, hello5, hello7, hello8
            ├─ 启动 hello12, hello13, hello14, hello15, hello16
            ├─ 启动 hello9, hello10 (fork 测试)
            └─ 启动 shell (sh.c)
```

### 关键启动细节

- **HHDM**: Limine 在启动时将全部物理内存映射到高地址区域，内核通过 HHDM 偏移访问物理页
- **网络延迟初始化**: `net_mod.init()` 不能在 boot 阶段调用（会导致未解释的死锁），而是在第一个 init 内核线程中执行
- **init.S**: 用户空间第一个进程，通过 `spawn` 系统调用启动所有测试程序和 shell

---

## 3. 内存管理

### 3.1 物理内存管理 (PMM)

**源文件**: `kernel/mm/pmm.zig` (267 行)

- 基于位图的物理页帧分配器
- 从 Limine 提供的内存映射中获取可用物理页
- 提供 `allocPage()` / `freePage()` 接口
- 使用 HHDM 将物理地址转换为内核可访问的虚拟地址

### 3.2 虚拟内存 (分页)

**源文件**: `kernel/arch/x86_64/paging.zig`

- 4 级页表: PML4 → PDPT → PD → PT → Page
- 页表标志: Present, Read/Write, User/Supervisor, No-Execute
- `mapPage(pml4, virt, phys, flags)`: 映射单个虚拟页
- `unmapPage(pml4, virt)`: 取消映射
- COW fork 时使用写保护 (Read-Only + COW 标志)

### 3.3 用户地址空间

**源文件**: `kernel/mm/user_space.zig`

```
用户空间布局:
0x00400000 ───────────  代码段 (ELF 加载地址)
              │
              │  (brk/mmap 堆区域)
              │
0x00800000 ───────────  栈顶 (栈向下增长)
```

- **代码段**: 0x400000，ELF 程序头直接映射
- **栈**: 从 0x800000 向下增长，初始 4 页 (16KB)
- **brk**: 程序断点，通过 `brk()` 系统调用扩展
- **mmap**: 通过 `mmap()` 系统调用映射匿名内存

### 3.4 内核栈

每个任务分配 KERNEL_STACK_PAGES=16 页 (64KB) 内核栈。
64KB 是必要的，因为网络系统调用链中的缓冲区可达 2048 字节，
嵌套调用会超过 32KB 栈空间。

---

## 4. 进程管理

### 4.1 Task 结构体

**源文件**: `kernel/proc/task.zig` (464 行)

Task 结构体约 6000 字节，包含：

| 字段 | 类型 | 说明 |
|---|---|---|
| state | enum | ready / running / blocked / zombie |
| pid | u32 | 进程 ID |
| ppid | u32 | 父进程 ID |
| pml4 | u64 | 页表物理地址 |
| kernel_stack | u64 | 内核栈虚拟地址 |
| rsp0 | u64 | 内核栈顶 (TSS 用) |
| rip | u64 | 恢复执行地址 |
| rsp | u64 | 恢复时的栈指针 |
| rflags | u64 | 恢复时的标志寄存器 |
| fds | [32]?Fd | 文件描述符表 |
| brk_base | u64 | brk 基地址 |
| brk_current | u64 | 当前 brk 位置 |
| cwd | [256]u8 | 当前工作目录 |
| cwd_len | u32 | cwd 长度 |
| envp | ?[*:null]?[*:0]u8 | 环境变量数组 |
| env_count | u32 | 环境变量数量 |
| signal_handler | ?*const fn | 信号处理函数 |
| signal_mask | u64 | 信号掩码 |
| waiting_for_child | bool | 是否在等待子进程 |
| exit_status | u32 | 退出状态码 |

### 4.2 进程状态

```
                    spawn / fork
    [不存在] ──────────────────→ [ready]
                                    │
                          scheduler ──→ [running]
                                    │       │
                    preempt / yield │       │ exit
                                    │       ↓
                                    │   [zombie] ──→ waitpid ──→ [不存在]
                                    │
                          I/O wait  │
                                    ↓
                                [blocked]
                                    │
                          I/O done  │
                                    └──→ [ready]
```

### 4.3 进程创建

- **createKernelThread()**: 分配内核栈，设置入口函数，标记为 ready
- **createUserProcess()**: 分配用户地址空间，加载 ELF，构建用户栈 (argc/argv/envp/auxv)
- **fork()**: COW 克隆父进程地址空间，复制文件描述符表和环境变量，继承 cwd
- **execve()**: 替换进程地址空间，重新加载 ELF，重建用户栈

### 4.4 用户栈构建

**源文件**: `kernel/proc/loader.zig` (686 行)

`buildUserStack()` 构建如下栈布局：

```
低地址 ←─────────────────────────────── 高地址
│ ... │ envp[0] │ ... │ envp[n] │ NULL │
│ padding (可选，对齐用) │
│ argv[0] │ ... │ argv[n] │ NULL │
│ argc (8 bytes) │
│ auxv entries │
                        ← RSP (16 字节对齐)
```

关键：padding 位于 envp-NULL 和 argv-NULL 之间，
确保 RSP 在 argc 之前为 16 字节对齐。

---

## 5. 调度器

**源文件**: `kernel/proc/sched.zig` (261 行)

- **算法**: 简单轮转调度 (Round-Robin)
- **时间片**: 由定时器中断驱动 (LAPIC Timer)
- **上下文切换**: 通过 `switch_to` 汇编实现，保存/恢复所有通用寄存器
- **抢占**: 定时器中断中检查是否需要切换
- **空闲**: 无 ready 任务时执行 `hlt` 指令

### 调度流程

```
定时器中断
  │
  ├─ 保存当前任务寄存器到 Task 结构体
  ├─ 将当前任务标记为 ready
  ├─ 扫描 tasks[] 数组，找到下一个 ready 任务
  ├─ 切换页表 (PML4) 如果需要
  ├─ 更新 TSS.rsp0 为新任务内核栈顶
  └─ switch_to(new_task.rsp) → 恢复新任务寄存器
```

---

## 6. 系统调用

**源文件**: `kernel/arch/x86_64/syscall_entry.zig` (2069 行)

### 6.1 系统调用机制

- 使用 `syscall` / `sysret` 指令 (通过 MSR LSTAR 设置入口点)
- 用户态通过 `syscall` 指令进入内核，syscallDispatch 根据 rax 分发
- SyscallFrame 结构保存所有寄存器
- 返回值通过 rax 传递，错误通过 rax = -errno 表示

### 6.2 系统调用表 (35 个)

| 编号 | 名称 | 功能 |
|---|---|---|
| 1 | write | 写入文件描述符 |
| 2 | exit | 终止当前进程 |
| 4 | getpid | 获取进程 ID |
| 5 | spawn | 创建新进程执行程序 |
| 6 | waitpid | 等待子进程退出 (当前为 hlt 忙等待) |
| 7 | brk | 调整程序断点 |
| 8 | mmap | 映射匿名内存 |
| 9 | open | 打开文件 |
| 10 | read | 读取文件描述符 |
| 11 | close | 关闭文件描述符 |
| 12 | munmap | 取消内存映射 |
| 13 | sigaction | 设置信号处理函数 |
| 14 | sigprocmask | 修改信号掩码 |
| 15 | sigreturn | 从信号处理函数返回 |
| 22 | pipe | 创建管道 |
| 33 | dup2 | 复制文件描述符 |
| 57 | fork | 克隆当前进程 (COW) |
| 59 | execve | 执行新程序 |
| 62 | kill | 发送信号 |
| 63 | uname | 获取系统信息 |
| 96 | gettimeofday | 获取当前时间 |
| 100 | net_send | 发送原始网络帧 |
| 101 | net_recv | 接收原始网络帧 |
| 102 | udp_send | 发送 UDP 数据报 |
| 103 | udp_recv | 接收 UDP 数据报 |
| 104 | net_poll | 轮询网络事件 (驱动 RX 队列) |
| 105 | getenv | 获取环境变量 |
| 106 | setenv | 设置环境变量 |
| 107 | listdir | 列出目录内容 |
| 108 | chdir | 改变工作目录 |
| 109 | getcwd | 获取当前工作目录 |
| 110 | fstat | 获取文件状态信息 |
| 111 | unlink | 删除文件 |
| 228 | clock_gettime | 获取高精度时间 |

### 6.3 设计细节

- **write**: 支持三种 fd — stdout/stderr (VGA+串口), stdin (键盘), 文件 fd
- **fork**: COW 克隆地址空间，设置所有页为 Read-Only，缺页时才复制
- **execve**: 完全替换地址空间，释放旧页表，加载新 ELF，构建新栈
- **waitpid**: 当前实现为 hlt 忙等待循环 (阻塞版本曾尝试但导致不稳定)
- **net_poll**: 唯一驱动 e1000 RX 队列清理的 syscall，udp_recv 不清理 (避免重入)

---

## 7. 文件系统

### 7.1 VFS 层

**源文件**: `kernel/fs/vfs.zig` (308 行)

虚拟文件系统抽象层，统一管理不同类型的文件：
- **ramdisk 文件**: 启动时从内核嵌入的 ramdisk 镜像加载
- **FAT32 文件**: 通过 virtio-blk 块设备访问
- **管道**: 进程间通信的环形缓冲区
- **设备文件**: stdin/stdout/stderr

文件描述符表 (fds) 每进程 32 个槽位。

### 7.2 FAT32 文件系统

**源文件**: `kernel/fs/fat32.zig` (771 行)

- 基于 virtio-blk 块设备驱动
- 支持: open, read, write, create, delete, stat, listdir
- `deleteFile()`: 标记目录项为 0xE5，遍历 FAT 簇链释放所有簇
- 缓存: 在内存中维护打开文件数组，避免频繁磁盘 I/O
- 路径解析: 支持绝对路径和相对路径 (相对于 cwd)

### 7.3 Ramdisk

**源文件**: `kernel/fs/ramdisk.zig`

- 启动时由 Limine 模块加载的内存文件系统
- 存储: init, hello2-hello18, shell 等用户程序
- 只读，用于存放可执行文件

### 7.4 块设备驱动

| 驱动 | 文件 | 行数 | 说明 |
|---|---|---|---|
| virtio-blk | kernel/drivers/virtio_blk.zig | 522 | 主存储设备 |
| AHCI | kernel/drivers/ahci.zig | 638 | SATA 控制器 (已实现，未为主要文件系统) |

---

## 8. 网络协议栈

**源文件**: `kernel/net/` 目录，共 467 行

### 8.1 网络层次

```
用户程序
  │
  ├─ syscall: net_send / net_recv / udp_send / udp_recv / net_poll
  │
  ├─ UDP 层 (udp.zig) — 端口复用，校验和计算
  ├─ ICMP 层 (icmp.zig) — Echo Reply 响应
  ├─ IPv4 层 (ipv4.zig) — 分片，校验和，路由
  ├─ ARP 层 (arp.zig) — 地址解析缓存
  ├─ Ethernet 层 (eth.zig) — 帧封装
  │
  ├─ 网络接口层 (netif.zig) — 接口管理
  └─ e1000 驱动 (drivers/e1000.zig, 413 行)
       ├─ TX/RX 描述符环 (各 128 个)
       ├─ Legacy 描述符格式 (16 字节)
       ├─ DMA 缓冲区管理
       └─ PCI 配置 (Bus Master + INTx Disable)
```

### 8.2 e1000 驱动关键点

- 必须设置 PCI Bus Master 位 (bit 2) 并禁用 INTx (bit 10)
- TX/RX 描述符必须恰好 16 字节 (Legacy 格式)
- 使用 DMA 进行零拷贝数据传输
- RX 队列仅由 `net_poll` 清理，`udp_recv` 不清理 (避免重入问题)

### 8.3 QEMU SLIRP 网络

- 使用 QEMU `-netdev user` (SLIRP) 后端
- 响应 ARP 请求和 ICMP ping
- UDP 数据包可收发 (需手动绑定端口)

---

## 9. 信号处理

**源文件**: `kernel/proc/signal.zig` (199 行)

- 支持信号: SIGINT (2), SIGILL (4), SIGFPE (8), SIGKILL (9), SIGSEGV (11), SIGTERM (15), SIGUSR1 (10), SIGUSR2 (12), SIGPIPE (13), SIGCHLD (20) 等
- `sigaction()`: 注册信号处理函数
- `sigprocmask()`: 阻塞/解除阻塞信号
- `sigreturn()`: 从信号处理函数返回，恢复原始上下文
- `kill()`: 向指定进程发送信号
- **Ctrl+C**: 键盘中断处理中检测，向前台进程发送 SIGINT
- **信号投递**: 仅在 `waitpid` 系统调用返回时检查 (`checkSignalsOnSyscallReturn`)

---

## 10. 管道与 I/O

**源文件**: `kernel/ipc/ipc.zig` (443 行)

- `pipe()`: 创建一对文件描述符 (读端 + 写端)
- 内部使用环形缓冲区 (4096 字节)
- `dup2()`: 复制文件描述符，用于 I/O 重定向
- Shell 使用管道连接进程: `cmd1 | cmd2`

---

## 11. 用户空间

### 11.1 init 进程

**源文件**: `user/init.S` (~540 行)

启动时第一个用户进程，按顺序 spawn:
- hello3 (ramdisk 读写) x2
- hello4 (多进程)
- hello5 (ELF 加载验证)
- hello7 (FAT32 写入) x2
- hello8 (网络 ARP)
- hello12 (信号处理)
- hello13 (UDP 网络)
- hello14 (环境变量)
- hello15 (fork+信号)
- hello16 (execve)
- hello9 (fork) x2
- hello10 (execve+pipe) x2
- shell

共 18 个输出检查点，全部稳定通过。

### 11.2 测试程序

| 程序 | 测试内容 |
|---|---|
| hello2 | 基本串口输出 |
| hello3 | ramdisk 文件读写 |
| hello4 | 多进程 spawn |
| hello5 | ELF 加载 + 参数传递 |
| hello7 | FAT32 文件创建/写入 |
| hello8 | 网络 ARP 请求 |
| hello9 | fork 系统调用 |
| hello10 | execve + 管道 |
| hello12 | 信号处理 (sigaction/sigreturn) |
| hello13 | UDP 收发 |
| hello14 | 环境变量 (getenv/setenv) |
| hello15 | fork + 信号传递 |
| hello16 | execve + argv |
| hello17 | fork+execve 自身 + argv 验证 + uname |
| hello18 | chdir/getcwd/fstat |

注: hello17 和 hello18 位于 ramdisk 中但不包含在 init.S 自动测试中
(加入后导致其他测试间歇性挂起，原因疑为调度器时序敏感)。

### 11.3 Shell

**源文件**: `user/sh.c` (~460 行)

交互式命令行 Shell，支持:
- 基本命令执行 (从 ramdisk/FAT32 加载程序)
- `cd [path]` — 改变工作目录
- `pwd` — 显示当前工作目录
- `ls` — 列出目录内容
- `echo` — 输出文本
- `export VAR=val` — 设置环境变量
- `env` — 显示所有环境变量
- 管道: `cmd1 | cmd2`
- Ctrl+C 中断

---

## 12. 中断与异常

**源文件**: `kernel/arch/x86_64/idt.zig` (553 行)

- IDT 设置: 异常 (0-31) + IRQ (32-47) + 系统调用 (0x80)
- 键盘 IRQ1: 读取扫描码，检测 Ctrl+C 发送 SIGINT
- 定时器 IRQ0: 触发调度器时间片轮转
- 异常处理: 缺页 (#PF) 用于 COW，通用保护错误 (#GP) 输出诊断信息

---

## 13. 内核模块依赖图

```
kernel/main.zig
  ├── arch/x86_64/
  │   ├── gdt.zig          — GDT/TSS 设置
  │   ├── idt.zig          — IDT/中断处理
  │   ├── paging.zig       — 页表管理
  │   ├── syscall_entry.zig — 系统调用入口 + 35 个处理函数
  │   └── exception.zig    — 异常处理器
  │
  ├── mm/
  │   ├── pmm.zig          — 物理内存分配器
  │   ├── user_space.zig   — 用户地址空间常量
  │   └── addr_space.zig   — COW 地址空间克隆
  │
  ├── proc/
  │   ├── task.zig         — Task 结构体 + 创建/退出
  │   ├── sched.zig        — 轮转调度器
  │   ├── loader.zig       — ELF 加载器 + 栈构建
  │   └── signal.zig       — 信号投递
  │
  ├── fs/
  │   ├── vfs.zig          — 虚拟文件系统
  │   ├── fat32.zig        — FAT32 实现
  │   └── ramdisk.zig      — ramdisk 设备
  │
  ├── drivers/
  │   ├── pci.zig          — PCI 配置空间
  │   ├── virtio_blk.zig   — virtio 块设备
  │   ├── ahci.zig         — AHCI/SATA
  │   ├── e1000.zig        — e1000 网卡
  │   └── keyboard.zig     — PS/2 键盘
  │
  ├── net/
  │   ├── mod.zig          — 网络模块初始化
  │   ├── netif.zig        — 网络接口
  │   ├── eth.zig          — Ethernet 帧
  │   ├── arp.zig          — ARP 协议
  │   ├── ipv4.zig         — IPv4 协议
  │   ├── icmp.zig         — ICMP 协议
  │   └── udp.zig          — UDP 协议
  │
  └── ipc/
      └── ipc.zig          — 管道实现
```

---

## 14. 已知限制

1. **无 SMP**: 仅支持单核运行，无多核调度
2. **无 TCP**: 网络协议栈仅支持 ARP/IPv4/ICMP/UDP
3. **阻塞式 waitpid**: 使用 hlt 忙等待而非真正的阻塞唤醒 (尝试过但导致不稳定)
4. **调度器时序敏感**: 增加进程数量 (如 hello17/18) 会导致其他进程间歇性挂起
5. **无 ext4**: 文件系统仅 FAT32 和 ramdisk
6. **无交换分区**: 物理内存耗尽时无 swap 机制
7. **用户栈固定大小**: 未实现栈自动扩展
8. **无安全模型**: 无用户权限、capability 等安全机制
9. **e1000 仅 QEMU**: 未测试真实硬件
10. **无 Windows 兼容**: 当前仅支持 Linux ELF 二进制格式

---

## 15. 源文件清单

### 内核源文件 (按大小排序)

| 文件 | 行数 | 功能 |
|---|---|---|
| kernel/arch/x86_64/syscall_entry.zig | 2069 | 系统调用入口 + 35 个处理函数 |
| kernel/fs/fat32.zig | 771 | FAT32 文件系统 |
| kernel/proc/loader.zig | 686 | ELF 加载器 + 用户栈构建 |
| kernel/drivers/ahci.zig | 638 | AHCI/SATA 驱动 |
| kernel/arch/x86_64/idt.zig | 553 | 中断描述符表 |
| kernel/drivers/virtio_blk.zig | 522 | virtio-blk 块设备驱动 |
| kernel/drivers/pci.zig | 465 | PCI 配置空间枚举 |
| kernel/proc/task.zig | 464 | Task 结构体 + 进程管理 |
| kernel/ipc/ipc.zig | 443 | 管道 + 进程间通信 |
| kernel/drivers/e1000.zig | 413 | e1000 网卡驱动 |
| kernel/fs/vfs.zig | 308 | 虚拟文件系统 |
| kernel/mm/pmm.zig | 267 | 物理内存管理 |
| kernel/proc/sched.zig | 261 | 轮转调度器 |
| kernel/main.zig | 256 | 内核主函数 |
| kernel/proc/signal.zig | 199 | 信号处理 |

**总计: 52 个 .zig 文件, 11,623 行**
