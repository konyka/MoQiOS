/* hello287: exit_group ends every thread of the process, and exit()/_exit() from the main thread use it.
 * Measured on the host (build with -DHOST): exit_group(42) from the main thread while another thread spins is reported as 0x2a00
 * and the spinning thread writes nothing afterwards; only the low 8 bits of the status survive (300 -> 44); exit_group from a
 * thread other than the main one ends the main thread too and its status is the one reported; exit(5) from main stops the other
 * threads; a thread that leaves through pthread_exit does not end the process. When the main thread leaves with SYS_exit while
 * another thread runs, the process is reported only after its last thread has exited, with that thread's status (or the status
 * of an exit_group it calls). */
#ifdef HOST
#define _GNU_SOURCE
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static void exit_group_call(int code) { syscall(SYS_exit_group, code); }
static void exit_thread_call(int code) { syscall(SYS_exit, code); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/time.h"
#include "../lib/moqi_libc/include/pthread.h"
static void exit_group_call(int code) { syscall1(SYS_exit_group, code); }
static void exit_thread_call(int code) { syscall1(SYS_exit, code); }
#endif

#ifndef WNOHANG
#define WNOHANG 1
#endif

static int failures;
static char msg[200];
static void check(int ok, const char *w) {
    print(ok ? "hello287:   ok   " : "hello287:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static void nap(int ms) { struct timespec t = { ms / 1000, (ms % 1000) * 1000000L }; nanosleep(&t, 0); }

static int bp[2];
static volatile long ready;
static void *spin(void *a) {
    (void)a;
    ready = 1;
    volatile unsigned long s = 0;
    for (;;) {
        s++;
        if ((s & 0xFFFFF) == 0) write(bp[1], "t", 1);
    }
    return (void *)0;
}
static void *group_exit_33(void *a) {
    (void)a;
    ready = 1;
    exit_group_call(33);
    return (void *)0;
}
static void *leave(void *a) {
    (void)a;
    pthread_exit((void *)7);
    return (void *)0;
}
static void *late_exit_9(void *a) {
    (void)a;
    nap(400);
    write(bp[1], "L", 1);
    exit_thread_call(9);
    return (void *)0;
}
static void *late_group_21(void *a) {
    (void)a;
    nap(400);
    exit_group_call(21);
    return (void *)0;
}
static int drain(void) {
    char b[256];
    int any = 0;
    while (read(bp[0], b, sizeof b) > 0) any = 1;
    return any;
}
static void wait_started(void) {
    for (int i = 0; i < 300; i++) {
        if (drain()) return;
        nap(10);
    }
}
/* Fork a child whose second thread spins; the child's main thread then runs `how`. */
static long spinning_child(int how) {
    long c = fork();
    if (c == 0) {
        pthread_t th;
        pthread_create(&th, (void *)0, spin, (void *)0);
        while (!ready) nap(1);
        nap(20);
        if (how == 0) exit_group_call(42);
        else if (how == 1) exit_group_call(300);
        else exit(5);
        _exit(99);
    }
    wait_started();
    return c;
}

int main(void) {
    int st = 0;
    long r, c;
    pipe2(bp, O_NONBLOCK);

    c = spinning_child(0);
    r = waitpid(c, &st, 0);
    snprintf(msg, sizeof msg, "A: exit_group(42) from the main thread is reported as 0x2a00 (%ld, 0x%x)", r, st);
    check(r == c && st == 0x2a00, msg);
    drain();
    nap(200);
    check(!drain(), "A: and the spinning thread writes nothing afterwards");

    c = spinning_child(1);
    st = 0;
    r = waitpid(c, &st, 0);
    snprintf(msg, sizeof msg, "B: only the low 8 bits survive: exit_group(300) is 0x2c00 (%ld, 0x%x)", r, st);
    check(r == c && st == 0x2c00, msg);
    drain();

    c = fork();
    if (c == 0) {
        pthread_t th;
        pthread_create(&th, (void *)0, group_exit_33, (void *)0);
        for (int i = 0; i < 200; i++) nap(10);
        _exit(99);
    }
    st = 0;
    r = waitpid(c, &st, 0);
    snprintf(msg, sizeof msg, "C: exit_group(33) from another thread ends the main thread too (%ld, 0x%x)", r, st);
    check(r == c && st == 0x2100, msg);

    c = spinning_child(2);
    st = 0;
    r = waitpid(c, &st, 0);
    snprintf(msg, sizeof msg, "D: exit(5) from main is reported as 0x500 (%ld, 0x%x)", r, st);
    check(r == c && st == 0x500, msg);
    drain();
    nap(200);
    check(!drain(), "D: and the other threads stop with it");

    c = fork();
    if (c == 0) {
        pthread_t th;
        void *rv = (void *)0;
        pthread_create(&th, (void *)0, leave, (void *)0);
        pthread_join(th, &rv);
        _exit(rv == (void *)7 ? 6 : 8);
    }
    st = 0;
    r = waitpid(c, &st, 0);
    snprintf(msg, sizeof msg, "E: pthread_exit ends only its thread; the main thread exits with 6 (%ld, 0x%x)", r, st);
    check(r == c && st == 0x600, msg);

    int ok = 0;
    for (int round = 0; round < 40; round++) {
        ready = 0;
        c = spinning_child(0);
        st = 0;
        if (waitpid(c, &st, 0) == c && st == 0x2a00) ok++;
    }
    drain();
    snprintf(msg, sizeof msg, "F: 40 processes in a row whose threads end through exit_group (%d/40)", ok);
    check(ok == 40, msg);

    /* G: the main thread leaves with SYS_exit while another thread runs on. The process is not reported until its last thread
     * has gone, and the status is that thread's. */
    drain();
    c = fork();
    if (c == 0) {
        pthread_t th;
        pthread_create(&th, (void *)0, late_exit_9, (void *)0);
        exit_thread_call(4);
    }
    nap(100);
    r = waitpid(c, &st, WNOHANG);
    snprintf(msg, sizeof msg, "G: the main thread exited but another runs: waitpid(WNOHANG) is 0 (%ld)", r);
    check(r == 0, msg);
    st = 0;
    r = waitpid(c, &st, 0);
    snprintf(msg, sizeof msg, "G: reported once the last thread exits, with its status 9 (%ld, 0x%x)", r, st);
    check(r == c && st == 0x900, msg);
    check(drain(), "G: and that thread ran after the main thread had exited");

    c = fork();
    if (c == 0) {
        pthread_t th;
        pthread_create(&th, (void *)0, late_group_21, (void *)0);
        exit_thread_call(4);
    }
    nap(100);
    r = waitpid(c, &st, WNOHANG);
    snprintf(msg, sizeof msg, "H: the main thread exited first, waitpid(WNOHANG) is 0 (%ld)", r);
    check(r == 0, msg);
    st = 0;
    r = waitpid(c, &st, 0);
    snprintf(msg, sizeof msg, "H: a later exit_group(21) from the other thread is the reported status (%ld, 0x%x)", r, st);
    check(r == c && st == 0x1500, msg);

    print(failures == 0 ? "hello287: PASS\n" : "hello287: FAIL\n");
    return failures;
}
