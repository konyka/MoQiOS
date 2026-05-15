# QNX Neutrino 源码架构文档

> 来源：QNX 官方 SVN 库导出 | 大小：79MB | 许可：MIT (仓库), QNX EULA (源码)  
> 路径：`3rd/QNXNeutrino/`  
> 在 MoQiOS 中的用途：**参考实现**（微内核 RTOS 架构、实时调度、进程间通信）

---

## 1. 项目概览

| 属性 | 值 |
|---|---|
| **项目名** | QNX Neutrino |
| **描述** | 微内核实时操作系统 (RTOS) |
| **来源** | 从 QNX 官方 SVN 库直接拉取 |
| **仓库路径** | `9ead0-main/` |
| **源码大小** | 79MB |
| **许可证** | MIT (仓库包装), QNX EULA (源码本身) |
| **语言** | C (主体) + 汇编 (ARM/MIPS/PPC/SH/x86) |
| **支持架构** | ARM, MIPS, PPC, SH (SuperH), x86 |
| **代码量** | 2,773 个 .c 文件, 894 个 .h 文件, 262 个汇编文件, 共 394,653 行 |
| **应用领域** | 汽车电子、工业自动化、医疗设备、航空航天 |

### 1.1 QNX Neutrino 核心特性

- **微内核架构**：内核仅提供最小服务（调度、IPC、中断），其余以用户空间服务实现
- **POSIX 兼容**：符合 POSIX 1003.1 标准
- **硬实时**：确定性调度，微秒级中断延迟
- **高可用性**：进程故障隔离，驱动崩溃不影响内核
- **SMP 支持**：多核处理器支持
- **消息传递 IPC**：同步消息传递是核心通信机制

### 1.2 顶层目录结构

```
3rd/QNXNeutrino/9ead0-main/
├── 23895604qnx.zip        # 原始压缩包 (14MB)
├── LICENSE                 # MIT 许可证
├── README.md               # 项目说明 (中文)
└── 23895604qnx/
    └── qnx/
        ├── Makefile         # 顶层构建文件
        ├── lib/             # 用户空间库 (23 个子库)
        ├── services/        # 系统服务 (18 个服务)
        ├── utils/           # 实用工具 (13 个类别)
        └── ports/           # 移植软件
```

---

## 2. 微内核架构概览

QNX Neutrino 采用**微内核**架构，与 Linux 的宏内核形成鲜明对比：

```
┌─────────────────────────────────────────────────────────┐
│                     用户空间                             │
│  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐          │
│  │ 应用程序 │ │ 应用程序 │ │ 应用程序 │ │ 应用程序 │          │
│  └───┬────┘ └───┬────┘ └───┬────┘ └───┬────┘          │
│      │          │          │          │                 │
│  ┌───▼──────────▼──────────▼──────────▼────┐           │
│  │              libc (lib/c/)               │           │
│  │  POSIX API + 内核调用桩 (kercalls)       │           │
│  └───────────────┬─────────────────────────┘           │
├──────────────────┼─────────────────────────────────────┤
│                  │ 消息传递 / 内核调用                    │
│  ┌───────────────▼─────────────────────────┐           │
│  │         Microkernel (ker/)              │           │
│  │  ┌──────────┐ ┌──────────┐ ┌─────────┐ │           │
│  │  │ 调度器    │ │ IPC 消息  │ │ 中断    │ │           │
│  │  │nano_sched│ │nano_msg  │ │nano_intr│ │           │
│  │  └──────────┘ └──────────┘ └─────────┘ │           │
│  │  ┌──────────┐ ┌──────────┐ ┌─────────┐ │           │
│  │  │ 线程管理  │ │ 同步原语  │ │ 定时器  │ │           │
│  │  │nano_thr  │ │nano_sync │ │nano_tim │ │           │
│  │  └──────────┘ └──────────┘ └─────────┘ │           │
│  └────────────────────────────────────────┘           │
│                                                        │
│  ┌────────────────────────────────────────┐           │
│  │         System Services (用户空间)      │           │
│  │  ┌──────────┐ ┌──────────┐ ┌────────┐ │           │
│  │  │ Process  │ │ Memory   │ │ Path   │ │           │
│  │  │ Manager  │ │ Manager  │ │ Manager│ │           │
│  │  │ (proc/)  │ │(memmgr/) │ │(pathmgr)│ │           │
│  │  └──────────┘ └──────────┘ └────────┘ │           │
│  │  ┌──────────┐ ┌──────────┐ ┌────────┐ │           │
│  │  │ Process  │ │ Device   │ │  File  │ │           │
│  │  │ Manager  │ │ Manager  │ │System  │ │           │
│  │  │(procmgr) │ │  (dev*)  │ │ (fs)   │ │           │
│  │  └──────────┘ └──────────┘ └────────┘ │           │
│  └────────────────────────────────────────┘           │
└────────────────────────────────────────────────────────┘
```

