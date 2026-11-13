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
