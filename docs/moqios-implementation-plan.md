# MoQiOS 实施计划

> **版本**: v0.3 (进度更新)  
> **日期**: 2026-05-22  
> **配套文档**: [moqios-design.md](./moqios-design.md)  
> **总目标**: 从零开始实现一个微内核操作系统，支持 Linux + Windows 双二进制兼容  
> **总代码量估算**: ~40,000 行 (含内核、服务、驱动、ntdll、测试框架)  
> **预计总工期**: ~40 周 (约 10 个月，含审计新增子系统)

---

## 实施进度 (截至 2026-05-22)

**M1–M10 全部完成，M11+ 扩展功能已完成。内核代码 ~11,600 行，18 个自动化测试全部通过。**

### 已完成功能清单

| 功能 | 里程碑 | 说明 |
|---|---|---|
| 内核启动 + 串口输出 | M1 | Limine 引导，GDT/IDT 初始化 |
| 物理内存管理 + 分页 | M2 | PMM 页分配，4 级页表，HHDM |
| 调度器 + 上下文切换 | M3 | 轮转调度，内核线程 + 用户进程 |
| 用户空间进程 + syscall | M4 | syscall/sysret，MSR LSTAR |
| 多进程 + ELF 加载器 | M5 | argc/argv/auxv 栈构建 |
| PCI 设备枚举 | M6 | PCI 配置空间读写 |
| virtio-blk + FAT32 | M7 | FAT32 读写，文件创建/删除 |
| e1000 + 网络协议栈 | M8 | ARP/IPv4/ICMP/UDP |
| 管道 + Shell | M9 | pipe/dup2，I/O 重定向，交互式 Shell |
| fork + execve | M10 | COW 地址空间克隆，argv 传递 |
| 信号处理 | M11+ | kill/sigaction/sigreturn/sigprocmask，Ctrl+C |
| 环境变量 | M11+ | getenv/setenv，fork 继承，Shell export |
| 目录操作 | M11+ | chdir/getcwd/listdir，路径规范化 |
| 文件元数据 | M11+ | fstat (mode/size/type)，uname |
| 文件删除 | M11+ | unlink FAT32 文件，FAT 簇链释放 |

### 已实现系统调用 (35 个)

```
1=write  2=exit  4=getpid  5=spawn  6=waitpid  7=brk  8=mmap
9=open  10=read  11=close  12=munmap  13=sigaction  14=sigprocmask
15=sigreturn  22=pipe  33=dup2  57=fork  59=execve  62=kill
63=uname  96=gettimeofday  100-104=net_*  105=getenv  106=setenv
107=listdir  108=chdir  109=getcwd  110=fstat  111=unlink
228=clock_gettime
```

### 测试覆盖

18 个自动化测试 (hello2–hello18) + 交互式 Shell，覆盖：ramdisk 读写、多进程、ELF 加载、管道、fork、execve、FAT32 写入、信号处理、网络 ARP/UDP、环境变量、argv 传递、目录操作、文件元数据。

---

## 0. 实施策略总览

### 0.1 核心原则

1. **增量可验证**: 每个 Milestone 结束时，必须有可运行的系统 + 可通过的测试
2. **先内核后服务**: 微内核先行，用户空间服务后上
3. **先 Linux 后 Windows**: Linux 兼容优先 (参考 Zigix 现成代码)，Windows 后续
4. **先 QEMU 后真机**: 所有开发先用 QEMU 验证，稳定后再上真机
5. **每个模块可独立测试**: 不依赖后续模块才能验证

### 0.2 里程碑总览

```
M0: 环境搭建 + 测试框架 (1.5 周) [审计新增: 测试框架]
  │
M1: 内核启动 + 串口输出 + ACPI + 调试 (3 周) [审计新增: ACPI、调试、时钟源]
  │
M2: 物理内存管理 + 页表 + 同步原语 (2.5 周) [审计新增: 内核锁]
  │
M3: 调度器 + 上下文切换 (2 周)
  │
M4: IPC 引擎 + 死锁预防 (3.5 周) ← 微内核核心完成 [审计新增: 死锁检测]
  │
M5: 用户空间进程 + 基础服务 + OOM (3.5 周) [审计新增: OOM、熵源、CRT]
  │
M6: PCI + Linux Personality — ELF + 核心 syscall (4.5 周) [审计新增: PCI 枚举]
  │
M7: VFS + ext4 只读 (3 周)
  │
M8: 伪文件系统 + PTY + Linux 完整 syscall (5 周) ← BusyBox 可运行 [审计新增: devfs/tmpfs/procfs、PTY]
  │
M9: Windows Personality — PE + NT 核心 API (6 周) ← Windows 兼容 MVP
  │
M10: 网络 + 驱动完善 + epoll (4.5 周) ← 生产可用 [审计新增: epoll、TTY 服务]
  │
M11: AArch64 移植 + SMP (4 周)
  │
M12: ext4 写入 + swap + VFS writeback + 关机 (4 周)
  │
M13: 电源管理 — STR/STD + 自适应策略 (3 周) ← [新增]
```

**预计总工期**: ~43 周 (约 11 个月，含审计新增子系统 + 电源管理)

### 0.3 缺陷修正记录

在细化计划过程中发现的设计文档缺陷，已在本计划中修正：

| # | 缺陷 | 修正 |
|---|---|---|
| D1 | 设计文档使用双 MSR (LSTAR/CSTAR) 区分 ABI，但 x86_64 的 `syscall` 指令**只走 LSTAR**，CSTAR 用于 `sysret` 返回后的兼容段 | 改用进程 `personality` 字段 + syscall 入口处检查当前进程 |
| D2 | 设计文档未讨论 bootloader 的具体实现方式 | 增加 bootloader 选型：Phase 1 用 Limine，后期自研 UEFI loader |
| D3 | 微内核中 VMM 作为用户空间服务，但缺页处理需要内核参与 (CoW) | 明确内核/服务边界：内核做缺页检测+CoW，VMM 做分配策略 |
| D4 | 设计中 IPC 消息固定 256 字节，未考虑缓存行对齐 | 改为 128 字节 payload (对齐 2 个 cache line)，控制消息总大小 256 字节 |
| D5 | ntdll.dll 作为 Zig 编译的 DLL，但 Zig 的 Windows DLL 输出能力有限 | 改为 C/ASM 编译 ntdll.dll (确保 Windows ABI 兼容)，Zig 写 Windows Personality 服务本身 |
| D6 | 设计未提及内核堆分配器 | 增加 slab 分配器作为内核内部堆管理 |
| D7 | klog 设计过于原始，只是分级串口输出 | 升级为结构化 klog + lock-free ring buffer + comptime 过滤 (详见设计文档 §13.1.1) |
| D8 | 缺少服务崩溃恢复机制 | Init 维护服务依赖图 + PM 健康监控 + 分级重启策略 (详见设计文档 §13.2) |
| D9 | 缺少 ptrace / 进程调试架构 | 内核提供 4 个调试原语 + LinuxPers 实现 ptrace + WinPers 实现 NT debug (详见设计文档 §13.3-13.4) |
| D10 | 缺少 IPC 消息追踪 | comptime 可选的 IPC trace ring buffer (详见设计文档 §13.2.3) |
| D11 | 中断处理缺少详细设计 | 新增 §14: Scheme D 中断线程 + MSI-X + coalescing + userspace MMIO |
| D12 | 内核栈溢出保护缺失 | 每 Task 分配 guard page; IDT #DF/#NMI 使用 IST (详见 §15.6) |
| D13 | Capability 系统缺少具体设计 | 新增 §15: 16 字节 capability + 32 槽直接表 + IPC inline 检查 |
| D14 | VFS 写操作 / ext4 读写缺失 | 新增 M12: ext4 读写 + VFS dirty page writeback (Phase 4) |
| D15 | 系统调用性能优化缺失 | 新增 §16: VDSO + 快速系统调用 + PCID (详见 §16.1-16.3) |
| D16 | 实施计划缺少 ext4 写 + swap | M12 覆盖; Phase 4 路线图更新 (设计文档 §10) |
| D17 | 共享内存 API 缺失 | 补充 §3.3.4: shm_create/map/unmap/transfer/destroy |
| D18 | 信号帧构建细节缺失 | 补充 §4.3.3 (Linux sigreturn frame) + §4.3.4 (Windows SEH 分发) |
| D19 | Windows DLL 加载链缺失 | 补充 §4.4.3: DLL 搜索顺序 + 递归加载 + IAT binding |
| D20 | Init 系统配置缺失 | 新增 §17.1-17.2: moqios.conf 配置格式 + 拓扑启动 |
| D21 | PCID/ASID 详细设计缺失 | §16.3 PCID 分配策略 + AArch64 ASID (256 约束) |
| D22 | futex 内核支持缺失 | 附录 C.1: hash table + IrqSpinlock 等待队列 |
| D23 | shutdown/reboot 设计缺失 | §17.3: 逆拓扑序退出 + ACPI S5 + QEMU 退出 |
| D24 | NUMA 预留接口 | 附录 C.2: PMM 预留 node_id 参数 (Phase 2+) |
| D25 | AArch64 FDT 解析缺失 | 附录 C.3: M11 新增 FDT 解析器任务 |
| E1 | USB 驱动栈完全缺失 | §18.1: xHCI + USB Core + HID + Mass Storage (~1,900 行, Phase 4) |
| E2 | GPU/Framebuffer 无设计 | §18.2: 三阶段策略 (基础 fb → virtio-gpu → 原生 GPU), M10 加基础 fb |
| E3 | 驱动动态加载机制未说明 | §18.3: PCI ID 匹配表 + DevMgr 自动加载 + 统一 DriverInterface |
| F1 | 物理内存分配器 (Buddy + Slab) 无详细设计 | §19.1: 伙伴系统 + Slab 分配器 (~780 行), M2 |
| F2 | LRU 页面置换策略未设计 | §19.2: 双链表 LRU + kswapd (~550 行), Phase 4 |
| F3 | 块设备缓冲层未设计 | §19.3: Bio + Buffer Cache + IO 调度器 (~600 行), Phase 3 |
| F4 | PID/IPC/网络命名空间未考虑 | §19.6: 预留接口 (Phase 5+) |
| F5 | 网络包缓冲管理未设计 | §19.4: NetBuf 链式零拷贝 (~250 行), Phase 3 |
| F6 | DMA 缓冲区管理未设计 | §19.5: 内核 DMA API (~300 行), Phase 2 |
| G1 | 完全没有电源管理 (无 S1/S3/S4) | §20: STR/STD/S1 完整方案 + 自适应策略 (~2,700 行) |
| G2 | 无驱动/服务挂起协调协议 | §20.6: 两阶段提交 + IPC 电源消息 |
| G3 | 无 STD 快照恢复机制 | §20.4: Save Map + swap + LZO 压缩 |
| G4 | 无唤醒源管理 | §20.7: WakeSource 注册 + 中断 mask |
| G5 | 无可配置策略 | §20.5: TOML 配置 + 自适应状态机 |
| H1 | 管道 (pipe) 完全空白 | §21.1: Pipe 内核对象 + 环形缓冲区 (~300 行), M5 |
| H2 | SMP AP bringup 无详细设计 | §21.2: x86_64 trampoline + SIPI 序列, M11 |
| H3 | per-CPU 数据区域未设计 | §21.3: PerCpuData + GS base, M11 |
| H4 | Core Dump 未设计 | §21.6: ELF core 文件 (~400 行), M8 |
| H5 | 日志持久化未设计 | §21.7: syslogd 服务 (~300 行), M8 |
| H6 | reboot 热重启缺失 | §21.4: ACPI Reset + 三重回退, M12 |
| H7 | ELF 动态链接未设计 | §21.5: ld-moqi.so 动态链接器 (~1500 行), Phase 4+ |
| H8-H10 | System V IPC/用户管理/时区 | §21.8: 声明为 Phase 5+ 远期 |

