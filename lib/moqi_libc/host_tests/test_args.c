/* test_args.c — host unit tests for the crt0 initial-stack parser
 * (argc/argv/envp) and stdlib getenv().
 *
 * Simulates the System V initial process stack that the MoQiOS kernel
 * builds (kernel/proc/user_stack.zig buildUserStack):
 *
 *   sp[0]          = argc
 *   sp[1..argc]    = argv pointers
 *   sp[argc+1]     = NULL (argv terminator)
 *   sp[argc+2..]   = envp pointers, NULL-terminated
 *
 * crt0.c derives envp as &argv[argc + 1]; this test pins that contract.
 */
#include <stdio.h>

#include "../include/crt0.h"

/* environ is defined by crt0.c in freestanding builds; the test supplies
 * its own definition for the linked-in stdlib.c below. */
char **environ;

#define getenv test_getenv
#include "../src/stdlib.c"

static int failures;
#define CHECK(cond) do { \
    if (!(cond)) { \
        printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
        failures++; \
    } \
} while (0)

int main(void) {
    static char s0[] = "hello45";
    static char s1[] = "--child";
    static char s2[] = "beta gamma";
    static char e0[] = "K1=V1";
    static char e1[] = "K2=two";

    /* Fake initial stack: argc=3, two env vars. */
    unsigned long stack[8];
    stack[0] = 3;
    stack[1] = (unsigned long)s0;
    stack[2] = (unsigned long)s1;
    stack[3] = (unsigned long)s2;
    stack[4] = 0; /* argv terminator */
    stack[5] = (unsigned long)e0;
    stack[6] = (unsigned long)e1;
    stack[7] = 0; /* envp terminator */

    long argc = -1;
    char **argv = (void *)0;
    char **envp = (void *)0;
    moqi_parse_initial_stack(stack, &argc, &argv, &envp);

    CHECK(argc == 3);
    CHECK(argv[0] == s0);
    CHECK(argv[1] == s1);
    CHECK(argv[2] == s2);
    CHECK(argv[3] == (char *)0);
    CHECK(envp[0] == e0);
    CHECK(envp[1] == e1);
    CHECK(envp[2] == (char *)0);

    /* Empty environment (what the kernel built before envp support):
     * the slot right after the argv terminator is the envp terminator. */
    stack[5] = 0;
    moqi_parse_initial_stack(stack, &argc, &argv, &envp);
    CHECK(argc == 3);
    CHECK(envp != (char **)0);
    CHECK(envp[0] == (char *)0);

    /* argc == 1: argv[1] is the terminator, envp right behind it. */
    unsigned long stack1[4];
    stack1[0] = 1;
    stack1[1] = (unsigned long)s0;
    stack1[2] = 0;
    stack1[3] = 0;
    moqi_parse_initial_stack(stack1, &argc, &argv, &envp);
    CHECK(argc == 1);
    CHECK(argv[0] == s0);
    CHECK(argv[1] == (char *)0);
    CHECK(envp[0] == (char *)0);

    /* getenv over a controlled environ. */
    static char *test_env[] = { e0, e1, (char *)0 };
    environ = test_env;
    const char *v;
    v = test_getenv("K1");
    CHECK(v != (const char *)0 && v[0] == 'V' && v[1] == '1' && v[2] == 0);
    v = test_getenv("K2");
    CHECK(v != (const char *)0 && v[0] == 't' && v[1] == 'w' && v[2] == 'o' && v[3] == 0);
    CHECK(test_getenv("NOPE") == (const char *)0);
    CHECK(test_getenv("K") == (const char *)0);   /* prefix must not match */
    CHECK(test_getenv("K1X") == (const char *)0); /* nor a longer key */

    /* getenv with an empty environment. */
    static char *empty_env[] = { (char *)0 };
    environ = empty_env;
    CHECK(test_getenv("K1") == (const char *)0);

    if (failures == 0) {
        printf("test_args: OK\n");
        return 0;
    }
    printf("test_args: %d failure(s)\n", failures);
    return 1;
}
