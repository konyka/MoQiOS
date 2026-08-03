// hello45.c — argc/argv/envp end-to-end test through moqi_libc crt0.
// Parent: fork + execve self with marker arg "--child", extra args and an
// environment. Child: crt0 parses the kernel's initial stack into
// main(argc, argv, envp); verify argc, argv contents and getenv().
// Prints "hello45: PASS" (or FAIL) and "hello45 done".

#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv, char **envp) {
    (void)envp; /* getenv() walks environ instead */

    if (argc >= 2 && strcmp(argv[1], "--child") == 0) {
        int ok = 1;
        if (argc != 4) {
            ok = 0;
        } else {
            if (strcmp(argv[0], "hello45") != 0) ok = 0;
            if (strcmp(argv[2], "alpha") != 0) ok = 0;
            if (strcmp(argv[3], "beta gamma") != 0) ok = 0;
        }
        const char *k1 = getenv("K1");
        const char *k2 = getenv("K2");
        if (k1 == (const char *)0 || strcmp(k1, "V1") != 0) ok = 0;
        if (k2 == (const char *)0 || strcmp(k2, "two") != 0) ok = 0;
        if (getenv("NOPE") != (const char *)0) ok = 0;

        printf("hello45 child: argc=%d argv0=%s K1=%s K2=%s\n",
               argc, argv[0],
               k1 ? k1 : "(null)", k2 ? k2 : "(null)");
        printf("hello45: %s\n", ok ? "PASS" : "FAIL");
        print("hello45 done\n");
        return ok ? 0 : 1;
    }

    print("hello45: fork+execve argv/envp test\n");

    long pid = fork();
    if (pid < 0) {
        print("hello45: fork failed\n");
        return 1;
    }

    if (pid == 0) {
        char *cargv[5];
        cargv[0] = "hello45";
        cargv[1] = "--child";
        cargv[2] = "alpha";
        cargv[3] = "beta gamma";
        cargv[4] = (char *)0;

        char *cenvp[3];
        cenvp[0] = "K1=V1";
        cenvp[1] = "K2=two";
        cenvp[2] = (char *)0;

        execve("hello45", cargv, cenvp);
        print("hello45: execve failed!\n");
        _exit(1);
    }

    int status;
    waitpid(-1, &status, 0);
    print("hello45 done\n");
    return 0;
}
