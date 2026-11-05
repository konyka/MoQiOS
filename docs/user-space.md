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

### 1.3 系统调用清单（分发表当前扩展至 #486，下表为常用子集）

### 1.3.1 Native IPC capability delegation

`moqipc_grant_cap_to` is syscall #486. It takes `target_tid` in `rdi`,
`endpoint` in `rsi`, and the `send|receive|notify|manage` rights bitmask in
`rdx`. It returns the recipient capability slot or a negative errno: `EINVAL`
for unknown rights/self-target, `EPERM` for a non-owner, `ESRCH` for an absent
target TID, and `ENOMEM` for a full recipient table. Capabilities bind the
endpoint's 64-bit generation, so endpoint slot reuse cannot transfer rights to
a new incarnation. `moqi_syscalls.h` exposes `moqi_grant_cap_to()`.

| 类别 | 调用 |
|---|---|
| 进程控制 | `exit`, `getpid`, `spawn`, `waitpid`, `fork`, `execve`, `kill` |
| 文件 I/O | `write`, `open`, `read`, `close`, `dup2` |
| 信号 | `sigaction`, `sigprocmask`, `sigreturn` |
| 管道 | `pipe` |
| 文件系统 | `listdir`, `chdir`, `getcwd`, `mkdir(path, mode)`, `unlink`, `truncate` |
| 网络 | `net_send`, `net_recv`, `net_poll`, `tcp_connect`, `tcp_send`, `tcp_recv`, `tcp_close`, `tcp_listen`, `socket`, `bind`, `accept`, `sendto`, `recvfrom`, `connect` |
| 环境变量 | `getenv`, `setenv` |
| 内存 | `brk` |
| 调度 | `sched_setscheduler` (#473), `sched_getscheduler` (#474), `sched_get_priority_max` (#475), `sched_get_priority_min` (#476), `sched_setattr` (#308), `sched_getattr` (#309), `sched_setaffinity` (#273), `getpriority` (#232), `setpriority` (#233) |

详细行为参见 syscall 入口与分发表 `kernel/arch/x86_64/syscall_entry.zig`（`syscallDispatch`
中的 `switch (syscall_nr)`，编号扩展至 #486）。

> 注：调度类系统调用使用 MoQiOS 自有编号——Linux 的 156/157/146/147 在本分发表已被
> msgget/msgsnd/epoll_create1/epoll_ctl 占用。SCHED_OTHER=0 / SCHED_FIFO=1 / SCHED_RR=2
> 与 Linux 策略编号一致；FIFO/RR 的 `sched_priority` 合法范围 1..99，OTHER 必须为 0。

---

## 2. init 进程

文件：`servers/init/main.c`（C，基于 moqi_libc，见第 5 节），编译安装为
`zig-out/user/init.bin`，作为 PID 1。2026-08 起取代汇编实现；`user/init.S`
（汇编，约 1306 行）保留在源码树中作为回退参考，但不再参与构建。
C 版保持成功路径的字节级行为一致：相同 spawn 顺序、相同打印行、相同 waitpid 语义。
`SYS_spawn` 返回恰好 `-1` 时，init 打印 `spawn failed <program>`，跳过该程序的成功标记和
`waitpid`，并继续后续配置的 spawn。

职责：

1. 顺序 `spawn` 自动化测试程序（当前从 `hello2` 到 `hello229`，权威序列是 `servers/init/main.c`；其中 `hello6`、`hello11`、`hello28`、`hello116`、`hello149`、`hello230`–`hello233` **不**在
   init 自动序列内：它们分别是会阻塞的键盘程序、exec 目标、手工复现程序和被别的测试启动的探针），并 `waitpid` 收回；随后进入交互 shell。
2. 仅监督 `servers/init/main.c` 中 `persistent_services` 显式登记的常驻服务；当前列表为
   `syslogd` 和 `devmgr`。`hello*` 测试与 `sh` 均为一次性进程，不纳入监督。
3. 测试全部通过后启动一次交互式 Shell（`sh`）；PID 1 保持运行并继续回收子进程。

### 2.1 有界服务监督策略

监督器是 `servers/init/supervisor.h` 中的固定大小状态机：最多 4 个服务，不使用动态内存。
按服务槽保存名称、当前 TID、状态和已使用的重启次数；子进程退出时最多线性扫描 4 个槽，
因此查找成本具有明确的小常数上界。

- 初次 spawn 成功：记录 TID，服务进入运行状态，不消耗重启预算。
- 初次 spawn 返回恰好 `-1`：打印 `spawn failed <name>`，随后立即尝试重启；spawn 失败与
  异常退出共享同一预算。
- 退出码为 `0`：视为干净退出，回收后停止，不重启。
- 退出码非 `0`（包括内核编码为 `128 + signal` 的致命信号退出）：立即重启。
- 每个服务最多执行 3 次重启 spawn；成功的重启同样消耗一次。预算耗尽后打印
  `service disabled <name>`，禁用该服务直至下次启动系统。
- 未登记或 TID 不匹配的子进程只正常回收，不影响任何服务状态。

这是第一阶段的最小 PID 1 监督，不提供退避或定时窗口、服务依赖图、就绪协议、看门狗、
系统范围进程重启或持久化监督日志；也不改变现有日志服务的持久化策略。重启预算仅保存在
本次 init 进程的内存中。

伪流程：

```
main():
    printf("init (pid %ld) started\n", getpid());
    spawn("hello2");  waitpid;
    ...
    spawn("hello44"); waitpid;   // SCHED_FIFO/RR realtime classes (after hello42)
    spawn("hello9/10/21"); waitpid;   // fork/ext2 写测试排在最后
    spawn("sh");
    forever: waitpid; dispatch registered service exits
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
| `ls [path]` | 列出目录（`opendir`/`readdir`，每行一个名字，不含 `.` 和 `..`）；不带参数列工作目录；`path` 是文件则打印它的名字；打不开则报错并以状态 1 结束 |
| `cd [path]` | 切换工作目录（`chdir`）；不带参数去 `/`；失败（目录不存在、是文件）打印 `cd: failed`、状态 1、工作目录不变，所以 `cd X && cmd` 在失败时不会运行 `cmd`。不支持 `cd -` 和 `cd ~` |
| `pwd` | 打印当前工作目录（`getcwd`） |
| `export KEY=VALUE` | 名字必须是 `[A-Za-z_][A-Za-z0-9_]*`，否则打印 `export: not a valid name`、状态 1；内核环境表写失败（表满等）状态 1；`export NAME`（无 `=`）不改任何东西，状态 0。设置环境变量：同时写进内核的每任务环境表（`$NAME` 读它）和 C 库的 `environ`（shell 启动的程序继承它） |
| `env` | 打印 `environ` 里所有的 `NAME=value`，每行一个 |
| `wait [PID]` | 等待后台任务（见 3.2a） |
| `help` | 显示内置命令帮助 |

### 3.1a 从文件或管道读命令

`sh FILE` 把 FILE 当作标准输入再按下面的规则执行（FILE 打不开、是目录或不可读：打印 `sh: cannot open/read FILE`、状态 127，什么都不运行；多余的参数被忽略）。`sh < script` 或 `producer | sh`：标准输入不是终端时，shell 不打印横幅、提示符 `> ` 和输入回显，逐行执行；输入结束时（`read` 返回 0）以最后一个命令的状态退出，最后一行没有换行也照常执行，空输入退出码 0。`exit N` 照常提前结束。结束时不等待仍在后台运行的任务（与 POSIX shell 一致）。标准输入是终端时行为不变（交互提示符、行编辑、遇到 EOF 让出 CPU 继续等待）。

### 3.2 外部命令

通过 `spawn`/`fork`+`execve` 启动 ELF；按 `PATH` 解析（默认 `/`）。`execve` 把 shell 当前的 `environ` 传给新程序，所以 `export` 过的变量会被继承（含后台任务、嵌套的 `sh -c`）。

### 3.2a 命令列表与 `sh -c`

- `sh -c "<命令行>"`：不打印提示符和 `bye`，执行一行后以最后一个命令的退出状态结束（被信号杀死则 128+信号）；`system()` 就是这样启动它。命令行整体是 `execve` 的一个参数，最长 127 字节；更长的 `system()` 返回 127（shell 没启动）。
- 命令之间可以用 `;`（总是执行下一个）、`&&`（上一个成功才执行）、`||`（上一个失败才执行）连接，自左向右求值，没有优先级和括号；状态是最后一个**实际执行**的管道的状态。`exit N` 在被执行到时结束 shell，其后的命令不再运行。
- 变量：`$NAME` 和 `$?` 在**每个列表元素即将运行之前**展开（不是读入整行时），所以 `$?`（上一个实际运行的命令的退出码，信号杀死为 128+信号，一个命令都没跑过时为 0；被 `&&`/`||` 跳过的命令不改变它）和同一行里前面 `export` 的变量都是最新的。双引号内的 `$X` 同样展开，但展开出的值里的空格和分隔符会被保护（`"$X"` 始终是一个单词）。
- 引号和转义（`protect_quotes`，在切分之前改写整行并去掉引号）：单引号内一切都是字面的，`$` 也不展开；双引号内空格、制表符、`;`、`&`、`|`、`>`、`<` 是普通字符，`$` 照常展开，反斜杠只在 `\`、`"`、`$` 之前生效（使其字面化），在其它字符前原样保留；引号外反斜杠使下一个字符字面化并被丢弃（行尾孤立的反斜杠保留）。没有闭合的引号延伸到行尾。做法是把被保护的字符换成控制字节 1..7（`$` 换成 14 或 8），切分之后由 `unprotect` 还原；行里手写的这些控制字节与被保护的字符无法区分。空元素视为成功；整行最长 255 字节。
- 后台任务：单个 `&` 结束一个元素（像 `;`），但把这个管道作为后台任务启动、不等待，该元素状态为 0；`$!` 是最近一个后台任务（管道的最后一个进程）的 pid。内建 `wait` 等待全部后台任务并返回 0，`wait PID` 等待该任务并返回它的退出状态，PID 不是本 shell 的子进程时返回 127。前台命令按自己的 pid 等待（不再 `waitpid(-1)`），所以先结束的后台任务不会被误当成前台命令的状态。交互提示符每次出现前会回收已结束的后台任务。后台任务表最多 16 个，用于 `wait PID` 和提示符前回收已结束的任务；表满后新任务不再被记录，但裸 `wait` 用 `waitpid(-1)` 等待 shell 的**所有**子进程，所以仍会等到它们；`wait PID` 对不在表里的任务同样有效（它直接按 pid 等待）；没有作业编号、`jobs`、`fg`/`bg`，后台任务的标准输入仍是终端。
- 内建命令（`echo`、`pwd`、`ls`、`pid`、`help`、`env`）支持 `> file` 重定向。

### 3.3 管道

`cmd1 | cmd2`：

1. `pipe(fds)`
2. fork cmd1：`dup2(fds[1], 1)`，关闭 `fds[0]`
3. fork cmd2：`dup2(fds[0], 0)`，关闭 `fds[1]`
4. 父进程关闭两端，`waitpid` 双方

管道缓冲 4095 字节。阻塞模式的 `write` 遇到满管道会睡到读者腾出空间（大于缓冲的写会分段完成）；非阻塞返回 `EAGAIN`；被处理函数打断时已写部分的字节数优先，一个字节没写返回 `EINTR`（`SA_RESTART` 则重启）；读者全部关闭返回 `EPIPE` 并发 `SIGPIPE`。不超过管道容量（4095 字节）的写是原子的：整块放得下才写（阻塞则等到够用，非阻塞返回 `EAGAIN`），不会和别的写者的数据交错；更大的写分段放入，段间可能夹入别的写者的数据。Linux 的 `PIPE_BUF` 是 4096，这里的原子范围是 ≤4095。

### 3.4 重定向

- `>` / `>>`：`open(O_WRONLY|O_CREAT[|O_TRUNC|O_APPEND])` + `dup2(fd, 1)`；作用于管道里的**最后**一个命令，内建命令（`echo`、`pwd` 等）同样遵守。
- `<`：`open(O_RDONLY)` + `dup2(fd, 0)`；作用于管道里的**第一个**命令。文件打不开时该命令以状态 1 结束，不会改去读终端。运算符两侧不需要空格；引号内的 `<`、`>` 是普通字符。
- 不支持：`2>`、`>&`、here-doc、一个命令里同时出现多个同方向重定向（取第一个）、对内建命令的 `<`（内建不读标准输入）。
- 历史：这一节在 hello227 的 B7 之前写着 `>>` 和 `<` 可用，但实际上 shell 既不认 `>>`（会把第二个 `>` 当成文件名的一部分）也不处理 `<`（只是把它当作参数分隔符，命令照旧读终端）；现在才真正实现并有用例。

### 3.5 信号处理

- Ctrl+C 触发 SIGINT：Shell 安装 handler，仅打印新提示符，不退出。
- 子进程收到 SIGINT 时由内核默认 terminate。

---

## 4. 测试程序（hello 系列）

`user/hello2.*` ~ `user/hello233.c` 是渐进式功能测试；其中 hello2~hello44 是早期基础系列，
hello45 之后的程序由当前 `servers/init/main.c` 按验收门禁顺序启动：

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
| hello45..hello101 | 当前验收门禁，覆盖 libc ABI、IPC、网络、SMP、swap 与 raw syscall；完整启动顺序以 `servers/init/main.c` 和 `tools/qemu_smoke.sh` 为准 |
| hello102..hello113 | 内核行为回归：阻塞 `clock_nanosleep`/`getrusage`、`UMIP`、实时线程唤醒抢占、超时在下一个 tick 到期、控制台滚动开销、内核锁争用、回收僵尸不抢 RT 任务、`sigaction/sigreturn`、`madvise(MADV_DONTNEED)`、`kill`/`SIGCHLD`、`sigaltstack`、SysV IPC/poll/AF_UNIX 加固 |
| hello114..hello134 | 第二块 virtio 盘上的只读 ext4/NTFS；身份变更与能力；`prctl`；`memfd_create`；`rename`/`renameat2`；`mseal`；工作目录与目录描述符；`execve` 错误；`utimensat`；`linkat`/`symlinkat`/`fchownat`；`statx`；`access`；`open/unlink/rmdir/mkdir/rename/truncate` 的 errno；fd 语义；`fcntl/dup3/pipe`；`mmap` 家族错误；时钟；进程生命周期；`socket` 类型标志 |
| hello135..hello148 | 信号调用参数与 errno；实时信号 32..64；`siginfo_t`/`ucontext_t`；`uname`/`rlimit`/`sysinfo`；`poll/select`；`ppoll/pselect6`；`ioctl`；`SCM_RIGHTS`；各种 socket 选项；UDP 阻塞/超时接收；`sendmsg/recvmsg`；`sendmmsg/recvmmsg`；`fstat` 文件类型 |
| hello149..hello195 | AF_UNIX 阻塞写与 `shutdown`；TCP 读写/半关闭/`SIGPIPE`/`poll`/`EPOLLRDHUP`/关闭端口的 RST；UDP 端口不可达；`MSG_PEEK/WAITALL/TRUNC`；`SEQPACKET`；进程 CPU 时间；IPv6 回环；`TIOCOUTQ`、`SO_SNDBUF/RCVBUF`、网卡 ioctl、TCP/IP/套接字选项；`getsockname`；`bind` 错误；各类 errno 一致性（对照真实 Linux）；hello190..hello193 是敌意参数扫描；hello195 是 `dns_resolve`。hello149 是只在手工启动时用的复现程序，init 与冒烟不跑它 |
| hello196..hello199 | `gethostbyname_ipv4`/`ipv4_to_text`；`gettimeofday` 指针错误；`mlock` 与 `mlockall`/`MAP_LOCKED` 的 `RLIMIT_MEMLOCK` 门禁（期望值取自真实 Linux） |
| hello200..hello208 | moqi_libc 在真内核上的验收：`mmap` 家族、时间 API、`gmtime_r/timegm/mktime/strftime`、`strptime/asctime/ctime`、`strtol` 家族与 `string.h`、`qsort/bsearch/rand_r`、`setenv` 家族（含传给 `execve`）、`realloc` 与对齐分配、`printf` 家族 |
| hello209..hello215 | 线程共享的进程状态：`brk`、映射、信号处置、`RLIMIT_AS`、资源限制、`chdir`/`umask`（`CLONE_FS`）、`pthread_create`+`join` 反复 |
| hello216..hello224 | 系统调用保持寄存器、`strtod/strtof`（含 xmm 状态跨上下文切换）、`printf` 浮点、`FILE` 流、`scanf` 族、`setjmp` 族、共享当前目录的并发、`math`/`ctype`、`/proc/lostats` |
| hello225 | `pause`/`alarm`/`gettid` |
| hello226 | `atexit/exit/abort/raise/assert/signal()/sigprocmask/perror/remove/rename/isatty` 与 id 调用，每个会终止进程的用例在 fork 的子进程里跑 |
| hello227 | `system()` 与 shell：`sh -c` 的状态、命令列表 `; && \|\|`、引号与反斜杠、`$?`/`$!`/延迟变量展开、后台 `&` 与 `wait`、`<` `>>`、`export`/`env`、`ls`、`cd` 与重定向失败的状态（见第 3 节） |
| hello228 | 线程 `join` 之后立刻复用其内存：4000 个线程，每个带栈上金丝雀 |
| hello229 | `SA_RESTART`（`read`/`write`/`waitpid`/`wait4`/`readv`/`writev`/`accept`/`recvfrom`）、管道写阻塞、`EINTR`/`EPIPE`、`PIPE_BUF` 原子性 |
| hello234 | `poll`/`ppoll` 的 libc 封装在真内核上：管道的 `POLLIN`/`POLLOUT`/`POLLHUP`、`POLLNVAL`、负描述符被忽略、超时、被写者唤醒、信号处理函数打断得 `EINTR`、`ppoll` 掩码挡住信号 |
| hello235 | 被信号打断的阻塞调用在返回 `-EINTR` **之前**已经运行了处理函数：`epoll_wait`、`futex(FUTEX_WAIT)`、SysV `semop`、`rt_sigtimedwait`、`mq_timedreceive`、`recvmmsg`、`connect` |
| hello230 / hello231 | hello227 用的小探针：`hello230` 是 `cat` 的替身（标准输入拷到标准输出，或 `count` 只统计字节数），`hello231` 检查环境变量 `H231V` |

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
| `include/stdio.h` | printf 家族（printf/vprintf/dprintf/vdprintf/snprintf/vsnprintf/sprintf/vsprintf/asprintf/vasprintf）、puts/putchar；语法与 glibc 一致：标志 `# 0 - + 空格 ' I`、宽度、精度、`*`、长度 `hh h l ll L q z Z j t`、转换 `d i u o x X b B c s p n m C S %`；浮点 `f F e E g G a A` 与 glibc 逐位一致，无 `long double`、无位置参数（`%1$d`） |
| `include/stdlib.h` | malloc 家族（`malloc/free/calloc/realloc/reallocarray/posix_memalign/aligned_alloc/memalign`）、`exit/atexit/_Exit/abort`、`strtol` 家族与 `atoi` 系列、`strtod/strtof/atof`、`qsort/bsearch/rand/srand/rand_r`、`abs/div` 家族、`getenv/setenv/unsetenv/putenv/clearenv`、`system` |
| `include/ctype.h` | isdigit/isalpha/isspace/toupper 等（纯头文件） |
| `include/signal.h` | glibc 的信号编号（SIGUSR1=10、SIGUSR2=12、SIGALRM=14、SIGRTMIN=34）、`sigset_t`（128 字节，只用前 64 位）、`signal()`（BSD 语义，返回旧处理函数）、`raise()`（发给调用线程，经 `gettid`+`tkill`）、`abort()`、`sigemptyset/sigfillset/sigaddset/sigdelset/sigismember`、`sigprocmask`/`sigpending`/`sigsuspend`、`struct ksigaction`（匹配内核读取的 28 字节布局）与 `sigaction` |
| `include/assert.h` | `assert`（失败时 stderr 输出 glibc 同款一行并 `abort()`，`NDEBUG` 下展开为空且不求值）、`static_assert` |
| `src/crt0.c` | `_start`（naked）：捕获入口 rsp → `_start_c` 解析 argc/argv/envp → 设置 `environ` → `main(argc, argv, envp)` → `_exit(main(...))` |
| `src/format.c` | printf 格式化核心（无 syscall，可在宿主机测试） |
| `src/malloc.c` | 分配器核心（无 syscall；经弱符号 `__moqi_heap_grow` 扩容） |
| `src/sbrk.c` | 强符号 `__moqi_heap_grow`，基于 brk 实现 |
| `src/unistd.c` `src/stdio.c` `src/stdlib.c` | 薄 syscall 封装、fd 1 输出与 getenv（仅 freestanding） |
| `include/poll.h` `src/poll.c` | `poll`/`ppoll`：glibc 的 `struct pollfd`（8 字节）和事件位；`poll` 返回就绪描述符个数、超时 0、失败 -1 加 errno（被信号处理函数打断是 `EINTR`）；`ppoll` 的信号掩码大小固定传 8（掩码为 NULL 时传 0）。没有 `select()` 的 libc 封装（内核调用存在） |
| `include/errno.h` `time.h` `mman.h` `resource.h` `netdb.h` `byteorder.h` `setjmp.h` `pthread.h` `math.h` `getopt.h` `dirent.h` | 对应的 libc 头文件：`errno`（每线程）、`clock_gettime`/`nanosleep`/`strftime` 等、`mmap` 家族、`getrlimit`/`setrlimit`、`gethostbyname`/`getaddrinfo`（仅 IPv4）、`htons` 家族、`setjmp` 家族（仅 x86-64）、pthread 子集、`<math.h>` 里结果有精确定义的部分 |
| `src/env.c` | `setenv/unsetenv/putenv/clearenv`（第一次修改时把初始栈上的 envp 拷进自己持有的 malloc 数组，被替换的旧字符串和旧数组不释放，因为 `getenv` 不加锁遍历） |
| `src/algo.c` `src/numconv.c` `src/strtod.c` | `qsort/bsearch/rand_r`；`strtol` 家族、`abs/div`、`rand/srand`；`strtod/strtof/atof`（大数整数运算的精确舍入，不用浮点） |
| `src/strfunc.c` `src/string.c` | `string.h` 的其余函数与基础的 `mem*`/`str*` |
| `src/scan.c` `src/scanf.c` `src/stdio_file.c` `src/stdio_streams.c` | `scanf` 引擎与 `sscanf`；`FILE` 层（`fopen/fgets/fread/fprintf/fscanf/...`）与三个标准流 |
| `src/math.c` | `<math.h>` 里只用整数运算、不依赖舍入模式的精确函数（`sqrt`、取整、`fmod`、`nextafter` 等） |
| `src/time.c` `src/timeconv.c` | 时钟与睡眠封装；日历转换与 `strftime`/`strptime`（本地时区固定为 UTC） |
| `src/pthread.c` | pthread 子集（x86-64 TLS variant II，线程栈 64 KiB） |
| `src/mman.c` `src/rlimit.c` `src/netdb.c` | `mmap` 家族、资源限制、主机名解析的封装 |
| `src/setjmp.c` | `setjmp/sigsetjmp/longjmp/siglongjmp`（汇编，仅 x86-64） |
| `src/exit.c` | `atexit`（后注册先执行；handler 内可再注册或再调 `exit`；首块静态、其后 malloc；`atexit(NULL)` 返回 EINVAL）、`exit`（跑完 handler 后 flush 所有 FILE）、`_Exit` |
| `src/system.c` | `system()`：子进程 `sh -c <命令>`，父进程在调用期间忽略 SIGINT/SIGQUIT、阻塞 SIGCHLD，结束后原样恢复，子进程 exec 前先恢复；返回 wait 状态，`system(NULL)` 非零，shell 起不来是退出码 127，fork/wait 失败是 -1 加 errno |
| `src/dirent.c` / `include/dirent.h` | `opendir`/`readdir`/`closedir`/`rewinddir`/`telldir`/`seekdir`/`dirfd`（glibc 布局：`struct dirent` 280 字节、`d_name` 偏移 19；基于 `getdents64` 的 4096 字节缓冲，close-on-exec，`opendir` 用 `fstat` 判目录并给出 `ENOTDIR`；`seekdir` 依赖内核的 `lseek` 游标，rofs（ext4/NTFS）目录只接受回到 0） |
| `src/getopt.c` / `include/getopt.h` | `getopt`/`getopt_long`/`getopt_long_only`（glibc 同款：簇、`::` 可选参数、`+`/`-`/`:` 前缀、`POSIXLY_CORRECT`、argv 置换、`optind=0` 重启、长选项缩写与歧义、`flag` 指针、`W;`、诊断行；54 个短选项场景 + 50 个长选项场景由 glibc 2.43 生成并逐项核对，变异验证） |
| `src/signal.c` `src/assert.c` `src/posix.c` | 信号与 `abort`/`raise`、`assert` 失败路径、`getuid/geteuid/getgid/getegid/getppid`、`alarm/pause`、`isatty`、`remove/rename/rmdir`、`perror`；经 `src/hostsys.h` 的 `MSYS*` 宏取系统调用，宿主机测试用记录桩替换 |
| `host_tests/` | 宿主机单元测试（test_string / test_format / test_malloc / test_args / test_exit_abi / test_signal_abi / test_assert_abi / test_posix_abi … + run_tests.sh） |

### 5.2 设计要点

- **syscall 层尽量薄**：`unistd.c` 每个函数都是 1:1 的 ABI 映射，返回内核原值
  （负数即 `-errno`），不做 errno 转换，因此无需也无法在宿主机测试。
- **可宿主机测试的部分与 syscall 解耦**：格式化核心（`format.c`）与分配器
  （`malloc.c`）不含任何 syscall；分配器通过弱符号 `__moqi_heap_grow(size)` 扩容，
  freestanding 构建由 `sbrk.c` 提供 brk 实现，宿主机测试用静态缓冲区覆盖该弱符号。
  测试方式为 TDD：`host_tests/run_tests.sh` 用 `zig cc`（私有缓存目录，可与
  `zig build` 并行）在本机编译运行断言。
- **malloc**：16 字节对齐的首次适配空闲链表，支持分裂与相邻块合并；扩容按
  4KiB 粒度走 brk（syscall #7）。线程安全（自旋锁，信号重入时 malloc 返回 NULL、free 延迟）；有
  `realloc`、`reallocarray`、`posix_memalign`、`aligned_alloc`、`memalign`，失败设 `ENOMEM`。
- **printf 家族**：共享格式化引擎 `format.c`，语法与 glibc 一致（标志、宽度、精度、`*`、长度修饰符，
  `d i u o x X b B c s p n m C S %` 以及 `f F e E g G a A`），`printf`/`dprintf` 经 512 字节分块的 `write`
  输出、不缓冲；浮点转换用 double 的精确十进制展开再舍入，与 glibc 逐位一致（无 `long double`，无位置参数）。
  另有 `sprintf`、`asprintf` 等，见 `include/stdio.h`。
- **argc/argv/envp 与初始栈契约**：内核（`kernel/proc/user_stack.zig`
  `buildUserStack`）按 System V 布局构建进程入口栈：RSP 指向 argc（8 字节），
  其后依次是 NULL 结尾的 argv 指针数组、NULL 结尾的 envp 指针数组
  （`envp == &argv[argc+1]`，两者恒连续，16 字节对齐 pad 在 envp-NULL 与
  auxv 之间），最后是 auxv 对。execve（syscall #59）把调用者的 argv/envp
  完整传入新程序（各最多 16 项、每项最长 127 字节，更长的返回 `E2BIG` 而不是被截断；第 17 项起被丢弃）；首个进程
  （`loader.loadProgram`）envp 为空。crt0 的 naked `_start` 捕获入口 rsp，
  `_start_c` 用 `include/crt0.h` 的 `moqi_parse_initial_stack` 解析，
  设置全局 `environ` 后以 `main(argc, argv, envp)` 进入程序。
- **environ / getenv / setenv**：`environ`（unistd.h 声明，crt0.c 定义）指向初始栈上的
  envp 数组；`getenv(name)`（stdlib）纯遍历 `environ`，不发 syscall，返回指向
  `environ` 条目内部的指针。`setenv/unsetenv/putenv/clearenv`（`src/env.c`）在 `environ`
  上工作，行为按 glibc 实测（见 `include/stdlib.h`）；初始栈上的数组不会被原地增长，
  第一次修改时拷贝到自己持有的 malloc 数组。**内核另有一张每任务环境表**
  （`moqi_setenv`/`moqi_getenv`），与 `environ` 是两套机制：`execve` 只传调用者给的 envp，
  不会自动带上内核表里的变量。shell 的 `export` 同时写两处，并把 `environ` 传给
  `execve`（见 3.2），所以 shell 启动的程序能继承 `export` 过的变量。

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

宽字符流、`popen`、文件锁、`long double`（`strtold`、`%Lf`，`scanf` 的 `%Lf` 同样拒绝）、locale、
完整 POSIX 信号语义（`SA_RESTART` 对 `read`/`write`/`waitpid`/`wait4`/`readv`/`writev` 和 socket 的收发/`accept` 生效，睡眠、`pause`、`sigsuspend`、poll/epoll 等待仍返回 EINTR（见 `docs/current-code-review-and-fix-plan.md` 的 SA_RESTART 一节））、`<math.h>` 里的超越函数（`sin`/`cos`/`exp`/`log`/`pow`…）、`float`/`long double` 版本和 `fma`。（`errno`、`realloc`、线程与 TLS、`setenv`/`putenv`、浮点
`printf`/`strtod`、`FILE` 流（`fopen`/`fgets`/`fread`/`fprintf`…）、`scanf` 族（`sscanf`/`fscanf`/`scanf`/`vsscanf`/`vfscanf`/`vscanf`）、`setbuf`/`setbuffer`/`setlinebuf`、`freopen`、`fgetpos`/`fsetpos`、`tmpfile`、`setjmp`/`longjmp`/`sigsetjmp`/`siglongjmp`、`ctype.h` 的全部分类函数和 `<math.h>` 里结果有精确定义的那部分（`sqrt`、取整、`fmod`/`remainder`/`remquo`、`fmax`/`fmin`/`fdim`、`nextafter`、`ldexp`/`frexp`/`modf`、`lround` 族、分类宏）此前列在这里或不存在，现已实现，见各自的 hello 探针与 current-code-review-and-fix-plan.md。）
需要时请按最小需求追加，不要预先泛化。

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

**轮转**：tmpfs 单文件上限为 2.25 MiB（64 直辖页 + 512 间接页，2026-08-14 前的
256 KiB 硬顶已随一级间接页扩容移除；触顶的写会被拒绝/短写），因此采用**写前轮转**——
当下一次写入会使文件超过上限时，先 close 并以 `O_WRONLY|O_CREAT|O_TRUNC|O_APPEND`
（0x641）重开。单代轮转，旧内容直接丢弃，无 `.1` 备份。启动标记为 stdout 一行
`[syslogd] started`。

**事件驱动**：自 J3 起 `/dev/kmsg` 支持阻塞读（读在最新字节处睡眠直到新日志到达），
syslogd 主循环为阻塞读，无轮询。

---

## 8. 微内核化规划目录

下列目录已建立框架，**当前尚未实现**，是迈向微内核架构的预留位置。详见 [moqios-design.md](./moqios-design.md)。

### 8.1 servers/ 用户空间服务

| 子目录 | 规划职责 |
|---|---|
| `servers/init/` | 用户态 init（**已实现**：`main.c` 基于 moqi_libc，取代 `user/init.S`；汇编版保留为回退） |
| `servers/pm/` | 进程管理服务（fork/exec/wait） |
| `servers/vfs/ext4/` | 文件系统服务（ext4 实现，从内核迁出） |
| `servers/devmgr/` | 设备管理 / 命名空间（**已实现**：`main.c` 基于 moqi_libc，事件驱动——阻塞读 `/dev/devfs-watch`（devfs 变更计数器），节点注册/注销（含 devfs_register 的用户态节点）时重新快照 `getdents("/dev")` 并打印 `[devmgr] devices: ...`；无 watch 节点时回退 1 Hz 轮询。启动标记 `[devmgr] started` 入 smoke） |
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

## 10. Launch Credentials And Raw Networking

ELF programs loaded for a new user task start with UID/GID `1000` and no
capabilities. The kernel's initial `init` task is the sole initial exception:
it starts as UID/GID `0` with `ALL_CAPS`. A later launch receives a capability
profile only when the caller is the trusted initial `init` task and the ramdisk
name matches exactly: `hello14` gets `CAP_NET_RAW`, `hello51`/`hello52` get
`CAP_SYS_RAWIO`, `hello54` gets `CAP_SYS_RAWIO` plus `CAP_KILL`, and
`hello13`/`hello58` get `CAP_KILL`, and `hello95`/`hello114` get
`CAP_SYS_MOUNT`, and the swap acceptance tests `hello96`/`hello98`/`hello99`/
`hello100`/`hello101` get only `CAP_SYS_ADMIN`. The legacy ext2 fixture programs
`hello21`/`hello23`/`hello24`/`hello25`/`hello29`/`hello77` get
`CAP_DAC_OVERRIDE|CAP_CHOWN` so they can prepare and exercise files in the
root-owned 0755 root directory; `hello114` does not receive those capabilities.
All other names remain unprivileged.

`setpriority` follows Linux: changing another user's process needs
`CAP_SYS_NICE`, and lowering a nice value (raising priority) always does;
the new value is clamped to [-20, 19] and a pid beyond 32 bits is `ESRCH`.
`sched_setaffinity`, `sched_setscheduler` and `sched_setattr` on another user's
process need `CAP_SYS_NICE`, and entering `SCHED_FIFO`/`SCHED_RR` always does.
POSIX message queues record their creator's euid/egid and
`(mode & 0777) & ~umask`; `mq_open` of an existing queue checks the requested
access against them and `mq_unlink` is limited to the owner (or root /
`CAP_DAC_OVERRIDE`); denials are `-13` (`EACCES`).
`kcmp` only compares processes the caller owns unless it holds
`CAP_SYS_PTRACE`. The realtime acceptance tests `hello44`/`hello104`/`hello108`
get only `CAP_SYS_NICE`.
`sethostname`, `setdomainname`, `swapon`, `swapoff` and the swap test hook
`pmm_set_reclaim_floor` require `CAP_SYS_ADMIN`;
`mount` and `umount2` require `CAP_SYS_MOUNT`; without them they return `-1`
(`EPERM`) and change nothing.

AF_INET `SOCK_RAW` creation and the custom raw network send/receive syscalls
return `EPERM` unless the current task has `CAP_NET_RAW`; TCP and UDP sockets
are unaffected. Fork, clone, and ordinary exec preserve the task credentials
and capability sets.

### 10.1 First-phase tmpfs DAC boundary

The first DAC phase applies only when opening an existing regular file under
`/tmp` and when listing an existing tmpfs directory. Regular-file open access
uses the effective UID/GID and the owner, group, or other mode bits; `O_RDONLY`
is access mode zero, and `O_TRUNC` adds a write requirement. Authorization is
performed while the tmpfs lock is held and before the open reference or file
contents are changed. A denial returns `-13` (`EACCES`) and leaves the file
size and directory-listing state unchanged.

UID `0` and effective `CAP_DAC_OVERRIDE` bypass these checks. Fresh tmpfs
objects created by `O_CREAT` or `mkdir` receive the caller's effective
UID/GID, and their permissions are `(requested_mode & 0777) & ~(umask & 0777)`
before the object becomes visible. Existing objects keep their metadata;
`O_CREAT|O_EXCL` returns `-17` (`EEXIST`) without modifying them. This phase
does not revalidate already-open descriptors and does not alter ramdisk, devfs,
or FAT32 behavior. Group management, ACLs, and setuid behavior are outside this
boundary.

The tmpfs root (`/tmp`) is mode `1777`. Creating an entry needs write+search on
its parent directory; unlink/rmdir need the same and, in a sticky directory,
additionally that the caller owns the entry or the directory, is uid 0, or holds
`CAP_FOWNER` (`dac.mayRemoveEntry`). chmod and chown on `/tmp` paths use the
same owner rules as ext2, both by path and through an open descriptor
(`fchmod`/`fchown`). A denial is `-13` (`EACCES`) for namespace changes and
`-1` (`EPERM`) for chmod/chown.

chmod/fchmod/fchmodat/fchmodat2 and chown/fchown/lchown on the ext2 root disk
are authorized against the inode's current owner (`fs/dac.zig` `mayChmod` /
`mayChown`, checked under the ext2 lock): changing permission bits needs the
owner, uid 0 or `CAP_FOWNER`; giving a file to another user needs `CAP_CHOWN`;
the owner may change the group only to its effective group (supplementary groups
are not tracked); a non-owner is refused with `-1` (`EPERM`). `chown(-1, -1)`
changes nothing and succeeds.

