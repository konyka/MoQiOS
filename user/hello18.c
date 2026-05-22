#include <stdint.h>

static long syscall1(long n, long a1) {
    long ret;
    __asm__ volatile("syscall" : "=a"(ret) : "a"(n), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static long syscall2(long n, long a1, long a2) {
    long ret;
    __asm__ volatile("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2) : "rcx", "r11", "memory");
    return ret;
}

static long syscall3(long n, long a1, long a2, long a3) {
    long ret;
    __asm__ volatile("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2), "d"(a3) : "rcx", "r11", "memory");
    return ret;
}

static void print(const char *s) {
    int len = 0;
    while (s[len]) len++;
    syscall3(1, 1, (long)s, len);
}

static void print_num(long n) {
    if (n < 0) { print("-"); n = -n; }
    if (n == 0) { print("0"); return; }
    char buf[20];
    int i = 0;
    while (n > 0) { buf[i++] = '0' + (n % 10); n = n / 10; }
    char out[20];
    for (int j = 0; j < i; j++) out[j] = buf[i - 1 - j];
    out[i] = '\0';
    print(out);
}

__attribute__((naked)) void _start(void) {
    __asm__ volatile(
        "xor %%ebp, %%ebp\n"
        "mov (%%rsp), %%rdi\n"
        "lea 8(%%rsp), %%rsi\n"
        "call main_body\n"
        "mov %%eax, %%edi\n"
        "mov $2, %%eax\n"
        "syscall\n"
        ::: "memory"
    );
}

int main_body(int argc, char **argv) {
    (void)argc;
    (void)argv;

    // Test 1: getcwd initial
    {
        char buf[256];
        for (int i = 0; i < 256; i++) buf[i] = 0;
        long ret = syscall2(109, (long)buf, 256);
        print("getcwd: ret=");
        print_num(ret);
        print(" path=");
        print(buf);
        print("\n");
    }

    // Test 2: chdir to absolute path
    {
        long ret = syscall1(108, (long)"/");
        print("chdir /: ret=");
        print_num(ret);
        print("\n");

        char buf[256];
        for (int i = 0; i < 256; i++) buf[i] = 0;
        syscall2(109, (long)buf, 256);
        print("getcwd after chdir: ");
        print(buf);
        print("\n");
    }

    // Test 3: fstat on stdout (fd=1)
    {
        char statbuf[144];
        for (int i = 0; i < 144; i++) statbuf[i] = 0;
        long ret = syscall2(110, 1, (long)statbuf);
        print("fstat stdout: ret=");
        print_num(ret);
        // Read mode field at offset 24 (u32)
        unsigned int mode = *(unsigned int*)(statbuf + 24);
        print(" mode=0o");
        // Print octal
        char obuf[8];
        int oi = 0;
        unsigned int m = mode;
        for (int d = 0; d < 6; d++) { obuf[oi++] = '0' + (m % 8); m /= 8; }
        for (int d = oi - 1; d >= 0; d--) print((char[]){obuf[d], 0});
        print("\n");
    }

    // Test 4: fstat on a ramdisk file
    {
        long fd = syscall3(9, (long)"hello2", 0, 0);
        print("open hello2: fd=");
        print_num(fd);
        print("\n");
        if (fd >= 0) {
            char statbuf[144];
            for (int i = 0; i < 144; i++) statbuf[i] = 0;
            long ret = syscall2(110, fd, (long)statbuf);
            long size = *(long*)(statbuf + 48);
            print("fstat hello2: ret=");
            print_num(ret);
            print(" size=");
            print_num(size);
            print("\n");
            syscall1(11, fd);
        }
    }

    print("hello18 done\n");
    syscall1(2, 0);
    return 0;
}
