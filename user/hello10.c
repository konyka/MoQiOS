#include <stdio.h>
#include <unistd.h>

int main(void) {
    print("hello10: fork+execve test\n");

    long pid = fork();
    if (pid < 0) {
        print("hello10: fork failed\n");
        _exit(1);
    }

    if (pid == 0) {
        print("hello10: child calling execve...\n");
        execve("hello11", (void *)0, (void *)0);
        print("hello10: execve failed!\n");
        _exit(1);
    }

    printf("hello10: parent, child=%ld\n", pid);

    int status;
    waitpid(-1, &status, 0);
    print("hello10 done\n");
    return 0;
}
