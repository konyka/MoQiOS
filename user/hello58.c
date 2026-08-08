// hello58 — 作业控制（job control）验收测试（TDD 目标）。
// 覆盖：setsid/getpgid/getsid、后台读 SIGTTIN（handler→EINTR 与默认→停）、
// TIOCSPGRP 前台切换 + SIGCONT 继续、kill(-pgid) 广播、孤儿进程组 SIGHUP。
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/signal.h"
#include "../lib/moqi_libc/include/moqi_syscalls.h"

#define SYS_ioctl_v 165
#define TIOCSPGRP 0x5410
#define SIGTTIN 21
#define SIGCONT 18
#define SIGHUP 1
#define SIGKILLv 9

static long ioctl2(long fd, long req, long arg) {
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"((long)SYS_ioctl_v), "D"(fd), "S"(req), "d"(arg) : "rcx", "r11", "memory");
    return ret;
}

static int failures;
#define CHECK(cond, name) do { if (!(cond)) { print("hello58: FAIL " name "\n"); failures++; } } while (0)

static int sigttin_seen;
static void on_sigttin(int s) { (void)s; sigttin_seen = 1; }

static volatile int sighup_seen;
static void on_sighup(int s) { (void)s; sighup_seen = 1; }

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello58: start\n");

    /* 1. 新会话：sid==pid, pgid==pid；认领控制终端并把本组设为前台 */
    long sid = setsid();
    long pid = getpid();
    CHECK(sid == pid, "setsid sid==pid");
    CHECK(getpgid(0) == pid, "setsid pgid==pid");
    CHECK(getsid(0) == pid, "getsid==pid");
    unsigned short mainpg = (unsigned short)pid;
    CHECK(ioctl2(0, TIOCSPGRP, (long)&mainpg) == 0, "ctty claim + fg self");

    /* 2. 后台组子进程带 handler 读 fd0 → 立即 EINTR 且 handler 触发 */
    long a = fork();
    if (a == 0) {
        long sp = setpgid(0, 0);
        struct ksigaction sa = { on_sigttin, 0, 0, 0 };
        sigaction(SIGTTIN, &sa, 0);
        char c;
        long r = read(0, &c, 1);
        /* 等 tick/返回路径把 handler 投递掉（有界） */
        struct timespec wts = { 0, 5 * 1000 * 1000 };
        for (int i = 0; i < 200 && !sigttin_seen; i++) nanosleep(&wts, 0);
        _exit(sp != 0 ? 3 : (r != -4 ? 5 : (!sigttin_seen ? 7 : 42)));
    }
    int st = 0;
    waitpid(a, &st, 0);
    CHECK(st == 42, "bg read SIGTTIN handler+EINTR");

    /* 3. 后台组子进程默认动作读 fd0 → 停住不返回；前台化 + SIGCONT 后进入键盘读 */
    long b = fork();
    if (b == 0) {
        long spb = setpgid(0, 0);
        (void)spb;
        char c;
        long r = read(0, &c, 1); // 默认 SIGTTIN：停，直到前台化
        (void)r;
        _exit(43);
    }
    /* 等 B 的 setpgid 生效（轮询其 pgid 字段，消除竞态） */
    {
        struct timespec ps = { 0, 5 * 1000 * 1000 };
        for (int i = 0; i < 400 && getpgid(b) != b; i++) nanosleep(&ps, 0);
    }
    struct timespec ts = { 0, 200 * 1000 * 1000 };
    nanosleep(&ts, 0);
    int st3 = 0;
    long wr = waitpid(b, &st3, 1);
    CHECK(wr == 0, "bg read stops (no early exit)");
    unsigned short bgpg = (unsigned short)b;
    long ior = ioctl2(0, TIOCSPGRP, (long)&bgpg);
    CHECK(ior == 0, "TIOCSPGRP ok");
    kill(b, SIGCONT);
    kill(b, SIGKILLv);
    waitpid(b, &st3, 0);

    /* 4. kill(-pgid) 广播：组内成员全部终止 */
    long e1 = fork();
    if (e1 == 0) {
        setpgid(0, 0);
        while (1) nanosleep(&ts, 0);
    }
    long e2 = fork();
    if (e2 == 0) {
        /* 等 e1 建好组再加入（轮询 pgid，消除竞态） */
        struct timespec ps = { 0, 5 * 1000 * 1000 };
        for (int i = 0; i < 400 && getpgid(e1) != e1; i++) nanosleep(&ps, 0);
        setpgid(0, e1);
        while (1) nanosleep(&ts, 0);
    }
    /* 等 e1/e2 的组都建好 */
    {
        struct timespec ps = { 0, 5 * 1000 * 1000 };
        for (int i = 0; i < 400 && getpgid(e1) != e1; i++) nanosleep(&ps, 0);
        for (int i = 0; i < 400 && getpgid(e2) != e1; i++) nanosleep(&ps, 0);
    }
    long kr = kill(-e1, SIGKILLv);
    CHECK(kr == 0, "kill(-pgid) accepted");
    int sx1 = 0, sx2 = 0;
    long w1 = waitpid(e1, &sx1, 0);
    long w2 = waitpid(e2, &sx2, 0);
    CHECK(w1 == e1 && w2 == e2, "kill(-pgid) both reaped");
    CHECK(sx1 == 128 + SIGKILLv && sx2 == 128 + SIGKILLv, "kill(-pgid) both dead");

    /* 5. 孤儿进程组：子会话长退出 → 成员收 SIGHUP（经继承的 pipe 回报） */
    int pfd[2];
    if (pipe(pfd) != 0) { print("hello58: FAIL pipe\n"); return 1; }
    long d = fork();
    if (d == 0) {
        setsid(); // 子会话长（D 自己有 sid==tid）
        long c = fork();
        if (c == 0) {
            close(pfd[0]);
            struct ksigaction sa = { on_sighup, 0, 0, 0 };
            sigaction(SIGHUP, &sa, 0);
            while (!sighup_seen) nanosleep(&ts, 0);
            char h = 'H';
            syscall3(SYS_write, pfd[1], (long)&h, 1);
            _exit(0);
        }
        close(pfd[0]);
        close(pfd[1]);
        _exit(0); // 会话长退出 → C 成孤儿 → 应收 SIGHUP
    }
    close(pfd[1]);
    /* 等 C 的 SIGHUP 报告（pipe 读在本内核是非阻塞的：空管道返回 0，轮询到有界） */
    char buf[4] = { 0 };
    long rn = 0;
    {
        struct timespec ps = { 0, 5 * 1000 * 1000 };
        for (int i = 0; i < 600 && rn != 1; i++) {
            rn = read(pfd[0], buf, 1);
            if (rn != 1) nanosleep(&ps, 0);
        }
    }
    CHECK(rn == 1 && buf[0] == 'H', "orphan SIGHUP delivered");
    close(pfd[0]);
    int sd = 0;
    waitpid(d, &sd, 0);

    if (failures == 0) {
        print("hello58: PASS\n");
    } else {
        print("hello58: FAIL count=");
        char buf2[24]; int i = 0;
        long v = failures;
        do { buf2[i++] = (char)('0' + v % 10); v /= 10; } while (v);
        while (i > 0) { char c2[2] = { buf2[--i], 0 }; print(c2); }
        print("\n");
        return 1;
    }
    return 0;
}
