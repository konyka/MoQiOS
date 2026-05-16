// Minimal C program for MoQiOS — uses raw syscalls
// Syscall #1 = write(fd, buf, count), Syscall #2 = exit(code)

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

void _start(void) {
    // Use a char array to avoid SSE movaps alignment issues
    char msg[24];
    msg[0]='H'; msg[1]='e'; msg[2]='l'; msg[3]='l'; msg[4]='o';
    msg[5]=' '; msg[6]='f'; msg[7]='r'; msg[8]='o'; msg[9]='m';
    msg[10]=' '; msg[11]='h'; msg[12]='e'; msg[13]='l'; msg[14]='l';
    msg[15]='o'; msg[16]='4'; msg[17]='!'; msg[18]='\n';
    syscall3(1, 1, (long)msg, 19);
    syscall1(2, 0);
    while (1) {}
}
