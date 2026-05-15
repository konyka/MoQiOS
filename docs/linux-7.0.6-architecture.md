# Linux 7.0.6 内核源码架构文档

> 版本：7.0.6 | 许可：GPL-2.0 | 大小：1.7GB  
> 路径：`3rd/linux-7.0.6/`  
> 在 MoQiOS 中的用途：**参考实现**（系统调用语义、协议栈行为、驱动接口、文件系统实现）

---

## 1. 项目概览

| 属性 | 值 |
|---|---|
| **版本** | 7.0.6 |
| **许可证** | GPL-2.0 |
| **源码大小** | 1.7GB |
| **构建系统** | Kbuild (Makefile + Kconfig) |
| **支持架构** | x86, arm64, riscv, mips, powerpc, s390 等 23 种 |
| **语言** | C 主体 + Rust (实验性) + 汇编 |
| **用途** | 作为 MoQiOS 的系统调用参考和协议栈行为参考 |

### 1.1 顶层目录结构

```
linux-7.0.6/
├── arch/           # 架构相关代码 (23 种 CPU 架构)
├── block/          # 块设备 I/O 层 (blk-mq, 电梯算法)
├── certs/          # 证书签名
├── crypto/         # 加密子系统 (对称/非对称/哈希)
├── Documentation/  # 内核文档 (极其详尽)
├── drivers/        # 设备驱动 (最大目录)
├── fs/             # 文件系统 (VFS + 具体实现)
├── include/        # 内核头文件
├── init/           # 内核启动入口
├── io_uring/       # io_uring 异步 I/O
├── ipc/            # 进程间通信
├── kernel/         # 核心内核代码 (调度, 信号, 进程)
├── lib/            # 内核通用库
├── LICENSES/       # 许可证文本
├── mm/             # 内存管理
├── net/            # 网络协议栈
├── rust/           # Rust 语言支持
├── samples/        # 示例代码
├── scripts/        # 构建和工具脚本
├── security/       # 安全框架 (LSM, SELinux)
├── sound/          # ALSA 声音子系统
├── tools/          # 用户空间工具
├── usr/            # initramfs
└── virt/           # 虚拟化 (KVM)
```

---

## 2. 构建系统

Linux 使用 **Kbuild** 构建系统，由以下组件构成：

| 文件 | 职责 |
|---|---|
| `Makefile` (74KB) | 顶层 Makefile，定义构建规则 |
| `Kconfig` | 顶层配置入口 |
| `scripts/kconfig/` | 配置解析器 (menuconfig) |
| 各子目录 `Kconfig` | 子系统配置选项 |
| 各子目录 `Makefile` | 子系统构建规则 |

---

## 3. 核心子系统详解

### 3.1 进程管理 (kernel/)

**路径：** `kernel/` (607 个源文件)  
**职责：** 进程/线程管理、调度器、信号、系统调用、时间管理、BPF

#### 子目录结构

| 目录 | 职责 | 关键文件 |
|---|---|---|
| `sched/` | CPU 调度器 | `core.c` (调度核心), `fair.c` (CFS), `rt.c` (实时), `deadline.c` |
| `entry/` | 系统调用入口 | `syscall_64.c`, `common.c` |
| `futex/` | 快速用户空间互斥 | `core.c`, `pi.c` (优先级继承) |
| `locking/` | 锁原语 | `mutex.c`, `spinlock.c`, `rwsem.c`, `rtmutex.c` |
| `irq/` | 中断管理 | `manage.c`, `chip.c`, `msi.c` |
| `time/` | 时间子系统 | `timer.c`, `hrtimer.c`, `posix-timers.c` |
| `bpf/` | BPF 子系统 | `syscall.c`, `verifier.c`, `arraymap.c` |
| `cgroup/` | 控制组 | `cgroup.c`, `cpuset.c`, `memory.c` |
| `events/` | 性能事件 | `core.c`, `ring_buffer.c` |
| `power/` | 电源管理 | `process.c`, `suspend.c` |
| `module/` | 模块加载 | `main.c`, `signing.c` |
| `rcu/` | RCU 机制 | `tree.c`, `update.c` |
| `printk/` | 内核日志 | `printk.c` |
| `dma/` | DMA 映射 | `mapping.c`, `debug.c` |
| `debug/` | 调试工具 | `kgdb.c`, `kdb/` |
| `livepatch/` | 热补丁 | `core.c`, `patch.c` |

#### 核心文件 (kernel/ 根目录)

