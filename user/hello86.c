// hello86 - raw readlink /proc/self/fd and procfs error-boundary acceptance.
#include <stdint.h>

static inline int64_t syscall2(uint64_t n, uint64_t a, uint64_t b) { int64_t r; __asm__ volatile("syscall":"=a"(r):"a"(n),"D"(a),"S"(b):"rcx","r11","memory"); return r; }
static inline int64_t syscall3(uint64_t n, uint64_t a, uint64_t b, uint64_t c) { int64_t r; register uint64_t x __asm__("rdx")=c; __asm__ volatile("syscall":"=a"(r):"a"(n),"D"(a),"S"(b),"r"(x):"rcx","r11","memory"); return r; }

#define SYS_WRITE 1
#define SYS_EXIT 2
#define SYS_CLOSE 11
#define SYS_READLINK 182
#define SYS_OPEN 9
#define O_RDONLY 0
#define EFAULT 14
#define EINVAL 22

static void print(const char *s) { uint64_t n=0; while(s[n]) n++; syscall3(SYS_WRITE,1,(uint64_t)s,n); }
static int check(int ok,const char *s){if(!ok){print("hello86: FAIL ");print(s);print("\n");return 1;}return 0;}
__attribute__((noreturn)) static void exit_raw(int x){syscall2(SYS_EXIT,(uint64_t)x,0);for(;;){}}

static int equal(const char *a, const char *b, uint64_t n) {
    for (uint64_t i = 0; i < n; i++) if (a[i] != b[i]) return 0;
    return 1;
}

void _start(void) {
    int failures = 0;
    char target[32];
    char fd_path[] = "/proc/self/fd/1";
    char exe_path[] = "/proc/self/exe";
    print("hello86: start\n");

    int64_t n = syscall3(SYS_READLINK, (uint64_t)exe_path, (uint64_t)target, sizeof(target));
    failures += check(n == 7 && equal(target, "/bin/sh", 7), "readlink /proc/self/exe");

    n = syscall3(SYS_READLINK, (uint64_t)fd_path, (uint64_t)target, sizeof(target));
    failures += check(n == 4 && equal(target, "file", 4), "readlink ordinary fd target");

    for (uint64_t i = 0; i < sizeof(target); i++) target[i] = 0x5a;
    n = syscall3(SYS_READLINK, (uint64_t)fd_path, (uint64_t)target, 2);
    failures += check(n == 2 && equal(target, "fi", 2), "readlink bounded truncation");

    failures += check(syscall3(SYS_READLINK, 0, (uint64_t)target, sizeof(target)) == -EFAULT,
                      "readlink bad path returns EFAULT");
    failures += check(syscall3(SYS_READLINK, (uint64_t)fd_path, 0, sizeof(target)) == -EFAULT,
                      "readlink bad output returns EFAULT");
    failures += check(syscall3(SYS_READLINK, (uint64_t)fd_path, (uint64_t)target, 0) == -EFAULT,
                      "readlink zero bufsiz returns EFAULT");
    char invalid_fd[] = "/proc/self/fd/63";
    failures += check(syscall3(SYS_READLINK, (uint64_t)invalid_fd, (uint64_t)target, sizeof(target)) == -EINVAL,
                      "readlink invalid fd returns EINVAL");

    if (!failures) print("hello86: PASS\nhello86 done\n");
    else print("hello86: FAIL\nhello86 done\n");
    exit_raw(failures != 0);
}
