# MINUX 3 架构文档

> 来源：自研 MINIX 3 学习项目 | 大小：2.5MB | 语言：C + x86 汇编  
> 路径：`3rd/MINUX3/`  
> 参考：《操作系统设计与实现(第三版)》(电子工业出版社)  
> 在 MoQiOS 中的用途：**参考实现**（微内核架构、MINIX 3 经典设计）

---

## 1. 项目概览

| 属性 | 值 |
|---|---|
| **项目名** | MINUX 3 (MINIX 3 学习版) |
| **描述** | 一步一步学 MINIX 3，加入中文注释方便阅读 |
| **源码大小** | 2.5MB |
| **语言** | C (主体) + x86 实模式/保护模式汇编 |
| **支持架构** | x86 (8088 实模式 + 80386 保护模式) |
| **代码量** | 91 .c 文件 + 107 .h 文件 + 7 .s 文件 = 30,395 行 |
| **Git 历史** | 4 commits (学习笔记式提交) |
| **参考书籍** | 《操作系统设计与实现(第三版)》 |
| **在 MoQiOS 中的角色** | 纯参考 — 微内核教学代码 |

### 1.1 MINIX 3 核心特性

- **微内核架构**：内核仅提供进程调度、IPC 消息传递、中断管理、时钟
- **用户空间服务**：文件系统 (FS)、进程管理器 (PM)、重启管理器 (RS) 均在用户空间运行
- **分层的进程模型**：内核 → 系统任务 → 服务进程 → 用户进程
- **POSIX 兼容**：实现了核心 POSIX 接口
- **教学导向**：代码结构清晰，适合学习操作系统原理

### 1.2 顶层目录结构

```
MUNIX3/
├── README.md          # 项目说明
├── kernel/            # 微内核 (调度, IPC, 中断, 时钟)
│   └── system/        # 内核系统调用处理 (do_fork, do_exec 等)
├── servers/           # 用户空间系统服务
│   ├── pm/            # 进程管理器 (Process Manager)
│   ├── fs/            # 文件系统 (File System)
│   ├── rs/            # 重启/信号管理器 (Reincarnation Server)
│   └── init/          # 初始化进程 (PID 1)
├── drivers/           # 设备驱动 (用户空间)
│   ├── at_wini/       # IDE 硬盘驱动
│   ├── tty/           # 终端/控制台驱动
│   ├── memory/        # /dev/mem, /dev/null, /dev/zero
│   ├── log/           # 系统日志驱动
│   ├── libdriver/     # 驱动框架库
│   └── libpci/        # PCI 总线库
└── include/           # 头文件
    ├── minix/         # MINIX 系统头文件
    ├── sys/           # POSIX 系统头文件
    └── ibm/           # IBM PC 硬件定义
```

### 1.3 代码量分布

