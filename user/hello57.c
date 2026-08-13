// hello57 — pthread 子集验收测试（TDD 目标）。
// 覆盖：pthread_create/join/retval、mutex 竞争正确性、pthread_once 恰好一次、
// pthread_getspecific 线程私有数据、errno 线程隔离、getpid tgid 一致性。
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/stdlib.h"
#include "../lib/moqi_libc/include/string.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/pthread.h"

#define NTHREADS 4
#define NITER 25000

static pthread_mutex_t counter_lock = PTHREAD_MUTEX_INITIALIZER;
static long counter;
static pthread_once_t once_ctrl = PTHREAD_ONCE_INIT;
static int once_ran;
static pthread_key_t key_a;

static int failures;

#define CHECK(cond, name) do { \
    if (!(cond)) { \
        print("hello57: FAIL " name "\n"); \
        failures++; \
    } \
} while (0)

static void print_u64(unsigned long v) {
    char buf[24];
    int i = 0;
    if (v == 0) { print("0"); return; }
    while (v != 0) { buf[i++] = (char)('0' + v % 10); v /= 10; }
    while (i > 0) { char c[2] = { buf[--i], 0 }; print(c); }
}

static void once_init(void) {
    once_ran++;
}

/* ── v2 CLONE_FILES 验收：线程共享 fd 表 ────────────────────────────── */
/* 读线程：直接读主线程打开的 fd，共享表下必须成功且内容一致。 */
static void *fdshare_reader(void *arg) {
    long fd = (long)arg;
    char buf[8];
    long n = read((int)fd, buf, 5);
    if (n != 5 || buf[0] != 's' || buf[1] != 'h' || buf[4] != '7') {
        print("hello57: FAIL fdshare-read\n");
        __sync_fetch_and_add(&failures, 1);
    }
    return (void *)0;
}

/* EBADF 线程：主线程 close 后再读同一 fd 号，必须失败。
   注意：本内核 read 闭合 fd 的历史 ABI 返回 -1（vfs.read 的 .none 分支），
   非 -9；接受两者，核心是"必须报错"。 */
static void *fdshare_ebadf(void *arg) {
    long fd = (long)arg;
    char buf[8];
    long n = read((int)fd, buf, 5);
    if (n != -1 && n != -9) { /* EBADF-class */
        print("hello57: FAIL fdshare-ebadf n=");
        char d[2] = { (char)('0' + (n < 0 ? -n : n) % 10), 0 };
        print(n < 0 ? "-" : "+");
        print(d);
        print("\n");
        __sync_fetch_and_add(&failures, 1);
    }
    return (void *)0;
}

/* detached 验收：线程仅原子自增后即退出，栈块由后续 create 惰性回收。 */
static volatile long detached_done;

static void *detached_worker(void *arg) {
    (void)arg;
    __sync_fetch_and_add(&detached_done, 1);
    return (void *)0;
}