---

## M0: 环境搭建 + 测试框架 (1.5 周)

### 目标

搭建完整的开发、构建、测试环境。编写单元测试框架骨架。

### 任务清单

| # | 任务 | 交付物 | 验证标准 |
|---|---|---|---|
| M0.1 | 安装 Zig 工具链 (锁定版本) | zig 0.14+ 可用 | `zig version` 输出正确 |
| M0.2 | 安装 QEMU (x86_64) | qemu-system-x86_64 可用 | 能启动一个 Linux 镜像 |
| M0.3 | 创建 Git 仓库 + 目录结构 | moqios/ 完整目录 | `tree` 输出与设计文档 §9 一致 |
| M0.4 | 编写 build.zig 骨架 | `zig build` 可运行 | 编译空 kernel/main.zig 为 freestanding ELF |
| M0.5 | 配置 Limine bootloader | boot/limine/ 配置文件 | QEMU 启动到 Limine 菜单 |
| M0.6 | 编写 linker script | kernel/linker.ld | 内核符号正确排列 (text → rodata → data → bss) |
| M0.7 | 编写 QEMU 启动脚本 | tools/qemu_run.sh | 一键启动 QEMU + Limine + 内核映像 |
| M0.8 | 配置 CI (可选) | GitHub Actions / 本地脚本 | 提交触发 `zig build` |
| M0.9 | **[审计新增]** 编写测试框架骨架 | tests/ + tools/test_runner/ | 能运行 `zig build test`，支持内核模块单元测试 |
| M0.10 | **[审计新增]** build.zig 用户空间编译支持 | build.zig 添加 freestanding 用户程序目标 | 能编译一个简单的用户空间 .bin 并放入 ramdisk |

### build.zig 骨架

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const kernel = b.addExecutable(.{
        .name = "moqi-kernel.elf",
        .root_source_file = b.path("kernel/main.zig"),
        .target = target,
        .optimize = .Debug, // 开发阶段用 Debug
    });
    kernel.setLinkerScript(b.path("kernel/linker.ld"));
    kernel.addObjectFile(b.path("kernel/arch/x86_64/entry.o")); // 汇编入口

    b.installArtifact(kernel);

    // QEMU 运行
    const run = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-M", "q35",
        "-m", "512M",
        "-serial", "stdio",
        "-kernel", "zig-out/bin/moqi-kernel.elf",
    });
    b.step("run", "Run in QEMU").dependOn(&run.step);
}
```

### 缺陷检查

- [x] Zig freestanding 交叉编译可行 (Zigix 已验证)
- [x] Limine 支持 x86_64 直接内核加载
- [ ] **待验证**: Zig 0.14+ 的 `addObjectFile` 对纯汇编 `.s` 文件的支持 → 可能需要先 `zig cc -c` 编译汇编

---

## M1: 内核启动 + 串口输出 + ACPI + 调试 (3 周)

### 目标

从 UEFI/Limine 启动内核，进入长模式，通过串口输出 "Hello MoQiOS"。解析 ACPI 表获取硬件拓扑。建立基础调试设施。

### 依赖关系

```
entry.s (汇编入口)
  → 设置栈 → 跳转 main.zig
    → vga.zig / serial.zig (输出)
    → gdt.zig (基本 GDT)
    → idt.zig (空 IDT，能捕获 triple fault)
    → acpi/ (RSDP → XSDT → MADT/MCFG 解析) [审计新增]
    → klog.zig + panic.zig + symbol_table (调试) [审计新增]
    → timer.zig (时钟源初始化) [审计新增]
```

### 任务清单

| # | 任务 | 文件 | 行数估算 | 验证标准 |
|---|---|---|---|---|
| M1.1 | x86_64 汇编入口 | `arch/x86_64/entry.s` | ~50 | 设置栈，调用 kernelMain() |
| M1.2 | Limine boot info 解析 | `boot_info.zig` | ~80 | 读取内存映射、ACPI RSDP |
| M1.3 | HHDM (高半直接映射) 设置 | `mm/hhdm.zig` | ~120 | 内核可通过 HHDM 访问所有物理内存 |
| M1.4 | VGA 文本模式输出 | `arch/x86_64/vga.zig` | ~80 | 屏幕显示文字 |
| M1.5 | 串口输出 (COM1) | `arch/x86_64/serial.zig` | ~60 | QEMU `-serial stdio` 看到输出 |
| M1.6 | 基本 GDT 设置 | `arch/x86_64/gdt.zig` | ~80 | 内核代码段 + 数据段 |
| M1.7 | 基本 IDT 设置 | `arch/x86_64/idt.zig` | ~150 | 能捕获异常，输出 panic 信息 |
| M1.8 | 内核 panic 处理 | `panic.zig` | ~40 | panic 时输出调用栈 |
| M1.9 | 内核日志系统 | `klog.zig` | ~60 | klog.info/warn/err 分级日志 |
| M1.10 | **[审计新增]** ACPI RSDP/XSDT 定位与解析 | `acpi/acpi_parser.zig` | ~200 | 从 Limine boot info 获取 RSDP，遍历 XSDT 条目 |
| M1.11 | **[审计新增]** ACPI MADT 解析 (CPU/APIC) | `acpi/acpi_parser.zig` (+) | ~120 | 提取 LAPIC 基地址、CPU APIC ID 列表、IOAPIC 地址 |
| M1.12 | **[审计新增]** ACPI MCFG 解析 (PCIe ECAM) | `acpi/acpi_parser.zig` (+) | ~60 | 提取 PCIe ECAM 基地址，为 PCI 做准备 |
| M1.13 | **[审计新增]** ACPI 表结构定义 | `acpi/acpi_tables.zig` | ~80 | RSDP/XSDT/MADT/MCFG/FADT 描述符头 |
| M1.14 | **[审计新增]** 异常环形缓冲区 | `arch/x86_64/exception.zig` | ~80 | 每 CPU 记录最近 64 条异常信息 |
| M1.15 | **[审计新增]** 内核符号表加载 | `debug/symbol_table.zig` | ~80 | build.zig 生成 kernel.sym，panic 时显示函数名 |
| M1.16 | **[审计新增]** 时钟源初始化 (TSC + LAPIC Timer) | `arch/x86_64/tsc.zig` | ~60 | 读取 TSC 频率，校准 LAPIC Timer |
| M1.17 | **[审计新增]** QEMU GDB 调试配置 | tools/qemu_run.sh (+) | ~5 | 支持 `zig build debug` 启动 GDB stub |

### 参考代码

| 任务 | 参考来源 | 文件 |
|---|---|---|
| 串口 | Zigix | `kernel/arch/x86_64/serial.zig` |
| HHDM | Zigix | `kernel/mm/hhdm.zig` |
| GDT/IDT | Zigix | `kernel/arch/x86_64/gdt.zig`, `idt.zig` |
| Boot info | Zigix | `kernel/boot_info.zig` |
| Panic | Zigix | `kernel/main.zig` (panic handler) |
| **ACPI 解析** | Zigix | `kernel/acpi/acpi_parser.zig` (443 行) |
| **异常缓冲区** | Zigix | `kernel/arch/x86_64/exception.zig` |

### 缺陷检查

- [x] Limine 协议已有成熟实现，不需要自己写 UEFI bootloader
- [ ] **待解决**: Limine 的 HHDM 偏移量由 bootloader 提供，内核需要正确解析 → 参考 Zigix 的 `limine.zig`
- [ ] **待解决**: IDT 的 double fault / triple fault 处理 — 需要独立 IST (Interrupt Stack Table) 防止栈溢出导致不可恢复
- [ ] **[审计新增]** ACPI RSDP 由 Limine 通过 boot info 提供 (不需要 BIOS 搜索)
- [ ] **[审计新增]** LAPIC Timer 初始化依赖 MADT 中的 LAPIC 地址 → ACPI 必须在调度器 (M3) 之前初始化
- [ ] **[审计新增]** TSC 频率校准：使用 `cpuid.0x15` (Intel) 或 PIT 测量 (AMD) → 两种路径都要支持

---

## M2: 物理内存管理 + 页表 + 同步原语 (2.5 周)

### 目标

实现物理页面分配器 (PMM) 和虚拟内存映射 (VMM)，能够分配/释放/映射物理页面。建立内核同步原语。

### 依赖关系

```
boot_info.zig (内存映射)
  → sync/irq_spinlock.zig (中断安全锁) [审计新增]
    → pmm.zig (物理页面分配，使用 IrqSpinlock)
      → paging.zig (4级页表操作)
        → vmm.zig (虚拟内存映射)
