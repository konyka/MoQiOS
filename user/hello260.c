/* hello260: capget/capset follow the Linux ABI. Measured on Linux (gcc probes): capabilities are numbered CAP_CHOWN 0 ... CAP_SETGID 6, CAP_SETUID 7;
 * the header version picks the data size (V1 one 12-byte set, V2/V3 two sets of low and high words, V1 leaves the high words alone); an unknown
 * version is EINVAL with the preferred version V3 written back into the header (with a NULL data pointer that is the "probe" and returns 0); a
 * negative pid is EINVAL for capget, a pid that does not exist ESRCH, a NULL header EFAULT, a NULL data pointer with a good version 0 for capget
 * and EFAULT for capset; capset is EPERM for another process (pid -1 too), EPERM when it asks for a capability the caller does not hold (new
 * permitted within old permitted, new effective within new permitted), and /proc/<pid>/status shows CapInh, CapPrm, CapEff, CapBnd and CapAmb as
 * 16 hex digits. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/fcntl.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/errno.h"
#include <stdint.h>

#define SYS_CAPGET 306
#define SYS_CAPSET 307
#define V1 0x19980330u
#define V2 0x20071026u
#define V3 0x20080522u
#define CAP_SETGID_BIT (1u << 6)
#define CAP_SETUID_BIT (1u << 7)
#define CAP_SYS_ADMIN_BIT (1u << 21)

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello260:   ok   " : "hello260:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

struct hdr { uint32_t version; int32_t pid; };
struct data { uint32_t eff, perm, inh; };

static long capget_(uint32_t version, int pid, struct data d[2], int with_data) {
    struct hdr h = { version, pid };
    return syscall2(SYS_CAPGET, (long)&h, with_data ? (long)d : 0);
}
static long capset_(uint32_t version, int pid, const struct data d[2], int with_data) {
    struct hdr h = { version, pid };
    return syscall2(SYS_CAPSET, (long)&h, with_data ? (long)d : 0);
}

/* The 16 hex digits after "<key>:\t" in /proc/self/status, or "" when the line is missing. */
static void status_hex(const char *key, char out[20]) {
    static char text[4096];
    out[0] = 0;
    int fd = (int)open("/proc/self/status", O_RDONLY, 0);
    if (fd < 0) return;
    long n = read(fd, text, sizeof text - 1);
    close(fd);
    if (n <= 0) return;
    text[n] = 0;
    char want[24];
    snprintf(want, sizeof want, "\n%s:\t", key);
    char *p = strstr(text, want);
    if (!p) return;
    p += strlen(want);
    size_t k = 0;
    while (p[k] && p[k] != '\n' && k < 19) { out[k] = p[k]; k++; }
    out[k] = 0;
}