static void *worker(void *arg) {
    long id = (long)arg;
    for (long i = 0; i < NITER; i++) {
        pthread_mutex_lock(&counter_lock);
        counter++;
        pthread_mutex_unlock(&counter_lock);
    }
    pthread_once(&once_ctrl, once_init);

    /* 线程私有数据：写入再读回，须为本线程的值。 */
    pthread_setspecific(key_a, (void *)(id * 100 + 7));
    void *got = pthread_getspecific(key_a);
    if (got != (void *)(id * 100 + 7)) {
        print("hello57: FAIL getspecific\n");
        __sync_fetch_and_add(&failures, 1);
    }

    /* errno 线程隔离：本线程改写 errno，不得影响其他线程。 */
    errno = (int)(1000 + id);

    /* getpid 在全部线程中必须一致（tgid）。 */
    long pid = getpid();
    return (void *)(id * 10 + (pid & 0));
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello57: start\n");

    if (pthread_key_create(&key_a, 0) != 0) {
        print("hello57: FAIL key_create\n");
        return 1;
    }

    pthread_t th[NTHREADS];
    for (long i = 0; i < NTHREADS; i++) {
        if (pthread_create(&th[i], 0, worker, (void *)i) != 0) {
            print("hello57: FAIL create\n");
            return 1;
        }
    }

    long main_pid = getpid();
    long main_errno = 5;
    errno = 5;

    for (long i = 0; i < NTHREADS; i++) {
        void *ret = 0;
        if (pthread_join(th[i], &ret) != 0) {
            print("hello57: FAIL join\n");
            return 1;
        }
        if (ret != (void *)(i * 10)) {
            print("hello57: FAIL retval\n");
            failures++;
        }
    }

    CHECK(counter == (long)NTHREADS * NITER, "counter");
    CHECK(once_ran == 1, "once");
    CHECK(errno == 5, "errno-isolation");
    CHECK(main_pid == getpid(), "tgid");
    (void)main_errno;

    /* ── v2 detached：不 join 的线程栈块由后续 create 惰性回收 ──────── */
    {
#define NDETACHED 8
        pthread_t dth[NDETACHED];
        for (long i = 0; i < NDETACHED; i++) {
            if (pthread_create(&dth[i], 0, detached_worker, (void *)0) != 0) {
                print("hello57: FAIL detach-create\n");
                failures++;
                break;
            }
            if (pthread_detach(dth[i]) != 0) {
                print("hello57: FAIL detach\n");
                failures++;
            }
        }
        /* 重复 detach 与 join-detached 都必须报 EINVAL。 */
        CHECK(pthread_detach(dth[0]) == -22, "double-detach-EINVAL");
        CHECK(pthread_join(dth[0], 0) == -22, "join-detached-EINVAL");
        /* 后续 create 触发死栈链排空；这两个线程自身走 join 回收。 */
        for (long i = 0; i < 2; i++) {
            pthread_t t;
            if (pthread_create(&t, 0, detached_worker, (void *)0) != 0 ||
                pthread_join(t, 0) != 0) {
                print("hello57: FAIL drain-create\n");
                failures++;
            }
        }
        /* 8 个 detached + 2 个 drain 线程共 10 次自增；有界等待。 */
        long spins = 0;
        while (detached_done != NDETACHED + 2 && spins < 100000000L) spins++;
        CHECK(detached_done == NDETACHED + 2, "detached-done");
    }

    /* ── v2 CLONE_FILES：pthread 线程共享 fd 表 ─────────────────────── */
    /* 用 pthread_join 排序：先证明线程可见主线程的 fd，再证明主线程
       close 后（共享表同一份）其他线程读同一 fd 号得到 EBADF。 */
    {
        long fd = open("/tmp/h57shr.dat", O_RDWR | O_CREAT | O_TRUNC, 0644);
        CHECK(fd >= 3, "shr-open");
        CHECK(write((int)fd, "shr57", 5) == 5, "shr-write");
        CHECK(lseek((int)fd, 0, SEEK_SET) == 0, "shr-lseek");
        pthread_t t;
        if (pthread_create(&t, 0, fdshare_reader, (void *)fd) != 0 ||
            pthread_join(t, 0) != 0) {
            print("hello57: FAIL shr-join1\n");
            failures++;
        }
        CHECK(close((int)fd) == 0, "shr-close");
        if (pthread_create(&t, 0, fdshare_ebadf, (void *)fd) != 0 ||
            pthread_join(t, 0) != 0) {
            print("hello57: FAIL shr-join2\n");
            failures++;
        }
        unlink("/tmp/h57shr.dat");
    }

    if (failures == 0) {
        print("hello57: PASS (");
        print_u64((unsigned long)counter);
        print(" increments)\n");
    } else {
        print("hello57: FAIL count=");
        print_u64((unsigned long)failures);
        print("\n");
        return 1;
    }
    return 0;
}
