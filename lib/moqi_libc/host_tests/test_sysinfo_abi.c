/* test_sysinfo_abi.c -- uname, gethostname, getrandom, getentropy, sysconf and getpagesize (src/sysinfo.c) against a recording
 * system-call stub. Expectations are glibc's on Linux x86-64 (measured with an equivalent program): struct utsname is six 65-byte
 * fields (sysname 0, nodename 65, release 130, version 195, machine 260, domainname 325; 390 bytes); gethostname copies the name and
 * a NUL when it fits and fails with ENAMETOOLONG when the buffer is shorter than name + 1 (including length 0); getentropy is 0 for
 * up to 256 bytes and EIO beyond that without asking the kernel; getrandom passes everything through; sysconf(_SC_PAGESIZE) is
 * 4096, _SC_CLK_TCK 100, _SC_HOST_NAME_MAX 64, and an unknown name is -1 with EINVAL.
 */
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../include/moqi_syscalls.h"

/* The library is compiled under moqi_ names and the header's declarations are not wanted (they would clash with the host's). */
struct moqi_utsname { char sysname[65]; char nodename[65]; char release[65]; char version[65]; char machine[65]; char domainname[65]; };
int moqi_uname(struct moqi_utsname *);
int moqi_gethostname(char *, size_t);
long moqi_getrandom(void *, size_t, unsigned int);
int moqi_getentropy(void *, size_t);
long moqi_sysconf(int);
int moqi_getpagesize(void);

static int bad;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); bad++; } } while (0)

static int errno_slot;
int *__errno_location(void) { return &errno_slot; }

static int ncalls;
static long c_nr, c_a1, c_a2, c_a3;
static long reply;
static long short_first;     /* >0: the first getrandom call returns only this many bytes, later ones the full request */
static int random_calls;
static unsigned char affinity_mask[16];
static unsigned long sysinfo_totalram, sysinfo_freeram;
static unsigned int sysinfo_unit = 1;

long moqi_test_syscall6(long nr, long a1, long a2, long a3, long a4, long a5, long a6) {
    (void)a4; (void)a5; (void)a6;
    ncalls++;
    c_nr = nr; c_a1 = a1; c_a2 = a2; c_a3 = a3;
    if (nr == SYS_uname && reply == 0) {
        struct moqi_utsname *u = (struct moqi_utsname *)a1;
        memset(u, 0, sizeof *u);
        strcpy(u->sysname, "MoQiOS");
        strcpy(u->nodename, "moqios");
        strcpy(u->machine, "x86_64");
    }
    if (nr == SYS_getrandom && short_first > 0) {
        random_calls++;
        long give = random_calls == 1 ? short_first : a2;
        for (long i = 0; i < give; i++) ((unsigned char *)a1)[i] = (unsigned char)(0x40 + random_calls);
        return give;
    }
    if (nr == SYS_sched_getaffinity && reply >= 0) {
        memcpy((void *)a3, affinity_mask, (size_t)a2 < sizeof affinity_mask ? (size_t)a2 : sizeof affinity_mask);
        return reply;
    }
    if (nr == SYS_sysinfo && reply == 0) {
        unsigned char *p = (unsigned char *)a1;
        memset(p, 0, 128);
        memcpy(p + 32, &sysinfo_totalram, 8);
        memcpy(p + 40, &sysinfo_freeram, 8);
        memcpy(p + 104, &sysinfo_unit, 4);
    }
    return reply;
}

static void arm(long r) { ncalls = 0; reply = r; errno_slot = 0; c_nr = c_a1 = c_a2 = c_a3 = -777; }