---

## 3. 系统服务层 (services/)

**路径：** `services/` (18 个服务)

### 3.1 服务总览

| 服务 | .c 文件数 | 职责 |
|---|---|---|
| **system/** | 381 | 系统核心（内核 + 进程 + 内存 + 路径） |
| **kdebug/** | 27 | 内核调试器 |
| **kdumper/** | 15 | 内核崩溃转储 |
| **lpd/** | 16 | 打印守护进程 |
| **mqueue/** | 13 | POSIX 消息队列 |
| **slogger/** | 9 | 系统日志器 |
| **random/** | 6 | 随机数生成器 |
| **dumper/** | 3 | 用户空间崩溃转储 |
| **init/** | 3 | 系统初始化 |
| **mig4nto/** | 3 | QNX4 → Neutrino 迁移 |
| **syslogd/** | 3 | syslog 守护进程 |
| **tracelogger/** | 4 | 内核跟踪日志 |
| **cron/** | 2 | 定时任务 |
| **devc-ditto/** | 2 | 字符设备镜像 |
| **mq/** | 1 | 消息队列管理 |
| **pipe/** | 1 | 管道服务 |
| **tinit/** | 1 | 终端初始化 |

### 3.2 system/ — 系统核心 (381 .c 文件)

这是 QNX Neutrino 的核心子系统，包含内核、进程管理器、内存管理器和路径管理器。

#### services/system/ker/ — 微内核 (190 .c 文件)

QNX Neutrino 的微内核实现，提供最低层的服务。

**内核调用处理 (ker_*.c)：**

| 文件 | 职责 |
|---|---|
| `ker_call_table.c` | 内核调用分发表 |
| `ker_channel.c` | Channel (通道) 操作 |
| `ker_clock.c` | 时钟管理 |
| `ker_connect.c` | 连接管理 (ConnectAttach/Disconnect) |
| `ker_fastmsg.c` | 快速消息传递优化路径 |
| `ker_interrupt.c` | 中断管理 (InterruptAttach/Detach) |
| `ker_message.c` | 消息传递 (MsgSend/MsgReceive/MsgReply) |
| `ker_net.c` | 网络消息传递 (Qnet) |
| `ker_sched.c` | 调度器内核调用 |
| `ker_signal.c` | 信号处理 |
| `ker_sync.c` | 同步原语 (互斥、条件变量、屏障) |
| `ker_sys.c` | 系统调用 (ThreadCtl, ClockCtl 等) |
| `ker_thread.c` | 线程管理 |
| `ker_timer.c` | 定时器管理 |
| `ker_trace.c` | 内核跟踪 |

**内核扩展 (kerext_*.c)：**

| 文件 | 职责 |
|---|---|
| `kerext_bind.c` | 内核扩展绑定 |
| `kerext_cache.c` | 数据缓存管理 |
| `kerext_cpumode.c` | CPU 模式管理 |
| `kerext_cred.c` | 凭证管理 (uid/gid) |
| `kerext_debug.c` | 调试支持 |
| `kerext_idle.c` | 空闲线程 |
| `kerext_limits.c` | 资源限制 |
| `kerext_mempart.c` | 内存分区 |
| `kerext_misc.c` | 杂项内核扩展 |
| `kerext_page.c` | 页面管理 |
| `kerext_process.c` | 进程管理扩展 |
| `kerext_reboot.c` | 重启 |
| `kerext_stack.c` | 栈管理 |
| `kerext_trace.c` | 跟踪 |

**微内核核心 (nano_*.c)：**

| 文件 | 职责 |
|---|---|
| `nano_alloc.c` | 内核内存分配器 |
| `nano_asyncmsg.c` | 异步消息传递 |
| `nano_clock.c` | 时钟子系统 |
| `nano_connect.c` | 连接管理 |
| `nano_cred.c` | 凭证管理 |
| `nano_debug.c` | 调试子系统 |
| `nano_event.c` | 事件 (脉冲) |
| `nano_fp_emu.c` | 浮点仿真 |
| `nano_interrupt.c` | 中断框架 |
| `nano_lookup.c` | 消息查找 |
| `nano_memphys.c` | 物理内存管理 |
| `nano_message.c` | 消息传递核心 |
| `nano_misc.c` | 杂项内核功能 |
| `nano_object.c` | 内核对象管理 |
| `nano_pulse.c` | 脉冲消息 |
| `nano_query.c` | 系统查询 |
| `nano_sched.c` | **实时调度器** |
| `nano_signal.c` | 信号 |
| `nano_smp_interrupt.c` | SMP 中断 |
| `nano_sync.c` | 同步原语 |
| `nano_syspage.c` | 系统页面 |
| `nano_thread.c` | 线程管理 |
| `nano_timer.c` | 定时器 |
| `nano_trace.c` | 跟踪 |
| `nano_vector.c` | 中断向量 |
| `nano_xfer*.c` | 消息传输 (5 个文件) |

**虚拟内存管理 (smm_*.c, emm_*.c)：**

| 文件 | 职责 |
|---|---|
| `smm_aspace.c` | 地址空间管理 |
| `smm_configure.c` | 内存配置 |
| `smm_dup.c` | 地址空间复制 (fork) |
| `smm_fault.c` | 缺页处理 |
| `smm_mapinfo.c` / `smm_map_xfer.c` | 映射信息 |
| `smm_mcreate.c` / `smm_mdestroy.c` | 内存对象创建/销毁 |
| `smm_mlock.c` / `smm_munlock.c` | 内存锁定 |
| `smm_mprotect.c` | 页面保护 |
| `smm_msync.c` | 内存同步 |
| `smm_resize.c` | 内存调整 |
| `smm_swapper.c` | 交换管理 |
| `smm_vaddrinfo.c` | 虚拟地址信息 |
| `smm_validate.c` | 地址验证 |
| `emm_init_mem.c` | 早期内存初始化 |
| `emm_mmap.c` / `emm_munmap.c` | 早期 mmap/munmap |
| `emm_pmem_add.c` | 物理内存添加 |
| `emm_vaddr_to_memobj.c` | 地址到内存对象转换 |

**其他核心文件：**

| 文件 | 职责 |
|---|---|
| `kmain.c` | 内核主入口 |
| `init_nto.c` | Neutrino 初始化 |
| `init_objects.c` | 内核对象初始化 |
| `idle.c` | 空闲线程 |
| `kprintf.c` | 内核 printf |
| `mdriver.c` | 管理器驱动接口 |
| `smp_*.c` | SMP 支持 (TLB flush, IPI, CPU 编号) |
| `shutdown_nto.c` | 关机 |
| `walk_asinfo.c` | 地址空间遍历 |

**架构特定子目录：**

| 目录 | 职责 |
|---|---|
| `arm/` | ARM 架构特定代码 |
| `mips/` | MIPS 架构特定代码 |
| `ppc/` | PowerPC 架构特定代码 |
| `sh/` | SuperH 架构特定代码 |
| `x86/` | x86 架构特定代码 |

#### services/system/memmgr/ — 内存管理器 (108 .c 文件)

用户空间内存管理服务，管理虚拟内存、共享内存、交换空间。

| 文件 | 职责 |
|---|---|
| `memmgr_init.c` | 内存管理器初始化 |
| `memmgr_ctrl.c` | 控制操作 |
| `memmgr_map.c` | mmap 服务 |
| `memmgr_shmem.c` | 共享内存 |
| `memmgr_swap.c` | 交换空间 |
| `memmgr_fd.c` | 文件描述符支持 |
| `mm_anmem.c` | 匿名内存 |
| `mm_class.c` | 内存分类 |
| `mm_map.c` | 映射管理 |
| `mm_memobj.c` | 内存对象 |
| `mm_mempart.c` | 内存分区 |
| `mm_memref.c` | 内存引用 |
| `mm_pte.c` | 页表项管理 |
| `mm_reference.c` | 引用计数 |
| `mm_rlimit.c` | 资源限制 |
| `mm_sysaddr.c` | 系统地址空间 |
| `mm_temp_map.c` | 临时映射 |
| `pa.c` / `pmm.c` | 物理地址 / 物理内存管理 |

架构特定子目录：`arm/`, `mips/`, `ppc/`, `apm/`

#### services/system/proc/ — 进程管理器 (27 .c 文件)

| 文件 | 职责 |
|---|---|
| `main.c` | 进程管理器主入口 |
| `loader_elf.c` | ELF 加载器 |
| `proc_loader.c` | 进程加载框架 |
| `proc_read.c` | procfs 读取 |
| `proc_termer.c` | 进程终止 |
| `bootimage_init.c` | 启动映像初始化 |
| `message.c` | 消息处理 |
| `support.c` | 辅助函数 |
| `sysmgr_cmd.c` / `sysmgr_conf.c` / `sysmgr_init.c` | 系统管理器 |
| `rsrcdbmgr_*.c` (5 文件) | 资源数据库管理器 |
| `timestamp.c` | 时间戳 |
| `link_assert.c` / `link_noops.c` | 链接辅助 |

#### services/system/procmgr/ — 进程管理器扩展 (16 .c 文件)

| 文件 | 职责 |
|---|---|
| `procmgr_init.c` | 初始化 |
| `procmgr_fork.c` | fork() 处理 |
| `procmgr_spawn.c` | spawn() 处理 |
| `procmgr_wait.c` | wait() 处理 |
| `procmgr_event.c` | 事件管理 |
| `procmgr_getsetid.c` | uid/gid 设置 |
| `procmgr_session.c` | 会话管理 |
| `procmgr_setpgid.c` | 进程组管理 |
| `procmgr_stack.c` | 栈管理 |
| `procmgr_umask.c` | umask |
| `procmgr_daemon.c` | 守护进程支持 |
| `procmgr_coredump.c` | 核心转储 |
| `procmgr_guardian.c` | 进程监护 |
| `procmgr_misc.c` | 杂项 |
| `procmgr_resource.c` | 资源管理 |
| `procmgr_termer.c` | 进程终止 |

#### services/system/pathmgr/ — 路径管理器 (15 .c 文件)

| 文件 | 职责 |
|---|---|
| `pathmgr_init.c` | 初始化 |
| `pathmgr_node.c` | 路径节点管理 |
| `pathmgr_object.c` | 路径对象管理 |
| `pathmgr_link.c` | 链接管理 |
| `pathmgr_resolve.c` | 路径解析 |
| `pathmgr_open.c` | 路径打开 |
| `procfs.c` | /proc 文件系统 |
| `devnull.c` / `devzero.c` | /dev/null, /dev/zero |
| `devmem.c` | /dev/mem |
| `devtext.c` / `devtty.c` | 终端设备 |
| `imagefs.c` | 镜像文件系统 |
| `namedsem.c` | 命名信号量 |

#### services/system/partmgr/ — 分区管理器 (23 .c 文件)

内存分区和调度分区的资源管理器实现。

#### services/system/public/ — 内核公共头文件

| 子目录 | 内容 |
|---|---|
| `sys/` | 系统级 API 头 (neutrino.h, kercalls.h, procfs.h, debug.h 等) |
| `kernel/` | 内核内部头 (cpu_*.h, kerext.h, memclass.h, mempart.h, objects.h 等) |
| `hw/` | 硬件相关头文件 |
| `arm/`, `mips/`, `ppc/`, `sh/`, `x86/` | 架构特定头文件 |

---

## 4. 用户空间库 (lib/)

**路径：** `lib/` (23 个子库)

### 4.1 库总览

| 库 | .c 文件 | 行数 | 职责 |
|---|---|---|---|
| **ncurses** | 241 | 70,335 | 终端 UI 库 |
| **c** | 1,157 | 7,810 | **核心 C 库** (libc) |
| **malloc** | 31 | 18,489 | 内存分配器 |
| **lzo** | 70 | 12,869 | LZO 压缩库 |
| **z** | 14 | 7,990 | zlib 压缩 |
| **qnxterm** | 25 | 6,477 | QNX 终端库 |
| **util** | 19 | 5,430 | 通用工具库 |
| **ucl** | 18 | 5,221 | UCL 压缩 |
| **mig4nto** | 25 | 4,406 | QNX4 → Neutrino 迁移库 |
| **compat** | 48 | 4,277 | 兼容性库 |
| **qnx43** | 18 | 3,543 | QNX 4.3 兼容 |
| **login** | 23 | 3,518 | 登录认证库 |
| **elf** | 2 | 3,431 | ELF 格式处理 |
| **bessel** | 12 | 3,368 | 贝塞尔函数 (libm) |
| **misc** | 16 | 2,885 | 杂项工具 |
| **kdutil** | 26 | 2,718 | 内核调试工具 |
| **asyncmsg** | 17 | 1,650 | 异步消息传递库 |
| **traceparser** | 1 | 1,502 | 跟踪解析器 |
| **shutdown** | 8 | 670 | 关机库 |
| **termcap** | 4 | 482 | 终端能力数据库 |
| **mq** | 1 | 394 | 消息队列库 |
| **m** | 0 | 3,828 | 数学库 (libm, 纯汇编/头文件) |

### 4.2 lib/c/ — 核心 C 库 (libc)

QNX Neutrino 的 POSIX C 库实现，1,157 个 .c 文件。

#### 子目录详解

| 子目录 | 职责 |
|---|---|
| `ansi/` | ANSI C 标准函数 (abort, exit, getenv, bsearch, qsort, ...) |
| `alloc/` | 内存分配 (malloc, free, calloc, realloc, memalign) |
| `dispatch/` | 调度框架 (dispatch_create, message_attach, resmgr_attach) |
| `iofunc/` | I/O 函数框架 — 资源管理器辅助 (60+ 函数) |
| `kercalls/` | **内核调用桩** — 用户空间到内核的系统调用接口 |
| `kercover/` | 内核调用覆盖 |
| `startup/` | C 运行时启动代码 (crtbegin, crtend) |
| `stdio/` | 标准 I/O (printf, scanf, fopen, fread, fwrite) |
| `string/` | 字符串操作 (strlen, strcmp, memcpy, ...) |
| `time/` | 时间函数 (clock_gettime, localtime, strftime) |
| `atomic/` | 原子操作 |
| `prof/` | 性能分析 (gmon, mcount) |
| `qnx/` | QNX 特有函数 (devctl, intr, getprio, gettid, hwi_*) |
| `unix/` | UNIX 兼容函数 |
| `xopen/` | X/Open 兼容 |
| `public/` | **公共头文件** (90+ .h 文件) |
| `services/` | 系统服务接口 |
| `resmgr/` | 资源管理器框架 |
| `ldd/` | 动态链接器辅助 |
| `lib/` | 内部库函数 |
| `misc/` | 杂项 |

#### lib/c/iofunc/ — 资源管理器 I/O 框架 (60+ 文件)

这是 QNX 资源管理器开发的核心框架，为每个 POSIX I/O 操作提供默认实现：

| 函数 | 文件 |
|---|---|
| `iofunc_attr_init/lock/trylock/unlock` | 属性初始化/锁定 |
| `iofunc_open/open_default` | open() 处理 |
| `iofunc_read_default/read_verify` | read() 处理 |
| `iofunc_write_default/write_verify` | write() 处理 |
| `iofunc_close_dup/close_ocb` | close() 处理 |
| `iofunc_stat/stat_default` | stat() 处理 |
| `iofunc_chmod/chmod_default` | chmod() 处理 |
| `iofunc_chown/chown_default` | chown() 处理 |
| `iofunc_lseek/lseek_default` | lseek() 处理 |
| `iofunc_mmap/mmap_default` | mmap() 处理 |
| `iofunc_devctl/devctl_default` | devctl() 处理 |
| `iofunc_lock/lock_default` | 文件锁定 |
| `iofunc_notify/notify_trigger` | 通知机制 |
| `iofunc_ocb_attach/ocb_calloc/ocb_detach` | OCB (打开控制块) 管理 |
| `iofunc_func_init` | 初始化函数表 |
| `iofunc_check_access/client_info` | 访问控制 |

#### lib/c/dispatch/ — 调度框架

| 函数 | 职责 |
|---|---|
| `dispatch_create` | 创建调度上下文 |
| `message_attach` | 注册消息处理函数 |
| `resmgr_attach/detach` | 注册/注销资源管理器 |
| `thread_pool_create/ctrl` | 线程池管理 |
| `dispatch_select/sigwait` | 事件等待 |

#### lib/c/kercalls/ — 内核调用桩

用户空间到微内核的系统调用接口。每个架构有独立的汇编桩文件：

| 子目录 | 架构 |
|---|---|
| `arm/` | ARM (6 文件) |
| `mips/` | MIPS (6 文件) |
| `ppc/` | PowerPC (4 文件) |
| `sh/` | SuperH (4 文件) |
| `x86/` | x86 (5 文件) |

`mkkercalls` 脚本自动从定义文件生成内核调用桩代码。

#### lib/c/public/ — 公共 API 头文件

核心 POSIX/QNX 头文件：

```
aio.h, alloca.h, assert.h, atomic.h, ctype.h, devctl.h, dirent.h,
dlfcn.h, errno.h, fcntl.h, float.h, fnmatch.h, ftw.h, glob.h,
grp.h, hw/inout.h, inttypes.h, intr.h, ioctl.h, libgen.h,
limits.h, locale.h, malloc.h, memory.h, mqueue.h, netdb.h,
netinet/in.h, poll.h, pthread.h, pwd.h, regex.h, sched.h,
search.h, semaphore.h, setjmp.h, signal.h, spawn.h, stdarg.h,
stdbool.h, stddef.h, stdint.h, stdio.h, stdlib.h, string.h,
strings.h, sys/asyncmsg.h, sys/iofunc.h, sys/dispatch.h,
sys/mman.h, sys/msg.h, sys/neutrino.h, sys/procfs.h,
sys/resource.h, sys/siginfo.h, sys/socket.h, sys/stat.h,
sys/time.h, sys/types.h, sys/wait.h, termios.h, time.h,
ucontext.h, unistd.h, utime.h, wchar.h, ...
```

### 4.3 lib/malloc/ — 内存分配器 (31 .c 文件, 18,489 行)

QNX 的 malloc 实现，支持多架构优化：

- `core.c` — 分配器核心
- `malloc.c` / `_malloc.c` — malloc 实现
- `_calloc.c` — calloc
- `_realloc.c` — realloc
- `_free.c` — free
- `_memalign.c` — memalign
- `_salloc.c` — 共享内存分配
- `band.c` / `barena.c` — 区段分配器
- `dlist.c` / `flist.c` — 空闲列表管理
- 架构优化：`arm/`, `mips/`, `ppc/`, `sh/`, `x86/`

### 4.4 lib/elf/ — ELF 处理 (2 .c 文件, 3,431 行)

ELF 格式加载和分析库。

---

## 5. 实用工具 (utils/)

**路径：** `utils/` (13 个类别)

| 目录 | 工具 | 说明 |
|---|---|---|
| `a/` | aps | 自适应分区调度器 |
| `c/` | cvs (177 .c 文件) | CVS 版本控制系统移植 |
| `d/` | dd, diff (53 .c 文件) | 数据复制、文件比较 |
| `e/` | enterkd, esh | 进入内核调试、嵌入式 Shell |
| `g/` | gawk, gzip (69 .c 文件) | AWK、压缩工具 |
| `h/` | hogs | CPU 占用分析 |
| `k/` | kdserver | 内核调试服务器 |
| `m/` | mkasmoff, mkrec, mkrom, mkxfs | 构建工具 (镜像/文件系统制作) |
| `o/` | on | 远程执行工具 |
| `p/` | patch, pdksh, pidin (64 .c 文件) | 补丁、KornShell、进程信息 |
| `s/` | sed, shutdown, slay (15 .c 文件) | 流编辑器、关机、进程终止 |
| `t/` | traceprinter (21 .c 文件) | 内核跟踪打印 |

**重要工具：**
- **pidin** — QNX 版 "ps" (进程信息显示)
- **esh** — 嵌入式 Shell
- **mkxfs** — 文件系统镜像制作
- **traceprinter** — 内核跟踪数据可视化

---

## 6. 其他服务

### 6.1 services/kdebug/ — 内核调试器 (27 .c 文件)

QNX 内核级调试器，支持断点、单步、内存检查。

### 6.2 services/kdumper/ — 内核转储器 (15 .c 文件)

内核崩溃时的内存转储服务。

### 6.3 services/mqueue/ — POSIX 消息队列 (13 .c 文件)

POSIX 1003.1b 消息队列服务实现。

### 6.4 services/slogger/ — 系统日志器 (9 .c 文件)

QNX 系统日志服务 (slogger2)。

### 6.5 services/lpd/ — 打印服务 (16 .c 文件)

行式打印守护进程。

### 6.6 services/init/ — 系统初始化 (3 .c 文件)

系统启动时的初始化服务。

---

## 7. 构建系统

QNX Neutrino 使用**递归 Make** 构建系统：

```makefile
# 顶层 Makefile
LIST=ALL
EARLY_DIRS=lib        # 先构建库
LATE_DIRS=apps mme    # 后构建应用
include recurse.mk     # 递归构建框架
```

每个子目录包含 `Makefile` 和 `common.mk`，支持多架构交叉编译。

**架构支持目录模式：** 每个模块下都有 `arm/`, `mips/`, `ppc/`, `sh/`, `x86/` 子目录存放架构特定代码。

---

## 8. QNX Neutrino 核心概念

### 8.1 消息传递 (Message Passing)

QNX 的核心 IPC 机制：

```
客户端线程                    服务端线程
    │                              │
    ├── MsgSend(chid, data) ──────►│
    │   (阻塞等待回复)              ├── MsgReceive(chid, buf)
    │                              │   (处理请求)
    │                              ├── MsgReply(rcvid, status, reply)
    │◄─────────────────────────────┤
    │   (MsgSend 返回)              │
```

### 8.2 Channel + Connection 模型

```
┌──────────┐     ConnectAttach()     ┌──────────┐
│  客户端   │ ──────────────────────► │  服务端   │
│  coid ────│◄────────────────────── │  chid    │
└──────────┘                         └──────────┘
```

- **Channel (通道)**：服务端创建，用于接收消息
- **Connection (连接)**：客户端通过 ConnectAttach() 连接到服务端的通道

### 8.3 实时调度策略

| 策略 | 说明 |
|---|---|
| SCHED_FIFO | 先入先出，同优先级不轮转 |
| SCHED_RR | 轮转，同优先级时间片轮转 |
| SCHED_OTHER | 默认策略 |
| SCHED_SPORADIC | 稀疏调度 (QNX 扩展) |
| APS | 自适应分区调度 (QNX 扩展) |

### 8.4 资源管理器 (Resource Manager)

QNX 的驱动/服务模型——通过文件系统命名空间提供服务：

```
资源管理器注册路径 → pathmgr → 客户端 open() 路径
→ 内核路由消息到资源管理器 → 资源管理器处理 I/O 请求
```

---

## 9. 在 MoQiOS 中的参考价值

| 领域 | 参考内容 |
|---|---|
| **微内核架构** | 最小内核 + 用户空间服务的设计模式 |
| **消息传递 IPC** | MsgSend/MsgReceive/MsgReply 同步消息机制 |
| **实时调度** | SCHED_FIFO/RR 的确定性实现 |
| **资源管理器** | 通过命名空间提供服务的驱动模型 |
| **iofunc 框架** | POSIX I/O 操作的分层实现 |
| **内存管理** | 用户空间内存管理器 + 内核 SMM 分离 |
| **多架构支持** | ARM/MIPS/PPC/SH/x86 五架构代码组织 |
| **内核调用** | 用户空间→微内核的系统调用桩设计 |