```

### 任务清单

| # | 任务 | 文件 | 行数估算 | 验证标准 |
|---|---|---|---|---|
| M2.1 | PMM — 伙伴系统分配器 | `mm/pmm.zig` | ~400 | 能分配/释放 4KB~4MB 连续物理页 (order 0-11) |
| M2.2 | PMM — PageFrame 描述符 + 引用计数 | `mm/page_frame.zig` (+) | ~80 | 每页 PageFrame 结构 + u16 ref_count |
| M2.3 | 4级页表操作 | `arch/x86_64/paging.zig` | ~250 | map/unmap/protect 页面 |
| M2.4 | 内核地址空间管理 | `mm/addr_space.zig` | ~150 | 内核 HHDM + 模块映射 |
| M2.5 | 内核堆 — Slab 分配器 | `mm/slab.zig` | ~300 | 预定义 6 种大小类别，内核 kmalloc/kfree |
| M2.6 | 页表刷新优化 | `arch/x86_64/paging.zig` (+) | ~30 | 使用 invlpg 单页刷新 |
| M2.7 | **[审计新增]** IrqSpinlock — 中断安全自旋锁 | `sync/irq_spinlock.zig` | ~48 | cli+xchg+pause+sti，PMM 使用 |
| M2.8 | **[审计新增]** TicketSpinlock — 公平自旋锁 | `sync/ticket_spinlock.zig` | ~60 | 原子 fetch_add，SMP 公平性 |
| M2.9 | **[审计新增]** DMA 缓冲区管理基础 | `mm/dma.zig` | ~300 | allocCoherent + mapSingle + IOMMU 预留 |

### 关键设计决策

**PMM 策略**: 采用伙伴系统 (详细设计见 §19.1)，支持 order 0-11：

```zig
// 物理页面分配器 (伙伴系统)
pub fn alloc(order: u6) ?PhysAddr;    // 分配 2^order 个连续物理页
pub fn free(addr: PhysAddr, order: u6) void;
pub fn allocPage() ?PhysAddr;         // 便捷: 分配单个 4KB 页
pub fn addRef(addr: PhysAddr) void;   // CoW 引用计数 +1
pub fn decRef(addr: PhysAddr) u16;    // 引用计数 -1，返回新值
```

**Slab 分配器**: 内核堆使用 slab (详细设计见 §19.1.2)，6 种预定义大小：

```zig
pub fn kmalloc(size: usize) ?*anyopaque;
pub fn kfree(ptr: *anyopaque) void;
pub fn krealloc(ptr: *anyopaque, new_size: usize) ?*anyopaque;
```

### 参考代码

| 任务 | 参考来源 | 文件 |
|---|---|---|
| PMM | Zigix | `kernel/mm/pmm.zig` (858 行) |
| 页表 | Zigix | `kernel/mm/vmm.zig` + `arch/x86_64/paging.zig` |
| HHDM | Zigix | `kernel/mm/hhdm.zig` |
| **IrqSpinlock** | Zigix | `kernel/spinlock.zig` (48 行) |
| **TicketSpinlock** | Linux | `kernel/locking/ticket_lock.c` (参考实现) |

### 缺陷检查

- [x] 位图 PMM 简单可靠，Zigix 已验证
- [ ] **待解决**: PMM 位图本身占用的物理内存需要在初始化时从可用内存区域中预留 → 参考 Zigix 的 `pmm.init()` 遍历两次内存映射
- [ ] **待解决**: slab 分配器需要 PMM 先初始化 → 初始化顺序：IrqSpinlock → PMM → slab → 其他
- [x] **[审计修正]** PMM 的 SMP 安全性 → M2 阶段即引入 IrqSpinlock 保护 PMM，单核时 cli/sti 仍提供中断安全
- [ ] **[审计新增]** M11 SMP 时 IrqSpinlock 需要升级为 TicketSpinlock 以保证公平性

---

## M3: 调度器 + 上下文切换 (2 周)

### 目标

实现内核线程调度，至少两个内核线程能交替执行。

### 依赖关系

```
pmm.zig (分配内核栈)
  → task.zig (任务结构体)
    → context_switch.s (汇编上下文切换)
      → sched.zig (调度器)
        → timer.zig (时钟中断驱动调度)
```

### 任务清单

| # | 任务 | 文件 | 行数估算 | 验证标准 |
|---|---|---|---|---|
| M3.1 | 任务结构体定义 | `task.zig` | ~80 | Task struct 包含状态、上下文、栈 |
| M3.2 | 上下文保存/恢复 (汇编) | `arch/x86_64/context_switch.s` | ~60 | swapContext(old, new) 正确保存/恢复寄存器 |
| M3.3 | 时钟中断 (PIT → APIC Timer) | `timer.zig` + `arch/x86_64/lapic.zig` | ~150 | 每 10ms 触发一次 tick |
| M3.4 | 调度器 — Round-Robin | `sched.zig` | ~200 | 两个内核线程交替打印字符 |
| M3.5 | 调度器 — 优先级队列 | `sched.zig` (+) | ~80 | 高优先级任务先运行 |
| M3.6 | 任务创建/销毁 API | `task.zig` (+) | ~100 | createKernelThread(fn) 创建并调度 |

### 关键设计决策

**初始调度策略**: 先实现 Round-Robin (时间片轮转)，验证上下文切换正确性。后续增加优先级队列和 CFS。

**上下文切换帧**:

```zig
pub const Context = extern struct {
    r15: u64, r14: u64, r13: u64, r12: u64,
    r11: u64, r10: u64, r9: u64, r8: u64,
    rbp: u64, rdi: u64, rsi: u64, rdx: u64,
    rcx: u64, rbx: u64, rax: u64,
    rip: u64, cs: u64, rflags: u64, rsp: u64, ss: u64,
};
```

### 参考代码

| 任务 | 参考来源 | 文件 |
|---|---|---|
| 进程结构 | Zigix | `kernel/proc/process.zig` (Context 结构) |
| 调度器 | Zigix | `kernel/proc/scheduler.zig` |
| APIC Timer | Zigix | `kernel/arch/x86_64/lapic.zig` |

### 缺陷检查

- [x] Context 结构可以复用 Zigix 的设计
- [ ] **待解决**: 内核线程的栈大小 — 建议 4 个页面 (16KB)，与 Zigix 的 64 页面 (256KB) 相比更节省
- [x] **[审计修正]** APIC Timer 初始化时机 — 需要 APIC 先初始化，APIC 又需要 ACPI 表 → ACPI 已在 M1 (M1.11) 中完成 MADT 解析，LAPIC 地址已知
- [ ] **待解决**: 第一个内核线程如何启动 — entry.s 中创建 init_task，第一次调度时通过 iretq 跳到内核线程入口
- [ ] **[审计新增]** 时钟源选择: x86_64 用 TSC (纳秒级单调时钟) + LAPIC Timer (驱动 tick)；AArch64 用 Generic Timer (CNTVCT_EL0)。TSC 校准已在 M1.16 完成。

---

## M4: IPC 引擎 + 死锁预防 (3.5 周) ← 微内核核心

### 目标

实现进程间消息传递 (send/receive/call/reply/notify)，两个用户空间进程能通过 IPC 通信。

### 依赖关系

```
sched.zig (调度器)
  → ipc.zig (IPC 引擎核心)
    → capability.zig (能力检查)
      → syscall_entry.zig (系统调用入口 → IPC 路由)
```

### 任务清单

| # | 任务 | 文件 | 行数估算 | 验证标准 |
|---|---|---|---|---|
| M4.1 | IPC 消息结构定义 | `ipc.zig` (消息部分) | ~80 | 256 字节消息，cache 对齐 |
| M4.2 | Endpoint 管理 | `ipc.zig` (端点部分) | ~120 | 每个服务有唯一 endpoint ID |
| M4.3 | send/receive 实现 (阻塞) | `ipc.zig` (核心) | ~250 | 进程 A send，进程 B receive，消息正确传递 |
| M4.4 | call/reply 实现 (事务型) | `ipc.zig` (+) | ~150 | call = send + 等待 reply |
| M4.5 | notify 实现 (异步通知) | `ipc.zig` (+) | ~80 | notify 不阻塞，设置位图 |
| M4.6 | 能力检查 | `capability.zig` | ~100 | IPC 需要有效 capability |
| M4.7 | 系统调用入口 (汇编) | `arch/x86_64/syscall_entry.zig` + `.s` | ~120 | syscall 指令 → 保存寄存器 → 内核处理 |
| M4.8 | ABI 路由 (personality 分发) | `syscall_entry.zig` (+) | ~60 | 根据进程 personality 转发到对应 Personality Server |
| M4.9 | **[审计新增]** IPC 死锁预防 | `ipc.zig` (死锁检测部分) | ~100 | 调用深度限制 8 层 + 超时 30s + 禁止自调用 + 循环检测 |

### 关键设计：ABI 路由修正

**设计文档缺陷 D1 修正**：x86_64 的 `syscall` 指令**只使用 `IA32_LSTAR` MSR**。不存在 "Linux 走 LSTAR, Windows 走 CSTAR" 的方案。

**正确方案**：

```
所有 syscall 都进入 LSTAR 入口:
  1. 汇编保存寄存器到当前 task 的上下文
  2. 从内核 task 结构读取 current_task.personality
  3. 根据 personality 构造不同的 IPC 消息:
     - .linux    → 转发到 LinuxPers endpoint
     - .windows  → 转发到 WinPers endpoint
     - .native   → 直接处理 (内核 IPC)
  4. 调用 ipc.call(personality_endpoint, &msg)
  5. 等待 reply → 将结果写入寄存器 → sysretq
```

这样做的优点：
- 只需要一个 syscall 入口点
- Personality 切换只需要改进程的 `personality` 字段
- 未来添加新 ABI 类型只需要加新的 Personality Server

### 关键设计：共享内存通道

为大数据传输优化的零拷贝通道：

```zig
pub const ShmChannel = struct {
    sender_pid: TaskId,
    receiver_pid: TaskId,
    vaddr: u64,          // 发送方虚拟地址
    size: u64,            // 共享区域大小
    page_count: u64,
    // 在接收方地址空间映射相同物理页面
};
```

### 参考代码

| 任务 | 参考来源 | 文件 |
|---|---|---|
| IPC send/recv | MINIX 3 | `kernel/proc.c` (mini_send, mini_receive) |
| IPC 消息结构 | MINIX 3 | `include/minix/ipc.h` (message 联合体) |
| syscall 入口 | Zigix | `kernel/arch/x86_64/syscall_entry.zig` |

### 缺陷检查

- [ ] **关键**: IPC send 阻塞时，发送方进程需要被移出调度队列，直到接收方调用 receive → 需要等待队列管理
- [x] **[审计修正]** call/reply 的死锁检测 — 如果 A call B，B call A，死锁 → M4.9 实现调用链跟踪 + 深度限制 + 超时机制
- [ ] **关键**: notify 的位图需要在 task 结构中预留 ~64 bit → 对应 64 种通知类型
- [ ] IPC 性能基线 — 需要在 M4 结束时测量：单次 IPC 往返延迟 < 1μs (QEMU)
- [ ] **syscall 入口需要 swapgs** — 进入内核时 `swapgs` 获取内核 GS base，退出时 `swapgs` 恢复用户 GS base

---

## M5: 用户空间进程 + 基础服务 + OOM (3.5 周)

### 目标

能从 ramdisk 加载并运行用户空间程序，Init 服务启动。

### 依赖关系

```
ipc.zig (IPC 可用)
  → user_mode.zig (用户态切换)
    → init 服务 (PID 1)
      → pm 服务 (进程管理)
