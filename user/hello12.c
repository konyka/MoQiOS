#include <stdint.h>

#define SYS_write   1
#define SYS_exit    2
#define SYS_open    9
#define SYS_read   10
#define SYS_close  11

static long syscall1(long n, long a1) {
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n), "D"(a1) : "rcx", "r11", "memory");
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

void _start(void) {
    print("hello12: step 1\n");

    long fd = syscall3(SYS_open, (long)"hello2", 0, 0);
    print("hello12: opened hello2, fd=");
    if (fd >= 0) {
        char buf[4];
        buf[0] = 'f'; buf[1] = 'd'; buf[2] = '0' + (char)fd; buf[3] = '\n';
        syscall3(SYS_write, 1, (long)buf, 3);

        char rbuf[64];
        long n = syscall3(SYS_read, fd, (long)rbuf, 10);
        print("hello12: read ok\n");

        syscall1(SYS_close, fd);
    } else {
        print("hello12: open failed\n");
    }

    print("hello12: step 2\n");

    long fd2 = syscall3(SYS_open, (long)"test.txt", 0x41, 0644);
    print("hello12: opened test.txt O_CREAT, fd=");
    if (fd2 >= 0) {
        char buf2[4];
        buf2[0] = 'f'; buf2[1] = 'd'; buf2[2] = '0' + (char)fd2; buf2[3] = '\n';
        syscall3(SYS_write, 1, (long)buf2, 3);

        print("hello12: about to write\n");
        const char *msg = "Hello from MoQiOS write test!\n";
        long w = syscall3(SYS_write, fd2, (long)msg, 30);
        if (w > 0) {
            print("hello12: write ok\n");
        } else {
            print("hello12: write FAILED\n");
        }
        syscall1(SYS_close, fd2);

        long fd3 = syscall3(SYS_open, (long)"test.txt", 0, 0);
        if (fd3 >= 0) {
            char rbuf[64];
            long n = syscall3(SYS_read, fd3, (long)rbuf, 30);
            if (n > 0) {
                print("hello12: read back ok, data=");
                syscall3(SYS_write, 1, (long)rbuf, (int)n);
            } else {
                print("hello12: read back FAILED\n");
            }
            syscall1(SYS_close, fd3);
        }
    }

    print("hello12: step 3\n");
    syscall3(SYS_exit, 0, 0, 0);
}
