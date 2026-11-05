#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <dirent.h>
#include <errno.h>

#define CTRL_C  0x03

/* Set by "sh -c": no prompt, no farewell. */
static int g_command_mode;

/* Utility functions */

/* True when standard input is a terminal: the prompt and the echo of typed characters are for people, and only a terminal can have
 * "no data yet" -- on a file or a pipe a read that returns 0 is the end of the input. */
static int g_interactive = 1;

/* Result of read_line at the end of the input (and nothing was read on the line). */
#define LINE_EOF (-2)

/* Read a line from stdin with basic line editing */
static int read_line(char *buf, int max) {
    int pos = 0;
    while (pos < max - 1) {
        long n = read(STDIN_FILENO, buf + pos, 1);
        if (n <= 0) {
            if (!g_interactive) {
                /* End of a script or pipe: a last line without its newline still counts, an empty one means we are done. */
                if (pos == 0) return LINE_EOF;
                buf[pos] = '\0';
                return pos;
            }
            /* EOF/error: yield instead of busy-spinning at 100% CPU */
            yield();
            continue;
        }
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
        if (g_interactive) {
            char echo[2] = {c, 0};
            print(echo);
        }
        pos++;
    }
    buf[pos] = '\0';
    return pos;
}

/* Where a built-in writes: standard output, or the file of a "> file" on its command line. */
static int g_out_fd = STDOUT_FILENO;
static void out_str(const char *s) {
    size_t n = 0;
    while (s[n]) n++;
    write(g_out_fd, s, n);
}

/* Quoting. Before a line is split into list elements, pipeline commands and words, protect_quotes() rewrites it in place and
 * drops the quote characters. Whatever the splitting code would act on (space, tab, ';', '&', '|', '>', '<') is replaced by a
 * control byte 1..7 that no splitter looks for when it is quoted or follows a backslash; unprotect() turns the bytes back when
 * a word is taken out, so the word holds the plain character. The rules:
 *   - inside single quotes everything is literal, '$' included (it becomes LITERAL_DOLLAR so no variable is expanded);
 *   - inside double quotes '$' is still expanded (QUOTED_DOLLAR, whose value stays protected), and a backslash before '\\', '"'
 *     or '$' makes that character literal; before any other character the backslash stays;
 *   - outside quotes a backslash makes the next character literal and is dropped (a lone backslash at the end stays);
 *   - an unterminated quote runs to the end of the line, and "" on its own makes no word.
 * A control byte 1..7, 14 or 8 typed on the line is indistinguishable from a protected character. */
static const char PROTECTED_CHARS[] = " \t;&|><";

/* A '$' inside double quotes is written as this byte, so that expand_vars() knows the variable's value has to be protected too
 * and the value of "$X" stays one word whatever it holds. */
#define QUOTED_DOLLAR '\010'
/* A '$' that must not start an expansion (single quotes, or after a backslash). */
#define LITERAL_DOLLAR '\016'

static char protect_char(char ch) {
    for (const char *c = PROTECTED_CHARS; *c; c++)
        if (*c == ch) return (char)(1 + (c - PROTECTED_CHARS));
    return ch;
}

static char literal_char(char ch) {
    return ch == '$' ? LITERAL_DOLLAR : protect_char(ch);
}

static void protect_quotes(char *line) {
    char *w = line;
    char quote = 0;
    for (const char *r = line; *r; r++) {
        if (quote == '\'') {
            if (*r == '\'') quote = 0;
            else *w++ = literal_char(*r);
        } else if (quote == '"') {
            if (*r == '"') quote = 0;
            else if (*r == '\\' && (r[1] == '\\' || r[1] == '"' || r[1] == '$')) *w++ = literal_char(*++r);
            else *w++ = *r == '$' ? QUOTED_DOLLAR : protect_char(*r);
        } else if (*r == '"' || *r == '\'') {
            quote = *r;
        } else if (*r == '\\' && r[1]) {
            *w++ = literal_char(*++r);
        } else {
            *w++ = *r;
        }
    }
    *w = '\0';
}