```

### 任务清单

| # | 任务 | 文件 | 行数估算 | 验证标准 |
|---|---|---|---|---|
| M5.1 | 用户态切换 (iretq) | `arch/x86_64/user_mode.zig` | ~100 | 内核跳转到 ring3 执行代码 |
| M5.2 | 用户空间地址空间创建 | `mm/user_space.zig` | ~150 | 为用户进程创建独立 PML4 |
| M5.3 | ramdisk 文件系统 | `fs/ramfs.zig` | ~200 | 从内核映像尾部加载 ramdisk |
| M5.4 | 简单程序加载器 (硬编码) | `loader.zig` (临时) | ~100 | 将 ramdisk 中的二进制映射到用户空间 |
| M5.5 | Init 服务 | `servers/init/main.zig` | ~100 | Init 启动，打印 "Init started" |
| M5.6 | PM 服务骨架 | `servers/pm/main.zig` | ~150 | PM 能创建/销毁进程 |
| M5.7 | 系统调用 — 通过 IPC | `servers/pm/syscall.zig` | ~100 | 用户程序通过 syscall → IPC → PM 完成 getpid() |
| M5.8 | **[审计新增]** VMM OOM 水位管理 | `servers/vmm/oom.zig` | ~150 | 高水位 85% 警告 → 释放页缓存；紧急水位 95% → SIGKILL |
| M5.9 | **[审计新增]** 内核熵源收集 | `kernel/entropy.zig` | ~100 | RDRAND/RDTSC + 简化 Fortuna pool |
| M5.10 | **[审计新增]** MoQiOS libc 最小子集 (设计) | `lib/moqi_libc/` | ~50 | 定义 ~50 函数范围: malloc, printf, string, memcpy |
| M5.11 | **[审计新增]** Init 服务依赖排序 | `servers/init/deps.zig` | ~80 | 按依赖拓扑启动: VMM → PM → VFS → DevMgr → LinuxPers |
| M5.12 | **[审计新增]** 管道 (pipe) 内核对象 | `kernel/pipe.zig` | ~300 | sys_pipe2 + 环形缓冲区 + 阻塞/唤醒 (§21.1) |

### 关键设计：用户态切换

```asm
; 跳转到用户态执行
; rdi = 入口点地址
; rsi = 用户栈顶
global jump_to_user
jump_to_user:
    ; 设置用户数据段
    mov ax, 0x23        ; 用户数据段选择子 (GDT entry 4, DPL=3)
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax

    ; 通过 iretq 跳转到 ring3
    push 0x23           ; SS (用户栈段)
    push rsi            ; RSP (用户栈顶)
    pushfq              ; RFlags
    or [rsp], 0x200     ; 确保中断开启 (IF=1)
    push 0x1B           ; CS (用户代码段, GDT entry 3, DPL=3)
    push rdi            ; RIP (入口点)
    iretq
```

### 缺陷检查

- [ ] **关键**: 用户态程序需要至少能做一个系统调用才能输出 → 需要一个最小的 write(1, msg, len) 路径
- [ ] **关键**: ramdisk 格式需要简单 → 建议 cpio 格式 (Linux initramfs 标准) 或自定义 flat binary
- [ ] **待解决**: 用户空间的 IPC 库 (libipc) — 用户程序如何发 IPC？ → 通过 syscall 指令进入内核，内核做 IPC 路由
- [ ] **待解决**: 用户空间进程的页表需要在创建时映射内核 (用于 syscall 入口) → 共享内核页表项
- [ ] **[审计新增]** Init 服务的启动顺序至关重要: VMM 必须先于 PM (进程创建需分配内存)，PM 先于 VFS (文件操作需进程)，VFS 先于 LinuxPers (ELF 加载需文件系统)
- [ ] **[审计新增]** OOM 水位检测需要定时器回调 → VMM 需要向内核注册定时器 IPC → 内核定时器机制需要在 M3/M4 中就位
- [ ] **[审计新增]** 熵源: 初期使用 RDRAND (QEMU 可能不支持) + RDTSC 作为 fallback；后续添加 virtio-rng

---

## M6: PCI + Linux Personality — ELF + 核心 syscall (4.5 周) ← Linux 兼容 MVP

### 目标

能加载并运行静态链接的 ELF 二进制 (Hello World)，执行基本的文件 I/O。

### 依赖关系

```
M5 (用户进程 + PM)
  → PCI 扫描 (内核) → DevMgr 设备注册 [审计新增]
    → linux_pers/ (Linux Personality Server)
      → elf_loader.zig (ELF 加载)
        → syscall_dispatch.zig (syscall 翻译)
          → vfs 服务 (文件 I/O)
```

### 任务清单

| # | 任务 | 文件 | 行数估算 | 验证标准 |
|---|---|---|---|---|
| M6.0a | **[审计新增]** PCI 配置空间访问 (0xCF8/0xCFC I/O 端口) | `kernel/drivers/pci.zig` | ~80 | 能读取 PCI vendor/device ID |
| M6.0b | **[审计新增]** PCI 总线扫描 + 设备列表 | `kernel/drivers/pci.zig` (+) | ~100 | 枚举 QEMU 中所有 PCI 设备 |
| M6.0c | **[审计新增]** PCI BAR 解析 + MMIO 映射 | `kernel/drivers/pci.zig` (+) | ~60 | 解析 virtio 设备的 BAR 空间 |
| M6.0d | **[审计新增]** PCIe ECAM 支持 (可选，MCFG 基地址) | `kernel/drivers/pci.zig` (+) | ~40 | 使用 ECAM 访问 PCI 配置空间 |
| M6.1 | ELF64 类型定义 | `lib/elf_types/elf.zig` | ~120 | extern struct: Elf64Header, Elf64Phdr, Elf64Shdr |
| M6.2 | ELF 加载器 — 静态 PIE/非 PIE | `servers/linux_pers/elf_loader.zig` | ~400 | 能加载 Hello World ELF |
| M6.3 | ELF 加载器 — 设置用户栈 (argc/argv/envp/auxv) | `servers/linux_pers/elf_loader.zig` (+) | ~150 | argv 正确传递 |
| M6.4 | Linux syscall 分发表 | `servers/linux_pers/syscall_dispatch.zig` | ~200 | syscall number → handler 映射 |
| M6.5 | 核心 I/O syscall: read/write/open/close | `servers/linux_pers/sys_io.zig` | ~200 | 能读写文件 |
| M6.6 | 进程 syscall: getpid/exit/exit_group | `servers/linux_pers/sys_proc.zig` | ~80 | 进程能退出 |
| M6.7 | 内存 syscall: brk/mmap/munmap | `servers/linux_pers/sys_mem.zig` | ~200 | 程序能分配内存 |
| M6.8 | Linux Personality 主循环 | `servers/linux_pers/main.zig` | ~100 | 接收 IPC 消息，分发到 syscall handler |
| M6.9 | VFS 服务骨架 | `servers/vfs/main.zig` | ~200 | 能打开/读取 ramdisk 中的文件 |

### 关键设计：Linux syscall 在微内核中的路径

```
用户程序执行 write(1, "hello\n", 6):
  1. libc 将参数放入寄存器: rax=1, rdi=1, rsi="hello", rdx=6
  2. syscall 指令 → LSTAR → 内核入口
  3. 内核读取 current_task.personality == .linux
  4. 构造 IPC 消息: {type=SYSCALL, syscall_nr=1, args=[1, "hello", 6]}
  5. ipc.call(linux_pers_endpoint, &msg)
  6. LinuxPers 接收，查找 table[1] = sysWrite
  7. sysWrite 需要做 I/O → ipc.call(vfs_endpoint, &vfs_msg)
  8. VFS 执行写操作 → reply 给 LinuxPers
  9. LinuxPers 构造返回值 → reply 给内核
  10. 内核将返回值写入 rax → sysretq

IPC 往返次数: 2 次 (user→linux_pers, linux_pers→vfs)
```

**性能优化考虑**: 对于简单的 syscall (如 getpid)，LinuxPers 可以直接回复而不需要转发到其他服务。

### 参考代码

| 任务 | 参考来源 | 文件 |
|---|---|---|
| ELF 加载器 | Zigix | `kernel/proc/elf.zig` (240行) + `execve.zig` (788行) |
| syscall 分发 | Zigix | `kernel/proc/syscall_table.zig` |
| read/write | Zigix | `kernel/proc/syscall.zig` |
| mmap/brk | Zigix | `kernel/mm/mmap.zig` |
| **PCI 扫描** | Zigix | `kernel/drivers/pci.zig` (276 行) |

### 缺陷检查

- [ ] **关键**: execve 在微内核中更复杂 — 需要销毁旧地址空间、创建新地址空间、映射 ELF → 需要 PM + VMM 协同
- [ ] **关键**: ELF 加载器的 "demand paging" 策略 — Personality 服务不在内核中，无法直接处理缺页 → 初期直接加载全部 PT_LOAD 段到内存 (eager loading)，后续优化为 demand paging
- [ ] **待解决**: 静态链接 ELF 需要什么 musl 版本？ → 建议先用最简单的静态编译 `zig cc -target x86_64-linux-musl -static`
- [ ] **待解决**: write(stdout) 的数据最终去哪？ → 初期走 serial 输出，后续走 console 驱动
- [ ] **[审计新增]** PCI 扫描必须在驱动加载之前完成 → M6.0a-d 优先于 M6.9 (VFS 骨架中的 virtio-blk 初始化)
- [ ] **[审计新增]** PCIe ECAM 需要 ACPI MCFG 表 (已在 M1.12 解析) → ECAM 基地址从 MCFG 获取

---

## M7: VFS + ext4 只读 (3 周)

### 目标

实现虚拟文件系统层，挂载 ext4 只读文件系统，能从真实磁盘读取文件。

### 依赖关系

```
M6 (VFS 骨架)
  → vfs/ 完善 (inode, dentry, page cache)
    → fs/ext4/ (ext4 只读驱动)
      → drivers/block/virtio_blk (块设备驱动)
```

### 任务清单

| # | 任务 | 文件 | 行数估算 | 验证标准 |
|---|---|---|---|---|
| M7.1 | VFS inode + dentry 缓存 | `servers/vfs/inode.zig` | ~300 | inode 分配、查找、缓存命中 |
| M7.2 | VFS 挂载点管理 | `servers/vfs/mount.zig` | ~150 | 能挂载/卸载文件系统 |
| M7.3 | VFS 文件描述符管理 | `servers/vfs/fd_table.zig` | ~150 | open 返回 fd，read/write 通过 fd 操作 |
| M7.4 | 页缓存 (page cache) | `servers/vfs/page_cache.zig` | ~200 | 重复读取同一文件命中缓存 |
| M7.5 | ext4 超级块 + 块组描述符解析 | `servers/vfs/ext4/super.zig` | ~200 | 能解析 ext4 超级块 |
| M7.6 | ext4 inode 读取 | `servers/vfs/ext4/inode.zig` | ~250 | 能读取文件 inode |
| M7.7 | ext4 目录项解析 | `servers/vfs/ext4/dir.zig` | ~150 | 能列出目录内容 |
| M7.8 | ext4 extent tree 读取 | `servers/vfs/ext4/extents.zig` | ~200 | 能读取大文件数据块 |
| M7.9 | virtio-blk 块设备驱动 | `drivers/block/virtio_blk/main.zig` | ~300 | QEMU 中能读写 virtio 磁盘 |
| M7.10 | DevMgr 服务骨架 | `servers/devmgr/main.zig` | ~200 | 能加载驱动、注册设备 |
| M7.11 | **[审计新增]** Bio 层 + Buffer Cache | `servers/vfs/bio.zig`, `buffer_cache.zig` | ~450 | 块 I/O 描述 + 块级缓存 (§19.3) |
| M7.12 | **[审计新增]** I/O 调度器 (电梯合并) | `servers/vfs/io_sched.zig` | ~150 | 合并相邻扇区请求，减少磁盘寻道 |

### 参考代码

| 任务 | 参考来源 | 文件 |
|---|---|---|
| VFS | Zigix | `kernel/fs/vfs.zig` + `kernel/fs/ext2.zig` |
| ext4 extents | Zigix | `kernel/fs/ext4/extents.zig` |
| virtio-blk | Zigix | `kernel/drivers/virtio_blk.zig` |
| 驱动框架 | MINIX 3 | `drivers/libdriver/driver.c` |

### 缺陷检查

- [ ] **关键**: VFS 作为用户空间服务，所有磁盘 I/O 需要通过 IPC → virtio-blk 驱动也是用户空间，需要两次 IPC (VFS → DevMgr → 驱动) → 需要优化
- [ ] **关键**: 页缓存在用户空间实现 — 需要共享内存机制让多个服务共享缓存页面
- [ ] **待解决**: ext4 只读不需要日志，但如果后续要写，日志是必须的 → Phase 2 再考虑
- [ ] **待解决**: 块大小 — ext4 支持 1K/4K 块，需要正确解析
- [ ] **优化**: VFS → 驱动可以减少一次 IPC，让 VFS 直接与驱动通信 (通过 capability 授权)

---

## M8: 伪文件系统 + PTY + Linux 完整 syscall (5 周) ← BusyBox 可运行

### 目标

覆盖足够的 Linux syscall，使 BusyBox 1.36 能完整运行 (Zigix 已达 10/10 测试)。

### 依赖关系

```
M6 (核心 syscall) + M7 (VFS)
  → devfs/tmpfs/procfs/devpts (伪文件系统) [审计新增]
    → fork/clone/execve
      → signal
        → pipe/fifo
          → 完整 syscall 集
