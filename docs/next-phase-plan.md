# MoQiOS 下一阶段统一方案

> **版本**: v1.0
> **日期**: 2026-08-13
> **说明**: 本文档汇总各文档中记录的未完成工作项，给出统一的优先级排序与执行方案。
> 权威问题清单仍以 [current-code-review-and-fix-plan.md](./current-code-review-and-fix-plan.md) 为准；
> 本文是它的执行排序视图。

## 排序原则（性能最优的交付路径）

1. **正确性先于性能**：会造成静默数据丢失或持久性假承诺的条目排在所有优化之前。
2. **小步可验证**：每一项必须能独立通过 `zig build test`（主机门禁）和
   `zig build smoke` / `smoke-smp`（QEMU 门禁）后才提交，避免多特性纠缠。
3. **锁粒度与并行性优先于算法微调**：SMP 下已验证的瓶颈在共享队列串行化
   （驱动队列、UDP 接收队列），先做契约再做多队列扩展。
4. **环境受限项不阻塞流水线**：真机/KVM 验证单独成轨，不占主线。

## P0：本批次已完成（2026-08-13）

- Limine 固定版本由 `v8.0.14-binary` 更正为 `v8.7.0-binary`
  （`aad3edd370955449717a334f0289dee10e2c5f01`）：v8.0.14 不支持内核要求的
  base revision 3，QEMU 直接报 `Limine protocol not supported`；v8.7.0 是 smoke
  矩阵实际验证过的版本。同步更新 `tools/limine_bootstrap.sh`、合约测试、README
  与构建文档。
- moqi_libc 补齐 rlimit 包装器（`include/resource.h` + `src/rlimit.c`，原生
  236/237/238），关闭 [rlimit.md](./rlimit.md) 的 "libc wrappers are future
  integration work"；ABI 由宿主机测试 `test_rlimit_abi` 锁定。
- 用户态 stdout/stderr 写路径由逐字节 `writeByte` 改为按块（≤4096 字节）单次
  `writeString`：串口锁从每字节一次降为每块一次，既消除 SMP 下跨核字符级交错
  导致的 smoke 标记行涂抹（review §6.18 已知残余），又减少锁获取次数。
- 测试程序适配新创建元数据语义：`O_CREAT` 打开显式传入 `0666`（原先依赖内核
  忽略 mode）；hello53 的 `/dev/full` 读检查改用 `O_RDWR`（O_WRONLY 描述符读
  现在按 POSIX 返回 EBADF）。
- 本批未提交里程碑（RLIMIT_NOFILE、tmpfs DAC 第一阶段、capability profile、
  creation metadata/umask、init 监督器、spawn 报告、mkdir ABI、磁盘 fixture
  manifest、CI 时长观察）随本次统一验证后提交。

## P1：下一批执行项（小/中工作量，按序执行）

> **2026-08-13 代码对账**：下表最初按文档记录整理；逐项核对当前代码后，
> #2/#5/#6/#7/#8 五项**在内核中早已完成**（文档滞后于代码），证据见"状态"列。

| # | 条目 | 来源 | 状态（2026-08-13 对账） |
|---|------|------|------|
| 1 | FAT32/ext2 写路径检查 `writeBlockUncached`/`safeWriteSectors` 返回值 | review §5.2h–j | ✅ 完成（6.23）：direct-write 丢弃点全部传播或注释约定 |
| 2 | `vfs.syncFile` 错误传播 + 设备 flush barrier 能力上报 | review §5.2g/§5.6 | 代码已完成：`vfs.zig:1313` syncFile 返回 bool，fsync syscall 传播 `-5 EIO` |
| 3 | UDP 接收队列串行化 + MSG_TRUNC/MSG_PEEK 语义 | review §5.6 | ✅ 完成（6.23）：队列锁（J1）+ recvFromEx/recvFromV6Ex + recvfrom flags，hello50 验收；顺带修复 sendto/recvfrom flags 错读 rcx 的 ABI bug |
| 4 | virtio-blk/virtio-net/NVMe 队列 single-flight 锁契约 | review §5.5/§5.6 | ✅ 完成（6.36）：2026-08-15 逐驱动核对后确认 virtio-blk（`io_lock`，virtio_blk.zig:167 全请求串行）与 NVMe（每队列 `io_locks` + 显式锁序注释，nvme.zig:195-210）**早已加锁**；唯一真实缺口是 virtio-net TX——`sendPacket` 无锁并发改写共享 TX free list/描述符链/avail 环/完成索引。已加 `tx_lock`（IrqSpinlock）覆盖整笔事务（alloc→publish→notify→reclaim），并新增纯队列记账模块 `virtio_net_queue.zig` + host 测试锁定 single-flight 不变量；RX 保持无锁（仅 ISR 单所有者、独立 rx_queue，见 review §6.36 审计）。P1 至此全部关闭。 |
| 5 | `/dev/kmsg` 阻塞读/poll 唤醒，syslogd 改事件驱动 | user-space §7.1 | 代码已完成（J3：kmsg 读在最新字节处阻塞，syslogd 无轮询循环） |
| 6 | panic 停 AP 改 NMI（替代 ~10ms tick 轮询） | review §6.5/6.6 | 代码已完成：`panic.zig` sendNmiAllButSelf + idt NMI 处理 park，tick 轮询降为兜底 |
| 7 | IOAPIC 消费 MADT ISO 覆盖（电平/极性） | review §6.12–14 | 代码已完成：`ioapic.zig` routeGsi 应用 ISO trigger/polarity |
| 8 | `tryStealTask` 死代码：启用需补 `onContextSwitch`，否则删除 | review §6.10 | 代码已完成：已删除（sched.zig:1362 注记） |
| 9 | fbcon 被 fb0 映射停用后的恢复路径 | review §6.17 | ✅ 完成（6.24）：fbdev 映射登记（8 槽 + IrqSpinlock），munmap/mremap 裁剪、exit/exec 注销，归零即恢复 mirror；smoke 门禁新增 disabled/restored 双标记 |

