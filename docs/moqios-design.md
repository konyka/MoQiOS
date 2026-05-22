# MoQiOS 操作系统设计文档

> **版本**: v0.4 (设计文档 — 长期目标)
> **日期**: 2026-05-22  
> **技术栈**: Zig + x86_64/AArch64 汇编  
> **架构**: 微内核 (Microkernel) — 设计目标，尚未实现
> **核心目标**: Linux + Windows 双二进制兼容 — 设计目标，尚未实现
> **补充章节**: §12 审计修正 · §13 调试架构 · §14 中断子系统 · §15 Capability · §16 性能优化 · §17 服务管理 · §18 驱动生态 · §19 内存与I/O基础设施
>
> **注意**: 本文档描述 MoQiOS 的**长期设计目标**，包括微内核架构、Windows 二进制兼容等尚未实现的功能。当前实际实现状态请参见 [moqios-architecture-current.md](./moqios-architecture-current.md)。截至 2026-05-22，MoQiOS 是一个单体内核，支持 35 个系统调用、FAT32 文件系统、e1000 网络和基本的用户空间程序。

---

## 1. 项目定位与设计目标

### 1.1 一句话定义

MoQiOS 是一个基于微内核架构的操作系统，使用 Zig + 汇编实现，能够在同一系统上**原生运行未经修改的 Linux ELF 二进制和 Windows PE 二进制**。

### 1.2 设计目标

| 优先级 | 目标 | 说明 |
|---|---|---|
| P0 | Linux 二进制兼容 | 运行静态链接的 ELF 二进制 (BusyBox 等)，覆盖 Linux ~200 个核心 syscall |
| P0 | Windows 二进制兼容 | 运行依赖 ntdll.dll 的 PE 二进制，覆盖 NT 核心 API |
| P1 | 微内核架构 | 内核 < 15,000 行，进程调度 + IPC + 中断管理 + 基本内存管理 |
| P1 | 高可靠性 | 驱动/服务在用户空间运行，崩溃可自动重启 |
| P2 | 多架构支持 | x86_64 (首发) → AArch64 |
| P2 | 实时能力 | 可选的实时调度策略 (SCHED_FIFO/RR) |
| P3 | POSIX 兼容 | 通过 Linux 兼容层间接实现 POSIX 兼容 |

### 1.3 非目标 (明确排除)

- **不追求** 100% Linux syscall 覆盖 (以实际应用需求驱动)
- **不追求** Windows GUI 子系统 (Win32k) — 仅核心 NT API
- **不追求** 二进制驱动兼容 — 驱动需要为 MoQiOS 重写
- **不追求** 多用户/企业级安全 — 初期采用简化的安全模型

### 1.4 参考实现

| 参考 | 用途 |
|---|---|
| Zigix (3rd/zigix/) | Zig 内核实现、Linux syscall 翻译、ELF 加载、clone/fork/execve |
| MINIX 3 (3rd/MINUX3/) | 微内核 IPC 设计 (send/receive/notify)、用户空间服务模型 |
| QNX Neutrino (3rd/QNXNeutrino/) | 微内核消息传递 (MsgSend/Receive/Reply)、实时调度 |
| ReactOS (3rd/reactos/) | Windows NT 兼容层、ntdll 实现、PE 加载、NT 执行体分层 |
| Linux 7.0.6 (3rd/linux-7.0.6/) | 系统调用语义参考、VFS 设计 |
| Dim-Sum (3rd/dim-sum/) | 简化内核实现参考 |

---

## 2. 整体架构

### 2.1 架构总览图

```
┌─────────────────────────────────────────────────────────────────────┐
│                          用户空间                                    │
│                                                                     │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐  │
│  │   Linux 应用      │  │  Windows 应用     │  │  MoQiOS 原生应用  │  │
│  │   (ELF 二进制)    │  │  (PE 二进制)      │  │  (ELF/自有格式)  │  │
│  └────────┬─────────┘  └────────┬─────────┘  └────────┬─────────┘  │
│           │                      │                      │            │
│           ▼                      ▼                      ▼            │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐  │
│  │   Linux 兼容库    │  │   ntdll.dll      │  │   MoQiOS libc    │  │
│  │   (musl/libc)    │  │   (兼容实现)      │  │   (自研/移植)    │  │
│  └────────┬─────────┘  └────────┬─────────┘  └────────┬─────────┘  │
│           │ syscall              │ Nt* API              │            │
│           │ 指令                 │ syscall 指令         │ send/recv  │
├───────────┼──────────────────────┼──────────────────────┼───────────┤
│           ▼                      ▼                      ▼            │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                     系统调用入口层                             │   │
│  │  ┌────────────────┐  ┌─────────────────┐  ┌──────────────┐  │   │
│  │  │ Linux syscall  │  │ Windows NT API  │  │ MoQiOS IPC   │  │   │
│  │  │ 分发器          │  │ 分发器           │  │ 分发器        │  │   │
│  │  └───────┬────────┘  └────────┬────────┘  └──────┬───────┘  │   │
│  └──────────┼─────────────────────┼──────────────────┼──────────┘   │
│             │                     │                  │               │
│             ▼                     ▼                  ▼               │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │               Personality Server 层 (用户空间)                │   │
│  │  ┌──────────────────────┐  ┌──────────────────────────────┐  │   │
│  │  │ Linux Personality    │  │ Windows Personality          │  │   │
│  │  │  ├─ 进程管理 (fork等) │  │  ├─ NT 对象管理器           │  │   │
│  │  │  ├─ 信号投递          │  │  ├─ PE 加载器               │  │   │
│  │  │  ├─ ELF 加载器       │  │  ├─ SEH 异常分发            │  │   │
│  │  │  ├─ /proc /sys 模拟  │  │  ├─ 注册表模拟             │  │   │
│  │  │  └─ Linux VFS 语义   │  │  ├─ NT 路径解析            │  │   │
│  │  │                      │  │  └─ Winsock 翻译           │  │   │
│  │  └──────────┬───────────┘  └──────────────┬───────────────┘  │   │
│  └─────────────┼──────────────────────────────┼─────────────────┘   │
│                │         统一 IPC 接口         │                      │
│                ▼                              ▼                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │               系统服务层 (用户空间)                            │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────────┐  │   │
│  │  │ 进程管理 │  │ 文件系统 │  │ 内存管理 │  │  设备管理  │  │   │
│  │  │  (PM)    │  │  (VFS)   │  │  (VMM)   │  │  (DevMgr)  │  │   │
│  │  └────┬─────┘  └────┬─────┘  └────┬─────┘  └─────┬──────┘  │   │
│  └───────┼──────────────┼──────────────┼──────────────┼─────────┘   │
│          │              │              │              │              │
│          │    ┌─────────┴──────────────┴──────────┐   │              │
│          │    │           设备驱动 (用户空间)       │   │              │
│          │    │  磁盘 │ 网络 │ GPU │ 输入 │ 时钟   │   │              │
│          │    └────────────────┬───────────────────┘   │              │
├──────────┼────────────────────┼────────────────────────┼──────────────┤
│          │                    IPC / 系统调用            │              │
│          ▼                    ▼                         ▼              │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                     微内核 (MoQi Kernel)                      │   │
│  │                    Zig 实现，< 15,000 行                      │   │
│  │                                                              │   │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────┐   │   │
│  │  │  调度器   │ │ IPC 引擎 │ │ 中断管理 │ │ 地址空间管理 │   │   │
│  │  │ scheduler│ │ ipc.zig  │ │ irq.zig  │ │   vmm.zig    │   │   │
│  │  └──────────┘ └──────────┘ └──────────┘ └──────────────┘   │   │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────┐   │   │
│  │  │  定时器   │ │ 能力安全 │ │ SMP 同步 │ │  系统调用    │   │   │
│  │  │ timer.zig│ │ caps.zig │ │ smp.zig  │ │  entry.zig   │   │   │
│  │  └──────────┘ └──────────┘ └──────────┘ └──────────────┘   │   │
│  └──────────────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                   硬件抽象层 (HAL)                            │   │
│  │        x86_64: IDT/GDT/APIC  │  AArch64: GIC/MMU/SPSR       │   │
│  │              汇编入口 + Zig 实现                               │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 核心设计原则

| 原则 | 描述 | 参考来源 |
|---|---|---|
| **最小内核** | 内核仅做调度、IPC、中断、地址空间管理 | MINIX 3, QNX |
| **Personality Server** | Linux/Windows 各一个 Personality Server，翻译 ABI 语义 | Windows NT 环境子系统 |
| **能力安全** | 所有 IPC 通道通过 capability token 授权 | seL4, MINIX 3 |
| **故障隔离** | 每个服务/驱动独立地址空间，崩溃可重启 | MINIX 3 RS (重启管理器) |
| **分层翻译** | syscall → 内核 IPC → Personality → 系统服务 | QNX, MINIX 3 |

### 2.3 为什么选择 Personality Server 模式？

**方案对比：**

| 方案 | 描述 | 优点 | 缺点 |
|---|---|---|---|
| **A: 统一内核翻译** | 内核直接处理两种 syscall | 性能好 | 内核膨胀，丧失微内核优势 |
| **B: Personality Server** (✅ 选定) | 用户空间服务翻译 ABI | 内核极简，故障隔离 | IPC 开销 (需优化) |
| **C: 双内核** | 两个独立内核共存 | 完全隔离 | 内存浪费，无法共享资源 |

选择 B 的核心理由：
1. **保持微内核纯粹性** — 内核不包含任何 ABI 特定逻辑
2. **可独立演进** — Linux/Windows 兼容层可以独立开发、调试、崩溃重启
3. **参考先例** — Windows NT 原本就有 POSIX/OS2/Win32 三个环境子系统

---

## 3. 微内核设计 (kernel/)

### 3.1 内核职责边界

内核**只做**以下事情，绝对不做更多：

```
✅ 进程/线程调度
✅ IPC 消息传递 (send, receive, notify, call+reply)
✅ 中断路由 (硬件中断 → 用户空间驱动)
✅ 地址空间管理 (页表创建/销毁, 映射/解除映射)
✅ 定时器 (高精度定时器, tick 调度)
✅ 能力检查 (IPC 授权验证)
✅ SMP 同步 (IPI, 原子操作)
✅ 系统调用入口 (路由到 Personality Server)
❌ 文件系统
❌ 设备驱动
❌ 内存分配策略 (只做映射，策略交给 VMM 服务)
❌ 信号投递 (交给 Personality)
❌ ELF/PE 加载 (交给 Personality)
❌ 网络/协议栈
```

### 3.2 内核模块划分

```
kernel/
├── main.zig              # 内核入口，初始化各子系统
├── sched.zig             # 调度器 (多级反馈队列 + 实时队列)
├── ipc.zig               # IPC 引擎 (同步消息传递)
├── irq.zig               # 中断控制器管理 (x86: APIC, ARM: GIC)
├── addr_space.zig        # 地址空间管理 (页表操作)
├── timer.zig             # 定时器子系统
├── capability.zig        # 能力令牌管理
├── smp.zig               # SMP 多核同步
├── syscall_entry.zig     # 系统调用入口 (路由到 Personality)
├── thread.zig            # 内核线程 (轻量级，用于内核内部任务)
├── panic.zig             # 内核 panic 处理
├── arch/
│   ├── x86_64/
│   │   ├── entry.s       # syscall/interrupt 汇编入口
│   │   ├── context.zig   # 上下文切换
│   │   ├── idt.zig       # 中断描述符表
│   │   ├── gdt.zig       # 全局描述符表
│   │   ├── apic.zig      # 本地/IO APIC
│   │   ├── paging.zig    # 4级页表操作
│   │   └── smp.zig       # IPI 处理
│   └── aarch64/
│       ├── entry.s       # exception vector 汇编入口
│       ├── context.zig   # 上下文切换
│       ├── mmu.zig       # 页表操作
│       ├── gic.zig       # 中断控制器
│       └── smp.zig       # 核间中断
└── hal/
    └── hal.zig           # 硬件抽象层接口 (架构无关)
```

**目标代码量**: ~12,000-15,000 行 Zig + ~2,000 行汇编

### 3.3 IPC 设计

#### 3.3.1 IPC 原语

```zig
/// IPC 操作类型
pub const IpcOp = enum {
    send,         // 发送消息，阻塞直到对方接收
    receive,      // 接收消息，阻塞直到有消息到达
    call,         // 发送 + 等待回复 (事务型)
    reply,        // 回复 call 者
    notify,       // 异步通知 (不阻塞，无数据，仅位图)
};
```

#### 3.3.2 消息结构

借鉴 MINIX 3 的 message 联合体设计，但使用 Zig 的 `extern union` 以确保 C ABI 兼容：

```zig
/// IPC 消息 — 固定 256 字节，适合 cache line
pub const Message = extern struct {
    sender: EndpointId,     // 发送者端点 (8 bytes)
    reply_to: EndpointId,   // call 场景下的回复地址 (8 bytes)
    msg_type: u32,          // 消息类型 (4 bytes)
    flags: u32,             // 消息标志 (4 bytes)
    payload: Payload,       // 联合体负载 (232 bytes)
};

pub const Payload = extern union {
    raw: [232]u8,
    small: SmallPayload,    // 通用小型消息 (int + pointer)
    syscall: SyscallPayload, // 系统调用参数
    fault: FaultPayload,    // 缺页异常信息
    irq: IrqPayload,        // 中断通知
};
```

#### 3.3.3 IPC 性能优化：共享内存通道

**关键设计决策**: IPC 消息本身**只传递控制信息和少量数据** (≤ 232 字节)。大数据传输通过**共享内存通道 (Shared Memory Channel)**:

```
大数据 read(fd, buf, 1MB):

传统方式 (慢):
  用户 → [IPC 1MB 数据] → FS 服务 → [IPC 1MB] → 磁盘驱动 → 回复
  开销: 2 次完整数据拷贝

优化方式 (快):
  1. 用户 mmap 一块共享内存区域
  2. 用户 → [IPC: "read fd=3, len=1MB, shm_key=0x1234"] → FS 服务
  3. FS 服务通过 shm_key 直接写入用户共享内存 (零拷贝)
  4. FS → [IPC: "read done, actual=1MB"] → 用户
  开销: 2 次小消息 IPC + 0 次大数据拷贝
   ```

#### 3.3.4 共享内存 API

**设计**: 内核管理共享内存区域，通过 capability 授权访问。

```zig
/// 共享内存区域 — 内核管理
pub const ShmRegion = struct {
    shm_id: u32,             // 全局唯一 ID
    phys_pages: []PhysAddr,  // 物理页面列表
    size: u64,               // 区域大小 (页对齐)
    owner_pid: u32,          // 创建者 PID
    ref_count: u32,          // 映射计数
    caps: CapTable,          // 访问 capability
};

/// 系统调用接口:
/// shm_create(size, flags) → shm_id        // 创建共享区域
/// shm_map(shm_id, addr_hint, flags) → addr // 映射到调用者地址空间
/// shm_unmap(addr)                           // 解除映射
/// shm_transfer(shm_id, target_pid, rights) // 授权其他进程访问
/// shm_destroy(shm_id)                       // 销毁 (所有映射自动解除)
```

**Linux 映射**: `shm_open()` + `mmap(MAP_SHARED)` → LinuxPers 转发到内核 shm API
**Windows 映射**: `NtCreateSection()` + `NtMapViewOfSection()` → WinPers 转发到同一 API
**MoQiOS 原生**: 直接调用内核 shm 系统调用

### 3.4 调度器设计

```
┌─────────────────────────────────────┐
│         调度优先级层次                │
│                                     │
│  ┌───────────────────────────────┐  │
│  │ 实时队列 (SCHED_FIFO/RR)      │  │ ← 最高优先级
│  │ 优先级 0-99                   │  │
│  └───────────────────────────────┘  │
│  ┌───────────────────────────────┐  │
│  │ 内核服务队列                   │  │
│  │ (PM, VFS, Personality 等)     │  │
│  └───────────────────────────────┘  │
│  ┌───────────────────────────────┐  │
│  │ 普通队列 (CFS 风格)            │  │
│  │ 优先级 100-139                │  │
│  └───────────────────────────────┘  │
│  ┌───────────────────────────────┐  │
│  │ 后台队列 (nice > 0)           │  │ ← 最低优先级
│  └───────────────────────────────┘  │
└─────────────────────────────────────┘
```

### 3.5 系统调用入口 — ABI 路由

这是双兼容的关键枢纽。内核根据系统调用入口点判断 ABI 类型：

```zig
/// x86_64 系统调用入口 (汇编)
/// Linux: syscall 指令 → MSR_LSTAR → 此处
/// Windows: ntdll!Nt* → syscall 指令 → MSR_CSTAR → 此处
///
/// 策略: 使用两个不同的 MSR 入口点区分 ABI
///   MSR_LSTAR = linux_syscall_entry  (Linux 应用走这里)
///   MSR_CSTAR = nt_syscall_entry     (Windows 应用走这里)
```

**ABI 识别策略**：每个进程在创建时绑定一个 `Personality` 标签：

```zig
pub const Personality = enum {
    linux,
    windows,
    native,   // MoQiOS 原生应用 (直接 IPC)
};

pub const Process = struct {
    personality: Personality,
    // ...
};
```

系统调用路由：

```
Linux 应用执行 syscall #1 (sys_write):
  MSR_LSTAR → linux_syscall_entry (汇编保存寄存器) → kernel syscall_entry.zig
  → 检查 current_process.personality == .linux
  → IPC 转发到 Linux Personality Server
  → Linux Personality 解析 syscall #1 → 翻译为内部操作 → 发送到 VFS 服务

Windows 应用执行 NtWriteFile:
  MSR_CSTAR → nt_syscall_entry (汇编保存寄存器) → kernel syscall_entry.zig
  → 检查 current_process.personality == .windows
  → IPC 转发到 Windows Personality Server
  → Windows Personality 解析 NT syscall → 翻译为内部操作 → 发送到 VFS 服务
```

---

## 4. 双 ABI 兼容 — 核心挑战与解决方案

### 4.1 二进制加载器

#### 4.1.1 双格式加载器架构

```
                    execve("program")
                          │
                    ┌─────▼─────┐
                    │  内核入口   │
                    │ 检测文件头  │
                    └─────┬─────┘
                          │
              ┌───────────┼───────────┐
              │                       │
      0x7F 'E' 'L' 'F'           'M' 'Z' (PE)
              │                       │
      ┌───────▼───────┐       ┌──────▼──────┐
      │ Linux ELF     │       │ Windows PE  │
      │ Personality   │       │ Personality │
      │ ELF Loader    │       │ PE Loader   │
      └───────────────┘       └─────────────┘
```

**内核只做一件事**：读取文件前 4 字节判断格式，然后委托给对应的 Personality Server 完成加载。

#### 4.1.2 ELF 加载器 (Linux Personality 内部)

参考 Zigix 的 `elf.zig` (240行) + `execve.zig` (788行)：

```zig
/// ELF 加载流程 (Linux Personality 内部)
/// 1. 解析 ELF64 header → 验证 magic/class/endianness
/// 2. 遍历 PT_LOAD segments → 为每个段创建 VMA
/// 3. 设置用户栈 (argc/argv/envp/auxv)
/// 4. 设置入口点 (e_entry 或 interpreter)
/// 5. 通知内核 "设置新进程上下文"
pub const Elf64Header = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    // ... 与 Zigix elf.zig 一致
};
```

#### 4.1.3 PE 加载器 (Windows Personality 内部)

这是**全新模块**，参考 ReactOS 的 `dll/ntdll/ldr/`：

```zig
/// PE 加载流程 (Windows Personality 内部)
/// 1. 解析 IMAGE_DOS_HEADER → 找到 PE header 偏移
/// 2. 解析 IMAGE_NT_HEADERS64 → 验证 PE\0\0 magic
/// 3. 遍历 IMAGE_SECTION_HEADER → 映射各 section
/// 4. 处理 Import Directory → 解析 DLL 依赖链
/// 5. 修复 IAT (Import Address Table)
/// 6. 处理重定位 (如果 ASLR 导致基址不同)
/// 7. 映射 ntdll.dll 到进程空间 (硬编码依赖)
/// 8. 设置 TEB (Thread Environment Block)
/// 9. 设置入口点 (AddressOfEntryPoint)
pub const ImageDosHeader = extern struct {
    e_magic: u16,        // 0x5A4D ("MZ")
    e_lfanew: u32,       // 偏移到 PE header
    // ... 其他字段
};