```

### 任务清单

| # | 任务 | 文件 | 行数估算 | 验证标准 |
|---|---|---|---|---|
| M8.1 | **[审计新增]** devfs — 设备文件系统 | `servers/vfs/devfs.zig` | ~236 | /dev/null, /dev/zero, /dev/urandom, /dev/console 可访问 |
| M8.2 | **[审计新增]** tmpfs — 内存文件系统 | `servers/vfs/tmpfs.zig` | ~400 | /tmp, /run 可创建/写入/删除文件 |
| M8.3 | **[审计新增]** procfs — 进程信息文件系统 | `servers/vfs/procfs.zig` | ~200 | /proc/self, /proc/cpuinfo, /proc/meminfo 可读取 |
| M8.4 | **[审计新增]** devpts — 伪终端设备 | `servers/vfs/devpts.zig` | ~100 | /dev/pts/0-7 设备节点创建 |
| M8.5 | **[审计新增]** TTY 服务骨架 | `servers/ttyd/main.zig` | ~80 | TTY 守护进程启动，接收键盘 IPC |
| M8.6 | **[审计新增]** PTY master/slave 管理 | `servers/ttyd/pty.zig` | ~200 | openpty() 创建 PTY 对，shell 能读写 |
| M8.7 | **[审计新增]** 行规范处理 (Line Discipline) | `servers/ttyd/line_discipline.zig` | ~150 | 回显、退格、行缓冲、Ctrl+C → SIGINT |
| M8.8 | fork/clone 实现 | `servers/linux_pers/clone.zig` | ~300 | fork() 返回两次，子进程是父进程的 CoW 副本 |
| M8.9 | execve 完善 | `servers/linux_pers/execve.zig` | ~400 | execve 替换进程映像，支持 shebang |
| M8.10 | wait4/waitpid | `servers/linux_pers/sys_proc.zig` (+) | ~100 | 父进程能等待子进程退出 |
| M8.11 | 信号投递 (sigaction/sigreturn) | `servers/linux_pers/signal.zig` | ~300 | 能捕获 SIGINT、忽略 SIGPIPE |
| M8.12 | pipe/fifo | `servers/linux_pers/pipe.zig` | ~200 | 能创建管道并通信 |
| M8.13 | 文件系统 syscall (mkdir/unlink/stat/lseek) | `servers/linux_pers/sys_fs.zig` | ~200 | 能操作目录和文件 |
| M8.14 | dup2/dup3/close | `servers/linux_pers/sys_fd.zig` | ~80 | 文件描述符复制 |
| M8.15 | ioctl (基础) | `servers/linux_pers/sys_ioctl.zig` | ~100 | TCGETS/TCSETS (终端控制) |
| M8.16 | futex (基础) | `servers/linux_pers/futex.zig` | ~200 | FUTEX_WAIT/WAKE 能工作 |
| M8.17 | gettimeofday/clock_gettime | `servers/linux_pers/sys_time.zig` | ~80 | 能获取时间 |
| M8.18 | **[审计新增]** epoll 基础实现 | `servers/linux_pers/epoll.zig` | ~200 | epoll_create/epoll_ctl(ADD/DEL)/epoll_wait |
| M8.19 | **[审计新增]** Core Dump 崩溃转储 | `servers/linux_pers/coredump.zig` | ~400 | SIGSEGV → 生成 ELF core 文件 (§21.6) |
| M8.20 | **[审计新增]** syslogd 日志持久化 | `servers/syslogd/main.zig` | ~300 | klog ring buffer → /var/log/kern.log + 日志轮转 (§21.7) |
| M8.21 | BusyBox 集成测试 | — | — | BusyBox 的 ls, cat, sh, cp 能工作 |

### 关键设计：fork 在微内核中的实现

fork 是最复杂的 syscall 之一，在微内核中尤其如此：

```
用户调用 fork():
  1. syscall → 内核 → IPC 到 LinuxPers
  2. LinuxPers 请求 PM 创建新进程
  3. PM 请求 VMM 创建新地址空间
  4. VMM 复制父进程页表 (CoW):
     - 标记所有可写页面为只读
     - 增加物理页面引用计数
     - 子进程共享父进程物理页面
  5. PM 在 LinuxPers 中注册新进程
  6. 子进程被调度运行
  7. 子进程写某个页面 → 缺页 → 内核 CoW → 分配新物理页面

涉及的 IPC 路径:
  LinuxPers → PM (创建进程)
  PM → VMM (创建地址空间)
  VMM → 内核 (页表操作)
```

### 参考代码

| 任务 | 参考来源 | 文件 |
|---|---|---|
| clone/fork | Zigix | `kernel/proc/clone.zig` (CoW 实现) |
| execve | Zigix | `kernel/proc/execve.zig` (788行) |
| signal | Zigix | `kernel/proc/signal.zig` |
| pipe | Zigix | `kernel/fs/pipe.zig` |
| futex | Zigix | `kernel/proc/futex.zig` |
| **devfs** | Zigix | `kernel/fs/devfs.zig` (236 行) |
| **tmpfs** | Zigix | `kernel/fs/tmpfs.zig` (~500 行) |
| **epoll** | Zigix | `kernel/proc/epoll.zig` |
| **TTY/PTY** | MINIX 3 | `drivers/tty/tty.c` (1,200+ 行完整 TTY 实现) |

### 缺陷检查

- [ ] **关键**: fork 后 CoW 缺页由谁处理？ → **内核**处理 (内核能看到 page fault，检查 ref_count > 1 → 分配新页面)。但 VMM 服务决定是否允许分配 → 内核只做"机械"操作，策略由 VMM 决定
- [ ] **关键**: 信号投递需要修改用户栈 (压入 signal frame) → LinuxPers 需要能写入用户进程的地址空间 → 需要内核提供 "write_user_memory" IPC 操作
- [ ] **关键**: BusyBox 的 `sh` 需要能 fork + exec + pipe → 这三个必须同时工作 → M8.8-M8.12 是一组，必须全部完成才能测试 sh
- [ ] **待解决**: shebang 处理 — `#!/bin/sh` 需要递归加载 → 参考 Zigix execve.zig 的 shebang 处理
- [ ] **[审计新增]** PTY 的 slave 设备需要通过 devpts 挂载 → devpts (M8.4) 必须在 PTY (M8.6) 之前就绪
- [ ] **[审计新增]** BusyBox sh 的 job control (Ctrl+C/Z) 完全依赖 TTY 服务 → M8.5-M8.7 (TTY) 必须在 BusyBox 测试 (M8.19) 之前完成
- [ ] **[审计新增]** epoll_wait 在微内核中需要等待来自 VFS/NetStack 的 IPC 通知 → 通知机制复用 IPC notify

---

## M9: Windows Personality — PE + NT 核心 API (6 周) ← Windows 兼容 MVP

### 目标

能加载并运行一个简单的 Windows PE 控制台程序 (hello.exe)。

### 依赖关系

```
M5 (用户进程 + PM + VFS)
  → win_pers/ (Windows Personality Server)
    → pe_loader.zig (PE 加载)
      → ntapi_dispatch.zig (NT API 翻译)
        → ntdll.dll (兼容实现)
```

### 任务清单

| # | 任务 | 文件 | 行数估算 | 验证标准 |
|---|---|---|---|---|
| M9.1 | PE/COFF 类型定义 | `lib/pe_types/pe.zig` | ~200 | IMAGE_DOS_HEADER, IMAGE_NT_HEADERS64, IMAGE_SECTION_HEADER |
| M9.2 | NT 基础类型定义 | `lib/nt_types/nt.zig` | ~300 | NTSTATUS, HANDLE, OBJECT_ATTRIBUTES, IO_STATUS_BLOCK 等 |
| M9.3 | PE 加载器 | `servers/win_pers/pe_loader.zig` | ~500 | 能加载 PE64 二进制 |
| M9.4 | PE Import Table 解析 | `servers/win_pers/pe_loader.zig` (+) | ~200 | 能解析 IAT，绑定到 ntdll 导出函数 |
| M9.5 | PE 重定位处理 | `servers/win_pers/pe_loader.zig` (+) | ~150 | ASLR 导致基址不同时能正确重定位 |
| M9.6 | TEB/PEB 设置 | `servers/win_pers/teb_peb.zig` | ~200 | 进程启动时设置 TEB (gs:0x30) 和 PEB |
| M9.7 | KUSER_SHARED_DATA 设置 | `servers/win_pers/kusd.zig` | ~100 | 映射 0x7FFE0000 页面，填入系统信息 |
| M9.8 | ntdll.dll 核心 API 实现 | `servers/win_pers/ntdll_impl.zig` | ~600 | NtCreateFile, NtReadFile, NtWriteFile, NtClose |
| M9.9 | ntdll.dll 内存 API | `servers/win_pers/ntdll_mem.zig` | ~200 | NtAllocateVirtualMemory, NtFreeVirtualMemory |
| M9.10 | ntdll.dll 进程 API | `servers/win_pers/ntdll_proc.zig` | ~200 | NtCreateProcess, NtCreateThread, NtTerminateProcess |
| M9.11 | ntdll.dll 同步 API | `servers/win_pers/ntdll_sync.zig` | ~150 | NtCreateEvent, NtWaitForSingleObject |
| M9.12 | SEH 基础支持 | `servers/win_pers/seh.zig` | ~300 | __try/__except 能捕获异常 |
| M9.13 | NT 路径解析 | `servers/win_pers/path.zig` | ~100 | `\??\C:\` → 内部 VFS 路径 |
| M9.14 | Windows Personality 主循环 | `servers/win_pers/main.zig` | ~100 | 接收 IPC，分发到 NT API handler |
| M9.15 | 简单 PE 测试程序 | `tests/hello_pe/` | ~50 | 一个调用 NtWriteFile 的 hello.exe 能运行 |

### 关键设计：ntdll.dll 实现策略修正

**缺陷 D5 修正**: ntdll.dll 是 Windows 应用直接链接的 DLL，必须完美匹配 Windows PE ABI (调用约定、结构体布局、SEH unwind info)。用 Zig 编译 DLL 有以下问题：
- Zig 的 Windows ABI 支持有限
- SEH unwind info 需要特殊的 .pdata/.xdata 段
- DLL 入口点 DllMain 的调用约定

**修正方案**:

```
方案: 分层实现