## P2：中期项（需要 1–2 个专项迭代）

- pthread v2 三件套：~~detached 线程栈回收~~（✅ 6.25）、~~CLONE_FILES 真共享 fd 表~~（✅ 6.27）、~~`__thread`（PT_TLS）~~（✅ 6.28，crt0 auxv 发现 + variant II 布局，内核零改动）——**全部完成**。
- ~~AHCI/SATA 实际 I/O 路径与 `io_sched.tryMerge` 验证~~（✅ 6.32：QEMU
  ich9-ahci + scratch 盘 boot 自测全覆盖——读模式验证 + 写回读 + flush，
  顺手修复 NCQ FIS 寄存器映射反转的真 bug；io_sched 定论为不可达死代码
  且 tryMerge 确有缓冲区越界缺陷，整层删除）——真机存储前提已具备。
- ~~tmpfs 单文件 256 KiB 上限扩容~~（✅ 6.29 完成：一级间接页，64 直辖 + 512 间接 = 576 页 / 2.25 MiB，hello42 大文件验收；user-space §7.1）。
- `mmap_regions` 固定 64 条目 → 动态 VMA 树：已新增 `/proc/vma_stats`、纯模型
  host 测试与 hello67 碎片化基线，并由 hello73 验收 modeled/visited telemetry
  一致性（见 `vma-profiling.md`）；继续先以扫描压力和可重复 QEMU 前后数据证明
  需要，再决定是否替换，不能仅因 64 槽容量或 telemetry 单独提前重构，也不宣称
  wall-clock speedup（review §5.2g/§5.2t）。
- `mprotect` 验收以原子事务语义为准：先检查对齐、长度、保护位、用户范围和完整
  映射覆盖，并预留 VMA 分裂及页表资源；预检失败返回 `EINVAL`/`ENOMEM` 且不改变
  映射，成功后才提交 PTE 与保护元数据。`PROT_NONE` 保留帧以支持恢复，部分大页
  覆盖降级为 4 KiB 且保留数据；hello74 覆盖普通页、故障恢复、无效参数回滚和
  fork/COW。后续证据限于可复现的语义/一致性检查，不作 QEMU 墙钟速度声明。
- `sync_file_range`（hello76）验收以 syscall #290 的有界范围契约为准：只处理
  `[offset, offset + nbytes)`，`nbytes == 0` 为有界空操作；支持 flags 之外的标志位及
  `offset + nbytes` 溢出返回 `EINVAL`，无效 fd 返回 `EBADF`，管道/设备等不支持的描述符
 返回 `EINVAL`。使用既有 ext2 文件和 raw syscall 检查 regular-file/range、错误传播与
 close；不以 wall-clock、吞吐或持久化性能作结论。
- `readahead`（hello77）验收以 syscall #291 的 ext2/FAT32 bounded best-effort 契约为准：
  regular-file 只预取 `[offset, offset + count * 4096)`，`count == 0` 返回 0 且不改变 fd
  offset；无效 fd 返回 `EBADF`，管道/设备返回 `EINVAL`，范围溢出或超过 32 页返回 `EINVAL`。
  后续 read 必须保持正确；不作 wall-clock、吞吐或命中率声明。
- `socketpair`（hello78）验收以 raw syscall #53 的严格支持边界为准：只支持
  `AF_UNIX`/`SOCK_STREAM`/protocol `0`，成功返回一对可双向 `write`/`read` 的 pipe-backed fd；
  非法 domain/type/protocol 返回 `EINVAL`，坏 `sv` 指针返回 `EFAULT`，失败不得泄漏 fd，成功
  的两个 fd 都关闭。证据限于 syscall 参数校验、双向数据语义和资源清理，不作完整 Unix
  socket 兼容性、wall-clock、吞吐或持久化性能声明。