/* Turn the control bytes of protect_quotes() back into the characters they stand for, copying src into dst (at most max bytes). */
static void unprotect(char *dst, const char *src, int max) {
    int i = 0;
    for (; *src && i < max - 1; src++, i++) {
        unsigned char c = (unsigned char)*src;
        if (c == LITERAL_DOLLAR) dst[i] = '$';
        else dst[i] = (c >= 1 && c <= (unsigned char)(sizeof(PROTECTED_CHARS) - 1)) ? PROTECTED_CHARS[c - 1] : (char)c;
    }
    dst[i] = '\0';
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
    unprotect(dst, dst, max);
    return src;
}

/* Exit code of the last command that ran, for "$?": the code for a normal exit, 128 + signal for a command killed by one. */
static int g_last_code;

static void set_last_code(int status) {
    if (status < 0) g_last_code = 1;
    else if (status & 0x7f) g_last_code = 128 + (status & 0x7f);
    else g_last_code = (status >> 8) & 0xff;
}

/* Background jobs: "cmd &" starts a pipeline and does not wait for it. g_background is set by execute_list for the element about
 * to run; execute_pipeline then records the pid of its last process in g_last_bg ("$!") and in the job table, and returns 0.
 * Foreground commands wait for their own pids, so a job that ends first is never mistaken for them; "wait" collects jobs. */
#define MAX_JOBS 16
static int g_background;
static long g_last_bg;
static long g_jobs[MAX_JOBS];
static int g_njobs;

static void job_add(long pid) {
    if (g_njobs < MAX_JOBS) g_jobs[g_njobs++] = pid;
}

static void job_remove(long pid) {
    for (int i = 0; i < g_njobs; i++) {
        if (g_jobs[i] == pid) {
            g_jobs[i] = g_jobs[--g_njobs];
            return;
        }
    }
}

/* Collect the jobs that have already finished (so they do not stay zombies at the prompt). */
static void jobs_reap_finished(void) {
    for (int i = 0; i < g_njobs;) {
        int st;
        long r = waitpid(g_jobs[i], &st, 1 /* WNOHANG */);
        if (r != 0) g_jobs[i] = g_jobs[--g_njobs];
        else i++;
    }
}

