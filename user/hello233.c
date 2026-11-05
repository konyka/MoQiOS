/* hello233: sleeps about 300 ms and exits 0. hello227 starts it as a slow background job. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/time.h"

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    struct timespec ts = { 0, 300000000L };
    while (nanosleep(&ts, &ts) != 0) {}
    return 0;
}
