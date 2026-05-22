#include <stdint.h>

/* Syscall numbers */
#define SYS_write   1
#define SYS_exit    2
#define SYS_getpid  4
#define SYS_waitpid 6
#define SYS_open    9
#define SYS_read   10
#define SYS_close  11
#define SYS_sigaction 13
#define SYS_pipe   22
#define SYS_dup2   33
#define SYS_fork   57
#define SYS_execve 59
#define SYS_kill   62
#define SYS_getenv 105
#define SYS_setenv 106
#define SYS_listdir 107
#define SYS_chdir   108
#define SYS_getcwd  109

#define SIGINT  2
#define SIG_IGN ((long)1)
#define CTRL_C  0x03

static long syscall0(long n) {
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n) : "rcx", "r11", "memory");
    return ret;
}

static long syscall1(long n, long a1) {
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static long syscall3(long n, long a1, long a2, long a3) {
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2), "d"(a3) : "rcx", "r11", "memory");
    return ret;
}

static long syscall2(long n, long a1, long a2) {
    long ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2) : "rcx", "r11", "memory");
    return ret;
}

/* Utility functions */
static void print(const char *s) {
    int len = 0;
    while (s[len]) len++;
    syscall3(SYS_write, 1, (long)s, len);
}

static void print_num(long n) {
    if (n < 0) { print("-"); n = -n; }
    if (n == 0) { print("0"); return; }
    char buf[20];
    int i = 0;
    while (n > 0) { buf[i++] = '0' + (n % 10); n /= 10; }
    char out[20];
    for (int j = 0; j < i; j++) out[j] = buf[i - 1 - j];
    out[i] = '\0';
    print(out);
}

static int streq(const char *a, const char *b) {
    while (*a && *b) {
        if (*a != *b) return 0;
        a++; b++;
    }
    return *a == *b;
}

static int strlen_s(const char *s) {
    int len = 0;
    while (s[len]) len++;
    return len;
}

/* Read a line from stdin with basic line editing */
static int read_line(char *buf, int max) {
    int pos = 0;
    while (pos < max - 1) {
        long n = syscall3(SYS_read, 0, (long)(buf + pos), 1);
        if (n <= 0) continue;
        char c = buf[pos];
        if (c == '\n') {
            buf[pos] = '\0';
            return pos;
        }
        if (c == CTRL_C) {
            while (pos > 0) { print("\b \b"); pos--; }
            print("^C\n");
            buf[0] = '\0';
            return -1;
        }
        if (c == '\b' || c == 127) {
            if (pos > 0) {
                pos--;
                print("\b \b");
            }
            continue;
        }
        /* Echo character */
        char echo[2] = {c, 0};
        print(echo);
        pos++;
    }
    buf[pos] = '\0';
    return pos;
}

/* Skip leading whitespace */
static const char *skip_spaces(const char *s) {
    while (*s == ' ' || *s == '\t') s++;
    return s;
}

/* Copy a token (command or argument) into dst, return pointer past token */
static const char *copy_token(char *dst, int max, const char *src) {
    src = skip_spaces(src);
    int i = 0;
    while (i < max - 1 && *src && *src != ' ' && *src != '\t' && *src != '|' && *src != '>' && *src != '<' && *src != '\n') {
        dst[i++] = *src++;
    }
    dst[i] = '\0';
    return src;
}

static void do_setenv(const char *kvp) {
    syscall2(SYS_setenv, (long)kvp, 0);
}

static int do_getenv(const char *key, char *val, int max) {
    return (int)syscall3(SYS_getenv, (long)key, (long)val, (long)max);
}

static int expand_vars(const char *src, char *dst, int max) {
    int si = 0, di = 0;
    while (src[si] && di < max - 1) {
        if (src[si] == '$') {
            si++;
            char key[64];
            int ki = 0;
            while (src[si] && ((src[si] >= 'a' && src[si] <= 'z') ||
                   (src[si] >= 'A' && src[si] <= 'Z') ||
                   (src[si] >= '0' && src[si] <= '9') ||
                   src[si] == '_') && ki < 63) {
                key[ki++] = src[si++];
            }
            key[ki] = '\0';
            if (ki > 0) {
                char val[128];
                long vlen = do_getenv(key, val, sizeof(val));
                if (vlen >= 0) {
                    for (int v = 0; v < vlen && di < max - 1; v++) {
                        dst[di++] = val[v];
                    }
                }
            }
        } else {
            dst[di++] = src[si++];
        }
    }
    dst[di] = '\0';
    return di;
}

