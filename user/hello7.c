// hello7.c — Reads a file from the FAT32 disk

static long syscall1(long n, long a1) {
    long ret;
    __asm__ volatile("syscall" : "=a"(ret) : "a"(n), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static long syscall3(long n, long a1, long a2, long a3) {
    long ret;
    __asm__ volatile("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2), "d"(a3) : "rcx", "r11", "memory");
    return ret;
}

static void puts(const char *s) {
    int len = 0;
    while (s[len]) len++;
    syscall3(1, 1, (long)s, len);
}

void _start(void) {
    puts("hello7: opening test.txt from disk\n");

    long fd = syscall3(9, (long)"test.txt", 0, 0);
    if (fd < 0) {
        puts("hello7: failed to open test.txt\n");
        syscall1(2, 1);
    }

    char buf[128];
    long n = syscall3(10, fd, (long)buf, sizeof(buf));
    if (n > 0) {
        syscall3(1, 1, (long)"hello7: read: ", 14);
        syscall3(1, 1, (long)buf, n);
    } else {
        puts("hello7: read failed\n");
    }

    syscall3(11, fd, 0, 0);
    puts("hello7 done\n");
    syscall1(2, 0);
    while (1) {}
}
