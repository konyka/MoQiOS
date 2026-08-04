# MoQiOS 用户空间

> **文档定位**: 描述 MoQiOS 用户态 ABI、init 进程、Shell、测试程序，以及未来微内核化所需的 `servers/` `drivers/` `lib/` 规划。
> **修订日期**: 2026-08-01
> **关联文档**: [moqios-architecture-current.md](./moqios-architecture-current.md)、[kernel-subsystems.md](./kernel-subsystems.md)

---

## 1. 系统调用接口

### 1.1 调用约定

MoQiOS 使用 x86_64 `SYSCALL` 指令进入内核，遵循 Linux x86_64 SysV ABI 寄存器约定：

| 寄存器 | 用途 |
|---|---|
| `rax` | 系统调用号；返回时为返回值 |
| `rdi` | 第 1 个参数 |
| `rsi` | 第 2 个参数 |
| `rdx` | 第 3 个参数 |
| `r10` | 第 4 个参数（注意：用户函数调用约定第 4 参数是 `rcx`，但 `syscall` 会破坏 `rcx`） |
| `r8`  | 第 5 个参数 |
| `r9`  | 第 6 个参数 |
| `rcx` | 由 `syscall` 自动写入返回地址（用户态原 `rip`） |
| `r11` | 由 `syscall` 自动写入原 `rflags` |

返回值：错误时 `rax` 为负小整数（约定为 `-errno`），成功时为非负值或合法指针。

### 1.2 用户侧封装（C）

```c
static inline long syscall3(long n, long a, long b, long c) {
    long ret;
    register long r10 __asm__("r10") = c;
    __asm__ volatile (
        "syscall"
        : "=a"(ret)
        : "a"(n), "D"(a), "S"(b), "d"(c)
        : "rcx", "r11", "memory"
    );
    return ret;
}

static inline long sys_write(int fd, const void *buf, unsigned long n) {
    return syscall3(SYS_write, fd, (long)buf, (long)n);
}
```

> 上述手写封装已收敛进 `lib/moqi_libc/`（见第 5 节）：编号常量在
> `include/moqi_syscalls.h`，常用调用在 `include/unistd.h`。新程序应直接使用
> moqi_libc，不再复制本节的内联汇编。

### 1.3 系统调用清单（分发表共 382 个编号分支，下表为常用子集）

