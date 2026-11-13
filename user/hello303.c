/* hello303: the native IPC basics a blocking test needs, on the real kernel (MoQiOS-specific, no Linux counterpart).
 * A a send into the caller's own endpoint is refused: without a send capability for it the kernel answers invalid_endpoint (-1), and
 * after granting itself one it answers would_deadlock (-3); B a child that owns an endpoint and grants the parent a
 * send capability receives every message the parent sends, in order (30 rounds); C a child blocked in moqipc_recv is killed by
 * SIGKILL and reaped promptly; D after the receiver is gone a send to its endpoint fails instead of blocking. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/time.h"

#define S_KILL 9
#define O_WNOHANG 1
#define ROUNDS 30

static int failures;
static char what[220];
static void check(int ok, const char *w) {
    print(ok ? "hello303:   ok   " : "hello303:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void nap(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }
static long ep_create(void) { return syscall0(297 /* moqipc_create_ep */); }
static long ep_destroy(long e) { return syscall1(298 /* moqipc_destroy_ep */, e); }
static long ep_send(long e, const void *m) { return syscall2(299 /* moqipc_send */, e, (long)m); }
static long ep_recv(long e, void *m) { return syscall2(300 /* moqipc_recv */, e, (long)m); }
static long grant_to(long tid, long e, long rights) { return syscall3(486 /* moqipc_grant_cap_to */, tid, e, rights); }
/* A 256-byte message: sender (filled in by the kernel with the sender's endpoint), reply_to, type and flags take the first 24 bytes;
 * word[3] is the first payload word and carries the sequence number. */
struct msg { long word[32]; };

/* Wait up to `ms` for the child; returns its pid or 0. */
static long reap_within(long c, int *st, int ms) {
    for (int i = 0; i < ms / 5; i++) {
        long r = waitpid(c, st, O_WNOHANG);
        if (r != 0) return r;
        nap(5);
    }
    return 0;
}

int main(void) {
    print("hello303: native IPC send and receive between two processes\n");
    struct msg m;
    memset(&m, 0, sizeof m);

    /* A */
    long own = ep_create();
    long no_cap = own > 0 ? ep_send(own, &m) : 0;
    long granted = own > 0 ? syscall2(311 /* moqipc_grant_cap */, own, 1 /* send */) : -1;
    long self_send = own > 0 ? ep_send(own, &m) : 0;
    snprintf(what, sizeof what, "A: a send into the caller's own endpoint is refused (ep %ld: no capability %ld, after granting %ld: %ld)", own, no_cap,
             granted, self_send);
    check(own > 0 && no_cap == -1 && granted >= 0 && self_send == -3, what);

    /* B: the child owns an endpoint, grants the parent a send capability and reports every message it receives on a pipe. */
    int idp[2], rp[2];
    if (pipe(idp) != 0 || pipe(rp) != 0) {
        print("hello303: FAIL (pipe)\n");
        return 1;
    }
    long c = fork();
    if (c == 0) {
        long mine = ep_create();
        if (mine > 0 && grant_to(getppid(), mine, 1 /* send */) < 0) mine = -1;
        write(idp[1], &mine, sizeof mine);
        struct msg in;
        for (;;) {
            long r = ep_recv(mine, &in);
            long out = r == 0 ? in.word[3] : -1000 + r;
            write(rp[1], &out, sizeof out);
        }
    }
    long child_ep = 0;
    read(idp[0], &child_ep, sizeof child_ep);
    int in_order = 0;
    long first_bad = 0, sent_bad = 0;
    for (int i = 0; i < ROUNDS && child_ep > 0; i++) {
        m.word[3] = 1000 + i;
        long s = ep_send(child_ep, &m);
        long got = 0;
        read(rp[0], &got, sizeof got);
        if (s == 0 && got == 1000 + i) in_order++;
        else if (first_bad == 0) {
            first_bad = got;
            sent_bad = s;
        }
    }
    snprintf(what, sizeof what, "B: the child receives every message in order (%d/%d, child endpoint %ld, first bad send %ld got %ld)", in_order, ROUNDS,
             child_ep, sent_bad, first_bad);
    check(child_ep > 0 && in_order == ROUNDS, what);

    /* C: the child is now blocked in moqipc_recv; SIGKILL must end it. */
    nap(20);
    int st = 0;
    long early = waitpid(c, &st, O_WNOHANG);
    kill(c, S_KILL);
    long reaped = reap_within(c, &st, 2000);
    snprintf(what, sizeof what, "C: a child blocked in moqipc_recv is killed and reaped within 2 s (still there %s, reaped %s, status 0x%x)",
             early == 0 ? "yes" : "no", reaped == c ? "yes" : "no", st);
    check(early == 0 && reaped == c && (st & 0x7f) == S_KILL, what);

    /* D: its endpoint went away with it, so a send fails at once instead of waiting. */
    long late = ep_send(child_ep, &m);
    snprintf(what, sizeof what, "D: a send to the dead receiver's endpoint fails (%ld)", late);
    check(late < 0, what);

    ep_destroy(own);
    print(failures == 0 ? "hello303: PASS\n" : "hello303: FAIL\n");
    return failures;
}