| 文件 | 职责 |
|---|---|
| `fork.c` | 进程创建 (clone, fork, vfork) |
| `exec_domain.c` | exec 系统调用 |
| `exit.c` | 进程退出 |
| `signal.c` | 信号处理 |
| `pid.c` | PID 分配 |
| `cred.c` | 进程凭证 (uid/gid/capabilities) |
| `sys.c` | 杂项系统调用 |
| `cpu.c` | CPU 热插拔 |
| `notifier.c` | 通知链 |
| `resource.c` | I/O 资源管理 |
| `audit.c` | 审计框架 |
| `capability.c` | POSIX capabilities |

#### 调度器架构 (kernel/sched/)

```
                    ┌──────────────────┐
                    │  sched_core.c    │
                    │  调度核心框架     │
                    └───────┬──────────┘
                            │
          ┌─────────────────┼─────────────────┐
          ▼                 ▼                 ▼
  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
  │   fair.c     │ │    rt.c      │ │ deadline.c   │
  │  CFS 调度器   │ │  实时调度器   │ │  Deadline    │
  │  (完全公平)   │ │  (SCHED_FIFO │ │  (SCHED_     │
  │              │ │   SCHED_RR)  │ │  DEADLINE)   │
  └──────────────┘ └──────────────┘ └──────────────┘
          │                 │                 │
          └─────────────────┼─────────────────┘
                            ▼
                    ┌──────────────┐
                    │  idle.c      │
                    │  空闲调度类   │
                    └──────────────┘
```

**关键调度器文件：**
- `core.c` — 调度核心：`schedule()`, `context_switch()`, `pick_next_task()`
- `fair.c` — CFS (完全公平调度器)：虚拟运行时间，红黑树
- `rt.c` — 实时调度：SCHED_FIFO, SCHED_RR
- `deadline.c` — Deadline 调度：EDF 算法
- `topology.c` — 调度域拓扑
- `cpufreq.c` / `cpufreq_schedutil.c` — CPU 频率调节
- `stats.c` — 调度统计
- `psi.c` — PSI (Pressure Stall Information)

---

### 3.2 内存管理 (mm/)

**路径：** `mm/` (191 个源文件)  
**职责：** 物理内存管理、虚拟内存、页面回收、slab 分配器

#### 关键文件

| 文件 | 职责 |
|---|---|
| `page_alloc.c` | 伙伴系统分配器 (`alloc_pages`, `__free_pages`) |
| `slab.c` | SLAB 分配器接口 |
| `slub.c` | SLUB 分配器 (默认) |
| `slob.c` | SLOB 分配器 (嵌入式) |
| `mmap.c` | mmap 系统调用 |
| `mremap.c` | mremap 系统调用 |
| `munmap.c` | munmap 系统调用 |
| `mprotect.c` | mprotect 系统调用 |
| `vma.c` | VMA (虚拟内存区域) 管理 |
| `vmalloc.c` | vmalloc 分配器 |
| `page_fault.c` | 缺页处理 |
| `gup.c` | get_user_pages (页钉住) |
| `filemap.c` | 页缓存 (address_space) |
| `swap.c` | 交换空间管理 |
| `swap_state.c` | 交换缓存 |
| `vmscan.c` | 页面回收 (kswapd) |
| `compaction.c` | 内存规整 |
| `oom_kill.c` | OOM Killer |
| `hugetlb.c` | 大页支持 |
| `huge_memory.c` | 透明大页 (THP) |
| `memory.c` | 核心内存操作 (缺页, COW) |
| `rmap.c` | 反向映射 |
| `kmemleak.c` | 内存泄漏检测 |
| `cma.c` | 连续内存分配器 |
| `memory_hotplug.c` | 内存热插拔 |
| `percpu.c` | per-CPU 变量分配器 |
| `shmem.c` | 共享内存 (tmpfs) |
| `memfd.c` | memfd_create |

---

### 3.3 文件系统 (fs/)

**路径：** `fs/` (2,107 个源文件)  
**职责：** VFS 抽象层和具体文件系统实现

#### VFS 核心文件