1. ntdll.dll (C + ASM 编译)
   - 极薄的桩函数 (stub)
   - 每个函数只做一件事: 将调用参数打包，通过 MoQiOS syscall 发送到 WinPers
   - 使用标准 Windows 调用约定 (__fastcall / __vectorcall)
   - 约 2,000 行 C 代码

2. WinPers 服务 (Zig 实现)
   - 接收来自 ntdll.dll 的 IPC 消息
   - 解析 Nt* API 语义
   - 转发到 VFS/PM/VMM 等系统服务
   - 约 3,000 行 Zig 代码

好处:
- ntdll.dll 的 ABI 兼容性由 C 编译器保证
- WinPers 的逻辑用 Zig 编写，享受类型安全和 comptime
- 测试时可以先用真实 Windows ntdll.dll 的桩替代
```

### 关键设计：PE 加载器流程

```
WinPers 加载 hello.exe:

1. VFS 读取 hello.exe 文件头
2. 验证 MZ 签名 → PE\0\0 签名
3. 解析 IMAGE_OPTIONAL_HEADER64:
   - ImageBase: 0x140000000 (64-bit 默认)
   - AddressOfEntryPoint: 相对 RVA
   - SizeOfImage: 总映像大小
   - DataDirectory[IMPORT]: 导入表位置
4. 请求 VMM 分配连续虚拟地址空间 (ImageBase 处)
5. 映射各 section (text, rdata, data, pdata)
6. 处理导入表:
   a. 读取 IMAGE_IMPORT_DESCRIPTOR
   b. 找到 "ntdll.dll" → 加载 ntdll.dll (MoQiOS 版)
   c. 遍历导入名称表，在 ntdll 导出表中查找函数
   d. 填充 IAT
7. 设置 TEB (分配一页，设置 gs:0x30)
8. 设置 PEB (分配一页，填充 ProcessParameters)
9. 映射 KUSER_SHARED_DATA (0x7FFE0000)
10. 设置入口点上下文
11. 通知 PM "新进程就绪"
```

### 参考代码

| 任务 | 参考来源 | 文件 |
|---|---|---|
| PE 加载 | ReactOS | `dll/ntdll/ldr/ldrpe.c` |
| NT 类型 | ReactOS | `sdk/include/xdk/` 中的头文件 |
| TEB/PEB | ReactOS | `dll/ntdll/teb.c`, `dll/ntdll/ldr/ldrinit.c` |
| SEH | ReactOS | `dll/ntdll/exception/` |
| ntdll stub | ReactOS | `dll/ntdll/` 各 Nt* 函数实现 |

### 缺陷检查

- [ ] **关键**: ntdll.dll 需要作为 PE DLL 加载到 Windows 进程空间 → 它本身需要被 PE 加载器加载 → 循环依赖？ → **解决**: ntdll.dll 由 WinPers 在进程创建时**硬映射** (不需要通过 PE 导入表解析)
- [ ] **关键**: SEH 的 .pdata/.xdata 段需要正确的 unwind info → 初期 ntdll.dll 的函数用简单的 leaf function (不需要 unwind)，异常处理通过 personality server 完成
- [ ] **关键**: Windows 的 process parameter block (RTL_USER_PROCESS_PARAMETERS) 需要正确设置 → 包含命令行、环境变量、当前目录等
- [ ] **待解决**: 测试 PE 程序怎么编译？ → 使用 Visual Studio 或 MinGW 交叉编译一个简单的 NtWriteFile 调用
- [ ] **待解决**: ntdll.dll 的导出表格式 — 需要 .edata 段正确导出所有 Nt* 函数名
- [ ] **风险**: 6 周时间紧张 — PE 加载器 + DLL 解析 + SEH + 50 个 Nt* API → 建议先只做 PE 加载 + 10 个核心 API，验证 hello.exe 能跑

---

## M10: 网络 + 驱动完善 + epoll (4.5 周) ← 生产可用

### 目标

实现 TCP/IP 网络栈，能在 QEMU 中 curl 一个网页。完善核心驱动。完成 epoll 网络优化。

### 任务清单

| # | 任务 | 文件 | 行数估算 | 验证标准 |
|---|---|---|---|---|
| M10.1 | virtio-net 网络驱动 | `drivers/net/virtio_net/main.zig` | ~400 | QEMU 中能收发网络包 |
| M10.2 | NetBuf — 网络包缓冲管理 | `servers/netstack/netbuf.zig` | ~250 | [新增] 链式零拷贝 pbuf + 固定大小池 (§19.4) |
| M10.3 | NetStack 服务骨架 | `servers/netstack/main.zig` | ~100 | 接收 IPC，分发到协议处理 |
| M10.3 | Ethernet + ARP | `servers/netstack/eth.zig` | ~150 | 能解析以太网帧 |
| M10.4 | IPv4 + ICMP | `servers/netstack/ipv4.zig` | ~200 | 能 ping |
| M10.5 | UDP | `servers/netstack/udp.zig` | ~200 | 能发送/接收 UDP 包 |
| M10.6 | TCP (基础) | `servers/netstack/tcp.zig` | ~500 | 能建立连接、发送/接收数据 |
| M10.7 | Socket API (Linux 兼容) | `servers/linux_pers/sys_socket.zig` | ~200 | socket/connect/bind/listen/accept/send/recv |
| M10.8 | DNS 解析 (基础) | `servers/netstack/dns.zig` | ~100 | 能解析域名 |
| M10.9 | 驱动框架完善 | `drivers/libdriver/` | ~300 | 统一的 init/open/close/read/write/ioctl/irq 接口 |
| M10.10 | 键盘驱动 (PS/2) | `drivers/input/keyboard/main.zig` | ~200 | 能接收键盘输入 |
| M10.11 | console 驱动 | `drivers/gpu/console/main.zig` | ~200 | VGA 文本模式 + Framebuffer 图形模式输出 |
| M10.12 | **[审计新增]** epoll + NetStack 集成 | `servers/linux_pers/epoll.zig` (+) | ~100 | epoll_wait 能感知 socket 可读/可写 |
| M10.13 | **[审计新增]** virtio-rng 熵源驱动 | `drivers/char/virtio_rng/main.zig` | ~100 | /dev/urandom 获得高质量熵 |
| M10.14 | **[审计新增]** TTY 服务信号生成完善 | `servers/ttyd/signal_gen.zig` | ~80 | 完整终端信号: SIGINT/SIGQUIT/SIGTSTP/SIGWINCH |
| M10.15 | **[审计新增]** Framebuffer console (替代 VGA) | `drivers/gpu/fb_console.zig` | ~200 | Limine GOP → 像素级文字渲染 |

### 缺陷检查

- [ ] **关键**: TCP 状态机实现复杂 — 建议参考 lwIP (Dim-Sum 已集成 lwIP 1.4.1) 而非从零实现
- [ ] **关键**: 网络驱动在中断模式下需要频繁 IPC → 建议使用轮询模式 (virtio 的 avail ring) 减少中断
- [ ] **待解决**: Socket API 是在 LinuxPers 中实现还是 NetStack 中实现？ → 建议 LinuxPers 中的 socket syscall 只做参数翻译，实际网络操作走 IPC 到 NetStack
- [ ] **待解决**: Winsock 兼容在 M10 暂不实现 → 放到后续阶段
- [ ] **[审计新增]** epoll + socket 集成: NetStack 需要在 socket 状态变化时通知 LinuxPers → 复用 IPC notify 机制
- [ ] **[审计新增]** 键盘输入 → TTY 服务的 IPC 链: 键盘驱动 → IPC → TTY → 行编辑 → PTY slave → shell → 需要完整的 IPC 通路

---

## M11: AArch64 移植 + SMP (4 周)

### 目标

将内核移植到 AArch64，启用 SMP 多核支持。

### 任务清单

| # | 任务 | 文件 | 行数估算 | 验证标准 |
|---|---|---|---|---|
| M11.1 | AArch64 汇编入口 | `arch/aarch64/entry.s` | ~80 | UEFI 启动 → 跳转到内核 |
| M11.1a | **[审计新增]** FDT 解析器 | `arch/aarch64/fdt.zig` | ~300 | 解析 CPU/memory/GIC/Timer 信息 |
| M11.2 | AArch64 MMU (页表) | `arch/aarch64/mmu.zig` | ~300 | 4级页表 (TTBR0/TTBR1) |
| M11.3 | AArch64 异常向量 | `arch/aarch64/exception.zig` | ~100 | 能捕获 synchronous IRQ/FIQ/SError |
| M11.4 | AArch64 上下文切换 | `arch/aarch64/context_switch.s` | ~60 | 能保存/恢复 ARM 寄存器 |
| M11.5 | GIC 中断控制器 | `arch/aarch64/gic.zig` | ~250 | 能接收和路由中断 |
| M11.6 | AArch64 系统调用入口 (SVC/SMC) | `arch/aarch64/syscall_entry.zig` | ~80 | SVC 指令 → 内核入口 |
| M11.7 | SMP — AP 启动 trampoline (x86_64) | `arch/x86_64/smp_trampoline.s` + `kernel/smp/ap_boot.zig` | ~300 | BSP 通过 INIT+SIPI 启动所有 AP, AP 跳转到长模式 (§21.2) |
| M11.8 | SMP — per-CPU 数据区域 | `kernel/smp/per_cpu.zig` | ~150 | GS base → PerCpuData, thisCpu()/currentTask() 宏 (§21.3) |
| M11.9 | SMP — 调度器多核安全 | `sched.zig` (+) | ~80 | per-CPU 运行队列 + 负载均衡 + 跨 CPU 唤醒 (IPI_RESCHEDULE) |
| M11.10 | SMP — IPC 锁 | `ipc.zig` (+) | ~80 | 多核安全 IPC |
| M11.11 | PCID 优化 (x86_64) | `arch/x86_64/paging.zig` (+) | ~50 | 减少上下文切换时的 TLB 刷新 |

### 缺陷检查

- [ ] **关键**: AArch64 的 syscall 入口使用 SVC 指令 (不是 x86_64 的 syscall) → 需要完全不同的入口汇编
- [ ] **关键**: ARM 的页表格式与 x86_64 不同 (64 条目/table, 4KB 页, 48 位 VA) → paging.zig 需要完全重写
- [ ] **关键**: SMP 启动顺序 — x86_64 需要通过 SIPI (Startup IPI) 唤醒 AP，AArch64 通过 PSCI (Power State Coordination Interface)
- [ ] **风险**: 4 周时间同时做 AArch64 移植 + SMP 可能不够 → 建议先做 x86_64 SMP (M11.7-11.11)，AArch64 移植单独一个 Milestone
- [ ] **[审计新增]** AArch64 使用 FDT (非 ACPI) → 需要 FDT 解析器 (参考 libfdt, ~300 行)
- [ ] **[审计新增]** AArch64 GIC 版本: GICv2 (QEMU virt) vs GICv3 (真机) → 两种都要支持

---

## M12: ext4 读写 + VFS 写路径 + Swap (4 周) ← Phase 4

### 目标

实现 ext4 文件系统写支持，VFS dirty page writeback，以及 swap 到磁盘。使系统具备数据持久化能力。

### 依赖关系

```
M10 (网络) + M11 (SMP)
  → ext4 journal 实现
    → VFS dirty page tracking + writeback
      → swap 到磁盘
        → 系统关机 (sync + ACPI S5)
