/* hello196: gethostbyname_ipv4() / ipv4_to_text() from moqi_libc, through the real dns_resolve system call.
 * Only names the kernel answers on its own, so it does not depend on a reachable DNS server. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/netdb.h"
#include "../lib/moqi_libc/include/byteorder.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello196:   ok   " : "hello196:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello196: libc hostname resolution\n");

    uint8_t ip[4] = {0xAA, 0xAA, 0xAA, 0xAA};
    char text[16];

    check(gethostbyname_ipv4("localhost", ip) == 0 && ip[0] == 127 && ip[1] == 0 && ip[2] == 0 && ip[3] == 1,
          "localhost resolves to 127.0.0.1");
    check(ipv4_to_text(ip, text, sizeof(text)) == 9 && text[0] == '1' && text[2] == '7' && text[3] == '.' && text[8] == '1' && text[9] == 0,
          "ipv4_to_text formats it as 127.0.0.1");

    check(gethostbyname_ipv4("gateway", ip) == 0 && ip[0] == 10 && ip[1] == 0 && ip[2] == 2 && ip[3] == 2,
          "gateway resolves to 10.0.2.2");

    for (int i = 0; i < 4; i++) ip[i] = 0xAA;
    check(gethostbyname_ipv4("bad name!", ip) == -22 && ip[0] == 0xAA, "a malformed name is EINVAL and leaves the output alone");
    check(gethostbyname_ipv4("", ip) == -2, "an empty name is ENOENT");
    check(gethostbyname_ipv4((const char *)0, ip) == -22, "a NULL name is refused by the wrapper");
    check(gethostbyname_ipv4("localhost", (uint8_t *)0) == -22, "a NULL output is refused by the wrapper");

    uint8_t parsed[4] = {0, 0, 0, 0};
    check(ipv4_from_text("10.0.2.15", parsed) == 1 && parsed[0] == 10 && parsed[1] == 0 && parsed[2] == 2 && parsed[3] == 15,
          "ipv4_from_text parses 10.0.2.15");
    check(ipv4_from_text("10.0.2.015", parsed) == 0 && ipv4_from_text("10.0.2", parsed) == 0, "ipv4_from_text rejects leading zeros and short forms");

    uint8_t sa[16];
    check(resolve_ipv4_sockaddr("0.0.0.0", 9196, sa) == 0 && sa[0] == 2 && sa[1] == 0 && sa[2] == 0x23 && sa[3] == 0xEC,
          "resolve_ipv4_sockaddr builds a sockaddr_in for 0.0.0.0:9196");
    long us = syscall3(117, 2, 2, 0); /* socket(AF_INET, SOCK_DGRAM, 0), MoQiOS number */
    check(us >= 0, "a UDP socket opens");
    check(us >= 0 && syscall3(118, us, (long)sa, 16) == 0, "the kernel accepts the built sockaddr_in in bind()");
    if (us >= 0) syscall1(SYS_close, us);
    uint8_t sb[16];
    check(resolve_ipv4_sockaddr("localhost", 80, sb) == 0 && sb[4] == 127 && sb[7] == 1 && sb[3] == 80,
          "resolve_ipv4_sockaddr resolves a name through dns_resolve");

    check(htons(8080) == 0x901F && ntohs(0x901F) == 8080 && htonl(0x0A000202u) == 0x0202000Au && ntohl(0x0202000Au) == 0x0A000202u,
          "htons/ntohs/htonl/ntohl swap bytes on the target");

    /* tcp_connect_host(): resolve + socket + connect against a loopback listener this test opens itself. */
    {
        uint8_t la[16];
        resolve_ipv4_sockaddr("127.0.0.1", 9197, la);
        long ls = syscall3(SYS_socket, 2, 1, 0);
        check(ls >= 0 && syscall3(SYS_bind, ls, (long)la, 16) == 0 && syscall3(SYS_listen, ls, 4, 0) == 0,
              "a loopback listener opens on 127.0.0.1:9197");
        long cs = tcp_connect_host("localhost", 9197);
        check(cs >= 0, "tcp_connect_host(\"localhost\", 9197) returns a connected socket");
        long peer = -1;
        for (int i = 0; i < 20 && peer < 0; i++) { syscall1(SYS_netpoll, 0); peer = syscall4(SYS_accept4, ls, 0, 0, 0); }
        check(peer >= 0, "the listener accepts that connection");
        if (cs >= 0) syscall1(SYS_close, cs);
        if (peer >= 0) syscall1(SYS_close, peer);
        long bad = tcp_connect_host("bad name!", 9197);
        check(bad == -22, "tcp_connect_host with a malformed name is EINVAL and opens no socket");
        check(tcp_connect_host((const char *)0, 80) == -22, "a NULL host is EINVAL");
        long refused = tcp_connect_host("127.0.0.1", 9198);
        check(refused < 0, "connecting to a port nobody listens on fails");
        if (ls >= 0) syscall1(SYS_close, ls);
    }

    {
        struct hostent *h = gethostbyname("localhost");
        check(h != (struct hostent *)0 && h->h_addrtype == AF_INET && h->h_length == 4 &&
              (uint8_t)h->h_addr_list[0][0] == 127 && (uint8_t)h->h_addr_list[0][3] == 1 && h->h_addr_list[1] == (char *)0,
              "gethostbyname(\"localhost\") returns 127.0.0.1 in a glibc-shaped hostent");
        check(h != (struct hostent *)0 && h->h_name[0] == 'l' && h->h_aliases[0] == (char *)0 && h_errno == 0,
              "its h_name is the name asked for, no aliases, h_errno 0");
        h = gethostbyname("no-such-host.invalid");
        check(h == (struct hostent *)0 && (h_errno == HOST_NOT_FOUND || h_errno == TRY_AGAIN),
              "an unknown name returns NULL with HOST_NOT_FOUND or TRY_AGAIN");
        h = gethostbyname("bad name!");
        check(h == (struct hostent *)0 && h_errno == HOST_NOT_FOUND, "a malformed name is NULL / HOST_NOT_FOUND");
        h = gethostbyname((const char *)0);
        check(h == (struct hostent *)0 && h_errno == HOST_NOT_FOUND, "a NULL name fails cleanly instead of faulting");
    }

    print(failures == 0 ? "hello196: PASS\n" : "hello196: FAIL\n");
    print("hello196 done\n");
    return failures;
}