| 文件 | 职责 |
|---|---|
| `inode.c` | Inode 管理 |
| `dentry.c` | 目录项缓存 (dcache) |
| `dcache.c` | dcache 核心算法 |
| `file.c` | 文件操作 |
| `file_table.c` | 文件表管理 |
| `open.c` | open/close 系统调用 |
| `read_write.c` | read/write 系统调用 |
| `readdir.c` | 目录读取 |
| `namei.c` | 路径查找 |
| `stat.c` | stat 系统调用 |
| `mount.c` | 挂载管理 |
| `namespace.c` | 命名空间 |
| `super.c` | 超级块管理 |
| `block_dev.c` | 块设备文件 |
| `char_dev.c` | 字符设备文件 |
| `pipe.c` | 管道 |
| `eventpoll.c` | epoll |
| `eventfd.c` | eventfd |
| `signalfd.c` | signalfd |
| `timerfd.c` | timerfd |
| `splice.c` | splice/tee |
| `aio.c` | POSIX AIO |
| `binfmt_elf.c` | ELF 加载器 |
| `binfmt_script.c` | 脚本加载器 |
| `exec.c` | execve |
| `buffer.c` | 块缓冲 |
| `mpage.c` | 多页 I/O |
| `direct-io.c` | 直接 I/O |
| `xattr.c` | 扩展属性 |
| `acl.c` | ACL |
| `notify/` | inotify/fanotify |
| `proc/` | /proc 文件系统 |
| `sysfs/` | sysfs |
| `debugfs/` | 调试文件系统 |
| `configfs/` | 配置文件系统 |
| `devpts/` | /dev/pts |
| `tmpfs/` (shmem.c) | tmpfs |

#### 支持的文件系统

| 文件系统 | 路径 | 类型 |
|---|---|---|
| ext4 | `fs/ext4/` | 日志文件系统 (默认) |
| ext2 | `fs/ext2/` | 经典 Linux FS |
| xfs | `fs/xfs/` | 高性能 64-bit FS |
| btrfs | `fs/btrfs/` | COW, 快照, 子卷 |
| f2fs | `fs/f2fs/` | Flash 友好 FS |
| jffs2 | `fs/jffs2/` | JFFS2 (MTD) |
| squashfs | `fs/squashfs/` | 只读压缩 FS |
| ntfs3 | `fs/ntfs3/` | NTFS 读写 |
| nfs | `fs/nfs/` | NFS 客户端 |
| cifs/smb | `fs/smb/` | SMB/CIFS 客户端 |
| 9p | `fs/9p/` | 9P 协议 (Virtio) |
| overlayfs | `fs/overlayfs/` | 联合挂载 |
| ecryptfs | `fs/ecryptfs/` | 加密文件系统 |
| fat/vfat | `fs/fat/` | FAT 文件系统 |
| isofs | `fs/isofs/` | ISO 9660 |
| coda | `fs/coda/` | Coda 网络FS |
| ceph | `fs/ceph/` | CephFS |
| autofs | `fs/autofs/` | 自动挂载 |
| cachefiles | `fs/cachefiles/` | FS 缓存 |
| 还有更多 | `fs/*/` | afs, befs, bfs, cramfs, efs, hfs, hfsplus, jfs, minix, omfs, qnx4, qnx6, reiserfs, romfs, sysv, ubifs, udf, ufs |

---

### 3.4 网络协议栈 (net/)

**路径：** `net/` (1,817 个源文件)  
**职责：** 完整 TCP/IP 网络协议栈

#### 协议层次

```
┌──────────────────────────────────────────────────────┐
│                  应用层 Socket API                     │
│  net/socket.c, net/sysctl_net.c                      │
├──────────────────────────────────────────────────────┤
│                  传输层                                │
│  net/ipv4/tcp_*.c  │  net/ipv4/udp.c  │  net/sctp/   │
├──────────────────────────────────────────────────────┤
│                  网络层                                │
│  net/ipv4/af_inet.c, ip_input, ip_output, icmp      │
│  net/ipv6/ (完整 IPv6)                               │
├──────────────────────────────────────────────────────┤
│                  链路层/邻居                           │
│  net/ethernet/  │  net/core/dev.c (net_device)       │
│  net/bridge/    │  net/8021q/ (VLAN)                 │
├──────────────────────────────────────────────────────┤
│                  驱动层                                │
│  drivers/net/ethernet/ (6,134 个源文件)               │
├──────────────────────────────────────────────────────┤
│                  安全/过滤                             │
│  net/netfilter/  │  net/xfrm/  │  security/         │
└──────────────────────────────────────────────────────┘
```

#### 关键子目录

