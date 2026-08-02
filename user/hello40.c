/// hello40: IPC_SET and rt_sigsuspend must not mutate state after a failed copy.

#include <stdint.h>

static inline int64_t syscall1(uint64_t nr, uint64_t a1) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall2(uint64_t nr, uint64_t a1, uint64_t a2) {
    int64_t ret;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2) : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall3(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    __asm__ volatile ("syscall" : "=a"(ret) : "a"(nr), "D"(a1), "S"(a2), "r"(rdx) : "rcx", "r11", "memory");
    return ret;
}

static inline int64_t syscall6(uint64_t nr, uint64_t a1, uint64_t a2, uint64_t a3,
                               uint64_t a4, uint64_t a5, uint64_t a6) {
    int64_t ret;
    register uint64_t rdx __asm__("rdx") = a3;
    register uint64_t r10 __asm__("r10") = a4;
    register uint64_t r8 __asm__("r8") = a5;
    register uint64_t r9 __asm__("r9") = a6;
    __asm__ volatile ("syscall" : "=a"(ret)
                      : "a"(nr), "D"(a1), "S"(a2), "r"(rdx), "r"(r10), "r"(r8), "r"(r9)
                      : "rcx", "r11", "memory");
    return ret;
}

#define SYS_WRITE          1
#define SYS_EXIT           2
#define SYS_MMAP           8
#define SYS_MUNMAP         12
#define SYS_SIGPROCMASK    14
#define SYS_SHMGET         149
#define SYS_SHMCTL         152
#define SYS_MSGGET         156
#define SYS_MSGCTL         159
#define SYS_RT_SIGSUSPEND  220

#define EFAULT 14
#define EINTR  4
#define IPC_CREAT 01000
#define IPC_RMID  0
#define IPC_STAT  2
#define IPC_SET   1
#define PROT_READ     1
#define PROT_WRITE    2
#define MAP_PRIVATE   2
#define MAP_ANONYMOUS 0x20
#define PAGE          4096

static void print(const char *s) {
    uint64_t n = 0;
    while (s[n]) n++;
    syscall3(SYS_WRITE, 1, (uint64_t)s, n);
}

static void fail(const char *why) {
    print("hello40: FAIL (");
    print(why);
    print(")\nhello40 done\n");
    syscall1(SYS_EXIT, 1);
    for (;;) {}
}

void _start(void) {
    const uint64_t mode = 0640;
    const int64_t copy_page = syscall6(SYS_MMAP, 0, PAGE, PROT_READ | PROT_WRITE,
                                       MAP_PRIVATE | MAP_ANONYMOUS, (uint64_t)-1, 0);
    if (copy_page <= 0) fail("mmap");
    if (syscall2(SYS_MUNMAP, (uint64_t)copy_page, PAGE) != 0) fail("munmap");

    const int64_t shmid = syscall3(SYS_SHMGET, 0, 4096, IPC_CREAT | mode);
    if (shmid < 0) fail("shmget");
    if (syscall3(SYS_SHMCTL, shmid, IPC_SET, (uint64_t)copy_page) != -EFAULT) fail("shmctl EFAULT");

    const int64_t msgid = syscall2(SYS_MSGGET, 0, IPC_CREAT | mode);
    if (msgid < 0) fail("msgget");
    if (syscall3(SYS_MSGCTL, msgid, IPC_SET, (uint64_t)copy_page) != -EFAULT) fail("msgctl EFAULT");

    uint64_t msg_info[6] = { 0 };
    if (syscall3(SYS_MSGCTL, msgid, IPC_STAT, (uint64_t)msg_info) != 0) fail("msgctl stat");
    if (msg_info[4] != mode) fail("msgctl mode changed");

    /* sigprocmask now takes the rt_* ABI: 8-byte masks with sigsetsize=8 in
       the 4th argument (r10). */
    uint64_t expected_mask = (uint64_t)1 << 1;
    uint64_t observed_mask = 0;
    if (syscall6(SYS_SIGPROCMASK, 2, (uint64_t)&expected_mask, 0, 8, 0, 0) != 0) fail("sigprocmask set");
    if (syscall2(SYS_RT_SIGSUSPEND, 0, 4) != -EFAULT) fail("rt_sigsuspend EFAULT");
    if (syscall6(SYS_SIGPROCMASK, 2, 0, (uint64_t)&observed_mask, 8, 0, 0) != 0) fail("sigprocmask get");
    if (observed_mask != expected_mask) fail("signal mask changed");

    if (syscall2(SYS_RT_SIGSUSPEND, (uint64_t)copy_page, 4) != -EFAULT) fail("rt_sigsuspend EFAULT");
    if (syscall6(SYS_SIGPROCMASK, 2, 0, (uint64_t)&expected_mask, 8, 0, 0) != 0) fail("sigprocmask get after failure");
    if (expected_mask != observed_mask) fail("rt_sigsuspend failed mask");

    uint64_t new_mode = 0600;
    if (syscall3(SYS_SHMCTL, shmid, IPC_SET, (uint64_t)&new_mode) != 0) fail("shmctl success");
    if (syscall3(SYS_MSGCTL, msgid, IPC_SET, (uint64_t)&new_mode) != 0) fail("msgctl success");
    if (syscall3(SYS_MSGCTL, msgid, IPC_STAT, (uint64_t)msg_info) != 0) fail("msgctl stat after set");
    if (msg_info[4] != new_mode) fail("msgctl mode after set");

    observed_mask = (uint64_t)1 << 2;
    if (syscall2(SYS_RT_SIGSUSPEND, (uint64_t)&observed_mask, 4) != -EINTR) fail("rt_sigsuspend success");
    if (syscall6(SYS_SIGPROCMASK, 2, 0, (uint64_t)&expected_mask, 8, 0, 0) != 0) fail("sigprocmask get after success");
    if (expected_mask != observed_mask) fail("rt_sigsuspend mask");

    syscall3(SYS_MSGCTL, msgid, IPC_RMID, 0);
    syscall3(SYS_SHMCTL, shmid, IPC_RMID, 0);
    print("hello40: PASS (IPC_SET and rt_sigsuspend EFAULT)\nhello40 done\n");
    syscall1(SYS_EXIT, 0);
    for (;;) {}
}
