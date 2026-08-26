// hello87 - statx output-fault and temporary-fd leak acceptance.
#include <stdint.h>

static inline int64_t syscall1(uint64_t n, uint64_t a) { int64_t r; __asm__ volatile("syscall":"=a"(r):"a"(n),"D"(a):"rcx","r11","memory"); return r; }
static inline int64_t syscall2(uint64_t n, uint64_t a, uint64_t b) { int64_t r; __asm__ volatile("syscall":"=a"(r):"a"(n),"D"(a),"S"(b):"rcx","r11","memory"); return r; }
static inline int64_t syscall3(uint64_t n, uint64_t a, uint64_t b, uint64_t c) { int64_t r; register uint64_t x __asm__("rdx")=c; __asm__ volatile("syscall":"=a"(r):"a"(n),"D"(a),"S"(b),"r"(x):"rcx","r11","memory"); return r; }
static inline int64_t syscall5(uint64_t n, uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e) { int64_t r; register uint64_t x __asm__("rdx")=c; register uint64_t y __asm__("r10")=d; register uint64_t z __asm__("r8")=e; __asm__ volatile("syscall":"=a"(r):"a"(n),"D"(a),"S"(b),"r"(x),"r"(y),"r"(z):"rcx","r11","memory"); return r; }

#define SYS_WRITE 1
#define SYS_EXIT 2
#define SYS_CLOSE 11
#define SYS_OPEN 9
#define SYS_STATX 183
#define AT_FDCWD ((uint64_t)-100L)
#define STATX_BASIC_STATS 0x7ff
#define EFAULT 14
#define MAX_FDS 64

static void print(const char *s) { uint64_t n=0; while(s[n]) n++; syscall3(SYS_WRITE,1,(uint64_t)s,n); }
static int check(int ok,const char *s){if(!ok){print("hello87: FAIL ");print(s);print("\n");return 1;}return 0;}
__attribute__((noreturn)) static void exit_raw(int x){syscall1(SYS_EXIT,(uint64_t)x);for(;;){}}

void _start(void) {
    int failures = 0;
    char path[] = "hello87";
    unsigned char statbuf[256];
    for (unsigned long i = 0; i < sizeof(statbuf); i++) statbuf[i] = 0x5a;
    print("hello87: start\n");

    const int64_t valid = syscall5(SYS_STATX, AT_FDCWD, (uint64_t)path, 0,
                                   STATX_BASIC_STATS, (uint64_t)statbuf);
    failures += check(valid == 0, "valid statx path succeeds");
    failures += check(statbuf[0] != 0 || statbuf[4] != 0,
                      "valid statx output is populated");

    /* The bad output pointer is rejected before temporary fd allocation.
     * Repeat beyond the descriptor table capacity, then prove a regular open
     * still gets a descriptor. */
    for (int i = 0; i < MAX_FDS + 8; i++) {
        failures += check(syscall5(SYS_STATX, AT_FDCWD, (uint64_t)path, 0,
                                    STATX_BASIC_STATS, 0) == -EFAULT,
                          "bad statx output returns EFAULT");
    }
    const int64_t fd = syscall3(SYS_OPEN, (uint64_t)path, 0, 0);
    failures += check(fd >= 0 && fd < MAX_FDS, "open succeeds after bad statx calls");
    if (fd >= 0) failures += check(syscall1(SYS_CLOSE, (uint64_t)fd) == 0,
                                   "close post-statx fd");

    if (!failures) print("hello87: PASS\nhello87 done\n");
    else print("hello87: FAIL\nhello87 done\n");
    exit_raw(failures != 0);
}
