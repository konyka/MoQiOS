#include <stdint.h>

#define SYS_write   1
#define SYS_exit    2
#define SYS_fork    57
#define SYS_waitpid 6
#define SYS_getpid  4
#define SYS_getenv  105
#define SYS_setenv  106

static long syscall0(long n) {
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n) : "rcx", "r11", "memory");
    return ret;
}

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

static void print_num(long n) {
    if (n < 0) { print("-"); n = -n; }
    if (n == 0) { print("0"); return; }
    char buf[20];
    int i = 0;
    while (n > 0) { buf[i++] = '0' + (n % 10); n /= 10; }
    char out[20];
    for (int j = 0; j < i; j++) out[j] = buf[i - 1 - j];
    out[i] = '\0';
    print(out);
}

static int do_getenv(const char *key, char *val, int max) {
    return (int)syscall3(SYS_getenv, (long)key, (long)val, (long)max);
}

static long do_setenv(const char *kvp) {
    return syscall2(SYS_setenv, (long)kvp, 0);
}

void _start(void) {
    print("hello16: env var test\n");

    print("hello16: set HOME=/moqi\n");
    do_setenv("HOME=/moqi");

    print("hello16: set USER=root\n");
    do_setenv("USER=root");

    char val[128];
    long len = do_getenv("HOME", val, sizeof(val));
    if (len >= 0) {
        print("hello16: HOME=");
        print(val);
        print("\n");
    } else {
        print("hello16: HOME not found\n");
    }

    len = do_getenv("USER", val, sizeof(val));
    if (len >= 0) {
        print("hello16: USER=");
        print(val);
        print("\n");
    } else {
        print("hello16: USER not found\n");
    }

    len = do_getenv("NONEXISTENT", val, sizeof(val));
    if (len < 0) {
        print("hello16: NONEXISTENT correctly not found\n");
    } else {
        print("hello16: NONEXISTENT should not exist!\n");
    }

    do_setenv("HOME=/updated");
    len = do_getenv("HOME", val, sizeof(val));
    if (len >= 0) {
        print("hello16: HOME updated to ");
        print(val);
        print("\n");
    }

    print("hello16: fork test\n");
    long pid = syscall0(SYS_fork);
    if (pid == 0) {
        len = do_getenv("HOME", val, sizeof(val));
        if (len >= 0) {
            print("hello16: child HOME=");
            print(val);
            print("\n");
        }
        do_setenv("CHILD=yes");
        len = do_getenv("CHILD", val, sizeof(val));
        if (len >= 0) {
            print("hello16: child set CHILD=");
            print(val);
            print("\n");
        }
        syscall1(SYS_exit, 0);
    } else {
        int status;
        syscall3(SYS_waitpid, pid, (long)&status, 0);
        len = do_getenv("CHILD", val, sizeof(val));
        if (len < 0) {
            print("hello16: parent CHILD not set (correct isolation)\n");
        }
    }

    print("hello16 done\n");
    syscall3(SYS_exit, 0, 0, 0);
}
