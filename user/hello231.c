/* hello231: environment probe started through the shell by hello227. Exits 0 when the variable H231V in its environment equals
 * argv[1], and 1 when it is missing or different. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"

int main(int argc, char **argv, char **envp) {
    (void)envp;
    const char *v = getenv("H231V");
    if (argc < 2) return v ? 2 : 1;
    return v && strcmp(v, argv[1]) == 0 ? 0 : 1;
}
