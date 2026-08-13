/* pthread.h — MoQiOS pthread 子集（v2）。
 *
 * 性能优先设计：
 * - mutex/once 的无竞争路径零系统调用（glibc 风格 0/1/2 futex 状态机）；
 * - join 经 futex 等待，线程退出只唤醒一次；
 * - TLS 经 FS:0 直读 TCB（arch_prctl/CLONE_SETTLS 各一次，之后纯内存访问）。
 *
 * v2 范围与限制（写进文档）：
 * - 不支持 CLONE_FILES 真共享 fd 表（创建时复制）；
 * - 不支持 __thread 关键字（PT_TLS）；线程私有数据用 pthread_getspecific；
 * - v2 起支持 pthread_detach：detached 线程的栈块退出时压入死栈链，
 *   由下一次 pthread_create 惰性回收，不再必依赖 join 释放；
 * - malloc/free 自带自旋锁，多线程并发 create/join 安全（v2）。
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
/* v2：detached 线程退出时把 TCB+栈块压入无锁死栈链，由下一次
 * pthread_create 排空回收（退出线程无法安全释放自己仍在运行的栈）。
 * join 一个 detached 线程返回 -EINVAL。 */
int pthread_detach(pthread_t thread);
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
