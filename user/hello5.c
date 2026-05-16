// hello5.c — Test argc/argv passing via Linux ABI stack setup
// Compiled as ELF, uses raw syscalls

#define SYS_WRITE 1
#define SYS_EXIT  2

static long syscall3(long num, long a1, long a2, long a3) {
    long ret;
    __asm__ volatile("syscall" : "=a"(ret) : "a"(num), "D"(a1), "S"(a2), "d"(a3) : "rcx", "r11", "memory");
    return ret;
}

static void print_str(const char *s) {
    int len = 0;
    while (s[len]) len++;
    syscall3(SYS_WRITE, 1, (long)s, len);
}

static void print_dec(long n) {
    char buf[20];
    int i = 0;
    if (n == 0) {
        syscall3(SYS_WRITE, 1, (long)"0", 1);
        return;
    }
    while (n > 0) {
        buf[i++] = '0' + (n % 10);
        n /= 10;
    }
    for (int j = 0; j < i / 2; j++) {
        char tmp = buf[j];
        buf[j] = buf[i - 1 - j];
        buf[i - 1 - j] = tmp;
    }
    syscall3(SYS_WRITE, 1, (long)buf, i);
}

// Naked _start: reads initial stack, then calls main_body
// The stack at _start entry: [argc, argv[0], argv[1], ..., NULL, ...]
__attribute__((naked))
void _start(void) {
    __asm__ volatile(
        "xor %%rbp, %%rbp\n"         // Clear frame pointer (ABI requirement)
        "mov (%%rsp), %%rdi\n"       // rdi = argc
        "lea 8(%%rsp), %%rsi\n"      // rsi = argv
        "call main_body\n"           // call main_body(argc, argv)
        "mov %%rax, %%rdi\n"         // exit code
        "mov $2, %%rax\n"            // SYS_EXIT
        "syscall\n"
        ::: "memory"
    );
}

__attribute__((noreturn))
void main_body(long argc, const char **argv) {
    print_str("hello5: argc=");
    print_dec(argc);
    print_str(" argv0=");
    if (argc > 0 && argv[0]) {
        print_str(argv[0]);
    } else {
        print_str("(null)");
    }
    print_str("\n");

    syscall3(SYS_EXIT, 0, 0, 0);
    __builtin_unreachable();
}