```

### 任务清单

| # | 任务 | 文件 | 行数估算 | 验证标准 |
|---|---|---|---|---|
| M12.1 | ext4 日志系统 (JBD2) | `servers/vfs/ext4/journal.zig` | ~500 | 事务提交和恢复正确 |
| M12.2 | ext4 块分配器 (block bitmap) | `servers/vfs/ext4/alloc.zig` | ~300 | 能分配和释放数据块 |
| M12.3 | ext4 inode 写入 | `servers/vfs/ext4/inode.zig` (+) | ~200 | 能修改文件大小和元数据 |
| M12.4 | ext4 目录操作 (创建/删除/重命名) | `servers/vfs/ext4/dir.zig` (+) | ~250 | 能创建和删除目录项 |
| M12.5 | ext4 文件写入 (data=ordered 模式) | `servers/vfs/ext4/write.zig` | ~300 | 文件写入后重启数据完整 |
| M12.6 | VFS dirty page tracking | `servers/vfs/page_cache.zig` (+) | ~150 | 脏页标记和定期刷写 |
| M12.7 | VFS writeback 线程 | `servers/vfs/writeback.zig` | ~150 | 后台定期将脏页写入磁盘 |
| M12.8 | VFS sync/fsync 实现 | `servers/vfs/sync.zig` | ~80 | sync 命令能刷写所有脏页 |
| M12.9 | Swap 到磁盘 | `servers/vmm/swap.zig` | ~300 | 物理内存不足时能换出页面 |
| M12.10 | **[审计新增]** LRU 页面置换 | `servers/vmm/lru.zig` | ~300 | 双链表 Active/Inactive LRU (§19.2) |
| M12.11 | **[审计新增]** kswapd 后台回收 | `servers/vmm/kswapd.zig` | ~250 | 水位线触发 + 后台页面回收守护 |
| M12.12 | 系统关机/重启流程 | `servers/init/shutdown.zig` | ~120 | shutdown (S5) + reboot (ACPI Reset + 三重回退) (§21.4) |
| M12.13 | 共享内存 API | `kernel/shm.zig` | ~200 | shm_create/map/unmap/transfer |
| M12.14 | futex 完整实现 (FUTEX_REQUEUE 等) | `servers/linux_pers/futex.zig` (+) | ~150 | pthread_mutex/cond 正常工作 |

### 缺陷检查

- [ ] **关键**: ext4 日志是数据完整性的核心 — 写入顺序: data → metadata → commit block
- [ ] **关键**: VFS 写路径涉及多次 IPC (用户→VFS→ext4→驱动) — 需要优化
- [ ] **待解决**: ext4 的 data=writeback vs ordered vs journal 模式 — 初期只实现 ordered
- [ ] **风险**: ext4 日志实现复杂 — 可参考 Zigix 的 ext2 (无日志) 先行，再升级 ext4 journal

---

## M13: 电源管理 — STR/STD (3 周) [新增]

### 目标

实现完整的电源管理：S1 (Light Sleep)、S3 (STR)、S4 (STD) 三种挂起模式，带自适应策略引擎和可配置唤醒源。

### 前置条件

- M6 完成 (ACPI 解析、中断控制器)
- M7 完成 (块设备驱动、VFS)
- M12 完成 (swap 分区、关机流程)
- 所有驱动实现 DriverInterface (§18.3)

### 任务

| # | 任务 | 文件 | 行数 | 验证标准 |
|---|---|---|---|---|
| M13.1 | 内核 ACPI sleep 寄存器操作 | `kernel/pm/acpi_sleep.zig` | ~200 | 能读 FADT 中 PM1a_CNT/PM1b_CNT + DSDT _S3/_S4 方法 |
| M13.2 | 内核 CPU 状态保存/恢复 | `kernel/pm/cpu_state.zig` | ~150 | 保存/恢复 CR3/CR4/EFER/IDTR/GDTR/LAPIC |
| M13.3 | 内核挂起/恢复核心 | `kernel/pm/suspend.zig` | ~400 | S1 (HLT idle) + S3 (完整挂起/恢复流程) |
| M13.4 | 唤醒源管理 | `kernel/pm/wake_source.zig` | ~100 | 注册唤醒源 + 挂起时只使能唤醒中断 |
| M13.5 | STD 快照写入 + LZO 压缩 | `kernel/pm/hibernate.zig` | ~500 | 物理内存快照 → swap 分区 (压缩后) |
| M13.6 | STD 恢复 (冷启动检测 + 内存恢复) | `kernel/pm/hibernate.zig` (+) | ~300 | 启动时检测 swap 快照 → 恢复内存 → 跳转 |
| M13.7 | PowerMgr 服务 — 策略引擎 | `servers/powermgr/policy.zig` | ~300 | 解析 /system/power.conf TOML 配置 |
| M13.8 | PowerMgr 服务 — 挂起协调器 | `servers/powermgr/coordinator.zig` | ~400 | 两阶段提交: SUSPEND_PREPARE → SUSPEND_READY → 执行 |
| M13.9 | PowerMgr 服务 — 空闲监控 | `servers/powermgr/idle_monitor.zig` | ~150 | 空闲计时 + 电量监控 → 触发策略决策 |
| M13.10 | PowerMgr 服务 — 服务入口 | `servers/powermgr/main.zig` | ~200 | IPC 循环 + 注册到 Init |

### 验证场景

```
场景 1 (S1): 
  执行 suspend --s1 → 所有 CPU 进入 HLT → 按任意键 → 立即恢复

场景 2 (S3 STR):
  执行 suspend → PowerMgr 协调服务冻结 → 内核保存 CPU → ACPI S3
  → 按电源键 → BIOS → 内核恢复 → 服务恢复 → shell 恢复

场景 3 (S4 STD):
  执行 hibernate → PowerMgr 协调 → 内存快照写入 swap → ACPI S4/S5
  → 按电源键 → 冷启动 → Limine → 内核检测快照 → 恢复内存 → 服务恢复

场景 4 (自适应):
  配置 idle_threshold_s3=60 → 60s 无操作 → 自动进入 S3

场景 5 (取消):
  某驱动 SUSPEND_CANCEL → 挂起中止 → 系统保持 S0

场景 6 (QEMU):
  QEMU 不完全支持 ACPI S3 → 使用 S5 + STD 组合测试
```

### 缺陷检查

- [ ] **关键**: STD 恢复时不能覆盖正在执行的内核代码 → 需要先复制内核到安全区域
- [ ] **关键**: LZO 压缩后的页可能 > 原始页 → 需要处理压缩膨胀 (fallback 到不压缩)
- [ ] **待解决**: QEMU 的 ACPI S3 支持有限 → 需要真机或特定 QEMU 版本测试
- [ ] **风险**: 多驱动挂起超时 → 协调器需要超时机制 (默认 10s)
- [ ] **[设计]** CPU C-state (C1/C6) 在 S0 idle 时自动使用 — 调度器 idle 线程执行 mwait/hlt

---

## 附录 A: 内核/服务边界明细

### 内核负责 (不可委托)

| 功能 | 说明 | 触发方式 |
|---|---|---|
| 进程调度 | 选择下一个运行的 task | 时钟中断 |
| 上下文切换 | 保存/恢复寄存器 | 调度器决定切换时 |
| IPC 消息传递 | 在进程间复制消息 | syscall (send/recv) |
| 页表操作 | 创建/销毁/修改页表映射 | 服务请求 (通过 capability 检查的 IPC) |
| 中断路由 | 硬件中断 → 通知用户空间驱动 | 硬件中断 |
| 缺页处理 (CoW) | 检查 ref_count > 1，分配新页面 | CPU 缺页异常 |
| 缺页处理 (demand paging) | 从 VMM 获取页面映射信息 | CPU 缺页异常 |
| 能力检查 | IPC 授权验证 | 每次 IPC |
| 定时器 | 高精度定时，驱动调度 tick | APIC Timer / HPET |
| SMP 同步 | 自旋锁、IPI | 调度/IPC 中需要 |

### 服务负责 (用户空间)

| 功能 | 哪个服务 | 触发方式 |
|---|---|---|
| 内存分配策略 | VMM | 进程 brk/mmap |
| 文件系统 | VFS | open/read/write |
| 进程创建 (策略) | PM | fork/execve |
| ELF/PE 加载 | LinuxPers / WinPers | execve |
| 信号投递 (策略) | LinuxPers | kill/sigaction |
| SEH 分发 | WinPers | 异常时 |
| 设备管理 | DevMgr | 驱动注册 |
| 网络 | NetStack | socket API |

### 缺页处理详细流程

```
CPU 触发 #PF (Page Fault):
  │
  ├── 内核异常入口 (entry.s)
  │     保存寄存器 → 调用 pageFaultHandler()
  │
  ├── pageFaultHandler():
  │     1. 获取 fault_addr 和 error_code
  │     2. 查找 fault_addr 所属的 task
  │     3. 检查物理页面 ref_count:
  │        a. ref_count > 1 → CoW:
  │           - 分配新物理页面
  │           - 复制内容
  │           - 映射新页面 (可写)
  │           - 旧页面 ref_count -1
  │           - 刷新 TLB
  │           - 返回，继续执行
  │        b. ref_count == 1 但页面不存在 → demand paging:
  │           - IPC 通知 VMM: "进程 X 的地址 Y 缺页"
  │           - VMM 回复映射信息 (物理页面 or 文件偏移)
  │           - 内核建立映射
  │           - 返回，继续执行
  │        c. 非法访问 → IPC 通知 Personality:
  │           - Linux: 发送 SIGSEGV
  │           - Windows: 发送 EXCEPTION_ACCESS_VIOLATION
  │
  └── 恢复执行 (或终止进程)
