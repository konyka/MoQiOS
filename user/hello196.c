/* hello196: gethostbyname_ipv4() / ipv4_to_text() from moqi_libc, through the real dns_resolve system call.
 * Only names the kernel answers on its own, so it does not depend on a reachable DNS server. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/netdb.h"

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

    print(failures == 0 ? "hello196: PASS\n" : "hello196: FAIL\n");
    print("hello196 done\n");
    return failures;
}