| 目录 | 职责 |
|---|---|
| `core/` | 网络核心：`dev.c` (设备框架), `sock.c` (socket), `skbuff.c` (skb) |
| `ipv4/` | IPv4 协议栈：TCP, UDP, ICMP, IP, ARP, 路由 |
| `ipv6/` | IPv6 协议栈 |
| `netfilter/` | 防火墙框架 (iptables/nftables) |
| `xfrm/` | IPsec 变换框架 |
| `unix/` | Unix 域 socket |
| `packet/` | AF_PACKET 原始套接字 |
| `bridge/` | 桥接 |
| `8021q/` | VLAN |
| `sched/` | 流量控制 (tc) |
| `tls/` | 内核 TLS |
| `mptcp/` | 多路径 TCP |
| `bluetooth/` | 蓝牙 |
| `mac80211/` | WiFi (mac80211) |
| `ethernet/` | 以太网通用代码 |
| `bpf/` | BPF 网络程序 |
| `sunrpc/` | Sun RPC |
| `ceph/` | Ceph 网络 |
| `openvswitch/` | Open vSwitch |
| `xdp/` | XDP (eXpress Data Path) |
| `dcb/` | 数据中心桥接 |
| `devlink/` | DevLink |
| `handshake/` | TLS 握手 |

---

### 3.5 设备驱动 (drivers/)

**路径：** `drivers/` (最大目录，数十万文件)

#### 主要子目录

| 目录 | 文件数 | 职责 |
|---|---|---|
| `gpu/` | 7,344 | GPU 驱动 (drm/i915, amdgpu, nouveau) |
| `net/` | 6,134 | 网卡驱动 (intel, realtek, broadcom, mellanox) |
| `pci/` | 239 | PCI/PCIe 总线 |
| `virtio/` | 22 | virtio 设备 |
| `block/` | 89 | 块设备驱动 |
| `ata/` | — | SATA/IDE |
| `scsi/` | — | SCSI/SAS |
| `nvme/` | — | NVMe |
| `usb/` | — | USB 主机/设备 |
| `input/` | — | 输入设备 (键盘/鼠标/触摸屏) |
| `i2c/` | — | I2C 总线 |
| `spi/` | — | SPI 总线 |
| `gpio/` | — | GPIO |
| `acpi/` | — | ACPI 驱动 |
| `clk/` | — | 时钟框架 |
| `regulator/` | — | 电压调节器 |
| `thermal/` | — | 温度管理 |
| `mmc/` | — | MMC/SD/SDIO |
| `mtd/` | — | Memory Technology Devices |
| `sound/` (alsa) | — | ALSA 声音驱动 |
| `bluetooth/` | — | 蓝牙驱动 |
| `crypto/` | — | 硬件加密 |
| `dma/` | — | DMA 引擎 |
| `char/` | — | 字符设备 |
| `tty/` | — | TTY/串口 |
| `hid/` | — | HID 设备 |
| `platform/` | — | 平台设备 |
| `firmware/` | — | 固件加载 |
| `reset/` | — | 复位控制器 |

---

### 3.6 块设备层 (block/)

**路径：** `block/` (89 个源文件)

| 文件 | 职责 |
|---|---|
| `blk-core.c` | 块层核心 (bio 提交) |
| `blk-mq.c` | 多队列块 I/O (blk-mq) |
| `blk-mq-sched.c` | blk-mq 调度器框架 |
| `elevator.c` | I/O 调度器接口 |
| `blk-settings.c` | 队列设置 |
| `partitions/` | 分区解析 (MSDOS, GPT, EFI) |

---

### 3.7 进程间通信 (ipc/)

**路径：** `ipc/` (12 个源文件)

| 文件 | 职责 |
|---|---|
| `shm.c` | 共享内存 (System V + POSIX) |
| `msg.c` | 消息队列 |
| `sem.c` | 信号量 |
| `mqueue.c` | POSIX 消息队列 |
| `namespace.c` | IPC 命名空间 |
| `util.c` | IPC 工具函数 |

---

### 3.8 安全框架 (security/)

**路径：** `security/` (262 个源文件)

| 目录/文件 | 职责 |
|---|---|
| `security.c` | LSM (Linux Security Module) 框架 |
| `selinux/` | SELinux 实现 |
| `apparmor/` | AppArmor 实现 |
| `smack/` | SMACK 实现 |
| `tomoyo/` | TOMOYO 实现 |
| `bpf/` | BPF LSM |
| `integrity/` | 完整性子系统 (IMA/EVM) |
| `keys/` | 密钥管理 |
| `landlock/` | Landlock 沙箱 |
| `capabilities.c` | POSIX capabilities |
| `min_addr.c` | 最小地址映射限制 |

---

### 3.9 加密子系统 (crypto/)

**路径：** `crypto/` (173 个源文件)