| 类别 | 调用 |
|---|---|
| 进程控制 | `exit`, `getpid`, `spawn`, `waitpid`, `fork`, `execve`, `kill` |
| 文件 I/O | `write`, `open`, `read`, `close`, `dup2` |
| 信号 | `sigaction`, `sigprocmask`, `sigreturn` |
| 管道 | `pipe` |
| 文件系统 | `listdir`, `chdir`, `getcwd`, `mkdir`, `unlink`, `truncate` |
| 网络 | `net_send`, `net_recv`, `net_poll`, `tcp_connect`, `tcp_send`, `tcp_recv`, `tcp_close`, `tcp_listen`, `socket`, `bind`, `accept`, `sendto`, `recvfrom`, `connect` |
| 环境变量 | `getenv`, `setenv` |
| 内存 | `brk` |
| 调度 | `sched_setscheduler` (#473), `sched_getscheduler` (#474), `sched_get_priority_max` (#475), `sched_get_priority_min` (#476), `sched_setattr` (#308), `sched_getattr` (#309), `sched_setaffinity` (#273), `getpriority` (#232), `setpriority` (#233) |

详细行为参见 syscall 入口与分发表 `kernel/arch/x86_64/syscall_entry.zig`（`syscallDispatch`
中的 `switch (syscall_nr)`，编号 1–476）。

> 注：调度类系统调用使用 MoQiOS 自有编号——Linux 的 156/157/146/147 在本分发表已被
> msgget/msgsnd/epoll_create1/epoll_ctl 占用。SCHED_OTHER=0 / SCHED_FIFO=1 / SCHED_RR=2
> 与 Linux 策略编号一致；FIFO/RR 的 `sched_priority` 合法范围 1..99，OTHER 必须为 0。

---

## 2. init 进程

文件：`servers/init/main.c`（C，基于 moqi_libc，见第 5 节），编译安装为
`zig-out/user/init.bin`，作为 PID 1。2026-08 起取代汇编实现；`user/init.S`
（汇编，约 1306 行）保留在源码树中作为回退参考，但不再参与构建。
C 版保持字节级行为一致：相同 spawn 顺序、相同打印行、相同 waitpid 语义。

职责：

1. 顺序 `spawn` 自动化测试程序（`hello2`–`hello44`；其中 `hello11` 与 `hello28` **不**在
   init 自动序列内），并 `waitpid` 收回；随后进入交互 shell。
2. 测试全部通过后启动交互式 Shell（`sh`）。
3. 在 Shell 退出后处于阻塞状态（避免内核因 init 退出而 panic）。

伪流程：

```
main():
    printf("init (pid %ld) started\n", getpid());
    spawn("hello2");  waitpid;
    ...
    spawn("hello44"); waitpid;   // SCHED_FIFO/RR realtime classes (after hello42)
    spawn("hello9/10/21"); waitpid;   // fork/ext2 写测试排在最后
    spawn("sh");
    exit(0);
```

历史说明：init 最初用汇编编写（`user/init.S`），以避免依赖 libc、直接控制系统调用号
与栈布局；moqi_libc 成熟后已迁移为 C（`servers/init/main.c`），行为逐字节保持一致，
汇编版保留作为回退。

---

## 3. Shell（user/sh.c）

约 370 行 C 代码（基于 moqi_libc，见第 5 节），实现一个最小但实用的交互式命令解释器。

### 3.1 内置命令

| 命令 | 功能 |
|---|---|
| `exit [code]` | 退出 Shell |
| `pid` | 打印当前 PID |
| `echo [args...]` | 回显参数 |
| `ls [path]` | 列出目录 |
| `cd <path>` | 切换工作目录（`chdir`） |
| `pwd` | 打印当前工作目录（`getcwd`） |
| `export KEY=VALUE` | 设置环境变量（`setenv`） |
| `env` | 打印所有环境变量 |
| `help` | 显示内置命令帮助 |

### 3.2 外部命令

通过 `spawn`/`fork`+`execve` 启动 ELF；按 `PATH` 解析（默认 `/`）。

### 3.3 管道

`cmd1 | cmd2`：

1. `pipe(fds)`
2. fork cmd1：`dup2(fds[1], 1)`，关闭 `fds[0]`
3. fork cmd2：`dup2(fds[0], 0)`，关闭 `fds[1]`
4. 父进程关闭两端，`waitpid` 双方

### 3.4 重定向

- `>` / `>>`：`open(O_WRONLY|O_CREAT[|O_TRUNC|O_APPEND])` + `dup2(fd, 1)`
- `<`：`open(O_RDONLY)` + `dup2(fd, 0)`

### 3.5 信号处理

- Ctrl+C 触发 SIGINT：Shell 安装 handler，仅打印新提示符，不退出。
- 子进程收到 SIGINT 时由内核默认 terminate。

---

## 4. 测试程序（hello 系列）

`user/hello2.c` ~ `user/hello44.c` 是渐进式功能测试，每个程序聚焦特定子系统：

| 程序 | 测试焦点 |
|---|---|
| hello2 / hello3 | 汇编入口 + write 系统调用 |
| hello4..hello10 | 进程控制、fork/exec、waitpid、信号 |
| hello11..hello16 | 文件 I/O（ramdisk / FAT32） |
| hello17 / hello18 | 管道 + 网络（部分用例不稳定） |
| hello19 | UDP 收发 |
| hello20..hello28 | TCP socket、ext2 写入、mkdir、unlink、connect、ext2 listdir |
| hello29..hello44 | fsync、brk/mmap、TLS、SIGSEGV 处理、futex、socket 选项、SysV IPC、mqueue、SCHED_FIFO/RR 实时调度类等（各 PASS 标记见 `tools/qemu_smoke.sh`） |
| hello43 | loopback（lo）设备：单进程内 TCP client+server over 127.0.0.1（socket/bind/listen/connect/accept + 双向回显）与 UDP sendto/recvfrom 自收发（F2） |
| hello44 | SCHED_FIFO / SCHED_RR 实时调度类（F3） |
| hello50 | SMP 并发压力（J1）：4 个 worker 经 sched_setaffinity 绑核（CPU 数不足返回 EINVAL 时跳过绑核、SMP=1 下共享 CPU 0），各跑 300 轮 tmpfs 文件写读校验 + pipe + loopback UDP 自收发 + 64 KiB 匿名 mmap 校验；任一轮数据错误或异常负返回 → 子进程以 10+i 退出，父进程汇总 PASS/FAIL |

每个测试在结束前打印 `helloN: PASS` / `helloN done` 等标记，由 init 顺序回收，构成自动化回归。

---

## 5. moqi_libc 最小 C 运行时（lib/moqi_libc/）

自研最小 freestanding libc，替代各 `user/*.c` 中手工复制的 syscall 内联汇编与
`print`/`strlen` 等辅助函数。**不改变内核 syscall ABI**：编号与寄存器约定同第 1 节，
`include/moqi_syscalls.h` 是用户侧编号的唯一权威来源（与
`kernel/arch/x86_64/syscall_entry.zig` 分发表一一对应）。

### 5.1 目录结构

| 路径 | 内容 |
|---|---|
| `include/moqi_syscalls.h` | syscall 编号常量 + `syscall0`..`syscall6` 内联封装 |
| `include/crt0.h` | 初始栈解析（`moqi_parse_initial_stack`，头文件内联，可宿主机测试） |
| `include/unistd.h` | read/write/open/close/lseek/fork/execve/waitpid/_exit/pipe/dup2/yield/nanosleep/brk/sbrk 等 + `extern char **environ` |
| `include/string.h` | memcpy/memmove/memset/memcmp/strlen/strcmp/strncmp/strcpy/strncpy/strcat/strchr/strrchr |
| `include/stdio.h` | print/puts/putchar/printf（%d %i %u %x %X %s %c %p %%，支持 l/ll；无浮点）+ snprintf/vsnprintf |
| `include/stdlib.h` | malloc/free/calloc（brk 上的首次适配空闲链表）、exit、atoi、getenv |
| `include/ctype.h` | isdigit/isalpha/isspace/toupper 等（纯头文件） |
| `include/signal.h` | `struct ksigaction`（匹配内核读取的 28 字节布局）、sigaction、SIGINT/SIG_IGN 等 |
| `src/crt0.c` | `_start`（naked）：捕获入口 rsp → `_start_c` 解析 argc/argv/envp → 设置 `environ` → `main(argc, argv, envp)` → `_exit(main(...))` |
| `src/format.c` | printf 格式化核心（无 syscall，可在宿主机测试） |
| `src/malloc.c` | 分配器核心（无 syscall；经弱符号 `__moqi_heap_grow` 扩容） |
| `src/sbrk.c` | 强符号 `__moqi_heap_grow`，基于 brk 实现 |
| `src/unistd.c` `src/stdio.c` `src/signal.c` `src/stdlib.c` | 薄 syscall 封装、fd 1 输出与 getenv（仅 freestanding） |
| `host_tests/` | 宿主机单元测试（test_string / test_format / test_malloc / test_args + run_tests.sh） |

### 5.2 设计要点

- **syscall 层尽量薄**：`unistd.c` 每个函数都是 1:1 的 ABI 映射，返回内核原值
  （负数即 `-errno`），不做 errno 转换，因此无需也无法在宿主机测试。
- **可宿主机测试的部分与 syscall 解耦**：格式化核心（`format.c`）与分配器
  （`malloc.c`）不含任何 syscall；分配器通过弱符号 `__moqi_heap_grow(size)` 扩容，
  freestanding 构建由 `sbrk.c` 提供 brk 实现，宿主机测试用静态缓冲区覆盖该弱符号。
  测试方式为 TDD：`host_tests/run_tests.sh` 用 `zig cc`（私有缓存目录，可与
  `zig build` 并行）在本机编译运行断言。
- **malloc**：16 字节对齐的首次适配空闲链表，支持分裂与相邻块合并；扩容按
  4KiB 粒度走 brk（syscall #7）。无 realloc，无线程安全（用户程序单线程）。
- **printf**：格式化进 512 字节栈缓冲后一次 write 到 fd 1，超长截断；
  无浮点、无宽度/精度修饰。
- **argc/argv/envp 与初始栈契约**：内核（`kernel/proc/user_stack.zig`
  `buildUserStack`）按 System V 布局构建进程入口栈：RSP 指向 argc（8 字节），
  其后依次是 NULL 结尾的 argv 指针数组、NULL 结尾的 envp 指针数组
  （`envp == &argv[argc+1]`，两者恒连续，16 字节对齐 pad 在 envp-NULL 与
  auxv 之间），最后是 auxv 对。execve（syscall #59）把调用者的 argv/envp
  完整传入新程序（各最多 16 项、每项截断到 127 字节）；首个进程
  （`loader.loadProgram`）envp 为空。crt0 的 naked `_start` 捕获入口 rsp，
  `_start_c` 用 `include/crt0.h` 的 `moqi_parse_initial_stack` 解析，
  设置全局 `environ` 后以 `main(argc, argv, envp)` 进入程序。
- **environ / getenv**：`environ`（unistd.h 声明，crt0.c 定义）指向初始栈上的
  envp 数组；`getenv(name)`（stdlib）纯遍历 environ，不发 syscall，返回指向
  environ 条目内部的指针。libc 不提供 setenv——修改内核侧环境请用
  `moqi_setenv`（注意：内核环境表与栈上 envp 是两套机制，execve 只传
  调用者给的 envp，不继承 `moqi_setenv` 设置的变量）。

### 5.3 编写新的 libc 用户程序

1. `user/foo.c` 以 `int main(int argc, char **argv, char **envp)` 为入口
   （crt0 提供 `_start`；不需要参数时可 `(void)` 丢弃三者），按需
   `#include <stdio.h> <unistd.h> <string.h> <stdlib.h> <ctype.h> <signal.h>`。
2. 把程序名加入 `build.zig` 的 `libc_programs` 列表（`addLibcUserProgram` 会
   连同 `lib/moqi_libc/src/*.c` 一起编译链接；手工编译命令见
   [build-and-toolchain.md](./build-and-toolchain.md) 第 4 节）。
3. 输出仍是 `zig-out/user/<name>.bin`（静态 freestanding ELF），与裸 C 程序一致。

现有示范：`user/sh.c`（最大消费者）、`user/hello10.c` 与 `servers/init/main.c`
（PID 1，2026-08 迁移）已迁移到 moqi_libc，PASS 标记与原始版本逐字节一致。
init 的源文件不在 `user/` 下，构建时以显式路径调用 `addLibcUserProgram`。

### 5.4 有意缺失

浮点 printf、stdio 缓冲/FILE、errno 全局量、realloc、线程与 TLS、locale、
setjmp/longjmp、完整 POSIX 信号语义、libc 侧 setenv（environ 只读；
改环境用 `moqi_setenv`，见 5.2）。需要时请按最小需求追加，不要预先泛化。

`lib/zig_crt/` 另含 `start.zig`：Zig 用户程序的最小 `_start`（对齐栈 →
`main()` → exit syscall），供 Zig 编写的 freestanding 用户程序链接，非 libc。

---

## 6. 用户链接脚本（user/user.ld）

```
ENTRY(_start)

SECTIONS {
    . = 0x0;
    .text   : { *(.text .text.*) }
    .rodata : { *(.rodata .rodata.*) }
    .data   : { *(.data .data.*) }
    .bss    : { *(.bss .bss.*) *(COMMON) }
}
```

- 起始地址 `0x0`，由内核加载器映射到任意空闲虚拟地址。
- 入口 `_start`，符合标准 ELF 约定。
- 不引入 `.eh_frame` / `.note.*`（运行时不需要）。

---

## 7. 系统服务（servers/）

### 7.1 syslogd — 系统日志守护（servers/syslogd/main.c）

第一个用户态系统服务，moqi_libc 程序（入口 `main(argc, argv, envp)`，构建与
链接方式同 init，见第 5 节），由 init 以 `spawn("syslogd")` 启动。

**kmsg 消费者模式**：

1. `open("/dev/kmsg", O_RDONLY)`：内核日志环的只读视图，每个 fd 有独立游标，
   打开时从最旧可用字节开始；`read()` 到达最新字节时返回 0，**不会阻塞**。
2. 主循环：有数据则 drain 并追加到日志文件；`read()` 返回 0（已追上）或出错时
   `nanosleep(100ms)`（syscall #35）——守护进程绝不忙等。

**日志文件 `/tmp/kern.log`**：vfs 的 open 路径只把 `/tmp` 前缀路由到 tmpfs
（唯一支持 `O_CREAT` 的可写位置，见 `kernel/fs/vfs.zig` `FdTable.open`）；
`/var/log/*` 等其它绝对路径会落到只读 ramdisk 查找而失败，因此目前无法用
`/var/log`。打开标志 `O_WRONLY|O_CREAT|O_APPEND` = 0x441（位值见
`lib/moqi_libc/include/unistd.h`）；内核在每次写前把 offset 重置为文件末尾，
实现 O_APPEND 语义。

**轮转**：tmpfs 单文件有 256 KiB 硬上限（`PAGES_PER_FILE * PAGE_SIZE`，触顶的写
会被拒绝/短写），因此采用**写前轮转**——当下一次写入会使文件超过 256 KiB 时，
先 close 并以 `O_WRONLY|O_CREAT|O_TRUNC|O_APPEND`（0x641）重开。单代轮转，
旧内容直接丢弃，无 `.1` 备份。启动标记为 stdout 一行 `[syslogd] started`。

**未来增强**：`/dev/kmsg` 目前不阻塞，syslogd 只能以 10 Hz 轮询；待内核为 kmsg
提供阻塞读（或 poll/epoll 唤醒）后，应以阻塞读替换 nanosleep 兜底，改为事件驱动。

---

## 8. 微内核化规划目录

下列目录已建立框架，**当前尚未实现**，是迈向微内核架构的预留位置。详见 [moqios-design.md](./moqios-design.md)。

### 8.1 servers/ 用户空间服务

| 子目录 | 规划职责 |
|---|---|
| `servers/init/` | 用户态 init（**已实现**：`main.c` 基于 moqi_libc，取代 `user/init.S`；汇编版保留为回退） |
| `servers/pm/` | 进程管理服务（fork/exec/wait） |
| `servers/vfs/ext4/` | 文件系统服务（ext4 实现，从内核迁出） |
| `servers/devmgr/` | 设备管理 / 命名空间 |
| `servers/netstack/` | 网络协议栈服务（从内核迁出） |
| `servers/ttyd/` | 终端 / 控制台守护 |
| `servers/syslogd/` | 日志服务（**已实现**：`main.c` 基于 moqi_libc，见第 7 节） |
| `servers/powermgr/` | 电源管理 |
| `servers/vmm/` | 虚拟机监视器（容器/沙箱） |
| `servers/linux_pers/` | Linux 个性（兼容 Linux 系统调用） |
| `servers/win_pers/` | Windows 个性（PE / Win32 兼容） |

### 8.2 drivers/ 用户空间驱动

| 子目录 | 规划职责 |
|---|---|
| `drivers/block/` | 块设备驱动（virtio-blk / AHCI 用户态化） |
| `drivers/char/` | 字符设备 |
| `drivers/gpu/` | 显卡 |
| `drivers/input/` | 键盘 / 鼠标 |
| `drivers/net/` | 网卡（e1000 用户态化） |
| `drivers/serial/` | 串口 |
| `drivers/usb/` | USB |
| `drivers/libdriver/` | 驱动公共库（IPC、寄存器抽象） |

### 8.3 lib/ 用户库

| 子目录 | 规划职责 |
|---|---|
| `lib/moqi_libc/` | 自研最小 libc，**已实现**（见第 5 节） |
| `lib/elf_types/` | ELF 类型定义 |
| `lib/pe_types/` | Windows PE 格式定义（用于 `win_pers`） |
| `lib/nt_types/` | Windows NT 类型 |
| `lib/driver_api/` | 驱动调用接口（与 `drivers/libdriver/` 配合） |
| `lib/ipc_lib/` | IPC 客户端（封装 send/receive/call） |
| `lib/zig_crt/` | Zig 用户态 CRT（`start.zig` 最小 `_start`，已实现） |

---

## 9. 用户态调试技巧

- 内核串口输出包含每个用户进程关键事件（spawn / exit / signal / page fault）。
- `panic` 时内核会打印 `rip` / `rsp` / `cr2` 等寄存器与符号化栈回溯，可对照用户 ELF 反汇编（`zig objdump -d user/hello21.bin`，C 程序的 `.bin` 即 ELF）定位问题。
- GDB 远程调试：`zig build debug` + `gdb user/sh.bin` + `target remote :1234`，注意 ASLR 关闭，加载地址即链接地址。

---

## 参考

- [moqios-architecture-current.md](./moqios-architecture-current.md)
- [kernel-subsystems.md](./kernel-subsystems.md)
- [build-and-toolchain.md](./build-and-toolchain.md)
- [moqios-design.md](./moqios-design.md)
