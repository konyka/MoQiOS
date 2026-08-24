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
    run_test("hello80");  /* raw unsupported syscall ENOSYS and user-buffer preservation */
     run_test("hello81");  /* bounded TCP sendmmsg/recvmmsg validation */
     run_test("hello82");  /* raw sched_getaffinity current-pid and CPU-0 mask boundary */

    start_persistent_services();

    run_test("hello9");   /* fork test */
    run_test("hello10");  /* fork+execve test */
    run_test("hello21");  /* ext2 write test — last, slow disk I/O */

    /* The shell remains one-shot. PID 1 stays alive to reap it and supervise
     * only persistent_services after the fixed startup sequence completes. */
    spawn_created("sh");
    for (;;) {
        if (reap_child((int *)0) < 0) {
            for (;;) __asm__ volatile ("pause");
        }
    }
}