| 子目录/文件 | 职责 |
|---|---|
| `api.c`, `cipher.c` | 加密 API 框架 |
| `aes_generic.c` | AES 软件实现 |
| `sha256_generic.c` | SHA-256 |
| `rsa.c` | RSA |
| `ecdsa.c` | ECDSA |
| `hkdf.c` | HKDF |
| `asymmetric_keys/` | 非对称密钥验证 |
| `krb5/` | Kerberos 5 加密 |

---

### 3.10 初始化 (init/)

**路径：** `init/` (13 个源文件)

| 文件 | 职责 |
|---|---|
| `main.c` | `start_kernel()` — 内核主初始化入口 |
| `do_mounts.c` | 根文件系统挂载 |
| `do_mounts_initrd.c` | initrd 处理 |
| `calibrate.c` | BogoMIPS 校准 |
| `version.c` | 版本信息 |

**启动流程：** `start_kernel()` → `setup_arch()` → `mm_init()` → `sched_init()` → `rest_init()` → `kernel_init()` → 执行 `/sbin/init`

---

### 3.11 IO_uring (io_uring/)

**路径：** `io_uring/` (82 个源文件)

高性能异步 I/O 框架，使用共享环形缓冲区实现用户空间和内核之间的零拷贝通信。

| 文件 | 职责 |
|---|---|
| `io_uring.c` | io_uring 核心实现 |
| `sqpoll.c` | SQPOLL 内核线程 |
| `rsrc.c` | 资源注册 |
| `opdef.c` | 操作定义 |
| `rw.c` | 读写操作 |
| `net.c` | 网络操作 |
| `fs.c` | 文件系统操作 |
| `poll.c` | 轮询操作 |
| `timeout.c` | 超时操作 |

---

### 3.12 架构支持 (arch/)

**路径：** `arch/` — 支持 23 种 CPU 架构：

| 架构 | 目录 | 说明 |
|---|---|---|
| x86 | `arch/x86/` | Intel/AMD (主要开发架构) |
| arm64 | `arch/arm64/` | ARM 64-bit (服务器/移动) |
| riscv | `arch/riscv/` | RISC-V (新兴) |
| loongarch | `arch/loongarch/` | 龙芯 |
| powerpc | `arch/powerpc/` | PowerPC |
| s390 | `arch/s390/` | IBM System z |
| mips | `arch/mips/` | MIPS |
| sparc | `arch/sparc/` | SPARC |
| arm | `arch/arm/` | ARM 32-bit |
| 其他 | alpha, arc, csky, hexagon, m68k, microblaze, nios2, openrisc, parisc, sh, um, xtensa | 各种嵌入式/遗留架构 |

---

### 3.13 Rust 支持 (rust/)

**路径：** `rust/`  
Linux 7.0.6 包含实验性的 Rust 语言支持，允许用 Rust 编写内核模块。

| 文件/目录 | 职责 |
|---|---|
| `kernel/` | Rust 内核绑定 |
| `macros/` | Rust 过程宏 |
| `bindings/` | 自动生成的 C 绑定 |
| `pin-init/` | 安全的初始化 API |

---

### 3.14 内核库 (lib/)

**路径：** `lib/` (6,762 个源文件)

提供内核通用工具函数：

| 文件 | 职责 |
|---|---|
| `string.c` | 字符串操作 |
| `vsprintf.c` | 格式化输出 |
| `sort.c` | 排序 |
| `rbtree.c` | 红黑树 |
| `list_debug.c` | 链表 |
| `hashtable.c` | 哈希表 |
| `radix-tree.c` | 基数树 |
| `xarray.c` | XArray |
| `bitmap.c` | 位图 |
| `crc32.c` | CRC32 |
| `sha256.c` | SHA-256 |
| `zlib_deflate/` | zlib 压缩 |
| `lz4/` | LZ4 压缩 |
| `zstd/` | ZSTD 压缩 |
| `crypto/` | 加密辅助 |
| `argv_split.c` | 参数解析 |
| `ctype.c` | 字符类型 |
| `hexdump.c` | 十六进制转储 |
| `scatterlist.c` | scatter-gather 列表 |

---

## 4. 在 MoQiOS 中的参考价值

| 领域 | 参考内容 |
|---|---|
| **系统调用** | 138 个系统调用的语义和返回值规范 |
| **调度器** | CFS/RT/Deadline 调度算法参考 |
| **文件系统** | ext4 日志、VFS 层设计模式 |
| **网络栈** | TCP 状态机、拥塞控制、OOO 处理 |
| **内存管理** | 伙伴系统、slab 分配器、页回收 |
| **驱动模型** | PCI/virtio/NVMe 驱动接口 |
| **同步原语** | futex、mutex、spinlock、RCU |
