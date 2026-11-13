/* hello301: a SIGSTOP that lands while a process blocks in a TCP recv or a SysV semop stops it at once (waitpid reports 0x137f),
 * nothing runs while it is stopped, and after SIGCONT (0xffff) the wait goes on and completes when its event arrives. Measured on the
 * host (build with -DHOST): 30/30 rounds for each wait, and 200/200 rounds where the stop is sent a varying moment after the event,
 * so some land as the child goes back into the wait; also under taskset -c 0. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/sem.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static void nap(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }
static long make_pair(int *cli, int *srv) {
    int ls = socket(AF_INET, SOCK_STREAM, 0);
    if (ls < 0) return -1;
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = 0;
    sa.sin_addr.s_addr = htonl(0x7f000001);
    if (bind(ls, (struct sockaddr *)&sa, sizeof sa) != 0 || listen(ls, 4) != 0) { close(ls); return -2; }
    socklen_t sl = sizeof sa;
    getsockname(ls, (struct sockaddr *)&sa, &sl);
    int c = socket(AF_INET, SOCK_STREAM, 0);
    if (c < 0 || connect(c, (struct sockaddr *)&sa, sizeof sa) != 0) { close(ls); return -3; }
    int s = accept(ls, 0, 0);
    close(ls);
    if (s < 0) { close(c); return -4; }
    *cli = c;
    *srv = s;
    return 0;
}
static long sem_new(void) { return semget(IPC_PRIVATE, 1, 0600); }
static long sem_op(long id, short op) {
    struct sembuf b = { 0, op, 0 };
    return semop((int)id, &b, 1);
}
static void sem_gone(long id) { semctl((int)id, 0, IPC_RMID, 0); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/time.h"
static void nap(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }
#define SYS_SOCKET 117
#define SYS_BIND 118
#define SYS_LISTEN 119
#define SYS_CONNECT 124
#define SYS_ACCEPT4 131
#define SYS_NETPOLL 104
/* The loopback stack needs netpoll to move segments. */
static void pump(int ms) {
    for (int i = 0; i < ms / 5; i++) {
        syscall1(SYS_NETPOLL, 0);
        nap(5);
    }
}
static long make_pair(int *cli, int *srv) {
    unsigned char sa[16];
    /* sockaddr_in: family 2 (LE), port big-endian, 127.0.0.1 */
    memset(sa, 0, sizeof sa);
    sa[0] = 2;
    long ls = syscall3(SYS_SOCKET, 2, 1, 0);
    if (ls < 0) return -1;
    unsigned short use_port = (unsigned short)(30000 + (getpid() % 2000));
    sa[2] = (unsigned char)(use_port >> 8);
    sa[3] = (unsigned char)(use_port & 0xff);
    sa[4] = 127; sa[7] = 1;
    if (syscall3(SYS_BIND, ls, (long)sa, 16) != 0) { close((int)ls); return -2; }
    if (syscall3(SYS_LISTEN, ls, 4, 0) != 0) { close((int)ls); return -3; }
    long c = syscall3(SYS_SOCKET, 2, 1, 0);
    long r = syscall3(SYS_CONNECT, c, (long)sa, 16);
    for (int i = 0; i < 100 && r < 0 && r != -106; i++) {
        pump(20);
        r = syscall3(SYS_CONNECT, c, (long)sa, 16);
    }
    long s = -1;
    for (int i = 0; i < 100 && s < 0; i++) {
        syscall1(SYS_NETPOLL, 0);
        s = syscall4(SYS_ACCEPT4, ls, 0, 0, 0);
        if (s < 0) pump(20);
    }
    close((int)ls);
    if ((r < 0 && r != -106) || s < 0) {
        close((int)c);
        if (s >= 0) close((int)s);
        return -4;
    }
    *cli = (int)c;
    *srv = (int)s;
    return 0;
}
static long sem_new(void) { return syscall3(153, 0, 1, 01000 | 0600); }
/* MoQiOS semop takes (semid, sem_num, op) with a plain signed operation. */
static long sem_op(long id, short op) { return syscall3(154, id, 0, (long)op); }
static void sem_gone(long id) { syscall4(155, id, 0, 0 /* IPC_RMID */, 0); }
#endif

#define S_KILL 9
#define S_STOP 19
#define S_CONT 18
#define O_WNOHANG 1
#define O_WUNTRACED 2
#define O_WCONTINUED 8
#define ROUNDS 30
#define RACE_ROUNDS 200

