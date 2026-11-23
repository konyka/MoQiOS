/* hello513: if_nameindex and if_freenameindex (glibc semantics, measured). A the list ends with {0, NULL}, has lo at index 1, and
 * agrees with if_nametoindex and if_indextoname for every entry; B every index appears once, in increasing order; C an interface
 * the kernel reports (eth0 while the NIC is up) is in the list; D 200 rounds of if_nameindex/if_freenameindex leave the heap where
 * it was (malloc'd array and names are all freed); E if_freenameindex(NULL) returns (glibc crashes on it, measured). Measured with
 * -DHOST in `unshare -n` with dummy interfaces (lo, d0 up, d1 down). */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
#define DEV (getenv("D513") ? getenv("D513") : "eth0")
static long has_dev(const char *name) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    struct ifreq r;
    memset(&r, 0, sizeof r);
    strncpy(r.ifr_name, name, IFNAMSIZ - 1);
    long rc = ioctl(s, SIOCGIFINDEX, &r) < 0 ? -errno : r.ifr_ifindex;
    close(s);
    return rc;
}
static void *heap_top(void) { return sbrk(0); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/errno.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/netdb.h"
#define DEV "eth0"
static long has_dev(const char *name) {
    long s = syscall3(SYS_socket, 2, 2, 0);
    unsigned char r[40];
    memset(r, 0, sizeof r);
    strncpy((char *)r, name, 15);
    long rc = syscall3(SYS_ioctl, s, 0x8933, (long)r);
    if (rc == 0) rc = (long)((unsigned)r[16] | (unsigned)r[17] << 8);
    syscall1(SYS_close, s);
    return rc;
}
static void *heap_top(void) { return sbrk(0); }
#endif
static int failures;
static char msg[600];
static void check(int ok, const char *w) {
    print(ok ? "hello513:   ok   " : "hello513:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
int main(void) {
    print("hello513: if_nameindex and if_freenameindex\n");
    errno = 0;
    struct if_nameindex *ni = if_nameindex();
    int e = errno;
    int n = 0, lo1 = 0, agree = 1, ordered = 1, dev_seen = 0;
    char list[200] = "";
    size_t o = 0;
    unsigned prev = 0;
    for (; ni && (ni[n].if_index != 0 || ni[n].if_name); n++) {
        unsigned idx = ni[n].if_index;
        const char *nm = ni[n].if_name;
        if (o < sizeof list) o += (size_t)snprintf(list + o, sizeof list - o, "%s%u:%s", n ? " " : "", idx, nm ? nm : "(null)");
        if (idx == 1 && nm && strcmp(nm, "lo") == 0) lo1 = 1;
        char back[IF_NAMESIZE];
        if (!nm || if_nametoindex(nm) != idx || !if_indextoname(idx, back) || strcmp(back, nm) != 0) agree = 0;
        if (idx <= prev) ordered = 0;
        prev = idx;
        if (nm && strcmp(nm, DEV) == 0) dev_seen = 1;
    }
    int term = ni && ni[n].if_index == 0 && ni[n].if_name == 0;
    snprintf(msg, sizeof msg, "A: %s errno %d, %d entries [%s], terminator %d, lo at 1 %d, names and indexes agree %d (ok 0 >=1 1 1 1)",
             ni ? "ok" : "NULL", e, n, list, term, lo1, agree);
    check(ni && e == 0 && n >= 1 && term && lo1 && agree, msg);
    snprintf(msg, sizeof msg, "B: indexes increasing %d (1)", ordered);
    check(ordered, msg);
    long dv = has_dev(DEV);
    snprintf(msg, sizeof msg, "C: %s SIOCGIFINDEX %ld, in list %d (index > 0, 1)", DEV, dv, dev_seen);
    check(dv > 0 && dev_seen, msg);
    if_freenameindex(ni);

    /* Warm up once so any one-time allocation is out of the way, then the heap must not grow over 200 rounds. */
    if_freenameindex(if_nameindex());
    void *top0 = heap_top();
    int nulls = 0;
    for (int i = 0; i < 200; i++) {
        struct if_nameindex *p = if_nameindex();
        if (!p) nulls++;
        if_freenameindex(p);
    }
    void *top1 = heap_top();
    snprintf(msg, sizeof msg, "D: 200 rounds, failures %d, heap grew %ld bytes (0, 0)", nulls, (long)((char *)top1 - (char *)top0));
    check(nulls == 0 && top1 == top0, msg);
#ifdef HOST
    print("hello513:   .. E skipped on the host: glibc's if_freenameindex(NULL) crashes\n");
    int ok_e = 1;
#else
    if_freenameindex((struct if_nameindex *)0);
    int ok_e = 1;
#endif
    check(ok_e, "E: if_freenameindex(NULL) returns");
    print(failures ? "hello513: FAIL\n" : "hello513: PASS\n");
    return failures ? 1 : 0;
}
