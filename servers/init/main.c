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
 * Behavior contract (mirrors user/init.S):
 *  - "spawned helloN" is printed after every spawn() attempt, whether or
 *    not the spawn succeeded; the spawn return value is never checked.
 *  - Each child is reaped with waitpid(-1, NULL, 0) before the next spawn.
 *  - hello2 additionally passes a status pointer and prints "child exited"
 *    instead of "hello2 done".
 *  - hello13..hello16 print no "done" line after their wait.
 *  - hello6 is never spawned (it blocks on keyboard input); hello11 and
 *    hello28 are built and packed but never part of the auto sequence.
 *  - hello40 runs before hello39; hello9, hello10 and hello21 (slow ext2
 *    write test) run at the very end, after hello44.
 *  - Finally the interactive shell "sh" is spawned and init exits.
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <moqi_syscalls.h>

/* spawn() has no libc wrapper yet (only sh/hello10 used the libc before
 * init), so call the syscall directly through the shared ABI header. */
static long spawn(const char *name) {
    return syscall1(SYS_spawn, (long)name);
}

/* Common case: spawn, announce, reap, announce done. */
static void run_test(const char *name) {
    spawn(name);
    printf("spawned %s\n", name);
    waitpid(-1, (void *)0, 0);
    printf("%s done\n", name);
}

/* hello13..hello16: no "done" line in the original sequence. */
static void run_test_quiet(const char *name) {
    spawn(name);
    printf("spawned %s\n", name);
    waitpid(-1, (void *)0, 0);
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    printf("init (pid %ld) started\n", getpid());
    print("Hello from init!\n");

    /* hello2: the only child reaped with a status pointer, and the only
     * one that prints "child exited" instead of "hello2 done". */
    int status;
    spawn("hello2");
    print("spawned hello2\n");
    waitpid(-1, &status, 0);
    print("child exited\n");

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

    /* First resident system service: drains /dev/kmsg into /tmp/kern.log.
     * Never exits — do not waitpid it. */
    spawn("syslogd");
    /* Device manager: watches the /dev node set (polling today, event
     * hooks when devfs grows them). Also resident — do not waitpid. */
    spawn("devmgr");

    run_test("hello9");   /* fork test */
    run_test("hello10");  /* fork+execve test */
    run_test("hello21");  /* ext2 write test — last, slow disk I/O */

    /* Spawn the interactive shell (runs forever), then exit. If the exit
     * syscall ever returned, park the CPU like the assembly fallback did. */
    spawn("sh");
    exit(0);
    for (;;) __asm__ volatile ("pause");
}