pub const ImageNtHeaders64 = extern struct {
    signature: u32,      // 0x00004550 ("PE\0\0")
    file_header: ImageFileHeader,
    optional_header: ImageOptionalHeader64,
};
```

### 4.2 线程模型 — Linux clone() vs Windows CreateThread

#### 4.2.1 问题分析

| 维度 | Linux | Windows |
|---|---|---|
| 创建原语 | `clone(flags)` | `NtCreateThreadEx()` |
| TLS 访问 | `fs_base` (x86_64) via `arch_prctl` | `gs_base` → TEB |
| 线程身份 | TGID (thread group) + TID | Process ID + Thread ID |
| 共享粒度 | clone flags 细粒度控制 | 隐式共享地址空间 |
| 退出通知 | `clear_child_tid` (futex) | 线程句柄 signaled |

#### 4.2.2 统一方案

内核维护**统一的线程模型**，Personality 层做语义翻译：

```zig
/// 内核级统一线程/进程结构
pub const Task = struct {
    task_id: TaskId,
    process_group: ProcessGroupId,  // 地址空间共享组
    page_table: PhysAddr,           // PML4 物理地址
    kernel_stack: VirtAddr,
    context: Context,               // 保存的寄存器
    state: TaskState,
    priority: u8,

    // === ABI 特定字段 ===
    personality: Personality,

    // Linux TLS
    linux_fs_base: u64,             // arch_prctl(ARCH_SET_FS)
    linux_clear_tid: u64,           // clone(CLONE_CHILD_CLEARTID)

    // Windows TLS
    windows_gs_base: u64,           // TEB 指针
    windows_peb: u64,               // Process Environment Block
    windows_teb: u64,               // Thread Environment Block

    // 通用
    pending_signals: u64,           // 位图
    blocked_signals: u64,
};
```

**关键设计**：`fs_base` 和 `gs_base` **独立存储**，根据 `personality` 字段决定在上下文切换时恢复哪个 MSR：

```zig
pub fn contextSwitch(next: *Task) void {
    // 保存当前任务状态...

    // 恢复 TLS 基址 (根据 personality 选择)
    switch (next.personality) {
        .linux => {
            wrmsr(MSR_FS_BASE, next.linux_fs_base);
        },
        .windows => {
            wrmsr(MSR_GS_BASE, next.windows_gs_base); // TEB
            // KUSER_SHARED_DATA 映射见 4.5 节
        },
        .native => {
            wrmsr(MSR_FS_BASE, next.linux_fs_base);
        },
    }
}
```

### 4.3 异常处理 — 信号 vs SEH

#### 4.3.1 问题分析

| 维度 | Linux 信号 | Windows SEH |
|---|---|---|
| 注册方式 | `sigaction(signum, &act)` | `__try/__except` 编译器生成 |
| 分发链 | 内核直接跳到 handler | ntdll 的 `KiUserExceptionDispatcher` |
| 栈帧 | 内核在用户栈构建 sigreturn frame | 用户空间遍历 EXCEPTION_REGISTRATION 链 |
| 恢复 | `sigreturn` syscall | `RtlUnwind` + `NtContinue` |

#### 4.3.2 统一方案：内核异常 → Personality 分发

```
CPU 异常 (例如 #PF 缺页):
  │
  ├── 内核处理缺页 (CoW, demand paging, 真缺页)
  │     │
  │     ├── 成功修复 → 继续执行
  │     └── 无法修复 (非法访问) → 通知 Personality
  │
  └── 通知 Personality Server:
        │
        ├── Linux Personality:
        │     产生 SIGSEGV → 构造 siginfo → 投递到信号处理链
        │
        └── Windows Personality:
              产生 EXCEPTION_ACCESS_VIOLATION →
              通过 TEB → SEH 链 → KiUserExceptionDispatcher
```

```zig
/// 内核异常处理 — 委托给 Personality
pub fn handleFault(task: *Task, fault_info: FaultInfo) void {
    // 先尝试内核级修复 (CoW, demand paging 等)
    if (tryKernelFixup(task, &fault_info)) return;

    // 无法修复 → 构造异常消息发送给对应 Personality
    const msg = Message{
        .msg_type = MSG_EXCEPTION,
        .payload = .{ .fault = .{
            .fault_addr = fault_info.address,
            .fault_type = fault_info.type,  // READ/WRITE/EXEC
            .error_code = fault_info.error_code,
        }},
    };
    ipc.send(task.personality_endpoint, &msg);
}
```

#### 4.3.3 信号帧构建 (Linux 信号投递)

**设计**: LinuxPers 在投递信号时需要在用户栈上构造 `sigreturn frame`，使得信号处理函数返回后执行 `rt_sigreturn` 系统调用恢复上下文。

```
信号投递流程:
  1. LinuxPers 决定投递信号 signum 给进程
  2. LinuxPers → IPC 请求内核: "写入用户栈信号帧, 跳转到 handler"
  3. 内核执行:
     a. 在用户栈顶分配空间 (向下增长):
        ┌───────────────────────┐ ← 新 RSP
        │ ucontext_t            │ ← 完整寄存器快照 (所有通用寄存器 + 浮点)
        │ siginfo_t             │ ← 信号详情 (si_signo, si_code, si_addr)
        │ __restore_rt 桩地址   │ ← 返回地址指向 sigreturn 桩
        └───────────────────────┘ ← 原 RSP
     b. 将返回地址设为 __restore_rt 桩 (在 vdso 或 libc 中)
     c. 修改 RIP 为信号处理函数地址
     d. 修改 RSP 为新栈顶
     e. 设置 RDI = signum, RSI = &siginfo, RDX = &ucontext
  4. 进程从信号处理函数返回时:
     → 执行 __restore_rt 桩
     → 桩执行 rt_sigreturn 系统调用
     → 内核从 ucontext 恢复原始上下文
     → 进程从被中断处继续执行

实时信号:
  SIGRTMIN-SIGRTMAX (34-64): 排队语义 (不丢失, FIFO 顺序)
  普通信号 (1-31): 位图语义 (同信号只投递一次)

线程信号路由:
  kill(pid, sig) → 任意线程接收 (进程级)
  tgkill(tgid, tid, sig) → 指定线程接收
  → 内核检查 current_task.pending_signals 位图
```

#### 4.3.4 SEH 异常分发 (Windows 异常处理)

```
异常分发流程:
  1. 内核检测到异常 (page fault / GP fault / illegal instruction)
  2. 内核通知 WinPers
  3. WinPers 构造 EXCEPTION_RECORD:
     → ExceptionCode (STATUS_ACCESS_VIOLATION, etc.)
     → ExceptionAddress
     → NumberParameters + ExceptionInformation
  4. WinPers 通过内核写入用户栈:
     → CONTEXT 结构 (所有寄存器)
     → EXCEPTION_POINTERS { ExceptionRecord, ContextRecord }
  5. 跳转到 ntdll!KiUserExceptionDispatcher:
     → 遍历 SEH chain (EXCEPTION_REGISTRATION_RECORD 链表, FS:0 指向)
     → 每个 __except filter 执行:
        → EXCEPTION_EXECUTE_HANDLER: 执行 __except 块
        → EXCEPTION_CONTINUE_SEARCH: 继续链
        → EXCEPTION_CONTINUE_EXECUTION: 恢复执行
  6. 如果 SEH chain 不处理 → WinPers 再次通知调试器 (second chance)
  7. 如果调试器不处理 → 终止进程

异常返回:
  → RtlRestoreContext() 恢复 CONTEXT 结构中的寄存器
  → 或 NtContinue(CONTEXT, TestAlert) 系统调用
```

### 4.4 ntdll.dll 兼容层

#### 4.4.1 为什么需要自研 ntdll.dll？

Windows 应用**不直接发 syscall** — 它们调用 ntdll.dll 的 `Nt*` 函数。这些函数内部是：

```asm
; ntdll!NtCreateFile 的典型实现
mov r10, rcx
mov eax, 0x55           ; syscall number (Windows 10)
syscall
ret
```

**关键问题**：Windows syscall number 在不同版本之间**会变化** (Win10 0x55 vs Win11 不同)。所以：

**策略**: 提供 MoQiOS 自研的 ntdll.dll，实现所有 Nt* 函数，内部使用 MoQiOS 的 IPC 机制而非 syscall 指令。

```zig
/// MoQiOS 的 ntdll.dll (Zig 编译为 DLL)
/// 每个函数内部不使用 syscall，而是通过共享内存 + IPC 调用 Windows Personality

pub export fn NtCreateFile(
    FileHandle: *HANDLE,
    DesiredAccess: ACCESS_MASK,
    ObjectAttributes: *OBJECT_ATTRIBUTES,
    IoStatusBlock: *IO_STATUS_BLOCK,
    AllocationSize: ?*LARGE_INTEGER,
    FileAttributes: ULONG,
    ShareAccess: ULONG,
    CreateDisposition: ULONG,
    CreateOptions: ULONG,
    EaBuffer: ?*void,
    EaLength: ULONG,
) callconv(.win64) NTSTATUS {
    // 不走 syscall，走 MoQiOS IPC → Windows Personality → VFS 服务
    return moqi_os_call(.NtCreateFile, ...);
}
```

#### 4.4.2 必须实现的 NT API 子集

| 模块 | 关键函数 | 用途 |
|---|---|---|
| **进程/线程** | NtCreateProcess, NtCreateThread, NtTerminateProcess | 进程管理 |
| **内存** | NtAllocateVirtualMemory, NtFreeVirtualMemory, NtProtectVirtualMemory | 内存操作 |
| **文件 I/O** | NtCreateFile, NtReadFile, NtWriteFile, NtClose | 文件操作 |
| **同步** | NtCreateEvent, NtWaitForSingleObject, NtReleaseMutant | 同步原语 |
| **section** | NtCreateSection, NtMapViewOfSection | 内存映射 |
| **信息查询** | NtQuerySystemInformation, NtQueryInformationProcess | 系统信息 |
| **PEB/TEB** | NtCurrentTeb, 进程初始化时自动设置 | 进程环境 |

#### 4.4.3 Windows DLL 加载链

**问题**: Windows 应用不只依赖 ntdll.dll，通常还依赖 kernel32.dll、msvcrt.dll 等。需要一个完整的 DLL 加载器。

```
DLL 加载链:
  PE 加载器 (WinPers) 加载 hello.exe:
    1. 解析 hello.exe 的导入表:
       → "kernel32.dll" → 需要加载
       → "ntdll.dll" → 已硬映射 (跳过)
       → "msvcrt.dll" → 需要加载
    2. DLL 搜索顺序:
       a. 应用所在目录
       b. /Windows/System32/ (MoQiOS 映射为 /system/dll/)
       c. /Windows/ → /system/dll/
       d. PATH 环境变量
    3. 每个需要加载的 DLL:
       a. VFS 读取 DLL 文件
       b. PE 加载器映射 DLL 到进程地址空间 (高位地址区)
       c. 递归解析 DLL 的导入表 (DLL 可能依赖其他 DLL)
       d. 处理重定位 (如果加载地址与 ImageBase 不同)
       e. 绑定 IAT: 将导入函数名匹配到导出 DLL 的 .edata 表
       f. 执行 TLS callbacks (如有)
       g. 调用 DllMain(DLL_PROCESS_ATTACH)
    4. 防止循环依赖: 维护加载中 DLL 列表, 检测循环 → 报错

MoQiOS 提供的 DLL:
  ntdll.dll  → MoQiOS 自研 (C/ASM), 硬映射到每个 Windows 进程
  kernel32.dll → MoQiOS 自研, 封装 ntdll.dll 的上层 API
  msvcrt.dll  → 使用 musl 或 mingw 的运行时 (可从 MinGW 获取)

第三方 DLL:
  → 放入 /system/dll/ 目录
  → PE 加载器按需加载

延迟加载 (Delay-load):
  → PE 的 DELAY_IMPORT_DIRECTORY 处理
  → 首次调用时触发加载 → 需要 page fault handler 配合
```

### 4.5 进程地址空间布局

#### 4.5.1 x86_64 地址空间规划

```
0xFFFF_8000_0000_0000 ─── 内核空间 (高半部分, HHDM)
                       │
                       │  内核代码 + 数据
                       │  内核堆
                       │  设备 MMIO 映射
                       │
0x0000_8000_0000_0000 ─── ─ ─ ─ 不可访问区域 ─ ─ ─
                       │
                       │  ┌─── Linux 应用布局 ───┐  ┌─── Windows 应用布局 ───┐
0x7FFF_FFFF_F000       │  │ 用户栈 (向下增长)    │  │ 用户栈 (向下增长)      │
                       │  │                     │  │                        │
0x7FFE_1000            │  │ —                   │  │ TEB                    │
0x7FFE_0000            │  │ —                   │  │ KUSER_SHARED_DATA ★    │
                       │  │                     │  │                        │
0x7000_0000_0000       │  │ mmap 区域 (↓)       │  │ DLL 映射区域           │
                       │  │                     │  │ ntdll.dll, kernel32.dll│
                       │  │                     │  │                        │
0x4000_0000            │  │ 程序代码段 (ET_EXEC) │  │ 程序代码段 (PE)        │
                       │  │ 堆 (brk/mmap ↑)     │  │ 堆 (VirtualAlloc ↑)    │
0x0001_0000            │  │ —                   │  │ PEB                    │
0x0000_0000            │  └─────────────────────┘  └────────────────────────┘
```

#### 4.5.2 KUSER_SHARED_DATA 处理

**问题**: Windows 应用从 `0x7FFE0000` 读取 `KUSER_SHARED_DATA` 获取系统时间、CPU 数量等。这是**硬编码地址，不可协商**。

**解决方案**: 在 Windows Personality 进程的页表中，将 `0x7FFE0000` 映射到一个特殊的只读页面，由 Windows Personality Server 定期更新：

```zig
/// 在创建 Windows 进程时:
/// 1. 分配一页物理内存
/// 2. 在进程页表中映射到 0x7FFE0000 (用户只读)
/// 3. 填入 KUSER_SHARED_DATA 结构
/// 4. 注册定时器定期更新 NtTickCount, TimeZoneBias 等
pub fn setupKUserSharedData(task: *Task) void {
    const page = pmm.alloc(1);
    const kusd: *KUSER_SHARED_DATA = @ptrFromInt(hhdm.translate(page));
    kusd.* = .{
        .NtMajorVersion = 10,
        .NtMinorVersion = 0,
        .NumberOfPhysicalPages = 1024 * 1024, // 4GB 假设
        .ActiveProcessorCount = smp.cpu_count,
        // ...
    };
    vmm.mapPage(task.page_table, 0x7FFE_0000, page, .{ .user = true, .readonly = true });
}
```

### 4.6 文件系统语义统一

#### 4.6.1 VFS 统一层设计

```
┌─────────────────────────────────────────────────┐
│                 VFS 统一层                       │
│                                                 │
│  ┌──────────────┐  ┌──────────────────────────┐ │
│  │ Linux VFS    │  │ Windows NT 文件系统       │ │
│  │ 语义适配器   │  │ 语义适配器                │ │
│  │              │  │                          │ │
│  │ • / 分隔符   │  │ • \ 分隔符              │ │
│  │ • 大小写敏感 │  │ • 大小写不敏感(保留大小写)│ │
│  │ • symlink    │  │ • 无 symlink → 模拟     │ │
│  │ • /proc /sys │  │ • NT 路径前缀 \??\      │ │
│  │ • rwxrwxrwx  │  │ • ACL → 简化为 rwx     │ │
│  └──────┬───────┘  └────────────┬─────────────┘ │
│         │                       │                │
│         └───────────┬───────────┘                │
│                     ▼                            │
│           ┌──────────────────┐                   │
│           │   VFS 核心       │                   │
│           │  inode + dentry  │                   │
│           │  挂载点管理      │                   │
│           │  页缓存          │                   │
│           └────────┬─────────┘                   │
│                    │                              │
│         ┌──────────┼──────────┐                  │
│         ▼          ▼          ▼                  │
│     ┌───────┐ ┌───────┐ ┌───────┐               │
│     │ ext4  │ │ FAT32 │ │ tmpfs │               │
│     └───────┘ └───────┘ └───────┘               │
└─────────────────────────────────────────────────┘
```

#### 4.6.2 路径解析统一

```zig
/// 统一路径解析器 — 根据进程 personality 自动处理差异
pub fn resolvePath(task: *Task, path: []const u8) !InodeRef {
    switch (task.personality) {
        .linux => return resolveLinuxPath(path),    // / 分隔, 大小写敏感
        .windows => return resolveNtPath(path),     // \??\C:\ 格式, 大小写不敏感
        .native => return resolveLinuxPath(path),   // 原生应用使用 Linux 风格
    }
}

fn resolveNtPath(path: []const u8) !InodeRef {
    // \??\C:\Windows\System32\ntdll.dll
    // → 去掉 \??\ 前缀
    // → 将 C: 映射到挂载点 /mnt/c/
    // → 将 \ 替换为 /
    // → 大小写不敏感查找
    const stripped = stripNtPrefix(path);  // C:\Windows\System32\ntdll.dll
    const unix_path = toUnixPath(stripped); // /mnt/c/Windows/System32/ntdll.dll
    return vfs.lookupCaseInsensitive(unix_path);
}
```

### 4.7 安全模型统一

#### 4.7.1 双模型共存策略

```
┌─────────────────────────────────────────┐
│         MoQiOS 统一安全模型              │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │   能力系统 (Capability)          │   │
│  │   所有 IPC 和资源访问的授权基础   │   │
│  └──────────────┬──────────────────┘   │
│                 │                       │
│  ┌──────────────┼──────────────────┐   │
│  │              │                  │   │
│  ▼              ▼                  ▼   │
│ Linux 权限     Windows Token      原生 │
│ UID/GID/Mode   SID/ACL/Integrity  Caps │
│ 模拟            Level 模拟         实际 │
└─────────────────────────────────────────┘
```

**初期简化策略**: 使用 Linux 风格的 UID/GID/rwx 作为基础，Windows ACL 通过 Windows Personality 翻译为简单的 rwx 权限。

---

## 5. 系统服务设计 (用户空间)

### 5.1 服务列表

| 服务 | 职责 | 对标 |
|---|---|---|
| **PM (Process Manager)** | 进程创建/销毁、PID 分配、信号转发 | MINIX PM + Linux kernel/fork.c |
| **VFS (Virtual Filesystem)** | 文件系统统一层、挂载管理、页缓存 | Linux VFS + Windows I/O Manager |
| **VMM (Virtual Memory Manager)** | 虚拟内存分配策略、CoW、demand paging、交换 | Linux mm/ + Windows Mm |
| **DevMgr (Device Manager)** | 设备发现、驱动加载、中断路由 | MINIX RS + Linux driver core |
| **LinuxPers (Linux Personality)** | Linux syscall 翻译、ELF 加载、信号投递 | — |
| **WinPers (Windows Personality)** | NT API 翻译、PE 加载、SEH 分发、ntdll 模拟 | Windows NT 环境子系统 |
| **NetStack (Network Stack)** | TCP/IP 协议栈、socket 接口 | Linux net/ + Winsock |
| **Init** | 系统启动、服务启动顺序、故障重启 | MINIX init + systemd |

### 5.2 服务间通信拓扑

```
Init
 ├── 启动 → PM
 ├── 启动 → VFS
 ├── 启动 → VMM
 ├── 启动 → DevMgr
 ├── 启动 → LinuxPers
 ├── 启动 → WinPers
 └── 启动 → NetStack

Linux 应用
  → LinuxPers → PM, VFS, VMM, DevMgr, NetStack

Windows 应用
  → WinPers → PM, VFS, VMM, DevMgr, NetStack
```

### 5.3 故障恢复

参考 MINIX 3 的 RS (Reincarnation Server)：

```
服务崩溃检测:
  内核监测服务心跳 (定时 notify)
  → 超时未心跳 → 通知 Init
  → Init 重启服务
  → 服务恢复状态 (从持久化存储或重新初始化)

驱动崩溃恢复:
  磁盘驱动崩溃 → DevMgr 检测到
  → 重启磁盘驱动
  → 重新注册中断处理
  → 恢复待处理的 I/O 请求
```

---

## 6. 设备驱动模型

### 6.1 统一驱动框架

```
┌──────────────────────────────────────────────────┐
│              MoQiOS 驱动框架                       │
│                                                  │
│  ┌────────────────────────────────────────────┐  │
│  │          驱动接口 (driver_api.zig)          │  │
│  │  • init() → 初始化                         │  │
│  │  • open/close/read/write/ioctl             │  │
│  │  • irq_handler() → 中断回调                │  │
│  │  • mmap() → 设备内存映射                   │  │
│  └───────────────────┬────────────────────────┘  │
│                      │                            │
│  ┌───────────────────┼────────────────────────┐  │
│  │                   │                         │  │
│  ▼                   ▼                         ▼  │
│ ┌──────────┐  ┌──────────┐  ┌──────────────┐  │
│ │ 块设备   │  │ 字符设备 │  │ 网络设备     │  │
│ │ blk.zig  │  │ chr.zig  │  │ net_driver   │  │
│ └──────────┘  └──────────┘  └──────────────┘  │
│                      │                            │
│                      ▼                            │
│          ┌───────────────────────┐                │
│          │ DevMgr (设备管理器)   │                │
│          │ 设备注册 / 中继 IPC   │                │
│          └───────────────────────┘                │
└──────────────────────────────────────────────────┘
```

### 6.2 驱动通信模型

```
用户空间 read("/dev/sda", buf, 4096):
  用户 → VFS (IPC) → DevMgr (IPC) → 磁盘驱动 (IPC)
  ← 磁盘驱动完成 DMA → 回复 DevMgr → 回复 VFS → 回复用户

中断处理:
  硬件 IRQ → 内核中断入口
  → 内核通知 DevMgr (async notify)
  → DevMgr 转发给对应驱动 (IPC)
  → 驱动处理中断，重新注册等待
```

---

## 7. Zig + 汇编技术栈实践

### 7.1 Zig 在 OS 开发中的优势

| 特性 | 用途 | 代码示例场景 |
|---|---|---|
| `comptime` | 编译时生成 syscall 表、位运算 | `comptime` 生成 512 项 syscall 分发表 |
| `extern struct` | 精确匹配 C/硬件结构布局 | ELF header, PE header, IDT entries |
| `@ptrCast` | 安全的类型转换 | 物理地址 → 结构体指针 (通过 HHDM) |
| `asm volatile` | 内联汇编 | `cli/sti`, `rdtsc`, `invlpg`, `wrmsr` |
| `build.zig` | 声明式构建，交叉编译 | 同时构建内核 + 多个用户空间服务 |
| `@embedFile` | 编译时嵌入文件 | 嵌入初始 ramdisk, 键盘映射表 |
| 无隐式分配 | 内核无隐藏堆分配 | 所有分配显式，适合内核环境 |
| `error` 联合体 | 清晰的错误处理 | syscall 返回 `!usize`，包含 errno 语义 |

### 7.2 汇编使用策略

| 场景 | 方式 | 原因 |
|---|---|---|
| 系统调用入口 | 独立 `.s` 文件 | 需要精确控制栈布局和寄存器保存 |
| 中断/异常入口 | 独立 `.s` 文件 | 需要交换栈 (内核栈 ↔ 用户栈) |
| 上下文切换 | 独立 `.s` 文件 | 需要保存/恢复所有寄存器 |
| 单条指令 (cli/sti/invlpg) | 内联 `asm volatile` | 简单，无需独立文件 |
| 端口 I/O (in/out) | 内联 `asm volatile` | 单条指令 |
| MMU 操作 (tlb flush) | 内联 `asm volatile` | 1-2 条指令 |
| 页表操作 | Zig 代码 | 逻辑复杂，Zig 更安全 |

### 7.3 构建系统

```zig
// build.zig — 统一构建
const std = @import("std");

pub fn build(b: *std.Build) void {
    const arch = b.option(std.Target.Cpu.Arch, "arch", "Target arch") orelse .x86_64;
    const target = .{ .cpu_arch = arch, .os_tag = .freestanding, .abi = .none };

    // 内核
    const kernel = b.addExecutable(.{
        .name = "moqi-kernel",
        .root_source_file = .{ .path = "kernel/main.zig" },
        .target = target,
        .optimize = .ReleaseSafe,
    });
    kernel.setLinkerScriptPath(.{ .path = "kernel/linker.ld" });

    // 用户空间服务
    const services = .{
        "pm", "vfs", "vmm", "devmgr",
        "linux_pers", "win_pers", "netstack", "init",
    };
    inline for (services) |name| {
        const srv = b.addExecutable(.{
            .name = name,
            .root_source_file = .{ .path = "servers/" ++ name ++ "/main.zig" },
            .target = target,
            .optimize = .ReleaseSafe,
        });
        // ... 每个服务独立构建
    }
}
```

---

## 8. 启动流程

### 8.1 x86_64 启动序列

```
UEFI 固件
  │
  ├── 加载 BOOTX64.EFI (MoQiOS bootloader)
  │     读取 EFI 系统分区上的内核映像 + ramdisk
  │     设置 UEFI 内存映射
  │     ExitBootServices()
  │     跳转到内核入口
  │
  ▼
内核入口 (kernel/arch/x86_64/entry.s)
  │  设置临时页表 (HHDM 映射)
  │  启用长模式 + 分页
  │  设置 GDT, IDT
  │  初始化 APIC
  │  跳转到 kernel/main.zig → kernelMain()
  │
  ▼
内核初始化 (kernel/main.zig)
  │  初始化物理内存管理器
  │  初始化内核堆 (slab 分配器)
  │  初始化调度器
  │  初始化 IPC 引擎
  │  初始化中断控制器
  │  启动 AP (应用处理器) — SMP
  │  创建 Init 服务进程 (PID 1)
  │  开始调度
  │
  ▼
Init 服务 (servers/init/main.zig)
  │  解析 /etc/moqios.conf
  │  启动核心服务: PM, VFS, VMM, DevMgr
  │  启动 Personality: LinuxPers, WinPers
  │  启动网络: NetStack
  │  挂载根文件系统
  │  启动登录 shell / 默认应用
```

---

## 9. 目录结构规划

```
moqios/
├── build.zig                    # 统一构建文件
├── kernel/                      # 微内核 (< 15,000 行)
│   ├── main.zig
│   ├── sched.zig
│   ├── ipc.zig
│   ├── irq.zig
│   ├── addr_space.zig
│   ├── timer.zig
│   ├── capability.zig
│   ├── smp.zig
│   ├── syscall_entry.zig
│   ├── thread.zig
│   ├── panic.zig
│   ├── klog.zig
│   ├── entropy.zig              # [新增] 熵收集和随机数
│   ├── acpi/                    # [新增] ACPI 解析
│   │   ├── acpi_parser.zig
│   │   ├── acpi_tables.zig
│   │   └── acpi_io.zig
│   ├── sync/                    # [新增] 同步原语
│   │   ├── irq_spinlock.zig
│   │   ├── ticket_spinlock.zig
│   │   ├── seqlock.zig
│   │   └── rwlock.zig
│   ├── arch/
│   │   ├── x86_64/
│   │   │   ├── entry.s
│   │   │   ├── context_switch.s
│   │   │   ├── idt.zig
│   │   │   ├── gdt.zig
│   │   │   ├── apic.zig
│   │   │   ├── paging.zig
│   │   │   ├── tss.zig
│   │   │   └── smp.zig
│   │   └── aarch64/
│   │       ├── entry.s
│   │       ├── context_switch.s
│   │       ├── mmu.zig
│   │       ├── gic.zig
│   │       └── smp.zig
│   ├── drivers/                 # 内核驻留驱动 (仅 PCI 枚举)
│   │   └── pci.zig              # [新增] PCI 总线扫描
│   ├── mm/                      # [新增] 内存管理
│   │   ├── pmm.zig              # 伙伴系统物理页分配 (~400 行)
│   │   ├── slab.zig             # Slab 小对象分配器 (~300 行)
│   │   ├── page_frame.zig       # PageFrame 描述符 (~80 行)
│   │   ├── dma.zig              # DMA 缓冲区管理 (~300 行)
│   │   └── iommu.zig            # IOMMU 管理 (Phase 5+, ~200 行)
│   ├── pm/                      # [新增] 电源管理
│   │   ├── suspend.zig          # 挂起/恢复核心
│   │   ├── acpi_sleep.zig       # ACPI S1/S3/S4/S5 寄存器操作
│   │   ├── cpu_state.zig        # CPU 状态保存/恢复
│   │   ├── hibernate.zig        # STD 快照写入/读取
│   │   └── wake_source.zig      # 唤醒源管理
│   ├── smp/                      # [新增] SMP 多核支持
│   │   ├── ap_boot.zig           # AP 启动 + trampoline 设置
│   │   └── per_cpu.zig           # per-CPU 数据区域管理
│   ├── pipe.zig                  # [新增] 管道 (环形缓冲区 + 阻塞唤醒)
│   └── hal/
│       └── hal.zig
│
├── servers/                     # 用户空间系统服务
│   ├── init/                    # 初始化进程
│   ├── pm/                      # 进程管理器
│   ├── vfs/                     # 虚拟文件系统
│   │   ├── main.zig
│   │   ├── inode.zig
│   │   ├── ext4/                # ext4 文件系统
│   │   ├── devfs.zig            # [新增] /dev 伪文件系统
│   │   ├── tmpfs.zig            # [新增] /tmp 内存文件系统
│   │   ├── procfs.zig           # [新增] /proc 伪文件系统
│   │   ├── devpts.zig           # [新增] /dev/pts 伪终端
│   │   ├── bio.zig              # [新增] 块设备 I/O 层
│   │   ├── buffer_cache.zig     # [新增] 块级缓冲缓存
│   │   └── io_sched.zig         # [新增] I/O 调度器 (电梯合并)
│   ├── vmm/                     # 虚拟内存管理器
│   │   ├── main.zig
│   │   ├── lru.zig              # [新增] 双链表 LRU 页面置换
│   │   └── kswapd.zig           # [新增] 后台页面回收守护
│   ├── devmgr/                  # 设备管理器
│   │   ├── main.zig
│   │   ├── pci.zig              # [新增] PCI 设备分配
│   │   └── driver_loader.zig    # [新增] 驱动加载
│   ├── ttyd/                    # [新增] TTY 守护进程
│   │   ├── main.zig
│   │   ├── line_discipline.zig
│   │   └── pty.zig
│   ├── netstack/                # 网络协议栈
│   │   ├── main.zig
│   │   ├── netbuf.zig           # [新增] 网络包缓冲管理 (pbuf 风格)
│   │   ├── tcp.zig
│   │   ├── udp.zig
│   │   └── ip.zig
│   ├── powermgr/                # [新增] 电源管理服务
│   │   ├── main.zig             # 服务入口 + IPC 循环
│   │   ├── policy.zig           # 策略引擎 + 配置解析
│   │   ├── coordinator.zig      # 挂起/恢复协调器
│   │   └── idle_monitor.zig     # 空闲检测 + 电量监控
│   ├── syslogd/                  # [新增] 系统日志守护
│   │   └── main.zig             # klog → 文件持久化 + 日志轮转
│   ├── linux_pers/              # Linux 兼容 Personality
│   │   ├── main.zig
│   │   ├── syscall_dispatch.zig
│   │   ├── elf_loader.zig
│   │   ├── signal.zig
│   │   ├── epoll.zig            # [新增] epoll 实现
│   │   ├── dynlinker.zig       # [新增] ELF 动态链接器
│   │   ├── coredump.zig        # [新增] 进程崩溃转储
│   │   ├── procfs.zig
│   │   └── sysfs.zig
│   └── win_pers/                # Windows 兼容 Personality
│       ├── main.zig
│       ├── ntapi_dispatch.zig
│       ├── pe_loader.zig
│       ├── seh.zig
│       ├── ntdll_impl.zig
│       ├── registry.zig
│       └── winsock.zig
│
├── drivers/                     # 用户空间设备驱动
│   ├── libdriver/               # 驱动框架库 (统一 DriverInterface)
│   ├── block/                   # 块设备驱动
│   │   ├── nvme/
│   │   ├── ahci/
│   │   └── virtio_blk/
│   ├── net/                     # 网络驱动
│   │   ├── virtio_net/
│   │   └── e1000/
│   ├── input/                   # 输入设备驱动
│   │   ├── keyboard/            # PS/2 键盘 (初期)
│   │   └── mouse/
│   ├── gpu/                     # GPU 驱动
│   │   ├── virtio_gpu/          # virtio-gpu 2D (Phase 4)
│   │   └── fb_console/         # [新增] Framebuffer console
│   ├── usb/                     # [新增] USB 驱动栈
│   │   ├── xhci/                # xHCI 控制器驱动 (Phase 4)
│   │   ├── hid/                 # USB HID (键盘/鼠标)
│   │   └── mass_storage/        # USB Mass Storage (U盘)
│   └── serial/                  # 串口驱动
│
├── lib/                         # 共享库
│   ├── ipc_lib/                 # IPC 用户空间库
│   ├── driver_api/              # 驱动开发 API
│   ├── pe_types/                # PE/COFF 类型定义
│   ├── elf_types/               # ELF 类型定义
│   ├── nt_types/                # Windows NT 类型定义
│   ├── zig_crt/                 # MoQiOS 原生 C 运行时
│   └── moqi_libc/               # [新增] MoQiOS 精简 libc
│
├── tools/                       # 开发工具
│   ├── mkimage/                 # 制作启动映像
│   ├── qemu_run/                # QEMU 测试启动 (含 -s -S GDB)
│   └── test_runner/             # [新增] 自动化测试脚本
│
├── tests/                       # [新增] 测试程序
│   ├── hello_elf/               # 静态链接 ELF 测试
│   ├── hello_pe/                # PE 测试
│   └── stress/                  # 压力测试
│
├── docs/                        # 文档
│   ├── moqios-design.md         # 本文档
│   ├── moqios-implementation-plan.md # 实施计划
│   └── 3rd-party-overview.md    # 第三方依赖概览
│
├── 3rd/                         # 第三方参考代码 (不参与编译)
│   ├── zigix/
│   ├── linux-7.0.6/
│   ├── reactos/
│   ├── QNXNeutrino/
│   ├── MINUX3/
│   └── dim-sum/
│
└── boot/                        # 启动相关
    ├── limine/                  # Limine bootloader 配置
    └── uefi/                    # UEFI bootloader (自研)
```

---

## 10. 开发路线图

### Phase 1: 微内核 MVP (预计 3-4 月)

| 阶段 | 内容 | 交付物 |
|---|---|---|
| 1.1 | x86_64 启动 (UEFI → 长模式 → 内核) | QEMU 能启动内核，输出日志 |
| 1.2 | 物理内存管理 + 页表操作 | 能分配/映射物理页面 |
| 1.3 | 调度器 + 上下文切换 | 两个内核线程交替执行 |
| 1.4 | IPC (send/receive) | 两个用户任务能交换消息 |
| 1.5 | 用户空间进程创建 | 能从 ramdisk 加载并运行一个简单程序 |
| 1.6 | 中断路由到用户空间 | 驱动能接收硬件中断 |

### Phase 2: Linux 兼容 (预计 4-6 月)

| 阶段 | 内容 | 交付物 |
|---|---|---|
| 2.1 | Linux Personality 骨架 | 能接收 Linux syscall IPC |
| 2.2 | ELF 加载器 | 能加载静态链接 ELF |
| 2.3 | 核心 syscall (read/write/open/close/exit) | 能运行 Hello World |
| 2.4 | 进程管理 (fork/execve/wait) | 能运行多进程程序 |
| 2.5 | 文件系统 (ext4 只读) | 能挂载并读取 ext4 磁盘 |
| 2.6 | 网络 (TCP/IP 基础) | 能 curl 一个网页 |
| 2.7 | BusyBox 完整运行 | 10/10 测试通过 |

### Phase 3: Windows 兼容 (预计 6-8 月)

| 阶段 | 内容 | 交付物 |
|---|---|---|
| 3.1 | PE 加载器 | 能加载简单 PE 二进制 |
| 3.2 | ntdll 骨架 + 核心 Nt* API | 能运行 NtCreateFile 级别程序 |
| 3.3 | Windows Personality + SEH | 异常处理正常工作 |
| 3.4 | TEB/PEB/KUSER_SHARED_DATA | Windows 应用能获取进程信息 |
| 3.5 | DLL 解析 + 导入表处理 | 能运行依赖多个 DLL 的程序 |
| 3.6 | 注册表模拟 | 能读写注册表 |
| 3.7 | Winsock 兼容 | Windows 网络程序运行 |

### Phase 4: 生产化 (持续)

| 阶段 | 内容 |
|---|---|
| 4.1 | ext4 读写 + VFS 写路径 (dirty page + writeback) |
| 4.2 | swap 到磁盘 + zRAM 压缩 |
| 4.3 | AArch64 移植 |
| 4.4 | SMP 多核优化 |
| 4.5 | 实时调度 (SCHED_FIFO/RR) |
| 4.6 | 安全加固 (能力系统完善) |
| 4.7 | GPU 驱动 + 图形输出 |
| 4.8 | 安装程序 |

---

## 11. 已知风险与缓解措施

| # | 风险 | 严重度 | 缓解措施 |
|---|---|---|---|
| R1 | IPC 开销导致系统调用性能差 | 高 | 共享内存通道 + 小消息混合模型; 对热路径 (read/write) 优化为零拷贝 |
| R2 | Windows syscall number 版本差异 | 高 | 自研 ntdll.dll 屏蔽 syscall 层; WinPers 内部使用稳定的 API 语义 |
| R3 | SEH 实现复杂度极高 | 高 | 初期仅支持简单的 __try/__except; 编译器生成的 SEH chain 优先支持 |
| R4 | Linux clone() 细粒度 flags 难以完全模拟 | 中 | 优先支持 CLONE_VM\|CLONE_THREAD (线程) 和普通 fork; 其他 flags 按需实现 |
| R5 | 驱动生态为零 | 中 | 先支持 virtio 驱动 (QEMU 测试); 逐步添加 NVMe/AHCI/E1000 |
| R6 | 两种安全模型共存复杂 | 中 | 初期简化为 UID/GID + rwx; Windows ACL 翻译为简化权限 |
| R7 | Zig 工具链成熟度 | 低 | Zigix 已验证 Zig 适合 OS 开发; 保持 Zig 版本锁定 |
| R8 | 页表切换频繁 (微内核 IPC) | 中 | 使用 PCID (Process-Context Identifier) 减少TLB 刷新 |

---

## 12. 缺失子系统补充 (审计修正)

> 以下子系统在初始设计中遗漏，经审计后补充。

### 12.1 ACPI 解析子系统

**为什么需要**: x86_64 上所有硬件发现依赖 ACPI 表。没有 ACPI，APIC 地址只能硬编码，CPU 数量无法发现，真机不可用。

**架构**: AArch64 使用 FDT (Flat Device Tree) 而非 ACPI，HAL 层需要双路径支持。

```
ACPI 初始化流程:
  1. RSDP 定位 (EFI 系统表提供物理地址)
  2. RSDP 校验 → 找到 XSDT/RSDT
  3. 遍历 XSDT 条目 → 按签名分发表:
     "APIC" (MADT) → 提取 LAPIC 地址、CPU APIC ID 列表、IOAPIC 地址
     "MCFG"        → 提取 PCIe ECAM 基地址 (用于 PCI 配置空间访问)
     "HPET"        → 提取高精度定时器地址
     "FACP" (FADT) → 提取电源管理信息
     "BGRT"        → 启动画面 (可选)
```

**内核新增文件**:
```
kernel/
├── acpi/
│   ├── acpi.zig           # 模块入口
│   ├── acpi_parser.zig    # RSDP/XSDT/MADT/MCFG 解析 (~450 行)
│   ├── acpi_tables.zig    # ACPI 表结构定义
│   └── acpi_io.zig        # 物理地址 → HHDM 虚拟地址转换
```

**参考**: Zigix `kernel/acpi/` (443 行解析器)

### 12.2 PCI/PCIe 总线枚举

**为什么需要**: 驱动无法硬编码设备地址。QEMU 的 virtio 设备通过 PCI 发现，NVMe/网卡都在 PCI 总线上。

```
PCI 初始化流程:
  1. 配置空间访问方式选择:
     x86_64: 0xCF8/0xCFC I/O 端口 (传统) 或 ECAM (通过 MCFG)
     AArch64: 仅 ECAM
  2. 扫描 bus 0-255, device 0-31, function 0-7
  3. 读取 vendor/device ID → 构建 PciDevice 列表
  4. 解析 BAR (Base Address Register) → 映射 MMIO
  5. 解析 Capability 链 → MSI-X, Power Management 等
  6. 启用设备 (Memory Space + Bus Master)
```

**内核新增文件**:
```
kernel/
├── drivers/
│   └── pci.zig            # PCI 扫描、BAR 解析、设备表 (~280 行)
```

**服务层新增**:
```
servers/
├── devmgr/
│   ├── pci.zig            # PCI 设备管理 (分配设备给驱动)
│   └── driver_loader.zig  # 根据 PCI ID 加载对应驱动
```

**参考**: Zigix `kernel/drivers/pci.zig` (276 行)

### 12.3 内核同步原语

**为什么需要**: 内核从 M2 (PMM) 开始就需要锁。SMP 多核后更需要。

| 原语 | 实现 | 用途 | 参考来源 |
|---|---|---|---|
| **IrqSpinlock** | cli + xchg + sti, ~48 行 | PMM、进程表等中断敏感区域 | Zigix `spinlock.zig` |
| **TicketSpinlock** | 原子 fetch_add, ~60 行 | SMP 公平锁 | 标准 ticket lock |
| **SeqLock** | 版本号 + 写者互斥, ~80 行 | 统计信息读取 (无锁读) | Linux seqlock_t |
| **RwLock** | 读者计数 + 写者位, ~100 行 | VMA 缓存、挂载表 | 标准 pthread_rwlock |

**内核新增文件**:
```
kernel/
├── sync/
│   ├── irq_spinlock.zig   # 中断安全自旋锁 (架构相关)
│   ├── ticket_spinlock.zig # 公平自旋锁
│   ├── seqlock.zig        # 顺序锁
│   └── rwlock.zig         # 读写锁
```

**x86_64 汇编关键**: `cli` 禁用中断 + `xchg` 原子交换 + `pause` 减少总线争用 + `sti` 恢复中断。

### 12.4 伪文件系统 (devfs / tmpfs / procfs / devpts)

**为什么需要**: BusyBox 和几乎所有 Linux 程序依赖这些伪文件系统。没有 /dev/null 很多程序直接崩溃。

| 文件系统 | 挂载点 | 功能 | 参考来源 |
|---|---|---|---|
| **devfs** | /dev | /dev/null, /dev/zero, /dev/urandom, /dev/console, 动态设备节点 | Zigix `devfs.zig` (236 行) |
| **tmpfs** | /tmp, /run | 内存文件系统，支持文件创建/写入/目录 | Zigix `tmpfs.zig` (~500 行) |
| **procfs** | /proc | /proc/self, /proc/cpuinfo, /proc/meminfo, /proc/version | Zigix `procfs.zig` |
| **devpts** | /dev/pts | 伪终端设备节点 (shell job control 必需) | 需自研 |

**实现位置**: VFS 服务内部，作为 VFS 插件注册。

### 12.5 伪终端 (PTY) 和 TTY 层

**为什么需要**: shell 的 job control (Ctrl+C, Ctrl+Z, fg, bg) 完全依赖 PTY。管道 `|` 不够 — 需要真正的终端行编辑和信号生成。

```
微内核 PTY 架构:

用户按键 → 键盘驱动 (用户空间)
  → IPC → TTY 服务 (用户空间)
    → 行编辑 (退格、回车)
    → 信号生成 (Ctrl+C → SIGINT, Ctrl+Z → SIGTSTP)
    → 数据写入 PTY slave buffer
  → shell 从 PTY master 读取

TTY 服务职责:
  1. 行规范处理 (Line Discipline): 回显、退格、行缓冲
  2. 信号生成: INTR=Ctrl+C, QUIT=Ctrl+\, SUSP=Ctrl+Z
  3. 终端大小管理 (TIOCGWINSZ)
  4. 多路复用: 多个 shell session 各有独立 PTY
```

**新增服务**:
```
servers/
├── ttyd/                  # TTY 守护进程
│   ├── main.zig           # 主循环
│   ├── line_discipline.zig # 行规范处理
│   ├── pty.zig            # PTY master/slave 管理
│   └── signal_gen.zig     # 终端信号生成
```

**参考**: MINIX 3 `drivers/tty/tty.c` (1,200+ 行完整 TTY 实现)

### 12.6 内存耗尽处理 (OOM)

**为什么需要**: 物理内存是有限资源。微内核中每个服务独立地址空间，没有天然的全局内存压力感知。

```
内存水位管理 (VMM 服务负责):

  高水位 (85% 已用) → 警告:
    - 通知 VFS 释放页缓存
    - 通知各服务收缩内部缓存
    - 日志告警

  紧急水位 (95% 已用) → OOM:
    - 选择最占内存的用户进程
    - 发送 SIGKILL (Linux) 或终止进程
    - 释放被杀进程的全部内存
    - 记录 OOM 事件

水位检测:
  VMM 定期检查 pmm.free_pages / pmm.total_pages
  通过定时器回调 (每秒检查一次)
```

**Phase 2 扩展**: swap 到磁盘、zRAM 压缩。

### 12.7 epoll — I/O 多路复用

**为什么需要**: 网络服务器必须使用 epoll 才能高效处理大量连接。select/poll 是 O(n) 复杂度。

```zig
/// epoll 实现要点:
/// 1. epoll_create → 分配一个 epoll 实例 (红黑树 + 就绪链表)
/// 2. epoll_ctl(ADD/MOD/DEL) → 注册/修改/删除监控的 fd
/// 3. epoll_wait → 阻塞等待就绪事件 (通过 IPC 等待 NetStack/VFS 通知)
///
/// 在微内核中的实现:
/// - epoll 实例在 LinuxPers 中维护
/// - fd 对应的 VFS/NetStack 注册回调通知
/// - 数据就绪 → 服务通知 LinuxPers → 唤醒 epoll_wait
```

**参考**: Zigix `kernel/proc/epoll.zig`

### 12.8 随机数 / Entropy

**为什么需要**: ASLR、进程 PID 随机化、/dev/urandom、网络初始序列号都需要熵源。

| 来源 | 架构 | 说明 |
|---|---|---|
| RDRAND/RDSEED 指令 | x86_64 (Intel) | 硬件随机数，最高质量 |
| RNDR 寄存器 | AArch64 (ARMv8.5+) | 硬件随机数 |
| RDTSC | x86_64 | 时间戳，低质量但总可用 |
| 中断间隔定时 | 通用 | 鼠标/键盘/网络中断间隔作为熵 |
| virtio-rng | QEMU | 虚拟机熵源设备 |

**实现**:
```
内核:
  entropy.zig — 收集内核熵源 (RDRAND/RDTSC/中断间隔)
  → 混入 entropy pool (简化版 Fortuna)

VFS:
  devfs 中 /dev/random (阻塞) 和 /dev/urandom (非阻塞)
  → 从内核 entropy pool 通过 IPC 读取
```

### 12.9 调试设施 (概要)

> 调试子系统的完整设计见 **§13 调试架构**。本节仅列出最初审计时识别的基本设施。

| 设施 | 实现方式 | 用途 | 详见 |
|---|---|---|---|
| **QEMU GDB** | QEMU 启动参数 `-s -S` | 断点、单步、寄存器查看 | §13.1 |
| **串口日志** | klog → COM1 | 运行时日志输出 | §13.1 |
| **异常环形缓冲区** | 每 CPU 64 条记录 | 崩溃前回溯 | §13.1 |
| **Panic 回溯** | 解析内核符号表 (ELF .symtab) | 崩溃时显示调用栈函数名 | §13.1 |
| **内核符号表** | build.zig 生成 `kernel.sym` | panic 回溯需要符号地址→名称映射 | §13.1 |

### 12.10 时钟源和时间管理

| 架构 | 主时钟源 | 高精度源 | 说明 |
|---|---|---|---|
| x86_64 | LAPIC Timer (per-CPU) | TSC (时间戳计数器) 或 HPET | TSC 为主 (纳秒级), LAPIC Timer 驱动 tick |
| AArch64 | Generic Timer (CNTVCT_EL0) | 同左 | ARM Generic Timer 本身就是高精度的 |

**时间 API**:
```zig
pub fn getTimeNs() u64;           // 纳秒级单调时钟
pub fn getTimeUs() u64;           // 微秒级
pub fn getEpochTime() i64;        // Unix 时间戳 (秒)
pub fn setDeadline(ns: u64) void; // NO_HZ 动态 tick
```

### 12.11 用户空间 C 运行时和构建策略

**三种用户空间程序的构建方式**:

| 程序类型 | 编译方式 | C 运行时 | 系统调用方式 |
|---|---|---|---|
| **Linux 应用** | `zig cc -target x86_64-linux-musl -static` | musl libc (自带 syscall 桩) | syscall 指令 |
| **Windows 应用** | MinGW 或 MSVC 交叉编译 | ntdll.dll (MoQiOS 提供) | ntdll 桩 → IPC |
| **MoQiOS 原生** | `zig cc -target x86_64-freestanding` | MoQiOS libc (精简) | 直接 IPC 调用 |

**MoQiOS libc 范围**: 提供最小子集 (malloc, printf, string, memcpy 等 ~50 个函数)，不追求完整 POSIX。

### 12.12 IPC 死锁预防

**设计**: IPC call 深度限制 + 超时机制。

```
规则:
  1. 最大调用深度: 8 层 (A→B→C→...→H, 超过则返回 ELOOP)
  2. 超时: 每次 call 默认 30 秒超时 (可配置)
  3. 禁止自调用: 进程不能 call 自己
  4. 内核跟踪调用链: 检测循环 → 返回 EDEADLK

实现:
   每个线程维护 call_chain[8]: 记录当前调用路径
   IPC call 时检查: 新目标是否在 chain 中 → 死锁检测
   ```

---

## 13. 调试架构 (完整设计)

> 基于对 Zigix、MINIX 3、ReactOS 三个参考项目的调试设施分析，设计 MoQiOS 五层调试架构。
> 微内核架构带来了独特的调试挑战——服务崩溃、IPC 死锁、跨地址空间调试——这些在宏内核中不存在。

### 13.1 Layer 1: 内核调试 (裸机层)

**可用环境**: 内核启动早期，无任何用户空间服务，只有串口和 QEMU。

**参考对比**:

| 设施 | Zigix | MINIX 3 | ReactOS |
|---|---|---|---|
| 日志 | 结构化 klog + ring buffer (4096×128B) | kprintf → circular buffer → LOG 驱动 | DbgPrint → 4 sink (screen/serial/logfile/KDBG) |
| Panic | dump ring 64 条 + 返回地址 + RBP | kprintf + prepare_shutdown | KeBugCheck (BSOD + stop code) |
| 异常追踪 | per-CPU 64 条 ring (ELR/SPSR/FAR/PID/EC) | 异常→信号映射 | KD 协议通知调试器 |
| 符号解析 | 无 (手动 llvm-nm) | 无 | KDBG 内置 |

#### 13.1.1 结构化内核日志 (klog)

**设计**: 采用 Zigix 的 lock-free SPSC ring buffer 架构，利用 Zig comptime 实现零开销过滤。

```
架构:
  klog.scoped(.subsystem).info("msg", .{ .key = value })
      ↓ comptime 过滤 (低于 min_level → 编译为空指令)
      ↓ 构建 LogEntry (128 字节 = 2 cache line)
      ↓ lock-free push 到 SPSC ring (4096 条)
      ↓ timer tick 时 drain (每 tick 最多 8 条 → 串口输出)
      ↓ panic 时 flushAll + panicDump(64)
```

**LogEntry 结构**:

```zig
pub const LogEntry = extern struct {
    tick: u64,               // 单调时钟 tick
    level: Level,            // trace/debug/info/warn/err/fatal
    subsystem: Subsystem,    // 子系统标识 (boot/mm/sched/ipc/vfs/...)
    field_count: u8,         // 有效字段数 (0-4)
    _pad: [5]u8,
    msg: [16]u8,             // 消息标签 (null-padded)
    fields: [4]Field,        // 结构化 key=value 字段
};
// comptime 断言: @sizeOf(LogEntry) == 128 (2 cache line)
```

**comptime 零开销过滤**:

```zig
// 子系统定义时指定编译期最小日志级别
pub fn scoped(comptime subsystem: Subsystem) type {
    return struct {
        const min_level = comptimeMinLevel(subsystem);
        
        pub inline fn debug(comptime msg: []const u8, fields: anytype) void {
            if (@intFromEnum(Level.debug) < @intFromEnum(min_level)) return; // 编译为空
            // ... 构建 entry + push
        }
    };
}

// Release 构建: 所有 .debug/.trace 调用编译为空指令
// Debug 构建: 保留所有级别，运行时可动态调整
```

**内核新增文件**:
```
kernel/debug/
├── klog/
│   ├── klog.zig           # 公共 API: scoped().info/warn/err
│   ├── ring.zig            # lock-free SPSC ring (4096 条)
│   ├── serial_sink.zig     # 串口输出 (rate-limited drain, 每 tick 8 条)
│   ├── format.zig          # LogEntry → 文本格式化
│   └── subsystems.zig      # 子系统枚举 + comptime level 过滤表
```

**初始化顺序**: `serial → klog.init(write_string, write_byte, get_tick) → 继续 boot`

#### 13.1.2 Panic Handler

**设计**: 内核 panic 时执行完整的诊断输出序列。

```
panic(msg) 执行序列:
  1. 禁用中断 (cli)
  2. 串口输出 "!!! KERNEL PANIC !!!"
  3. klog.flushAll()           // 刷新所有待输出日志
  4. klog.panicDump(64)        // dump ring 中最近 64 条
  5. 串口输出 panic 消息
  6. backtrace.dump()          // 栈回溯 (frame pointer walk)
     → 逐帧解析 symbol_table 查找函数名
     → 输出: "  #0 0xFFFFFFFF80012345 in handlePageFault (fault.zig:42)"
     → "  #1 0xFFFFFFFF80067ABCD in pageFaultHandler (idt.zig:128)"
     → ...
  7. exception_ring.dump()     // dump 异常历史
  8. halt()                    // 死循环 (`hlt` 指令)
```

#### 13.1.3 栈回溯 (Backtrace)

**设计**: 基于 frame pointer (RBP chain) 的栈遍历 + 符号解析。

```
x86_64 栈帧布局 (启用 -fno-omit-frame-pointer):
  [RBP_old]  ← 当前 RBP 指向
  [return_addr]
  
  walk: rbp = current_rbp → [rbp] = prev_rbp, [rbp+8] = return_addr
  最多遍历 32 帧
```

```zig
pub fn dump() void {
    var rbp: u64 = asm volatile ("movq %%rbp, %[rbp]" : [rbp] "=r" (-> u64));
    var depth: u32 = 0;
    while (depth < 32 and rbp != 0) : (depth += 1) {
        const ret_addr: u64 = @as(*u64, @ptrFromInt(rbp + 8)).*;
        const sym = symbol_table.lookup(ret_addr) orelse "???";
        klog.rawPrint("  #{d} 0x{x} in {s}\n", .{ depth, ret_addr, sym });
        rbp = @as(*u64, @ptrFromInt(rbp)).*;
    }
}
```

**符号表**: build.zig 在编译后运行 `llvm-nm --defined-only kernel.elf > kernel.sym`。内核启动时解析为有序数组，backtrace 时二分查找。

#### 13.1.4 异常环形缓冲区 (Exception Ring)

**设计**: per-CPU 环形缓冲区，记录每次异常入口和返回的关键寄存器。

```
每条记录 (x86_64 版本):
  ExcRingEntry (40 字节):
    rip: u64         // 故障指令地址
    cs: u64          // 代码段
    fault_addr: u64  // CR2 (page fault) 或 0
    pid: u32         // 当前进程 PID
    cpu: u8          // CPU ID
    vec: u8          // 中断向量号
    kind: u8         // 0=entry, 1=return, 2=NMI
    _pad: u8

Per-CPU: 64 条 × 40 字节 = 2.5 KiB
4 核总计: 10 KiB
```

**x86_64 实现要点**: 在 IDT 异常处理入口和返回处各记录一条。使用 per-CPU 索引 (GS base 偏移) 避免 SMP 竞争。

#### 13.1.5 QEMU GDB 调试

**配置**: QEMU 启动参数 `-s -S` 启用 GDB stub，`zig build debug` 自动附加 GDB。

```
支持的操作:
  - 硬件断点 (QEMU 虚拟化，无数量限制)
  - 软件断点 (INT3)
  - 单步执行
  - 寄存器查看/修改
  - 内存查看/修改
  - 远程调试 (TCP:1234)
```

**不需要在内核中实现**——QEMU 的 GDB stub 运行在模拟器层，完全透明。

### 13.2 Layer 2: 用户空间服务调试 (微内核特有)

**核心问题**: VFS/PM/VMM/LinuxPers 崩溃了怎么办？这是宏内核不存在的挑战。

#### 13.2.1 服务崩溃检测

```
检测机制 (内核负责):
  1. 进程异常: 用户态 page fault / GP fault / 除零
     → 内核检查 current_task.is_service
     → 如果是关键服务 (PM/VMM/Init): 内核 panic
     → 否则: 通知 PM "服务 X 崩溃, reason=SIGSEGV"
  
  2. 进程退出: 服务调用 exit() 但不是正常终止
     → PM 收到 exit IPC → 检查服务注册表
     → 如果是注册服务: 触发重启流程
  
  3. IPC 超时: 服务 30 秒无响应 (死锁检测)
     → IPC 超时回调 → 通知 PM "服务 X 无响应"
     → PM 可选择: kill + restart 或 panic
```

#### 13.2.2 服务崩溃恢复

```
恢复流程 (Init + PM 协同):
  1. PM 通知 Init: "服务 X 崩溃, reason=Y"
  2. Init 查询服务依赖图:
     - X 有谁依赖? → 通知依赖方 "X 已崩溃，请重置连接"
     - X 依赖谁? → 重启 X 前确保其依赖仍然存活
  3. PM 重启服务 X:
     a. 创建新进程 (新 PID)
     b. 映射服务二进制 (从 ramdisk/VFS)
     c. 注册新 endpoint (capability 重建)
     d. 启动服务
  4. 依赖方重连:
     - 客户端持有旧 capability → 下次 IPC 返回 ESRVC
     - 客户端通过 PM 查询新 endpoint → 重建连接
```

**服务崩溃严重度分级**:

| 级别 | 服务 | 崩溃处理 | 理由 |
|---|---|---|---|
| 🔴 致命 | Init, PM, VMM | **内核 panic** | 系统无法运行 |
| 🟠 严重 | VFS, DevMgr | 重启 + 通知所有客户端 | 可能丢失 I/O 状态 |
| 🟡 一般 | LinuxPers, WinPers, NetStack | 重启 + 通知受影响进程 | 只影响对应 ABI |
| 🟢 可选 | TTY, 用户驱动 | 静默重启 | 无级联影响 |

#### 13.2.3 IPC 消息追踪

**设计**: comptime 可选的 IPC trace ring buffer，记录所有 IPC 消息流。

```zig
// IPC trace entry — 32 字节 (半个 cache line)
const IpcTraceEntry = extern struct {
    timestamp: u64,     // TSC 纳秒
    src_pid: u32,       // 发送方 PID
    dst_pid: u32,       // 接收方 PID
    msg_type: u32,      // 消息类型 (SYSCALL/REPLY/NOTIFY/...)
    flags: u8,          // send/recv/call/reply/notify
    result: u8,         // 0=success, 1=timeout, 2=error
    _pad: [2]u8,
};

// Per-CPU ring: 1024 条 × 32B = 32KB per CPU
// comptime 开关控制:
const enable_ipc_trace = config.debug; // Debug 构建启用, Release 编译为空
```

**查询接口**: 通过专用 IPC `TRACE_QUERY` 或 `/proc/ipc_trace` 读取最近 N 条记录。

**开销分析**: 每条 IPC 增加 ~50ns (TSC 读取 + ring buffer 写入)。Release 构建完全无开销。

#### 13.2.4 服务状态转储

```
服务崩溃时内核保存的状态:
  1. 进程上下文: 寄存器快照 (保存在 task struct 中)
  2. 地址空间: 页表 + VMA 列表 (通过 VMM 查询)
  3. IPC 历史: 最近 32 条 IPC 消息 (从 trace ring 读取)
  4. 内核日志: klog 中该 PID 的所有条目 (按 subsystem 过滤)
  5. 栈内容: 内核栈 + 用户栈前 4KB

转储目标:
  - Phase 1: 串口输出 (文本格式)
  - Phase 2: 写入 /var/crash/service.PID.dump (需要 VFS 写支持)
```

### 13.3 Layer 3: Linux 二进制调试 (ptrace)

**核心问题**: 微内核中 ptrace 由谁实现？

**参考**: MINIX 3 的方案——内核提供 `SYS_TRACE` 基本操作，PM 管理进程关系。

#### 13.3.1 内核调试原语

**设计**: 内核提供 4 个最基本的调试操作，LinuxPers 和 WinPers 共享。

```zig
// kernel/debug/trace.zig — 统一调试原语
pub const TraceOp = enum(u8) {
    read_memory,    // 读取目标进程内存
    write_memory,   // 写入目标进程内存
    get_regs,       // 获取寄存器快照
    set_regs,       // 修改寄存器
    single_step,    // 单步执行 (设置 TF flag)
    continue_,      // 继续执行
    set_breakpoint, // 设置 INT3 断点
    clear_breakpoint, // 清除断点
};

// 安全检查: 只有 tracer 才能操作 tracee
pub fn traceOp(tracer_pid: u32, tracee_pid: u32, op: TraceOp, ...) Error!Result;
```

**INT3 断点处理**:

```
tracee 执行到 INT3:
  1. CPU 触发 #BP (向量 3)
  2. 内核异常处理器:
     a. 检查 current_task.traced_by != 0
     b. 是 → 暂停 tracee (状态设为 STOPPED)
     c. 向 tracer 发送通知 IPC: { .type = TRACE_EVENT, .event = .breakpoint, .addr = rip }
     d. tracer (gdb) 通过 ptrace(PTRACE_GETREGS) 查询
     e. tracer 调用 ptrace(PTRACE_CONT) → tracee 恢复
```

#### 13.3.2 ptrace 系统调用路径

```
gdb 调用 ptrace(request, pid, addr, data):
  1. syscall → 内核 LSTAR 入口
  2. personality == .linux → IPC 到 LinuxPers
  3. LinuxPers 处理 ptrace 请求:
     - PTRACE_TRACEME: 标记当前进程 "被父进程 trace"
       → IPC 通知 PM: "PID X 标记为被 PID Y trace"
     - PTRACE_ATTACH: 请求 trace 目标进程
       → PM 检查权限 → 通知目标进程 "你被 trace 了"
       → 目标进程收到 SIGSTOP
     - PTRACE_PEEKTEXT/DATA: 读取 tracee 内存
       → LinuxPers → IPC → PM → 内核 traceOp(.read_memory)
     - PTRACE_CONT/SINGLESTEP: 恢复 tracee 执行
       → LinuxPers → IPC → PM → 内核 traceOp(.continue_/.single_step)
     - PTRACE_GETREGS/SETREGS: 读写寄存器
       → LinuxPers → IPC → PM → 内核 traceOp(.get_regs/.set_regs)
  4. LinuxPers 构造 ptrace 返回值 → reply 内核 → sysretq
```

**涉及 IPC 路径**: `gdb → kernel → LinuxPers → PM → kernel(traceOp)` = 3 次 IPC 往返。
**性能影响**: 每次 ptrace 操作约 3μs (QEMU)，可接受 (gdb 本身有延迟)。

#### 13.3.3 fork 后的 tracing

```
PTRACE_TRACEME (由子进程调用):
  1. fork() 后子进程设置 self.traced_by = parent_pid
  2. 子进程任何 signal 都先通知 tracer
  3. tracer 决定: 继续传递 signal / 忽略 / 终止

PTRACE_ATTACH (由 gdb 调用):
  1. 请求 trace 任意进程
  2. PM 检查: tracer 有权限 trace 目标吗? (同 UID)
  3. 目标进程收到 SIGSTOP → 暂停
  4. tracer 获得 trace 权限
```

### 13.4 Layer 4: Windows 二进制调试 (NT Debug APIs)

**设计**: 复用 Layer 3 的内核调试原语，WinPers 翻译为 NT 语义。

#### 13.4.1 NT Debug API 映射

```
Windows API 调用链:
  DebugActiveProcess(pid)  →  ntdll.dll 桩  →  IPC 到 WinPers
  WaitForDebugEvent(event) →  ntdll.dll 桩  →  IPC 阻塞等待
  ContinueDebugEvent(...)  →  ntdll.dll 桩  →  IPC 继续

WinPers 内部:
  DebugActiveProcess → 请求 PM trace 目标进程 (同 ptrace 机制)
  WaitForDebugEvent → 阻塞等待内核 TRACE_EVENT IPC
  ContinueDebugEvent → 内核 traceOp(.continue_)
```

**DEBUG_EVENT 转换**:

| Windows 事件 | MoQiOS 内部事件 | 生成条件 |
|---|---|---|
| EXCEPTION_DEBUG_EVENT | traceOp 报告断点/异常 | INT3 / 页面异常 / 非法指令 |
| CREATE_PROCESS_DEBUG_EVENT | PM 通知新进程 | 目标进程 execve |
| EXIT_PROCESS_DEBUG_EVENT | PM 通知进程退出 | 目标进程 exit |
| LOAD_DLL_DEBUG_EVENT | WinPers 通知 DLL 加载 | PE 加载器映射新 DLL |
| OUTPUT_DEBUG_STRING_EVENT | WinPers 转发 | 目标调用 OutputDebugString |

#### 13.4.2 SEH 与调试器交互

```
Windows 异常处理的调试器交互:
  异常发生 → 内核 → WinPers:
    第一步: 通知调试器 (if attached)
      → 发送 EXCEPTION_DEBUG_EVENT (first chance)
      → 调试器返回 DBG_CONTINUE (已处理) 或 DBG_EXCEPTION_NOT_HANDLED
    第二步: 如果调试器不处理 → 走 SEH chain
      → __try/__except 处理
    第三步: 如果 SEH 也不处理 → 再次通知调试器 (second chance)
      → 调试器仍不处理 → 终止进程 ( crash )
```

### 13.5 Layer 5: 高级/生产调试

#### 13.5.1 Core Dump 生成

```
进程崩溃时:
  1. 内核暂停崩溃进程 (状态 = STOPPED)
  2. PM 通知 crash handler 服务
  3. crash handler:
     a. 读取进程寄存器快照
     b. 通过 VMM IPC 获取地址空间映射
     c. dump 进程内存到文件:
        - Linux 进程 → ELF core file (readelf -a 可解析)
        - Windows 进程 → minidump format (.dmp)
     d. 保存到 /var/core/core.PID.TIMESTAMP
  4. 通知 Personality Server 发送信号/异常

实现阶段: M8 之后 (需要 VFS 写 + ext4 读写)
```

#### 13.5.2 系统级事件追踪 (Tracepoint)

```zig
// 利用 Zig comptime 实现零开销 tracepoint
pub fn tracepoint(comptime name: []const u8, args: anytype) void {
    if (!config.tracepoint_enabled) return; // Release 编译为空

    const entry = TraceEntry{
        .timestamp = arch.readTsc(),
        .name_hash = comptime hashString(name), // 编译期计算
        .cpu_id = smp.cpuId(),
        .args = packArgs(args),
    };
    trace_ring.push(entry);
}

// 使用:
tracepoint("sched.switch", .{ .from = old_pid, .to = new_pid });
tracepoint("ipc.send", .{ .src = src, .dst = dst, .type = msg_type });
tracepoint("page.fault", .{ .pid = pid, .addr = fault_addr, .cow = is_cow });
tracepoint("syscall.enter", .{ .pid = pid, .nr = syscall_nr });
```

**输出**: 通过 `/proc/trace` 或专用 IPC 查询接口读取。

#### 13.5.3 性能剖析 (Perf Sampling)

```
基于 timer interrupt 的采样:
  每次 tick (可配置: 1ms/10ms/100ms):
    → 记录 { timestamp, pid, pc, cpu }
    → 积累 N 个样本后统计热点函数
    → 通过 /proc/perf 读取

开销: 每次 tick +100ns (一条记录)
精度: 与 Linux perf stat 类似 (统计意义)
```

### 13.6 内核调试模块文件结构

```
kernel/debug/
├── klog/
│   ├── klog.zig            # 公共 API: scoped().info/warn/err (~115 行)
│   ├── ring.zig             # lock-free SPSC ring buffer (~130 行)
│   ├── serial_sink.zig      # 串口输出 + rate-limited drain (~100 行)
│   ├── format.zig           # LogEntry → 文本格式化 (~80 行)
│   └── subsystems.zig       # 子系统枚举 + level 过滤表 (~60 行)
├── backtrace.zig            # RBP chain walk + symbol resolve (~120 行)
├── symbol_table.zig         # ELF .symtab 加载 + 二分查找 (~80 行)
├── exception_ring.zig       # per-CPU 异常追踪 ring (~100 行)
├── panic.zig                # 统一 panic: flushAll + backtrace + halt (~60 行)
└── trace.zig                # 统一调试原语 (read/write/step/breakpoint) (~200 行)

总计: ~1,045 行 (内核调试设施)
```

### 13.7 实施优先级

| 优先级 | 设施 | 阶段 | 复杂度 | 行数估算 | 理由 |
|---|---|---|---|---|---|
| **P0** | 结构化 klog + ring buffer | M1 | 中 | ~485 | 所有其他调试的基础 |
| **P0** | Serial 输出 | M1 | 低 | ~60 | 已有，确保最早可用 |
| **P0** | QEMU GDB stub | M1 | 低 | ~5 | `-s -S` 即可 |
| **P1** | Panic handler + backtrace | M1 | 中 | ~180 | 崩溃诊断必需 |
| **P1** | Exception ring buffer | M1 | 中 | ~100 | 崩溃前回溯 |
| **P1** | Symbol table 加载 | M1 | 低 | ~80 | 回溯显示函数名 |
| **P2** | 服务崩溃检测 + 恢复 | M5 | 中 | ~200 | 服务可用性 |
| **P2** | IPC trace buffer | M4 | 中 | ~120 | 微内核调试核心工具 |
| **P3** | 统一调试原语 (trace.zig) | M8 | 高 | ~200 | ptrace 和 NT debug 共享 |
| **P3** | ptrace 实现 (LinuxPers) | M8 | 高 | ~300 | Linux gdb 调试 |
| **P3** | Windows debug API (WinPers) | M9 | 高 | ~250 | Windows 调试器 |
| **P4** | Core dump | M8+ | 中 | ~200 | 事后分析 |
| **P4** | Tracepoint (ftrace) | M10+ | 中 | ~150 | 性能分析 |
| **P4** | Perf sampling | M10+ | 低 | ~80 | 热点分析 |

### 13.8 发现的设计缺陷

| # | 缺陷 | 严重度 | 修正方案 |
|---|---|---|---|
| D7 | §12.9 klog 设计过于原始，只是分级串口输出 | 高 | 升级为结构化 klog + lock-free ring buffer + comptime 过滤 |
| D8 | 缺少服务崩溃恢复机制 | 高 | Init 维护服务依赖图 + PM 健康监控 + 分级重启策略 |
| D9 | 缺少 ptrace / 进程调试架构 | 高 | 内核提供 4 个调试原语 + LinuxPers 实现 ptrace + WinPers 实现 NT debug |
| D10 | 缺少 IPC 消息追踪 | 中 | comptime 可选的 IPC trace ring buffer，Debug 构建启用 |

**D7 修正**: 将 §12.9 的简单 klog 替换为本节的结构化设计。内核 `klog.zig` 从 ~60 行扩展为完整模块 (~485 行)。

**D8 修正**: Init 服务需要增加服务依赖图和重启策略。PM 需要增加服务健康监控 (心跳 IPC)。已在实施计划 M5.11 (Init 依赖排序) 基础上扩展。

**D9 修正**: 内核新增 `debug/trace.zig` (~200 行) 提供统一调试原语。LinuxPers 新增 `ptrace.zig` (~300 行)。WinPers 新增 `debug_api.zig` (~250 行)。

**D10 修正**: IPC 引擎 (ipc.zig) 中增加可选 trace ring (~120 行)，comptime 开关控制。

---

## 14. 中断子系统设计

> 基于性能优先原则，选定 Scheme D: 中断线程 + MSI-X + 中断合并 + 用户空间 MMIO。
> 参考: QNX Neutrino 中断线程模型、Linux threaded IRQ、Zigix virtio 驱动。

### 14.1 设计选型: Scheme D (中断线程)

**方案对比**:

| 方案 | 延迟 | 吞吐 | 实现复杂度 | 适用场景 |
|---|---|---|---|---|
| A: 直接 IPC 通知 | 高 (2-3μs) | 低 | 低 | 简单设备 |
| B: 内核 bottom half + IPC | 中 | 中 | 中 | 混合设备 |
| C: 用户空间轮询 (virtio ring) | 最低 | 最高 | 中 | 高速设备 |
| **D: 中断线程 + MSI-X** | **低** | **高** | **中** | **通用** |

**Scheme D 架构**:

```
硬件中断 → CPU:
  1. 内核 IDT 入口 (汇编, ~20 条指令)
     → 保存少量寄存器
     → ACK 中断 (LAPIC EOI 或 write to IOAPIC)
     → 查找 IRQ → 中断线程映射
     → 唤醒对应中断线程 (unblock)
     → iretq 返回
  2. 中断线程 (内核线程, 优先级最高):
     → 被唤醒后执行驱动回调
     → 驱动通过 IPC 通知用户空间服务 (DevMgr/驱动进程)
     → 驱动重新注册等待下一个中断
```

**关键优势**: ACK + 唤醒在内核中完成 (快速)，实际处理在中断线程上下文 (可调度、可抢占)。

### 14.2 x86_64 中断控制器

```
初始化顺序 (M1 → M3):
  1. ACPI MADT 解析 → 获取 LAPIC 基地址 + IOAPIC 地址 + CPU APIC ID 列表
  2. LAPIC 初始化:
     → 映射 MMIO 基地址 (通过 MADT 提供)
     → 设置 Spurious Interrupt Vector (0xFF)
     → 配置 Timer (周期模式, divide=16)
     → 配置 LVT entries (Timer, LINT0, LINT1, Error, PMC)
  3. IOAPIC 初始化:
     → 映射 MMIO 基地址
     → 配置 24 个 redirection entry
     → 设置 IRQ → vector 映射
  4. MSI-X 配置 (PCI 设备):
     → 通过 PCI Capability 链发现 MSI-X
     → 分配 vector → 写入 MSI-X table
     → 每个队列独立 vector (virtio: rx/tx/control 各一个)
```

### 14.3 中断线程模型

```zig
/// 中断线程描述符
pub const IrqThread = struct {
    irq: u8,                    // IRQ 号
    vector: u8,                 // CPU 中断向量 (32-255)
    thread_id: ThreadId,        // 关联的内核线程
    handler: *const fn (*IrqThread) void,  // 驱动回调
    dev_endpoint: EndpointId,   // 用户空间驱动 endpoint (用于 IPC 通知)
    enabled: bool,
    pending_count: u32,         // 中断合并计数
    last_tick: u64,             // 上次中断 tick (用于合并判断)
};

/// 内核维护的中断线程表
var irq_threads: [256]?IrqThread = .{null} ** 256;
```

**中断合并 (Coalescing)**:

```
高频中断 (如网络 rx):
  设置合并窗口 = 100μs (可配置)
  在窗口内的后续中断只增加 pending_count, 不重复唤醒线程
  中断线程被唤醒后处理所有 pending 事件
  → 减少 80%+ 的中断线程唤醒次数
```

### 14.4 中断路由到用户空间

```
硬件中断 → 内核 → 用户空间驱动的完整路径:

  1. 硬件中断 → CPU (vector N)
  2. 内核 IDT 入口:
     a. 保存上下文
     b. ACK 中断 (LAPIC: write EOI; IOAPIC: write EOI 或 level-triggered 自动)
     c. irq_thread = irq_threads[N]
     d. if irq_thread.coalesce_window 未过期 → pending_count++ → iretq
     e. scheduler.unblock(irq_thread.thread_id)
     f. iretq
  3. 中断线程被调度执行:
     a. 调用 handler() — 通常是 minimal work (读取状态寄存器)
     b. 通过 IPC notify 通知用户空间驱动: notify(dev_endpoint, IRQ_NOTIFY_BIT)
     c. pending_count = 0
  4. 用户空间驱动 (通过 IPC notify 唤醒):
     a. 读取设备寄存器 (通过 MMIO 映射 — userspace MMIO)
     b. 处理完成队列 (virtio avail/used ring 等)
     c. 重新注册等待
```

**userspace MMIO**: 通过 DevMgr 将设备的 BAR 空间映射到驱动进程的地址空间 (MAP_DEVICE 权限)，驱动可直接读写寄存器，无需 IPC。

### 14.5 AArch64 中断模型

```
ARM64 中断控制器: GICv2/GICv3 (通过 ACPI or FDT 发现)
  → Distributor: 中断路由和优先级
  → Redistributor (GICv3): per-CPU 配置
  → CPU Interface: ACK/EOI

差异:
  - x86_64: IDT + LAPIC/IOAPIC + MSI-X
  - AArch64: Exception Vector + GIC + SPI/PPI/SGI

HAL 抽象:
  hal.irq_init()          → x86_64: init LAPIC + IOAPIC; ARM: init GIC
  hal.irq_ack(vector)     → x86_64: LAPIC EOI; ARM: GIC DIR + EOI
  hal.irq_mask(vector)    → x86_64: IOAPIC mask; ARM: GIC disable
  hal.irq_unmask(vector)  → x86_64: IOAPIC unmask; ARM: GIC enable
  hal.irq_set_affinity()  → x86_64: IOAPIC redirection; ARM: GIC affinity
```

### 14.6 中断优先级

```
中断优先级分层:
  最高: NMI, Machine Check (不可屏蔽, 必须立即处理)
  高:   时钟中断 (驱动调度器 tick)
  中:   块设备完成, 网络中断 (驱动 I/O)
  低:   键盘, 鼠标, 串口

实现:
  - x86_64: IOAPIC redirection entry 的 delivery mode + priority
  - 中断线程继承优先级: 时钟中断线程 = SCHED_FIFO 最高优先级
  - 低优先级中断在高负载时可延迟处理
```

### 14.7 缺陷修正

| # | 缺陷 | 修正 |
|---|---|---|
| D11 | 中断处理缺少详细设计 | 新增本节，采用 Scheme D (中断线程 + MSI-X + coalescing + userspace MMIO) |

---

## 15. Capability 系统设计

> 微内核安全的基石。所有 IPC 通道和资源访问通过 capability 授权。

### 15.1 设计目标

1. **最小权限**: 进程只能访问它持有的 capability 允许的资源
2. **可委托**: 进程可以将 capability 子集传递给子进程
3. **可撤销**: capability 可以被撤销 (服务重启场景)
4. **高性能**: capability 检查是热路径 (每次 IPC), 必须极快

### 15.2 Capability 数据结构

```zig
/// Capability 令牌 — 16 字节, 对齐到 cache line
pub const Capability = extern struct {
    object_id: u32,      // 目标对象 (endpoint, device, memory region)
    rights: Rights,      // 权限位图
    generation: u16,     // 代数 (用于撤销检测)
    _pad: u16,

    pub const Rights = packed struct(u32) {
        send: bool,          // 可以向 endpoint 发送消息
        receive: bool,       // 可以从 endpoint 接收消息
        call: bool,          // 可以发起 call (send + wait reply)
        notify: bool,        // 可以发送异步通知
        grant: bool,         // 可以传递此 capability 给其他进程
        revoke: bool,        // 可以撤销此 capability
        read_memory: bool,   // 可以读取目标内存区域
        write_memory: bool,  // 可以写入目标内存区域
        map_device: bool,    // 可以映射设备 MMIO
        manage: bool,        // 可以管理 (创建/销毁) 子 capability
        _reserved: u22,      // 保留
    };
};

/// 进程的 capability 表 — 存储在内核 task 结构中
pub const CapTable = struct {
    /// 直接 capability (快速路径): 32 个固定槽位
    direct: [32]?Capability,
    
    /// 间接 capability (慢路径): 用于大量 capability 场景
    /// 通过 slab 分配的链表
    indirect_count: u16,
    indirect: ?*IndirectCapNode,
};

pub const IndirectCapNode = struct {
    caps: [64]Capability,
    next: ?*IndirectCapNode,
};
```

### 15.3 Capability 生命周期

```
创建:
  内核启动时:
    → Init 获得 CAP_KERNEL(所有权限) — root capability
    → PM, VFS, VMM 各获得 CAP_MANAGE + 对应资源权限
  
  服务启动时 (Init 委托):
    → Init 从自己的 capability 中派生子 capability
    → 子 capability 权限 ⊆ 父 capability (权限衰减)
    → 子 capability 新 generation number
  
  用户进程创建时 (PM 委托):
    → PM 分配 CAP_SEND(linux_pers_endpoint) — 只能发 IPC 给 LinuxPers
    → PM 分配 CAP_CALL(pm_endpoint) — 可以向 PM 请求服务

传递:
  IPC 消息中携带 capability:
    → 发送方在 msg.flags 中设置 CAP_TRANSFER 标志
    → 接收方在指定槽位获得 capability 副本
    → 权限: min(sender_rights, requested_rights)

撤销:
  服务重启时:
    → 所有持有该服务 endpoint capability 的进程
    → generation 不匹配 → IPC 返回 ESRVC
    → 进程需要通过 PM 重新获取 capability

销毁:
  进程退出时:
    → 所有 capability 自动释放
    → 引用计数减少
```

### 15.4 IPC 中的 Capability 检查

```zig
/// 每次 IPC 的安全检查 — 内核热路径
pub fn ipcCheck(caller: *Task, target_ep: EndpointId, op: IpcOp) bool {
    // 快速路径: 检查直接 capability 表 (32 个槽位)
    comptime var i: usize = 0;
    inline while (i < 32) : (i += 1) {
        if (caller.caps.direct[i]) |cap| {
            if (cap.object_id == target_ep) {
                return switch (op) {
                    .send    => cap.rights.send,
                    .receive => cap.rights.receive,
                    .call    => cap.rights.call,
                    .reply   => true, // reply 不检查 (已有调用上下文)
                    .notify  => cap.rights.notify,
                };
            }
        }
    }
    
    // 慢路径: 检查间接 capability 表
    return checkIndirectCaps(caller, target_ep, op);
}
```

**性能**: 直接表检查是 inline 循环 (32 次比较), 约 ~50ns。绝大多数服务只需 < 10 个 capability, 热路径极快。

### 15.5 缺陷修正

| # | 缺陷 | 修正 |
|---|---|---|
| D12 | 内核栈溢出保护缺失 | 每个 Task 创建时分配 guard page; IDT #DF/#NMI 使用 IST |
| D13 | Capability 系统缺少具体设计 | 新增本节, 定义数据结构 + 生命周期 + IPC 检查 |

### 15.6 内核栈保护设计 (D12)

```
内核栈布局 (4 页 = 16KB + 1 guard page):
  ┌───────────────────┐ 0xFFFF...1000  ← 栈顶 (RSP 初始值)
  │ 内核栈 16KB       │                ← 正常使用
  ├───────────────────┤ 0xFFFF...5000
  │ Guard Page (未映射) │              ← 访问触发 #PF → 检测到栈溢出
  └───────────────────┘ 0xFFFF...4000

IDT IST 配置:
  IST1 → Double Fault 栈 (独立 16KB, 防止栈溢出时无法处理 #DF)
  IST2 → NMI 栈 (独立 16KB, 任何上下文都能处理)
  
上下文切换时:
  → 检查 task.kernel_stack 指向的 guard page 是否完好
  → 可选: 栈使用量统计 (栈底放 magic number, 检查是否被覆盖)
```

---

## 16. 性能优化策略

> 微内核的 IPC 开销是性能瓶颈。本节定义关键优化路径。

### 16.1 VDSO (Virtual Dynamic Shared Object)

**问题**: `gettimeofday`, `clock_gettime`, `getpid` 等高频调用不需要进入内核。

```
VDSO 实现:
  1. 内核在用户进程地址空间映射一个特殊页面 (类似 KUSER_SHARED_DATA)
     → 0x7FFFF7FFF000 (Linux vdso 位置)
  2. 页面内容:
     → 时钟值 (由内核 timer tick 更新)
     → PID 缓存
     → CPU 数量
     → 可用处理器掩码
  3. libc 的 gettimeofday 直接读取此页面, 不执行 syscall
  4. 读取操作: 单次内存访问 ~2ns vs syscall ~500ns

映射时机: 进程创建时由 PM 请求内核映射
更新频率: 每次 timer tick (可配置)
```

### 16.2 快速系统调用 (Fast Path)

**问题**: 某些 syscall 不需要走 IPC 到 Personality Server。

```
内核直接处理的 syscall (不需要 IPC):
  Linux: getpid(), gettid(), sched_yield(), clock_gettime(VDSO fallback)
  Windows: NtCurrentTeb() (纯用户空间), GetTickCount() (KUSER_SHARED_DATA)

判定规则:
  → 无副作用的只读操作 → 内核直接处理
  → 涉及资源修改 → 必须走 IPC
  → 性能测量后动态调整列表

实现:
  syscall 入口处:
    if (fastPathTable[syscall_nr]) |handler| {
        return handler(&regs);  // 直接在内核处理, ~100ns
    }
    // 否则走 IPC → Personality Server
```

### 16.3 PCID / ASID 优化

```
x86_64 PCID (Process-Context Identifier):
  → CR3 低 12 bit 包含 PCID (0-4095)
  → 进程切换时: 加载新 CR3 + PCID → 只刷新本 PCID 的 TLB
  → 不再需要全局 TLB 刷新 (invlpg all → PCID-local flush)
  
  分配策略:
    PCID 0: 内核 (共享, 不刷新)
    PCID 1-N: 用户进程 (每个进程唯一)
    PCID 复用: 进程退出时释放

AArch64 ASID:
  → TTBR0_EL1[47:0] = 页表基址, ASID 在 TTBR0_EL1[63:48] (8 bit = 256 个)
  → 内核在 TTBR1_EL1 (不切换, 共享)
  → 用户进程切换 TTBR0 + ASID → 不刷新 TLB
  
  约束: ARM ASID 只有 256 个, 需要 round-robin 溢出时全局刷新

实施: M11 (SMP 移植时集成)
```

### 16.4 系统调用批处理 (io_uring 方向)

```
Phase 2 优化方向:
  → 类似 Linux io_uring 的共享环形缓冲区
  → 用户写入请求到 ring → 内核批量处理 → 写回结果到 ring
  → 减少 syscall 次数: N 次 I/O = 1 次 syscall (而非 N 次)
  → 需要 VFS 写支持 + 共享内存 API

本阶段: 预留接口, 不实现
```

### 16.5 缺陷修正

| # | 缺陷 | 修正 |
|---|---|---|
| D15 | 系统调用性能优化路径缺失 | 新增本节: VDSO + 快速系统调用 + PCID + io_uring 方向 |
| D21 | PCID/ASID 详细设计缺失 | §16.3 PCID 分配策略 + AArch64 ASID 约束 |

---

## 17. 服务管理、Init 配置与系统关机

### 17.1 Init 配置文件格式

```toml
# /etc/moqios.conf — MoQiOS 服务配置文件

[service.pm]
binary = "/sbin/pm"
priority = 90          # 调度优先级
restart_on_crash = false  # 关键服务，崩溃 → panic
depends = []

[service.vmm]
binary = "/sbin/vmm"
priority = 88
restart_on_crash = false
depends = []

[service.vfs]
binary = "/sbin/vfs"
priority = 85
restart_on_crash = true
max_restarts = 3
restart_window_sec = 60
depends = ["pm", "vmm"]

[service.devmgr]
binary = "/sbin/devmgr"
priority = 80
restart_on_crash = true
max_restarts = 5
depends = ["vfs"]

[service.linux_pers]
binary = "/sbin/linux_pers"
priority = 70
restart_on_crash = true
max_restarts = 10
depends = ["pm", "vfs", "vmm"]

[service.win_pers]
binary = "/sbin/win_pers"
priority = 70
restart_on_crash = true
max_restarts = 10
depends = ["pm", "vfs", "vmm"]

[service.netstack]
binary = "/sbin/netstack"
priority = 60
restart_on_crash = true
depends = ["devmgr"]

[service.ttyd]
binary = "/sbin/ttyd"
priority = 50
restart_on_crash = true
depends = ["devmgr", "vfs"]
```

### 17.2 服务启动流程

```
Init 启动序列:
  1. 解析 /etc/moqios.conf
  2. 构建服务依赖图 (DAG)
  3. 拓扑排序确定启动顺序:
     pm → vmm → vfs → devmgr → (linux_pers | win_pers | netstack) → ttyd
  4. 逐个启动:
     a. IPC 请求 PM: "创建进程, binary=/sbin/pm, priority=90"
     b. 等待服务就绪 (服务通过 IPC 向 Init 报告 "ready")
     c. 超时 (5 秒) → 标记启动失败
  5. 所有服务启动后:
     a. 挂载根文件系统 (VFS 就绪后)
     b. 启动默认 shell 或 login 程序

错误处理:
  - 关键服务 (restart_on_crash=false) 启动失败 → 内核 panic
  - 非关键服务启动失败 → 记录日志, 跳过
  - 重启策略: 指数退避 (1s, 2s, 4s, 8s, 最大 60s)
```

### 17.3 系统关机流程

```
shutdown 路径:
  1. Init 收到 shutdown 信号 (SIGTERM 或 IPC 命令)
  2. 通知所有用户进程终止 (SIGTERM → 等待 5s → SIGKILL)
  3. 按逆拓扑序通知服务退出:
     ttyd → netstack → win_pers → linux_pers → devmgr → vfs → vmm → pm
  4. VFS sync (将脏页刷入磁盘, 需要 ext4 写支持)
  5. 内核关机:
     a. 停止其他 CPU (发送 IPI HALT)
     b. ACPI shutdown:
        → 写 SLP_TYP=S5 到 PM1a_CNT / PM1b_CNT
        → 写 SLP_EN 位
     c. QEMU 退出: 写 0x604 (QEMU ACPI shutdown port)
     d. 最后手段: hlt 循环
```

### 17.4 缺陷修正

| # | 缺陷 | 修正 |
|---|---|---|
| D20 | Init 系统配置缺失 | §17.1 配置文件格式 + §17.2 启动流程 |
| D23 | shutdown/reboot 设计缺失 | §17.3 完整关机流程 |

---

## 18. 驱动生态与图形输出

> 基于宏内核架构对比审查，补充 USB 驱动栈、GPU/Framebuffer 和驱动动态加载三项关键遗漏。

### 18.1 USB 驱动栈 (E1)

**为什么需要**: USB 是现代系统的基本外设总线。QEMU 默认使用 USB 键盘/鼠标，真机几乎没有 PS/2。U 盘是最常见的可移动存储。

**架构**: xHCI 驱动作为用户空间服务进程运行，通过 Capability 授权访问 MMIO。

```
USB 驱动栈层次:

  ┌──────────────────────────────────────────────────┐
  │              用户空间                              │
  │                                                  │
  │  应用程序: 文件管理器, shell, ...                  │
  │       │                                          │
  │       ▼                                          │
  │  VFS (块设备 / 字符设备)                          │
  │       │                                          │
  │  ┌────┴────┐                                     │
  │  │ DevMgr  │ 设备注册/发现/驱动加载               │
  │  └────┬────┘                                     │
  │       │                                          │
  │  ┌────┴──────────────────────────────────┐       │
  │  │         USB 驱动服务 (usbd)            │       │
  │  │                                       │       │
  │  │  ┌─────────────┐  ┌───────────────┐  │       │
  │  │  │ xHCI 控制器  │  │ USB Hub 驱动   │  │       │
  │  │  │ 驱动         │  │ (root hub)    │  │       │
  │  │  └──────┬──────┘  └───────┬───────┘  │       │
  │  │         │                 │           │       │
  │  │  ┌──────┴─────────────────┴───────┐  │       │
  │  │  │         USB Core               │  │       │
  │  │  │  设备枚举 / 传输管理 / URB     │  │       │
  │  │  └──────────────┬────────────────┘  │       │
  │  │                 │                    │       │
  │  │  ┌──────────────┼────────────────┐  │       │
  │  │  │ USB HID      │ USB Mass       │  │       │
  │  │  │ (键盘/鼠标)  │ Storage (U盘)  │  │       │
  │  │  └──────────────┴────────────────┘  │       │
  │  └─────────────────────────────────────┘       │
  │       │ IPC (中断通知 + 数据传输)                │
  ├───────┼──────────────────────────────────────────┤
  │  内核  │                                          │
  │  └── IRQ 路由 → 中断线程 → notify usbd            │
  └──────────────────────────────────────────────────┘
```

#### 18.1.1 xHCI 控制器驱动

```zig
/// xHCI (USB 3.0) 控制器驱动 — 用户空间服务
/// 通过 PCI 发现 xHCI 控制器, Capability 授权 MMIO 访问

pub const XhciDriver = struct {
    /// MMIO 寄存器 (通过 DevMgr 映射到驱动地址空间)
    regs: *volatile XhciRegisters,
    
    /// Command Ring (驱动 → 控制器命令)
    cmd_ring: CommandRing,
    
    /// Event Ring (控制器 → 驱动完成通知)
    event_ring: EventRing,
    
    /// Transfer Ring (每个 USB 设备的端点各一个)
    transfer_rings: [256]?TransferRing,
    
    /// 已枚举的 USB 设备
    devices: [128]?UsbDevice,
    
    pub fn init(pci_device: PciDeviceInfo) !XhciDriver;
    pub fn enumerateDevices(self: *XhciDriver) !void;
    pub fn submitUrb(self: *XhciDriver, device: u8, endpoint: u8, urb: *Urb) !void;
};
```

**xHCI 初始化流程**:
```
1. DevMgr 发现 PCI device (class=0x0C03, xHCI)
2. 映射 BAR0 (MMIO 寄存器空间) 到驱动地址空间
3. 请求内核分配中断线程 (MSI-X vector)
4. BIOS Handoff (如果 BIOS 仍在控制 xHCI)
5. Reset controller → await ready
6. 设置 Command Ring + Event Ring (DMA, 物理内存)
7. 启动 controller → 枚举 Root Hub ports
8. 对每个连接的设备: 
   → Reset port → Set Address → Get Descriptor
   → 根据 Class/Protocol 选择子类驱动
```

#### 18.1.2 USB 设备类驱动

| USB 类 | 驱动 | 注册到 | 功能 |
|---|---|---|---|
| HID (0x03) | usbd 内置 | DevMgr → /dev/input/kbd, /dev/input/mouse | 键盘/鼠标输入 |
| Mass Storage (0x08) | usbd 内置 | DevMgr → /dev/sdX (块设备) | U 盘读写 |
| CDC-ACM (0x02) | 可选 | DevMgr → /dev/ttyACMX | USB 串口 |
| Hub (0x09) | usbd 内置 | 内部 | 端口扩展 |

**USB HID → TTY 集成**:
```
USB 键盘按键:
  xHCI 中断 → 中断线程 → notify usbd
  → usbd 读取 Transfer Ring → 解析 HID report
  → IPC 通知 DevMgr: "键盘事件, scancode=X"
  → DevMgr 路由到 TTY 服务 (§12.5)
  → TTY 行编辑 → PTY slave → shell
```

#### 18.1.3 实施计划

| 任务 | 行数估算 | 阶段 |
|---|---|---|
| xHCI 控制器驱动核心 | ~800 | Phase 4 (M12+) |
| USB Core (枚举/URB/Hub) | ~600 | Phase 4 |
| USB HID 子类驱动 | ~200 | Phase 4 |
| USB Mass Storage 子类驱动 | ~300 | Phase 4 |
| **总计** | **~1,900** | |

---

### 18.2 GPU / Framebuffer (E2)

**为什么需要**: 现代系统必须支持图形输出。即使是服务器也需要 framebuffer 用于 console。VGA 文本模式在现代硬件上已过时。

#### 18.2.1 分阶段策略

```
阶段 1: 基础 Framebuffer (M10 并行, ~200 行)
  → 通过 Limine/UEFI GOP 获取 framebuffer 信息
  → 线性帧缓冲: 写像素 = 写内存
  → console 驱动从 VGA 文本模式切换到图形模式
  → 支持基础文字渲染 (内置 bitmap 字体)
  
  初始化:
    1. Limine boot info 提供: framebuffer_addr, width, height, pitch, bpp
    2. 内核映射 framebuffer 到 HHDM (write-combining 属性提高性能)
    3. console 驱动使用此映射直接绘制像素
    4. 字体: 内置 8x16 PC screen font (通过 @embedFile 编译时嵌入)

阶段 2: virtio-gpu 2D 驱动 (Phase 4, ~400 行)
  → PCI 设备, 通过 virtqueue 发送 2D 命令
  → 支持分辨率切换、多显示器
  → 2D 加速: 矩形填充、位图传输 (bitblt)
  → QEMU 中测试

阶段 3: 原生 GPU 驱动 (Phase 5+, 远期)
  → 需要配合窗口系统设计
  → 可选: 简单 compositor (Wayland-like)
  → 极高复杂度, 按需启动
```

#### 18.2.2 基础 Framebuffer Console

```zig
/// Framebuffer console — 替代 VGA 文本模式
pub const FbConsole = struct {
    fb_base: [*]u32,          // 帧缓冲基地址 (已映射)
    width: u32,               // 像素宽度
    height: u32,              // 像素高度
    pitch: u32,               // 每行字节数
    cols: u32,                // 文本列数 (width / 8)
    rows: u32,                // 文本行数 (height / 16)
    cursor_x: u32,
    cursor_y: u32,
    fg_color: u32,            // 前景色 (ARGB)
    bg_color: u32,            // 背景色
    
    font: *const [256][16]u8, // 8x16 bitmap 字体
    
    pub fn drawChar(self: *FbConsole, ch: u8, x: u32, y: u32) void;
    pub fn scrollUp(self: *FbConsole) void;
    pub fn writeStr(self: *FbConsole, s: []const u8) void;
    pub fn setCursor(self: *FbConsole, x: u32, y: u32) void;
};
```

**性能**: framebuffer 写入通过 `movnti` (non-temporal store) 或 `rep movsq` 实现，带宽可达数 GB/s，远超串口。

---

### 18.3 驱动动态加载机制 (E3)

**为什么需要**: 微内核中驱动是用户空间进程，但需要一个机制将硬件设备自动匹配到驱动并启动。

#### 18.3.1 驱动匹配表

```
/system/drivers/pci.ids (TOML 格式):

# virtio 设备
[driver.virtio_blk]
match = "pci:vendor=0x1AF4,device=0x1001"    # virtio block device
binary = "/system/drivers/virtio_blk"
type = "block"

[driver.virtio_net]
match = "pci:vendor=0x1AF4,device=0x1000"    # virtio network device
binary = "/system/drivers/virtio_net"
type = "net"

[driver.virtio_gpu]
match = "pci:vendor=0x1AF4,device=0x1050"    # virtio GPU
binary = "/system/drivers/virtio_gpu"
type = "gpu"

[driver.xhci]
match = "pci:class=0x0C0330"                  # xHCI USB controller
binary = "/system/drivers/xhci"
type = "usb"

[driver.nvme]
match = "pci:class=0x010802"                   # NVMe controller
binary = "/system/drivers/nvme"
type = "block"
```

#### 18.3.2 驱动加载流程

```
系统启动时:
  1. 内核 PCI 扫描 → 构建 PciDevice[] 列表 (M6.0a-d)
  2. 内核通过 IPC 将列表发送给 DevMgr
  3. DevMgr 读取 /system/drivers/pci.ids
  4. 对每个 PciDevice:
     a. 查找匹配的驱动条目
     b. 请求 PM 创建驱动进程:
        PM → 创建进程 (binary=/system/drivers/virtio_blk)
        → 分配 Capability: 
          CAP_MAP_DEVICE(pci_device_X.bar[0])  // MMIO 访问
          CAP_RECEIVE(irq_endpoint_X)           // 中断接收
     c. 驱动进程启动 → 初始化设备
     d. 驱动向 DevMgr 注册:
        "我是 virtio_blk, 提供块设备 /dev/vda"
     e. DevMgr 更新设备表 → 通知 VFS 新设备可用

热插拔:
  内核检测到 PCI/设备变化:
    → notify DevMgr (PCI hotplug event)
    → DevMgr 查找驱动 → 启动驱动进程 (同上)
    → 设备移除 → DevMgr 通知驱动进程 → 驱动进程退出

驱动进程退出:
  → DevMgr 检测到进程退出 (PM 通知)
  → 清理设备表
  → 通知 VFS: "设备 /dev/vda 已移除"
  → 等待重新插入或保持空闲
```

#### 18.3.3 驱动进程接口

```zig
/// 所有驱动进程必须实现的接口 (libdriver/driver_api.zig)
pub const DriverInterface = struct {
    /// 驱动入口 — DevMgr 启动后调用
    pub fn main() void;
    
    /// 初始化设备
    pub fn init(device_info: DeviceInfo) !void;
    
    /// 打开设备 (来自用户进程的 open())
    pub fn open(flags: u32) !DeviceHandle;
    
    /// 关闭设备
    pub fn close(handle: DeviceHandle) void;
    
    /// 读取
    pub fn read(handle: DeviceHandle, buf: []u8, offset: u64) !usize;
    
    /// 写入
    pub fn write(handle: DeviceHandle, data: []const u8, offset: u64) !usize;
    
    /// I/O 控制
    pub fn ioctl(handle: DeviceHandle, cmd: u32, arg: u64) !u64;
    
    /// 中断处理回调 (由中断线程调用)
    pub fn handleInterrupt(irq: u8) void;
    
    /// 设备移除通知
    pub fn deinit() void;
};
```

**DevMgr 通信协议**:
```
驱动进程的 IPC 消息循环:

while (true) {
    const msg = ipc.receive(any_endpoint);
    switch (msg.msg_type) {
        .DEV_INIT     => init(msg.payload.device_info),
        .DEV_OPEN     => open(msg.payload.flags),
        .DEV_READ     => read(...),
        .DEV_WRITE    => write(...),
        .DEV_IOCTL    => ioctl(...),
        .DEV_CLOSE    => close(...),
        .IRQ_NOTIFY   => handleInterrupt(msg.payload.irq),
        .DEV_REMOVE   => { deinit(); return; },
    }
}
```

### 18.4 缺陷修正

| # | 缺陷 | 修正 |
|---|---|---|
| E1 | USB 驱动栈完全缺失 | §18.1: xHCI + USB Core + HID + Mass Storage (~1,900 行, Phase 4) |
| E2 | GPU/Framebuffer 无设计 | §18.2: 三阶段策略 (基础 fb → virtio-gpu → 原生 GPU) |
| E3 | 驱动动态加载机制未说明 | §18.3: PCI ID 匹配表 + DevMgr 自动加载 + 热插拔 + 统一驱动接口 |

---

## 19. 内存与 I/O 基础设施

> 基于完整 Linux 内核架构对比审查，补充物理内存分配器、页面置换、块 I/O 层、网络缓冲管理和 DMA 管理五项核心遗漏。

### 19.1 物理内存分配器 (F1)

**为什么需要**: 内核从 M2 开始就需要分配物理页帧。没有 PMM，所有后续子系统（虚拟内存、进程创建、页缓存）都无法工作。

#### 19.1.1 伙伴系统 (Buddy Allocator)

管理物理页帧 (4KB 为最小单位)，支持 order 0-11 (4KB → 8MB)，O(1) 分配/释放。

```zig
/// 物理内存管理器 — 伙伴系统
pub const Pmm = struct {
    /// 每个order的空闲链表 (bitmaps + stacks)
    free_lists: [MAX_ORDER]FreeList,
    
    /// 物理页帧描述符数组 (one per 4KB page)
    page_frames: []PageFrame,
    
    /// 总物理页数
    total_pages: u64,
    /// 空闲页数
    free_pages: u64,
    
    /// 从 Limine memory map 初始化
    pub fn init(memmap: []const MemmapEntry) Pmm;
    
    /// 分配 2^order 个连续物理页
    pub fn alloc(self: *Pmm, order: u6) !PhysAddr;
    
    /// 释放之前分配的物理页
    pub fn free(self: *Pmm, addr: PhysAddr, order: u6) void;
    
    /// 分配单个物理页 (order-0 便捷方法)
    pub fn allocPage(self: *Pmm) !PhysAddr;
    
    /// 空闲页数量
    pub fn freeCount(self: *Pmm) u64;
};

const MAX_ORDER = 11; // order-0: 4KB, order-10: 4MB

pub const PageFrame = struct {
    flags: packed struct {
        allocated: bool,
        slab_page: bool,
        buddy_order: u4,      // 在伙伴系统中的 order
        reserved: u3,
    },
    ref_count: u16,
    // 可链接到 free_list 或 slab cache
    next: ?*PageFrame,
};
```

**初始化流程**:
```
1. Limine boot info 提供 memory map (可用物理内存区域)
2. 跳过内核映像占用的区域 (Limine 标记)
3. 计算 page_frames 数组大小 = 物理内存大小 / 4KB
4. 将 page_frames 数组放在内核 BSS 段之后 (HHDM 映射)
5. 遍历可用内存区域，按 4KB 对齐后插入伙伴系统
6. DMA 区域 (低 16MB) 特殊标记 (ISA DMA 需要)
```

**分配算法**:
```
alloc(order=3):
  free_lists[3] 非空? → 弹出头部，返回
  free_lists[3] 空? → 从 order=4 找一个
    → 分成两个 order=3 块 (buddy pair)
    → 一个返回给调用者
    → 另一个挂到 free_lists[3]
  递归向上查找直到找到非空 order
```

**合并规则**:
```
free(addr, order):
  计算伙伴地址: buddy = addr XOR (1 << (order + 12))
  buddy 也在 free_lists[order] 中?
    → 是: 从链表移除 buddy，合并为 order+1 块
    → 递归合并直到不能合并
    → 否: 直接挂入 free_lists[order]
```

#### 19.1.2 Slab 分配器

在伙伴系统之上，为内核频繁分配的小对象提供缓存。

```zig
/// Slab 分配器 — 用于内核小对象
pub const Slab = struct {
    caches: [16]?SlabCache,   // 16 个预定义大小类别
    
    pub fn init(backing: *Pmm) Slab;
    
    /// 分配指定大小的对象
    pub fn alloc(self: *Slab, size: usize) !*u8;
    
    /// 释放对象
    pub fn free(self: *Slab, ptr: *u8, size: usize) void;
};

pub const SlabCache = struct {
    obj_size: u16,              // 对象大小
    per_page: u16,              // 每页可放多少对象
    free_list: ?*u8,            // 空闲对象链表 (嵌入在对象内存中)
    allocated_pages: u32,       // 已分配的物理页数
    
    /// 预定义大小: 32, 64, 128, 256, 512, 1024, 2048 字节
};
```

**预定义缓存**:
| 对象 | 大小 | 用途 |
|---|---|---|
| Process 结构 | ~512B | PMM 进程管理 |
| Thread 结构 | ~256B | 调度器线程 |
| IPC Message | 256B | IPC 消息缓冲 |
| Page Cache Entry | ~128B | VFS 页缓存 |
| VMA 描述符 | ~64B | VMM 虚拟内存区域 |
| Capability Slot | ~32B | 能力令牌 |

**文件**:
```
kernel/
├── mm/
│   ├── pmm.zig          # 伙伴系统 (~400 行)
│   ├── slab.zig         # Slab 分配器 (~300 行)
│   └── page_frame.zig   # PageFrame 描述符 (~80 行)
```

---

### 19.2 LRU 页面置换策略 (F2)

**为什么需要**: 当物理内存不足时，需要决定哪些页面应该换出到磁盘。§12.6 OOM 处理是最后手段，在此之前的页面回收才是主要机制。

#### 19.2.1 双链表 LRU

```
页面状态流转:

  新分配的页面
       │
       ▼
  ┌──────────────┐
  │ Active 链表   │ ← 最近被访问的页面
  │ (热点数据)    │
  └──────┬───────┘
         │ 一段时间未被访问
         ▼
  ┌──────────────┐
  │ Inactive 链表 │ ← 回收候选
  │ (冷数据)      │
  └──────┬───────┘
         │ 内存压力时扫描尾部
         ▼
  ┌──────────────┐
  │   回收决策    │
  │ 干净文件页    │ → 直接丢弃
  │ 脏文件页      │ → writeback 后丢弃
  │ 匿名页        │ → 写入 swap 分区
  └──────────────┘
```

#### 19.2.2 水位线与 kswapd

```zig
/// VMM 页面回收参数
pub const Watermark = struct {
    high: u64,    // 空闲页 > high → 不回收
    low: u64,     // 空闲页 < low → 唤醒 kswapd 后台回收
    min: u64,     // 空闲页 < min → 直接同步回收 (阻塞分配者)
};

/// kswapd — VMM 服务中的后台页面回收线程
pub const Kswapd = struct {
    active_list: DoublyLinkedList(Page),
    inactive_list: DoublyLinkedList(Page),
    watermark: Watermark,
    
    /// 后台回收循环
    pub fn run(self: *Kswapd) void {
        while (true) {
            // 等待唤醒 (VMM 检测到空闲 < watermark_low)
            suspend;
            
            // 扫描 inactive 尾部
            while (free_pages < watermark.high) {
                const page = self.inactive_list.popLast();
                self.reclaimPage(page);
            }
        }
    }
    
    fn reclaimPage(self: *Kswapd, page: *Page) void;
};
```

**水位线计算**: `high = total_pages * 5%`, `low = total_pages * 3%`, `min = total_pages * 1%`

**文件**: `servers/vmm/lru.zig` (~300 行) + `servers/vmm/kswapd.zig` (~250 行)

---

### 19.3 块设备 I/O 层 (F3)

**为什么需要**: VFS 到块驱动之间缺少标准化的 I/O 描述和调度层。没有这层，每次文件读取都直接 IPC 到驱动，无法合并、排序或缓存块级数据。

#### 19.3.1 Bio 层 (Block I/O)

```zig
/// 块设备 I/O 请求
pub const BioRequest = struct {
    device: u32,           // 设备 ID (DevMgr 分配)
    sector: u64,           // 起始扇区号
    count: u32,            // 扇区数量
    direction: enum { read, write },
    buffer: []u8,          // 数据缓冲区 (调用者提供)
    callback: BioCallback, // 完成回调
    
    /// 链表: 合并的请求
    next: ?*BioRequest,
};

/// I/O 调度器 (简单电梯算法)
pub const IoScheduler = struct {
    /// 按设备分组的待处理请求
    pending: HashMap(u32, *BioRequestQueue),
    
    /// 提交 I/O 请求
    pub fn submit(self: *IoScheduler, req: *BioRequest) void {
        // 尝试与现有请求合并 (相邻扇区)
        if (self.tryMerge(req)) return;
        // 否则加入队列
        self.enqueue(req);
        // 队列达到阈值 → flush 到驱动
        if (self.queueLen(req.device) >= 8) {
            self.flush(req.device);
        }
    }
    
    /// 合并条件: 相邻扇区 + 同方向 + 总长度 ≤ 256KB
    fn tryMerge(self: *IoScheduler, req: *BioRequest) bool;
};
```

#### 19.3.2 Buffer Cache (块级缓存)

```zig
/// 块级缓冲缓存 (缓存磁盘块)
pub const BufferCache = struct {
    /// 哈希表: (device, block_number) → BufferHead
    entries: HashMap(BufferKey, *BufferHead),
    
    /// LRU 链表: 最近使用的缓冲
    lru: DoublyLinkedList(BufferHead),
    
    /// 脏缓冲链表: 需要写回的缓冲
    dirty: DoublyLinkedList(BufferHead),
    
    pub fn getBlock(self: *BufferCache, device: u32, block: u64) !*BufferHead;
    pub fn markDirty(self: *BufferCache, bh: *BufferHead) void;
    pub fn sync(self: *BufferCache) void; // flush all dirty buffers
};

pub const BufferHead = struct {
    device: u32,
    block_num: u64,
    data: [4096]u8,         // 4KB 块数据
    dirty: bool,
    ref_count: u16,
};
```

**用途**: 
- 文件系统 superblock、inode 表、目录项 — 这些不适合用页缓存 (不是页对齐的)
- 文件 I/O 走页缓存；元数据 I/O 走 buffer cache

**文件**: `servers/vfs/bio.zig` (~250 行) + `servers/vfs/buffer_cache.zig` (~200 行) + `servers/vfs/io_sched.zig` (~150 行)

---

### 19.4 网络包缓冲管理 (F5)

**为什么需要**: NetStack 在各协议层之间传递数据包时，需要高效的缓冲管理。不能每层都复制数据。

#### 19.4.1 NetBuf (pbuf 风格)

```zig
/// 网络包缓冲区 — 链式零拷贝设计 (参考 lwIP pbuf / FreeBSD mbuf)
pub const NetBuf = struct {
    next: ?*NetBuf,           // 链式 (大包分片)
    payload: [*]u8,           // 数据指针
    len: u16,                 // 本段长度
    total_len: u32,           // 整条链总长度
    ref_count: u8,            // 引用计数 (多协议层共享)
    
    // 协议层 header 解析结果 (零拷贝指针)
    eth_hdr: ?*EthernetHeader,
    ip_hdr: ?*Ipv4Header,
    transport_hdr: ?*TransportHeader,
    
    // 管理
    pool: *NetBufPool,        // 所属池
    pool_index: u32,          // 池内索引 (快速释放)
};

/// 固定大小 NetBuf 池 (避免运行时内存分配)
pub const NetBufPool = struct {
    bufs: []NetBuf,                    // NetBuf 元数据数组
    storage: []u8,                     // 连续 payload 存储
    buf_size: u16,                     // 每个 payload 大小 (2048)
    free_stack: []u32,                 // 空闲索引栈
    free_top: u32,                     // 栈顶
    
    pub fn init(buf_count: u32, buf_size: u16) !NetBufPool;
    pub fn alloc(self: *NetBufPool) ?*NetBuf;
    pub fn free(self: *NetBufPool, buf: *NetBuf) void;
    
    /// 引用计数操作
    pub fn ref(buf: *NetBuf) void { buf.ref_count += 1; }
    pub fn unref(buf: *NetBuf) void {
        buf.ref_count -= 1;
        if (buf.ref_count == 0) buf.pool.free(buf);
    }
};
```

**零拷贝协议处理**:
```
网卡收到包:
  NetBufPool.alloc() → NetBuf
  驱动 DMA 写入 payload
  → 解析 EthernetHeader → eth_hdr 指向 payload[0..14]
  → 解析 Ipv4Header → ip_hdr 指向 payload[14..34]
  → 解析 TcpHeader → transport_hdr 指向 payload[34..54]
  → 数据从驱动 → IP层 → TCP层 → Socket，全程零拷贝

发送包:
  TCP 构造 header → 分配 NetBuf → 填充 payload
  → IP 层补充 IP header (同一 NetBuf 内前移指针)
  → 驱动 从 payload 读取完整帧 → DMA 发送
```

**池配置**: 1024 个 × 2048 字节 = 2MB (启动时 VMM 分配)

**文件**: `servers/netstack/netbuf.zig` (~250 行)

---

### 19.5 DMA 缓冲区管理 (F6)

**为什么需要**: 用户空间驱动做 DMA 时，需要物理连续内存，且需要知道设备可访问的物理地址。内核必须提供 DMA 缓冲区分配服务。

#### 19.5.1 内核 DMA API

```zig
/// DMA 缓冲区管理 (内核服务)
pub const DmaManager = struct {
    pmm: *Pmm,                   // 底层物理页分配
    
    /// 分配 Coherent DMA 缓冲区 (长期映射)
    /// 返回: 内核虚拟地址 + 设备物理地址
    pub fn allocCoherent(
        self: *DmaManager,
        size: usize,
        attrs: DmaAttrs
    ) !DmaMapping {
        const order = log2ceil(size / 4096);
        const phys = try self.pmm.alloc(order);
        const virt = self.hhdm_offset + phys;
        return DmaMapping{
            .virt_addr = virt,
            .phys_addr = phys,
            .device_addr = phys,    // QEMU: 无 IOMMU, 设备地址 = 物理地址
            .size = @as(usize, 1) << (order + 12),
            .mapping_type = .coherent,
        };
    }
    
    /// 流式 DMA 映射 (临时, 单次 I/O)
    pub fn mapSingle(
        self: *DmaManager,
        virt_addr: usize,
        size: usize,
        direction: DmaDirection
    ) !DmaDeviceAddr;
    
    /// 流式 DMA 解除映射
    pub fn unmapSingle(
        self: *DmaManager,
        device_addr: DmaDeviceAddr
    ) void;
    
    /// 释放 Coherent DMA 缓冲区
    pub fn freeCoherent(self: *DmaManager, mapping: DmaMapping) void;
};

pub const DmaMapping = struct {
    virt_addr: usize,          // CPU 访问地址
    phys_addr: PhysAddr,       // 物理地址
    device_addr: u64,          // 设备可访问地址 (IOMMU 映射后)
    size: usize,
    mapping_type: enum { coherent, streaming },
};

pub const DmaAttrs = packed struct {
    non_coherent: bool,        // 不保证缓存一致性
    uncacheable: bool,         // 禁用缓存 (write-combining)
    low_mem: bool,             // 必须在低 16MB (ISA DMA)
};
```

#### 19.5.2 驱动使用 DMA 的流程

```
驱动初始化时 (Coherent DMA):
  1. 驱动通过 Capability 请求内核 DMA 服务
  2. dma_alloc_coherent(4096 * 2, DMA_ATTR_UNCACHEABLE)
     → 内核分配 2 页物理连续内存
     → 返回: { virt=0xFFFF...0000, phys=0x2000000, device=0x2000000 }
  3. 驱动写入 virt_addr 构造描述符环
  4. 驱动将 device_addr 写入设备寄存器
  5. 设备通过 DMA 读写该内存区域

每次 I/O (Streaming DMA):
  1. 驱动有数据在用户空间缓冲区
  2. dma_map_single(buffer, len, DMA_TO_DEVICE)
     → 内核确保数据刷出 CPU 缓存
     → 返回设备地址
  3. 驱动将设备地址写入设备 scatter/gather 表
  4. 设备完成 DMA
  5. dma_unmap_single(device_addr)
     → 内核确保 CPU 缓存失效 (DMA_FROM_DEVICE 时)
     → CPU 可以读取设备写入的数据
```

#### 19.5.3 IOMMU 预留

```
QEMU 阶段: 无 IOMMU, device_addr = phys_addr (直接映射)
真机阶段: 需要启用 IOMMU (Intel VT-d / ARM SMMU)
  → iommu_map(device_id, device_addr, phys_addr)
  → 设备只能访问被明确映射的物理地址
  → 防止恶意/有缺陷的设备越界访问

IOMMU 初始化:
  1. ACPI 表: DMAR (Intel) 或 IORT (ARM)
  2. 解析 IOMMU 能力 → 启用
  3. 为每个设备创建地址空间 (设备页表)
  4. dma_alloc 时: phys → iommu_map → device_addr
  
Phase 5+ 实现，当前仅预留接口。
```

**文件**:
```
kernel/
├── mm/
│   ├── dma.zig          # DMA 缓冲区管理 (~300 行)
│   └── iommu.zig        # IOMMU 管理 (~200 行, Phase 5+)
```

### 19.6 命名空间预留 (F4)

**为什么预留**: Linux 支持 PID/IPC/Network/Mount 命名空间用于容器隔离。MVP 阶段所有进程共享全局命名空间，但数据结构中预留命名空间字段。

```zig
/// 命名空间预留接口 — Phase 5+ 实现
pub const Namespace = struct {
    id: u32,                  // 命名空间 ID
    
    /// PID 命名空间: 进程 PID 在命名空间内独立编号
    pub const PidNs = struct {
        parent: ?*PidNs,
        next_pid: u32,
        // Phase 5+: 实现 PID 映射
    };
    
    /// IPC 命名空间: System V IPC 和 POSIX MQ 隔离
    pub const IpcNs = struct {
        shm_ids: ShmIdTable,
        msg_queues: MsgQueueTable,
        // Phase 5+: 实现 IPC 隔离
    };
    
    /// 网络命名空间: 独立网络栈
    pub const NetNs = struct {
        loopback: NetDevice,
        interfaces: NetDeviceList,
        // Phase 5+: 每个命名空间独立的协议栈
    };
};
```

**进程结构预留**:
```zig
pub const Process = struct {
    personality: Personality,
    pid_ns: ?*Namespace.PidNs,    // Phase 5+: 默认 null (全局)
    ipc_ns: ?*Namespace.IpcNs,    // Phase 5+: 默认 null (全局)
    net_ns: ?*Namespace.NetNs,    // Phase 5+: 默认 null (全局)
    // ...
};
```

### 19.7 缺陷修正

| # | 缺陷 | 修正 |
|---|---|---|
| F1 | 物理内存分配器 (Buddy + Slab) 无详细设计 | §19.1: 伙伴系统 (order 0-11) + Slab 分配器 (6 种预定义大小) |
| F2 | LRU 页面置换策略未设计 | §19.2: 双链表 LRU + 水位线 + kswapd 后台回收 |
| F3 | 块设备缓冲层 (Buffer Cache / Bio) 未设计 | §19.3: Bio 层 + Buffer Cache + 电梯调度器 |
| F4 | PID/IPC/网络命名空间未考虑 | §19.6: 预留接口 (Phase 5+) |
| F5 | 网络包缓冲管理未设计 | §19.4: NetBuf 链式零拷贝 + 固定大小池 |
| F6 | DMA 缓冲区管理未设计 | §19.5: 内核 DMA API + Coherent/Streaming 两种模式 + IOMMU 预留 |

---

## 20. 电源管理 — STR/STD 可配置方案

> 基于 ACPI 电源状态设计完整的挂起/恢复机制。采用 STR (Suspend to RAM, S3) 和 STD (Suspend to Disk, S4) 可配置、自适应策略，性能优先。

### 20.1 设计目标与约束

**目标**:
- 支持 ACPI S1/S3/S4/S5 四种睡眠状态
- 可配置策略: 用户/管理员决定何时用哪种模式
- 自适应: 根据空闲时间、电量自动选择最优状态
- **性能优先**: STR 唤醒 ~1-2s，STD 唤醒 ~5-10s

**约束**:
- 微内核特有挑战: 驱动在用户空间，每个驱动需要参与 suspend/resume
- 内核负责 CPU 状态保存/恢复 + ACPI 寄存器操作
- 用户空间服务负责冻结自身状态 + 通知驱动

**ACPI 电源状态对比**:

| 状态 | 功耗 | 唤醒时间 | 数据安全 | 实现复杂度 |
|---|---|---|---|---|
| S0 | 正常 | — | — | — |
| S1 (Power On Suspend) | ~50W | ~100ms | CPU 停止，内存刷新 | 低 |
| S3 (STR) | ~5W | ~1-2s | 只有内存供电 | 中 |
| S4 (STD) | ~0W | ~5-10s | 全部写入磁盘 | 高 |
| S5 (Soft Off) | ~0W | 完整启动 | 全部丢失 | 已实现 (§17.3) |

### 20.2 整体架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                          用户空间                                    │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────┐      │
│  │         PowerMgr (电源管理服务)                            │      │
│  │                                                           │      │
│  │  ┌─────────────┐  ┌──────────────┐  ┌────────────────┐   │      │
│  │  │ 策略引擎    │  │ 状态机       │  │ 通知协调器     │   │      │
│  │  │ (Policy)    │  │ (SM)         │  │ (Coordinator)  │   │      │
│  │  └──────┬──────┘  └──────┬───────┘  └───────┬────────┘   │      │
│  │         │                │                   │             │      │
│  │  idle timer + battery    │          通知所有服务和驱动     │      │
│  │  → 选择 S1/S3/S4        │          freeze/thaw            │      │
│  └─────────┼────────────────┼───────────────────┼─────────────┘      │
│            │                │                   │                     │
│  ┌─────────┴────────┐       │          ┌────────┴──────────┐         │
│  │ 各服务: PM/VFS/   │       │          │ 各驱动: 块/网/    │         │
│  │ VMM/NetStack/... │       │          │ USB/GPU/input     │         │
│  │ 自身状态保存     │       │          │ 设备suspend/resume │         │
│  └──────────────────┘       │          └───────────────────┘         │
│                             │                                        │
├─────────────────────────────┼────────────────────────────────────────┤
│                         内核空间                                      │
│                                                                     │
│  ┌────────────────────────┐  ┌───────────────────────────────────┐  │
│  │ ACPI 电源管理          │  │ CPU 状态保存/恢复                  │  │
│  │ • FADT: PM1a/b_CNT    │  │ • CR0/CR3/CR4/EFER               │  │
│  │ • SLP_TYP/SLP_EN      │  │ • IDT/GDT/TSS                    │  │
│  │ • Wake Vector (S4)     │  │ • LAPIC 状态                      │  │
│  │ • PM Timer             │  │ • MSR 快照                        │  │
│  └────────────────────────┘  │ • NMIs 设置                       │  │
│                              └───────────────────────────────────┘  │
│  ┌────────────────────────┐  ┌───────────────────────────────────┐  │
│  │ 中断路由 (唤醒源)      │  │ STD 映像写入器                    │  │
│  │ • 电源按钮 (PWRBTN)    │  │ • 物理内存快照 → swap分区         │  │
│  │ • RTC 闹钟             │  │ • 内核数据结构 → swap分区         │  │
│  │ • USB 唤醒             │  │ • 恢复引导头 (restore header)     │  │
│  │ • 网卡 WOL             │  └───────────────────────────────────┘  │
│  └────────────────────────┘                                         │
└─────────────────────────────────────────────────────────────────────┘
```

### 20.3 STR (Suspend to RAM, S3) 详细流程

S3 是最常用的挂起模式。内存持续供电，CPU 和大部分硬件掉电。唤醒后从 BIOS POST 跳转到内核恢复入口。

#### 20.3.1 挂起流程 (Suspend)

```
阶段 1: 用户/策略触发
  用户: 合盖 / 执行 suspend 命令
  策略: PowerMgr 空闲超时 → 决定进入 S3

阶段 2: 服务冻结 (用户空间, 由 PowerMgr 协调)
  PowerMgr 广播 PM_SUSPEND_PREPARE:
    → 各服务收到通知 → 保存自身状态:
      • VFS: 刷出所有脏页 (sync), 冻结页缓存操作
      • NetStack: 关闭所有 UDP/TCP 连接? NO → 保持状态, 网卡进入 WOL 模式
      • TTY: 保存终端状态
      • VMM: 刷新 VMA 缓存
    → 各驱动收到通知 → 设备进入低功耗:
      • virtio_blk: 完成所有 pending I/O → 禁用设备中断
      • virtio_net: 完成所有 pending 包 → 启用 WOL
      • xHCI: 挂起所有 USB 设备 → 启用远程唤醒
      • GPU: 保存 framebuffer 内容 → 进入 D3 状态
      • keyboard: 保存状态 → 作为唤醒源注册
    → 所有服务/驱动回复 ACK (准备就绪)

阶段 3: 内核冻结 (内核空间)
  1. 停止所有用户空间进程 (冻结调度器)
  2. 禁用所有非唤醒源中断:
     → APIC mask: 只保留 PWRBTN, RTC, 配置的唤醒中断
  3. 保存 CPU 状态 (每个 CPU):
     CR3 (页表基址) → suspend_cpu_state.cr3
     CR4 (扩展控制) → suspend_cpu_state.cr4
     EFER (长模式)  → suspend_cpu_state.efer
     IDTR            → suspend_cpu_state.idtr
     GDTR            → suspend_cpu_state.gdtr
     LAPIC 状态      → suspend_cpu_state.apic
     关键 MSRs       → suspend_cpu_state.msrs[]
  4. 保存中断控制器状态:
     IOAPIC 路由表 → suspend_ioapic_routing
     LAPIC 状态    → suspend_lapic_state (per CPU)
  5. 停止其他 CPU (发送 HALT IPI, 等待 ACK)
  6. BSP (引导 CPU) 保存自身状态

阶段 4: ACPI 进入 S3
  1. 从 FADT 获取 PM1a_CNT / PM1b_CNT 地址
  2. 从 DSDT 的 _S3 方法获取 SLP_TYP 值
  3. 写入 SLP_TYP 到 PM1a_CNT + PM1b_CNT
  4. 写 SLP_EN 位 → CPU 停止 → 系统进入 S3
  
  此时: 只有内存供电, 所有 CPU 停止
```

#### 20.3.2 恢复流程 (Resume)

```
阶段 1: 唤醒事件
  电源按钮 / 合盖打开 / RTC 闹钟 / USB 唤醒 / 网卡 WOL
  → 硬件产生唤醒信号 → CPU 从 ACPI 恢复向量开始执行
  
  ⚠️ BIOS 执行 POST (但跳过内存检测 — 内存还在)
  → BIOS 跳转到内核的 resume 入口点

阶段 2: 内核恢复 (内核空间, 早期 — 类似启动但跳过内存初始化)
  resume_entry (汇编):
    1. 设置临时栈
    2. 恢复 CR3 (页表) → 启用分页
    3. 恢复 IDT, GDT, TSS
    4. 恢复 EFER (长模式)
    5. 恢复 LAPIC 状态
    6. 唤醒其他 CPU (发送 INIT/SIPI, AP 从 restore 入口开始)
    7. 跳转到 Zig resume_main()

阶段 3: 设备恢复
  内核恢复中断控制器 → 重新启用中断路由
  → 通知 PowerMgr: PM_RESUME
  → PowerMgr 广播 PM_RESUME_POST:
    → 驱动恢复设备:
      • virtio_blk: 重新初始化 virtqueue → 恢复 I/O
      • virtio_net: 重新初始化 → 恢复网络
      • xHCI: 重新初始化 → 恢复 USB
      • GPU: 恢复 framebuffer
    → 服务恢复:
      • VFS: 恢复页缓存 → 允许 I/O
      • NetStack: 恢复 TCP 连接 (重传超时的包)
      • TTY: 恢复终端

阶段 4: 正常运行
  调度器解冻 → 用户进程恢复执行
  → 应用程序看到的是: 系统时间跳了一下, 网络可能断过重连
```

#### 20.3.3 内核 Suspend/Resume 数据结构

```zig
/// 每个CPU的挂起状态 — 保存到固定物理地址 (BSS 段)
pub const SuspendCpuState = extern struct {
    magic: u32 = 0x53554E50,             // "SUNP" — 校验 magic
    cr0: u64,
    cr3: u64,                             // 页表基址
    cr4: u64,
    efer: u64,                            // IA32_EFER
    idtr: Idtr,                           // IDT base + limit
    gdtr: Gdtr,                           // GDT base + limit
    tr_selector: u16,                     // TSS selector
    rsp: u64,                             // 内核栈指针
    rbx: u64, rcx: u64, rdx: u64,        // 通用寄存器
    rsi: u64, rdi: u64, rbp: u64, r8: u64,
    r9: u64, r10: u64, r11: u64, r12: u64,
    r13: u64, r14: u64, r15: u64,
    apic_base: u64,                       // LAPIC MSR
    msrs: [16]MsrEntry,                   // 关键 MSR 快照
};

pub const MsrEntry = extern struct {
    index: u32,
    value: u64,
};

/// 全局挂起控制块
pub const SuspendControl = struct {
    target_state: AcpiSleepState,        // S1/S3/S4
    resume_vector: u64,                  // 内核恢复入口物理地址
    cpu_states: []*SuspendCpuState,      // per-CPU 状态
    ioapic_saved: []IoApicEntry,         // IOAPIC 路由表备份
    wakeup_devices: []WakeDevice,        // 唤醒源列表
    
    /// S3 的 magic 位置 — 固定物理地址, resume 后 BIOS 跳到这里
    const RESUME_MAGIC_ADDR = 0x1000;    // 低内存固定位置
    const RESUME_MAGIC = 0x52555345;     // "RUSE"
};

pub const AcpiSleepState = enum(u8) {
    s1 = 1,
    s3 = 3,
    s4 = 4,
    s5 = 5,
};
```

### 20.4 STD (Suspend to Disk, S4) 详细流程

S4 将全部物理内存内容写入 swap 分区，然后完全断电。唤醒时等同于一次特殊启动——从 swap 恢复内存。

#### 20.4.1 挂起流程 (Hibernate)

```
阶段 1-2: 同 S3 (服务冻结 + 驱动 suspend)
  PowerMgr 广播 PM_SUSPEND_PREPARE
  → 所有服务和驱动保存状态 (同 S3)

阶段 3: 内存快照写入 (内核空间)
  1. 计算需要保存的内存区域:
     • 内核映像 (text + rodata + data + BSS) — 必须保存
     • 内核堆 (slab 分配的所有对象) — 必须保存
     • 页表 (所有进程的页表) — 必须保存
     • 用户空间页 (所有已映射的物理页) — 必须保存
     • 空闲页 — 不保存 (恢复时从 PMM 重新分配)
     • 设备 MMIO — 不保存 (恢复时重新映射)
  
  2. 构建保存映射 (save_map):
     ┌────────────────────────────────────────────┐
     │ SaveMap: 需要保存的物理页列表              │
     │                                            │
     │ Entry { phys_addr: u64, size: u32,         │
     │         type: PageType, checksum: u32 }     │
     │                                            │
     │ PageType: kernel | page_table | user_data  │
     │          | slab | vmm_meta | ...           │
     └────────────────────────────────────────────┘
  
  3. 写入 swap 分区:
     写入顺序:
     a. Restore Header (恢复头):
        • magic: 0x534C4550 ("SLEP")
        • version: 1
        • kernel_entry: 内核恢复入口虚拟地址
        • save_map_offset: save_map 在 swap 中的位置
        • total_pages: 需要恢复的页数
        • checksum: CRC32
        • acpi_wake_vector: FACS.wake_vector (BIOS 跳转地址)
     
     b. Save Map (保存映射表)
     
     c. 逐页写入物理内存:
        对 save_map 中每个条目:
          → 读物理页 (通过 HHDM)
          → 计算 checksum
          → 写入 swap 分区 (LBA 顺序写入, 性能最优)
     
     4. 写入完成 → sync (确保数据落盘)

阶段 4: ACPI 进入 S4 (或 S5 — 取决于硬件)
  如果硬件支持 S4:
    → 写 SLP_TYP=S4 → SLP_EN → 系统完全断电
  如果硬件不支持 S4:
    → 直接进入 S5 (关机), 恢复时正常启动但检测到 swap 中有有效快照
```

#### 20.4.2 恢复流程 (Hibernate Restore)

```
阶段 1: 启动 (类似冷启动)
  按电源键 → BIOS POST
  → Limine bootloader 启动
  → 加载内核映像到内存
  → 内核初始化 (PMM, HHDM, ACPI)
  
  ⚠️ 关键区别: 内核初始化过程中检查 swap 分区是否包含有效快照

阶段 2: 检测恢复快照
  内核启动时:
    1. 初始化块设备驱动 (最小化 — 只需能读 swap)
    2. 读取 swap 分区头部:
       → 检查 magic == 0x534C4550?
       → 检查 checksum?
       → 有效 → 进入 hibernate restore 路径
       → 无效 → 正常启动 (冷启动)
    
    3. 如果 Limine 支持: 传递内核参数 hibernate=resume
       → 内核直接进入恢复模式

阶段 3: 内存恢复
  1. 从 swap 读取 Save Map
  2. 分配临时页表 (恢复过程中需要映射)
  3. 逐页从 swap 读取 → 写入原始物理地址:
     for entry in save_map:
       → 从 swap 读取一页数据
       → 验证 checksum
       → 通过 HHDM 写入物理地址
     ⚠️ 不能覆盖当前正在执行的内核代码 → 先复制到安全区域
  
  4. 所有页恢复完成 → 切换到恢复后的页表 (CR3)
  5. 跳转到恢复后的内核 resume 入口

阶段 4: 内核 + 设备恢复 (同 S3 resume)
  → 恢复 CPU 状态
  → 恢复中断控制器
  → 通知 PowerMgr: PM_RESUME
  → 驱动和服务恢复
  → 解冻调度器

阶段 5: 清理
  → 标记 swap 快照为无效 (防止重复恢复)
  → 恢复 swap 分区正常使用
```

#### 20.4.3 STD 性能优化

| 优化 | 效果 | 实现 |
|---|---|---|
| **LBA 顺序写入** | 写入速度提升 3-5x | 按 swap 分区 LBA 顺序排列保存页, 而非按物理地址 |
| **LZO 压缩** | 写入量减少 40-60% | 每页用 LZO 快速压缩后再写入, 解压 ~500MB/s |
| **跳过零页** | 减少无效 I/O | 全零页只记录 "零页" 标记, 恢复时直接清零 |
| **空闲页跳过** | 减少保存量 | PMM 空闲页不保存, 恢复后重新从 PMM 分配 |
| **预分配 swap 空间** | 避免运行时分配 | 启动时在 swap 末尾预留 hibernate 区域 (等于 RAM 大小) |
| **多线程压缩/写入** | 并行加速 | 多核并行压缩 + 提交 I/O (适合 NVMe) |

### 20.5 自适应电源策略

#### 20.5.1 策略引擎

```zig
/// 电源策略配置 (/system/power.conf — TOML 格式)
///
/// [policy]
/// mode = "auto"              # auto | performance | battery | custom
/// idle_threshold_s1 = 60     # 空闲 60s → S1
/// idle_threshold_s3 = 600    # 空闲 10min → S3
/// idle_threshold_s4 = 0      # 禁用自动 S4 (0 = 禁用)
/// battery_critical_s4 = 10   # 电量 < 10% → 自动 S4
/// battery_low_s3 = 20        # 电量 < 20% → 空闲即 S3
/// lid_close = "s3"           # 合盖动作: s1 | s3 | s4 | nothing
/// power_button = "s3"        # 电源按钮: s1 | s3 | s4 | shutdown
///
/// [wake_sources]
/// power_button = true
/// lid_open = true
/// rtc_alarm = false
/// usb_keyboard = true
/// network_wol = false

pub const PowerPolicy = struct {
    mode: PolicyMode,
    idle_s1_sec: u32,          // 空闲 → S1 的秒数
    idle_s3_sec: u32,          // 空闲 → S3 的秒数
    idle_s4_sec: u32,          // 空闲 → S4 的秒数 (0=禁用)
    battery_critical: u8,      // 临界电量 (%)
    battery_low: u8,           // 低电量 (%)
    lid_action: SleepAction,
    power_button_action: SleepAction,
};

pub const PolicyMode = enum {
    auto,          // 根据空闲+电量自动决策
    performance,   // 永不自动挂起, 保持 S0
    battery,       // 激进省电: 快速进 S3/S4
    custom,        // 用户完全自定义
};

pub const SleepAction = enum {
    nothing,
    s1,
    s3,
    s4,
    shutdown,
};
```

#### 20.5.2 决策状态机

```
                    ┌─────────┐
                    │   S0     │ ← 正常运行
                    │ (Active) │
                    └────┬────┘
                         │ 空闲计时器启动
                         ▼
                    ┌─────────┐
                ┌──→│  Idle   │ ← 检查策略
                │   │ Monitor │
                │   └────┬────┘
                │        │
                │   idle ≥ idle_s1_sec?
                │        ├─ YES ──→ ┌─────────┐
                │        │          │   S1     │ ← CPU halt, 内存刷新
                │        │          │ (Light)  │    唤醒: ~100ms
                │        │          └────┬────┘
                │        │               │ 唤醒 → S0
                │        │
                │   idle ≥ idle_s3_sec?  (或 lid_close, power_button)
                │        ├─ YES ──→ ┌─────────┐
                │        │          │   S3     │ ← STR: 内存供电
                │        │          │ (STR)   │    唤醒: ~1-2s
                │        │          └────┬────┘
                │        │               │ 唤醒 → S0
                │        │
                │   idle ≥ idle_s4_sec?  (或 battery_critical)
                │        ├─ YES ──→ ┌─────────┐
                │        │          │   S4     │ ← STD: 写磁盘后断电
                │        │          │ (STD)   │    唤醒: ~5-10s
                │        │          └────┬────┘
                │        │               │ 唤醒 (冷启动+恢复) → S0
                │        │
                │   用户活动 / 网络请求 / 唤醒事件
                └────────┘ ← 重置空闲计时器

特殊路径:
  battery < battery_critical → 直接 S4 (跳过 S1/S3)
  battery < battery_low → 跳过 S1, 直接进 S3
  配置 idle_s4_sec=0 → 禁止自动 S4 (只能手动触发)
```

#### 20.5.3 性能优先策略详解

**"性能最优" 意味着在满足省电需求的前提下，最小化唤醒延迟**：

| 场景 | 最优策略 | 原因 |
|---|---|---|
| 短暂离开 (< 5 min) | S1 | 唤醒最快 (~100ms)，内存保持，应用无感知 |
| 午休/会议 (< 2h) | S3 (STR) | 唤醒 1-2s，应用可能需要重连网络 |
| 下班/过夜 (> 8h) | S4 (STD) | 零功耗，数据安全（磁盘上），唤醒 5-10s |
| 电池低 (< 10%) | S4 | 防止电池耗尽丢失数据 |
| 服务器 (无人值守) | S1 或禁用 | 服务器通常不休眠，用 CPU C-state 代替 |
| 桌面 (常供电) | S3 | 不需要省电到极致，S3 唤醒快 |
| 笔记本 (电池) | 自适应 S3→S4 | 电池充足用 S3，低电量自动切 S4 |

**CPU C-State 优化 (S0 内部)**:

即使在 S0 状态，也可以利用 CPU C-state 降低功耗（不需要完整的系统挂起）:

```
C0: 正常执行
C1: HLT (停止执行核心, 唤醒: ~10ns)     ← 内核 idle 时自动使用
C2: Stop Clock (停止时钟, 唤醒: ~100ns)  ← 需要 BIOS/ACPI 支持
C6: 深度省电 (降低电压, 唤醒: ~1us)      ← 笔记本 idle 时使用

内核调度器 idle 线程:
  当没有可运行任务时 → 执行 mwait/hlt
  → 中断到达 → 立即唤醒 → 继续调度

这与 STR/STD 互补:
  C-state: S0 内部的微睡眠 (透明, 应用无感知)
  S1/S3/S4: 系统级睡眠 (需要协调所有驱动和服务)
```

### 20.6 微内核特有: 驱动与服务协调协议

宏内核只需要一个 centralized suspend，微内核需要分布式协调。

#### 20.6.1 电源管理 IPC 消息

```zig
/// 电源管理 IPC 消息类型
pub const PmMessage = enum(u32) {
    /// 通知: 即将进入挂起, 请保存状态
    SUSPEND_PREPARE = 0x5001,
    /// 通知: 已完成挂起准备, 可以睡眠
    SUSPEND_READY = 0x5002,
    /// 通知: 挂起被取消 (某驱动拒绝)
    SUSPEND_CANCEL = 0x5003,
    /// 通知: 从睡眠中恢复
    RESUME_START = 0x5004,
    /// 通知: 恢复完成
    RESUME_COMPLETE = 0x5005,
    /// 查询: 驱动是否支持此睡眠状态?
    QUERY_CAPABILITY = 0x5006,
};

/// 驱动/服务必须实现的电源接口
pub const PmCap = packed struct {
    s1: bool,    // 支持 S1
    s3: bool,    // 支持 S3
    s4: bool,    // 支持 S4
    wakeup: bool, // 可作为唤醒源
};

/// 驱动注册时声明电源能力
pub const PmRegistration = extern struct {
    service_name: [32]u8,
    capabilities: PmCap,
    suspend_latency_us: u32,   // 挂起延迟上限
    resume_latency_us: u32,    // 恢复延迟上限
};
```

#### 20.6.2 挂起协调流程

```
PowerMgr 协调挂起 (分布式两阶段提交):

阶段 1: PREPARE (广播)
  PowerMgr → IPC broadcast SUSPEND_PREPARE(target_state=S3):
    → VFS: 刷出脏页, 冻结 I/O → 回复 SUSPEND_READY
    → NetStack: 网卡启用 WOL, 冻结发送队列 → 回复 SUSPEND_READY
    → virtio_blk 驱动: 完成所有 pending I/O → 回复 SUSPEND_READY
    → xHCI 驱动: 挂起 USB 设备 → 回复 SUSPEND_READY
    → keyboard 驱动: 注册为唤醒源 → 回复 SUSPEND_READY
    → ...

  如果任何一个回复 SUSPEND_CANCEL:
    → PowerMgr 中止挂起
    → 广播 RESUME_START (已准备的服务需要恢复)
    → 返回 S0

  如果全部回复 SUSPEND_READY (或超时):
    → PowerMgr 通知内核: 执行挂起

阶段 2: EXECUTE (内核)
  内核执行 §20.3.1 的阶段 3-4:
    → 冻结调度器
    → 保存 CPU 状态
    → 写 ACPI 寄存器 → 进入 S3

阶段 3: RESUME (内核 → PowerMgr → 服务/驱动)
  唤醒事件 → 内核恢复 CPU → 恢复中断
  → 通知 PowerMgr: RESUME_START
  → PowerMgr 广播 RESUME_START:
    → 驱动恢复设备
    → 服务恢复状态
  → 全部完成 → PowerMgr 报告 RESUME_COMPLETE → S0
```

**超时处理**:
```
驱动/服务必须在 suspend_latency_us 内回复 SUSPEND_READY
超时 → PowerMgr 记录警告 → 强制进入挂起 (或取消, 取决于配置)

默认超时:
  服务: 5 秒
  驱动: 2 秒
  总超时: 10 秒 (所有 ACK 收集完毕)
```

### 20.7 唤醒源配置

```zig
/// 唤醒源类型
pub const WakeSource = enum {
    power_button,      // 电源按钮 (ACPI PWRBTN)
    lid_open,          // 笔记本开盖 (ACPI LID)
    rtc_alarm,         // RTC 闹钟 (定时唤醒)
    usb_keyboard,      // USB 键盘按键
    usb_mouse,         // USB 鼠标移动
    network_wol,       // 网卡 Wake-on-LAN (Magic Packet)
    pci_pme,           // PCI Power Management Event
    custom_gpio,       // GPIO 中断 (嵌入式场景)
};

/// 唤醒源注册 (驱动通过 IPC 向内核注册)
pub const WakeRegistration = struct {
    source: WakeSource,
    irq: u8,                    // 关联的中断号
    enabled: bool,
    driver_endpoint: EndpointId, // 注册的驱动端点
};
```

**内核在挂起时只使能已注册的唤醒中断**，其他中断全部 mask。唤醒时硬件触发中断 → 内核恢复 → 通知对应驱动。

### 20.8 S1 (Light Sleep) 简化实现

S1 是最简单的挂起模式——CPU 执行 HLT，内存和所有设备保持供电。

```
S1 进入:
  1. PowerMgr 通知驱动: SUSPEND_PREPARE(S1)
  2. 驱动可以选择降低设备功耗 (网卡降低速率, 磁盘停转)
  3. 调度器 idle → 所有 CPU 执行 mwait/hlt
  4. 不需要保存 CPU 状态 (内存还在)
  5. 不需要写 ACPI 寄存器 (直接 HLT 就行)

S1 唤醒:
  任何中断 → CPU 退出 HLT → 调度器恢复运行
  → PowerMgr 广播 RESUME_START → 驱动恢复设备全速
```

**优势**: 几乎零延迟，不需要复杂的协调。适合短暂空闲。

### 20.9 内核新增文件

```
kernel/
├── pm/                           # [新增] 电源管理
│   ├── suspend.zig               # 挂起/恢复核心 (~400 行)
│   ├── acpi_sleep.zig            # ACPI S1/S3/S4/S5 寄存器操作 (~200 行)
│   ├── cpu_state.zig             # CPU 状态保存/恢复 (~150 行)
│   ├── hibernate.zig             # STD 快照写入/读取 (~500 行)
│   └── wake_source.zig           # 唤醒源管理 (~100 行)

servers/
├── powermgr/                     # [新增] 电源管理服务
│   ├── main.zig                  # 服务入口 + IPC 循环 (~200 行)
│   ├── policy.zig                # 策略引擎 + 配置解析 (~300 行)
│   ├── coordinator.zig           # 挂起/恢复协调器 (~400 行)
│   └── idle_monitor.zig          # 空闲检测 + 电量监控 (~150 行)
```

### 20.10 实施阶段规划

| 阶段 | 任务 | 代码量 | 依赖 |
|---|---|---|---|
| Phase 4a | 内核 ACPI sleep 寄存器 + S1 空闲 | ~350 | ACPI 解析器 (M6) |
| Phase 4b | 内核 CPU 状态保存/恢复 + STR | ~550 | 中断控制器 (M6) |
| Phase 4c | PowerMgr 服务 + 策略引擎 | ~1,050 | IPC (M4) + 所有驱动 |
| Phase 4d | STD 快照写入/恢复 + 压缩 | ~500 | swap (M12) |
| Phase 4e | 唤醒源配置 + WOL | ~250 | 网络驱动 (M10) |
| **总计** | | **~2,700** | |

### 20.11 缺陷修正

| # | 缺陷 | 修正 |
|---|---|---|
| G1 | 完全没有电源管理设计 (无 S1/S3/S4) | §20: 完整 STR/STD/S1 方案 + 自适应策略 |
| G2 | 无驱动/服务挂起协调协议 | §20.6: 两阶段提交 + IPC 电源消息 + 超时 |
| G3 | 无 STD 快照和恢复机制 | §20.4: Save Map + swap 写入 + 压缩 + 顺序 I/O |
| G4 | 无唤醒源管理 | §20.7: WakeSource 注册 + 内核只使能唤醒中断 |
| G5 | 无可配置策略 | §20.5: TOML 配置 + 自适应状态机 + 电池感知 |

---

## 21. 关键缺失子系统补充

> 第四轮审查发现的遗漏项。管道、SMP、per-CPU、reboot、动态链接、core dump、日志持久化。

### 21.1 管道 (Pipe) — H1

**为什么关键**: BusyBox 几乎每个命令都用管道 `cmd1 | cmd2`。`ls | grep foo` 不工作则整个 shell 不可用。`sys_pipe` 是 Linux syscall #22 (附录B)，但完全无设计。

#### 21.1.1 管道内核对象

管道在**内核空间**实现（不在 VFS 服务中），因为它是调度器级别的阻塞/唤醒原语。

```zig
/// 管道对象 — 内核空间
pub const Pipe = struct {
    buffer: [PIPE_BUF_SIZE]u8,     // 环形缓冲区 (默认 64KB)
    read_pos: u32,                 // 读位置
    write_pos: u32,                // 写位置
    readable: KernelEvent,         // 读端事件 (有数据可读时唤醒)
    writable: KernelEvent,         // 写端事件 (有空间可写时唤醒)
    read_fd_count: u32,            // 读端 fd 引用计数
    write_fd_count: u32,           // 写端 fd 引用计数
    flags: packed struct {
        nonblocking: bool,         // O_NONBLOCK
        read_closed: bool,         // 读端关闭
        write_closed: bool,        // 写端关闭
    },
    
    const PIPE_BUF_SIZE = 65536;   // 64KB
    const PIPE_BUF_ATOMIC = 4096;  // 原子写入保证 ≤ 4KB
    
    /// 写入数据 (调用者在 syscall 上下文)
    pub fn write(self: *Pipe, data: []const u8) !usize;
    
    /// 读取数据
    pub fn read(self: *Pipe, buf: []u8) !usize;
    
    /// 关闭读端
    pub fn closeRead(self: *Pipe) void;
    
    /// 关闭写端
    pub fn closeWrite(self: *Pipe) void;
};
```

#### 21.1.2 管道操作语义

```
sys_pipe2(fds, flags):
  1. 内核创建 Pipe 对象
  2. 在进程的 fd 表中分配两个 fd:
     fds[0] = read end  (O_RDONLY)
     fds[1] = write end (O_WRONLY)
  3. 如果 flags & O_NONBLOCK → 两个 fd 都设非阻塞
  4. 如果 flags & O_CLOEXEC → 两个 fd 都设 close-on-exec
  5. 返回 0

写操作 (write 到 pipe write end):
  1. 如果 pipe.buffer 已满 (write_pos - read_pos == PIPE_BUF_SIZE):
     阻塞模式: 挂起调用线程 → 等待 readable 事件
     非阻塞模式: 返回 EAGAIN
  2. 如果写入量 ≤ PIPE_BUF_ATOMIC (4KB): 保证原子写入
     (要么全部写入，要么不写)
  3. 如果写入量 > PIPE_BUF_ATOMIC: 可能部分写入
  4. 写入完成 → 唤醒 readable 等待者

读操作 (read 从 pipe read end):
  1. 如果 pipe.buffer 为空:
     非阻塞模式: 返回 EAGAIN
     写端已关闭: 返回 0 (EOF)
     阻塞模式: 挂起 → 等待 writable 事件
  2. 读取数据 → 唤醒 writable 等待者

关闭语义:
  写端关闭 → 所有阻塞的读端返回 0 (EOF)
  读端关闭 → 所有阻塞的写端收到 SIGPIPE (Linux) 或 ERROR_BROKEN_PIPE (Windows)
  两端都关闭 → 释放 Pipe 对象
```

#### 21.1.3 Shell 管道集成

```
shell 执行 "ls | grep foo":
  1. shell fork() → 子进程 A
  2. shell fork() → 子进程 B
  3. sys_pipe2(fds)
  4. 子进程 A: dup2(fds[1], STDOUT) → close(fds[0]) → exec("ls")
  5. 子进程 B: dup2(fds[0], STDIN)  → close(fds[1]) → exec("grep foo")
  6. shell: close(fds[0]) + close(fds[1]) → waitpid(A) + waitpid(B)

数据流:
  ls → write(STDOUT=pipe[1]) → Pipe buffer → read(pipe[0]=STDIN) → grep foo
```

**命名管道 (FIFO)**: `mkfifo` 创建一个 VFS 文件节点，`open()` 时内核创建 Pipe 对象。第一个 open 阻塞直到另一端也被打开。存储在 tmpfs 或其他文件系统上。

**文件**: `kernel/pipe.zig` (~300 行) + VFS 中 `fifo.zig` (~100 行)

---

### 21.2 SMP 多核启动 (AP Bringup) — H2

**为什么关键**: M11 目标是 SMP 支持，但 x86_64 AP 启动序列完全空白。

#### 21.2.1 x86_64 AP 启动序列

```
BSP (Boot Processor) 启动 AP 的完整流程:

1. ACPI MADT 解析 → 获取所有 LAPIC ID
   MADT 条目: Type=0 (Local APIC) → {ACPI Processor ID, APIC ID, Flags}
   跳过 BSP 自己 (APIC ID == 当前 CPU)
   跳过 disabled 的 CPU (Flags & 1 == 0)

2. 为每个 AP 准备启动代码
   a. 分配一页物理内存 (4KB, 对齐到 4KB, 在物理地址 0x0000-0xFFFFF 内)
      → AP 从实模式启动, 只能访问低 1MB
      → 典型地址: 0x7000 (Linux 默认) 或 0x8000
   
   b. 将 AP 启动代码 (trampoline_16bit.s) 复制到该页
      启动代码内容:
      ┌──────────────────────────────────────────────────┐
      │ trampoline_16bit:                                 │
      │   ; 实模式入口 (16-bit)                           │
      │   cli                                            │
      │   xor ax, ax                                     │
      │   mov ds, ax                                     │
      │   ; 切换到保护模式: 加载临时 GDT                  │
      │   lgdt [gdt32_desc]                              │
      │   mov eax, CR0                                   │
      │   or eax, 1                                      │
      │   mov CR0, eax                                   │
      │   ; 远跳转到 32-bit 代码                         │
      │   jmp dword gdt32_cs:trampoline_32bit             │
      │                                                  │
      │ trampoline_32bit:                                 │
      │   ; 保护模式 (32-bit)                             │
      │   ; 启用长模式: 设置临时页表                      │
      │   mov eax, PML4_PHYS_ADDR    ; BSP 的页表        │
      │   mov CR3, eax                                   │
      │   mov eax, EFER_MSR                              │
      │   rdmsr                                           │
      │   or eax, 0x100          ; EFER.LME              │
      │   wrmsr                                           │
      │   mov eax, CR0                                   │
      │   or eax, 0x80000000     ; CR0.PG                 │
      │   mov CR0, eax                                   │
      │   ; 远跳转到 64-bit 代码                          │
      │   jmp gdt64_cs:trampoline_64bit                   │
      │                                                  │
      │ trampoline_64bit:                                 │
      │   ; 长模式 (64-bit)                               │
      │   ; 加载完整 GDT, IDT                             │
      │   lgdt [gdt64_desc]                              │
      │   lidt [idt64_desc]                              │
      │   ; 设置 AP 的栈                                  │
      │   mov rsp, AP_STACK_TOP                          │
      │   ; 跳转到 Zig AP 入口                            │
      │   call apMain                                    │
      │   hlt                                            │
      └──────────────────────────────────────────────────┘
   
   c. 填充启动代码中的变量:
      PML4_PHYS_ADDR = BSP 的 CR3 (共享页表)
      AP_STACK_TOP = 为该 AP 分配的内核栈 (8KB)
      gdt64_desc = BSP 的 GDT 地址
      idt64_desc = BSP 的 IDT 地址

3. 发送 INIT + SIPI 序列 (Intel Manual Vol 3, §8.4)
   
   对每个 AP APIC ID:
   a. 发送 INIT IPI:
      LAPIC.ICR = {dest=APIC_ID, vector=0, delivery=INIT, assert}
      → 等待 10ms (使用 TSC delay)
   
   b. 发送 SIPI (Startup IPI):
      LAPIC.ICR = {dest=APIC_ID, vector=trampoline_page>>12,
                   delivery=StartUp, assert}
      → 等待 200us
   
   c. 如果 AP 未就绪, 再发一次 SIPI:
      → 等待 200us
   
   d. 如果仍未就绪 → 标记该 AP 为 offline

4. AP 在 apMain() 中:
   a. 初始化自己的 LAPIC
   b. 设置 per-CPU 数据 (GS base → PerCpuData)
   c. 原子递增 cpu_online_count
   d. 设置 AP_READY 标志
   e. 进入调度器 idle 循环 (等待任务分配)
```

#### 21.2.2 AArch64 AP 启动 (PSCI)

```
AArch64 通过 PSCI (Power State Coordination Interface) 启动 AP:

1. FDT 解析 → 获取 CPU 节点列表
   /cpus/cpu@0 { reg = <0x0>; }   // BSP
   /cpus/cpu@1 { reg = <0x1>; }   // AP1
   /cpus/cpu@2 { reg = <0x2>; }   // AP2

2. PSCI 调用 (通过 HVC 或 SMC 指令):
   psci_cpu_on(target_cpu=MPIDR_EL1, entry_point=ap_entry_addr, context_id=0)
   
   → AP 从 ap_entry_addr 开始执行 (已是 EL1 异常级别)
   → 不需要实模式 → 保护模式切换 (ARM 直接在异常级别启动)

3. AP 入口 (ap_entry.s):
   a. 设置 TPIDR_EL1 → PerCpuData
   b. 初始化 GIC CPU interface
   c. 启用 MMU (TTBR0_EL1 = BSP 的页表 或 独立页表)
   d. 跳转到 Zig apMain()
```

#### 21.2.3 SMP 同步点

```
BSP 等待所有 AP 就绪:

  BSP:                            AP:
  发送 INIT/SIPI                  收到 INIT → reset
  → 等待                         收到 SIPI → 执行 trampoline
  检查 cpu_online_count           初始化 LAPIC + per-CPU
  == expected_count?              设置 AP_READY
  NO → 继续等待                   进入 idle 循环
  YES → 启用调度器 → 分配任务给 AP

同步原语:
  cpu_online_count: AtomicU32 (所有 AP 原子递增)
  ap_ready_flags: AtomicBitset (每个 AP 一位)
  barrier: 全部就绪后 BSP 广播 "开始调度"
```

---

### 21.3 per-CPU 数据区域 — H3

**为什么关键**: SMP 多核的基础设施。没有 per-CPU 数据，每个 CPU 访问全局 current_task 需要锁，性能灾难。

#### 21.3.1 数据结构

```zig
/// per-CPU 数据 — 每个 CPU 一份，通过 GS base (x86_64) 或 TPIDR_EL1 (AArch64) 访问
pub const PerCpuData = extern struct {
    /// 自我指针 — GS:0 指向自身 (方便通过 GS 偏移访问字段)
    self: *PerCpuData,
    
    /// CPU 标识
    cpu_id: u32,                    // CPU 编号 (0, 1, 2, ...)
    apic_id: u32,                   // LAPIC ID (x86_64) 或 MPIDR (AArch64)
    
    /// 当前任务
    current_task: ?*Task,           // 当前运行的线程
    current_process: ?*Process,     // 当前进程
    
    /// 调度器
    run_queue: RunQueue,            // 本 CPU 运行队列
    idle_task: Task,                // 本 CPU 的 idle 线程
    
    /// 中断
    interrupt_nesting: u32,         // 中断嵌套深度
    interrupt_stack_top: u64,       // 中断栈顶 (IST 或独立栈)
    
    /// 统计
    ctx_switch_count: u64,          // 上下文切换次数
    interrupt_count: u64,           // 中断次数
    syscall_count: u64,             // syscall 次数
    
    /// 内核栈
    kernel_stack_base: u64,         // 内核栈基址 (用于栈溢出检测)
    kernel_stack_top: u64,          // 内核栈顶
};

/// 访问 per-CPU 数据的宏
pub fn thisCpu() *PerCpuData {
    // x86_64: return GS:[0]
    // AArch64: return TPIDR_EL1
    return arch.readPerCpuBase();
}

/// 便捷访问
pub fn currentTask() ?*Task {
    return thisCpu().current_task;
}

pub fn currentProcess() ?*Process {
    return thisCpu().current_process;
}
```

#### 21.3.2 初始化

```
x86_64:
  BSP: 在启动时设置 MSR_GS_BASE = &per_cpu_data[0]
  AP:  在 apMain() 中设置 MSR_GS_BASE = &per_cpu_data[cpu_id]
  
  通过 SWAPGS 指令在 syscall entry/exit 时切换用户/内核 GS base:
    syscall entry:  SWAPGS (切到内核 GS = PerCpuData)
    syscall exit:   SWAPGS (切回用户 GS = TLS)

AArch64:
  BSP: MSR TPIDR_EL1, &per_cpu_data[0]
  AP:  MSR TPIDR_EL1, &per_cpu_data[cpu_id]

内存分配:
  per_cpu_data: [MAX_CPU]PerCpuData
  MAX_CPU = 256 (x86_64) 或 8 (AArch64 QEMU)
  在内核 BSS 段静态分配
```

---

### 21.4 Reboot (热重启) — H6

**为什么需要**: §17.3 只有 shutdown (S5)，没有 reboot。调试和运维都需要重启能力。

#### 21.4.1 重启方法 (按优先级)

```
方法 1: ACPI Reset (最可靠)
  1. 从 FADT 获取 reset_reg 和 reset_value
  2. 写入 reset_value 到 reset_reg
  → 系统重置 (ACPI 规范定义)
  
  FADT 字段:
    reset_reg: ACPI Generic Address (可以是 I/O port, MMIO, PCI config)
    reset_value: u8

方法 2: Keyboard Controller Reset (回退)
  1. 写 0xFE 到 I/O port 0x64 (键盘控制器命令端口)
  → 触发 CPU reset (传统 PC 兼容)
  
  代码: outb(0x64, 0xFE);

方法 3: Triple Fault (最后手段)
  1. 加载一个空的 IDT (0 条目)
  2. 触发中断 → IDT 无效 → triple fault
  → CPU 自动 reset
  
  代码:
    idt.base = 0; idt.limit = 0;
    lidt idt;
    int 3;  // 触发 → triple fault → reset

方法 4: EFI Reset (UEFI 系统)
  runtime_services->ResetSystem(EfiResetCold, ...)

方法 5: QEMU 特定
  写 0 到 0x501 (QEMU debug exit) 或
  写 val 到 0xf4 (QEMU isa-debug-exit)
```

#### 21.4.2 Reboot 流程

```
reboot 路径 (Init 收到 reboot 命令):
  1. 通知所有进程终止 (SIGTERM → 3s → SIGKILL)
  2. VFS sync (刷出所有脏页)
  3. 停止服务 (逆拓扑序)
  4. 停止其他 CPU (IPI HALT)
  5. 尝试 ACPI Reset
  6. 失败 → 尝试 Keyboard Controller Reset (0x64, 0xFE)
  7. 失败 → Triple Fault
  8. 不应该到达这里 → hlt 循环
```

---

### 21.5 ELF 动态链接 / 共享库 (.so) — H7

**为什么需要**: 静态链接的 BusyBox 能跑，但真实的 Linux 生态严重依赖动态链接。glibc 程序加载 `libc.so.6` → `ld-linux-x86-64.so.2`。如果不支持，大量现有二进制无法运行。

#### 21.5.1 动态链接流程

```
用户执行 ELF 二进制文件:
  LinuxPers elf_loader.zig:
    1. 解析 ELF header → 检查 e_type:
       ET_EXEC (静态) → 直接加载 (当前已实现)
       ET_DYN  (动态/PIE) → 需要动态链接

    2. 如果有 PT_INTERP 段:
       → 读取解释器路径: "/lib64/ld-linux-x86-64.so.2"
       → 加载 ld-linux.so 到进程地址空间 (作为 ET_DYN)
       → ld-linux.so 负责:
         a. 解析 ELF 的 PT_DYNAMIC 段
         b. 从 .dynsym + .dynstr 获取需要的共享库名称
         c. 搜索路径: RPATH → LD_LIBRARY_PATH → /lib → /usr/lib → /system/lib
         d. 加载每个 .so (mmap)
         e. 解析符号 (.dynsym → .hash/.gnu_hash → 查找)
         f. 重定位 (.rela.dyn, .rela.plt)
         g. 填充 GOT (Global Offset Table)
         h. 设置 PLT (Procedure Linkage Table) → 懒加载
         i. 调用 .init_array / DT_INIT
         j. 跳转到程序入口

    3. MoQiOS 提供的最小 .so 集合:
       /system/lib/ld-moqi.so     → MoQiOS 动态链接器 (自研, ~1500 行)
       /system/lib/libc.so        → 指向 moqi_libc (§12.11)
       /system/lib/libm.so        → 数学库 (基础)
       /system/lib/libpthread.so  → 线程库 (futex 封装)
       
       Linux 二进制兼容:
       /lib64/ld-linux-x86-64.so.2 → symlink → /system/lib/ld-moqi.so
       /lib/x86_64-linux-gnu/libc.so.6 → symlink → /system/lib/libc.so
```

#### 21.5.2 动态链接器 (ld-moqi.so)

```zig
/// MoQiOS 动态链接器 — 用户空间服务 (LinuxPers 内部)
pub const DynLinker = struct {
    /// 加载主程序和所有依赖
    pub fn loadExecutable(elf_path: []const u8) !ProcessImage;
    
    /// 递归加载共享库依赖
    fn loadDependencies(self: *DynLinker, needed: []const u8) void;
    
    /// 解析符号
    fn resolveSymbol(self: *DynLinker, name: []const u8) ?u64;
    
    /// 重定位
    fn relocate(self: *DynLinker, image: *ProcessImage) void;
    
    /// 填充 GOT/PLT
    fn setupPltGot(self: *DynLinker, image: *ProcessImage) void;
};
```

**懒绑定 (Lazy Binding)**: PLT 默认使用懒绑定——函数第一次调用时才解析符号。性能最优。

**实现位置**: `servers/linux_pers/dynlinker.zig` (~1500 行)

---

### 21.6 Core Dump (崩溃转储) — H4

**为什么需要**: 进程 crash 后唯一的离线调试手段。gdb 需要 core dump 文件分析崩溃原因。

#### 21.6.1 Core Dump 生成流程

```
进程 crash 路径:
  Linux 应用触发 SIGSEGV/SIGABRT:
    → LinuxPers 捕获信号
    → 检查: 进程是否设置了 RLIMIT_CORE > 0?
      NO → 直接终止进程
      YES → 生成 core dump:

Core dump 生成 (LinuxPers 负责):
  1. 创建 ELF 文件: /var/core/core.{pid}.{timestamp}
  2. 写入 ELF header (ET_CORE 类型)
  3. 写入 NOTE 段:
     • NT_PRSTATUS: 寄存器快照 (RAX-R15, RIP, RSP, RFLAGS)
     • NT_PRPSINFO: 进程信息 (PID, PPID, signal, uid/gid)
     • NT_AUXV: auxiliary vector 副本
     • NT_FILE: 文件映射表 (路径 + 地址范围)
  4. 写入 LOAD 段:
     • 对进程地址空间中每个可读 VMA:
       → 匿名映射: 直接复制内存内容
       → 文件映射: 记录文件路径 + 偏移 (不复制, 减小 core 大小)
  5. 写入线程信息 (每个线程一个 NOTE):
     • NT_PRSTATUS: 各线程的寄存器
  6. 关闭文件
  7. 发送 SIGKILL 终止进程

限制:
  • core dump 最大大小: RLIMIT_CORE (默认 64MB)
  • 超过限制 → 截断 (只写入部分内存映射)
  • 敏感页面 (如含密码): 通过 /proc/{pid}/coredump_filter 过滤
```

**文件**: `servers/linux_pers/coredump.zig` (~400 行)

---

### 21.7 日志持久化 — H5

**为什么需要**: §13.1 klog ring buffer 只在内存中，重启丢失。生产系统需要持久化日志用于事后分析。

#### 21.7.1 日志持久化方案

```
日志流向:

  内核 klog (ring buffer, §13.1)
       │
       │ IPC notify (新日志条目)
       ▼
  ┌──────────────────────────────────┐
  │    syslogd (用户空间服务)         │
  │                                  │
  │  1. 接收内核 klog 条目 (IPC)     │
  │  2. 接收服务日志 (IPC)           │
  │  3. 接收 /dev/kmsg 读取请求      │
  │  4. 按级别过滤:                  │
  │     ERROR → /var/log/error.log   │
  │     WARN+ → /var/log/kern.log    │
  │     ALL → /var/log/all.log       │
  │  5. 日志轮转:                    │
  │     kern.log → kern.log.1        │
  │     (超过 10MB 或每天轮转)       │
  │  6. 保留最近 N 个轮转文件        │
  └──────────────────────────────────┘
```

**配置**: `/system/syslog.conf`
```toml
[syslog]
kern_log = "/var/log/kern.log"     # 内核日志
max_size = 10485760                 # 10MB
rotate_count = 5                    # 保留 5 个轮转文件
level = "warn"                      # 最低记录级别
```

**Linux 兼容**: 支持 `dmesg` 命令 → 读取 `/dev/kmsg` (VFS 字符设备)

**文件**: `servers/syslogd/main.zig` (~300 行) + `/dev/kmsg` 在 devfs 中注册

---

### 21.8 远期目标声明 — H8/H9/H10

以下功能声明为 Phase 5+ 远期目标，MVP 阶段不实现：

| 项目 | 说明 | 预计阶段 |
|---|---|---|
| **H8: System V IPC** | shmget/msgget/semget — 部分旧 Linux 应用需要。用 MoQiOS IPC 共享内存 + 信号量模拟 | Phase 5+ |
| **H9: 用户/权限管理** | /etc/passwd, /etc/group, login, su, chmod — 初期 root 单用户。通过 moqi_libc 提供 stub | Phase 5+ |
| **H10: 时区 / NTP** | 时区数据库 (tzdata) + NTP 客户端 (NetStack UDP) — 通过 moqi_libc localtime() 支持 | Phase 5+ |

### 21.9 缺陷修正

| # | 缺陷 | 修正 |
|---|---|---|
| H1 | 管道 (pipe) 实现完全空白 | §21.1: Pipe 内核对象 + 环形缓冲区 + 阻塞/唤醒 + FIFO |
| H2 | SMP AP bringup 无详细设计 | §21.2: x86_64 INIT/SIPI/trampoline + AArch64 PSCI 完整序列 |
| H3 | per-CPU 数据区域未设计 | §21.3: PerCpuData 结构 + GS base/TPIDR_EL1 + thisCpu() 宏 |
| H4 | Core Dump 未设计 | §21.6: ELF core 文件 + NOTE/LOAD 段 + RLIMIT_CORE |
| H5 | 日志持久化未设计 | §21.7: syslogd 服务 + 日志轮转 + /dev/kmsg |
| H6 | reboot 热重启缺失 | §21.4: ACPI Reset + 0x64/0xFE + Triple Fault 三重回退 |
| H7 | ELF 动态链接未设计 | §21.5: PT_INTERP + ld-moqi.so + GOT/PLT 懒绑定 |
| H8 | System V IPC 未设计 | §21.8: 声明为 Phase 5+ 远期 |
| H9 | 用户/权限管理未设计 | §21.8: 声明为 Phase 5+ 远期 |
| H10 | 时区/NTP 未考虑 | §21.8: 声明为 Phase 5+ 远期 |

| 术语 | 定义 |
|---|---|
| **Personality Server** | ABI 翻译服务，将 Linux/Windows 系统调用翻译为 MoQiOS 内部 IPC |
| **IPC** | 进程间通信 (Inter-Process Communication) |
| **VFS** | 虚拟文件系统 (Virtual File System) |
| **VMM** | 虚拟内存管理器 (Virtual Memory Manager) |
| **CoW** | 写时复制 (Copy-on-Write) |
| **SEH** | 结构化异常处理 (Structured Exception Handling) |
| **TEB** | 线程环境块 (Thread Environment Block) |
| **PEB** | 进程环境块 (Process Environment Block) |
| **IAT** | 导入地址表 (Import Address Table) |
| **HHDM** | 高半直接映射 (Higher-Half Direct Map) |
| **Capability** | 能力令牌，用于 IPC 和资源访问授权 |
| **Demand Paging** | 按需分页，访问时才分配物理页面 |
| **STR** | Suspend to RAM (ACPI S3)，挂起到内存，唤醒 ~1-2s |
| **STD** | Suspend to Disk (ACPI S4)，挂起到磁盘，唤醒 ~5-10s |
| **PowerMgr** | 电源管理服务，负责策略决策和挂起/恢复协调 |
| **Wake Source** | 唤醒源，能将系统从睡眠状态唤醒的硬件事件 |
| **BSP** | Bootstrap Processor，引导处理器 (x86_64 SMP 中第一个启动的 CPU) |
| **AP** | Application Processor，应用处理器 (被 BSP 唤醒的从 CPU) |
| **per-CPU** | 每个 CPU 独立的数据区域，通过 GS base 或 TPIDR_EL1 访问 |
| **trampoline** | SMP 启动蹦床代码，AP 从实模式切换到长模式的过渡代码 |
| **PLT** | 过程链接表 (Procedure Linkage Table)，动态链接的懒绑定机制 |
| **GOT** | 全局偏移表 (Global Offset Table)，存储动态链接符号的地址 |

## 附录 B: 系统调用覆盖范围

### B.1 Linux 核心系统调用 (Phase 2 目标: ~80 个)

```
# I/O
0   sys_read            1   sys_write           2   sys_open
3   sys_close           8   sys_lseek           16  sys_ioctl
19  sys_readv           20  sys_writev          22  sys_pipe

# 文件系统
4   sys_stat            5   sys_fstat           40  sys_mkdir
41  sys_unlink          42  sys_execve          83  sys_mkdirat
87  sys_unlinkat        78  sys_getdents64

# 进程
39  sys_getpid          56  sys_clone           57  sys_fork
58  sys_vfork           59  sys_execve          60  sys_exit
61  sys_wait4           101 sys_nanosleep

# 内存
9   sys_mmap            10  sys_mprotect        11  sys_munmap
12  sys_brk

# 信号
13  sys_rt_sigaction    14  sys_rt_sigprocmask  15  sys_rt_sigreturn

# 网络
41  sys_socket          42  sys_connect         43  sys_accept
44  sys_sendto          45  sys_recvfrom        46  sys_sendmsg
47  sys_recvmsg         48  sys_shutdown        49  sys_bind
50  sys_listen          51  sys_getsockname     52  sys_getpeername

# 同步
202 sys_futex           231 sys_exit_group
```

### B.2 Windows 核心 NT API (Phase 3 目标: ~50 个)

```
# 进程/线程
NtCreateProcess          NtCreateThread
NtTerminateProcess       NtTerminateThread
NtQueryInformationProcess NtQueryInformationThread

# 内存
NtAllocateVirtualMemory  NtFreeVirtualMemory
NtProtectVirtualMemory   NtQueryVirtualMemory

# 文件 I/O
NtCreateFile             NtReadFile
NtWriteFile              NtClose
NtQueryInformationFile   NtSetInformationFile
NtQueryDirectoryFile

# 同步
NtCreateEvent            NtSetEvent
NtWaitForSingleObject    NtWaitForMultipleObjects
NtCreateMutex            NtReleaseMutex
NtCreateSemaphore        NtReleaseSemaphore

# Section (共享内存)
NtCreateSection          NtMapViewOfSection
NtUnmapViewOfSection

# 信息查询
NtQuerySystemInformation NtQueryObject
```

## 附录 C: 补充设计细节

### C.1 futex 内核支持 (D22)

```
futex(FUTEX_WAIT, addr, val):
  1. 内核检查 *addr == val?
     → 不等 → 立即返回 EAGAIN
     → 相等 → 将当前线程加入等待队列 (hash table, key = addr + PID)
  2. 线程阻塞, 移出运行队列

futex(FUTEX_WAKE, addr, count):
  1. 查找等待队列中 key = addr + PID 的线程
  2. 唤醒前 count 个 (count=1 唤醒一个, INT_MAX 唤醒全部)
  3. 被唤醒线程返回 0

futex(FUTEX_REQUEUE): 从一个等待队列移到另一个 (用于 pthread_cond)
futex(FUTEX_CMP_REQUEUE): 带 val 检查的 requeue

内核实现:
  全局 hash table: addr_hash → 等待队列链表
  使用 IrqSpinlock 保护 hash table
  约 ~200 行内核代码
```

### C.2 NUMA 预留接口 (D24)

```
Phase 2+ NUMA 感知 (预留接口):

PMM 扩展:
  pmm.alloc_on_node(node_id, count) → PhysAddr  // 指定 NUMA 节点分配
  pmm.alloc_local(count) → PhysAddr               // 在当前 CPU 节点分配

ACPI SRAT 解析 (在 ACPI 模块中预留):
  → 提取 NUMA 节点 → 内存范围映射
  → CPU → NUMA 节点亲和性

调度器扩展:
  → task.preferred_node = 当前 CPU 所在 NUMA 节点
  → 迁移时优先选择同节点 CPU

本阶段: 不实现, 但 PMM 和调度器接口预留 node_id 参数 (默认 0)
```

### C.3 AArch64 FDT 解析 (D25)

```
AArch64 不使用 ACPI, 使用 FDT (Flattened Device Tree):
  1. bootloader (UEFI) 传递 FDT 地址给内核
  2. 内核解析 FDT:
     → /cpus → CPU 数量、频率、MMU 特性
     → /memory → 物理内存范围
     → /soc/uart → 串口地址
     → /soc/gic → GIC 中断控制器配置
     → /soc/timer → Generic Timer 频率

HAL 抽象:
  x86_64: ACPI → 硬件发现
  AArch64: FDT → 硬件发现
  两者通过 hal.zig 统一接口

M11 新增任务:
  M11.0a: FDT 解析器 (参考 libfdt, ~300 行)
  M11.0b: FDT → HAL 统一接口适配
```

### C.4 缺陷修正汇总

| # | 缺陷 | 修正位置 |
|---|---|---|
| D11 | 中断处理缺少详细设计 | §14 中断子系统 (Scheme D) |
| D12 | 内核栈溢出保护缺失 | §15.6 guard page + IST |
| D13 | Capability 系统缺少具体设计 | §15 Capability 系统 |
| D14 | VFS 写操作缺失 | §10 Phase 4.1 ext4 读写 |
| D15 | 系统调用性能优化缺失 | §16 VDSO + 快速 syscall + PCID |
| D16 | 实施计划缺少 ext4 写 + swap | §10 Phase 4.1-4.2 |
| D17 | 共享内存 API 缺失 | §3.3.4 共享内存 API |
| D18 | 信号帧构建细节缺失 | §4.3.3 信号帧 + §4.3.4 SEH 分发 |
| D19 | Windows DLL 加载链缺失 | §4.4.3 DLL 加载链 |
| D20 | Init 配置缺失 | §17.1-17.2 配置格式 + 启动流程 |
| D21 | PCID/ASID 详细设计缺失 | §16.3 PCID 分配策略 |
| D22 | futex 内核支持缺失 | §C.1 futex 内核实现 |
| D23 | shutdown/reboot 缺失 | §17.3 系统关机流程 |
| D24 | NUMA 预留接口 | §C.2 NUMA 预留 |
| D25 | AArch64 FDT 缺失 | §C.3 FDT 解析 |
