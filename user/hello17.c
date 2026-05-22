// hello17.c — Test argv passing through execve
// First invocation: fork + execve self with extra args
// Second invocation (child): verify argc and argv, print them

#include <stdint.h>

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

// _start reads argc/argv from stack (System V ABI)
__attribute__((naked)) void _start(void) {
    __asm__ volatile(
        "xor %%ebp, %%ebp\n"
        "mov (%%rsp), %%rdi\n"        // argc
        "lea 8(%%rsp), %%rsi\n"       // argv
        "call main_body\n"
        "mov %%eax, %%edi\n"
        "mov $2, %%eax\n"
        "syscall\n"
        ::: "memory"
    );
}

int main_body(int argc, char **argv) {
    if (argc >= 4) {
        print("hello17 child: argc=");
        print_num(argc);
        print("\n");

        print("hello17 child: argv0=");
        print(argv[0]);
        print("\n");

        print("hello17 child: argv1=");
        print(argv[1]);
        print("\n");

        print("hello17 child: argv2=");
        print(argv[2]);
        print("\n");

        print("hello17 done\n");
        syscall1(2, 0);
    }

    // Parent: fork + execve with args
    print("hello17: fork+execve argv test\n");

    long pid = syscall1(57, 0);
    if (pid < 0) {
        print("hello17: fork failed\n");
        syscall1(2, 1);
    }

    if (pid == 0) {
        // Child: execve self with extra arguments
        char *argv_child[5];
        argv_child[0] = "hello17";
        argv_child[1] = "--child";
        argv_child[2] = "test_arg";
        argv_child[3] = "extra";
        argv_child[4] = (char*)0;

        // execve(filename, argv, envp) — syscall #59
        // RDI=filename, RSI=argv, RDX=envp
        long ret;
        __asm__ volatile(
            "syscall"
            : "=a"(ret)
            : "a"(59), "D"((long)"hello17"), "S"((long)argv_child), "d"(0L)
            : "rcx", "r11", "memory"
        );
        // Should not return
        print("hello17: execve failed!\n");
        syscall1(2, 1);
    }

    // Parent: wait for child
    int status;
    syscall3(6, -1, (long)&status, 0);

    // Test uname syscall (#63)
    {
        char ubuf[390];
        for (int i = 0; i < 390; i++) ubuf[i] = 0;
        long ret;
        __asm__ volatile("syscall"
            : "=a"(ret)
            : "a"(63L), "D"((long)ubuf)
            : "rcx", "r11", "memory");
        if (ret == 0) {
            // ubuf[0..64] = sysname
            print("uname: ");
            print(ubuf);
            print("\n");
        } else {
            print("uname: failed\n");
        }
    }

    print("hello17 done\n");
    syscall1(2, 0);
    return 0;
}