/* Execute a single command with optional redirections.
   If pipe_fd >= 0, redirect stdout to pipe_fd.
   If pipe_in >= 0, redirect stdin from pipe_in.
   If redir_out != NULL, redirect stdout to that file.
   Never returns in the child (calls execve or exit). */
static void run_command(const char *cmd, int pipe_in, int pipe_out, const char *redir_out) {
    /* Extract command name */
    char name[64];
    const char *p = copy_token(name, sizeof(name), cmd);

    if (name[0] == '\0') {
        syscall1(SYS_exit, 1);
    }

    /* Handle output redirection */
    if (redir_out && redir_out[0]) {
        long fd = syscall3(SYS_open, (long)redir_out, 0x41 /* O_WRONLY|O_CREAT */, 0644);
        if (fd < 0) {
            print("sh: cannot open ");
            print(redir_out);
            print("\n");
            syscall1(SYS_exit, 1);
        }
        syscall3(SYS_dup2, fd, 1, 0);
        syscall1(SYS_close, fd);
    }

    /* Handle pipe input */
    if (pipe_in >= 0) {
        syscall3(SYS_dup2, pipe_in, 0, 0);
        syscall1(SYS_close, pipe_in);
    }

    /* Handle pipe output */
    if (pipe_out >= 0) {
        syscall3(SYS_dup2, pipe_out, 1, 0);
        syscall1(SYS_close, pipe_out);
    }

    char args[8][64];
    const char *argp = p;
    int nargs = 0;
    args[0][0] = '\0';
    for (int i = 0; i < 8; i++) {
        argp = copy_token(args[i], sizeof(args[i]), argp);
        if (args[i][0] == '\0') break;
        nargs++;
    }

    char *argv[9];
    for (int i = 0; i < nargs; i++) argv[i] = args[i];
    argv[nargs] = (void*)0;

    long ret = syscall3(SYS_execve, (long)name, (long)argv, 0);
    /* If execve returns, it failed */
    print("sh: ");
    print(name);
    print(": exec failed\n");
    syscall1(SYS_exit, 127);
}

/* Parse and execute a pipeline: cmd1 | cmd2 | cmd3 ...
   Returns the exit code of the last command. */
