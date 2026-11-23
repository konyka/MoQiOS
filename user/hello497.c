/* hello497: TCP bind(port=0) allocates immediately (inet_bind -> inet_csk_get_port), so getsockname reports a real port and listen
 * can use it. The allocation and the connecting client's automatic port both honor ip_local_port_range and ip_local_reserved_ports.
 * A: IPv4; B: IPv6. Measured with -DHOST in a new network namespace with lo up. */
#ifdef HOST
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
static void print(const char *s) { fputs(s, stdout); fflush(stdout); }
static long rc(long r) { return r < 0 ? -errno : r; }
static long sock(int f, int t, int p) { return rc(socket(f, t, p)); }
static long bind_(long s, const void *a, int l) { return rc(bind((int)s, a, (socklen_t)l)); }
static long listen_(long s, int n) { return rc(listen((int)s, n)); }
static long connect_(long s, const void *a, int l) { return rc(connect((int)s, a, (socklen_t)l)); }
static long accept_(long s) { return rc(accept((int)s, 0, 0)); }
static long name_(long s, void *a) { socklen_t l = 28; return rc(getsockname((int)s, a, &l)); }
static long open_(const char *p, int wr) { return rc(open(p, wr ? O_WRONLY : O_RDONLY)); }
static long read_(long fd, void *b, int n) { return rc(read((int)fd, b, (size_t)n)); }
static long write_(long fd, const void *b, int n) { return rc(write((int)fd, b, (size_t)n)); }
static void close_(long s) { close((int)s); }
#else
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
static long sock(int f, int t, int p) { return syscall3(117, f, t, p); }
static long bind_(long s, const void *a, int l) { return syscall3(118, s, (long)a, l); }
static long listen_(long s, int n) { return syscall2(119, s, n); }
static long connect_(long s, const void *a, int l) { return syscall3(124, s, (long)a, l); }
static long accept_(long s) { return syscall3(120, s, 0, 0); }
static long name_(long s, void *a) { int l = 28; return syscall3(126, s, (long)a, (long)&l); }
static long open_(const char *p, int wr) { return syscall3(9, (long)p, wr, 0); }
static long read_(long fd, void *b, int n) { return syscall3(10, fd, (long)b, n); }
static long write_(long fd, const void *b, int n) { return syscall3(1, fd, (long)b, n); }
static void close_(long s) { syscall1(11, s); }
#endif
static const char reserved_path[] = "/proc/sys/net/ipv4/ip_local_reserved_ports";
static const char range_path[] = "/proc/sys/net/ipv4/ip_local_port_range";
static int failures;
static char msg[600], saved_reserved[128] = { 0 }, saved_range[64] = { 0 };
static void check(int ok, const char *w) {
    print(ok ? "hello497:   ok   " : "hello497:   FAIL ");
    print(w);
    print("\n");
    if (!ok) failures++;
}
static long write_text(const char *path, const char *s) {
    long fd = open_(path, 1);
    if (fd < 0) return fd;
    long r = write_(fd, s, (int)strlen(s));
    close_(fd);
    return r;
}
static long read_text(const char *path, char *out, int cap) {
    long fd = open_(path, 0);
    if (fd < 0) return fd;
    long n = read_(fd, out, cap - 1);
    close_(fd);
    if (n >= 0) out[n] = 0;
    return n;
}
static void mkaddr(unsigned char *a, int v6) {
    memset(a, 0, 28);
    a[0] = v6 ? 10 : 2;
    if (v6) a[23] = 1; else { a[4] = 127; a[7] = 1; }
}
static int port_of(const unsigned char *a) { return (a[2] << 8) | a[3]; }
static int available(int p) {
    return p >= 52000 && p <= 52010 && p != 52000 && (p < 52002 || p > 52004);
}
static void run_family(int v6) {
    unsigned char listener_addr[28], client_addr[28];
    mkaddr(listener_addr, v6);
    long listener = sock(v6 ? 10 : 2, 1, 0);
    long br = bind_(listener, listener_addr, v6 ? 28 : 16);
    long nr = name_(listener, listener_addr);
    int listener_port = port_of(listener_addr);
    long lr = listen_(listener, 4);
    long client = sock(v6 ? 10 : 2, 1, 0);
    long cr = connect_(client, listener_addr, v6 ? 28 : 16);
    long accepted = cr == 0 ? accept_(listener) : -1000;
    long cn = name_(client, client_addr);
    int client_port = port_of(client_addr);
    snprintf(msg, sizeof msg, "%c: bind0 %ld name %ld port %d listen %ld; connect %ld accept %ld client name %ld port %d (0 0 unreserved 0; 0 >=0 0 unreserved, distinct)",
             v6 ? 'B' : 'A', br, nr, listener_port, lr, cr, accepted, cn, client_port);
    check(br == 0 && nr == 0 && available(listener_port) && lr == 0 && cr == 0 && accepted >= 0 && cn == 0 && available(client_port) && client_port != listener_port, msg);
    close_(accepted); close_(client); close_(listener);
}
int main(void) {
    print("hello497: TCP bind(port=0) allocates outside reserved ports\n");
    long sr = read_text(reserved_path, saved_reserved, sizeof saved_reserved);
    long rg = read_text(range_path, saved_range, sizeof saved_range);
    long wr = write_text(reserved_path, "52000,52002-52004\n");
    long sw = write_text(range_path, "52000 52010\n");
    snprintf(msg, sizeof msg, "setup: saved %ld / %ld, reserved write %ld range write %ld (>=0 >0 18 12)", sr, rg, wr, sw);
    check(sr >= 0 && rg > 0 && wr == 18 && sw == 12, msg);
    run_family(0);
    run_family(1);
    long restored_reserved = write_text(reserved_path, saved_reserved);
    long restored_range = write_text(range_path, saved_range);
    snprintf(msg, sizeof msg, "restore %ld / %ld (%ld / %ld)", restored_reserved, restored_range, sr, rg);
    check(sr >= 0 && rg > 0 && restored_reserved == sr && restored_range == rg, msg);
    print(failures ? "hello497: FAIL\n" : "hello497: PASS\n");
    return failures ? 1 : 0;
}
