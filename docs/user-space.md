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

1. 顺序 `spawn` 自动化测试程序（当前从 `hello2` 到 `hello401`，权威序列是 `servers/init/main.c`；其中 `hello6`、`hello11`、`hello28`、`hello116`、`hello149`、`hello230`–`hello233` **不**在
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
| hello228 | 线程 `join` 之后立刻复用其内存：4000 个线程，每个带栈上金丝雀；join 等到内核清零 `CLONE_CHILD_CLEARTID` 字才回收线程块 |
| hello229 | `SA_RESTART`（`read`/`write`/`waitpid`/`wait4`/`readv`/`writev`/`accept`/`recvfrom`）、管道写阻塞、`EINTR`/`EPIPE`、`PIPE_BUF` 原子性 |
| hello234 | `poll`/`ppoll`/`select` 的 libc 封装在真内核上：管道的 `POLLIN`/`POLLOUT`/`POLLHUP`、`POLLNVAL`、负描述符被忽略、超时、被写者唤醒、信号处理函数打断得 `EINTR`、`ppoll` 掩码挡住信号 |
| hello235 | 被信号打断的阻塞调用在返回 `-EINTR` **之前**已经运行了处理函数：`epoll_wait`、`futex(FUTEX_WAIT)`、SysV `semop`、`rt_sigtimedwait`、`mq_timedreceive`、`recvmmsg`、`connect` |
| hello236 | `epoll_*` 的 libc 封装在真内核上：packed 布局、`ADD`/`MOD`/`DEL`、`EEXIST`/`ENOENT`、超时、水平触发、数据字原样返回、写端关闭后的 `EPOLLHUP`、`EBADF`/`EINVAL` |
| hello237 | TCP 套接字上的 epoll（回环，靠 `netpoll` 推进）：`EPOLLET` 只报新边沿；正常 FIN 关闭给 `EPOLLIN\|EPOLLRDHUP`（`0x2001`）；对端关闭时带着未读数据（RST）给 `0x2019`；被 RST 唤醒的阻塞 `recv`；监听套接字关闭时尚未被 `accept` 的已建立连接收到 RST（`0x201d`，`recv` 先 `-ECONNRESET` 再 0）；对监听套接字 `shutdown`：`SHUT_RD`/`SHUT_RDWR` 与 `close` 一样停止监听、`SHUT_WR` 不改变任何东西；RST 之后 `getsockopt(SO_ERROR)` 读到 `ECONNRESET` 一次并清掉（`send` 先报告则读到 0） |
| hello238 | `pselect` 与 `epoll_pwait` 的 libc 封装在真内核上：超时、`timespec` 不被改写、就绪管道；信号被阻塞且待处理时，空的临时掩码让处理函数先运行、调用以 `EINTR` 失败、旧掩码恢复；掩码为 NULL 时阻塞的信号不打断等待 |
| hello239 | 上面那批描述符/文件调用在真内核上（48 项）：`dup` 共享偏移、`dup3` 的 `EINVAL`/`O_CLOEXEC`、`fcntl` 各命令、`pread`/`pwrite` 不动文件偏移、`truncate`/`ftruncate` 截断与零填充扩展、`fsync`/`fdatasync`、`access` 的 `ENOENT`/`EINVAL`、`umask`、`pipe2` 的 `O_NONBLOCK`/`O_CLOEXEC`、`fchdir`；以及 tmpfs 文件的大小对所有描述符一致（`truncate`/`ftruncate`/追加写通过另一个描述符可见） |
| hello240 | `stat`/`lstat`/`fstat`/`chmod`/`fchmod`/`readlink`/`symlink`/`link` 在真内核上（tmpfs 与 ext2）：类型/权限/大小/链接数、`ENOENT`/`ENOTDIR`/`ENAMETOOLONG`/`EBADF`/`EEXIST`/`EINVAL`、符号链接 `lstat` 与 `stat` 的差别、`readlink` 不带 NUL、硬链接使 `nlink` 变 2、`chmod` 保留 setuid/setgid/sticky；文件名结尾的 `/` 对普通文件是 `ENOTDIR`（`open`/`stat`/`access`/`chmod`） |
| hello241 | tmpfs 条目在最后一次 `close` 后归还（用“创建文件直到表满”测剩余条目数）：`create+close+unlink`、`stat` 一个已打开的文件、同一文件 `open` 两次后按两种顺序关闭、打开后 `unlink` 仍可读、`dup`/`fcntl(F_DUPFD)`/`dup3`/`dup2`（覆盖已打开的目标）、`dup` 在原描述符关闭并 `unlink` 后仍可读写、`mkdir`+`chdir`+相对名 `open`+`rmdir` 不留条目；`fork` 后子进程关闭自己那份、父进程的描述符仍可读写，子进程不关闭直接退出也各释放一份 |
| hello242 | `uname`/`gethostname`/`getrandom`/`getentropy`/`getpagesize`/`sysconf` 在真内核上（40 项），含 `sched_getaffinity` 对未固定任务报告全部已配置 CPU，含内核 `getrandom` 的新规则：任意长度（上限 32 MiB/次）整块写满、未知标志与 `RANDOM\|INSECURE` 同用是 `EINVAL`、零长度请求不碰指针、空/未映射/内核地址的缓冲区是 `EFAULT` |
| hello243 | `sched_setaffinity` 的掩码规则（原生系统调用，对照 `sched_getaffinity`）：大小为 0、空掩码、只有不存在的 CPU（60、64）是 `EINVAL`；坏指针 `EFAULT`、不存在的 pid `ESRCH`；任意非零大小可用（1 字节、200 字节）；把所有 CPU 都点名就解除固定（`getaffinity` 再报告全部）；固定到单个 CPU 后 `getaffinity` 报告的恰好是那个 CPU（任务是否立刻迁到那个 CPU 只打印、不断言：迁移偶尔有延迟，修改前的内核上就存在）；`{1,60}` 忽略不存在的 CPU；H 段（3 个以上 CPU）：`{1,2}` 被原样报告回来，迁移后任务只在 CPU 1、2 上运行，`fork` 的子进程继承这个掩码 |
| hello244 | 更大的 `/tmp`（tmpfs 从 63 个条目扩到 511 个）：先测剩余条目数、创建 300 个内容各不相同的文件（超过一个字节能编号的范围）并逐个读回、20 个目录各带一个文件、中间 `unlink` 后槽位可复用且邻居不受影响、把表填满后得到 `ENOSPC`（不崩溃、已有文件完好）、全部删除后剩余条目数回到起点 |
| hello245 | `sched_setaffinity` 钉住后任务应立刻在目标 CPU 上（8 核，轮流钉到各个 CPU 共 200 次，用 `getcpu` 检查）；输出每次运行的“立刻/稍后/始终没迁”计数；**判定有界而不是零**：最多允许 8 次未立刻迁移（旧内核最坏一次 30 次），因为钉住后偶尔仍会留在原 CPU（已知限制，见计划文档） |
| hello246 | FAT32 根目录文件（裸文件名）的槽位和多描述符一致性（15 项）：测剩余槽数（57）、创建/写/关闭/`unlink` 后槽位归还、`stat` 不占槽、同一文件打开两次；第二个描述符立刻看到第一个的写入（`fstat`/`SEEK_END`/`read`）且互相可见；`unlink` 后每个已打开的描述符仍能读写，最后一次 `close` 才归还槽位；`dup`、`fork`（子进程关闭它的描述符不影响父进程）|
| hello248 | 通过另一个描述符截短/扩展/`truncate(path)` 后，已打开的描述符看到的文件大小（9 项：tmpfs、FAT32、ext2 各 3 项）：`ftruncate` 到 5 后另一个描述符的 `fstat`/`SEEK_END`/`read` 都是 5；再扩到 12 读 12 字节且新增部分为 0；`truncate(path, 3)` 后新打开的描述符 `fstat` 3、读 3 字节 |
| hello249 | 文件映射与另一个描述符的截短（tmpfs、FAT32、ext2 各 6 项）：8192 字节文件映射两页后截到 100，从未触碰的第二页读取是 SIGBUS（子进程退出信号 7）；含新末尾的第一页仍可读且末尾之后的字节为 0；扩回 8192 后第二页读为 0；扩展范围用 `pread` 读为 0；第一个描述符在截短后写入，第二个读得到；从未见过这次截短的描述符写入不会破坏已分配给另一个文件的块 |
| hello250 | 打开的目录流看得到其它路径对目录的修改（tmpfs、ext2 各 8 项）：空目录列出 `.` 和 `..`；创建一批文件后同一个流（`rewinddir` 后）列出全部；按名字逐个打开都成功；删除一半后列出剩下的；全部删除后只剩点目录项；清空后的目录可以 `rmdir`，同名可以重新 `mkdir`；删除后空闲块数回到创建前的值（用 `statfs` 读，抓目录块泄漏）。ext2 夹具只有 128 个 inode，所以能建的文件数不固定（实测 44），判定相对于实际创建数 |
| hello251 | `statfs`/`fstatfs` 按文件系统报告各自的数字（tmpfs、FAT32、ext2；每个 7–9 项）：类型码（tmpfs 0x01021994、FAT 0x4d44、ext2 0xEF53）、块大小/块数/空闲/可用、`f_namelen`（tmpfs 为 60，其余 255）、ext2 保留给 root 的块不计入可用、inode 总数与空闲数、`fstatfs` 与 `statfs` 一致、写 40960 字节后空闲块数按各文件系统的块大小下降（tmpfs 10 块、ext2 41 块含一个间接块、FAT32 79–80 簇）、不存在的路径 `ENOENT`、`<文件>/x` 为 `ENOTDIR`；`/proc` 文件报 `PROC_SUPER_MAGIC`（0x9fa0）且块数和 inode 数为 0，`/dev` 节点报 `TMPFS_MAGIC`（devtmpfs）而不是 ext2；管道报 pipefs（0x50495045）、套接字报 sockfs（0x534f434b）、epoll 报 anon_inode（0x09041934），都没有块和 inode |
| hello252 | 目录增长超过 12 个块（tmpfs、ext2 各 5 项）：56 个条目（ext2 用 240 字节名字，约 14 KiB 目录记录，超过 1 KiB 块下 inode 的 12 个直接块；因夹具只有 128 个 inode，ext2 条目是指向同一个文件的硬链接）全部创建、列出（加点目录项共 59）、按名字打开、删除，清空后目录可 `rmdir`，`statfs` 空闲块数回到创建前（抓间接块泄漏）。名字用 `chdir` 进目录后的相对名，因为路径上限 255 字节 |
| hello253 | `/proc/self` 指调用者自己：`/proc/self/status` 能打开且其 `Pid` 行等于 `getpid()`、与按数字 pid 打开的同一文件一致；`/proc/self/cmdline` 能打开；`/proc/self` 下的未知文件、`/proc/selfx/status`、`/proc` 下的未知名字都返回 `-ENOENT`（原来返回 `-1`，即 `EPERM`）；`fork` 出的子进程里 `/proc/self` 是子进程自己，不是父进程；以 root 启动的探针里降到 uid 1000 的子进程读不了父进程的 `/proc/<pid>/maps`（`EACCES`），但能读它的 `status` 和自己的 `maps`（共 8 项） |
| hello254 | `/proc` 作为目录（12 项）：`stat("/proc")` 和 `stat("/proc/<pid>")`、`stat("/proc/self")` 是目录，`stat("/proc/meminfo")` 是普通文件；`opendir("/proc")` 列出 `.`、`..`、各个文件（`DT_REG`）、`self`（`DT_LNK`）和每个存活进程的数字目录（`DT_DIR`，线程不单独列出）；`opendir("/proc/<pid>")` 列出 `status` 等；`opendir("/proc/meminfo")` 为 `ENOTDIR`；已回收进程没有 `/proc/<pid>`；`statfs("/proc")` 为 `PROC_SUPER_MAGIC` |
| hello255 | 根目录列表（8 项）：`opendir("/")` 列出 `.`、`..`、ext2 的条目（含 `testdir`）以及 `tmp`、`dev`、`proc`（各一次，`DT_DIR`）和 FAT32 卷根目录里的文件（裸文件名创建的文件，`DT_REG`，`unlink` 后消失）；`rewinddir` 后第二遍列表与第一遍相同；从 `/` 出发的 `opendir(".")` 与 `/` 相同；`stat("/")` 是目录 |
| hello256 | TCP 连接拆除（8 项，状态号取自 `TCP_INFO`，Linux 编号）：对端先关闭后本端是 `CLOSE_WAIT`（8）且读得 0；`CLOSE_WAIT` 的套接字仍占着端口（`bind` 为 `EADDRINUSE`），本端也关闭后端口释放；客户端 `SHUT_WR` 后客户端 `FIN_WAIT2`（5）、服务端 `CLOSE_WAIT`，半关闭的客户端仍能收到服务端发来的数据，`SHUT_WR` 之后写为 `EPIPE`（探针忽略 `SIGPIPE`，否则像 Linux 一样以状态 141 被杀）；服务端也 `SHUT_WR` 后两端读都是 0，客户端离开 `FIN_WAIT2`、服务端离开 `CLOSE_WAIT` |
| hello257 | `/proc/self/fd`（15 项）：`readlink("/proc/self/fd/N")` 对 tmpfs 文件给 `/tmp/...`，对用相对名打开的 ext2 文件给绝对路径，管道给 `pipe:[n]`（两个管道编号不同、同一管道的两端相同），套接字给 `socket:[n]`，epoll 给 `anon_inode:[eventpoll]`；不是打开描述符的数字、字母、负号和超大数字都是 `ENOENT`（原来是 `EINVAL`；hello86 的期望随之改为 `ENOENT`），关闭后消失；`opendir("/proc/self/fd")` 列出 `.`、`..` 和每个打开描述符的编号；`open("/proc/self/fd/N")` 重新打开同一个文件（新的打开文件描述，自己的偏移，原描述符偏移不变），`stat("/proc/self/fd/N")` 描述该文件，不是描述符的数字 `ENOENT`；`lstat("/proc/self/fd/N")` 描述链接本身（符号链接，模式 0700，大小 64，Linux 对所有这类链接都报 64），不是描述符的数字失败 |
| hello258 | 进程名（comm，17 项）：程序启动时名字是文件名（不是 argv[0]）；`prctl(PR_SET_NAME)` 最多存 15 字节并把其余补零（较短的名字不留旧名字的尾巴），空名字允许，坏指针 `EFAULT` 且名字不变；`PR_GET_NAME` 坏指针 `EFAULT`；`/proc/self/comm` 是名字加换行，`/proc/self/status` 以 `Name:\t<名字>` 开头，`/proc/self/stat` 第二个字段是 `(<名字>)`，`/proc/self` 目录列出 `comm`；`fork` 和新线程继承名字，子进程自己的改名不影响父进程，父进程能从 `/proc/<pid>/comm` 读到子进程的名字；`execve` 把名字重置为新程序的文件名（不是 argv[0]，也不是旧名字） |
| hello259 | `/proc/<pid>/status`（28 项）：`Name`、`Tgid`/`Pid`/`PPid`（等于 `getpid()`/`getpid()`/`getppid()`）、`Ngid` 和 `TracerPid` 为 0、`Umask`（四位八进制，随 `umask()` 变化）、`Uid`/`Gid`（真实、有效、保存、文件系统四个数，制表符分隔）、`FDSize` 覆盖最大打开描述符、`NoNewPrivs`（`prctl` 设置后为 1，只影响子进程自己）、`Groups`（`setgroups(5,7,9)` 之后是 `5 7 9 `，每个组后跟一个空格）、`Threads`（1；有另一个线程时 2；线程退出并 join 后回到 1）、线程自己的 status（`Pid` 是线程 tid，`Tgid` 和 `PPid` 是进程的）；`State`：阻塞在 read 的进程是 `S (sleeping)`，`SIGSTOP` 后 `T (stopped)`，`SIGCONT` 后回到 `S`，退出未被等待的是 `Z (zombie)`；睡眠中的进程被停止再继续后，仍睡满 600 ms（`nanosleep` 返回 0），并且继续后不会被第二次停止；一个不断计算的进程被 `SIGSTOP` 后也显示 `T`、停止期间没有进展、`SIGCONT` 后继续 |
| hello260 | `capget`/`capset` 遵循 Linux ABI（29 项）：能力用 Linux 编号（CAP_SETGID 6、CAP_SETUID 7），V3/V2 返回两组、V1 只写一组并保留高位字；未知版本 `EINVAL` 且头部回写 V3，数据指针为 NULL 时的探测返回 0；负 pid `EINVAL`、不存在的 pid `ESRCH`、NULL 头部 `EFAULT`；`capset` 对别的进程（含 -1）`EPERM`、要没有持有的能力（包括高位字）`EPERM`、没有数据指针 `EFAULT`；丢弃 CAP_SETGID 后不能再要回；`/proc/self/status` 的 `CapInh`/`CapPrm`/`CapEff`/`CapBnd`/`CapAmb` 各 16 位十六进制并随 `capset` 变化 |
| hello261 | 停止信号对睡眠进程、致命或有 handler 的信号对已停止进程（8 项）：带 handler 的 `SIGTSTP` 运行 handler 且 `read` 得 `-EINTR`、进程不停止；被屏蔽或忽略的 `SIGTSTP` 让睡眠者继续睡；`SIGTERM` 发给已停止的进程后它仍是 `T`，`SIGCONT` 之后才以信号 15 死亡；带 handler 的 `SIGTERM` 在 `SIGCONT` 之后才运行 handler；`SIGKILL` 立刻结束已停止的进程 |
| hello262 | 发给整个进程组的信号 `kill(-pgid, sig)`（6 项）：两个睡眠成员同组；`SIGSTOP` 停止全员；`SIGTERM` 发给已停止的组后全员仍是 `T`，`SIGCONT` 之后以信号 15 死亡；`SIGKILL` 立刻结束已停止的组（信号 9）；默认 `SIGTSTP` 停止睡眠中的成员；忽略且阻塞的 `SIGTSTP` 经 `kill(-pgid)` 仍排队（`sigpending` 可见），未阻塞则丢弃 |
| hello263 | `kill(0, sig)` 与 `kill(-1, sig)`（10 项）：`kill(0)` 发给调用者所在进程组全员包括调用者自己、不碰其它组；`kill(0, 0)` 为 0；信号号 130 `EINVAL`；不存在的组或 pid `ESRCH`；`kill(-1)` 发给所有其它可发送的进程、不含调用者 |
| hello264 | `/proc/<pid>/status` 的 `VmSize`/`VmRSS`/`VmData`（11 项）：两行存在且 `VmRSS` 不超过 `VmSize`；`mmap` 1 MiB 使 `VmSize` +1024 kB；逐页触碰后 `VmRSS` 比 `mmap` 前多 1024 kB 而 `VmSize` 不变；`munmap` 两者各 -1024 kB 且 `VmRSS` 回到起点附近；`sbrk` 1 MiB 使 `VmSize` +1024 kB；`/proc/<pid>/status` 与 `/proc/self/status` 一致；`VmData` 只计堆和可写私有映射（私有只读、共享映射不计，`sbrk` +1024 kB，`munmap` 可写私有映射 -1024 kB；`mprotect` 后 `VmData` 是否变化**没有**断言，本内核的数据账本不跟随 `mprotect`）。本内核在 `mmap` 时就填充匿名页，所以 `VmRSS` 在 `mmap` 瞬间就上升（Linux 是惰性的），用例打印这一差异而不断言它 |
| hello265 | `mprotect` 与 RLIMIT_DATA 账本（20 项，经 `VmData` 观察）：可写→只读退还页数、改回可写再计入；把中间四分之一改只读退 256 kB；`PROT_NONE` 不是数据（退还可写的四分之三）；再全部可写计入整兆；`munmap` 按碎片**现在**的状态退款，净值为 0；只读→读+执行不变、加写计入；部分可写的区域只补另一半；共享映射永远不计；`RLIMIT_DATA` 下只读→可写若超限则 `ENOMEM`（`errno` 12）且账本不变，先在别处放弃可写后就有余量；`mprotect` 变成只读的区域上 `MAP_FIXED` 读写覆盖仍然成功并计入；一百次第一页 `mprotect` 往返不会耗尽区域表（相邻同保护位的区域会合并回去）；四十个同时存活的映射各做一次往返仍能放下；跨保护边界的 `mremap` 缩小成功，之后账本只剩留下的数据页（-8 kB）；横跨两个映射的放大是 `EFAULT`、缩到 4 页中的 3 页原地成功、同样大小的 `MREMAP_FIXED` 移动成功且数据带过去、各部分保留各自的保护位（搬走后账本 -12 kB）；四十个先拆分又合回的映射移走后全部存活仍放得进区域表。`MAP_FIXED` 只读覆盖读写区域被快路径拒绝是既有限制（hello65），不在此断言 |
| hello266 | 同时追加写入同一文件（`O_APPEND`，每个文件系统 2 项，共 6 项：tmpfs、FAT32 根目录、ext2 `testdir/`）：四个子进程各向文件追加 50 行 2 字节，一次 `write` 一行，20 轮，文件恰好是 400 字节、每行完整（宿主机 Linux 0 轮出错）；同样但每行两次 `write`（`x` 再 `\n`），也不丢字节（宿主机 0 轮出错） |
| hello267 | `SO_REUSEPORT` 监听者关闭时迁移积压连接：两个 TCP 监听者共享一个端口，4 个客户端连接，关闭其中一个，另一个必须 `accept` 到全部 4 个 |
| hello268 | `O_APPEND` 描述符上的 `pwrite`/`pwritev`：数据落在文件末尾（忽略传入的偏移，与宿主机 Linux 一致），返回字节数；四个进程在偏移 0 上并发 `pwrite`/`pwritev` 同一个追加文件，每条记录完整落在末尾；`copy_file_range` 目的是 `O_APPEND` 返回 `EBADF`，`splice` 到 `O_APPEND` 文件返回 `EINVAL`（三个文件系统各一遍） |
| hello269 | 已结束的连接不会耗尽 TCB 表：一个本机监听者，100 轮 `connect`/`accept`/双向 `close`（每轮留下一个 15 秒的 TIME_WAIT），`socket()` 与 `connect` 始终成功，且没有任何一轮卡住几秒（表满时等 TIME_WAIT 到期） |
| hello270 | `O_APPEND` 锁按文件分片：四个进程各向自己的文件写 200 次 4 KiB，普通写与 `O_APPEND` 写各一遍（tmpfs、FAT32、ext2），`O_APPEND` 的耗时不超过普通写的 3 倍加 300 毫秒（改成按文件分片之前慢 15 到 58 倍）；tmpfs 一行只是测量 |
| hello271 | `fork` 之后子进程继承父进程在 `fork` 之前打开的描述符：管道和普通文件，子进程的写分别到达父进程和文件（回归保护；`pipe2` 写回两个 32 位整数） |
| hello272 | 40 个同时打开的本机 TCP 连接（80 个 TCB，超过旧的 64 槽表）：全部被接受、同时保持打开、每条都能传一个字节；客户端在子进程里，让每个进程都远低于描述符上限 |
| hello273 | 一个进程超过 64 个描述符：`RLIMIT_NOFILE` 软上限不小于 100，同时打开 50 个管道共 100 个描述符（旧的管道池只有 16 个），每个管道都能传一个字节，`/proc/self/status` 的 `FDSize` 覆盖最高描述符，`dup2` 到 120 成功 |
| hello274 | 实时信号排队：同一个实时信号 `rt_sigqueueinfo` 三次就是三次投递，按发送顺序、各带自己的值；`SIGUSR1` 发三次仍只投递一次；`kill`/`tkill` 的实时信号也排队；多个待处理时编号小的先出、同一信号先进先出；解除屏蔽后处理函数在 `sigprocmask` 返回前运行四次；装 `SIG_IGN` 丢弃所有排队的实例 |
| hello275 | 曾经让写回池失效的两种 FAT32 写入：`unlink` 之后仍打开的文件的写入（并在 `fsync` 后按 `unlink` 前的内容读回）、`ftruncate` 加长后在旧末尾之外写入（空洞读回 0）；随后各向一个新建的 FAT32 和 ext2 文件写 4 MiB（超过整个 512 块的写回池），两者都必须完整 |
| hello276 | 打开期间被 `unlink` 的 tmpfs 条目的 `/proc/self/fd/N`：`readlink` 返回原路径加 `" (deleted)"`（文件和目录都是），经该链接 `open` 仍能读到数据且从偏移 0 开始、不影响原描述符的偏移，`stat` 成功；仍有名字的条目不带后缀 |
| hello277 | 经 `/proc/self/fd/N` 打开时按本次传入的标志和对象类型处理（文件和已 `unlink` 的 tmpfs 条目都一样）：`O_CREAT\|O_EXCL` 得 `EEXIST`，`O_TRUNC` 截断，文件上的 `O_DIRECTORY` 得 `ENOTDIR`，目录的 `O_RDWR` 得 `EISDIR`；访问模式按新标志并重新核对权限（非 root 对 0444 文件请求写得 `EACCES`，`unlink` 后仍然）；管道任一端按访问模式重开为对应的一端，eventfd/epoll 得 `EACCES`、套接字得 `ENXIO`；经链接对管道、套接字 `stat` 成功 |
| hello278 | ext2 文件的 `/proc/self/fd/N` 跟随改名和删除：文件或父目录被 `rename` 后链接给出新路径（在非根工作目录下按相对名打开、改名、删除也一样）；打开时用的名字被 `unlink` 后给出 `"<路径> (deleted)"`（即使还有别的硬链接），经链接仍能重开并读到数据，重开得到的描述符同样是 deleted；未改动的文件和幸存的硬链接给出普通路径 |
| hello279 | 打开期间被删掉名字的 ext2 对象：被 `rmdir` 的目录经 `/proc/self/fd/N` 读出 `"<路径> (deleted)"`，`fstat` 的 nlink 为 0，`getdents64` 和 `openat(O_CREAT)` 得 `ENOENT`（同名新目录出现后也一样，不会建到新目录里），仍能经链接重开；被 `rename` 覆盖的文件和空目录同样是 ` (deleted)`，被覆盖的文件仍能读到数据 |
| hello280 | 打开期间被 `unlink` 的 FAT32 文件：`/proc/self/fd/N` 读出 `"/<名字> (deleted)"`，经链接 `O_CREAT\|O_EXCL` 得 `EEXIST`，重开从偏移 0 读到数据，新描述符同样是 deleted，并在原描述符关闭后仍能读；最后一次关闭后名字仍不存在 |
| hello281 | 目录的粘滞位（ext2 与 tmpfs）：uid 1000 对 root 在 `1777` 目录里的文件和目录做 `rename` 移走、`unlink`、`rmdir`、`rename` 覆盖都得 `EPERM`，root 的文件仍在；自己的文件可删；`0777` 无粘滞位的目录里同样操作都成功 |
| hello282 | 跨进程 `process_vm_readv/writev`：父进程读到子进程的数据；写进子进程的 COW 页（栈、`mmap` 匿名页、数据段）只改子进程的副本；不存在的 pid 与已回收的子进程是 `ESRCH`；flags 非零是 `EINVAL`；零长度读取对不存在的 pid 也返回 0；降为 uid 1000 的子进程读 root 进程是 `EPERM`；子进程从没碰过的文件页（tmpfs、ext2）：读到文件内容，写 MAP_PRIVATE 页只给子进程私有副本，写 MAP_SHARED 页写进文件，EOF 之后的页是 `EFAULT` |
| hello283 | 孤儿进程组（Linux `kill_orphaned_pgrp`）：退出使一个含停止成员的组新成为孤儿时，组内成员先收 SIGHUP 再收 SIGCONT；检查退出者自己的组和每个子进程所在的组；组内无停止成员、组仍被同会话他组的父进程链接、或停止的子进程留在退出会话长自己的组里时，什么都不发（宿主机 Linux 实测同结果） |
| hello284 | `waitpid` 报告停止与继续的子进程：`WUNTRACED` 把 SIGSTOP 停止报告为 `0x137f`（每次停止只报告一次，不带该选项不报告），`WCONTINUED` 把 SIGCONT 继续报告为 `0xffff`；阻塞的 `WUNTRACED` 等待在子进程停止时返回；父进程在停止和继续时各收一次 SIGCHLD，SIGCHLD 动作带 `SA_NOCLDSTOP` 时不收，但停止照样报告（宿主机 Linux 实测同结果） |
| hello285 | `waitid`（系统调用 500）：成功返回 0，子进程身份和状态写进调用方的 siginfo（`CLD_EXITED`/`CLD_KILLED`/`CLD_STOPPED`/`CLD_CONTINUED`，`si_status` 是退出码、致死信号、停止信号或 SIGCONT）；`WNOWAIT` 报告但不回收，同一僵尸或停止可再报告；`WNOHANG` 没有可报告的变化时返回 0 并清掉 siginfo；第五个参数 rusage 只在报告了子进程时填写，utime/stime 是子进程的 CPU 时间，`WNOHANG` 无变化时原样不动，不可写是 `EFAULT`；`idtype`/`options`/`id` 非法是 `EINVAL`，没有这样的子进程是 `ECHILD`；空的 infop 也照样回收（宿主机原始 syscall 实测同结果）；只写 siginfo 的六个字段，缓冲区其余字节保持调用者原来的内容（F） |
| hello286 | `kill(pid, SIGSTOP)` 停止子进程的每一个线程，父进程只在整组都停下后看到一次 `0x137f`；停止期间旋转的线程不再写管道；`SIGCONT` 让它重新跑起来并只报告一次 `0xffff`；`SIGKILL` 之后没有任何线程继续运行；几乎总在 `write()` 里的子进程（D）和 `kill(getpid(), SIGSTOP)` 自停的子进程（E：父进程等待；F：父进程在睡眠）在 `SIGCONT` 之前不再运行任何用户代码；旋转线程用 `sched_setaffinity` 绑在 CPU 0 上时同样如此（G，重复四轮）；对单个线程 `tkill` 的 `SIGSTOP`/`SIGCONT`/`SIGKILL` 作用于整个进程，`tkill(组长, SIGCONT)` 也恢复其他线程（H）；`sigsuspend` 解除阻塞一个已待处理的默认 `SIGTSTP` 时停下任务，`SIGCONT` 后继续停在 `sigsuspend` 里（I）；线程不断创建并退出的同时，60 轮整组停止和继续都被报告，停止期间没有写入（J）；三线程进程的 `SIGCONT` handler 每次继续只运行一次，`kill` 报告 `SI_USER`，`tkill(组长)` 报告 `SI_TKILL`（K）；一个线程阻塞在 `read()` 时 200 轮 `SIGSTOP` 都报告 `0x137f`，停止期间没有写入，`SIGCONT` 后回到 `read()`（L）；`fork` 之后立刻 `SIGSTOP`，子进程随后创建的线程也被停住，停止期间不写（M）（宿主机 Linux 实测同结果） |
| hello287 | `exit_group`（原生 501）结束进程的每一个线程：主线程 `exit_group(42)` 报告为 `0x2a00`，之后旋转的线程不再写管道；只保留状态的低 8 位（300 报告为 44）；非主线程调用时主线程也随之结束，报告的是它给的状态；主线程 `exit(5)` 同样结束其他线程（libc 的 `_exit` 走 `exit_group`）；`pthread_exit` 只结束自己的线程；连续 40 个进程（宿主机 Linux 实测同结果）；主线程 `SYS_exit` 后另一个线程还在跑时，进程要等最后一个线程退出才被报告，状态是那个线程的（G/H） |
| hello288 | `rt_tgsigqueueinfo`（226）按线程投递：发给另一个线程时 handler 在那个线程里运行，带调用者的 value 和 `SI_QUEUE`；发给自己时在自己线程里运行；tgid 不对或 tid 不属于 tgid 是 `ESRCH`；tid/tgid 为 0 或负数是 `EINVAL`；信号号 65 是 `EINVAL`；sig 0 只探测；坏 siginfo 指针是 `EFAULT`；`rt_sigqueueinfo`（222）只允许向调用者自己的 tid 伪造 `SI_USER`（非主线程发给 `getpid()` 是 `EPERM`），不存在的 pid 配信号 65 是 `ESRCH`（F）；两个调用对子进程第二个线程发 `SIGSTOP`/`SIGCONT` 都停下、继续整个子进程，报告 `0x137f`/`0xffff`（G/H）；主线程阻塞 `SIGUSR1` 时，`kill(getpid())` 和 `rt_sigqueueinfo(getpid())` 的 handler 在另一个线程里运行，主线程上没有留下待处理信号（I）；两个线程都阻塞时 `kill(getpid())` 等着，先解除阻塞的那个线程运行 handler（J）；另一个线程的 `sigpending` 看得到这个信号，它的 `sigtimedwait` 取走信号和值，`tkill` 发给主线程的信号另一个线程看不到（K）；被点名的线程退出后信号仍在，主线程解除阻塞后 handler 在主线程里运行，值还在（L）；`SIG_IGN` 把 held 的进程级信号从所有线程上丢掉，`tkill` 给兄弟线程的另一个信号保留（M）；都阻塞的实时信号发两次，先解除阻塞的线程按顺序运行两个实例（N）；忽略且未阻塞的信号在发送时丢弃，`sigtimedwait` 超时，阻塞时则能取到（O）；POSIX 定时器过期和 `mq_notify` 的信号同样如此（P）；`RLIMIT_SIGPENDING` 限制该 uid 已排队的实时信号实例，超出后 `rt_sigqueueinfo` 是 `EAGAIN`，`kill` 仍置待处理位（Q）；20 个 15 ms 的一次性定时器没有一个提前到期或丢失，刚设好 1.234567891 s 的定时器 `timer_gettime` 报告的剩余时间不超过设定值、精确到纳秒（R）（宿主机 Linux 实测同结果） |
| hello289 | Linux personality（`personality(1)`）下 231 号是 `exit_group`：子进程调用 `231(300)` 后整个进程结束，报告 `0x2c00`，另一个线程之后不再写管道；247 号是 `waitid`，报告孙进程为 `CLD_EXITED`、`si_status` 7。原生 personality 下 231 仍是 `move_pages`（status-only 形状返回 0）、247 仍是 `clock_nanosleep`（20 ms 睡眠返回 0）（C/D 宿主机 Linux 实测同结果） |
| hello290 | 阻塞的 `flock(LOCK_EX)` 和 `fcntl(F_SETLKW)` 在持有者解锁后返回 0，等待期间几乎不消耗 CPU；`flock` 在持有者退出时释放，`fcntl` 锁在持有者关闭描述符或被 `SIGKILL` 时释放；两个不同的 `/tmp` 文件的锁互不影响（宿主机 Linux 实测同结果） |
| hello291 | `timerfd_gettime` 和 `timerfd_settime` 的旧值按纳秒报告剩余时间，不超过设定值（A）；20 个 15 ms 的一次性 timerfd 没有一个让阻塞的 `read()` 提前返回（B）；`TFD_TIMER_ABSTIME` 的 `CLOCK_MONOTONIC` 截止时间不会提前到（C）；20 ms 的周期 timerfd 在 210 ms 内计满 10 次到期（D）（宿主机 Linux 实测同结果） |
| hello292 | POSIX 定时器的信号带 `SI_TIMER`、定时器 id、`si_overrun` 0 和创建时的 `sigev_value`，`timer_getoverrun` 为 0（A）；20 ms 的周期定时器在信号阻塞 210 ms 期间只排一个信号，其 `si_overrun` 计入其余到期（7～11），`timer_getoverrun` 与之相同，之后不再有第二个信号（B）；`sigevent` 为空时发 `SIGALRM`，`si_value` 是定时器 id（C）；信号被忽略 100 ms 的周期定时器在恢复默认处理后仍会投递，忽略期间的到期计入 overrun（D）（宿主机 Linux 实测同结果） |
| hello293 | `mq_notify` 的信号是 `SI_MESGQ`，带发送者的 pid 和 uid、以及注册时的 `sigev_value`（A）；不再注册就再发一条消息没有信号（B）；队列非空时重新注册本身不发信号，排空后再有消息到达空队列才再次投递（C）（宿主机 Linux 实测同结果） |
| hello294 | `mq_notify(SIGEV_NONE)` 注册成功、占住注册位（再注册是 `EBUSY`）、消息到达不发信号并消耗注册（A）；`SIGEV_SIGNAL` 信号 0 同样注册、不发信号、被消耗（B）；别的进程 `mq_notify(NULL)` 返回 0 且替换是 `EBUSY`，原注册仍投递（C）；同一进程用另一个描述符能注销（D）；关闭做出注册的描述符会移除注册（E）（宿主机 Linux 实测同结果） |
| hello295 | `timer_create(SIGEV_SIGNAL\|SIGEV_THREAD_ID)` 只接受本进程的活线程和 1..64 的信号号，别的进程的 tid、不存在的 tid、信号 0 都是 `EINVAL`（A）；到期信号只排给被点名的线程：它的 `sigpending` 是 0x200，主线程的是 0（B）；点名调用者时 `sigtimedwait` 取到 `SI_TIMER` 和 `sigev_value`（C）（宿主机 Linux 实测同结果） |
| hello296 | `timer_create`/`timerfd_create` 接受 `CLOCK_BOOTTIME`：相对 30 ms 到期带 `SI_TIMER` 和 `sigev_value`（B），绝对截止时间按 boot time 计算，已过去的立即到期（C），20 ms 周期 timerfd 在 210 ms 内计约 10 次（D）；`CLOCK_MONOTONIC_RAW` 对 `timer_create` 是 `EOPNOTSUPP`、对 `timerfd_create` 是 `EINVAL`（A）（宿主机 Linux 实测同结果） |
| hello297 | `splice` 等空管道时对信号的反应：没有 `SA_RESTART` 的处理函数让 pipe→文件的 splice 返回 `EINTR`（A），有 `SA_RESTART` 时重新执行并返回之后写入的 3 字节（B），`SIGSTOP` 让阻塞的进程停下（`0x137f`），`SIGCONT` 后继续并拿到数据（C），`SIGKILL` 杀死它（D）；pipe→pipe 的 splice 在源管道空时等待、被处理函数以 `EINTR` 结束（E），`SPLICE_F_NONBLOCK` 是 `EAGAIN`（F），数据到达后返回 4 字节（G），写端全关返回 0（H）。文件端在目标机上是 ext2 的 `testdir/h297`（宿主机 Linux 实测同结果） |
| hello298 | tmpfs 文件可以做 `splice` 和 `sendfile` 的文件端：文件→管道搬 4 字节并推进文件偏移（A），显式偏移只改偏移变量（B），管道→文件写在文件偏移处（C）或显式偏移处（D），`sendfile` 从 tmpfs 文件到管道（E），另一个描述符追加的字节也能 splice 出来（F），在末尾和越过末尾返回 0（G）（宿主机 Linux 实测同结果） |
| hello299 | `splice` 和 `sendfile` 读 ext2（`testdir/h299e`）和 FAT32（`h299f`）文件时能看到另一个描述符刚写入、还在写回缓存里的字节：先打开的描述符 splice 出新写的 11 字节（A），`sendfile` 从偏移 6 发出 "world"（B），中间被覆盖的字节按新内容读出（C），在新末尾返回 0（D）（宿主机 Linux 实测同结果） |
| hello300 | 阻塞在 eventfd 读、timerfd 读、`mq_receive`、`epoll_wait`、AF_UNIX `recv`、`nanosleep` 里的进程收到 `SIGSTOP` 立即停下（`0x137f`），停止期间不运行，`SIGCONT`（`0xffff`）后等待继续并在事件到达时完成，每种 30 轮；另有 200 轮在事件之后隔一段可变时间发 `SIGSTOP`，停止信号落在子进程回到等待途中也必须停下（宿主机 Linux 实测同结果） |
| hello301 | 阻塞在 TCP `recv` 或 SysV `semop` 里的进程收到 `SIGSTOP` 立即停下（`0x137f`），停止期间不运行，`SIGCONT`（`0xffff`）后等待继续并在事件到达时完成，每种 30 轮；另有 200 轮在事件之后隔一段可变时间发 `SIGSTOP`，落在子进程回到等待途中也必须停下（宿主机 Linux 实测同结果） |
| hello302 | 阻塞在 400 ms 的 `nanosleep` 里的进程收到 `SIGSTOP` 后 200 ms 内就报 `0x137f`（实测最慢 1～7 ms），停止期间不运行，`SIGCONT`（`0xffff`）后睡眠继续并完成；8 轮加上 40 轮在睡眠结束后隔一段可变时间发 `SIGSTOP`（宿主机 Linux 实测同结果，目标机在未修改的内核上同样通过，是回归测试） |
| hello304 | 写进满管道的进程被杀后释放它的写端：`write()`（A）、文件→管道 `splice`（B）、`sendfile`（E）都停住（Linux 在满管道上阻塞，不是返回 0），`SIGKILL` 与 `SIGTERM` 都让管道随后读到 EOF；file→pipe 的 `splice` 在满管道上等待，读端 drain 后返回全部 16 字节（G）；连杀十次后仍能新建 32 个管道（C） |
| hello305 | 阻塞读 `/dev/mouse`：`O_NONBLOCK` 且没有事件时是 `EAGAIN`（A）；不带 `O_NONBLOCK` 的读在没有鼠标移动时 300 ms 后仍在等，等待期间几乎不占 CPU（B）；没有 `SA_RESTART` 的 `SIGUSR1` 让它在处理函数运行后返回 `EINTR`（C）；`SIGKILL` 立即结束它（D）；`SIGSTOP` 让它停下、`SIGCONT` 继续（E）。规则按 Linux `/dev/input/mice` |
| hello306 | `process_vm_readv`/`process_vm_writev` 访问另一个进程 4 MiB 匿名映射里的 2 MiB 巨页块（映射在 fork 之后建立，避免 fork 拆页）：读到分叉后写入的标记（A），跨 2 MiB 边界的 8 KiB 整块读出（B），写入的标记子进程能看到（C）（宿主机 Linux 实测同结果） |
| hello307 | `CLOCK_TAI`（11）：`clock_gettime` 等于 REALTIME 加 TAI 偏移（本内核没有 `adjtimex`，偏移是 0；宿主机是 37 秒）（A），`clock_getres` 是 1 ns（B），`clock_nanosleep` 相对和 `TIMER_ABSTIME` 都按 20 ms 睡（C、D），`clock_settime` 是 `EINVAL`（E），`timer_create` 成功（F），`timerfd_create` 是 `EINVAL`（G）（宿主机 Linux 实测同结果） |
| hello308 | `CLOCK_PROCESS_CPUTIME_ID`/`CLOCK_THREAD_CPUTIME_ID` 上的 POSIX 定时器按 CPU 时间计：两种时钟都能建（A、E）；20 ms 的定时器在进程睡眠时不触发（C），进程用掉 20 ms CPU 后触发（D）；线程时钟只计本线程（F）；`timer_gettime` 报剩余的 CPU 时间，睡眠时不减少（G）（宿主机 Linux 实测同结果） |
| hello309 | `execve` 丢掉旧镜像留下的东西：exec 前武装的 100 ms POSIX 定时器不会把信号送进新镜像（A，新镜像 300 ms 内收不到），旧镜像的 `mq_notify` 注册也被移除，新镜像可以重新注册而不是 `EBUSY`（B）（宿主机 Linux 实测同结果） |
| hello310 | `flock` 属于打开文件描述、`fcntl` 锁属于进程，两类互不影响：别的进程打开再关闭同一文件不会释放别人的锁（A/B）；同一进程第二次 `open` 拿不到已持有的 `flock`，`dup` 出来的描述符共享它（C/D）；关闭该文件的任一描述符释放本进程的 `fcntl` 区间锁（E）；`flock` 与 `fcntl` 锁互不阻塞，`F_GETLK` 不报告 `flock`（F/G）；`fork` 子进程退出不带走共享的 `flock`（H）；`F_GETLK` 报告写锁/读锁类型和持有者 pid（I）；同一进程的第二段区间锁不覆盖第一段（J）；解锁中段会拆分区间（L）；两个新建的空 FAT32 文件各自加锁（K）（宿主机 Linux 实测同结果） |
| hello311 | `F_SETLKW` 在等待会构成锁属主环时返回 `EDEADLK`，而不是永远等下去：两个进程各持一个字节、交叉等待对方，后发起的那个立刻得到 `EDEADLK`，先等的那个在对方放弃后拿到锁（A）；等一个自己没在等待的持有者不算死锁，持有者解锁后返回 0（B）；经过三个进程的环也能发现（C）（宿主机 Linux 实测同结果） |
| hello312 | CPU 时钟（`CLOCK_PROCESS_CPUTIME_ID`、`CLOCK_THREAD_CPUTIME_ID`）上的 POSIX 定时器带 `TIMER_ABSTIME` 时，`it_value` 是 CPU 时钟的读数：截止时间在 20 ms CPU 之后时剩余不超过 20 ms，烧够后触发（A、B）；已过去的截止时间不再烧 CPU 也会触发（C）；10 s 之后的截止时间剩余 9～10 s，睡眠时不触发（D）；线程时钟同样（E、F）（宿主机 Linux 实测同结果） |
| hello313 | OFD 锁（`F_OFD_GETLK`/`F_OFD_SETLK`/`F_OFD_SETLKW`）属于打开文件描述：同一进程两次 `open` 互相冲突（A），和普通 `fcntl` 锁互相冲突（B），关闭别的描述符不释放（C），`dup` 共享、最后一次关闭释放（D），`GETLK` 报告 `l_pid` -1（E），`l_pid` 非 0 是 `EINVAL`（F），`F_OFD_SETLKW` 等到解锁（G），`fork` 的子进程共享且退出不释放（H），中段解锁保留两端（I）（宿主机 Linux 实测同结果） |
| hello314 | 3 个线程反复睡眠、唤醒时，主线程连续 1.5 秒读 `CLOCK_PROCESS_CPUTIME_ID` 和自己的 `CLOCK_THREAD_CPUTIME_ID`：进程时钟不倒退（A），线程时钟不倒退（B），进程时钟走得不比墙钟乘以线程数快（C）（宿主机 Linux 实测同结果） |
| hello315 | 一个线程烧 CPU 时在 `CLOCK_PROCESS_CPUTIME_ID` 上 `clock_nanosleep`：相对 50 ms 返回 0 且进程 CPU 时间走够（A），`TIMER_ABSTIME` 截止时间到达（B），已过去的截止时间立刻返回（C），没有线程烧 CPU 时 `SIGALRM` 让 10 s 的睡眠以 `EINTR` 结束并写回 `rem`（D），线程时钟上原始 syscall 是 `-EOPNOTSUPP`（E）（宿主机 Linux 实测同结果） |
| hello316 | 文件租约 `F_SETLEASE`(1024)/`F_GETLEASE`(1025)：读租约、升级为写租约、解除，没有租约时 `F_UNLCK` 为 `EAGAIN`（A）；已有写打开或其它打开时拿租约为 `EAGAIN`（B）；未知类型、pipe、目录为 `EINVAL`（C）；子进程的非阻塞写打开打破读租约，持有者收到一次 `SIGIO`（D）；阻塞写打开等持有者在 handler 里解除（E）；读打开把写租约降级（F）；`truncate` 打破读租约（G）；租约跟着打开文件描述走，dup 共享、最后一次关闭时删除（H）；持有者自己的非阻塞写打开为 `EAGAIN` 且返回时 handler 已运行（I）；同一进程两个租约只收到一次 `SIGIO`（J）；`ftruncate` 不打破调用者自己的写租约，子进程通过继承的 fd 也一样（K） |
| hello317 | `adjtimex`(502)/`clock_adjtime`(503)：只读调用返回时钟状态（开机 5、`STA_UNSYNC`），tick 10000、precision 1、tolerance 32768000、constant 2（A）；`ADJ_TAI` 37 后 TAI − REALTIME = 37 s（B）；`clock_nanosleep(CLOCK_TAI, TIMER_ABSTIME)` 按 TAI 截止（C）；越界的 TAI 偏移被忽略（D）；非特权子进程的修改为 `EPERM`、`0x8000` 为 `EINVAL`、读取可用（E）；`clock_adjtime` 各时钟的错误码和 NULL 为 `EFAULT`（F）；`adjtimex(NULL)` 为 `EFAULT`（G）；`ADJ_SETOFFSET` 让 REALTIME 前进再退回（H） |
| hello318 | `F_SETOWN`(8)/`F_GETOWN`(9)/`F_SETSIG`(10)/`F_GETSIG`(11)：默认 0（A）；`F_SETSIG` 接受 0..64，越界 `EINVAL` 不改原值，参数按 int 截断（B）；`F_SETOWN` 读回 pid 和 -pgrp，不存在的目标 `ESRCH`，`INT_MIN` `EINVAL`，0 清除（C）；属于打开文件描述，dup 和 fork 可见、另一次 open 不可见（D）；`F_SETLEASE` 无 owner 时设为调用者（E）；打破租约发出设置的信号，`si_code` `POLL_MSG`、`si_band` 0x441、`si_fd` 为租约 fd，sig 0 时发 `SIGIO`/`SI_KERNEL`（F–H）；`F_UNLCK` 清除 owner/sig（I）；owner 0 时不发信号但打开者仍 `EAGAIN`（J）；持租约期间改信号生效（K）；pipe 可设置、坏 fd `EBADF`（L） |
| hello319 | `F_SETLEASE` 要求是文件属主或持有 `CAP_LEASE`（以 uid 1000、只带 `CAP_LEASE` 启动）：自己建的文件可拿租约（A）；持 `CAP_LEASE` 时 root 的文件可拿（B）；`capget` 把 `CAP_LEASE` 报为第 28 位，`capset` 能放弃它（C）；放弃后 root 的文件 `F_RDLCK`/`F_WRLCK`/`F_UNLCK` 都是 `EACCES`，类型 7、-1 仍是 `EINVAL`（D）；`/dev/null`、eventfd 是 `EACCES`，管道、目录是 `EINVAL`（E）；自己的文件仍可拿（F） |
| hello320 | 管道上的 `O_ASYNC`：`F_SETFL O_ASYNC` 成功，`F_GETFL` 读回 0x2000/0x2001，没有 owner 不发信号（A）；sig 0 时每次写入发 `SIGIO`/`SI_KERNEL`（B）；`F_SETSIG 40` 时写入发 `POLL_IN`、band 0x41、读端 fd（C）；读出数据给写端发 `POLL_OUT`、band 0x304、写端 fd（D）；关闭写端给读端发 `POLL_IN`，读到 EOF 不发（E）；关闭读端给写端发 `POLL_OUT`，之后 `EPIPE` 不发（F）；清除后不发（G）；dup、fork 共享这一位（H）；子进程写入发给父进程（I）；-pgrp owner（J）；`/dev/null`、普通文件接受但不保留（K）；关闭两个描述符之一后照常发（L） |
| hello321 | `F_SETOWN_EX`/`F_GETOWN_EX`：新打开是 TID 0（A）；`F_SETOWN` 的 pid 读回 PID，-pgrp 读回 PGRP（B）；三种类型设置并读回（C）；坏类型 `EINVAL`（D）；不存在或负的 id `ESRCH`（E）；id 0 保留类型（F）；`EFAULT`/`EBADF`（G）；dup、fork 共享（H）；`F_SETLEASE` 设 PID owner、保留 TID owner（I）；O_ASYNC 管道的 TID owner 只由那个线程收到（J）；PID owner 收到进程定向信号，主线程屏蔽时转给其他线程（K） |
| hello322 | SIGIO 的发送权限（以 root、只带 `CAP_SETUID` 启动，子进程用 `setresuid` 换身份）：uid 1 设置的 owner 收不到（A）；设置者 uid 0、euid 0 时收到（B、C）；只有 suid 0 不算（D）；root 设置者能发给 uid 1（E）；目标 suid、uid 匹配时收到，只有 euid 匹配时收不到（F–H）；凭据在设置时记录（I）；`F_SETOWN_EX` 同样（J）；-pgrp owner 只发给允许的组员（K） |
| hello323 | AF_UNIX 套接字的 `O_ASYNC`：socketpair 读回 0x2002（A）；对端发送发 POLL_IN、sig 0 发 SIGIO（B、C）；自己读写不发（D）；写满 EAGAIN 后对端读空发一次 POLL_OUT（E）；对端 shutdown：RD 不发、WR 发 POLL_IN、RDWR 发 POLL_HUP（F）；对端 close 发 POLL_HUP，band 0x18（G）；数据报（H）；新连接通知监听套接字（I）；监听套接字关闭时队列里的客户端收到 POLL_HUP（J）；清除后不发（K）；子进程发送（L）；阻塞的流式读者不收、数据报读者收（M）；`O_NONBLOCK` 经 dup 的 `F_SETFL`/`FIONBIO` 设置后对原描述符生效（N）；`RWF_NOWAIT` 不改描述的标志（O） |
| hello324 | UDP 套接字的 `O_ASYNC`（127.0.0.1）：读回 0x2002、无 owner 不发（A）；sig 0 发 SIGIO（B）；每个数据报发 POLL_IN、band 0x41（C）；自己发送不发（D）；bind 前设置在 bind 后仍生效（E）；端口不可达发 POLL_ERR、band 0x8，recv 返回 ECONNREFUSED（F）；清除后不发（G）；dup、fork 共享（H）；关闭一个描述符照常发（I）；同端口的新套接字不收到（J） |
| hello325 | TCP 套接字的 `O_ASYNC`（127.0.0.1）：监听套接字读回 0x2002（A）；握手完成时监听套接字收到 POLL_IN、band 0x41，accept 出来的不带（B）；客户端收到 POLL_OUT、band 0x304（C）；每次数据到达发 POLL_IN（D）；自己读写不发（E）；清除后不发（F）；写满到 EAGAIN 后，ACK 或对端读空腾出空间时发 POLL_OUT（G）；对端 SHUT_WR 发 POLL_IN（H）；dup 共享（I）；复位发 POLL_ERR、band 0x8（J）；连接被拒绝发 POLL_ERR，阻塞 connect 返回 ECONNREFUSED（K） |
| hello326 | 控制台 `/dev/tty` 的 `O_ASYNC` 与 TIOCSTI：读回 0x2002（A）；开启时没有 owner 就设成调用者或前台组，已有的 owner 保留（B）；TIOCSTI 注入的每个字符发 POLL_IN、band 0x41（C、D）；自己读写不发（E）；sig 0 发 SIGIO（F）；清除后不发（G）；dup 共享（H）；再 open 一次是另一个描述（I）；TIOCSTI 在管道上返回 ENOTTY、NULL 返回 EFAULT、其他会话且无 CAP_SYS_ADMIN 返回 EPERM（J） |
| hello327 | owner 消失后的 F_GETOWN / F_GETOWN_EX：PID owner 被杀未回收时仍报 pid（A），回收后报 0、类型保留（B）；join 后的 TID owner 报 TID/0（C），再设这个 tid 返回 ESRCH（D）；PGRP owner 成员为 zombie 时报 -pgrp、回收后报 0（E）；组长回收而成员活着时仍报 -pgrp，全部回收后报 0（F） |
| hello328 | setfsuid / setfsgid（原生 504/505）：-1 只读回（A）；设成 1000/2000 返回旧值、status 第四栏显示（B）；fsuid 1000 打不开 root 的 0600 文件且 CapEff 去掉文件系统 capability（C）；新文件属主是 fs id（D）；access 按真实 id、AT_EACCESS 按 fs id（E）；chmod 按 fsuid 判属主（F）；setfsuid(0) 恢复（G）；setres[ug]id 全 -1 保留 fs id、给出 euid 时跟随（H）；无 CAP_SETUID 只能取现有 id（I）；fork 继承、execve 重置（J） |
| hello329 | `/proc/<pid>/maps` 与 `/proc/<pid>/fd` 的访问：双方同为 1000 都能打开（A）；目标 saved/real uid 为 0、saved gid 为 0 或 egid 不同时 maps 是 EACCES、fd 能打开（B–E）；无 capability 的 root 都被拒（F），fsuid 改成 1000 后都能打开（G）；只有 CAP_SYS_PTRACE 时 maps 放行、fd 拒绝（H），只有 CAP_DAC_OVERRIDE 时相反（I）；自己的进程总能打开（K） |
| hello330 | SO_REUSEPORT 端口组的属主是 `socket()` 时创建者的 fsuid（TCP、UDP 各一遍）：root 创建、降到 1000 后绑定，1000 的套接字加不进来（A）；1000 创建、回到 root 后绑定，root 加不进来（B）；root 在 fsuid 1000 时创建，root 加不进来（C）；两个 root 能共享（D）；1000 创建的和 fsuid 1000 时创建的能共享（E） |
| hello331 | fd 0 作为控制台终端保留 `O_ASYNC`：读回原值加 0x2000（A）；默认 owner 是调用者或前台组（B）；TIOCSTI 注入发 POLL_IN、band 0x41、si_fd 0（C）；dup 共享，关掉 dup 后 fd 0 仍生效（D）；fork 的子进程看到 `O_ASYNC`，子进程退出后父进程仍收到（E）；子进程清除后父进程也清除（F）；清除后不发（G） |
| hello332 | `mq_notify` 的注册属于进程：属主关闭同一队列的另一次 open 会移除注册（A）；fork 的子进程关闭继承的或自己的描述符不移除（B）；属主的线程关闭会移除（C）；线程做出的注册在它退出后仍在，主线程接到信号（D）；做出注册的线程阻塞信号时由主线程接（E）；子进程注册后退出不留注册（F） |
| hello333 | POSIX mq 描述符由 CLONE_FILES 线程共享：线程打开的描述符在线程退出后主线程能用（A）；线程关闭后主线程得到 EBADF，号码被重用（B）；线程用过再退出不关闭描述符（C）；fork 的子进程有自己的一份（D） |
| hello334 | POSIX mq 描述符是普通 fd：拿最低的空闲号码（A）；dup/dup2 共享 description（B、E）；总是 FD_CLOEXEC，F_GETFL 报访问模式、O_NONBLOCK 和打开时的 O_CLOEXEC（C）；poll 按消息数报 POLLIN/POLLOUT（D）；read 返回状态行，write 是 EINVAL，可 lseek（F）；非 mq 的 fd 是 EBADF（G）；F_SETFL 与 mq_setattr 改同一个 O_NONBLOCK（H）；fstat 和 /proc/self/fd（I）；fork 继承（J） |
| hello335 | mq 描述符的 read 偏移属于 open description：dup 副本接着原 fd 的位置读（A），通过副本 lseek 移动原 fd（B），另一次 mq_open 从 0 开始（C），fork 子进程的 read 移动父进程的偏移（D），SEEK_END 为 80、负位置失败（E），pread 不动偏移（F） |
| hello336 | mq 描述符上的边沿触发 epoll 每次收发都重新报告（Linux 每次唤醒 wait_q）：IN\|OUT\|ET 加入时报 OUT（A）；发送、满、接收、清空依次报 IN\|OUT、IN、IN\|OUT、OUT（B）；只关注 IN 时清空后不报（C）；只关注 OUT 时每次接收都报 OUT（D） |
| hello337 | 控制台 tty 的 TCSETSW、TCSETSF：TCSETSW 成功并读回 VMIN（A），保留已排队输入（B）；TCSETSF 设 termios 并丢掉未读输入（C）；管道上 ENOTTY、NULL 参数 EFAULT（D） |
| hello338 | 控制台 tty 的 TCFLSH、TCSBRK：TCOFLUSH 保留输入（A），TCIFLUSH、TCIOFLUSH 丢掉未读输入（B、C），其他选择子 EINVAL（D），TCSBRK 0/1 成功（E），管道上 ENOTTY（F） |
| hello339 | 控制台 tty 的 TCXONC（tcflow）：TCOOFF/TCOON/TCIOFF/TCION 成功（A），其他选择子 EINVAL（B），管道上 ENOTTY（C），TCOON 后写入照常（D） |
| hello340 | TCP bind 的 SO_REUSEADDR 冲突规则（Linux inet_csk_bind_conflict）：两边都设且占用者不在 LISTEN 才可共享（A、C），只有一边设或占用者在监听则 EADDRINUSE（B、D、E），共享者中只能一个 listen（G），同一 4 元组 connect 是 EADDRNOTAVAIL（H），accept 出来的连接继承 SO_REUSEADDR（F） |
| hello341 | 回环队列满时发送不失败：40 个不读的 UDP 数据报 `sendto` 都成功（A），队列满之后非阻塞 TCP `connect` 返回 EINPROGRESS（B），连接随后完成并被 accept（C），UDP 仍能收到数据报（D） |
| hello342 | 重传的 SYN 带原始 ISN（回归测试）：回环队列满、第一个 SYN 被丢以后，对关闭端口的 connect 以 ECONNREFUSED 失败（A、B），对监听者的 connect 完成并被 accept（C），数据可以传过去（D） |
| hello343 | 卡在 SYN-SENT 的 connect 的 SYN 始终算未确认：监听者 backlog 32，发起 40 个非阻塞 connect（A），1.5 秒后仍有连接在 SYN-SENT（B），4 秒内每 100 ms 读一次 TCP_INFO，SYN-SENT 的连接 `tcpi_unacked` 都是 1（C），12 秒内 40 个都被 accept（D） |
| hello344 | IPv4 和 IPv6 的 TCP 套接字可以绑定同一个端口：IPv6 套接字设 IPV6_V6ONLY（A），`0.0.0.0:p` 和 `[::]:p` 都能 bind（B）和 listen（C），同族的第二个 bind 是 `EADDRINUSE`（D），两个监听者各自 accept 本族的连接（E） |
| hello345 | TCP 套接字记住绑定的 IPv4 地址：`127.0.0.1:p` 和 `127.0.0.2:p` 可以同时 bind、listen（A），再绑 `0.0.0.0:p` 或同一地址是 `EADDRINUSE`（B），getsockname 给出绑定地址、通配绑定给 `0.0.0.0`（C），SYN 交给绑定其目的地址的监听者、accept 出的套接字以被连接的地址为名（D），没人监听的 `127.0.0.3:p` 被拒绝（E），客户端绑定 `127.0.0.5` 后以它为源地址（F） |
| hello346 | 只有本地地址不同的 TCP 连接是两个连接：127.0.0.1 和 127.0.0.2 上各一个监听者（A），两个都绑 `127.0.0.5:18899` 的客户端分别连接、数据各到各的（B），绑 `127.0.0.6:18899` 的客户端用同样的端口对连 127.0.0.1 成功（C），完全相同的 4 元组再 connect 是 `EADDRNOTAVAIL`（D） |
| hello347 | UDP 套接字记住绑定的 IPv4 地址：getsockname 报告绑定地址、通配绑定报告 `0.0.0.0`（A），绑定 127.0.0.5 的套接字发出的数据报源地址是 127.0.0.5（B），未绑定套接字发往 127.0.0.2 的源地址是 127.0.0.1（C），未绑定、未发送的套接字名字是 `0.0.0.0`（D） |
| hello348 | 同一端口上的 UDP 套接字按绑定的 IPv4 地址区分：`127.0.0.1:p` 和 `127.0.0.2:p` 可以同时绑定，再绑通配或重复地址返回 `EADDRINUSE`（A），数据报只交给绑定其目的地址的套接字（B），发往没人绑定的地址回 ICMP 端口不可达、已 connect 的发送者 recv 得到 `ECONNREFUSED`（C），`SO_REUSEADDR` 下具体地址优先于通配地址（D） |
| hello349 | IPv6 UDP 套接字记住绑定的地址：绑 `[::1]:18905` 的 getsockname 报告 `::1`（A），绑 `[::]:18906` 的报告 `::`（B），未绑定、未发送的套接字报告 `::`（C），从 `[::1]:18905` 发出的数据报源地址是 `[::1]:18905`（D） |
| hello350 | 共享打开文件描述的偏移读改写是原子的：父子进程共享一个 tmpfs 描述并发 4 字节读，6 轮里每条记录恰好读一次（A），第一轮后 SEEK_CUR 是文件大小（C），并发各写 1024 条记录不互相覆盖（B） |
| hello351 | 大于 4 KiB 的调用在共享描述上覆盖连续的一段：父子进程同时起跑，各写 24 个 16 KiB 块，每块都完整（A），换成 4 段 writev 也一样（B）；每次读 16 KiB 得到连续的字、合起来每个字读一次（C），换成 4 段 readv 也一样（D） |
| hello352 | getdents64 在共享目录描述上原子地移动游标：父子进程同时起跑，用约一条一次的缓冲区列 120 个条目的目录，8 轮里每个条目恰好看到一次（A），每轮结束后游标在末尾（B） |
| hello353 | aio 读写按 iocb 的偏移进行、不动共享偏移：父进程在共享描述上提交 300 个 aio 读写时，子进程顺序读到全部 4096 条记录（A），每个 aio 读拿到自己偏移处的数据（B），结束后共享偏移是子进程读到的位置（C） |
| hello354 | 带偏移指针的 copy_file_range 不动共享偏移：父进程在共享描述上做 3000 次复制时，子进程顺序读到全部 4096 条记录（A），每次复制放对位置、两个指针各前进 64（B），结束后共享偏移是子进程读到的位置（C），NULL 指针使用并推进描述符偏移（D） |
| hello355 | 带显式偏移的 splice、sendfile 不动共享偏移：父进程在共享描述上做 3000 次 splice 文件→管道（A）、splice 管道→文件（B）、sendfile 文件→管道（C）时，子进程顺序读到全部 4096 条记录，每次调用的数据和偏移都对，结束后共享偏移是 16384；NULL 偏移使用并推进描述符偏移（D）。核对测试，没有内核改动 |
| hello356 | 共享 mq 描述的 read 原子推进偏移：父子进程各读 1 字节，200 轮合起来正好读完状态行的每个字节一次（A），每轮结束后共享偏移等于行长（B），另一次打开的描述偏移仍是 0（C） |
| hello357 | IPv6 UDP 的绑定地址参与端口冲突和收包选择：`[::1]` 和 `[ff0e::1]` 可共用端口，`[::]` 和重复的 `[::1]` 是 EADDRINUSE（A）；SO_REUSEADDR 下发往 `::1` 的数据报不论绑定先后都给绑 `::1` 的套接字（B、C）；绑 `[ff0e::1]` 的套接字不收发往 `::1` 的数据报（D） |
| hello358 | IPv6 UDP 数据报从套接字的绑定地址发出：连到站外地址的套接字报告 SLAAC 得到的全局地址 G（A）；绑定 `[G]:18982` 的套接字用 sendto（B）和 connect 后的 sendmsg（C）发往 `::1`，收端看到的源地址都是 G；绑定 `[::]` 的套接字发往 `::1` 时源地址是 `::1`（D） |
| hello359 | IPv6 TCP 的绑定地址参与冲突、监听者选择、连接查找、源地址和 getsockname：`[::1]:p` 和 `[G]:p` 都能监听，`[::]:p` 是 EADDRINUSE（A）；绑定 `[G]` 的客户端连 `::1` 由 `::1` 监听者接受，服务端看到对端 G（B）；接受的套接字报告 `::1`（C）；本地地址不同的两个连接各收各的数据（D）；只有 `[G]:p` 监听时连 `[::1]:p` 是 ECONNREFUSED（E） |
| hello360 | 链路范围的 IPv6 地址需要接口：连到 `[fe80::2%2]` 的 UDP 套接字报告链路本地地址 L、scope 2（L）；绑定 `[L]` 时 scope 0 是 EINVAL、99 是 ENODEV、1（lo）是 EADDRNOTAVAIL、2 成功且 getsockname 报告 scope 2（A）；`[ff02::1]` 同样要求 scope（B）；TCP 绑定 `[L]` scope 0 是 EINVAL（C）；发往 `[L%2]` 的数据报到达时源是 L、scope 2（D） |
| hello361 | IPv6 UDP 组播：`IPV6_MULTICAST_HOPS/LOOP/IF/ALL` 的默认值、取值范围和错误码（O）；`IPV6_ADD/DROP_MEMBERSHIP` 的 EINVAL、ENODEV、EADDRINUSE、EADDRNOTAVAIL（J）；TCP 套接字加组是 EPROTO、设置 `MULTICAST_HOPS` 是 ENOPROTOOPT（T）；发往已加入组 `ff0e::101` 的数据报每个绑定 `::` 或该组且加组（或开着 `MULTICAST_ALL`）的套接字各收一份（D1、D2），没人加入的组谁都收不到（D3），发送方 `MULTICAST_LOOP 0` 时本机不收（D4），组里没有成员后谁都收不到（D5） |
| hello362 | IPv4 UDP 组播：`IP_MULTICAST_TTL/LOOP/IF/ALL` 的默认值、取值范围和错误码（O，含单字节值、`IP_MULTICAST_IF` 的 EADDRNOTAVAIL）；`IP_ADD/DROP_MEMBERSHIP` 的 EINVAL、ENODEV、EADDRINUSE、EADDRNOTAVAIL，`ip_mreq` 和 `ip_mreqn` 两种格式（J）；TCP 加组 EPROTO、设置 `MULTICAST_TTL` EINVAL（T）；发往已加入组 `239.1.1.1` 的数据报每个匹配并加组（或开着 `MULTICAST_ALL`）的套接字各收一份（D1、D2），没人加入的组收不到（D3），`224.0.0.1` 不用加组（D4），`MULTICAST_LOOP 0` 时本机不收（D5），没有成员后收不到（D6）；绑定组播地址的套接字发往 127.0.0.1 时源是 127.0.0.1（S） |
| hello363 | 组播出接口和共享端口上各套接字自己的发送选项：`IP_MULTICAST_IF` 指向 lo（127.0.0.1 或 ip_mreqn 编号 1）时数据报只经 lo 发出，lo 上的成员不论 LOOP、TTL 都收到一份，源地址是 IF 地址（F1、F2）；在网卡上加入的组收不到经 lo 发出的数据报（F3）；224.0.0.1 经 lo 也收到（F4）；只在 lo 上加入的组收不到从网卡回送的副本（F5、F6，按到达接口检查成员）；两个 SO_REUSEADDR 套接字共用端口时各用自己的 `IP_MULTICAST_LOOP`/`IPV6_MULTICAST_LOOP`（K4、K6）；`IPV6_MULTICAST_IF` 为 1 时发往组播地址是 ENETUNREACH，发往 ::1 照常（N6） |
| hello364 | IPv6 套接字绑定的接口（sin6_scope_id → sk_bound_dev_if）：ff01::1 不带 scope 是 EINVAL，scope 9 是 ENODEV（S）；同一端口上 ff02::1%1 和 ff02::1%2 都能绑（B1）；同接口重复、接口与 `::` 之间仍是 EADDRINUSE（B2）；全局地址忽略 scope（B3）；getsockname 报告绑定的接口（N）；发往 [ff02::1%2] 的数据报只到绑在接口 2 上的套接字（D）；IPv6 成员只比较组、本机成员按出接口判断（J、J2）；IPv6 TCP 绑组播地址是 EINVAL，IPv4 TCP 可以绑 239.1.1.1（T） |
| hello365 | IPv6 数据报的出接口：sendto 的 sin6_scope_id 对需要 scope 的地址选出接口，未绑定时 ff02::1%1、%9 和 fe80::1%1 是 ENETUNREACH，全局组忽略 scope（S1）；绑在 ff02::1%1 上的套接字只能带 scope 2 发往 ff02::1，发往 ff0e::1 也走 lo 而失败，发往 ::1 可以（S2）；`IPV6_MULTICAST_IF` 为 lo 时带 scope 2 可以发出，scope 0 不行（S3），这份副本在网卡上回送给在网卡上加入的成员（S4）；发往 [ff02::1:6%2] 的源地址是带 scope 2 的链路本地地址（R）；connect 到需要 scope 的地址把套接字绑到该接口：scope 0 是 EINVAL 且不算已连接（C1），%2 成功并命名 scope 2（C2），%9 是 ENETUNREACH 但接口留下，之后换 %2 是 EINVAL（C3、C5），已连接的套接字仍按自己的接口检查 sendto（C4），没有 scope 的组用 `IPV6_MULTICAST_IF`（C6），全局地址忽略 scope（C7） |
| hello366 | UDP 的 connect(AF_UNSPEC) 断开：IPv4 已绑定已连接的套接字断开后 getpeername 是 ENOTCONN，send 是 EDESTADDRREQ，其他来源的数据报能收到，绑定的地址和端口保留（U1）；AF_UNSPEC 长度 2 返回 0，长度 1 是 EINVAL（U2）；IPv6 用 ::1 做同样的检查（U3）；绑在 [ff02::1%1] 上的套接字断开后 scope 变为 0，之后 connect 到 %2 成功（U4）；connect 到 [ff02::1%2] 后断开，名字回到 :: 和 scope 0，再 connect 到 %1 是 ENETUNREACH 而不是 EINVAL（U5）；绑 0.0.0.0 连接后名字是 127.0.0.1，断开后回到 0.0.0.0（U6）；IPv6 套接字用 AF_INET、IPv4 套接字用 AF_INET6 都是 EAFNOSUPPORT（U7） |
| hello367 | IPv6 TCP connect 的出接口：connect 到 ff02::1%2、ff02::1 和 ff0e::1 都是 ENETUNREACH（G）；connect 到不带 scope 的 fe80::1 是 EINVAL，之后带 %2 可以发起（N）；connect 到 [fe80::1%2] 后 getsockname 报告链路本地地址和 scope 2（S）；connect 到 %9 是 ENETUNREACH，套接字留在接口 9 上，再 connect 到 %2 是 EINVAL（X）；connect 到 [fe80::1%1] 是 ENETUNREACH（L）；绑在自己的链路本地地址 %2 上的套接字 connect 到 %1 是 EINVAL，不带 scope 可以发起（B）；connect 到 [::1%9] 能连上 ::1 上的监听者，非链路本地地址忽略 scope（U） |
| hello368 | IPv4 的下一跳：发往网关 10.0.2.2 的数据报（必要时重试到 ARP 有结果）之后，发往子网外的 192.0.2.1 和 198.51.100.7 立即成功，因为解析的是网关的 MAC（A）；非阻塞 connect 到子网外的 192.0.2.1 是 EINPROGRESS（B）；非阻塞 connect 到子网内不应答 ARP 的 10.0.2.99 是 EINPROGRESS，SYN 等 ARP 期间算作已发出（C） |
| hello369 | 下一跳不应答 ARP/NDP 的 TCP connect 约 3 秒后以 EHOSTUNREACH 失败：非阻塞 connect 到子网内的 10.0.2.99 是 EINPROGRESS，2–6 秒内 SO_ERROR 变为 113，再读一次是 0（A）；阻塞 connect 到 10.0.2.98 在 2–6 秒内返回 -113（B）；非阻塞 connect 到自己全局 /64 里的 ::99 是 EINPROGRESS，2–6 秒内 SO_ERROR 变为 113（C） |
| hello370 | 发往本机 IPv4 地址（网卡的 10.0.2.15）的报文走 lo：数据报送到绑在通配地址上的套接字，源地址是本机地址（U）；TCP connect 到本机地址能连上通配地址上的监听者，双向收发数据，两端的名字都是本机地址（T）；connect 到本机地址上没人监听的端口是 ECONNREFUSED（R） |
| hello371 | IPv4 ping 套接字（`SOCK_DGRAM`/`IPPROTO_ICMP`）：新套接字名字的端口是 0，SO_PROTOCOL 是 1；发往 127.0.0.1 的回显请求收到回显应答，序号和数据不变，id 是套接字的 ident，校验和正确，来源 127.0.0.1、地址长度 16，之后名字报告 ident（P）；发往本机网卡地址的请求由该地址应答（O）；不到 8 字节、类型不是回显请求、code 不是 0、地址不到 16 字节是 EINVAL，AF_INET6 地址是 EAFNOSUPPORT，未连接又没给地址是 EDESTADDRREQ，空队列 recv 是 EAGAIN（E）；bind 4371 后名字是 4371，再 bind 是 EINVAL，另一个 ping 套接字也能 bind 4371（两者都有 SO_REUSEADDR），清掉 SO_REUSEADDR 的是 EADDRINUSE，UDP 的 4371 不冲突，10.0.2.99 和 224.0.0.1 是 EADDRNOTAVAIL（B）；connect 后用 send 发出并收到应答（C）；UDP recvfrom 报告 16 字节的地址长度，sin_zero 清零，调用方只给 8 字节时也报告 16（U） |
| hello372 | 共用 ident 的 ping 套接字：A、B 都 bind 4700，A 和 B 发出的请求，应答都交给后 bind 的 B，C 再 bind 4700 后交给 C（L）；先绑 127.0.0.1、后绑通配地址时应答交给后者，先绑通配、后绑本机网卡地址时发往 127.0.0.1 的应答交给前者（S）；D 第一次发送得到 ident，E bind 这个 ident 后 D 的应答交给 E（A）；新套接字名字是 0.0.0.0:0，connect 到 127.0.0.1 后名字是 127.0.0.1 和 ident；4701 上后绑、连到 127.0.0.1 的套接字照样收到来自 127.0.0.2 的应答（C） |
| hello373 | `net.ipv4.ping_group_range`：默认读出 `65534\t65534\n`，连 root 也不能建 ping 套接字（EACCES）（D）；写入 `0 0` 返回 3、读回 `0\t0\n`，root 之后可以建；写入 `2 9` 后 egid 9 和 egid 0 但附加组含 7 的进程可以，egid 10 不行；raw 套接字不看这个范围（W）；写入 `7` 只改下界（`7\t9\n`），`5 3`（倒置）读回空范围，`x`、`-1 3` 和超过 4294967294 的值是 EINVAL 且不改变范围，`1 2 3` 设为 `1\t2\n` 并返回 4（P）；uid 1 的进程不能以写方式打开这个文件，但能读（U）；测试结束时恢复原来的范围 |
| hello374 | IPv6 ping 套接字：范围为空时 `socket(AF_INET6, SOCK_DGRAM, 58)` 是 EACCES，写入 `0 0` 后可以建，SO_PROTOCOL 58、SO_DOMAIN 10，AF_INET6 配协议 1、AF_INET 配协议 58 都是 EPROTONOSUPPORT（S）；新套接字名为 `[::]:0`，发往 ::1 的回显请求收到类型 129 的应答，序号和数据不变，id 是套接字的 ident，校验和按 ::1 伪首部正确，来源 ::1、地址长度 28（P）；不足 8 字节、类型 8、code 1、不足 28 字节的地址是 EINVAL，AF_INET 地址 EAFNOSUPPORT，未连接又没给地址 EDESTADDRREQ，空队列 EAGAIN（E）；bind `[::]:4374` 后名字是 4374，再 bind 是 EINVAL；ff02::1 是 EINVAL，2001:db8::1 是 EADDRNOTAVAIL，AF_INET 地址 EAFNOSUPPORT，24 字节 EINVAL，`[::1]:4376` 可以（B）；连到 ::1 后 send 能收到应答，getpeername 是 ENOTCONN，已连接的 IPv4 ping 套接字也一样（C）；IPv6 和 IPv4 ping 套接字绑同一个 ident 4375，各自只收到本族的应答（F）；测试结束时恢复原来的范围 |
| hello375 | IPv4 下一跳未解析时帧挂起等 ARP：ping 网关后 SIOCGARP 返回 0，flags 为 ATF_COM，hw 族 1，MAC 已填，设备名保留（G）；SIOCDARP 0，之后 SIOCGARP、再次 SIOCDARP 都是 ENXIO，AF_INET6 地址 EPFNOSUPPORT，未知设备 ENODEV，目录 fd ENOTTY（D）；删掉网关条目后 ping 仍返回 16，条目重新出现（R）；删掉 10.0.2.3 后 UDP 发往它返回 16，条目重新出现（U）；发往不应答的 10.0.2.99 时 sendto、connected send、ping 都返回 16，4 秒内收不到任何东西，SO_ERROR 0（Q） |
| hello376 | IPv6 下一跳未解析时帧挂起等邻居通告：连到 [fec0::99]:9 的套接字名字在 fec0::/64 里（A，最多等 10 秒）；发往路由器 fec0::2 的回显请求返回 16 并收到应答（R）；发往 [fec0::3]:9 的 UDP 返回 16（U）；发往不应答的 fec0::99 时 sendto、connected send、ping 都返回 16，4 秒内收不到任何东西，SO_ERROR 0（Q） |
| hello377 | SIOCSARP 设置 ARP 条目：带 ATF_PERM 建永久条目，SIOCGARP 报 flags 0x6、MAC 和族 1，发往它的 UDP 返回 16 且条目还在（P）；不带 ATF_PERM 是普通条目（0x2），再次设置换 MAC，永久条目被重设为普通条目（T）；没有 ATF_COM 时新条目 EINVAL、已有永久条目保留 MAC 变成普通条目（C）；不给设备名时同链路地址装到网卡上，链路外地址 ENETUNREACH（N）；硬件族 0 取设备类型，族 772 和 eth0 不符 EINVAL，未知设备 ENODEV，AF_INET6 EPFNOSUPPORT，lo 上族 1 EINVAL（E）；uid 1000 的子进程 SIOCSARP EPERM、SIOCGARP 仍可读（U）；SIOCDARP 删掉（D） |
| hello378 | `/proc/net/arp`：只读打开，开头是 Linux 的表头（H）；SIOCSARP 设的永久条目 10.0.2.77 那一行 flags 0x6、MAC 正确、硬件类型 0x1（P），普通条目 10.0.2.78 那一行 flags 0x2（O），每 37 字节读一次，验证从文件中间开始的读；SIOCDARP 后两行都消失（D）；以写方式打开被拒绝（W） |
| hello379 | `/proc` 子目录：`/proc` 列出 sys（目录）和 net（目录或符号链接）（R）；`/proc/net` 和 `/proc/net/` 的 fstat 是 S_IFDIR，列出 arp（普通文件）（N）；`/proc/sys` 列出 net，`/proc/sys/net` 列出 ipv4，`/proc/sys/net/ipv4/` 列出 ping_group_range（S）；ping_group_range 仍可读出两个数（F）；`/proc/sys/nosuch`、`/proc/net/nosuch` 是 ENOENT，对 `/proc/net/arp` 调用 getdents64 是 ENOTDIR（E） |
| hello380 | ARP 缓存满了仍能学到新邻居：用 SIOCSARP 设 16 个普通条目，再设一次第一个（F）；向已删除条目的网关发 UDP，应答被缓存，SIOCGARP 报告 0x2（G）；刚设过的条目还在，16 个里至少留下 15 个（O）；SIOCDARP 删除它们（D） |
| hello381 | 一个 IPv6 UDP 套接字加入多个组播组：在 lo 上加入 64 个不同的组都成功，再加第一个是 EADDRINUSE（J）；64 个都能退出，再退第一个是 EADDRNOTAVAIL（D） |
| hello382 | 代理 ARP 条目（ATF_PUBL）：在 eth0 上设置成功、重复设置也成功，`/proc/net/arp` 列出 type 0x1、flags 0xc、MAC 全 0 的一行，SIOCGARP 是 ENXIO（P）；不指名设备时是所有设备（type 0x0、设备 `*`），带 ATF_COM 而 MAC 不属于任何设备是 ENODEV（N）；netmask /24 是 EINVAL，netmask 0 开关 proxy_arp、不列出（M）；同地址的普通条目与代理条目并存，不带 ATF_PUBL 的 SIOCDARP 只删普通条目（C）；SIOCDARP ATF_PUBL 删除代理条目，再删是 ENOENT（D） |
| hello383 | net.ipv4.conf.<dev>.proxy_arp：`/proc/sys/net/ipv4` 列出 `conf` 目录，`conf` 列出 all、default、lo、eth0，设备目录列出 proxy_arp，未知设备或文件 ENOENT（L）；四个值都读 `0\n`，再读和 pread 偏移 1 都是 0 字节（R）；SIOCSARP ATF_PUBL+netmask 0 把 eth0 的值设为 1（all 不变），SIOCDARP 清零，不指名设备时是 all，lo 是 lo（I）；写入按 proc_dointvec 解析一个 int（`0x10` 是 16、`010` 是 8、`12abc`/`4\r`/超出 int 是 EINVAL、空写返回 0），偏移不为 0 的写入整段吞掉不生效（W1、W2）；default 和 all 各自独立（D）；有 CAP_NET_ADMIN 的 uid 1000 能以写方式打开 proxy_arp 和 ping_group_range，用 capset 去掉能力的子进程得到 EACCES、仍能读（P） |
| hello384 | 不完整的 IPv4 邻居：发往无人应答的同链路地址的 UDP 数据报被接受，`/proc/net/arp` 列出 flags 0x0、MAC 全 0 的一行，SIOCGARP 返回 0、flags 0（I）；非阻塞 TCP connect 是 EINPROGRESS，留下同样的条目（T）；4 秒后仍无人应答，两个条目都还在、flags 0（F）；不带 ATF_COM 的 SIOCSARP 是 EINVAL、条目不变，带 MAC 后变成 flags 0x2（S）；ATF_PERM 不带 MAC 成功，flags 0x6、MAC 全 0（P）；SIOCDARP 删除两个条目，再删 ENXIO（D） |
| hello385 | 未命名的 UDP 套接字没有本地端口：getsockname 报 0，空 recv 后仍是 0，第一次 sendto 才给端口（A）；另一个套接字发给它，断开后端口回 0、再发旧端口收不到（R）；旧端口被别的套接字 bind 成功、下一次 sendto 换端口（D）；connect 给端口，断开交还（C）；bind 端口 0 给端口、断开交还，用户指定 40385 保留（B）；绑 127.0.0.1:0 的套接字保留地址、断开丢端口（W）；失败的 send/sendto 仍给端口（E）；IPv6 同样（V） |
| hello386 | 绑定 127/8 的套接字不能经网卡发送：UDP 绑 127.0.0.1 后 sendto 网关、8.8.8.8、子网广播是 EINVAL，发往 127.9.9.9、本机 10.0.2.15、255.255.255.255、224.0.0.1 照发，名字不变（U）；sendmsg 同样（M）；connect 网关 EINVAL，之后仍未连接（C）；TCP 绑 127.0.0.1 connect 网关 EINVAL（阻塞、非阻塞都是），SO_ERROR 0，之后能连本机监听者（T）；绑网卡地址发往 127.0.0.1 照发（B）；ping 套接字绑 127.0.0.1 发往网关和 connect 都是 EINVAL，发往本机照发（P） |
| hello387 | net.ipv4.conf.<dev>.route_localnet：设备目录列出 route_localnet 和 proxy_arp，四个值都是 0（L）；都为 0 时绑 127.0.0.1 发往网关是 EINVAL（N）；网卡置 1 或 all 置 1 就能发（1），lo 置 1 或 default 置 1 仍不能（EINVAL），因为出接口是网卡（E）；7 和 -1 都算开（V）；网卡置 1 时非阻塞 TCP connect 从 127.0.0.1 到网关是 EINPROGRESS 而不是 EINVAL（T）；测试结束四个值都回到 0（R） |
| hello388 | UDP 套接字没有很小的全局上限：一个进程同时开 100 个 IPv4 UDP 套接字，每个都能 sendto 127.0.0.1:9 并拿到不同端口（S）；紧接着这阵发送（每个都引出一个 ICMP 端口不可达）之后，一个套接字发给另一个仍能收到（B）；100 个设 SO_REUSEADDR 的套接字都能绑 127.0.0.1:40388，发过去的数据报恰好一个收到（R）；100 个 IPv6 UDP 套接字都能开、都能发 [::1]:9（V）；全部关闭后新套接字收发正常（C） |
| hello389 | IPv4 raw ICMP 套接字（`socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)`，要 CAP_NET_RAW）：SO_TYPE、SO_PROTOCOL、getsockname 端口位是协议号 1（A）；未连接 send/write 返回 EDESTADDRREQ，8 字节地址 EINVAL，AF_INET6 地址 EAFNOSUPPORT（S）；sendto 127.0.0.1 的回显请求，套接字收到请求和内核的回显应答两份（带 IP 头，来源 127.0.0.1 端口 0），之后 EAGAIN（E）；poll POLLIN（P）；MSG_TRUNC 返回整个长度（T）；connect 后只收对端来的、write/read 可用（C）；bind 过滤目的地址、非本机地址 EADDRNOTAVAIL（B）；connect(AF_UNSPEC) 解除连接（U）；dup 共享套接字（D）；多个 raw 套接字各收一份（M）；UDP 发往无人端口引出的端口不可达也能收到（X）；raw 套接字写的端口不可达设已连接 UDP 套接字的 SO_ERROR 111（I）；listen/accept 返回 EOPNOTSUPP（L） |
| hello390 | ICMP 差错送到引起它的套接字（通过 raw ICMP 套接字向 127.0.0.1 写差错，引用套接字发出的数据报）：已连接 UDP 套接字按 Linux `icmp_err_convert` 取 SO_ERROR，目的不可达代码 2 3 4 6 7 8 9 10 13 14 15 分别是 92 111 90 101 112 64 101 113 113 113 113，参数问题 71，代码 0 1 5 11 12、超时、源抑制、重定向不报（U）；未连接 UDP 套接字都不报（N）；已连接 ping 套接字对引用它回显请求的差错取同样的 errno（P）；未连接（只 bind）的 ping 套接字不报（Q）；引用回显应答的差错和校验和错的差错不报（R/K）；待处理的差错让 poll 报 POLLERR，下一次 recv 失败一次（ECONNREFUSED）后 EAGAIN（V）；下一次 send 失败一次，之后 SO_ERROR 为 0（S）；UDP 的 recv（代码 13，EHOSTUNREACH）和 send（代码 2，ENOPROTOOPT）同样报一次（E）；测试把 `ping_group_range` 设为 `0 0`，结束时恢复 |
| hello391 | IPv6 raw ICMPv6 套接字（`socket(AF_INET6, SOCK_RAW, IPPROTO_ICMPV6)`）和 raw 套接字的 shutdown：协议 0 是 EPROTONOSUPPORT，SO_TYPE 3、SO_PROTOCOL 58、SO_DOMAIN 10，getsockname 28 字节、端口位 58（A）；未连接 send EDESTADDRREQ，16 字节地址 EINVAL，AF_INET EAFNOSUPPORT，端口 17 EINVAL，长度 0、1 EFAULT，2、3 EINVAL（S）；向 ::1 发校验和错的回显请求，内核填好校验和，收到请求和内核的回复各 16 字节，来源 ::1 端口 0（E）；poll（P）；MSG_TRUNC（T）；ICMP6_FILTER 读写、只放行回复、8 字节只改前两个字、40 字节截断、其他选项和 IPv4 raw 上是 ENOPROTOOPT（F）；IPV6_CHECKSUM 读 2、不能设（K）；connect、write、AF_UNSPEC（C）；bind（B）；shutdown：未连接 ENOTCONN 但生效，SHUT_RD 后 POLLIN\|POLLRDHUP、非阻塞 EAGAIN、阻塞返回 0、之后的数据报照样收到，SHUT_RDWR 加 POLLHUP，IPv4 raw 一样（H）；UDP 到 [::1]:9 引起的端口不可达被看到（U）；IPv4 raw 发 0、1 字节 EFAULT，看不到 ICMPv6（Z）；listen、accept EOPNOTSUPP（L） |
| hello392 | ICMPv6 差错送到引起它的 IPv6 套接字（经 raw ICMPv6 套接字向 ::1 写差错，引用 ::1 -> ::1 的数据报）：连到 [::1]:9 的 UDP 套接字对目的不可达码 0..7 依次得到 0 13 0 0 111 13 13 71，包过大 EMSGSIZE，超时无，参数问题码 0..2 EPROTO，未知差错类型无（U）；未连接的 UDP 套接字都不收（N）；引用发往 [::2]:9 的数据报不影响连到 [::1]:9 的套接字（A）；连到 ::1 的 IPv6 ping 套接字得到同样的 errno，只是包过大对 ping 是软差错（P）；未连接（只 bind）的 ping 套接字不收（Q）；引用回显应答或码 1 的回显请求不属于任何 ping 套接字（R）；挂起的差错显示为 POLLERR，下一次 recv 失败一次（ECONNREFUSED）然后 EAGAIN（V）；下一次 ping send 失败一次，之后 SO_ERROR 读 0（S）；UDP 上 recv 对码 1 是 EACCES 然后 EAGAIN，send 对参数问题是 EPROTO（E）。程序把 net.ipv4.ping_group_range 设为 "0 0"，结束时恢复 |
| hello393 | ICMPv6 差错引用的报文带扩展头时照样送到后面的套接字（经 raw ICMPv6 套接字向 ::1 写端口不可达）：逐跳选项（8 字节）后接 UDP，连到 [::1]:9 的 UDP 套接字得到 ECONNREFUSED（H）；目的选项（16 字节）、路由头（8 字节）后接 UDP 也是 111（D）；首个分片（偏移 0）后接 UDP 是 111（F）；后续分片（偏移 8）读不到 UDP 头，0（L）；逐跳选项后是“无下一个头”（59），0（N）；扩展头声明的长度超出引用部分，0（T）；ESP（50）不是可跳过的扩展头，0（E）；AH（12 字节）后接回显请求，已连接的 IPv6 ping 套接字得到 111（P）。程序把 net.ipv4.ping_group_range 设为 "0 0"，结束时恢复 |
| hello394 | raw ICMP 套接字保存 SOL_SOCKET 选项，阻塞接收遵守 SO_RCVTIMEO：IPv4 raw 套接字设 100 ms 后阻塞 recv 约 100 ms 返回 EAGAIN（T）；getsockopt 读回 0 s、100000 us（G）；SO_SNDTIMEO 2.5 s 读回 2 s、500000 us（S）；SO_RCVBUF 4096 读回 8192（B）；dup 出的描述符读到同样的超时，阻塞 recv 也超时（D）；已入队的数据报（发往 127.0.0.1 的回显请求）立即交付（R）；IPv6 raw ICMPv6 套接字同样超时并读回（6） |
| hello395 | raw ICMP 套接字接受 IP 层选项，发送带上它们：IP_TTL 默认 64、设 7 后读回 7，发往 127.0.0.1 的回显请求回到套接字时 TTL 是 7（T）；IP_TOS 0x10 读回，请求的 TOS 字节是 0x10（Q）；IP_TTL 0 和 256 是 EINVAL，-1 恢复 64（E）；IPv4 raw 上 SOL_IPV6 的 get 是 EOPNOTSUPP、set 是 ENOPROTOOPT（L）；dup 读到同样的 TTL（D）；IPv6 raw ICMPv6 套接字的 IPV6_UNICAST_HOPS 默认 64、设 9 读回，发往 ::1 的回显请求照样发出（H）；IPV6_TCLASS 0x20 读回（C）；IPv6 raw 上 SOL_IP 两者都是 ENOPROTOOPT（S） |
| hello396 | raw IPv4 套接字的 IP_HDRINCL：默认读 0，设 1 读 1，清掉读 0（G）；UDP 套接字上 set 是 ENOPROTOOPT、get 读 0（U）；自带头（来源 0、总长 0、校验和 0、id 0x1234、TTL 5）的回显请求发往 127.0.0.1 返回 28，套接字收到的副本 TTL 5（套接字的 IP_TTL 9 不套用）、id 0x1234、来源 127.0.0.1、总长 28、校验和正确（I）；整个写好的 UDP 数据报（来源 127.0.0.1:4000）送到绑定的 UDP 套接字（P）；19 字节、IHL 60 而只发 28 字节都是 EINVAL（S）；清掉 IP_HDRINCL 后缓冲区又是 ICMP 报文，副本带内核的头、TTL 9（O） |
| hello397 | raw ICMP 套接字的 sendmsg/recvmsg：4 + 4 字节两个 iovec 发往 127.0.0.1 返回 8（S）；recvmsg 收到 28 字节（IP 头 0x45 起、偏移 20 处类型 8），名字族 2、127.0.0.1、namelen 16，controllen 0，flags 0（R）；10 字节缓冲区返回 10、msg_flags MSG_TRUNC，带 MSG_TRUNC 返回 28（T）；空队列 MSG_DONTWAIT 是 EAGAIN，未连接又无 msg_name 是 EDESTADDRREQ（E）；connect 之后不带 msg_name 发送 8，副本收回 28（C）；IPv6 raw 套接字发往 ::1 返回 8、recvmsg 8，名字族 10、末字节 1、namelen 28（6） |
| hello398 | raw ICMP 套接字的 MSG_PEEK 和队列顺序：peek 拿到 28 字节回显请求的副本和来源（namelen 16），随后一次读拿到同一个数据报，之后队列空（EAGAIN）（P）；10 字节的 MSG_PEEK\|MSG_TRUNC 返回 28，数据报仍在，再读得到全部 28 字节（T）；recvmsg 带 MSG_PEEK 两次都看到同一个数据报并回填名字，再读才取走（M）；两个请求排队时 peek 看到较早的，读走它，下一次 peek 看到较晚的（O）；队列先进先出：请求 A 和应答 A 入队，读走请求 A 后请求 B 到达，下一次读拿到应答 A（F）；IPv6 raw 套接字 peek 和读都拿到来自 ::1 的 8 字节请求（6） |
| hello399 | IPv4 raw 套接字的 ICMP_FILTER（SOL_RAW 选项 1）：新套接字读 0、长度 4，8 字节缓冲区仍读 4 字节，2 字节缓冲区读掩码的低 2 字节，长度 0 读 0 字节，长度 -1 是 EINVAL（G）；掩码第 0 位（回显应答）置位时发往 127.0.0.1 的请求只收回自己的副本（B）；第 8 位（回显请求）置位时只收回应答（R）；2 字节的 set 只改低 2 字节，6 字节的 set 取 4 字节（L）；SOL_RAW 选项 2、IPv6 raw 套接字上的 ICMP_FILTER 都是 ENOPROTOOPT，UDP 套接字 set 也是 ENOPROTOOPT（N）；所有位置位时类型 40 的报文照样收回，回显请求和应答都被挡住（H） |
| hello400 | 不认识的层上的 getsockopt/setsockopt（选项 1000，层 SOL_TCP、SOL_UDP、SOL_RAW、SOL_ICMPV6、1000、SOL_IP、SOL_IPV6）：IPv4 TCP 在 SOL_TCP、SOL_IP 以外的层 get 是 EOPNOTSUPP，所有层 set 是 ENOPROTOOPT（T）；IPv4 UDP 在 SOL_UDP、SOL_IP 以外的层 get 是 EOPNOTSUPP（U）；IPv4 raw 在 SOL_RAW、SOL_IP 以外的层 get 是 EOPNOTSUPP（R）；IPv6 TCP、UDP、raw 所有层两个方向都是 ENOPROTOOPT（6）；AF_UNIX 流、数据报、seqpacket 所有层两个方向都是 EOPNOTSUPP（X） |
| hello401 | 任意协议的 IPv4 raw 套接字：协议 0 是 EPROTONOSUPPORT，-1、263 是 EINVAL；协议 253 的 SO_PROTOCOL 和 getsockname 端口都是 253、IP_HDRINCL 0，IPPROTO_RAW 的 IP_HDRINCL 1，253 上的 ICMP_FILTER 两个方向都是 EOPNOTSUPP（A）；253 套接字发 5 字节到 127.0.0.1，收回 25 字节副本（协议 253、TTL 64、来源端口 0），发 0 字节和 1 字节也可以，副本 20、21 字节（S）；另一个 253 套接字收到同样三份，254 套接字和 ICMP 套接字收不到（O）；协议 17 的 raw 套接字看到发往已绑定 UDP 套接字的数据报（32 字节、目的端口 4011），UDP 套接字照样收到（U）；协议 6 的 raw 套接字看到连接关闭端口时的 SYN 和 RST\|ACK（T）；IPPROTO_RAW 发出协议 252 的数据报，没有处理者时 ICMP 套接字收到协议不可达，开着 252 套接字时由它收下、不回不可达（P）；绑定到 127.0.0.1 的 248 套接字收不到发往 127.0.0.2 的数据报，发送方收到协议不可达（B） |
| hello303 | MoQiOS 原生 IPC（无 Linux 对应）：没有 send 能力时发给自己的端点返回 `invalid_endpoint`（-1），给自己授予后返回 `would_deadlock`（-3）（A）；子进程创建端点并给父进程授予 send 能力，父进程发 30 条消息子进程按序收到（B）；阻塞在 `moqipc_recv` 里的子进程收到 `SIGSTOP` 立即停下（E，30 轮），事件之后的可变延迟停止 200 轮也全部停下（F）；被 `SIGKILL` 后 2 秒内被收尸，状态 9（C）；之后发给它的端点立即失败（D）。在 `hello304` 之后运行 |
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
| `include/epoll.h` `src/epoll.c` | `epoll_create1`/`epoll_ctl`/`epoll_wait`/`epoll_pwait`：`struct epoll_event` 是 **packed 的 12 字节**（`events` 偏移 0、8 字节 `data` 联合偏移 4），`EPOLLIN`…`EPOLLET` 等位与 glibc 一致；成功返回内核值，失败 -1 加 errno。`epoll_pwait` 多一个信号掩码参数（`const void *`，实际是 `sigset_t *`，只用前 64 位，NULL 表示不换掩码；传给内核的大小固定 8，无掩码时 0）。没有 `epoll_create`、`epoll_pwait2` 的封装 |
| `include/fcntl.h` `include/unistd.h` `src/fdops.c` | `dup`/`dup3`/`fcntl`/`pread`/`pwrite`/`truncate`/`ftruncate`/`fsync`/`fdatasync`/`access`/`umask`/`pipe2`/`fchdir`：POSIX/glibc 约定（成功返回内核值，失败 -1 加 errno；`umask` 不会失败）。`fcntl(fd, cmd, ...)` 的第三个参数按 `long` 读；`fcntl.h` 提供 `O_NONBLOCK`/`O_CLOEXEC`/`O_EXCL`/`O_DIRECTORY`/`O_NOFOLLOW`/`O_ACCMODE` 与 `F_*`/`FD_CLOEXEC`（`O_RDONLY`…`O_APPEND` 仍在 `unistd.h`），`unistd.h` 提供 `F_OK`/`R_OK`/`W_OK`/`X_OK`。宿主机测试 `test_fdops_abi` |
| `include/stat.h` `src/stat.c` | `stat`/`lstat`/`fstat`/`chmod`/`fchmod`/`readlink`/`symlink`/`link`/`statfs`/`fstatfs`：`struct stat` 是 glibc x86-64 布局（144 字节，`st_ino` 8、`st_nlink` 16、`st_mode` 24、`st_size` 48、`st_blksize` 56、`st_blocks` 64、三个时间 72/88/104），`S_IS*` 与权限位宏。`stat`/`lstat` 用内核 `statx` 再转成 `struct stat`（statx 掩码没声明的字段为 0，`st_dev`/`st_rdev` 恒为 0，tmpfs 没有时间和块数）；`fstat` 是内核自己的 `fstat`。`readlink` 不写结尾 NUL。tmpfs 里没有符号链接和硬链接（`symlink`/`link` 只在 ext2 可用）。`struct statfs` 是 glibc x86-64 布局（120 字节，`f_type` 0、`f_bsize` 8、`f_blocks` 16、`f_bfree` 24、`f_bavail` 32、`f_files` 40、`f_ffree` 48、`f_fsid` 56、`f_namelen` 64、`f_frsize` 72、`f_flags` 80，其后四个备用字），`statfs`/`fstatfs` 直接传给内核同名调用，失败时 -1 加 `errno`；`TMPFS_MAGIC`/`MSDOS_SUPER_MAGIC`/`EXT2_SUPER_MAGIC`/`ST_RDONLY` 常量。宿主机测试 `test_stat_abi`（含 statfs 的布局偏移和错误码转发）；hello250/251/252 改为通过这个头文件调用 |
| `include/utsname.h` `include/sysinfo.h` `src/sysinfo.c` | `uname`（`struct utsname` 是 glibc 的 6×65 字节，共 390 字节）、`gethostname`（读 `uname` 的 nodename；缓冲区小于名字+1 是 `ENAMETOOLONG`，非空缓冲区被填成截断的名字且无 NUL，与 glibc 一致）、`getrandom`（直通内核）、`getentropy`（至多 256 字节，超过是 `EIO`，不会问内核；短读会继续读完）、`getpagesize`（4096）、`sysconf`。`sysconf` 与 glibc 一致的：`_SC_PAGESIZE` 4096、`_SC_CLK_TCK` 100、`_SC_HOST_NAME_MAX` 64、`_SC_LOGIN_NAME_MAX` 256、`_SC_NGROUPS_MAX` 65536、`_SC_IOV_MAX` 1024、`_SC_LINE_MAX` 2048；**故意与 glibc 不同的**：`_SC_OPEN_MAX` 是 64（这个内核的描述符表大小，glibc 在 Linux 上是 `RLIMIT_NOFILE` 的软上限）、`_SC_CHILD_MAX` 63（任务表上限）、`_SC_ARG_MAX` 2097152。`_SC_NPROCESSORS_*` 是 `sched_getaffinity` 返回掩码的置位数（内核失败时为 1），`_SC_PHYS_PAGES`/`_SC_AVPHYS_PAGES` 来自 `sysinfo` 的总内存/空闲内存除以 4096。**没列出的名字一律是 -1 / `EINVAL`**（glibc 对它认识但本库没实现的名字会给出值或 -1 且 errno 不变，这里不区分）。宿主机测试 `test_sysinfo_abi` |
| `include/select.h` `src/select.c` | `select`、`pselect`、`fd_set`（128 字节，`FD_SETSIZE` 1024）和 `FD_ZERO/FD_SET/FD_CLR/FD_ISSET`，布局与 glibc 一致（`FD_SET(3)` 使第 0 个 64 位字等于 0x8）；失败 -1 加 errno，超时 0；内核把剩余时间写回非空的 `timeval`。宏不检查描述符是否小于 `FD_SETSIZE`。`pselect` 的超时是 `const struct timespec *`（NULL 永久等待）加一个可选信号掩码；库把超时拷到局部变量再交给内核，所以调用者的 `timespec` 不会被改写（与 glibc 的包装一致），掩码在等待期间替换阻塞集、返回前恢复 |
| `include/poll.h` `src/poll.c` | `poll`/`ppoll`：glibc 的 `struct pollfd`（8 字节）和事件位；`poll` 返回就绪描述符个数、超时 0、失败 -1 加 errno（被信号处理函数打断是 `EINTR`）；`ppoll` 的信号掩码大小固定传 8（掩码为 NULL 时传 0）。`select()` 见 `select.h` |
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
(`fchmod`/`fchown`). As in Linux `may_delete`, missing write+search on the
parent is `-13` (`EACCES`); a sticky-directory refusal is `-1` (`EPERM`), as is
a chmod/chown refusal.

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
(`EACCES`). Sticky directories are enforced on ext2 as on tmpfs: unlink, rmdir,
rename of the source and of a replaced or exchanged target are refused with
`-1` (`EPERM`) unless the caller owns the entry or the directory, or holds
`CAP_FOWNER`. FAT32 has no permission bits, so neither DAC nor the sticky rule
applies there.

Independent of DAC, descriptor access modes are enforced at read time
regardless of filesystem: reading a descriptor opened `O_WRONLY` fails with
`-9` (`EBADF`). Callers that need both directions must open `O_RDWR`.

---

## Reference

- [moqios-architecture-current.md](./moqios-architecture-current.md)
- [kernel-subsystems.md](./kernel-subsystems.md)
- [build-and-toolchain.md](./build-and-toolchain.md)
- [moqios-design.md](./moqios-design.md)
