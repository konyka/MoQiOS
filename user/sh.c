#include <stdint.h>

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
    syscall3(1, 1, (long)s, len);
}

static int read_stdin(char *buf, int max) {
    int total = 0;
    while (total < max - 1) {
        long n = syscall3(10, 0, (long)(buf + total), 1);
        if (n <= 0) continue;
        if (buf[total] == '\n') {
            buf[total] = '\0';
            return total;
        }
        if (buf[total] == '\b' || buf[total] == 127) {
            if (total > 0) {
                total--;
                print("\b \b");
            }
            continue;
        }
        char c[2] = {buf[total], 0};
        print(c);
        total++;
    }
    buf[total] = '\0';
    return total;
}

static int streq(const char *a, const char *b) {
    while (*a && *b) {
        if (*a != *b) return 0;
        a++; b++;
    }
    return *a == *b;
}

static void copy_cmd(char *dst, const char *src, int max) {
    while (*src == ' ') src++;
    int i = 0;
    while (i < max - 1 && *src && *src != ' ' && *src != '\n') {
        dst[i++] = *src++;
    }
    dst[i] = '\0';
}

void _start(void) {
    static const char banner[] = "MoQiOS shell\n";
    syscall3(1, 1, (long)banner, 13);

    static const char prompt[] = "> ";
    for (;;) {
        syscall3(1, 1, (long)prompt, 2);
        char line[128];
        int len = read_stdin(line, sizeof(line));
        if (len == 0) continue;

        char cmd[64];
        copy_cmd(cmd, line, sizeof(cmd));
        if (cmd[0] == '\0') continue;

        static const char exit_msg[] = "bye\n";
        if (streq(cmd, "exit")) {
            syscall3(1, 1, (long)exit_msg, 4);
            syscall1(2, 0);
        }

        long pid = syscall1(5, (long)cmd);
        if (pid < 0) {
            print(cmd);
            print(": not found\n");
            continue;
        }

        int status;
        syscall3(6, -1, (long)&status, 0);
    }
}
