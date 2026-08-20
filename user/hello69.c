// hello69 - private-futex ABI rejection and pthread fast-path acceptance.
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/pthread.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"

static int failures;
#define CHECK(cond, name) do { if (!(cond)) { print("hello69: FAIL " name "\n"); failures++; } } while (0)

#define SYS_futex 143
#define FUTEX_WAIT 0
#define FUTEX_WAKE 1
#define FUTEX_LOCK_PI 6
#define FUTEX_UNLOCK_PI 7
#define FUTEX_TRYLOCK_PI 8
#define FUTEX_WAIT_REQUEUE_PI 11
#define FUTEX_CMP_REQUEUE_PI 12
#define FUTEX_REQUEUE 3
#define FUTEX_CMP_REQUEUE 4
#define FUTEX_WAKE_OP 5
#define FUTEX_WAIT_BITSET 9
#define FUTEX_WAKE_BITSET 10
#define FUTEX_PRIVATE_FLAG 128
#define EAGAIN 11
#define EINVAL 22
#define ENOSYS 38

static pthread_mutex_t counter_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile int counter;

static long futex_raw(volatile int *uaddr, long op, long val,
                      long val2, volatile int *uaddr2, long val3) {
    return syscall6(SYS_futex, (long)uaddr, op, val, val2, (long)uaddr2, val3);
}

static void *counter_worker(void *arg) {
    (void)arg;
    for (int i = 0; i < 1000; i++) {
        pthread_mutex_lock(&counter_lock);
        counter++;
        pthread_mutex_unlock(&counter_lock);
    }
    return 0;
}

static void check_pi_unsupported(void) {
    static const long pi_ops[] = {
        FUTEX_LOCK_PI,
        FUTEX_UNLOCK_PI,
        FUTEX_TRYLOCK_PI,
        FUTEX_WAIT_REQUEUE_PI,
        FUTEX_CMP_REQUEUE_PI,
    };
    volatile int first = 0x13579bdf;
    volatile int second = 0x2468ace0;
    for (unsigned long i = 0; i < sizeof(pi_ops) / sizeof(pi_ops[0]); i++) {
        const long op = pi_ops[i];
        CHECK(futex_raw(&first, op, 0, 0, &second, 0) == -ENOSYS,
              "PI op returns ENOSYS");
        CHECK(first == 0x13579bdf && second == 0x2468ace0,
              "PI op preserves sentinel words");
        CHECK(futex_raw(&first, op | FUTEX_PRIVATE_FLAG, 0, 0, &second, 0) == -ENOSYS,
              "private PI op returns ENOSYS");
        CHECK(first == 0x13579bdf && second == 0x2468ace0,
              "private PI op preserves sentinel words");
    }
}

static void check_other_unsupported(void) {
    static const long ops[] = { FUTEX_REQUEUE, FUTEX_CMP_REQUEUE, FUTEX_WAKE_OP,
                                FUTEX_WAIT_BITSET, FUTEX_WAKE_BITSET };
    volatile int first = 0x13579bdf;
    volatile int second = 0x2468ace0;
    for (unsigned long i = 0; i < sizeof(ops) / sizeof(ops[0]); i++) {
        CHECK(futex_raw(&first, ops[i], 1, 1, &second, 0) == -ENOSYS,
              "unsupported futex op returns ENOSYS");
        CHECK(futex_raw(&first, ops[i] | FUTEX_PRIVATE_FLAG, 1, 1, &second, 0) == -ENOSYS,
              "private unsupported futex op returns ENOSYS");
        CHECK(first == 0x13579bdf && second == 0x2468ace0,
              "unsupported futex op preserves sentinel words");
    }
}

int main(int argc, char **argv, char **envp) {
    (void)argc;
    (void)argv;
    (void)envp;
    print("hello69: start\n");

    unsigned char misaligned_storage[8] = { 0 };
    volatile int *misaligned = (volatile int *)(misaligned_storage + 1);
    CHECK(futex_raw(misaligned, FUTEX_WAIT | FUTEX_PRIVATE_FLAG, 0, 0, 0, 0) == -EINVAL,
          "misaligned private WAIT returns EINVAL");

    check_pi_unsupported();
    check_other_unsupported();

    volatile int mismatch = 1;
    CHECK(futex_raw(&mismatch, FUTEX_WAIT | FUTEX_PRIVATE_FLAG, 0, 0, 0, 0) == -EAGAIN,
          "private WAIT mismatch returns EAGAIN");

    pthread_t c1;
    pthread_t c2;
    counter = 0;
    CHECK(pthread_create(&c1, 0, counter_worker, 0) == 0, "create counter worker 1");
    CHECK(pthread_create(&c2, 0, counter_worker, 0) == 0, "create counter worker 2");
    CHECK(pthread_join(c1, 0) == 0, "join counter worker 1");
    CHECK(pthread_join(c2, 0) == 0, "join counter worker 2");
    CHECK(counter == 2000, "pthread mutex contention increments exactly");

    if (failures == 0) {
        print("hello69: PASS\nhello69 done\n");
        _exit(0);
    }
    print("hello69: FAIL\nhello69 done\n");
    _exit(1);
}