static int is_hex16(const char *s) {
    if (strlen(s) != 16) return 0;
    for (int i = 0; i < 16; i++) if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return 0;
    return 1;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello260: capget / capset\n");
    char what[240], hex[20];
    struct data d[2];

    memset(d, 0x77, sizeof d);
    long r = capget_(V3, 0, d, 1);
    snprintf(what, sizeof what, "A: V3 reports CAP_SETGID(6) and CAP_SETUID(7) as Linux numbers (rc %ld, eff %#x perm %#x, high %#x %#x %#x)", r, d[0].eff, d[0].perm, d[1].eff, d[1].perm, d[1].inh);
    check(r == 0 && d[0].eff == (CAP_SETUID_BIT | CAP_SETGID_BIT) && d[0].perm == (CAP_SETUID_BIT | CAP_SETGID_BIT) && d[1].eff == 0 && d[1].perm == 0 && d[1].inh == 0, what);

    status_hex("CapEff", hex);
    snprintf(what, sizeof what, "B: status CapEff is the effective set in 16 hex digits (\"%s\")", hex);
    check(strcmp(hex, "00000000000000c0") == 0, what);
    status_hex("CapPrm", hex);
    check(strcmp(hex, "00000000000000c0") == 0, "B: and CapPrm the permitted set");
    status_hex("CapAmb", hex);
    check(strcmp(hex, "0000000000000000") == 0, "B: CapAmb is empty (ambient capabilities do not exist here)");
    status_hex("CapBnd", hex);
    snprintf(what, sizeof what, "B: CapBnd and CapInh are present as 16 hex digits (\"%s\")", hex);
    char hex2[20];
    status_hex("CapInh", hex2);
    check(is_hex16(hex) && is_hex16(hex2), what);

    struct data d3[2];
    memcpy(d3, d, sizeof d3);
    memset(d, 0x77, sizeof d);
    r = capget_(V2, 0, d, 1);
    check(r == 0 && memcmp(d, d3, sizeof d) == 0, "C: V2 returns the same two sets as V3");

    memset(d, 0x77, sizeof d);
    r = capget_(V1, 0, d, 1);
    snprintf(what, sizeof what, "D: V1 fills one set and leaves the high words alone (rc %ld, high %#x)", r, d[1].eff);
    check(r == 0 && d[0].eff == d3[0].eff && d[0].perm == d3[0].perm && d[1].eff == 0x77777777u && d[1].perm == 0x77777777u && d[1].inh == 0x77777777u, what);

    memset(d, 0x77, sizeof d);
    struct hdr bad = { 0x12345u, 0 };
    r = syscall2(SYS_CAPGET, (long)&bad, (long)d);
    snprintf(what, sizeof what, "E: an unknown version is EINVAL, V3 comes back in the header and the data is untouched (rc %ld, version %#x)", r, bad.version);
    check(r == -EINVAL && bad.version == V3 && d[0].eff == 0x77777777u, what);
    bad.version = 0x12345u;
    bad.pid = 0;
    r = syscall2(SYS_CAPGET, (long)&bad, 0);
    snprintf(what, sizeof what, "F: an unknown version with no data pointer is the probe: 0 and V3 in the header (rc %ld, version %#x)", r, bad.version);
    check(r == 0 && bad.version == V3, what);

    check(capget_(V3, 0, d, 0) == 0, "G: V3 with no data pointer is 0");
    r = capget_(V3, -1, d, 1);
    snprintf(what, sizeof what, "H: a negative pid is EINVAL (rc %ld)", r);
    check(r == -EINVAL, what);
    r = capget_(V3, 99999999, d, 1);
    snprintf(what, sizeof what, "H: a pid that does not exist is ESRCH (rc %ld)", r);
    check(r == -ESRCH, what);
    r = syscall2(SYS_CAPGET, 0, (long)d);
    snprintf(what, sizeof what, "H: a NULL header is EFAULT (rc %ld)", r);
    check(r == -EFAULT, what);
    check(capget_(V3, getppid(), d, 1) == 0, "I: another process's capabilities can be read");

    /* capset */
    memcpy(d, d3, sizeof d);
    check(capset_(V3, 0, d, 1) == 0, "J: capset with the data capget returned is accepted");
    check(capset_(V3, getpid(), d, 1) == 0, "J: and naming the caller's own pid is the same");
    struct data more[2];
    memcpy(more, d3, sizeof more);
    more[0].perm |= CAP_SYS_ADMIN_BIT;
    more[0].eff |= CAP_SYS_ADMIN_BIT;
    r = capset_(V3, 0, more, 1);
    snprintf(what, sizeof what, "J: asking for CAP_SYS_ADMIN, which is not held, is EPERM (rc %ld)", r);
    check(r == -EPERM, what);
    memcpy(more, d3, sizeof more);
    more[0].eff |= CAP_SYS_ADMIN_BIT;
    r = capset_(V3, 0, more, 1);
    check(r == -EPERM, "J: effective outside permitted is EPERM");
    memcpy(more, d3, sizeof more);
    more[1].perm = 1;
    r = capset_(V3, 0, more, 1);
    check(r == -EPERM, "J: a capability in the high word that is not held is EPERM");
    r = capset_(V3, 1, d, 1);
    snprintf(what, sizeof what, "J: another process's pid is EPERM (rc %ld)", r);
    check(r == -EPERM, what);
    check(capset_(V3, -1, d, 1) == -EPERM, "J: pid -1 is EPERM too");
    struct hdr bad2 = { 0x12345u, 0 };
    r = syscall2(SYS_CAPSET, (long)&bad2, (long)d);
    snprintf(what, sizeof what, "J: an unknown version is EINVAL with V3 written back (rc %ld, version %#x)", r, bad2.version);
    check(r == -EINVAL && bad2.version == V3, what);
    check(capset_(V3, 0, d, 0) == -EFAULT, "J: no data pointer is EFAULT");
    check(syscall2(SYS_CAPSET, 0, (long)d) == -EFAULT, "J: a NULL header is EFAULT");

    /* Dropping: keep only CAP_SETUID, then it cannot be taken back. */
    memset(more, 0, sizeof more);
    more[0].eff = more[0].perm = CAP_SETUID_BIT;
    r = capset_(V3, 0, more, 1);
    memset(d, 0x77, sizeof d);
    long g = capget_(V3, 0, d, 1);
    snprintf(what, sizeof what, "K: dropping CAP_SETGID works (capset %ld, capget %ld, eff %#x perm %#x)", r, g, d[0].eff, d[0].perm);
    check(r == 0 && g == 0 && d[0].eff == CAP_SETUID_BIT && d[0].perm == CAP_SETUID_BIT, what);
    status_hex("CapEff", hex);
    snprintf(what, sizeof what, "K: and status follows (CapEff \"%s\")", hex);
    check(strcmp(hex, "0000000000000080") == 0, what);
    memcpy(more, d3, sizeof more);
    r = capset_(V3, 0, more, 1);
    snprintf(what, sizeof what, "K: taking CAP_SETGID back is EPERM (rc %ld)", r);
    check(r == -EPERM, what);

    /* V1 carries one set. */
    memset(more, 0x77, sizeof more);
    memset(&more[0], 0, sizeof more[0]);
    r = capset_(V1, 0, more, 1);
    memset(d, 0x77, sizeof d);
    g = capget_(V3, 0, d, 1);
    snprintf(what, sizeof what, "L: a V1 capset reads only one set (capset %ld) and dropping everything works (eff %#x perm %#x)", r, d[0].eff, d[0].perm);
    check(r == 0 && g == 0 && d[0].eff == 0 && d[0].perm == 0 && d[1].eff == 0 && d[1].perm == 0, what);
    status_hex("CapPrm", hex);
    check(strcmp(hex, "0000000000000000") == 0, "L: status CapPrm is empty");

    print(failures == 0 ? "hello260: PASS\n" : "hello260: FAIL\n");
    return failures;
}
