# Dim-Sum OS 架构文档

> 来源：[Gitee - xiebaoyou/dim-sum](https://gitee.com/xiebaoyou/dim-sum) | 大小：422MB | 语言：C + 汇编  
> 路径：`3rd/dim-sum/`  
> 在 MoQiOS 中的用途：**参考实现**（Linux 风格内核的简化实现，ARM64/RISC-V64 架构）

---

## 1. 项目概览

| 属性 | 值 |
|---|---|
| **项目名** | Dim-Sum (点心) |
| **描述** | 自研操作系统内核，风格类似 Linux，但大幅简化 |
| **来源** | Gitee (谢宝友) |
| **源码大小** | 422MB (含工具链) |
| **语言** | C (主体) + ARM64/RISC-V 汇编 |
| **构建系统** | Linux Kbuild (Makefile + Kconfig) |
| **支持架构** | ARM64 (Cortex-A53, QEMU virt), RISC-V 64 |
| **交叉编译** | aarch64-elf-gcc (Linaro 5.3) |
| **运行环境** | QEMU (virt machine) |
| **网络栈** | lwIP 1.4.1 (嵌入式 TCP/IP) |
| **文件系统** | lext3 (带日志), ramfs, devfs, romfs |
| **许可证** | GPL |
| **微信联系** | linux-kernel |

### 1.1 代码量统计

| 模块 | 行数 (.c + .h) | .c 文件数 |
|---|---|---|
| **net/** (含 lwIP) | 63,976 | 70 |
| **scripts/** | 36,400 | 56 |
| **include/** | 32,589 | 0 |
| **arch/** | 29,852 | 49 |
| **adapter/** (klibc) | 28,009 | 266 |
| **fs/** | 26,924 | 46 |
| **drivers/** | 15,204 | 32 |
| **usr/** | 12,246 | 27 |
| **mm/** | 8,585 | 17 |
| **kernel/** | 7,959 | 38 |
| **lib/** | 5,373 | 16 |
| **block/** | 2,635 | 9 |
| **init/** | 478 | 6 |
| **ipc/** | 453 | 1 |
| **总计** | ~272,683 | ~633 |

### 1.2 顶层目录结构

```
dim-sum/
├── conv.sh           # 编码转换脚本 (GB2312 → UTF-8)
├── Makefile           # 顶层构建脚本
├── README             # 中文使用说明
├── .gitignore         # Git 忽略规则
├── script/            # 构建/开发脚本
├── toolchains/        # 交叉编译工具链 (gcc-linaro aarch64)
└── src/               # 内核源码主体
    ├── arch/          # 架构相关 (arm64, riscv64)
    ├── block/         # 块设备层
    ├── drivers/       # 设备驱动
    ├── fs/            # 文件系统
    ├── include/       # 头文件
    ├── init/          # 内核启动入口
    ├── ipc/           # 进程间通信
    ├── kernel/        # 核心内核 (调度, 锁, IRQ, 时间)
    ├── lib/           # 内核库
    ├── mm/            # 内存管理
    ├── net/           # 网络栈 (lwIP)
    ├── scripts/       # Kbuild 脚本
    ├── usr/           # 用户空间 (initramfs, shell)
    └── adapter/       # klibc 适配层 (C 标准库子集)
```

---

## 2. 构建系统

### 2.1 顶层 Makefile

```makefile
# 编译内核
make kernel
# → cd src; make ARCH=arm64 CROSS_COMPILE=.../aarch64-elf- Image dtbs

# 运行
make run
# → qemu-system-aarch64 -machine virt -cpu cortex-a53 -smp 4 -m 1024 ...

# 一键编译+运行
make        # = make kernel + make run
```

### 2.2 运行配置

| 参数 | 值 |
|---|---|
| Machine | QEMU virt |
| CPU | Cortex-A53 |
| SMP | 4 核 |
| 内存 | 1024 MB |
| 存储 | virtio-blk (dim-sum.img) |
| 网络 | virtio-net (tap) |
| 控制台 | ttyAMA0 (串口) |
| 根文件系统 | ext3 (日志盘独立分区) |

---

## 3. 架构支持 (arch/)

### 3.1 ARM64 (arm64/)

| 子目录 | 职责 |
|---|---|
| `kernel/` | 异常向量、上下文切换、系统调用入口、SMP 启动 |
| `mm/` | 页表操作、TLB 维护、缺页处理 |
| `lib/` | 架构特定库函数 (memcpy, memset 等) |
| `boot/` | 内核映像构建、设备树 (DTS) |
| `include/asm/` | ARM64 架构头文件 |
| `configs/` | defconfig 配置 |

### 3.2 RISC-V 64 (riscv64/)

| 子目录 | 职责 |
|---|---|
| `kernel/` | RISC-V 特权级异常、上下文切换、SBI 调用 |
| `mm/` | Sv39 页表操作 |
| `lib/` | RISC-V 架构库函数 |
| `boot/` | 内核映像构建 |
| `include/asm/` | RISC-V 架构头文件 |
| `configs/` | defconfig |

---

## 4. 内核核心 (kernel/)

**路径：** `kernel/` (38 .c 文件, 7,959 行)  
**职责：** 进程管理、调度、同步、中断、系统调用

### 4.1 目录结构

```
kernel/
├── sched/            # CPU 调度器
│   ├── core.c        # 调度核心 (pick_next_task, context_switch)
│   ├── task.c        # 任务管理
│   ├── wait.c        # 等待队列
│   ├── sleep.c       # 睡眠/唤醒
│   └── idle.c        # 空闲任务
├── locking/          # 同步原语
│   ├── mutex.c       # 互斥锁
│   ├── semaphore.c   # 信号量
│   ├── rwsem.c       # 读写信号量
│   ├── percpu.c      # per-CPU 变量
│   ├── smp_lock.c    # SMP 自旋锁
│   ├── smp_rwlock.c  # SMP 读写锁
│   ├── smp_bit_lock.c # SMP 位锁
│   └── smp_seq_lock.c # SMP 顺序锁
├── irq/              # 中断管理
│   ├── irq.c         # 中断核心
│   ├── controller.c  # 中断控制器抽象
│   ├── map.c         # 中断映射
│   └── maintain.c    # 中断维护
├── time/             # 时间管理
│   ├── time.c        # 时间函数
│   ├── timer.c       # 定时器
│   └── timer_device.c # 定时器设备
├── sh_kapi/          # Shell 内核 API
├── count/            # 内核计数器
├── cpu.c             # CPU 管理
├── execve.c          # execve 系统调用
├── signal.c          # 信号处理
├── smp.c             # SMP 多核管理
├── syscall.c         # 系统调用
├── workqueue.c       # 工作队列
├── kallsyms.c        # 内核符号表
├── printk.c          # 内核打印
├── panic.c           # panic 处理
└── bounds.c          # 编译期常量生成
```

### 4.2 关键文件

| 文件 | 职责 |
|---|---|
| `sched/core.c` | 调度核心：任务选择、上下文切换、时间片调度 |
| `sched/task.c` | 任务创建、销毁、状态管理 |
| `syscall.c` | 系统调用分发 |
| `execve.c` | ELF 程序加载执行 |
| `signal.c` | POSIX 信号投递和处理 |
| `smp.c` | 多核启动、IPI、CPU 热插拔 |
| `irq/irq.c` | 中断注册、分发、处理 |
| `locking/mutex.c` | 互斥锁实现 |
| `time/timer.c` | 内核定时器 |

---

## 5. 内存管理 (mm/)

**路径：** `mm/` (17 .c 文件, 8,585 行)

### 5.1 文件详解

| 文件 | 职责 |
|---|---|
| `boot_allotter.c` | 启动期内存分配器 (memblock 风格) |
| `beehive_allotter.c` | 蜂巢分配器 (slab 风格对象缓存) |
| `page_allotter.c` | 物理页分配器 (伙伴系统) |
| `page_num.c` | 页帧号 (PFN) 管理 |
| `page_cache.c` | 页缓存 (address_space) |
| `page_flush.c` | 脏页回写 |
| `page_writeback.c` | 页面写回控制 |
| `readahead.c` | 预读机制 |
| `vmm.c` | 虚拟内存管理 (VMA) |
| `mmu.c` | MMU/页表操作 |
| `memory.c` | 核心内存操作 (缺页, COW) |
| `mem_init.c` | 内存子系统初始化 |
| `init_mm.c` | 内核地址空间初始化 |
| `swap.c` | 交换空间管理 |
| `truncate.c` | 页面截断 |
| `phys_regions.c` | 物理内存区域管理 |
| `mem_cmd.c` | 内存调试命令 |

### 5.2 Dim-Sum 特有概念

| 概念 | 说明 |
|---|---|
| **beehive_allotter** | 蜂巢分配器 — 类似 Linux slab 的对象缓存分配器 |
| **boot_allotter** | 启动分配器 — 系统启动期间使用的简单分配器 |
| **page_allotter** | 页分配器 — 物理页帧的伙伴系统分配 |

---

## 6. 文件系统 (fs/)

**路径：** `fs/` (46 .c 文件, 26,924 行)

### 6.1 支持的文件系统

| 文件系统 | 路径 | .c 文件数 | 职责 |
|---|---|---|---|
| **lext3** | `fs/lext3/` | 14 | Dim-Sum 自研 ext3 (带日志) |
| **journal** | `fs/journal/` | 7 | 日志子系统 (JBD 风格) |
| **ramfs** | `fs/ramfs/` | 1 | 内存文件系统 |
| **devfs** | `fs/devfs/` | 1 | 设备文件系统 (/dev) |
| **romfs** | `fs/romfs/` | 2 | 只读文件系统 (含 cpio) |

### 6.2 lext3 — 自研 ext3 文件系统

Dim-Sum 的主文件系统，兼容 ext3 格式：

| 文件 | 职责 |
|---|---|
| `super.c` | 超级块读写、文件系统挂载 |
| `node.c` / `node_ops.c` / `node_alloc.c` | inode 管理 (分配、操作、缓存) |
| `file.c` | 文件读写操作 |
| `dir.c` | 目录项操作 |
| `block.c` | 数据块分配和管理 |
| `space.c` | 磁盘空间管理 |
| `journal.c` | 日志集成 |
| `ioctl.c` | ioctl 操作 |
| `fsync.c` | 文件同步 |
| `symlink.c` | 符号链接 |
| `error.c` | 错误处理 |

### 6.3 journal — 日志子系统

| 文件 | 职责 |
|---|---|
| `journal.c` | 日志管理器核心 |
| `transaction.c` | 事务管理 (begin, commit) |
| `checkpoint.c` | 检查点 (将日志写回磁盘) |
| `commit.c` | 日志提交 |
| `revoke.c` | 日志撤销 |
| `recover.c` | 日志恢复 (崩溃恢复) |

---

## 7. 块设备层 (block/)

**路径：** `block/` (9 .c 文件, 2,635 行)

| 子目录/文件 | 职责 |
|---|---|
| `partitions/` | 分区解析 |
| 块设备核心 | 请求队列、bio 管理、I/O 调度 |

---

## 8. 设备驱动 (drivers/)

**路径：** `drivers/` (32 .c 文件, 15,204 行)

| 子目录 | .c 数 | 职责 |
|---|---|---|
| `tty/` | 9 | TTY 子系统 (串口终端) |
| `base/` | 7 | 驱动核心框架 (设备模型, 总线) |
| `dt/` | 4 | 设备树解析 |
| `irqchip/` | 3 | 中断控制器驱动 (GIC) |
| `virtio/` | 3 | virtio 设备驱动 (virtio-blk, virtio-net) |
| `clocksource/` | 2 | 时钟源驱动 |
| `amba/` | 1 | AMBA 总线驱动 |
| `block/` | 1 | 块设备驱动 |
| `char/` | 1 | 字符设备驱动 |
| `net/` | 1 | 网络设备驱动框架 |
| `of/` | 0 | Open Firmware 辅助 (纯头文件) |

---

## 9. 网络栈 (net/)

**路径：** `net/` (70 .c 文件, 63,976 行 — 大部分来自 lwIP)

### 9.1 lwIP 1.4.1

Dim-Sum 使用开源 **lwIP** (轻量级 TCP/IP) 协议栈作为网络实现：

```
net/
├── lwip-1.4.1/       # lwIP 协议栈源码
│   └── src/           # 核心、IPv4、TCP、UDP、DHCP、DNS 等
├── apps/             # 网络应用
│   ├── ping.c        # Ping 工具
│   ├── tftp.c        # TFTP 客户端
│   └── netcmd.c      # 网络命令
├── netdev.c          # 网络设备抽象层
└── netdev.h
```

---

## 10. 进程间通信 (ipc/)

**路径：** `ipc/` (1 .c 文件, 453 行)

| 文件 | 职责 |
|---|---|
| `msg_queue.c` | System V 风格消息队列 |

---

## 11. 初始化 (init/)

**路径：** `init/` (6 .c 文件, 478 行)

| 文件 | 职责 |
|---|---|
| `main.c` | 内核主入口 `start_kernel()` |
| `init_task.c` | 初始任务 (PID 0) |
| `initramfs.c` | initramfs 解压和挂载 |
| `calibrate.c` | BogoMIPS 校准 |
| `version.c` | 版本信息 |
| `test.c` | 内核测试函数 |

---

## 12. 用户空间 (usr/)

**路径：** `usr/` (27 .c 文件, 12,246 行)

| 子目录/文件 | 职责 |
|---|---|
| `shell/` | Dim-Sum 内置 Shell |
| `lwip_file.c` | 基于 lwIP 的文件操作 |
| `app.c` | 用户应用程序入口 |
| `initramfs_data.S` | initramfs 嵌入数据 |
| `gen_init_cpio.c` | cpio 镜像生成工具 |

---

## 13. C 库适配层 (adapter/)

**路径：** `adapter/klibc/` (266 .c 文件, 28,009 行)

提供精简的 C 标准库实现 (klibc 风格)，供内核和用户空间使用：

| 类别 | 包含函数 |
|---|---|
| **字符串** | strcpy, strcat, strcmp, strlen, memcpy, memset, ... |
| **内存** | malloc, free, calloc, realloc, brk |
| **I/O** | printf, sprintf, fprintf, open, read, write, close |
| **文件系统** | stat, mkdir, opendir, readdir, mount |
| **进程** | fork, exec, exit, wait, getpid |
| **环境** | getenv, setenv, clearenv |
| **排序/搜索** | qsort, bsearch |
| **时间** | time, clock, localtime |
| **其他** | assert, errno, getopt, syslog, daemon, ... |

---

## 14. 内核库 (lib/)

**路径：** `lib/` (16 .c 文件, 5,373 行)

| 文件 | 职责 |
|---|---|
| `string.c` | 字符串操作 |
| `vsprintf.c` | 格式化输出 |
| `rbtree.c` | 红黑树 |
| `radix-tree.c` | 基数树 |
| `idr.c` | ID 分配器 |
| `object.c` | 对象管理 |
| `elf.c` | ELF 解析 |
| `libfdt.c` | Flattened Device Tree 解析 |
| `ctype.c` | 字符类型 |
| `find_next_bit.c` / `find_last_bit.c` | 位操作 |
| `ioremap.c` | I/O 内存映射 |
| `scatterlist.c` | scatter-gather 列表 |
| `virt_space.c` | 虚拟地址空间管理 |
| `dump_stack.c` | 栈转储 |
| `dec_and_lock.c` | 原子递减+锁 |

---

## 15. 头文件 (include/)

**路径：** `include/` (32,589 行)  
包含 154 个核心头文件 (在 `include/dim-sum/` 中)

### 15.1 关键头文件

| 头文件 | 职责 |
|---|---|
| `dim-sum/sched.h` | 调度器接口 |
| `dim-sum/process.h` | 进程/任务结构 |
| `dim-sum/mm.h` | 内存管理接口 |
| `dim-sum/page_allotter.h` | 页分配器 |
| `dim-sum/beehive_allotter.h` | 蜂巢分配器 |
| `dim-sum/blk_dev.h` / `blk_infrast.h` | 块设备框架 |
| `dim-sum/vfs.h` (fs.h) | 文件系统接口 |
| `dim-sum/lext3_fs.h` | lext3 文件系统 |
| `dim-sum/journal.h` | 日志子系统 |
| `dim-sum/device.h` | 设备模型 |
| `dim-sum/irq.h` | 中断管理 |
| `dim-sum/mutex.h` / `semaphore.h` | 同步原语 |
| `dim-sum/netdev.h` | 网络设备 |
| `dim-sum/virtio.h` | virtio 接口 |
| `dim-sum/printk.h` | 内核打印 |
| `dim-sum/syscall.h` | 系统调用 |
| `dim-sum/tty.h` | TTY 接口 |
| `dim-sum/rbtree.h` | 红黑树 |
| `dim-sum/device_tree.h` | 设备树 |

### 15.2 兼容层头文件

`include/linux/` — 提供 Linux 风格的兼容头文件，方便移植代码。  
`include/asm-generic/` — 架构无关的汇编头文件。  
`include/kapi/` — 内核 API 头文件。  
`include/uapi/` — 用户空间 API 头文件。  
`include/scsi/` — SCSI 相关定义。

---

## 16. Dim-Sum 特有设计

### 16.1 命名约定

Dim-Sum 使用独特的中文友好命名：

| Linux 概念 | Dim-Sum 命名 | 说明 |
|---|---|---|
| slab allocator | **beehive_allotter** | 蜂巢分配器 |
| memblock | **boot_allotter** | 启动分配器 |
| buddy allocator | **page_allotter** | 页分配器 |
| ext3 | **lext3** | Dim-Sum 的 ext3 实现 |

### 16.2 与 Linux 的对比

| 特性 | Linux | Dim-Sum |
|---|---|---|
| 代码量 | ~3000 万行 | ~27 万行 |
| 架构支持 | 23 种 | 2 种 (ARM64, RISC-V) |
| 文件系统 | 40+ | 5 种 (lext3, ramfs, devfs, romfs) |
| 网络栈 | 完整自研 TCP/IP | lwIP 1.4.1 (嵌入式) |
| 驱动数 | 数万 | ~32 个核心驱动 |
| 调度器 | CFS/RT/Deadline | 简单时间片调度 |
| SMP | 完善的 CFS 负载均衡 | 基础 4 核支持 |

---

## 17. 在 MoQiOS 中的参考价值

| 领域 | 参考内容 |
|---|---|
| **简化内核架构** | Linux 风格但大幅简化的代码，易于理解内核原理 |
| **ARM64 启动** | QEMU virt 平台启动流程、设备树解析 |
| **RISC-V 支持** | Sv39 页表、SBI 调用的简化实现 |
| **自研文件系统** | lext3 + journal 的从零实现 (14+7 = 21 文件) |
| **内存管理** | 蜂巢分配器、启动分配器的清晰实现 |
| **klibc 适配** | 266 个 C 标准库函数的精简实现 |
| **设备树** | libfdt 集成和设备树解析 |
| **lwIP 集成** | 嵌入式 TCP/IP 在内核中的集成方式 |
| **中文注释** | 代码包含中文注释，便于学习 |