static int execute_pipeline(const char *line) {
    /* Find all pipe positions */
    const char *cmds[8];  /* up to 8 commands in a pipeline */
    int ncmds = 0;

    const char *p = line;
    cmds[0] = p;
    ncmds = 1;

    while (*p) {
        if (*p == '|') {
            if (ncmds >= 8) break;
            cmds[ncmds] = p + 1;
            ncmds++;
        }
        p++;
    }

    /* Check for output redirection on the last command */
    const char *redir_out = (void *)0;
    char redir_file[64];
    /* Scan last command for '>' */
    const char *last = cmds[ncmds - 1];
    const char *r = last;
    while (*r) {
        if (*r == '>') {
            r++;
            r = skip_spaces(r);
            copy_token(redir_file, sizeof(redir_file), r);
            redir_out = redir_file;
            /* Truncate last command at '>' */
            /* We need to null-terminate the last command before '>' */
            /* Find the '>' in the original string and overwrite it */
            break;
        }
        r++;
    }

    if (ncmds == 1) {
        /* Single command — no pipes */
        char cmd[64];
        copy_token(cmd, sizeof(cmd), cmds[0]);

        /* Built-in commands */
        if (streq(cmd, "exit")) {
            print("bye\n");
            syscall1(SYS_exit, 0);
        }
        if (streq(cmd, "pid")) {
            print_num(syscall0(SYS_getpid));
            print("\n");
            return 0;
        }
        if (streq(cmd, "help")) {
            print("Commands: exit, pid, echo, ls, cd, pwd, export, env, help, <program>\n");
            return 0;
        }
        if (streq(cmd, "echo")) {
            const char *rest = cmds[0];
            int idx = 0;
            while (rest[idx] && rest[idx] != ' ') idx++;
            while (rest[idx] == ' ') idx++;
            print(rest + idx);
            print("\n");
            return 0;
        }
        if (streq(cmd, "export")) {
            const char *rest = cmds[0];
            int idx = 0;
            while (rest[idx] && rest[idx] != ' ') idx++;
            while (rest[idx] == ' ') idx++;
            if (rest[idx]) {
                do_setenv(rest + idx);
            }
            return 0;
        }
        if (streq(cmd, "env")) {
            print("(use export VAR=value to set)\n");
            return 0;
        }
        if (streq(cmd, "ls")) {
            char lsbuf[4096];
            long n = syscall2(SYS_listdir, (long)lsbuf, sizeof(lsbuf));
            if (n > 0) {
                syscall3(SYS_write, 1, (long)lsbuf, (int)n);
            }
            return 0;
        }
        if (streq(cmd, "cd")) {
            const char *rest = cmds[0];
            int idx = 0;
            while (rest[idx] && rest[idx] != ' ') idx++;
            while (rest[idx] == ' ') idx++;
            if (!rest[idx]) {
                long ret = syscall1(SYS_chdir, (long)"/");
                if (ret < 0) print("cd: failed\n");
            } else {
                long ret = syscall1(SYS_chdir, (long)(rest + idx));
                if (ret < 0) print("cd: failed\n");
            }
            return 0;
        }
        if (streq(cmd, "pwd")) {
            char buf[256];
            for (int i = 0; i < 256; i++) buf[i] = 0;
            long n = syscall2(SYS_getcwd, (long)buf, sizeof(buf));
            if (n > 0) {
                print(buf);
                print("\n");
            } else {
                print("pwd: failed\n");
            }
            return 0;
        }

        /* Fork and exec */
        long pid = syscall0(SYS_fork);
        if (pid < 0) {
            print("sh: fork failed\n");
            return -1;
        }
        if (pid == 0) {
            /* Child */
            run_command(cmds[0], -1, -1, redir_out);
            /* run_command never returns */
        }
        /* Parent: wait for child */
        int status;
        long waited = syscall3(SYS_waitpid, -1, (long)&status, 0);
        return (int)status;
    }

    /* Pipeline: multiple commands connected by pipes */
    int prev_pipe = -1;
    long last_pid = -1;

    for (int i = 0; i < ncmds; i++) {
        int is_last = (i == ncmds - 1);
        int pipefd[2] = {-1, -1};

        /* Create pipe for all but the last command */
        if (!is_last) {
            /* pipe syscall: returns [read_fd, write_fd] via two longs on stack */
            long pfd[2];
            pfd[0] = -1;
            pfd[1] = -1;
            long ret = syscall3(SYS_pipe, (long)pfd, 0, 0);
            if (ret < 0) {
                print("sh: pipe failed\n");
                return -1;
            }
            pipefd[0] = (int)pfd[0];
            pipefd[1] = (int)pfd[1];
        }

        long pid = syscall0(SYS_fork);
        if (pid < 0) {
            print("sh: fork failed\n");
            return -1;
        }

        if (pid == 0) {
            /* Child */
            /* Close unused pipe ends */
            if (prev_pipe >= 0) {
                /* stdin will be replaced by run_command, no need to close here */
            }
            if (!is_last) {
                syscall1(SYS_close, pipefd[0]); /* Close read end in child */
            }

            const char *redir = is_last ? redir_out : (void *)0;
            run_command(cmds[i], prev_pipe, is_last ? -1 : pipefd[1], redir);
        }

        /* Parent */
        if (prev_pipe >= 0) {
            syscall1(SYS_close, prev_pipe);
        }
        if (!is_last) {
            syscall1(SYS_close, pipefd[1]); /* Close write end in parent */
            prev_pipe = pipefd[0];          /* Next command reads from this pipe */
        }

        last_pid = pid;
    }

    /* Wait for all children */
    int status = 0;
    for (int i = 0; i < ncmds; i++) {
        syscall3(SYS_waitpid, -1, (long)&status, 0);
    }

    return status;
}

void _start(void) {
    syscall3(SYS_sigaction, SIGINT, SIG_IGN, 0);

    print("MoQiOS shell\n");

    for (;;) {
        print("> ");
        char line[256];
        int len = read_line(line, sizeof(line));
        if (len < 0) continue;
        if (len == 0) continue;

        char expanded[256];
        expand_vars(line, expanded, sizeof(expanded));

        execute_pipeline(expanded);
    }
}
