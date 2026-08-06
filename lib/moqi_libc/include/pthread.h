/* pthread.h — MoQiOS pthread 子集（v1）。
 *
 * 性能优先设计：
 * - mutex/once 的无竞争路径零系统调用（glibc 风格 0/1/2 futex 状态机）；
 * - join 经 futex 等待，线程退出只唤醒一次；
 * - TLS 经 FS:0 直读 TCB（arch_prctl/CLONE_SETTLS 各一次，之后纯内存访问）。
 *
 * v1 范围与限制（写进文档）：
 * - 不支持 CLONE_FILES 真共享 fd 表（创建时复制）；
 * - 不支持 __thread 关键字（PT_TLS）；线程私有数据用 pthread_getspecific；
 * - detached 线程的栈描述符在 v1 中由调用方负责（join 释放；不 join 则泄漏）。
 */
#ifndef MOQI_PTHREAD_H
#define MOQI_PTHREAD_H

#include <stddef.h>

/* ── 类型 ─────────────────────────────────────────────────────────── */
typedef unsigned long pthread_t;
typedef struct { volatile int f; } pthread_mutex_t;
typedef struct { volatile int s; } pthread_once_t;
typedef int pthread_key_t;

#define PTHREAD_MUTEX_INITIALIZER { 0 }
#define PTHREAD_ONCE_INIT { 0 }
#define PTHREAD_KEYS_MAX 32

/* ── 线程创建/退出/汇合 ───────────────────────────────────────────── */
int pthread_create(pthread_t *thread, const void *attr,
                   void *(*start_routine)(void *), void *arg);
void pthread_exit(void *retval) __attribute__((noreturn));
int pthread_join(pthread_t thread, void **retval);
pthread_t pthread_self(void);

/* ── 互斥锁（无竞争零系统调用） ────────────────────────────────────── */
int pthread_mutex_init(pthread_mutex_t *m, const void *attr);
int pthread_mutex_lock(pthread_mutex_t *m);
int pthread_mutex_unlock(pthread_mutex_t *m);
int pthread_mutex_destroy(pthread_mutex_t *m);

/* ── 一次性初始化 ─────────────────────────────────────────────────── */
int pthread_once(pthread_once_t *o, void (*init_routine)(void));

/* ── 线程私有数据 ─────────────────────────────────────────────────── */
int pthread_key_create(pthread_key_t *key, void (*destructor)(void *));
int pthread_setspecific(pthread_key_t key, const void *value);
void *pthread_getspecific(pthread_key_t key);

/* ── errno（每线程，经 TCB） ───────────────────────────────────────── */
int *__errno_location(void);
#ifndef errno
#define errno (*__errno_location())
#endif

#endif /* MOQI_PTHREAD_H */
