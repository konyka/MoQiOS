#ifndef MOQI_LIBC_DEAD_REAP_H
#define MOQI_LIBC_DEAD_REAP_H

/* pthread_join / pthread_detach / pthread_exit 的 TCB 块所有权协议
 *（host 可测）。
 *
 * exit/detach 两侧都是"先存自己的标志，再读对方的"：exit 存 state=1 后读
 * detached，detach TAS detached=1 后读 state。x86 TSO 允许
 *   exit:store state=1 → detach:TAS detached=1 → 双方 load 互见
 * 的交错，若无所有权认领，两侧都会 dead_push 同一 TCB（dead_next 自环
 * → dead_drain 死循环 + double-free）。dead_claimed 用 CAS 认领压链
 * 所有权，保证同一 TCB 恰好被压一次。
 *
 * 反向交错（双方 load 都过期 → 泄漏）不可达：两侧的存都是全栅栏
 * （exit 用 SEQ_CST store / xchg，detach 用 TAS / xchg），load 不可能
 * 越过它们看到旧值。
 *
 * join 认领（join_claimed）：pthread_join 在等待之前 CAS 认领块所有权；
 * 认领成功且此刻 detached==0 后，块唯一归 join（等待、读 retval、free
 * alloc_base）。detach 看到 join_claimed 已置位则返回 -22 且不压链；
 * exit 看到 join_claimed 已置位则不压链（join 会 free）。因此 join 持
 * 认领期间块不可能上死栈链，等待后不可能再触到已被 dead_drain 回收的
 * 内存（旧实现等待后复读 detached 的"防护"对该窗口不成立）。
 *
 * 有序性论证（与 exit/detach 同理）：join 的认领是 CAS（全栅栏），其后
 * 读 detached 不可能越过认领；若 join 读到 detached==0，则 detach 的
 * TAS 必在其后，detach 随后读 join_claimed 必然见 1 而退让。反向：若
 * detach 先 TAS，则 join 认领后复读 detached 见 1 而返回 -22，不读
 * retval/alloc_base。残余窗口：join/detach 竞速（POSIX 属 UB）下双方
 * 都退让时该块可能泄漏（detached==1 且 join_claimed==1，无人压链也
 * 无人 free）——仅泄漏，无 UAF/double-free，按既有惯例记录为已接受
 * 残余。
 *
 * dead_reap_on_* 返回非 0 表示调用方赢得压链所有权、必须把 TCB 压入
 * 死栈链；join_claim_acquire 返回 0 表示 join 赢得块所有权。 */

/* join 侧：等待前调用。先快检 detached（已 detach 时不写认领位，避免
 * 触碰可能已回收的块），再 CAS 认领，认领后复读 detached 收口竞速。
 * 返回 -22 表示已有 join 认领或已 detach：调用方不得再读 retval 或
 * free alloc_base。 */
static int join_claim_acquire(volatile int *detached, volatile int *join_claimed) {
    if (__atomic_load_n(detached, __ATOMIC_ACQUIRE) != 0) return -22;
    if (!__sync_bool_compare_and_swap(join_claimed, 0, 1)) return -22;
    if (__atomic_load_n(detached, __ATOMIC_ACQUIRE) != 0) return -22;
    return 0;
}

/* detach 侧：TAS detached=1 之后、压链判断之前调用；join 持认领则退让
 *（返回 -22，不压链，块归 join）。 */
static int join_claim_held(volatile int *join_claimed) {
    return __atomic_load_n(join_claimed, __ATOMIC_ACQUIRE) != 0;
}

/* exit 侧：看到 detached 已置位且无 join 认领才尝试认领压链。 */
static int dead_reap_on_exit(volatile int *detached, volatile int *join_claimed,
                             volatile int *claimed) {
    return *detached != 0 &&
           __atomic_load_n(join_claimed, __ATOMIC_ACQUIRE) == 0 &&
           __sync_bool_compare_and_swap(claimed, 0, 1);
}

/* detach 侧：看到 state==1（线程已退出）才尝试认领。 */
static int dead_reap_on_detach(volatile int *state, volatile int *claimed) {
    return __atomic_load_n(state, __ATOMIC_ACQUIRE) == 1 &&
           __sync_bool_compare_and_swap(claimed, 0, 1);
}

#endif
