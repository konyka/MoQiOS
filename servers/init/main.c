/* servers/init/main.c — PID 1 for MoQiOS, built against moqi_libc.
 *
 * C replacement for user/init.S (retained as the assembly fallback). The
 * kernel loads the ramdisk file named "init" (kernel/main.zig calls
 * loader.loadProgram("init", 0)), so this program is the first userspace
 * task. It runs the hello* auto-test sequence in the exact order the
 * assembly version did, printing the exact same byte stream — the QEMU
 * smoke test (tools/qemu_smoke.sh) greps the serial log for these markers,
 * so every line here is load-bearing.
 *
 * Behavior contract:
 *  - A SYS_spawn return of exactly -1 reports "spawn failed <program>";
 *    init skips that program's marker and wait, then continues the sequence.
 *  - Each successfully created test child is reaped with waitpid(-1, NULL,
 *    0) before the next spawn.
 *  - hello2 additionally passes a status pointer and prints "child exited"
 *    instead of "hello2 done".
 *  - hello13..hello16 print no "done" line after their wait.
 *  - hello6 is never spawned (it blocks on keyboard input); hello11 and
 *    hello28 are built and packed but never part of the auto sequence.
 *  - hello40 runs before hello39; hello9, hello10 and hello21 (slow ext2
 *    write test) run at the very end, after hello44.
 *  - Finally the interactive shell "sh" is spawned and init remains alive
 *    to reap children and supervise only the opt-in persistent services.
 */

#include <stdio.h>
#include <unistd.h>
#include <moqi_syscalls.h>

#include "spawn_report.h"
#include "supervisor.h"

static const char *const persistent_services[] = {
    "syslogd",
    "devmgr",
};

static struct init_supervisor supervisor;

/* spawn() has no libc wrapper yet (only sh/hello10 used the libc before
 * init), so call the syscall directly through the shared ABI header. */
static long spawn(const char *name) {
    return syscall1(SYS_spawn, (long)name);
}

static void report_spawn_failure(const char *name) {
    printf("spawn failed %s\n", name);
}

static int spawn_created(const char *name) {
    return init_spawn_created(spawn(name), name, report_spawn_failure);
}

static void report_service_disabled(const char *name) {
    printf("service disabled %s\n", name);
}

static const struct init_supervisor_ops supervisor_ops = {
    spawn,
    report_spawn_failure,
    report_service_disabled,
};

static long spawn_child(const char *name) {
    long tid = spawn(name);

    if (!init_spawn_created(tid, name, report_spawn_failure)) return -1;
    return tid;
}

static long reap_child(int *status) {
    for (;;) {
        int child_status = 0;
        long tid = waitpid(-1, &child_status, 0);

        if (tid < 0) return tid;
        if (init_supervisor_child_exit(&supervisor, tid, child_status,
                                       &supervisor_ops) ==
            INIT_SUPERVISOR_IGNORED) {
            if (status != (int *)0) *status = child_status;
            return tid;
        }
    }
}

/* Common case: spawn, announce, reap, announce done. */
static void run_test(const char *name) {
    if (spawn_child(name) == -1) return;
    printf("spawned %s\n", name);
    (void)reap_child((int *)0);
    printf("%s done\n", name);
}

/* hello13..hello16: no "done" line in the original sequence. */
static void run_test_quiet(const char *name) {
    if (spawn_child(name) == -1) return;
    printf("spawned %s\n", name);
    (void)reap_child((int *)0);
}

