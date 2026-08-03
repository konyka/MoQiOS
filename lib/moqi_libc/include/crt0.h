/* crt0.h — shared initial-stack parser for the MoQiOS process-entry ABI.
 *
 * The kernel (kernel/proc/user_stack.zig buildUserStack) enters every user
 * program with a System V style stack: rsp points at argc, followed by the
 * NULL-terminated argv pointer array, immediately followed by the
 * NULL-terminated envp pointer array, then the auxv pairs. crt0.c's _start
 * hands the raw stack pointer to moqi_parse_initial_stack(); the function is
 * a header-only inline so the host tests can exercise the exact parsing
 * logic the freestanding crt0 uses.
 */
#ifndef MOQI_CRT0_H
#define MOQI_CRT0_H

static inline void moqi_parse_initial_stack(unsigned long *sp,
                                            long *argc_out,
                                            char ***argv_out,
                                            char ***envp_out) {
    long argc = (long)sp[0];
    char **argv = (char **)(sp + 1);
    *argc_out = argc;
    *argv_out = argv;
    *envp_out = argv + argc + 1; /* skip argv pointers + NULL terminator */
}

#endif /* MOQI_CRT0_H */
