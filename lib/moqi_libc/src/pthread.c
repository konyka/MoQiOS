/* pthread.c — MoQiOS pthread 子集实现（v2）。
 *
 * 布局：x86-64 TLS variant II —— FS base（tp）指向 TCB（TCB[0]=self），
 * 程序 PT_TLS 模板的每线程副本位于 tp 下方（编译器 LE 模型以负偏移访问
 * __thread 变量）。无 PT_TLS 的程序保持 v1 布局（TCB 在分配区头部）。
 * 子线程 FS 由内核经 CLONE_SETTLS 安装，主线程由 crt0 经 arch_prctl 安装。
 *
 * 无竞争路径零系统调用：mutex/once 是 glibc 风格 futex 状态机。
 */
#include "../include/pthread.h"
#include "../include/stdlib.h"
#include "../include/string.h"
#include "../include/unistd.h"
#include "../include/moqi_syscalls.h"

#define SYS_clone_v     243 /* clone(flags, stack, parent_tid, child_tid, tls) */
#define SYS_futex_v     143 /* futex(uaddr, op, val, val2, uaddr2, val3) */
#define SYS_arch_prctl  472
#define ARCH_SET_FS     0x1002

#define CLONE_VM        0x100
#define CLONE_FILES     0x400
#define CLONE_THREAD    0x10000
#define CLONE_SETTLS    0x80000

#define FUTEX_WAIT      0
#define FUTEX_WAKE      1

#define THREAD_STACK_SIZE (64 * 1024)

/* ── PT_TLS 模板（__thread 支持） ─────────────────────────────────────
 * crt0 在 main 前调用 __moqi_tls_setup(sp)：从初始栈 auxv 取 AT_PHDR/
 * AT_PHNUM/AT_PHENT，扫描出 PT_TLS 段，记录模板位置与尺寸。
 * tls_block_size = align_up(memsz, align)：每个线程的 TLS 副本占用
 * tp 正下方的这么多字节；0 表示程序没有 PT_TLS。 */
#define AT_PHDR  3
#define AT_PHENT 4
#define AT_PHNUM 5
#define PT_TLS   7

static const char *tls_image;
static unsigned long tls_filesz;
static unsigned long tls_memsz;
static unsigned long tls_align = 8;
static unsigned long tls_block_size;

static unsigned long tls_align_up(unsigned long n, unsigned long a) {
    return (n + a - 1) & ~(a - 1);
}

/* 由 crt0 的 _start_c 在 main 前调用；sp 为内核构建的初始栈。 */
void __moqi_tls_setup(unsigned long *sp) {
    long argc = (long)sp[0];
    char **argv = (char **)(sp + 1);
    char **envp = argv + argc + 1;
    while (*envp) envp++;           /* 跳过 NULL 结尾的 envp 指针数组 */
    unsigned long *auxv = (unsigned long *)(envp + 1);

    unsigned long phdr = 0, phent = 56, phnum = 0;
    for (unsigned long *a = auxv; a[0] != 0; a += 2) {
        if (a[0] == AT_PHDR) phdr = a[1];
        else if (a[0] == AT_PHENT) phent = a[1];
        else if (a[0] == AT_PHNUM) phnum = a[1];
    }
    if (phdr == 0 || phnum == 0) return;

    for (unsigned long i = 0; i < phnum; i++) {
        const unsigned char *ph = (const unsigned char *)phdr + i * phent;
        unsigned int p_type;
        __builtin_memcpy(&p_type, ph, 4);
        if (p_type != PT_TLS) continue;
        unsigned long vaddr, filesz, memsz, align;
        __builtin_memcpy(&vaddr, ph + 16, 8);
        __builtin_memcpy(&filesz, ph + 32, 8);
        __builtin_memcpy(&memsz, ph + 40, 8);
        __builtin_memcpy(&align, ph + 48, 8);
        tls_image = (const char *)vaddr;
        tls_filesz = filesz;
        tls_memsz = memsz;
        if (align != 0) tls_align = align;
        tls_block_size = tls_align_up(memsz, tls_align);
        return;
    }
}

