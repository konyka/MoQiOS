/* hello232: argument checker started by hello227. argv[1] is a count N; the program exits 0 when it was given exactly N arguments
 * after its name, and every one of them is a run of the same letter (the first byte of the argument) of the same length as
 * argv[2]. It also checks the first environment string. Any mismatch is exit 1. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"

int main(int argc, char **argv, char **envp) {
    if (argc < 3) return 1;
    int want = atoi(argv[1]);
    if (argc != want + 1) return 2;
    size_t len = strlen(argv[2]);
    for (int i = 2; i < argc; i++) {
        if (strlen(argv[i]) != len) return 3;
        for (size_t k = 0; k < len; k++)
            if (argv[i][k] != argv[i][0]) return 4;
    }
    if (want > 0 && envp[0]) {
        size_t el = strlen(envp[0]);
        for (size_t k = 0; k < el; k++)
            if (envp[0][k] != envp[0][0]) return 5;
    }
    return 0;
}