| 模块 | 行数 | .c 文件 | 占比 |
|---|---|---|---|
| **drivers/** | 8,331 | 13 | 27.4% |
| **servers/fs/** | 7,821 | 24 | 25.7% |
| **kernel/** | 5,206 | 37 | 17.1% |
| **servers/pm/** | 3,506 | 13 | 11.5% |
| **include/** | 4,558 | 0 | 15.0% |
| **servers/rs/** | 513 | 3 | 1.7% |
| **servers/init/** | 460 | 1 | 1.5% |
| **总计** | 30,395 | 91 | 100% |

---

## 2. MINIX 3 微内核架构

### 2.1 整体架构图

```
┌──────────────────────────────────────────────────────────┐
│                      用户空间                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐              │
│  │  用户进程  │  │  用户进程  │  │  用户进程  │              │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘              │
│       │              │              │                     │
│       │  系统调用 (send/receive)    │                     │
│       ▼              ▼              ▼                     │
│  ┌──────────────────────────────────────────┐            │
│  │              系统服务层                    │            │
│  │  ┌────────┐  ┌────────┐  ┌────────┐     │            │
│  │  │   PM   │  │   FS   │  │   RS   │     │            │
│  │  │进程管理 │  │文件系统 │  │重启管理 │     │            │
│  │  └───┬────┘  └───┬────┘  └───┬────┘     │            │
│  │      │           │           │           │            │
│  │  ┌───▼───────────▼───────────▼────┐     │            │
│  │  │         设备驱动                │     │            │
│  │  │  at_wini │ tty │ memory │ log  │     │            │
│  │  └───────────────┬─────────────────┘     │            │
│  └──────────────────┼───────────────────────┘            │
├─────────────────────┼─────────────────────────────────────┤
│                     │ IPC 消息传递                         │
│  ┌──────────────────▼─────────────────────────────────┐  │
│  │                   微内核 (kernel/)                  │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐         │  │
│  │  │   proc.c │  │ system.c │  │ clock.c  │         │  │
│  │  │ 进程调度  │  │系统调用   │  │ 时钟中断 │         │  │
│  │  └──────────┘  └──────────┘  └──────────┘         │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐         │  │
│  │  │protect.c │  │ i8259.c  │  │exception │         │  │
│  │  │ 内存保护  │  │ 中断控制 │  │ 异常处理  │         │  │
│  │  └──────────┘  └──────────┘  └──────────┘         │  │
│  └────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────┐  │
│  │                硬件抽象 (x86)                       │  │
│  │  mpx.s/mpx386.s │ klib.s/klib386.s │ start.c      │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

### 2.2 进程分层模型

```
层 0: 内核 (kernel/)           — 调度、IPC、中断、时钟
层 1: 系统任务 (kernel/system/) — 内核系统调用处理 (do_fork, do_exec 等)
层 2: 系统服务 (servers/)       — PM, FS, RS, INIT (用户空间)
层 3: 设备驱动 (drivers/)       — 磁盘, 终端, 内存, 日志 (用户空间)
层 4: 用户进程                  — 应用程序
```

---

## 3. 微内核 (kernel/)

**路径：** `kernel/` (37 .c 文件, 5,206 行)  
**职责：** 进程调度、消息传递、中断管理、内存保护

### 3.1 核心文件

| 文件 | 职责 |
|---|---|
| **main.c** | 内核主入口 — 初始化进程表、中断向量、调度各任务 |
| **proc.c** | 进程管理 — 调度器 (`pick_proc`)、上下文切换、进程状态管理 |
| **system.c** | 系统任务 — 内核调用分发器 |
| **clock.c** | 时钟驱动 — 定时器中断、时间片调度 |
| **protect.c** | 内存保护 — GDT、LDT、段描述符设置 |
| **exception.c** | 异常处理 — 缺页、一般保护错误、双故障等 |
| **i8259.c** | 8259A PIC — 可编程中断控制器管理 |
| **start.c** | 内核启动 — 实模式→保护模式切换、C 运行时初始化 |

### 3.2 汇编文件

| 文件 | 架构 | 职责 |
|---|---|---|
| `mpx.s` / `mpx88.s` | 8088 | 实模式中断处理、进程切换 |
| `mpx386.s` | 80386 | 保护模式中断/异常入口、进程切换 |
| `klib.s` / `klib88.s` | 8088 | 内核汇编工具函数 |
| `klib386.s` | 80386 | 保护模式内核工具 (端口 I/O, 启用/禁用中断) |

### 3.3 内核头文件

| 头文件 | 职责 |
|---|---|
| `kernel.h` | 内核主头文件 (包含所有依赖) |
| `proc.h` | 进程表结构 (`proc[]`) |
| `protect.h` | 保护模式结构 (GDT, IDT, 段选择子) |
| `config.h` | 内核配置常量 |
| `const.h` | 内核常量定义 |
| `glo.h` | 全局变量声明 |
| `priv.h` | 特权信息结构 |
| `ipc.h` | IPC 消息结构定义 |
| `proto.h` | 函数原型声明 |
| `sconst.h` | 系统常量 (中断向量等) |

### 3.4 内核系统调用处理 (kernel/system/)

28 个 `do_*.c` 文件，每个处理一个内核级操作：

| 文件 | 功能 |
|---|---|
| `do_fork.c` | fork() — 创建子进程，复制进程表项 |
| `do_exec.c` | execve() — 加载新程序映像，设置栈 |
| `do_exit.c` | exit() — 终止进程，释放资源 |
| `do_kill.c` | kill() — 向进程发送信号 |
| `do_sigsend.c` | 信号投递 |
| `do_sigreturn.c` | 信号处理返回 |
| `do_endksig.c` | 内核信号处理结束 |
| `do_getksig.c` | 获取待处理内核信号 |
| `do_nice.c` | nice() — 调整进程优先级 |
| `do_copy.c` | 进程间内存拷贝 |
| `do_vcopy.c` | 虚拟地址拷贝 |
| `do_umap.c` | 虚拟→物理地址映射 |
| `do_newmap.c` | 设置进程内存映射 |
| `do_memset.c` | 内存设置 |
| `do_segctl.c` | 段控制 (设置 LDT) |
| `do_devio.c` | 设备 I/O (in/out 端口操作) |
| `do_sdevio.c` | 安全设备 I/O |
| `do_vdevio.c` | 虚拟设备 I/O |
| `do_irqctl.c` | 中断控制 (挂钩/取消挂钩 IRQ) |
| `do_int86.c` | 实模式 BIOS 调用 |
| `do_setalarm.c` | 设置定时器告警 |
| `do_times.c` | 获取进程执行时间 |
| `do_getinfo.c` | 获取内核信息 |
| `do_trace.c` | 进程追踪 (ptrace) |
| `do_privctl.c` | 特权控制 |
| `do_abort.c` | 内核中止 |
| `do_unused.c` | 未使用的系统调用槽位 |

---

## 4. 进程管理器 (servers/pm/)

**路径：** `servers/pm/` (13 .c 文件, 3,506 行)  
**职责：** POSIX 进程管理 — fork, exec, exit, signal, wait, brk

### 4.1 文件详解

| 文件 | 职责 |
|---|---|
| **main.c** | PM 主循环 — 接收消息、分发处理 |
| **forkexit.c** | fork() 和 exit() — 进程创建和终止 |
| **exec.c** | execve() — 程序替换加载 |
| **signal.c** | 信号处理 — sigaction, kill, sigprocmask |
| **break.c** | brk() / sbrk() — 数据段扩展 |
| **alloc.c** | 内存分配 — 进程内存管理 |
| **getset.c** | getuid/setuid/getgid/setgid/getpid 等 |
| **time.c** | 时间系统调用 — time, stime, times |
| **timers.c** | 定时器管理 — alarm, setitimer |
| **trace.c** | ptrace — 进程追踪 |
| **misc.c** | 杂项系统调用 — uname, reboot |
| **table.c** | 进程表初始化 |
| **utility.c** | 工具函数 |

### 4.2 头文件

| 头文件 | 职责 |
|---|---|
| `pm.h` | PM 主头文件 |
| `mproc.h` | 进程槽结构 (`mproc[]`) |
| `param.h` | 消息参数提取 |
| `proto.h` | 函数原型 |

---

## 5. 文件系统 (servers/fs/)

**路径：** `servers/fs/` (24 .c 文件, 7,821 行)  
**职责：** POSIX 文件系统 — open, read, write, close, mount, pipe, inode 管理

### 5.1 文件详解

| 文件 | 职责 |
|---|---|
| **main.c** | FS 主循环 — 消息分发 |
| **open.c** | open() / creat() — 文件打开和创建 |
| **read.c** | read() — 文件读取 |
| **write.c** | write() — 文件写入 |
| **link.c** | link() / unlink() / rename() — 链接操作 |
| **mount.c** | mount() / umount() — 文件系统挂载 |
| **path.c** | 路径解析 — 目录项查找 |
| **inode.c** | Inode 管理 — 分配、释放、缓存 |
| **super.c** | 超级块管理 — 文件系统元数据 |
| **cache.c** | 块缓存 — buffer cache |
| **pipe.c** | 管道 — pipe() 及读写 |
| **device.c** | 设备文件管理 |
| **filedes.c** | 文件描述符管理 |
| **lock.c** | 文件锁 — POSIX record locking |
| **select.c** | select() — I/O 多路复用 |
| **protect.c** | 文件保护 — 权限检查 |
| **stadir.c** | stat() / fstat() — 文件状态 |
| **dmap.c** | 设备映射表 |
| **cdprobe.c** | CD-ROM 探测 |
| **time.c** | 文件时间戳管理 |
| **timers.c** | 定时器 |
| **misc.c** | 杂项操作 |
| **utility.c** | 工具函数 |
| **table.c** | FS 表初始化 |

### 5.2 头文件

| 头文件 | 职责 |
|---|---|
| `fs.h` | FS 主头文件 |
| `buf.h` | 缓冲区结构 (`buf[]`) |
| `file.h` | 文件描述结构 |
| `fproc.h` | FS 进程结构 (`fproc[]`) |
| `inode.h` | Inode 结构 |
| `super.h` | 超级块结构 |
| `lock.h` | 锁结构 |
| `select.h` | select 结构 |

---

## 6. 重启管理器 (servers/rs/)

**路径：** `servers/rs/` (3 .c 文件, 513 行)  
**职责：** 系统服务监控和重启 (Reincarnation Server)

| 文件 | 职责 |
|---|---|
| `rs.c` / `manager.c` | 服务管理主循环 |
| `service.c` | 服务注册、监控、崩溃重启 |

MINIX 3 的核心特性之一：当驱动或服务崩溃时，RS 可以自动重启它们，不影响系统稳定性。

---

## 7. 初始化进程 (servers/init/)

**路径：** `servers/init/` (1 .c 文件, 460 行)

| 文件 | 职责 |
|---|---|
| `init.c` | 系统初始化 (PID 1) — 启动 getty/login, 读取 /etc/ttytab |

init 是内核启动后的第一个用户空间进程，负责：
1. 读取 `/etc/ttytab` 配置
2. 为每个终端启动 `getty` 进程
3. `getty` 显示登录提示 → `login` → `shell`

---

## 8. 设备驱动 (drivers/)

**路径：** `drivers/` (13 .c 文件, 8,331 行)  
**职责：** 用户空间设备驱动

### 8.1 驱动列表

| 驱动 | 路径 | .c 文件 | 职责 |
|---|---|---|---|
| **at_wini** | `at_wini/` | 1 (多版本) | IDE/ATA 硬盘驱动 |
| **tty** | `tty/` | 3 | 终端/控制台 (键盘+显示) |
| **memory** | `memory/` | 1 | /dev/mem, /dev/null, /dev/zero, /dev/kmem |
| **log** | `log/` | 3 | 系统日志设备 (/dev/klog) |
| **libdriver** | `libdriver/` | 2 | 驱动框架库 (消息处理循环) |
| **libpci** | `libpci/` | 2 | PCI 总线枚举和配置 |

### 8.2 libdriver — 驱动框架

所有 MINIX 3 驱动共享的框架库：

| 文件 | 职责 |
|---|---|
| `driver.c` | 驱动主循环 — 接收消息，分发到 open/close/read/write/ioctl 处理函数 |
| `driver.h` | 驱动接口定义 |
| `drvlib.c` | 驱动辅助函数 (分区扫描等) |
| `drvlib.h` | 辅助函数接口 |

### 8.3 at_wini — IDE 硬盘驱动

包含多个版本文件 (`at_wini.c050921`, `at_wini.c_b050916`, `at_wini.c.diff`)，显示学习演进过程。

### 8.4 tty — 终端驱动

| 文件 | 职责 |
|---|---|
| `tty.c` | TTY 核心 — 输入/输出处理、行编辑 |
| `console.c` | 控制台 — VGA 文本模式输出 |
| `keyboard.c` | 键盘 — 扫描码处理、键映射 |
| `vidcopy.s` | 视频内存拷贝 (汇编优化) |
| `keymaps/` | 键盘映射表 |

### 8.5 libpci — PCI 库

| 文件 | 职责 |
|---|---|
| `pci.c` | PCI 核心枚举和配置 |
| `pci_table.c` | PCI 设备 ID 表 |
| `pci_intel.h` / `pci_amd.h` / `pci_via.h` / `pci_sis.h` | 厂商特定定义 |

---

## 9. 头文件 (include/)

**路径：** `include/` (107 .h 文件, 4,558 行)

### 9.1 include/minix/ — MINIX 系统头文件

| 头文件 | 职责 |
|---|---|
| `callnr.h` | 系统调用编号定义 |
| `com.h` | 通信常量 (任务号、端点号) |
| `config.h` | 系统配置 (进程数、缓冲区数等) |
| `const.h` | 系统常量 |
| `ipc.h` | IPC 消息结构 (`message` 联合体) |
| `type.h` | 基本类型定义 |
| `syslib.h` | 系统库函数接口 |
| `sysutil.h` | 系统工具函数 |
| `devio.h` | 设备 I/O 定义 |
| `dmap.h` | 设备映射 |
| `ioctl.h` | ioctl 命令 |
| `keymap.h` | 键盘映射 |
| `partition.h` | 分区信息 |
| `bitmap.h` | 位图操作 |
| `u64.h` | 64 位整数操作 |

### 9.2 include/sys/ — POSIX 系统头文件

| 头文件 | 职责 |
|---|---|
| `types.h` | POSIX 基本类型 |
| `stat.h` | 文件状态结构 |
| `statfs.h` | 文件系统状态 |
| `time.h` | 时间结构 |
| `wait.h` | waitpid 选项 |
| `ioctl.h` | ioctl 定义 |
| `resource.h` | 资源限制 |
| `select.h` | select 定义 |
| `ptrace.h` | ptrace 定义 |
| `sigcontext.h` | 信号上下文 |
| `svrctl.h` | SVR4 控制接口 |
| `ioc_*.h` | I/O 控制命令 (CMOS, 磁盘, 内存, TTY) |
| `dir.h` | 目录操作 |

### 9.3 include/ibm/ — IBM PC 硬件定义

| 头文件 | 职责 |
|---|---|
| `bios.h` | BIOS 数据区定义 |
| `cpu.h` | CPU 特征定义 |
| `memory.h` | 物理内存布局 |
| `interrupt.h` | 中断向量定义 |
| `portio.h` | I/O 端口操作宏 |
| `ports.h` | 端口地址定义 |
| `cmos.h` | CMOS 内存定义 |
| `diskparm.h` | 磁盘参数 |
| `partition.h` | PC 分区表结构 |
| `int86.h` | 实模式 INT 调用 |

---

## 10. MINIX 3 消息传递机制

### 10.1 IPC 原语

MINIX 3 使用三个核心 IPC 原语：

```
send(dest, &msg)      // 发送消息并等待接收方取走
receive(src, &msg)    // 接收消息 (可指定来源)
sendrec(src, &msg)    // 发送+等待回复 (事务型)
notify(dest)          // 异步通知 (不阻塞)
```

### 10.2 系统调用流程

```
用户进程调用 read(fd, buf, count)
    │
    ├── 库函数发送消息到 FS
    │   msg.m_type = READ
    │   msg.fd = fd, msg.addr = buf, msg.nbytes = count
    │
    ▼
FS (servers/fs/) 接收消息
    │
    ├── 查找 inode、验证权限
    ├── 从块缓存读取数据
    ├── 如果需要磁盘 I/O，发送消息到磁盘驱动
    │   │
    │   ▼
    │   at_wini 驱动处理磁盘请求
    │   │
    │   ▼ 返回数据
    │
    ├── 将数据拷贝到用户空间
    └── 回复消息给用户进程
```

---

## 11. 在 MoQiOS 中的参考价值

| 领域 | 参考内容 |
|---|---|
| **微内核设计** | 最经典的微内核教学实现，内核仅 ~5,000 行 |
| **消息传递 IPC** | send/receive/sendrec 同步消息模型 |
| **用户空间服务** | PM/FS/RS 分离设计，内核极简 |
| **进程管理** | fork/exec/exit/signal 的完整实现 |
| **文件系统** | Inode + buffer cache + 块设备分层 |
| **驱动模型** | 用户空间驱动 + libdriver 框架 |
| **x86 保护模式** | GDT/LDT/IDT 设置，段式内存保护 |
| **代码简洁** | ~30,000 行完整 OS，代码可读性极高 |
| **中文注释** | 加入中文注释便于学习理解 |