static void start_persistent_services(void) {
    unsigned long i;

    init_supervisor_init(&supervisor);
    for (i = 0; i < sizeof(persistent_services) / sizeof(persistent_services[0]);
         i++) {
        int slot = init_supervisor_register(&supervisor,
                                            persistent_services[i]);
        if (slot >= 0) init_supervisor_start(&supervisor, slot, &supervisor_ops);
    }
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    printf("init (pid %ld) started\n", getpid());
    print("Hello from init!\n");


    /* hello2: the only child reaped with a status pointer, and the only
     * one that prints "child exited" instead of "hello2 done". */
    int status;
    if (spawn_child("hello2") != -1) {
        print("spawned hello2\n");
        (void)reap_child(&status);
        print("child exited\n");
    }

    run_test("hello3");
    run_test("hello4");
    run_test("hello5");
    /* hello6 intentionally skipped: it blocks on keyboard input. */
    run_test("hello7");
    run_test("hello8");   /* pipe test */

    run_test("hello12");  /* FAT32 write test */
    run_test_quiet("hello13"); /* signal test */
    run_test_quiet("hello14"); /* network test */
    run_test_quiet("hello15"); /* network stack test */
    run_test_quiet("hello16"); /* env var test */
    run_test("hello17");  /* argv test */
    run_test("hello18");  /* chdir/getcwd/fstat test */
    run_test("hello19");  /* TCP test */
    run_test("hello20");  /* ext2 test */

    run_test("hello22");  /* TCP socket API test */
    run_test("hello26");  /* TCP echo server test */
    run_test("hello27");  /* connect syscall test */
    run_test("hello23");  /* mkdir test */
    run_test("hello24");  /* ext2 unlink test */
    run_test("hello25");  /* ext2 multi-level path test */

    run_test("hello29");  /* getdents64 short-buffer test */
    run_test("hello30");  /* brk grow/zero/shrink test */
    run_test("hello31");  /* per-task TLS base test */
    run_test("hello32");  /* SIGSEGV delivery + NX exec fault test */
    run_test("hello33");  /* read-only destination buffer test */
    run_test("hello34");  /* refused copy must not consume data */
    run_test("hello35");  /* CLONE_VM thread test */
    run_test("hello36");  /* copy-vs-munmap race */
    run_test("hello37");  /* audit regression suite */
    run_test("hello38");  /* futex user-word fault regression */
    run_test("hello40");  /* IPC_SET and rt_sigsuspend failed-copy regression */
    run_test("hello39");  /* socket option and sockaddr validation regressions */
    run_test("hello41");  /* copy_file_range fd and offset rollback regression */
    run_test("hello42");  /* pread64/pwrite64 fd and offset regression */
    run_test("hello43");  /* TCP/UDP loopback test */
    run_test("hello44");  /* SCHED_FIFO/RR realtime scheduling classes */
    run_test("hello45");  /* argc/argv/envp through moqi_libc crt0 */
    run_test("hello46");  /* file-backed mmap (MAP_PRIVATE demand paging) */
    run_test("hello47");  /* /dev/kmsg ring buffer reader */
    run_test("hello48");  /* MAP_SHARED file mappings (tmpfs/ext2/ramdisk) */
    run_test("hello49");  /* user 2MiB huge-page anonymous mmap */
    run_test("hello50");  /* SMP concurrent-workload stress (4 workers) */
    run_test("hello51");  /* userspace driver framework (pci/mmio/irq/dma) */
    run_test("hello52");  /* ioperm: user port I/O via TSS I/O bitmap */
    run_test("hello53");  /* devfs device nodes (/dev registry + getdents) */
    run_test("hello54");  /* userspace-owned /dev node (devfs proxy) */
    run_test("hello56");  /* display/input/time: fb0 mmap, mouse, wall clock */
    run_test("hello57");  /* pthread 子集: create/join/mutex/once/specific/errno */
    run_test("hello58");  /* 作业控制: ctty/前后台/SIGTTIN/kill(-pgid)/孤儿组 */
    run_test("hello59");  /* RLIMIT_STACK 执行语义: 默认值/EINVAL/继承/SIGSEGV */
    run_test("hello60");  /* RLIMIT_AS 执行语义: mmap/brk 计费/超限/继承/SIGSEGV */
    run_test("hello61");  /* fork COW 事务化克隆回归: 96MiB 大页表规模 */
    run_test("hello62");  /* 文件映射 fault-around: 256KiB 顺序扫描校验 */
    run_test("hello63");  /* RLIMIT_DATA 执行语义: mmap/brk 计费/退款/继承 */
    run_test("hello64");  /* RLIMIT_NPROC 执行语义: 默认/EINVAL/EAGAIN/继承/释放 */
    run_test("hello65");  /* bounded transactional MAP_FIXED anonymous replacement */
    run_test("hello66");  /* RLIMIT_FSIZE writes, pwrite, SIGXFSZ, inheritance */
    run_test("hello67");  /* fixed-table VMA fragmentation baseline */
    run_test("hello68");  /* observation-only present-user-page RSS telemetry */
    run_test("hello69");  /* private futex isolation and pthread contention */
    run_test("hello70");  /* native AIO io_cancel unsupported contract */
    run_test("hello71");  /* mlock ABI rejection and MAP_FIXED independence */
    run_test("hello72");  /* ioprio process ABI and unsupported scopes */
    run_test("hello73");  /* expanded VMA telemetry acceptance */
    run_test("hello74");  /* raw ABI mprotect transactions and ordinary-page COW */
    run_test("hello75");  /* strict raw openat2 validation for #320 and #437 */
    run_test("hello76");  /* bounded raw sync_file_range validation for #290 */
    run_test("hello77");  /* bounded raw ext2 readahead validation for #291 */
    run_test("hello78");  /* raw Unix socketpair #53 boundary and bidirectional I/O */
    run_test("hello79");  /* raw fallocate #274 mode boundary and size preservation */
    /* hello80 fixture: a root-owned POSIX message queue that only root may
     * open (0600), and one created as 0666 that init's umask (022) leaves
     * 0644. Kept open by nobody. */
    {
        long q = syscall4(186 /* mq_open */, (long)"/h80-root", O_RDWR | O_CREAT, 0600, 0);
        if (q >= 0) syscall1(SYS_close, q); /* mq descriptors close with close() */
        q = syscall4(186 /* mq_open */, (long)"/h80-open", O_RDWR | O_CREAT, 0666, 0);
        if (q >= 0) syscall1(SYS_close, q); /* mq descriptors close with close() */
    }
    run_test("hello80");  /* raw unsupported syscall ENOSYS and user-buffer preservation */
     run_test("hello81");  /* bounded TCP sendmmsg/recvmmsg validation */
    run_test("hello82");  /* raw sched_getaffinity current-pid and CPU-0 mask boundary */
    run_test("hello83");  /* raw epoll_create1 flag boundary */
    run_test("hello84");  /* raw epoll_create1 CLOEXEC creation and close boundary */
    run_test("hello85");  /* accept4 strict flags and backlog preservation */
    run_test("hello86");  /* raw readlink procfs fd and truncation boundary */
    run_test("hello87");  /* statx output fault and temporary-fd cleanup */
    run_test("hello88");  /* copy_file_range offsets, errors, and rollback */
    run_test("hello89");  /* epoll_pwait/epoll_pwait2 masks and boundaries */
    run_test("hello90");  /* raw sendfile/splice offsets, FIFO, and boundaries */
    run_test("hello91");  /* raw pipe fd lifecycle, duplication, fork, and waitpid */
    run_test("hello92");  /* process_vm readv/writev on the caller: safety and boundaries */
    run_test("hello93");  /* eventfd2 drain/semaphore, EAGAIN/EINVAL, fork, blocking wake */
    run_test("hello94");  /* timerfd real fd, settime/gettime, EAGAIN, expiry read */
    run_test("hello95");  /* mount/umount2/vmsplice/setitimer user-copy EFAULT */
    run_test("hello96");  /* swapon device-targeting gate + CLONE_VM swap-reclaim stress */
    run_test("hello97");  /* PCID no-flush CR3 vs >32-page flush fallback (stale-entry probe) */
    run_test("hello98");  /* 4-worker CLONE_VM swap-reclaim stress (SMP=4 RIP=0 tripwire) */
    run_test("hello99");  /* PROT_NONE reservation vs swap-entry encoding (SIGSEGV/EFAULT/restore) */
    run_test("hello100"); /* non-present PTE teardown reclaim + PROT_NONE first-access SIGSEGV */
    run_test("hello101"); /* real swapoff: drain all slots to RAM, disable, re-arm (§6.50) */
    run_test("hello102"); /* blocking clock_nanosleep, nanosleep validation, real getrusage */
    run_test("hello103"); /* CR4.UMIP: sgdt/sidt/sldt/smsw/str #GP in user mode */
    run_test("hello104"); /* SCHED_FIFO wakeup preemption on the waker's CPU */
    run_test("hello105"); /* futex/epoll timeouts expire on the next tick */
    run_test("hello106"); /* console writes stay cheap while fbcon scrolls */
    run_test("hello107"); /* cross-CPU kernel lock contention stays fair and bounded */
    run_test("hello108"); /* orphan reaping never steals the CPU from an RT task */
    run_test("hello109"); /* sigaction sa_mask/SA_RESETHAND, FPU-preserving signal frames */
    run_test("hello110"); /* madvise(MADV_DONTNEED) drops anonymous pages */
    run_test("hello111"); /* kill(2) permission/probe/group, SIGCHLD, SIG_IGN auto-reap */
    run_test("hello112"); /* sigaltstack delivery, undeliverable signal -> SIGSEGV */
    run_test("hello113"); /* SysV IPC / poll hardening */
    run_test("hello114"); /* read-only ext4 / NTFS volumes on the 2nd virtio disk */
    run_test("hello115"); /* setuid family drops capabilities (capabilities(7)) */
    run_test("hello117"); /* prctl: PDEATHSIG delivery, NO_NEW_PRIVS */
    run_test("hello118"); /* memfd_create */
    run_test("hello119"); /* rename on tmpfs */
    run_test("hello120"); /* mseal */
    run_test("hello121"); /* cwd and directory fds in path lookup */
    run_test("hello122"); /* execve/execveat errnos and name resolution */
    run_test("hello123"); /* utimensat/futimens */
    run_test("hello124"); /* linkat/symlinkat/fchownat */
    run_test("hello125"); /* statx fields and flags */
    run_test("hello126"); /* access/faccessat/faccessat2 */
    run_test("hello127"); /* namespace errnos */
    run_test("hello128"); /* rename/truncate/read/write/chmod errnos */
    run_test("hello129"); /* lseek/pread/pwrite/ftruncate/O_APPEND semantics */
    run_test("hello130"); /* fcntl/dup3/pipe semantics */
    run_test("hello131"); /* mmap/munmap/mprotect/mremap/brk argument rules */
    run_test("hello132"); /* clocks and sleeping */
    run_test("hello133"); /* wait status, options, orphaning, pgrp/session */
    run_test("hello134"); /* socket flags and AF_UNIX semantics */
    run_test("hello135"); /* signal call argument and errno rules */
    run_test("hello136"); /* real-time signals 32..64 */
    run_test("hello137"); /* siginfo and ucontext */
    run_test("hello138"); /* uname, hostname, rlimit, sysinfo */
    run_test("hello139"); /* poll and select readiness and timeouts */
    run_test("hello140"); /* ppoll and pselect6 */
    run_test("hello141"); /* ioctl requests */
    run_test("hello142"); /* SCM_RIGHTS fd passing */
    run_test("hello143"); /* socket options on every socket kind */
    run_test("hello144"); /* UDP receive: blocking, timeout, non-blocking */
    run_test("hello145"); /* UDP sendmsg/recvmsg, AF_UNIX receive timeout */
    run_test("hello146"); /* sendmmsg / recvmmsg */
    run_test("hello147"); /* directory fd follows its directory across rename */
    run_test("hello148"); /* fstat file types for every descriptor kind */
    run_test("hello150"); /* blocking AF_UNIX stream writes */
    run_test("hello151"); /* read/write on TCP socket descriptors */
    run_test("hello152"); /* read() returns what is available */
    run_test("hello153"); /* AF_UNIX shutdown half-close semantics */
    run_test("hello154"); /* TCP write errors and half-close */
    run_test("hello155"); /* SIGPIPE on sockets */
    run_test("hello156"); /* TCP shutdown(SHUT_RD) */
    run_test("hello157"); /* TCP poll/epoll readiness */
    run_test("hello158"); /* EPOLLRDHUP and POLLRDHUP */
    run_test("hello159"); /* AF_UNIX EPOLLRDHUP and POLLRDHUP */
    run_test("hello160"); /* TCP connect to a closed port */
    run_test("hello161"); /* UDP port unreachable on loopback */
    run_test("hello162"); /* remaining timeout written back by ppoll/pselect6/select */
    run_test("hello163"); /* socketpair(AF_UNIX, SOCK_DGRAM) */
    run_test("hello164"); /* SCM_CREDENTIALS / SO_PASSCRED */
    run_test("hello165"); /* MSG_PEEK / MSG_WAITALL / MSG_TRUNC */
    run_test("hello166"); /* SSE register state across fork */
    run_test("hello167"); /* recvmsg MSG_PEEK / MSG_WAITALL / MSG_TRUNC */
    run_test("hello168"); /* socketpair(AF_UNIX, SOCK_SEQPACKET) */
    run_test("hello169"); /* socket(AF_UNIX, SOCK_SEQPACKET) listen/connect/accept */
    run_test("hello170"); /* process CPU time: threads and waited-for children */
    run_test("hello171"); /* TCP connect to a closed IPv6 loopback port */
    run_test("hello172"); /* UDP ICMPv6 port unreachable on loopback */
    run_test("hello173"); /* ioctl(TIOCOUTQ) on sockets */
    run_test("hello174"); /* SO_SNDBUF / SO_RCVBUF on TCP */
    run_test("hello175"); /* netdevice ioctls */
    run_test("hello176"); /* sleeping is not CPU time */
    run_test("hello177"); /* TCP_INFO / TCP_MAXSEG / TCP_CONGESTION */
    run_test("hello178"); /* IP_TTL / IP_TOS / IPV6_* socket options */
    run_test("hello179"); /* SO_PRIORITY / SO_MARK / SO_BINDTODEVICE ... */
    run_test("hello180"); /* getsockname / getpeername on AF_UNIX */
    run_test("hello181"); /* AF_UNIX datagram sendto with an address */
    run_test("hello182"); /* poll vs epoll wake-up latency */
    run_test("hello183"); /* TCP bind errors */
    run_test("hello184"); /* TCP errno conformance */
    run_test("hello185"); /* fd/path errno conformance */
    run_test("hello186"); /* epoll errno and layout conformance */
    run_test("hello187"); /* fcntl errno and flag conformance */
    run_test("hello188"); /* memory-management errno conformance */
    run_test("hello189"); /* signal errno conformance */
    run_test("hello195"); /* dns_resolve */
    run_test("hello196"); /* libc gethostbyname_ipv4 */
    run_test("hello197"); /* gettimeofday pointer conformance */
    run_test("hello198"); /* mlock / RLIMIT_MEMLOCK */
    run_test("hello199"); /* mlockall / MAP_LOCKED / RLIMIT_MEMLOCK in mmap, brk, mremap */
    run_test("hello200"); /* libc mman wrappers */
    run_test("hello201"); /* libc time API */
    run_test("hello202"); /* libc calendar and strftime */
    run_test("hello203"); /* libc strptime, asctime, ctime */
    run_test("hello204"); /* libc strtol family, rand, string functions */
    run_test("hello205"); /* libc qsort, bsearch, rand_r, memmem, strsignal */
    run_test("hello206"); /* libc setenv, unsetenv, putenv, clearenv; environment across execve */
    run_test("hello207"); /* libc realloc, aligned allocation, allocation errno */
    run_test("hello208"); /* libc printf family: width, precision, flags, length modifiers, asprintf, dprintf */
    run_test("hello209"); /* program break shared by CLONE_VM threads */
    run_test("hello210"); /* mappings shared by CLONE_VM threads */
    run_test("hello211"); /* signal dispositions shared by threads */
    run_test("hello212"); /* RLIMIT_AS accounting shared by threads */
    run_test("hello213"); /* resource limits shared by threads */
    run_test("hello214"); /* current directory and umask shared by threads */
    run_test("hello215"); /* thread create/join storm */
    run_test("hello216"); /* registers survive system calls */
    run_test("hello217"); /* strtod, strtof, atof; xmm state across thread switches */
    run_test("hello218"); /* printf floating point */
    run_test("hello219"); /* FILE streams */
    run_test("hello220"); /* scanf family */
    run_test("hello221"); /* setjmp family */
    run_test("hello222"); /* current directory shared by threads */
    run_test("hello223"); /* math and ctype */
    run_test("hello224"); /* /proc/lostats */
    run_test("hello225"); /* pause, alarm, gettid */
    run_test("hello226"); /* libc: atexit/abort/raise/assert/signal/sigset/perror/remove/rename/isatty */
    run_test("hello227"); /* libc system(): sh -c, exit status, 127, redirection, signal state restored */
    run_test("hello228"); /* join, then reuse the joined thread's block */
    run_test("hello229"); /* SA_RESTART: blocked read/waitpid restart or EINTR */
    run_test("hello234"); /* poll and ppoll */
    run_test("hello235"); /* handler runs before EINTR: epoll_wait, futex, semop, sigtimedwait, mq_timedreceive, recvmmsg, connect */
    run_test("hello236"); /* libc epoll wrappers */
    run_test("hello237"); /* epoll on TCP sockets */
    run_test("hello238"); /* libc pselect and epoll_pwait */
    run_test("hello239"); /* libc dup/fcntl/pread/truncate/fsync/access/umask/pipe2/fchdir */
    run_test("hello240"); /* libc stat/lstat/fstat/chmod/fchmod/readlink/symlink/link */
    run_test("hello241"); /* tmpfs entries are released by rmdir/unlink */
    run_test("hello242"); /* libc uname/gethostname/getrandom/getentropy/sysconf */
    run_test("hello243"); /* sched_setaffinity masks */
    run_test("hello244"); /* a larger /tmp */
    run_test("hello245"); /* sched_setaffinity migrates at once */
    run_test("hello246"); /* FAT32 descriptor references and slots */
    run_test("hello248"); /* a truncate is seen by every descriptor */
    run_test("hello249"); /* a shared mapping follows a truncate through another descriptor */
    run_test("hello250"); /* a directory stream follows changes made through other paths */
    run_test("hello251"); /* statfs/fstatfs report each filesystem's own figures */
    run_test("hello252"); /* a directory grows past the direct blocks */
    run_test("hello253"); /* /proc/self names the calling process */
    run_test("hello254"); /* /proc as a directory */
    run_test("hello255"); /* the root directory */
    run_test("hello256"); /* TCP teardown */
    run_test("hello257"); /* /proc/self/fd */
    run_test("hello258"); /* process name (comm) */
    run_test("hello259"); /* /proc/<pid>/status */
    run_test("hello260"); /* capget / capset */
    run_test("hello261"); /* stop and fatal signals vs sleeping and stopped processes */
    run_test("hello262"); /* signals to a process group */
    run_test("hello263"); /* kill(0) and kill(-1) */
    run_test("hello264"); /* VmSize / VmRSS */
    run_test("hello265"); /* mprotect and the RLIMIT_DATA ledger */
    run_test("hello266"); /* simultaneous O_APPEND writers */
    run_test("hello267"); /* SO_REUSEPORT listener close migrates its backlog */
    run_test("hello268"); /* pwrite/pwritev on O_APPEND files */
    run_test("hello269"); /* finished connections do not exhaust the TCB table */
    run_test("hello270"); /* O_APPEND writers to different files do not wait for each other */
    run_test("hello271"); /* a fork()ed child inherits its parent's descriptors */
    run_test("hello272"); /* 40 simultaneous TCP connections (more than 64 TCBs) */
    run_test("hello273"); /* more than 64 descriptors and 16 pipes in one process */
    run_test("hello274"); /* real-time signals queue one instance per send */
    run_test("hello275"); /* FAT32 writes that used to poison the writeback pool */
    run_test("hello276"); /* /proc/self/fd/N of unlinked entries */
    run_test("hello277"); /* open flags and object kinds through /proc/self/fd/N */
    run_test("hello278"); /* ext2 fd paths follow rename and unlink */
    run_test("hello279"); /* ext2 names removed under an open descriptor (rmdir, rename victims) */
    run_test("hello280"); /* FAT32 files unlinked while open through /proc/self/fd/N */
    run_test("hello281"); /* sticky directories: EPERM for another user's entries on ext2 and tmpfs */
    run_test("hello282"); /* process_vm_readv/writev across processes: COW-private writes, ESRCH, EPERM */
    run_test("hello283"); /* orphaned process groups: SIGHUP+SIGCONT only for a newly orphaned group with a stopped member */
    run_test("hello284"); /* waitpid WUNTRACED/WCONTINUED: stopped and continued children, SIGCHLD, SA_NOCLDSTOP */
    run_test("hello285"); /* waitid: P_ALL/P_PID/P_PGID, WEXITED/WSTOPPED/WCONTINUED, WNOWAIT, siginfo */
    run_test("hello286"); /* process-directed SIGSTOP stops every thread; the parent is told once the group has stopped */
    run_test("hello287"); /* exit_group and exit() from the main thread end every thread of the process */
    run_test("hello288"); /* rt_tgsigqueueinfo queues for the named thread of the named process */
    run_test("hello289"); /* Linux personality: 231 is exit_group, 247 is waitid */
    run_test("hello290"); /* flock and F_SETLKW sleep while blocked; locks go away with close and exit */
    run_test("hello291"); /* timerfd expiries and remaining time in nanoseconds */
    run_test("hello292"); /* POSIX timer signals carry SI_TIMER, the timer id, the overrun and the value */
    run_test("hello293"); /* mq_notify signals carry SI_MESGQ, the sender pid and uid, and the value */
    run_test("hello294"); /* mq_notify: SIGEV_NONE and signal 0 register without sending, only the owner removes it */
    run_test("hello295"); /* SIGEV_THREAD_ID delivers a timer signal to one thread */
    run_test("hello296"); /* CLOCK_BOOTTIME for timer_create and timerfd */
    run_test("hello297"); /* splice waits on an empty pipe react to signals; pipe-to-pipe splice waits for input */
    run_test("hello298"); /* splice and sendfile accept a tmpfs file end */
    run_test("hello299"); /* splice and sendfile read staged ext2/FAT32 writes */
    run_test("hello300"); /* default stops in eventfd, timerfd, mq, epoll, socket and sleep waits */
    run_test("hello301"); /* default stops in TCP recv and SysV semop waits */
    run_test("hello302"); /* a SIGSTOP in a long nanosleep is taken at once */
    run_test("hello304"); /* a killed blocked pipe writer releases its end */
    run_test("hello303"); /* native IPC send/receive; a killed moqipc_recv waiter is reaped */
    run_test("hello305"); /* a blocking /dev/mouse read waits for an event */
    run_test("hello306"); /* process_vm across a 2 MiB user block */
    run_test("hello307"); /* CLOCK_TAI */
    run_test("hello308"); /* POSIX timers on CPU-time clocks */
    run_test("hello309"); /* exec drops the old image's timers and mq_notify */
    run_test("hello310"); /* flock is per open file description, fcntl per process; independent kinds */
    run_test("hello311"); /* F_SETLKW that would close a cycle of lock owners is EDEADLK */
    run_test("hello312"); /* TIMER_ABSTIME on a CPU-time clock is a reading of that clock */
    run_test("hello313"); /* OFD locks are owned by the open file description and share the fcntl range space */
    run_test("hello314"); /* the CPU-time clocks never step backwards while sibling threads switch in and out */
    run_test("hello315"); /* clock_nanosleep on CLOCK_PROCESS_CPUTIME_ID waits for process CPU time */
    run_test("hello316"); /* file leases: F_SETLEASE/F_GETLEASE, SIGIO on a conflicting open or truncate */
    run_test("hello317"); /* adjtimex / clock_adjtime: NTP variables, TAI offset, ADJ_SETOFFSET */
    run_test("hello318"); /* F_SETOWN/F_GETOWN/F_SETSIG/F_GETSIG and the signal a lease break sends */
    run_test("hello319"); /* F_SETLEASE needs the file's owner or CAP_LEASE */
    run_test("hello320"); /* O_ASYNC on a pipe: SIGIO with POLL_IN / POLL_OUT to the owner */
    run_test("hello321"); /* F_SETOWN_EX/F_GETOWN_EX: owner types TID/PID/PGRP and thread-directed SIGIO */
    run_test("hello322"); /* SIGIO permission: the owner setter's uid/euid against the target's uid/saved uid */
    run_test("hello323"); /* O_ASYNC on AF_UNIX sockets: POLL_IN/POLL_OUT/POLL_HUP, listener; flags shared by dup */
    run_test("hello324"); /* O_ASYNC on UDP sockets: POLL_IN per datagram, POLL_ERR on port unreachable */
    run_test("hello325"); /* O_ASYNC on TCP sockets: POLL_IN to the listener and on data/FIN, POLL_OUT on connect and after EAGAIN, POLL_ERR on reset/refusal */
    run_test("hello326"); /* O_ASYNC on /dev/tty: POLL_IN per queued character, owner defaults to the foreground group or the caller; TIOCSTI */
    run_test("hello327"); /* F_GETOWN reports 0 once the owner is gone */
    run_test("hello328"); /* setfsuid / setfsgid: filesystem checks use the fs ids */
    run_test("hello329"); /* /proc/<pid>/maps and fd: ptrace access with the fs ids, fd directory owned by the target */
    run_test("hello330"); /* SO_REUSEPORT owner: the socket creator's fsuid, fixed at socket() */
    run_test("hello331"); /* O_ASYNC on fd 0 as the console terminal, shared by dup and fork */
    run_test("hello332"); /* an mq_notify registration belongs to the process: closes, threads, signal target */
    run_test("hello333"); /* POSIX mq descriptors are shared by the threads of a process, not copied per thread */
    run_test("hello334"); /* a POSIX mq descriptor is an ordinary file descriptor: lowest number, dup, fcntl, poll, read, fstat */
    run_test("hello335"); /* an mq descriptor's read offset belongs to its open description: dup and fork share it */
    run_test("hello336"); /* edge-triggered epoll on an mq descriptor reports again after every send and receive */
    run_test("hello337"); /* TCSETSW keeps queued console input, TCSETSF discards it */
    run_test("hello338"); /* TCFLSH discards console input for TCIFLUSH/TCIOFLUSH, TCSBRK succeeds */
    run_test("hello339"); /* TCXONC (tcflow) on the console tty: valid selectors succeed, others EINVAL */
    run_test("hello340"); /* TCP bind with SO_REUSEADDR: shareable only when both set it and the holder is not listening */
    run_test("hello341"); /* a full loopback queue does not make sendto or connect fail */
    run_test("hello342"); /* a retransmitted SYN carries the original ISN */
    run_test("hello343"); /* a connect stuck in SYN-SENT keeps its SYN outstanding (no tail loss probe before the handshake) */
    run_test("hello344"); /* an IPv4 and an IPv6 TCP socket may bind and listen on the same port */
    run_test("hello345"); /* a TCP socket keeps the IPv4 address it was bound to: per-address bind, SYN dispatch and getsockname */
    run_test("hello346"); /* TCP connections that differ only in a local address are different connections (lookup and connect 4-tuple) */
    run_test("hello347"); /* a UDP socket keeps the IPv4 address it was bound to: getsockname and the datagram source */
    run_test("hello348"); /* UDP sockets on one port are told apart by their bound IPv4 address: bind conflicts and receive dispatch */
    run_test("hello349"); /* an IPv6 UDP socket keeps the address it was bound to: getsockname and the datagram source */
    run_test("hello350"); /* read and write move a shared open file offset atomically between processes */
    run_test("hello351"); /* a read or write larger than 4 KiB on a shared description covers one contiguous range */
    run_test("hello352"); /* getdents64 moves a shared directory cursor atomically between processes */
    run_test("hello353"); /* aio reads and writes use their own offset and leave the shared file offset alone */
    run_test("hello354"); /* copy_file_range with offset pointers leaves the shared file offset alone */
    run_test("hello355"); /* splice and sendfile with an explicit offset leave the shared file offset alone */
    run_test("hello356"); /* read on a shared mq description moves its offset atomically */
    run_test("hello357"); /* an IPv6 UDP socket's bound address takes part in port conflicts and receiver choice */
    run_test("hello358"); /* an IPv6 UDP datagram leaves from its socket's bound address */
    run_test("hello359"); /* an IPv6 TCP socket's bound address takes part in conflicts, listener choice, lookup and naming */
    run_test("hello360"); /* a link-scoped IPv6 address names its interface */
    run_test("hello361"); /* IPv6 UDP multicast options, membership and local delivery */
    run_test("hello362"); /* IPv4 UDP multicast options, membership and local delivery */
    run_test("hello363"); /* multicast outgoing interface and per-socket send options */
    run_test("hello364"); /* the interface an IPv6 socket is bound to */
    run_test("hello365"); /* the interface an IPv6 datagram leaves through */
    run_test("hello366"); /* connect(AF_UNSPEC) dissolves a UDP association */
    run_test("hello367"); /* the interface an IPv6 TCP connect goes through */
    run_test("hello368"); /* the IPv4 next hop */
    run_test("hello369"); /* a connect whose next hop never answers fails with EHOSTUNREACH */
    run_test("hello370"); /* datagrams and segments to our own IPv4 address go over lo */
    run_test("hello371"); /* IPv4 ping sockets */
    run_test("hello372"); /* ping sockets that share an ident */
    run_test("hello373"); /* net.ipv4.ping_group_range */
    run_test("hello374"); /* IPv6 ping sockets */
    run_test("hello375"); /* IPv4 frames wait for ARP; SIOCGARP/SIOCDARP */
    run_test("hello376"); /* IPv6 frames wait for Neighbor Discovery */
    run_test("hello377"); /* SIOCSARP: permanent and ordinary ARP entries */
    run_test("hello378"); /* /proc/net/arp */
    run_test("hello379"); /* /proc/net and /proc/sys directories */
    run_test("hello380"); /* a full ARP cache still learns a new neighbour */
    run_test("hello381"); /* one IPv6 socket joins 64 multicast groups */
    run_test("hello382"); /* proxy ARP entries (ATF_PUBL) */
    run_test("hello383"); /* net.ipv4.conf.<dev>.proxy_arp sysctls, set by ATF_PUBL netmask 0 */
    run_test("hello384"); /* incomplete IPv4 neighbours (flags 0x0) */
    run_test("hello385"); /* UDP autobind: no port until bind, connect or a send; disconnect gives an auto port up */
    run_test("hello386"); /* a 127/8-bound socket cannot reach out through the NIC */
    run_test("hello387"); /* net.ipv4.conf.<dev>.route_localnet */
    run_test("hello388"); /* 100 UDP sockets at once: the socket table holds 256 */
    run_test("hello389"); /* raw ICMP socket */
    run_test("hello390"); /* ICMP errors for connected UDP and ping sockets */
    run_test("hello391"); /* IPv6 raw ICMPv6 socket */
    run_test("hello392"); /* ICMPv6 errors to UDP/ping sockets */
    run_test("hello393"); /* ICMPv6 error quotes with extension headers */
    run_test("hello394"); /* raw ICMP sockets keep SO_RCVTIMEO */
    run_test("hello395"); /* raw ICMP sockets take IP-level options */
    run_test("hello396"); /* IP_HDRINCL on raw IPv4 sockets */
    run_test("hello397"); /* sendmsg and recvmsg on raw ICMP sockets */
    run_test("hello398"); /* MSG_PEEK on raw ICMP sockets */
    run_test("hello399"); /* ICMP_FILTER on IPv4 raw ICMP sockets */
    run_test("hello400"); /* getsockopt and setsockopt at a level the socket does not know */
    run_test("hello401"); /* IPv4 raw sockets of any protocol */
    run_test("hello402"); /* the IPv4 id of an IP_HDRINCL send */
    run_test("hello403"); /* IPv6 raw sockets of any protocol, IPV6_CHECKSUM */
    run_test("hello404"); /* IPV6_HDRINCL, IPPROTO_RAW, ICMPv6 parameter problem */
    run_test("hello405"); /* ARP NUD: STALE, DELAY, PROBE, FAILED */
    run_test("hello406"); /* ICMP errors for TCP */
    run_test("hello407"); /* TCP_USER_TIMEOUT, ETIMEDOUT once connected */
    run_test("hello408"); /* TCP_SYNCNT, SYN retransmission schedule */
    run_test("hello409"); /* zero-window probes and TCP_USER_TIMEOUT */
    run_test("hello410"); /* IPv6 extension headers on input */
    run_test("hello411"); /* established TCP gives up on time, TCP_RTO_MAX_MS */
    run_test("hello412"); /* accepted TCP connections inherit the listener options */
    run_test("hello413"); /* SYN-ACK retransmissions, tcp_synack_retries */
    run_test("hello414"); /* first RTO from the handshake RTT, 3 s fallback */
    run_test("hello415"); /* TCP_DEFER_ACCEPT */
    run_test("hello416"); /* TCP_NOTSENT_LOWAT */
    run_test("hello417"); /* TCP_LINGER2: orphan FIN_WAIT2 timeout and reset */
    run_test("hello418"); /* IPv4 id and DF of kernel-built headers */
    run_test("hello419"); /* IP_MTU_DISCOVER */
    run_test("hello420"); /* TCP_NOTSENT_LOWAT: a window update wakes the writer */
    run_test("hello421"); /* IPv4 UDP receive control messages */
    run_test("hello422"); /* IPv6 UDP receive control messages */
    run_test("hello423"); /* IPv4 UDP sendmsg control messages */
    run_test("hello424"); /* IPv6 UDP sendmsg control messages */
    run_test("hello425"); /* IPv4 ping socket sendmsg control messages */
    run_test("hello426"); /* IPv4 raw socket sendmsg control messages */
    run_test("hello427"); /* IPv6 raw socket sendmsg control messages */
    run_test("hello428"); /* raw socket recvmsg control messages */
    run_test("hello429"); /* IPv6 ping socket sendmsg control messages */
    run_test("hello430"); /* ping socket recvmsg control messages */
    run_test("hello431"); /* sigsetsize must be 8 (rt_sigpending accepts up to 8) */
    run_test("hello432"); /* SO_SNDTIMEO bounds a blocking TCP connect */
    run_test("hello433"); /* a signal wakes its rt_sigtimedwait waiter at once */
    run_test("hello434"); /* sendmmsg / recvmmsg batch up to 1024; recvmmsg writes the timeout back */
    run_test("hello435"); /* lseek on a terminal is ESPIPE */
    run_test("hello436"); /* ucontext fpregs points at the interrupted FPU state */
    run_test("hello437"); /* pidfd_send_signal reads its siginfo and flags */
    run_test("hello438"); /* madvise MADV_DONTFORK / MADV_DOFORK */
    run_test("hello439"); /* the zero-window probe timer starts from the connection's RTO */
    run_test("hello440"); /* rt_sigaction requires sigsetsize 8 */
    run_test("hello441"); /* F_SETPIPE_SZ / F_GETPIPE_SZ resize a pipe */
    run_test("hello442"); /* signalfd reads pending signals as signalfd_siginfo */
    run_test("hello443"); /* TCP urgent data: MSG_OOB, POLLPRI, exceptfds, SIOCATMARK, SIGURG */
    run_test("hello444"); /* SO_TIMESTAMP(NS) and IP(V6)_RECVORIGDSTADDR control messages */
    run_test("hello445"); /* IP_RECVERR: ICMP errors queued for recvmsg(MSG_ERRQUEUE) */
    run_test("hello446"); /* a signalfd in epoll reports its signals and wakes epoll_wait */
    run_test("hello447"); /* madvise MADV_WIPEONFORK / MADV_KEEPONFORK */
    run_test("hello448"); /* a new pipe holds 64 KiB */
    run_test("hello449"); /* an oversized UDP datagram is EMSGSIZE and a local IP_RECVERR entry */
    run_test("hello450"); /* clone's exit signal, __WCLONE and __WALL */
    run_test("hello451"); /* IPv4 fragment reassembly */
    run_test("hello452"); /* IPv4 UDP datagrams over the MTU are fragmented */
    run_test("hello453"); /* IPv6 fragments: Fragment headers out, reassembly in */
    run_test("hello454"); /* IPv4 ICMP over the MTU: raw and ping sends fragmented, big echo replies */
    run_test("hello455"); /* IPv6 ICMPv6 over the MTU: raw and ping sends fragmented, big echo replies */
    run_test("hello456"); /* a clone child reports with SIGCHLD once its parent has exec'd (parent_exec_id) */
    run_test("hello457"); /* /dev/random and /dev/urandom: whole reads, writes mixed into the generator */
    run_test("hello458"); /* a recvmmsg batch that fails part-way leaves the error pending */
    run_test("hello459"); /* the random generator reseeds from interrupt timing (/proc/randstats) */
    run_test("hello460"); /* pidfd flags, PIDFD_SELF, poll readiness and waitid(P_PIDFD) */
    run_test("hello461"); /* IPV6_DONTFRAG refuses datagrams over the path MTU */
    run_test("hello462"); /* IPv6 flow labels: IPV6_FLOWINFO, IPV6_FLOWINFO_SEND */
    run_test("hello463"); /* net.ipv6.auto_flowlabels */
    run_test("hello464"); /* IPv4 options: IP_RECVOPTS and IP_RETOPTS */
    run_test("hello465"); /* IP_OPTIONS and IP_RETOPTS on a UDP sender */
    run_test("hello466"); /* IPv4 options on raw and ping sockets */
    run_test("hello467"); /* IPv4 options on TCP sockets */
    run_test("hello468"); /* TCP_MAXSEG reports mss_cache */
    run_test("hello469"); /* IP_PKTOPTIONS on TCP sockets */
    run_test("hello470"); /* a pipe counts page-sized buffers */
    run_test("hello471"); /* SO_RCVBUF bounds reassembled datagrams; many reassemble at once */
    run_test("hello472"); /* SO_RCVMARK and SO_RCVPRIORITY */
    run_test("hello473"); /* UDP datagrams come out in arrival order */
    run_test("hello474"); /* SO_RCVBUF, not a fixed count, bounds a UDP socket queue */
    run_test("hello475"); /* SO_RCVBUF, not a fixed count, bounds a raw socket queue */
    run_test("hello476"); /* SO_RCVMARK / SO_RCVPRIORITY / SO_TIMESTAMP on raw sockets */
    run_test("hello477"); /* SO_TIMESTAMP on AF_UNIX sockets */
    run_test("hello478"); /* the IP_RECVERR queue: quote length and SO_RCVBUF */
    run_test("hello479"); /* MADV_DONTFORK / MADV_WIPEONFORK on the brk heap and the stack */
    run_test("hello480"); /* sigreturn takes the FPU image fpregs points at */
    run_test("hello481"); /* /proc/sys/fs/pipe-max-size */
    run_test("hello482"); /* pipe-user-pages-soft/hard */
    run_test("hello483"); /* AF_UNIX per-record receive timestamps */
    run_test("hello484"); /* IPV6_FLOWLABEL_MGR */
    run_test("hello485"); /* TIOCGPGRP only on the controlling terminal */
    run_test("hello486"); /* poll after own SHUT_RD */
    run_test("hello487"); /* getsockopt sweep of SOL_IPV6 / SOL_IP option numbers */
    run_test("hello488"); /* IP_MINTTL / IPV6_MINHOPCOUNT on TCP input */
    run_test("hello489"); /* IP_LOCAL_PORT_RANGE on automatic local ports */
    run_test("hello490"); /* IP_FREEBIND / IPV6_FREEBIND on nonlocal bind */
    run_test("hello491"); /* IP_TRANSPARENT / IPV6_TRANSPARENT on nonlocal bind */
    run_test("hello492"); /* net.ipv4/ipv6.ip_nonlocal_bind */
    run_test("hello493"); /* net.ipv4.ip_local_port_range */
    run_test("hello494"); /* net.ipv4.ip_unprivileged_port_start */
    run_test("hello495"); /* net.ipv4.ip_local_reserved_ports */
    run_test("hello496"); /* IP_MINTTL / IPV6_MINHOPCOUNT for TCP ICMP errors */
    run_test("hello497"); /* TCP bind(port=0) and reserved ports */
    run_test("hello498"); /* CLONE_SIGHAND / CLONE_FS */
    run_test("hello499"); /* IPv6 raw connect scope and route */
    run_test("hello500"); /* multicast membership on raw sockets */
    run_test("hello501"); /* writable /proc/<pid>/comm */
    run_test("hello502"); /* net.ipv4.tcp_notsent_lowat */
    run_test("hello503"); /* /etc/hosts before the resolver */
    run_test("hello504"); /* getnameinfo names addresses from /etc/hosts */
    run_test("hello505"); /* canonical names and aliases from /etc/hosts */
    run_test("hello506"); /* getaddrinfo with AF_INET6 */
    run_test("hello507"); /* getnameinfo with sockaddr_in6 */
    run_test("hello508"); /* gethostbyname2 and multi-address /etc/hosts answers */
    run_test("hello509"); /* gethostbyaddr from /etc/hosts */
    run_test("hello510"); /* gethostbyname_r, gethostbyname2_r, gethostbyaddr_r */
    run_test("hello511"); /* if_nametoindex, if_indextoname and interface-name scopes */
    run_test("hello512"); /* /proc/net/if_inet6 and AI_ADDRCONFIG */
    run_test("hello513"); /* if_nameindex and if_freenameindex */
    run_test("hello514"); /* /etc/resolv.conf nameservers */
    run_test("hello515"); /* system calls writing into untouched stack pages */
    run_test("hello516"); /* system calls reading untouched stack pages */
    run_test("hello517"); /* writev/pwritev from unreadable memory */
    run_test("hello518"); /* /etc/resolv.conf search, domain and ndots */
    run_test("hello519"); /* /etc/resolv.conf timeout and attempts, reply codes */
    run_test("hello520"); /* CNAME chains and several addresses */
    run_test("hello521"); /* reverse DNS (PTR) */
    run_test("hello522"); /* /etc/resolv.conf options rotate */
    run_test("hello523"); /* large DNS answers */
    run_test("hello524"); /* truncated replies and DNS over TCP */
    run_test("hello525"); /* AAAA records */
    run_test("hello526"); /* IPv6 nameservers */
    run_test("hello527"); /* pipe writes into a hole when the pipe holds data */
    run_test("hello528"); /* the hosts line of /etc/nsswitch.conf */
    run_test("hello529"); /* a link-local nameserver with a %scope */
    run_test("hello530"); /* AF_UNSPEC asks A and AAAA together */
    run_test("hello531"); /* options single-request */
    run_test("hello532"); /* loopback has no built-in name */
    run_test("hello533"); /* getaddrinfo without /etc/hosts */
    run_test("hello534"); /* the whole nsswitch.conf is read */
    run_test("hello535"); /* a bad line voids nsswitch.conf */
    run_test("hello536"); /* the database name ends at a blank or a colon */
    run_test("hello537"); /* nsswitch.conf lines have no length limit */
    run_test("hello538"); /* a hosts line has no limit on its sources */
    run_test("hello539"); /* DNS replies over TCP longer than 4096 bytes */
    run_test("hello540"); /* options use-vc sends every query over TCP */
    run_test("hello541"); /* options no-tld-query and a "." search domain */
    run_test("hello542"); /* options edns0 adds an OPT record to every query */
    run_test("hello543"); /* use-vc asks an AF_UNSPEC pair on one TCP connection */
    run_test("hello544"); /* nsswitch.conf merge action */
    run_test("hello545"); /* getnameinfo NI_NOFQDN */
    run_test("hello546"); /* nsswitch.conf myhostname source */
    run_test("hello547"); /* options trust-ad sets the AD bit */
    run_test("hello548"); /* reverse DNS without a resolv.conf nameserver */
    run_test("hello549"); /* SO_PEEK_OFF on AF_UNIX sockets */
    run_test("hello550"); /* SO_PEEK_OFF on UDP sockets */
    run_test("hello551"); /* zero-length UDP datagrams */
    run_test("hello552"); /* zero-byte write() and AF_UNIX sends */
    run_test("hello553"); /* SO_PEEK_OFF on TCP sockets */
    run_test("hello554"); /* SO_PEEK_OFF on raw sockets */
    run_test("hello555"); /* MSG_TRUNC on a TCP recv */
    run_test("hello556"); /* MSG_TRUNC on a TCP recvmsg */
    run_test("hello557"); /* zero-byte sends on a ping socket */
    run_test("hello558"); /* an address on an unconnected AF_UNIX stream or seqpacket socket */
    run_test("hello559"); /* sh -e */
    run_test("hello560"); /* set -e, set +e and ! in the shell */
    run_test("hello561"); /* set -x, set +x and sh -x */
    run_test("hello562"); /* set -u, set +u and sh -u */
    run_test("hello563"); /* sh -s, positional params */
    run_test("hello564"); /* sh FILE args, sh -c args, shift, set -- */
    run_test("hello190"); /* hostile-argument sweep over every system call */
    run_test("hello191"); /* deep hostile-argument sweep (arguments that pass validation) */
    run_test("hello192"); /* stateful hostile-argument sweep (chains of calls on live objects) */
    run_test("hello193"); /* concurrent hostile-argument sweep (threads sharing objects) */

    start_persistent_services();

    run_test("hello9");   /* fork test */
    run_test("hello10");  /* fork+execve test */
    run_test("hello21");  /* ext2 write test — last, slow disk I/O */

    /* The shell remains one-shot. PID 1 stays alive to reap it and supervise
     * only persistent_services after the fixed startup sequence completes. */
    spawn_created("sh");
    for (;;) {
        if (reap_child((int *)0) < 0) {
            /* Nothing left to reap (all services exited and spawn failed):
             * park on a 1 s cadence so PID 1 keeps the reap loop alive
             * without pinning a CPU at 100%. */
            struct timespec idle = { .tv_sec = 1, .tv_nsec = 0 };
            nanosleep(&idle, (void *)0);
        }
    }
}
