#ifndef MOQIOS_INIT_SPAWN_REPORT_H
#define MOQIOS_INIT_SPAWN_REPORT_H

typedef void (*init_spawn_failure_reporter)(const char *name);

/* SYS_spawn returns a negative errno (e.g. -EAGAIN from the RLIMIT_NPROC
 * preflight) when creation fails; only non-negative tids are real children. */
static int init_spawn_created(long tid, const char *name,
                              init_spawn_failure_reporter report_failure) {
    if (tid < 0) {
        report_failure(name);
        return 0;
    }
    return 1;
}

#endif