static int failures;
static char what[220];
static void check(int ok, const char *w) {
    print(ok ? "hello301:   ok   " : "hello301:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static int bp[2];
static int drain(void) {
    char b[64];
    int any = 0;
    while (read(bp[0], b, sizeof b) > 0) any = 1;
    return any;
}
static long wait_report(long c, int *st, int opt) {
    long r = 0;
    for (int i = 0; i < 300 && r == 0; i++) {
        r = waitpid(c, st, opt | O_WNOHANG);
        if (r == 0) nap(10);
    }
    return r;
}
static int got_back(void) {
    for (int i = 0; i < 200; i++) {
        if (drain()) return 1;
        nap(5);
    }
    return 0;
}

/* The child blocks in the wait, reports each completion on bp, and blocks again. */
static void child(int kind, long obj, long obj2) {
    char b[16];
    for (;;) {
        long r = 0;
        if (kind == 0) r = read((int)obj2, b, 1);
        else r = sem_op(obj, -1);
        /* read() reports the byte count; semop() reports 0 on success. */
        const int done = kind == 0 ? r > 0 : r == 0;
        if (done) {
            /* The semaphore is a one-slot door: put the token back for the next wait. */
            if (kind != 0) sem_op(obj, 1);
            write(bp[1], "r", 1);
        }
    }
}
static void trigger(int kind, long obj, long obj2) {
    if (kind == 0) write((int)obj, "t", 1);
    else sem_op(obj, 1); /* an increment never blocks */
}

static void one(int kind) {
    int sv[2] = { -1, -1 };
    long obj = -1, obj2 = -1;
    const char *name = "";
    if (kind == 0) {
        if (make_pair(&sv[0], &sv[1]) != 0) {
            check(0, "a loopback pair could not be made");
            return;
        }
        obj = sv[0];
        obj2 = sv[1];
        name = "TCP recv";
    } else {
        obj = sem_new();
        if (obj >= 0) {
            /* Start with no token: the first trigger hands one over, as do all later ones. */
#ifdef HOST
            semctl((int)obj, 0, SETVAL, 0);
#else
            syscall4(155, obj, 0, 16 /* IPC_SETVAL */, 0);
#endif
        }
        if (obj < 0) {
            check(0, "semget failed");
            return;
        }
        obj2 = obj;
        name = "SysV semop";
    }
    drain();
    int st = 0;
    long c = fork();
    if (c == 0) child(kind, obj, obj2);
    int stops = 0, quiet = 0, conts = 0, back = 0;
    trigger(kind, obj, obj2);
    int started = got_back();
    for (int round = 0; started && round < ROUNDS; round++) {
        kill(c, S_STOP);
        st = 0;
        if (wait_report(c, &st, O_WUNTRACED) == c && st == 0x137f) stops++;
        else break;
        drain();
        nap(5);
        if (!drain()) quiet++;
        kill(c, S_CONT);
        st = 0;
        if (wait_report(c, &st, O_WCONTINUED) == c && st == 0xffff) conts++;
        else break;
        trigger(kind, obj, obj2);
        if (got_back()) back++;
        else break;
    }
    /* Race: the stop is sent a varying moment after the event, so some land while the child is on its way back into the wait. */
    int rstops = 0;
    for (int round = 0; started && back == ROUNDS && round < RACE_ROUNDS; round++) {
        trigger(kind, obj, obj2);
        for (volatile int k = 0; k < (round % 40) * 500; k++) {}
        kill(c, S_STOP);
        st = 0;
        if (wait_report(c, &st, O_WUNTRACED) == c && st == 0x137f) rstops++;
        else break;
        kill(c, S_CONT);
        st = 0;
        if (wait_report(c, &st, O_WCONTINUED) != c) break;
        if (!got_back()) break;
        drain();
    }
    kill(c, S_KILL);
    waitpid(c, &st, 0);
    snprintf(what, sizeof what, "%s: a SIGSTOP stops the blocked child (%d/%d), nothing runs while stopped (%d), SIGCONT (%d), the wait completes again (%d)",
             name, stops, ROUNDS, quiet, conts, back);
    check(started && stops == ROUNDS && quiet == ROUNDS && conts == ROUNDS && back == ROUNDS, what);
    snprintf(what, sizeof what, "%s: a SIGSTOP sent just after the event, as the child goes back into the wait, stops it (%d/%d)", name, rstops, RACE_ROUNDS);
    check(rstops == RACE_ROUNDS, what);
    if (kind == 0) {
        close(sv[0]);
        close(sv[1]);
    } else sem_gone(obj);
}

int main(void) {
    print("hello301: default stops in TCP recv and SysV semop waits\n");
    if (pipe(bp) != 0) {
        print("hello301: FAIL (pipe)\n");
        return 1;
    }
    fcntl(bp[0], F_SETFL, O_NONBLOCK);
    for (int k = 0; k < 2; k++) one(k);
    print(failures == 0 ? "hello301: PASS\n" : "hello301: FAIL\n");
    return failures;
}