/* 在 base 处复制 TLS 模板（filesz 拷贝 + memsz-filesz 清零）。 */
static void tls_init_block(char *base) {
    __builtin_memcpy(base, tls_image, tls_filesz);
    __builtin_memset(base + tls_filesz, 0, tls_memsz - tls_filesz);
}

/* ── TCB ──────────────────────────────────────────────────────────── */
typedef struct TCB {
    struct TCB *self;               /* FS:0 — pthread_self 直读 */
    int errno_val;                  /* 每线程 errno */
    volatile int state;             /* 0=running 1=done */
    void *retval;
    void *(*fn)(void *);
    void *arg;
    void *specific[PTHREAD_KEYS_MAX];
    void *alloc_base;               /* join 时 free */
    volatile int detached;          /* pthread_detach 置位；join 返回 EINVAL */
    struct TCB *dead_next;          /* 死栈链链接（仅退出后使用） */
} TCB;

/* ── detached 栈惰性回收（v2） ────────────────────────────────────────
 * 退出的 detached 线程无法安全 free 自己仍在运行的栈，因此把 TCB 块压入
 * 无锁死栈链，由下一次 pthread_create 排空并 free。压链是退出线程的
 * 最后内存写：其后以纯寄存器 asm 直接 syscall exit，不再触碰本栈；
 * 残余窗口是压链与 exit 之间的信号投递（帧会写到可能已回收的栈顶），
 * 指令级宽度，按既有惯例记录为已接受残余。 */
static TCB *volatile dead_head;

static void dead_push(TCB *t) {
    TCB *head;
    do {
        head = dead_head;
        t->dead_next = head;
    } while (!__sync_bool_compare_and_swap(&dead_head, head, t));
}

static void dead_drain(void) {
    TCB *list = __sync_lock_test_and_set(&dead_head, (TCB *)0);
    while (list != 0) {
        TCB *next = list->dead_next;
        free(list->alloc_base);
        list = next;
    }
}

static TCB main_tcb = { .self = &main_tcb };

/* crt0 在 main 前调用：为主线程安装 FS。有 PT_TLS 时主线程也需要动态
 * 布局（TLS 块在 tp 正下方），静态 main_tcb 无法满足相对位置。 */
void __pthread_init_main(void) {
    if (tls_block_size == 0) {
        syscall2(SYS_arch_prctl, ARCH_SET_FS, (long)&main_tcb);
        return;
    }
    char *base = malloc(tls_block_size + tls_align + sizeof(TCB));
    char *tls_start = (char *)tls_align_up((unsigned long)base, tls_align);
    TCB *t = (TCB *)(tls_start + tls_block_size);
    tls_init_block(tls_start);
    t->self = t;
    t->errno_val = 0;
    t->state = 0;
    t->retval = 0;
    t->alloc_base = 0;              /* 主线程 TCB 永不回收 */
    t->detached = 0;
    t->dead_next = 0;
    for (int i = 0; i < PTHREAD_KEYS_MAX; i++) t->specific[i] = 0;
    syscall2(SYS_arch_prctl, ARCH_SET_FS, (long)t);
}

static inline TCB *tcb_self(void) {
    TCB *t;
    __asm__ volatile ("movq %%fs:0, %0" : "=r"(t));
    return t;
}

static inline long clone_call(long flags, long stack, long ptid, long ctid, long tls) {
    long ret;
    register long r10 __asm__("r10") = ctid;
    register long r8 __asm__("r8") = tls;
    __asm__ volatile ("syscall"
        : "=a"(ret)
        : "a"((long)SYS_clone_v), "D"(flags), "S"(stack), "d"(ptid), "r"(r10), "r"(r8)
        : "rcx", "r11", "memory");
    return ret;
}

