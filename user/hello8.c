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

static void print_num(int n) {
    char buf[12];
    int i = 0;
    if (n == 0) { print("0"); return; }
    while (n > 0) { buf[i++] = '0' + (n % 10); n /= 10; }
    char out[12];
    for (int j = 0; j < i; j++) out[j] = buf[i - 1 - j];
    out[i] = '\0';
    print(out);
}

void _start(void) {
    __asm__ volatile (
        "xor %%rbp, %%rbp\n"
        "call main\n"
        "movl $2, %%eax\n"
        "xor %%edi, %%edi\n"
        "syscall\n"
        ::: "memory"
    );
    __builtin_unreachable();
}

int main(void) {
    print("hello8: pipe test\n");

    int pipefd[2];
    long ret = syscall1(22, (long)pipefd);
    if (ret < 0) {
        print("hello8: pipe() failed\n");
        syscall1(2, 1);
    }

    print("hello8: pipe read_fd=");
    print_num(pipefd[0]);
    print(" write_fd=");
    print_num(pipefd[1]);
    print("\n");

    const char *msg = "Hello from pipe!";
    int msglen = 0;
    while (msg[msglen]) msglen++;

    long wret = syscall3(1, pipefd[1], (long)msg, msglen);
    print("hello8: wrote ");
    print_num(wret);
    print(" bytes\n");

    char buf[64];
    for (int i = 0; i < 64; i++) buf[i] = 0;
    long rret = syscall3(10, pipefd[0], (long)buf, 63);
    print("hello8: read ");
    print_num(rret);
    print(" bytes: ");
    if (rret > 0) {
        buf[rret] = '\0';
        print(buf);
    }
    print("\n");

    syscall1(11, pipefd[0]);
    syscall1(11, pipefd[1]);

    print("hello8 done\n");
    return 0;
}