```

**注意**: demand paging 场景 (步骤 3b) 中，内核需要**同步等待** VMM 的回复，但 VMM 是用户空间服务。这意味着内核在缺页处理中需要**临时切换**到 VMM 的上下文执行，然后再切回来。这与传统宏内核不同。

**可选优化**: 将 demand paging 信息缓存在内核中 (VMA 列表)，避免每次缺页都 IPC 到 VMM。但这会导致内核和 VMM 的状态同步问题。

---

## 附录 B: 测试策略

### 每个 Milestone 的测试要求

| Milestone | 测试标准 |
|---|---|
| M0 | `zig build` 成功 |
| M1 | QEMU 串口输出 "Hello MoQiOS" |
| M2 | 分配 1000 个页面，全部释放，再次分配成功 |
| M3 | 两个内核线程交替打印 "Thread A" / "Thread B" |
| M4 | 两个用户进程通过 IPC 传递消息，内容正确 |
| M5 | Init 服务启动，通过 IPC 向 PM 注册 |
| M6 | 静态链接的 `hello` 程序输出 "Hello from ELF" |
| M7 | 从 ext4 磁盘读取 /etc/motd 文件内容 |
| M8 | BusyBox 的 `ls`, `cat`, `sh`, `cp` 全部正常工作 |
| M9 | `hello.exe` 输出 "Hello from PE" |
| M10 | `curl http://example.com` 返回 HTML |
| M11 | 4 核 QEMU 中，top 显示 4 个 CPU 都在工作 |

### 集成测试矩阵

| 测试 | M6 | M7 | M8 | M9 | M10 |
|---|---|---|---|---|---|
| Hello World (ELF) | ✅ | | | | |
| 文件读写 | | ✅ | | | |
| fork + exec | | | ✅ | | |
| pipe + shell | | | ✅ | | |
| Hello World (PE) | | | | ✅ | |
| TCP 连接 | | | | | ✅ |
| DNS 解析 | | | | | ✅ |

---

## 附录 C: 代码量估算

| 模块 | 文件 | 行数估算 | Milestone |
|---|---|---|---|
| **内核** | | **~13,000** | |
| ├ entry.s + context_switch.s | 2 个汇编 | ~160 | M1 |
| ├ main.zig | 1 | ~200 | M1 |
| ├ boot_info.zig | 1 | ~80 | M1 |
| ├ mm/hhdm.zig | 1 | ~120 | M1 |
| ├ mm/pmm.zig | 1 | ~380 | M2 |
| ├ mm/slab.zig | 1 | ~200 | M2 |
| ├ mm/addr_space.zig | 1 | ~150 | M2 |
| ├ arch/x86_64/paging.zig | 1 | ~280 | M2 |
| ├ arch/x86_64/gdt.zig | 1 | ~80 | M1 |
| ├ arch/x86_64/idt.zig | 1 | ~150 | M1 |
| ├ arch/x86_64/serial.zig | 1 | ~60 | M1 |
| ├ arch/x86_64/vga.zig | 1 | ~80 | M1 |
| ├ arch/x86_64/lapic.zig | 1 | ~200 | M3 |
| ├ arch/x86_64/tsc.zig | **[新增]** 1 | ~60 | M1 |
| ├ arch/x86_64/exception.zig | **[新增]** 1 | ~80 | M1 |
| ├ acpi/ | **[新增]** 4 | ~460 | M1 |
| ├ drivers/pci.zig | **[新增]** 1 | ~280 | M6 |
| ├ sync/ | **[新增]** 4 | ~288 | M2 |
| ├ entropy.zig | **[新增]** 1 | ~100 | M5 |
| ├ debug/symbol_table.zig | **[新增]** 1 | ~80 | M1 |
| ├ task.zig | 1 | ~80 | M3 |
| ├ sched.zig | 1 | ~280 | M3 |
| ├ timer.zig | 1 | ~80 | M3 |
| ├ ipc.zig (含死锁检测) | 1 | ~780 | M4 |
| ├ capability.zig | 1 | ~100 | M4 |
| ├ syscall_entry.zig | 1 | ~180 | M4 |
| ├ smp.zig | 1 | ~100 | M11 |
| ├ panic.zig | 1 | ~40 | M1 |
| ├ klog.zig | 1 | ~60 | M1 |
| **lib (共享库)** | | **~820** | |
| ├ elf_types/elf.zig | 1 | ~120 | M6 |
| ├ pe_types/pe.zig | 1 | ~200 | M9 |
| ├ nt_types/nt.zig | 1 | ~300 | M9 |
| ├ moqi_libc/ | **[新增]** ~10 | ~200 | M5+ |
| **服务 (用户空间)** | | **~14,500** | |
| ├ init/ | 2 | ~180 | M5 |
| ├ pm/ | 3 | ~400 | M5 |
| ├ vfs/ (含 ext4 + 伪FS) | **[新增]** 12 | ~3,100 | M7+M8 |
| │ ├ ext4/ | 4 | ~800 | M7 |
| │ ├ **devfs.zig** | 1 | ~236 | M8 |
| │ ├ **tmpfs.zig** | 1 | ~400 | M8 |
| │ ├ **procfs.zig** | 1 | ~200 | M8 |
| │ ├ **devpts.zig** | 1 | ~100 | M8 |
| ├ vmm/ (含 OOM) | **[新增]** 4 | ~550 | M5 |
| ├ devmgr/ (含 PCI 管理) | **[新增]** 3 | ~400 | M6+M7 |
| ├ ttyd/ | **[新增]** 4 | ~510 | M8+M10 |
| │ ├ main.zig | 1 | ~80 | M8 |
| │ ├ line_discipline.zig | 1 | ~150 | M8 |
| │ ├ pty.zig | 1 | ~200 | M8 |
| │ └ signal_gen.zig | 1 | ~80 | M10 |
| ├ linux_pers/ (含 epoll) | **[新增]** 12 | ~3,000 | M6+M8 |
| │ ├ **epoll.zig** | 1 | ~300 | M8+M10 |
| ├ win_pers/ | 8 | ~3,000 | M9 |
| ├ netstack/ | 6 | ~1,600 | M10 |
| **驱动 (用户空间)** | | **~2,000** | |
| ├ libdriver/ | 2 | ~300 | M7 |
| ├ virtio_blk/ | 1 | ~300 | M7 |
| ├ virtio_net/ | 1 | ~400 | M10 |
| ├ virtio_rng/ | **[新增]** 1 | ~100 | M10 |
| ├ keyboard/ | 1 | ~200 | M10 |
| ├ console/ | 1 | ~200 | M10 |
| **ntdll.dll** | C+ASM | ~2,000 | M9 |
| **测试框架** | **[新增]** ~10 | ~800 | M0+ |
| ├ tools/test_runner/ | 3 | ~300 | M0 |
| ├ tests/ | 7 | ~500 | 持续 |
| **总计** | | **~33,120** | |

> **注**: 原始估算 ~24,000 行，第一轮审计新增 ~9,000 行，第三轮架构审查新增 ~2,000 行，第四轮电源管理新增 ~2,700 行，第五轮关键子系统补充新增 ~3,000 行。总代码量预计 ~48,000 行。

---

## 附录 D: 关键风险追踪

| # | 风险 | 影响 | 缓解 | 状态 |
|---|---|---|---|---|
| R1 | IPC 性能瓶颈导致 syscall 延迟过高 | 高 | 共享内存通道; 对 getpid 等简单 syscall 内核直接处理 | 待验证 (M4) |
| R2 | fork 的 CoW 在微内核中实现复杂 | 高 | 内核处理 CoW 页面，VMM 处理策略 | 设计完成 |
| R3 | ntdll.dll ABI 兼容性 | 高 | 用 C/ASM 编译 ntdll，Zig 写 WinPers | 设计完成 |
| R4 | SEH 完整实现难度 | 中 | 初期仅支持编译器生成的 SEH，手动 SEH 后续 | 待验证 (M9) |
| R5 | VFS 在用户空间导致额外 IPC 开销 | 中 | VFS 直接与驱动通信 (跳过 DevMgr); 页缓存减少实际 I/O | 待验证 (M7) |
| R6 | 缺页处理中内核同步等待 VMM | 中 | 内核缓存 VMA 信息，减少 IPC | 待验证 (M5) |
| R7 | BusyBox 兼容性 (需要多少 syscall) | 中 | Zigix 已验证 138 个 syscall 足够 | 参考 Zigix |
| R8 | AArch64 移植工作量 | 中 | HAL 抽象层隔离架构差异; 先完成 x86_64 | 待验证 (M11) |
| R9 | **[审计新增]** TTY/PTY IPC 链路延迟 (键盘→驱动→TTY→PTY→shell) | 中 | 减少 TTY IPC 中间层; 考虑共享内存环形缓冲区 | 待验证 (M8) |
| R10 | **[审计新增]** ACPI 解析器覆盖不全 (QEMU vs 真机差异) | 低 | 初期只解析 MADT/MCFG/FADT; 真机时按需扩展 | 设计完成 |
| R11 | **[审计新增]** OOM 误杀关键系统服务 | 高 | 系统服务标记为 "不可杀" (VMM/PM/Init); 用户进程按 oom_score 排序 | 设计完成 |
| R12 | **[审计新增]** 测试覆盖率不足 | 中 | M0 建立测试框架; 每个 Milestone 必须有测试通过标准 | 进行中 |
| R13 | **[审计新增]** USB 驱动栈复杂度 (xHCI spec 600+ 页) | 高 | Phase 4 实施; 初期用 PS/2 和 virtio 绕过 USB | 设计完成 (§18.1) |
| R14 | **[审计新增]** GPU 驱动复杂度极高 | 中 | 三阶段: 基础 fb (M10) → virtio-gpu (Phase 4) → 原生 (Phase 5+) | 设计完成 (§18.2) |
| R15 | **[审计新增]** 驱动匹配表维护成本 | 低 | 使用标准 PCI class code 匹配 (不需要枚举所有 vendor/device) | 设计完成 (§18.3) |
| R16 | **[审计新增]** 伙伴系统碎片化 (长期运行后) | 中 | 定期后台碎片整理; Slab 回收; 预留大块连续内存 | 设计完成 (§19.1) |
| R17 | **[审计新增]** DMA 安全性 (无 IOMMU 时设备可访问任意物理内存) | 中 | QEMU 环境可信; 真机阶段启用 IOMMU (VT-d/SMMU) | 设计完成 (§19.5) |
| R18 | **[审计新增]** LRU 扫描开销 (内存大时) | 低 | 水位线控制扫描频率; 只扫描 Inactive 链表尾部 | 设计完成 (§19.2) |
| R19 | **[审计新增]** QEMU ACPI S3 支持有限 | 中 | 初期测试 S4 (S5+快照恢复) + S1; S3 需真机验证 | 设计完成 (§20) |
| R20 | **[审计新增]** STD 恢复时覆盖正在执行的内核 | 高 | 先将恢复代码复制到安全区域 (固定物理页) 再执行 | 设计完成 (§20.4) |
| R21 | **[审计新增]** 多驱动挂起协调超时 | 中 | 两阶段提交 + 10s 总超时; 超时则取消或强制挂起 | 设计完成 (§20.6) |
