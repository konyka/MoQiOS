#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>

#define CTRL_C  0x03

/* Utility functions */

/* Read a line from stdin with basic line editing */
static int read_line(char *buf, int max) {
    int pos = 0;
    while (pos < max - 1) {
        long n = read(STDIN_FILENO, buf + pos, 1);
        if (n <= 0) {
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
                long vlen = moqi_getenv(key, val, sizeof(val));
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
        _exit(1);
    }

    /* Handle output redirection */
    if (redir_out && redir_out[0]) {
        long fd = open(redir_out, O_WRONLY | O_CREAT | O_TRUNC, 0644);
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

    execve(name, argv, (void *)0);
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
        if (strcmp(cmd, "exit") == 0) {
            print("bye\n");
            _exit(0);
        }
        if (strcmp(cmd, "pid") == 0) {
            printf("%ld\n", getpid());
            return 0;
        }
        if (strcmp(cmd, "help") == 0) {
            print("Commands: exit, pid, echo, ls, cd, pwd, export, env, help, <program>\n");
            return 0;
        }
        if (strcmp(cmd, "echo") == 0) {
            const char *rest = cmds[0];
            int idx = 0;
            while (rest[idx] && rest[idx] != ' ') idx++;
            while (rest[idx] == ' ') idx++;
            print(rest + idx);
            print("\n");
            return 0;
        }
        if (strcmp(cmd, "export") == 0) {
            const char *rest = cmds[0];
            int idx = 0;
            while (rest[idx] && rest[idx] != ' ') idx++;
            while (rest[idx] == ' ') idx++;
            if (rest[idx]) {
                moqi_setenv(rest + idx);
            }
            return 0;
        }
        if (strcmp(cmd, "env") == 0) {
            print("(use export VAR=value to set)\n");
            return 0;
        }
        if (strcmp(cmd, "ls") == 0) {
            char lsbuf[4096];
            long n = moqi_listdir(lsbuf, sizeof(lsbuf));
            if (n > 0) {
                write(STDOUT_FILENO, lsbuf, (size_t)n);
            }
            return 0;
        }
        if (strcmp(cmd, "cd") == 0) {
            const char *rest = cmds[0];
            int idx = 0;
            while (rest[idx] && rest[idx] != ' ') idx++;
            while (rest[idx] == ' ') idx++;
            if (!rest[idx]) {
                long ret = chdir("/");
                if (ret < 0) print("cd: failed\n");
            } else {
                long ret = chdir(rest + idx);
                if (ret < 0) print("cd: failed\n");
            }
            return 0;
        }
        if (strcmp(cmd, "pwd") == 0) {
            char buf[256];
            memset(buf, 0, sizeof(buf));
            long n = getcwd(buf, sizeof(buf));
            if (n > 0) {
                print(buf);
                print("\n");
            } else {
                print("pwd: failed\n");
            }
            return 0;
        }

        /* Fork and exec */
        long pid = fork();
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
        waitpid(-1, &status, 0);
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
            run_command(cmds[i], prev_pipe, is_last ? -1 : pipefd[1], redir);
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
    }

    /* Wait for all children */
    int status = 0;
    for (int i = 0; i < ncmds; i++) {
        waitpid(-1, &status, 0);
    }

    return status;
}

int main(void) {
    struct ksigaction ign = { SIG_IGN, 0, 0, 0 };
    sigaction(SIGINT, &ign, (void *)0);

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
