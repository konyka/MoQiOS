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

文件：`user/init.S`（汇编，约 1306 行），编译为 `user/init.elf`，作为 PID 1。

职责：

1. 顺序 `spawn` 自动化测试程序（`hello2`–`hello44`；其中 `hello11` 与 `hello28` **不**在
   `init.S` 自动序列内），并 `waitpid` 收回；随后进入交互 shell。
2. 测试全部通过后启动交互式 Shell（`sh`）。
3. 在 Shell 退出后处于阻塞状态（避免内核因 init 退出而 panic）。

伪流程：

```
_start:
    setup_argv_envp
    spawn("hello2");  waitpid;
    ...
    spawn("hello44"); waitpid;   // SCHED_FIFO/RR realtime classes (after hello42)
    spawn("sh");      waitpid;
    loop_forever
```

为什么用汇编：避免依赖 libc，便于直接控制系统调用号与栈布局。

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
| `include/unistd.h` | read/write/open/close/lseek/fork/execve/waitpid/_exit/pipe/dup2/yield/nanosleep/brk/sbrk 等 |
| `include/string.h` | memcpy/memmove/memset/memcmp/strlen/strcmp/strncmp/strcpy/strncpy/strcat/strchr/strrchr |
| `include/stdio.h` | print/puts/putchar/printf（%d %i %u %x %X %s %c %p %%，支持 l/ll；无浮点）+ snprintf/vsnprintf |
| `include/stdlib.h` | malloc/free/calloc（brk 上的首次适配空闲链表）、exit、atoi |
| `include/ctype.h` | isdigit/isalpha/isspace/toupper 等（纯头文件） |
| `include/signal.h` | `struct ksigaction`（匹配内核读取的 28 字节布局）、sigaction、SIGINT/SIG_IGN 等 |
| `src/crt0.c` | `_start`：对齐栈 → 调 `main()` → `_exit(main())` |
| `src/format.c` | printf 格式化核心（无 syscall，可在宿主机测试） |
| `src/malloc.c` | 分配器核心（无 syscall；经弱符号 `__moqi_heap_grow` 扩容） |
| `src/sbrk.c` | 强符号 `__moqi_heap_grow`，基于 brk 实现 |
| `src/unistd.c` `src/stdio.c` `src/signal.c` `src/stdlib.c` | 薄 syscall 封装与 fd 1 输出（仅 freestanding） |
| `host_tests/` | 宿主机单元测试（test_string / test_format / test_malloc + run_tests.sh） |

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

### 5.3 编写新的 libc 用户程序

1. `user/foo.c` 以 `int main(void)` 为入口（crt0 提供 `_start`），按需
   `#include <stdio.h> <unistd.h> <string.h> <stdlib.h> <ctype.h> <signal.h>`。
2. 把程序名加入 `build.zig` 的 `libc_programs` 列表（`addLibcUserProgram` 会
   连同 `lib/moqi_libc/src/*.c` 一起编译链接；手工编译命令见
   [build-and-toolchain.md](./build-and-toolchain.md) 第 4 节）。
3. 输出仍是 `zig-out/user/<name>.bin`（静态 freestanding ELF），与裸 C 程序一致。

现有示范：`user/sh.c`（最大消费者）与 `user/hello10.c` 已迁移到 moqi_libc，
PASS 标记与原始版本逐字节一致。

### 5.4 有意缺失

浮点 printf、stdio 缓冲/FILE、errno 全局量、realloc、线程与 TLS、locale、
setjmp/longjmp、完整 POSIX 信号语义。需要时请按最小需求追加，不要预先泛化。

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

## 7. 微内核化规划目录

下列目录已建立框架，**当前尚未实现**，是迈向微内核架构的预留位置。详见 [moqios-design.md](./moqios-design.md)。

### 7.1 servers/ 用户空间服务

| 子目录 | 规划职责 |
|---|---|
| `servers/init/` | 用户态 init（替代当前 `user/init.S`） |
| `servers/pm/` | 进程管理服务（fork/exec/wait） |
| `servers/vfs/ext4/` | 文件系统服务（ext4 实现，从内核迁出） |
| `servers/devmgr/` | 设备管理 / 命名空间 |
| `servers/netstack/` | 网络协议栈服务（从内核迁出） |
| `servers/ttyd/` | 终端 / 控制台守护 |
| `servers/syslogd/` | 日志服务 |
| `servers/powermgr/` | 电源管理 |
| `servers/vmm/` | 虚拟机监视器（容器/沙箱） |
| `servers/linux_pers/` | Linux 个性（兼容 Linux 系统调用） |
| `servers/win_pers/` | Windows 个性（PE / Win32 兼容） |

### 7.2 drivers/ 用户空间驱动

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

### 7.3 lib/ 用户库

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

## 8. 用户态调试技巧

- 内核串口输出包含每个用户进程关键事件（spawn / exit / signal / page fault）。
- `panic` 时内核会打印 `rip` / `rsp` / `cr2` 等寄存器与符号化栈回溯，可对照用户 ELF 反汇编（`zig objdump -d user/hello21.bin`，C 程序的 `.bin` 即 ELF）定位问题。
- GDB 远程调试：`zig build debug` + `gdb user/sh.bin` + `target remote :1234`，注意 ASLR 关闭，加载地址即链接地址。

---

## 参考

- [moqios-architecture-current.md](./moqios-architecture-current.md)
- [kernel-subsystems.md](./kernel-subsystems.md)
- [build-and-toolchain.md](./build-and-toolchain.md)
- [moqios-design.md](./moqios-design.md)