static inline long futex_call(volatile int *uaddr, long op, long val, long val2) {
    long ret;
    register long r10 __asm__("r10") = val2;
    __asm__ volatile ("syscall"
        : "=a"(ret)
        : "a"((long)SYS_futex_v), "D"(uaddr), "S"(op), "d"(val), "r"(r10)
        : "rcx", "r11", "memory");
    return ret;
}

/* ── 创建/退出/汇合 ─────────────────────────────────────────────────── */
int pthread_create(pthread_t *thread, const void *attr,
                   void *(*start_routine)(void *), void *arg) {
    (void)attr;
    /* v2：先回收已退出 detached 线程的栈块（见 dead_drain 注释）。 */
    dead_drain();
    /* PT_TLS 布局：[TLS 块（align 对齐）][TCB 于 tp][栈]；无模板时退化为
     * v1 布局（TCB 在分配区头部）。多分配 align 字节以容纳对齐余量。 */
    void *base = malloc(tls_block_size + tls_align + sizeof(TCB) + THREAD_STACK_SIZE);
    if (base == 0) return -12; /* ENOMEM */
    char *tls_start = (char *)tls_align_up((unsigned long)base, tls_align);
    TCB *t = (TCB *)(tls_start + tls_block_size);
    if (tls_block_size != 0) tls_init_block(tls_start);
    t->self = t;
    t->errno_val = 0;
    t->state = 0;
    t->retval = 0;
    t->fn = start_routine;
    t->arg = arg;
    t->alloc_base = base;
    t->detached = 0;
    t->dead_next = 0;
    for (int i = 0; i < PTHREAD_KEYS_MAX; i++) t->specific[i] = 0;

    long sp = (long)t + sizeof(TCB) + THREAD_STACK_SIZE;
    sp &= ~15L;
    long ret = clone_call(CLONE_VM | CLONE_FILES | CLONE_THREAD | CLONE_SETTLS,
                          sp, 0, 0, (long)t);
    if (ret == 0) {
        /* 子线程：不经 pthread_create 帧（父可能已返回），经 FS 自取 TCB。 */
        TCB *me = tcb_self();
        void *rv = me->fn(me->arg);
        pthread_exit(rv);
        __builtin_unreachable();
    }
    if (ret < 0) {
        free(base);
        return (int)ret;
    }
    *thread = (pthread_t)t;
    return 0;
}

void pthread_exit(void *retval) {
    TCB *me = tcb_self();
    me->retval = retval;
    __atomic_store_n(&me->state, 1, __ATOMIC_SEQ_CST);
    futex_call((volatile int *)&me->state, FUTEX_WAKE, 1, 0);
    if (me->detached) {
        /* 压入死栈链后不再触碰本栈：直接以寄存器内联 exit syscall，
           连 _exit 的调用帧都不建。栈块由下一次 pthread_create 回收。 */
        dead_push(me);
        __asm__ volatile("syscall"
            :: "a"((long)2 /* SYS_exit */), "D"(0L)
            : "rcx", "r11", "memory");
        __builtin_unreachable();
    }
    _exit(0);
    __builtin_unreachable();
}

int pthread_detach(pthread_t thread) {
    TCB *t = (TCB *)thread;
    if (__sync_lock_test_and_set(&t->detached, 1) != 0) return -22; /* EINVAL */
    /* 已退出的线程不会再被 join：直接送入死栈链。 */
    if (__atomic_load_n(&t->state, __ATOMIC_ACQUIRE) == 1) dead_push(t);
    return 0;
}

int pthread_join(pthread_t thread, void **retval) {
    TCB *t = (TCB *)thread;
    if (__atomic_load_n(&t->detached, __ATOMIC_ACQUIRE) != 0) return -22; /* EINVAL */
    while (__atomic_load_n(&t->state, __ATOMIC_SEQ_CST) == 0) {
        futex_call((volatile int *)&t->state, FUTEX_WAIT, 0, 0);
    }
    /* 与并发 detach 的竞速（POSIX 属 UB，但必须不产生 double-free）：
       退出线程只在看到 detached==1 时压死栈链；压链发生在 state=1 之后，
       因此此处复见 detached==1 时该块可能已在死栈链上，所有权归
       dead_drain，join 不得再读 retval 或 free。 */
    if (__atomic_load_n(&t->detached, __ATOMIC_ACQUIRE) != 0) return -22; /* EINVAL */
    if (retval) *retval = t->retval;
    free(t->alloc_base);
    return 0;
}

