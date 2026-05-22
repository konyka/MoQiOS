#include <stdint.h>

#define SYS_write   1
#define SYS_exit    2
#define SYS_getpid  4
#define SYS_sigaction 13
#define SYS_sigreturn 15
#define SYS_kill    62
#define SYS_fork    57
#define SYS_waitpid 6

static long syscall1(long n, long a1) {
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static long syscall2(long n, long a1, long a2) {
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2) : "rcx", "r11", "memory");
    return ret;
}

static long syscall3(long n, long a1, long a2, long a3) {
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2), "d"(a3) : "rcx", "r11", "memory");
    return ret;
}

static void print(const char *s) {
    int len = 0;
    while (s[len]) len++;
    syscall3(SYS_write, 1, (long)s, len);
}

static volatile int signal_received;

void sigusr1_handler(int sig) {
    signal_received = sig;
    print("hello13: signal handler called!\n");
}

void _start(void) {
    print("hello13: step 1 - register SIGUSR1 handler\n");

    long ret = syscall2(SYS_sigaction, 10, (long)sigusr1_handler);
    if (ret != 0) {
        print("hello13: sigaction failed\n");
        syscall3(SYS_exit, 1, 0, 0);
    }

    print("hello13: step 2 - fork\n");
    long pid = syscall1(SYS_fork, 0);

    if (pid == 0) {
        long ppid = syscall1(SYS_getpid, 0) - 1;
        print("hello13: child sending SIGUSR1 to parent\n");
        syscall2(SYS_kill, ppid, 10);
        print("hello13: child exiting\n");
        syscall3(SYS_exit, 0, 0, 0);
    } else {
        print("hello13: parent waiting for child\n");
        int status;
        syscall3(SYS_waitpid, pid, (long)&status, 0);

        if (signal_received == 10) {
            print("hello13: SIGUSR1 received correctly!\n");
        } else {
            print("hello13: signal NOT received\n");
        }

        print("hello13: step 3 - done\n");
        syscall3(SYS_exit, 0, 0, 0);
    }
}