int main(void) {
    CHECK(sizeof(struct moqi_utsname) == 390 && offsetof(struct moqi_utsname, nodename) == 65 && offsetof(struct moqi_utsname, domainname) == 325);
    CHECK(SYS_uname == 63 && SYS_getrandom == 242 && SYS_sysinfo == 99 && SYS_sched_getaffinity == 227);

    /* uname */
    struct moqi_utsname u;
    arm(0);
    CHECK(moqi_uname(&u) == 0 && c_nr == SYS_uname && c_a1 == (long)&u && strcmp(u.sysname, "MoQiOS") == 0);
    arm(-14);
    CHECK(moqi_uname(&u) == -1 && errno_slot == EFAULT);

    /* gethostname: the name comes from uname's nodename field; it needs room for the NUL as well */
    char h[70];
    arm(0);
    memset(h, '#', sizeof h);
    CHECK(moqi_gethostname(h, sizeof h) == 0 && strcmp(h, "moqios") == 0 && h[7] == '#');
    memset(h, '#', sizeof h);
    CHECK(moqi_gethostname(h, 7) == 0 && strcmp(h, "moqios") == 0);
    memset(h, '#', sizeof h);
    errno_slot = 0;
    CHECK(moqi_gethostname(h, 6) == -1 && errno_slot == ENAMETOOLONG);
    CHECK(h[0] == 'm' && h[5] == 's');             /* glibc fills the buffer with the truncated name; no NUL */
    memset(h, '#', sizeof h);
    errno_slot = 0;
    CHECK(moqi_gethostname(h, 0) == -1 && errno_slot == ENAMETOOLONG && h[0] == '#');
    arm(-14);
    CHECK(moqi_gethostname(h, sizeof h) == -1 && errno_slot == EFAULT);

    /* getrandom: straight to the kernel */
    unsigned char rb[300];
    arm(16);
    CHECK(moqi_getrandom(rb, 16, 0) == 16 && c_nr == SYS_getrandom && c_a1 == (long)rb && c_a2 == 16 && c_a3 == 0);
    arm(300);
    CHECK(moqi_getrandom(rb, 300, 1) == 300 && c_a2 == 300 && c_a3 == 1);
    arm(-22);
    CHECK(moqi_getrandom(rb, 16, 0x1234) == -1 && errno_slot == EINVAL);
    arm(-14);
    CHECK(moqi_getrandom(NULL, 16, 0) == -1 && errno_slot == EFAULT);

    /* getentropy: at most 256 bytes, all or nothing, and a request over the limit never reaches the kernel */
    arm(256);
    CHECK(moqi_getentropy(rb, 256) == 0 && c_nr == SYS_getrandom && c_a2 == 256);
    arm(0);
    CHECK(moqi_getentropy(rb, 257) == -1 && errno_slot == EIO && ncalls == 0);
    arm(100);
    CHECK(moqi_getentropy(rb, 100) == 0 && c_a2 == 100);
    /* a short read from the kernel is not "all": the call goes on for the rest, into the part of the buffer that is still empty */
    memset(rb, 0, sizeof rb);
    arm(0);
    short_first = 30;
    random_calls = 0;
    CHECK(moqi_getentropy(rb, 100) == 0 && random_calls == 2);
    CHECK(rb[0] == 0x41 && rb[29] == 0x41 && rb[30] == 0x42 && rb[99] == 0x42);
    short_first = 0;
    arm(-14);
    CHECK(moqi_getentropy(NULL, 8) == -1 && errno_slot == EFAULT);
    arm(0);
    CHECK(moqi_getentropy(rb, 0) == 0);

    /* getpagesize / sysconf constants */
    CHECK(moqi_getpagesize() == 4096);
    CHECK(moqi_sysconf(30) == 4096);          /* _SC_PAGESIZE */
    CHECK(moqi_sysconf(2) == 100);            /* _SC_CLK_TCK */
    CHECK(moqi_sysconf(180) == 64);           /* _SC_HOST_NAME_MAX */
    CHECK(moqi_sysconf(71) == 256);           /* _SC_LOGIN_NAME_MAX */
    CHECK(moqi_sysconf(3) == 65536);          /* _SC_NGROUPS_MAX */
    CHECK(moqi_sysconf(60) == 1024);          /* _SC_IOV_MAX */
    CHECK(moqi_sysconf(43) == 2048);          /* _SC_LINE_MAX */
    CHECK(moqi_sysconf(0) > 0);               /* _SC_ARG_MAX */
    CHECK(moqi_sysconf(1) > 0);               /* _SC_CHILD_MAX */
    CHECK(moqi_sysconf(4) >= 64);             /* _SC_OPEN_MAX */
    errno_slot = 0;
    CHECK(moqi_sysconf(99999) == -1 && errno_slot == EINVAL);
    errno_slot = 0;
    CHECK(moqi_sysconf(-1) == -1 && errno_slot == EINVAL);

    /* processors: counted from the affinity mask the kernel reports (one bit per CPU) */
    memset(affinity_mask, 0, sizeof affinity_mask);
    affinity_mask[0] = 0x0f;
    arm(8);
    CHECK(moqi_sysconf(84) == 4 && c_nr == SYS_sched_getaffinity && c_a1 == 0);      /* _SC_NPROCESSORS_ONLN */
    affinity_mask[0] = 0xff; affinity_mask[1] = 0x01;
    arm(8);
    CHECK(moqi_sysconf(83) == 9);                                                       /* _SC_NPROCESSORS_CONF */
    affinity_mask[0] = 0x01; affinity_mask[1] = 0;
    arm(8);
    CHECK(moqi_sysconf(84) == 1);
    arm(-22);   /* the kernel refuses: one CPU is the safe answer */
    CHECK(moqi_sysconf(84) == 1);

    /* memory: sysinfo's totalram and freeram in bytes, divided into pages (mem_unit applied) */
    sysinfo_totalram = 1UL << 30; sysinfo_freeram = 1UL << 29; sysinfo_unit = 1;
    arm(0);
    CHECK(moqi_sysconf(85) == (1L << 30) / 4096 && c_nr == SYS_sysinfo);    /* _SC_PHYS_PAGES */
    arm(0);
    CHECK(moqi_sysconf(86) == (1L << 29) / 4096);                           /* _SC_AVPHYS_PAGES */
    sysinfo_totalram = 1UL << 20; sysinfo_unit = 4096;
    arm(0);
    CHECK(moqi_sysconf(85) == (1L << 20));                                   /* mem_unit 4096: the count is in 4 KiB units already */
    arm(-14);
    errno_slot = 0;
    CHECK(moqi_sysconf(85) == -1 && errno_slot == EFAULT);

    if (bad) { fprintf(stderr, "%d check(s) failed\n", bad); return 1; }
    printf("test_sysinfo_abi: ok\n");
    return 0;
}