pthread_t pthread_self(void) {
    return (pthread_t)tcb_self();
}

/* ── 互斥锁（0=unlocked 1=locked-uncontended 2=locked-contended） ───── */
int pthread_mutex_init(pthread_mutex_t *m, const void *attr) {
    (void)attr;
    m->f = 0;
    return 0;
}

int pthread_mutex_lock(pthread_mutex_t *m) {
    int c;
    __asm__ volatile ("xor %%eax, %%eax\n\t"
                      "mov $1, %%ecx\n\t"
                      "lock cmpxchg %%ecx, %1\n\t"
                      : "=a"(c) : "m"(m->f) : "ecx", "memory");
    if (c == 0) return 0; /* 无竞争快路径：一次 lock cmpxchg */
    if (c != 2) c = __sync_lock_test_and_set(&m->f, 2);
    while (c != 0) {
        futex_call(&m->f, FUTEX_WAIT, 2, 0);
        c = __sync_lock_test_and_set(&m->f, 2);
    }
    return 0;
}

int pthread_mutex_unlock(pthread_mutex_t *m) {
    if (__sync_lock_test_and_set(&m->f, 0) == 2) {
        futex_call(&m->f, FUTEX_WAKE, 1, 0);
    }
    return 0;
}

int pthread_mutex_destroy(pthread_mutex_t *m) {
    (void)m;
    return 0;
}

/* ── 一次性初始化（0=未做 1=进行中 2=完成） ─────────────────────────── */
int pthread_once(pthread_once_t *o, void (*init_routine)(void)) {
    if (__atomic_load_n(&o->s, __ATOMIC_ACQUIRE) == 2) return 0;
    int c;
    __asm__ volatile ("xor %%eax, %%eax\n\t"
                      "mov $1, %%ecx\n\t"
                      "lock cmpxchg %%ecx, %1\n\t"
                      : "=a"(c) : "m"(o->s) : "ecx", "memory");
    if (c == 0) {
        init_routine();
        __atomic_store_n(&o->s, 2, __ATOMIC_RELEASE);
        futex_call(&o->s, FUTEX_WAKE, 0x7fffffff, 0);
        return 0;
    }
    while (__atomic_load_n(&o->s, __ATOMIC_ACQUIRE) != 2) {
        futex_call(&o->s, FUTEX_WAIT, 1, 0);
    }
    return 0;
}

/* ── 线程私有数据 ─────────────────────────────────────────────────── */
static volatile unsigned long key_bm;

int pthread_key_create(pthread_key_t *key, void (*destructor)(void *)) {
    (void)destructor; /* v1：不调用析构 */
    for (int i = 0; i < PTHREAD_KEYS_MAX; i++) {
        unsigned long bit = 1UL << i;
        if (!(__sync_fetch_and_or(&key_bm, bit) & bit)) {
            *key = i;
            return 0;
        }
    }
    return -11; /* EAGAIN */
}

int pthread_setspecific(pthread_key_t key, const void *value) {
    if (key < 0 || key >= PTHREAD_KEYS_MAX) return -22;
    tcb_self()->specific[key] = (void *)value;
    return 0;
}

void *pthread_getspecific(pthread_key_t key) {
    if (key < 0 || key >= PTHREAD_KEYS_MAX) return 0;
    return tcb_self()->specific[key];
}

/* ── errno（每线程） ───────────────────────────────────────────────── */
int *__errno_location(void) {
    return &tcb_self()->errno_val;
}
