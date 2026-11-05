/* hello230: a stand-in for cat in the test image. Copies standard input to standard output until end of file and exits 0. With the
 * argument "count" it writes nothing and exits with the number of bytes read (low 8 bits). hello227 starts it through the shell
 * to test input redirection. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/string.h"

int main(int argc, char **argv, char **envp) {
    (void)envp;
    int count_only = argc > 1 && strcmp(argv[1], "count") == 0;
    long total = 0;
    char buf[256];
    for (;;) {
        long n = read(0, buf, sizeof buf);
        if (n <= 0) break;
        total += n;
        if (!count_only) write(1, buf, (size_t)n);
    }
    return count_only ? (int)(total & 0xff) : 0;
}