static int expand_vars(const char *src, char *dst, int max) {
    int si = 0, di = 0;
    while (src[si] && di < max - 1) {
        if ((src[si] == '$' || src[si] == QUOTED_DOLLAR) && (src[si + 1] == '?' || src[si + 1] == '!')) {
            int bang = src[si + 1] == '!';
            si += 2;
            char num[24];
            int n = bang ? snprintf(num, sizeof(num), "%ld", g_last_bg) : snprintf(num, sizeof(num), "%d", g_last_code);
            for (int v = 0; v < n && di < max - 1; v++) dst[di++] = num[v];
        } else if (src[si] == '$' || src[si] == QUOTED_DOLLAR) {
            int quoted = src[si] == QUOTED_DOLLAR;
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
                long vlen = moqi_getenv(key, val, sizeof(val));
                const char *inherited = vlen >= 0 ? (const char *)0 : getenv(key);
                if (inherited) vlen = (long)strlen(inherited);
                if (vlen >= 0) {
                    for (int v = 0; v < vlen && di < max - 1; v++) {
                        char ch = inherited ? inherited[v] : val[v];
                        dst[di++] = quoted ? protect_char(ch) : ch;
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
   If redir_in != NULL, redirect stdin from that file (a missing file ends the command with status 1).
   If redir_out != NULL, redirect stdout to that file, appending when `append` is set and truncating otherwise.
   Never returns in the child (calls execve or exit). */
static void run_command(const char *cmd, int pipe_in, int pipe_out, const char *redir_out, int append, const char *redir_in) {
    /* Extract command name */
    char name[64];
    const char *p = copy_token(name, sizeof(name), cmd);

    if (name[0] == '\0') {
        _exit(1);
    }

    /* Handle input redirection */
    if (redir_in && redir_in[0]) {
        long fd = open(redir_in, O_RDONLY, 0);
        if (fd < 0) {
            print("sh: cannot open ");
            print(redir_in);
            print("\n");
            _exit(1);
        }
        dup2((int)fd, STDIN_FILENO);
        close((int)fd);
    }

    /* Handle output redirection */
    if (redir_out && redir_out[0]) {
        long fd = open(redir_out, O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC), 0644);
        if (fd < 0) {
            print("sh: cannot open ");
            print(redir_out);
            print("\n");
            _exit(1);
        }
        dup2((int)fd, STDOUT_FILENO);
        close((int)fd);
    }

    /* Handle pipe input */
    if (pipe_in >= 0) {
        dup2(pipe_in, STDIN_FILENO);
        close(pipe_in);
    }

    /* Handle pipe output */
    if (pipe_out >= 0) {
        dup2(pipe_out, STDOUT_FILENO);
        close(pipe_out);
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

    /* execve follows Linux semantics: argv[0] is the program name. */
    char *argv[10];
    argv[0] = name;
    for (int i = 0; i < nargs; i++) argv[i + 1] = args[i];
    argv[nargs + 1] = (void*)0;

    execve(name, argv, environ);
    /* If execve returns, it failed */
    print("sh: ");
    print(name);
    print(": exec failed\n");
    _exit(127);
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

    /* Input redirection: "<" in the first command (its text runs up to the first '|') */
    const char *redir_in = (void *)0;
    char in_file[64];
    for (const char *q = cmds[0]; *q && *q != '|'; q++) {
        if (*q == '<') {
            copy_token(in_file, sizeof(in_file), q + 1);
            if (in_file[0]) redir_in = in_file;
            break;
        }
    }

    /* Check for output redirection on the last command */
    const char *redir_out = (void *)0;
    int append = 0;
    char redir_file[64];
    /* Scan last command for '>' */
    const char *last = cmds[ncmds - 1];
    const char *r = last;
    while (*r) {
        if (*r == '>') {
            r++;
            if (*r == '>') {
                append = 1;
                r++;
            }
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

    /* "cmd args > file" (or "< file"): the text before the first '>' or '<' is the command, the file is not one of its arguments. The fork-and-exec path stops
     * each command at '>' by itself (copy_token), but a built-in reads the raw text, so cut it here for them. */
    char single[256];
    if (ncmds == 1) {
        int n = 0;
        while (cmds[0][n] && cmds[0][n] != '>' && cmds[0][n] != '<' && n < (int)sizeof(single) - 1) { single[n] = cmds[0][n]; n++; }
        while (n > 0 && (single[n - 1] == ' ' || single[n - 1] == '\t')) n--;
        single[n] = '\0';
        cmds[0] = single;
    }

    if (ncmds == 1) {
        /* Single command — no pipes */
        char cmd[64];
        copy_token(cmd, sizeof(cmd), cmds[0]);

        /* A built-in that writes output has "> file" honoured: it writes to the file instead of the console. */
        int redirected_fd = -1;
        if (redir_out && redir_out[0] &&
            (strcmp(cmd, "pid") == 0 || strcmp(cmd, "help") == 0 || strcmp(cmd, "echo") == 0 || strcmp(cmd, "ls") == 0 ||
             strcmp(cmd, "pwd") == 0 || strcmp(cmd, "env") == 0)) {
            long rfd = open(redir_out, O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC), 0644);
            if (rfd < 0) {
                print("sh: cannot open ");
                print(redir_out);
                print("\n");
                return 1 << 8;
            }
            redirected_fd = (int)rfd;
            g_out_fd = redirected_fd;
        }

        /* Built-in commands */
        if (strcmp(cmd, "wait") == 0) {
            /* "wait" collects every background job (status 0); "wait PID" collects that one and gives its status, or 127 when it
             * is not a child of the shell. */
            const char *rest = cmds[0];
            int idx = 0;
            while (rest[idx] && rest[idx] != ' ') idx++;
            while (rest[idx] == ' ') idx++;
            if (rest[idx] >= '0' && rest[idx] <= '9') {
                long target = 0;
                for (const char *d = rest + idx; *d >= '0' && *d <= '9'; d++) target = target * 10 + (*d - '0');
                int st = 0;
                if (waitpid(target, &st, 0) < 0) return 127 << 8;
                job_remove(target);
                return st;
            }
            while (g_njobs > 0) {
                int st = 0;
                waitpid(g_jobs[0], &st, 0);
                job_remove(g_jobs[0]);
            }
            return 0;
        }
        if (strcmp(cmd, "exit") == 0) {
            /* "exit N" ends the shell with status N (low 8 bits); without a number it is 0. The farewell is only for people. */
            const char *rest = cmds[0];
            int idx = 0;
            while (rest[idx] && rest[idx] != ' ') idx++;
            while (rest[idx] == ' ') idx++;
            int code = 0;
            for (const char *d = rest + idx; *d >= '0' && *d <= '9'; d++) code = (code * 10 + (*d - '0')) & 0xff;
            if (!g_command_mode) print("bye\n");
            _exit(code);
        }
        if (strcmp(cmd, "pid") == 0) {
            char num[24];
            snprintf(num, sizeof(num), "%ld\n", getpid());
            out_str(num);
            goto builtin_done;
        }
        if (strcmp(cmd, "help") == 0) {
            out_str("Commands: exit, pid, echo, ls, cd, pwd, export, env, wait, help, <program>\n");
            goto builtin_done;
        }
        if (strcmp(cmd, "echo") == 0) {
            const char *rest = cmds[0];
            int idx = 0;
            while (rest[idx] && rest[idx] != ' ') idx++;
            while (rest[idx] == ' ') idx++;
            char text[256];
            unprotect(text, rest + idx, sizeof(text));
            out_str(text);
            out_str("\n");
            goto builtin_done;
        }
        if (strcmp(cmd, "export") == 0) {
            const char *rest = cmds[0];
            int idx = 0;
            while (rest[idx] && rest[idx] != ' ') idx++;
            while (rest[idx] == ' ') idx++;
            if (rest[idx]) {
                char kv[256];
                unprotect(kv, rest + idx, sizeof(kv));
                char *eq = kv;
                while (*eq && *eq != '=') eq++;
                /* The name before '=' (or the whole word when there is none) must look like a variable name. */
                int valid = kv[0] != '\0' && kv[0] != '=' && !(kv[0] >= '0' && kv[0] <= '9');
                for (const char *c = kv; c < eq && valid; c++)
                    if (!((*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') || (*c >= '0' && *c <= '9') || *c == '_')) valid = 0;
                if (!valid) {
                    print("export: not a valid name\n");
                    return 1 << 8;
                }
                if (*eq == '=') {
                    /* The kernel's per-task table is what "$NAME" reads; the C library's environ is what the programs started
                     * from here inherit (it is passed to execve), so both are kept in step. */
                    if (moqi_setenv(kv) < 0) {
                        print("export: cannot set\n");
                        return 1 << 8;
                    }
                    *eq = '\0';
                    setenv(kv, eq + 1, 1);
                }
            }
            return 0;
        }
        if (strcmp(cmd, "env") == 0) {
            for (char **e = environ; e && *e; e++) {
                out_str(*e);
                out_str("\n");
            }
            goto builtin_done;
        }
        if (strcmp(cmd, "ls") == 0) {
            /* "ls" lists the working directory and "ls PATH" lists PATH, one name per line ("." and ".." left out). A path that is
             * not a directory is printed as it was given when it exists; one that cannot be opened is a message and status 1. */
            const char *rest = cmds[0];
            int idx = 0;
            while (rest[idx] && rest[idx] != ' ') idx++;
            while (rest[idx] == ' ') idx++;
            char target[256];
            if (rest[idx]) unprotect(target, rest + idx, sizeof(target));
            else { target[0] = '.'; target[1] = '\0'; }
            DIR *d = opendir(target);
            int ls_status = 0;
            if (d) {
                struct dirent *ent;
                while ((ent = readdir(d)) != (struct dirent *)0) {
                    if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;
                    out_str(ent->d_name);
                    out_str("\n");
                }
                closedir(d);
            } else if (errno == ENOTDIR) {
                out_str(target);
                out_str("\n");
            } else {
                print("ls: cannot open ");
                print(target);
                print("\n");
                ls_status = 1;
            }
            if (redirected_fd >= 0) {
                close(redirected_fd);
                g_out_fd = STDOUT_FILENO;
            }
            return ls_status ? (1 << 8) : 0;
        }
        if (strcmp(cmd, "cd") == 0) {
            const char *rest = cmds[0];
            int idx = 0;
            while (rest[idx] && rest[idx] != ' ') idx++;
            while (rest[idx] == ' ') idx++;
            long ret;
            if (!rest[idx]) {
                ret = chdir("/");
            } else {
                char dir[256];
                unprotect(dir, rest + idx, sizeof(dir));
                ret = chdir(dir);
            }
            if (ret < 0) {
                print("cd: failed\n");
                return 1 << 8;
            }
            return 0;
        }
        if (strcmp(cmd, "pwd") == 0) {
            char buf[256];
            memset(buf, 0, sizeof(buf));
            long n = getcwd(buf, sizeof(buf));
            if (n > 0) {
                out_str(buf);
                out_str("\n");
            } else {
                print("pwd: failed\n");
            }
            goto builtin_done;
        }

        goto not_builtin;
builtin_done:
        if (redirected_fd >= 0) {
            close(redirected_fd);
            g_out_fd = STDOUT_FILENO;
        }
        return 0;
not_builtin:;
        /* Fork and exec */
        long pid = fork();
        if (pid < 0) {
            print("sh: fork failed\n");
            return -1;
        }
        if (pid == 0) {
            /* Child */
            run_command(cmds[0], -1, -1, redir_out, append, redir_in);
            /* run_command never returns */
        }
        /* Parent: a background job is only recorded; a foreground one is waited for by its own pid */
        if (g_background) {
            g_last_bg = pid;
            job_add(pid);
            return 0;
        }
        int status = 0;
        waitpid(pid, &status, 0);
        return (int)status;
    }

    /* Pipeline: multiple commands connected by pipes */
    int prev_pipe = -1;
    long last_pid = -1;
    long pids[8];
    int npids = 0;

    for (int i = 0; i < ncmds; i++) {
        int is_last = (i == ncmds - 1);
        int pipefd[2] = {-1, -1};

        /* Create pipe for all but the last command */
        if (!is_last) {
            /* pipe syscall writes two 32-bit fds (8 bytes total) */
            int pfd[2];
            pfd[0] = -1;
            pfd[1] = -1;
            long ret = pipe(pfd);
            if (ret < 0) {
                print("sh: pipe failed\n");
                return -1;
            }
            pipefd[0] = pfd[0];
            pipefd[1] = pfd[1];
        }

        long pid = fork();
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
                close(pipefd[0]); /* Close read end in child */
            }

            const char *redir = is_last ? redir_out : (void *)0;
            run_command(cmds[i], prev_pipe, is_last ? -1 : pipefd[1], redir, append, i == 0 ? redir_in : (void *)0);
        }

        /* Parent */
        if (prev_pipe >= 0) {
            close(prev_pipe);
        }
        if (!is_last) {
            close(pipefd[1]);       /* Close write end in parent */
            prev_pipe = pipefd[0];  /* Next command reads from this pipe */
        }

        last_pid = pid;
        pids[npids++] = pid;
    }

    if (g_background) {
        g_last_bg = last_pid;
        job_add(last_pid);
        return 0;
    }

    /* Wait for every process of the pipeline by pid; the status is the last command's */
    int status = 0;
    for (int i = 0; i < npids; i++) {
        int st = 0;
        waitpid(pids[i], &st, 0);
        if (i == npids - 1) status = st;
    }

    return status;
}

/* True when a wait status (or a built-in's 0) means the command succeeded: exited normally with code 0. */
static int status_ok(int status) {
    return status >= 0 && (status & 0x7f) == 0 && ((status >> 8) & 0xff) == 0;
}

/* Run a command list: pipelines joined by ';' (always run the next), '&&' (run it only after success) and '||' (only after
 * failure). Evaluated left to right with no precedence and no grouping, as the shell's other syntax is just as plain. The
 * status is that of the last pipeline that ran, in the same encoding execute_pipeline returns. The line has been through
 * protect_quotes(), so a quoted separator is not seen here. Each element is variable-expanded just before it runs (so "$?" and a
 * variable exported earlier in the same line are current); an empty element between separators counts as success. A single '&'
 * ends an element like ';' does but starts it as a background job (status 0, "$!" is its pid). */
static int execute_list(const char *line) {
    char elem[256];
    int status = 0;
    int run_next = 1;
    const char *p = line;
    for (;;) {
        int n = 0;
        while (*p && !(*p == ';' || *p == '&' || (*p == '|' && p[1] == '|')) && n < (int)sizeof(elem) - 1)
            elem[n++] = *p++;
        elem[n] = '\0';
        int bg = (*p == '&' && p[1] != '&');
        if (run_next) {
            const char *e = skip_spaces(elem);
            if (*e) {
                char expanded[256];
                expand_vars(e, expanded, sizeof(expanded));
                g_background = bg;
                status = execute_pipeline(expanded);
                g_background = 0;
            } else {
                status = 0;
            }
            set_last_code(status);
        }
        if (*p == '\0') break;
        if (*p == ';' || bg) {
            run_next = 1;
            p++;
        } else if (*p == '&') {
            run_next = status_ok(status) ? 1 : 0;
            p += 2;
        } else {
            run_next = status_ok(status) ? 0 : 1;
            p += 2;
        }
    }
    return status;
}

int main(int argc, char **argv, char **envp) {
    (void)envp;

    /* "sh -c command": run one command line (pipes, redirection and the built-ins work as at the prompt), print nothing of its
     * own, and end with the command's exit status; a command killed by a signal ends the shell with 128 + signal. system() in
     * the C library starts the shell like this. */
    if (argc >= 3 && strcmp(argv[1], "-c") == 0) {
        g_command_mode = 1;
        char quoted[256];
        snprintf(quoted, sizeof(quoted), "%s", argv[2]);
        protect_quotes(quoted);
        int status = execute_list(quoted);
        if (status < 0) return 1;
        int sig = status & 0x7f;
        return sig ? 128 + sig : (status >> 8) & 0xff;
    }

    struct ksigaction ign = { SIG_IGN, 0, 0, 0 };
    sigaction(SIGINT, &ign, (void *)0);

    /* Commands from a file or a pipe ("sh < script"): no banner, no prompt, no echo; the shell ends at the end of the input with
     * the status of the last command it ran. */
    g_interactive = isatty(STDIN_FILENO) != 0;
    if (g_interactive) print("MoQiOS shell\n");
    int last_status = 0;

    for (;;) {
        jobs_reap_finished();
        if (g_interactive) print("> ");
        char line[256];
        int len = read_line(line, sizeof(line));
        if (len == LINE_EOF) {
            int sig = last_status & 0x7f;
            return sig ? 128 + sig : (last_status >> 8) & 0xff;
        }
        if (len < 0) continue;
        if (len == 0) continue;

        protect_quotes(line);
        int status = execute_list(line);
        last_status = status < 0 ? (1 << 8) : status;
    }
}