- `fallocate`（hello79）验收以 raw syscall #274 的严格模式边界为准：只支持 regular file
  上的 `mode == 0` 有界范围；所有非零 mode 必须在目标查找和修改之前返回 `EOPNOTSUPP`，且不得改变
  文件大小。无效 fd 返回 `EBADF`；pipe/device 等不支持目标只接受文档规定的 `EINVAL` 或
  `EOPNOTSUPP`。验收只证明 syscall 语义、错误传播和大小不变性，不作 wall-clock、吞吐、
  分配速度或持久化性能声明。
- `acct`/`unshare`/`process_madvise`/Landlock（hello80）验收以当前 native dispatcher 的显式
  `ENOSYS` unsupported boundary 为准：raw syscall #281/#282/#440/#444-#446 必须在目标查找、
  namespace/LSM 状态处理或用户缓冲区读写之前返回 `ENOSYS`，并保持所有 sentinel buffer 不变。
  该门禁只锁定“不支持”的 ABI 合约，不代表实现 process accounting、namespace、跨进程 madvise
  或 Landlock；若 dispatcher 仍返回 no-op 成功，验收必须失败，不能由测试放宽为成功。
- ~~2MB 大页（尤其文件映射）与 fork COW OOM 半途回滚~~（review §5.6/§6.8）——
  fork COW 部分 ✅ 6.34（三阶段事务化克隆，两条路径）；文件映射部分 ✅ 6.35
  以 fault-around 预缺页收口：真 2MiB PDE 与零拷贝 MAP_SHARED 设计物理上
  不兼容（后备帧逐 4K 分配不连续），分析定论见 kernel-subsystems §1.8.1。
- smoke 门禁 CI 化（当前 CI 只跑主机测试；QEMU 门禁依赖本地环境，review §1）。
- rlimit 扩展到 NOFILE 之外的资源（先定执行语义再实现，避免 stub 蔓延）——
  ~~RLIMIT_STACK~~（✅ 6.31：缺页增长地板执行 + 真实 set/get/prlimit64，hello59 验收）、
  ~~RLIMIT_AS~~（✅ 6.33：as_used 计费 + mmap/brk/mremap/栈增长执行点，hello60 验收）、
  ~~RLIMIT_NPROC~~（✅ 6.37：per-UID 活任务计数 + fork/clone/spawn 前置 EAGAIN 闸点，
  hello64 验收）、~~RLIMIT_DATA~~（✅ 6.38：独立 `data_used` 账本——brk 增长 +
  可写私有 mmap 计费，munmap/mremap/brk shrink/MAP_FIXED/exec 退款，hello63 验收；
  与 RLIMIT_AS 独立）、~~RLIMIT_FSIZE~~（✅：常规文件写入边界、SIGXFSZ、pwrite/
  writev 统一预检，hello66 验收）。`RLIMIT_RSS` 当前仅有 x86 present-user-PTE
  观测 telemetry（`/proc/<pid>/rss`、hello68），仍保持 reported-only；安全 enforcement
  需独立的 shared-address-space resident ledger。剩余资源（CORE 与 RSS enforcement）
  仍待各自语义定稿。

## P3：大项（需独立设计评审，不与其他工作混批）

- ~80 处 `_ = copyToUser(...)` 返回值治理（review §5.2q，大且易回归，需分批 + 全程门禁）。
- 地址空间并发：统一锁/TLB shootdown 契约，以及超出当前有界策略的 MAP_FIXED 事务回滚；
  当前策略只接受精确覆盖、完整跟踪的匿名私有 RW 4K PMM-owned 区域，长度最多 128 页。
  资源检查或形状不支持时返回 `ENOMEM` 且不改变原映射，成功替换后的页面为零填充。
  该策略不是全局并发安全保证。
  `process_vm_readv/writev` 的引用计数 mm 抽象（review §5.5/§5.6）。
- riscv64/aarch64 跑通用户进程 + `main.zig` 初始化收敛到共享 arch 抽象
  （cross-arch-port-plan）。
- 微内核服务化第一批迁移（netstack 或 vfs 迁出内核，依托已验证的 devfs
  用户态节点机制，moqios-design §5）。
- Windows PE 兼容 personality（moqios-design §4/§10 Phase 3）。

## 独立轨道（环境受限）

- 真机/KVM 验证包：AP LAPIC 定时器、PCID no-flush 硅验证、GSI≥16 真实设备。
- QEMU slirp ARP/connect 偶发抖动为上游既有行为，不修；真实 DNS 端到端依赖
  宿主机网络。

## 验证门禁

- 每个 P1 条目：主机测试（`zig build test`）+ 单核 smoke；涉及调度/SMP 的条目
  追加 `smoke-smp`（至少 2/4 核）。
- 性能相关条目合并前在 PR 描述中给出前后对照（如 syslogd 轮询 → 事件驱动的
  唤醒次数、kmsg 读取延迟）。
- CI（`.github`）对推送与 PR 运行 `zig build test` 并记录时长观察（非门禁）。