Opening an existing ext2 file applies the same open decision as tmpfs
(`dac.decideExistingOpen` against the inode's owner and mode bits, before any
truncation); a denial is `-13` (`EACCES`). New ext2 files, directories and
symlinks record the creator's effective UID/GID, and files/directories get
`(requested_mode & 0777) & ~(umask & 0777)`; symlinks are always 0777. Programs
must therefore pass a real mode to `open(O_CREAT)` — a zero mode creates a file
nobody but root can open.

`user.*` extended attributes on ext2 follow the file's own mode: set/remove need
write permission, get/list need read permission, and a denial (`-13`) is
reported before whether the attribute exists.

Namespace mutation (create, mkdir, symlink, unlink, rmdir, rename and hardlink)
checks search permission on intermediate directories and write+search on the
final parent while holding the ext2 lock. A denial is `-13` (`EACCES`), not a
fallback to FAT32. Opening a path (and statx, access and truncate by path)
checks search permission on every directory walked; a denial is `-13`
(`EACCES`). Sticky-bit semantics are not implemented; tmpfs and FAT32
namespace mutation still has no parent-directory DAC.

Independent of DAC, descriptor access modes are enforced at read time
regardless of filesystem: reading a descriptor opened `O_WRONLY` fails with
`-9` (`EBADF`). Callers that need both directions must open `O_RDWR`.

---

## Reference

- [moqios-architecture-current.md](./moqios-architecture-current.md)
- [kernel-subsystems.md](./kernel-subsystems.md)
- [build-and-toolchain.md](./build-and-toolchain.md)
- [moqios-design.md](./moqios-design.md)
