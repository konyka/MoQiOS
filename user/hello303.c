/* hello303: the native IPC basics a blocking test needs, on the real kernel (MoQiOS-specific, no Linux counterpart).
 * A a send into the caller's own endpoint is refused: without a send capability for it the kernel answers invalid_endpoint (-1), and
 * after granting itself one it answers would_deadlock (-3); B a child that owns an endpoint and grants the parent a
 * send capability receives every message the parent sends, in order (30 rounds); C a child blocked in moqipc_recv is killed by
 * SIGKILL and reaped promptly; D after the receiver is gone a send to its endpoint fails instead of blocking. E a SIGSTOP that lands
 * while the child blocks in moqipc_recv stops it at once (waitpid reports 0x137f), nothing runs while it is stopped, SIGCONT
 * (0xffff) puts it back in the wait and the next message is received (30 rounds); F 200 rounds where the stop is sent right after a
 * message, so some land as the child goes back into the wait. A stop and continue that wake the wait before a message make
 * moqipc_recv return not_ready (-2); the child's loop receives again, as a server loop would. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/time.h"

#define S_KILL 9
#define S_STOP 19
#define S_CONT 18
#define O_WNOHANG 1
#define O_WUNTRACED 2
#define O_WCONTINUED 8
#define RACE_ROUNDS 200
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

/* Wait up to `ms` for a report matching `opt` (WUNTRACED / WCONTINUED); returns the pid or 0. */
static long reap_within_opt(long c, int *st, int opt, int ms) {
    for (int i = 0; i < ms / 5; i++) {
        long r = waitpid(c, st, opt | O_WNOHANG);
        if (r != 0) return r;
        nap(5);
    }
    return 0;
}
/* Whether the pipe has data to read now (the read end is left blocking). */
static int pending(int fd) {
    int fl = (int)fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    long v = 0;
    long r = read(fd, &v, sizeof v);
    fcntl(fd, F_SETFL, fl);
    return r > 0;
}
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
            /* A stop and continue wake the wait without a message: moqipc_recv reports not_ready (-2), and a receive loop simply
             * receives again, the way an interrupted read is retried. */
            if (r == -2) continue;
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

    /* E: stop and continue the child while it blocks in moqipc_recv; each continue is followed by a message it must receive. */
    int stops = 0, quiet = 0, conts = 0, back = 0;
    for (int round = 0; child_ep > 0 && in_order == ROUNDS && round < ROUNDS; round++) {
        nap(5);
        kill(c, S_STOP);
        int sst = 0;
        if (reap_within_opt(c, &sst, O_WUNTRACED, 3000) == c && sst == 0x137f) stops++;
        else break;
        if (!pending(rp[0])) quiet++;
        kill(c, S_CONT);
        if (reap_within_opt(c, &sst, O_WCONTINUED, 3000) == c && sst == 0xffff) conts++;
        else break;
        m.word[3] = 2000 + round;
        long got = 0;
        if (ep_send(child_ep, &m) == 0 && read(rp[0], &got, sizeof got) == (long)sizeof got && got == 2000 + round) back++;
        else break;
    }
    snprintf(what, sizeof what, "E: a SIGSTOP stops the child blocked in moqipc_recv (%d/%d), nothing runs while stopped (%d), SIGCONT (%d), the next message arrives (%d)",
             stops, ROUNDS, quiet, conts, back);
    check(stops == ROUNDS && quiet == ROUNDS && conts == ROUNDS && back == ROUNDS, what);

    /* F: the stop is sent right after a message, so some land while the child is on its way back into moqipc_recv. */
    int rstops = 0;
    for (int round = 0; back == ROUNDS && round < RACE_ROUNDS; round++) {
        m.word[3] = 3000 + round;
        if (ep_send(child_ep, &m) != 0) break;
        kill(c, S_STOP);
        int sst = 0;
        if (reap_within_opt(c, &sst, O_WUNTRACED, 3000) == c && sst == 0x137f) rstops++;
        else break;
        kill(c, S_CONT);
        if (reap_within_opt(c, &sst, O_WCONTINUED, 3000) != c) break;
        long got = 0;
        if (read(rp[0], &got, sizeof got) != (long)sizeof got || got != 3000 + round) break;
    }
    snprintf(what, sizeof what, "F: a SIGSTOP sent just after a message, as the child goes back into the wait, stops it (%d/%d)", rstops, RACE_ROUNDS);
    check(rstops == RACE_ROUNDS, what);

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
