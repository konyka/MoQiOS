# ReactOS 架构文档

> 版本：0.4.15 | 许可：GPL-2.0 | 大小：1.2GB  
> 路径：`3rd/reactos/`  
> 在 MoQiOS 中的用途：**参考实现**（Windows NT 兼容 OS 设计、驱动模型、文件系统实现）

---

## 1. 项目概览

| 属性 | 值 |
|---|---|
| **项目名** | ReactOS |
| **描述** | 开源 Windows NT 兼容操作系统 (NT4/2000/XP/2003 兼容) |
| **版本** | 0.4.15 |
| **许可证** | GNU GPL 2.0 |
| **源码大小** | 1.2GB |
| **构建系统** | CMake (`CMakeLists.txt`) |
| **目标兼容性** | Windows Server 2003 (关注 Vista+ 未来兼容) |
| **语言** | C (主体) + 汇编 (x86/ARM) |
| **支持架构** | x86 (i386), AMD64 (部分), ARM (部分) |
| **代码规模** | ntoskrnl: 424 文件, dll/win32: 1,947 文件, sdk: 3,823 文件 |

### 1.1 顶层目录结构

```
reactos/
├── base/            # 用户空间应用程序和系统服务
│   ├── applications/  # 应用程序 (notepad, calc, mspaint 等)
│   ├── services/      # 系统服务 (rpcss, eventlog, dhcp 等)
│   ├── setup/         # 安装程序
│   ├── shell/         # Shell (explorer)
│   └── system/        # 系统工具 (cmd, regedit, smss, winlogon)
├── boot/            # 引导加载器
│   ├── freeldr/       # FreeLoader 引导管理器
│   ├── bootdata/      # 引导配置数据
│   └── bcd/           # BCD (Boot Configuration Data)
├── dll/             # DLL 实现 (Windows 兼容层)
│   ├── win32/         # Win32 API DLL (kernel32, user32, gdi32 等)
│   ├── ntdll/         # NT DLL (系统调用接口)
│   ├── cpl/           # 控制面板小程序
│   ├── shellext/      # Shell 扩展
│   ├── keyboard/      # 键盘布局
│   ├── nls/           # 本地化数据
│   ├── directx/       # DirectX
│   ├── opengl/        # OpenGL
│   └── 3rdparty/      # 第三方 DLL
├── drivers/         # 内核驱动
│   ├── filesystems/   # 文件系统驱动
│   ├── network/       # 网络驱动
│   ├── storage/       # 存储驱动
│   ├── usb/           # USB 驱动
│   ├── audio/         # 音频驱动
│   ├── video/         # 显卡驱动
│   └── wdm/           # WDM 框架
├── hal/             # 硬件抽象层
├── media/           # 媒体资源 (字体, 主题, 声音)
├── modules/         # 第三方模块 (Wine 等)
├── ntoskrnl/        # NT 内核 (核心!)
├── sdk/             # SDK (头文件, 导入库, 工具)
├── subsystems/      # 环境子系统 (Win32, POSIX, OS/2)
└── tools/           # 构建工具
```

---

## 2. 构建系统

ReactOS 使用 **CMake** 构建系统：

| 文件 | 职责 |
|---|---|
| `CMakeLists.txt` | 顶层 CMake 配置 |
| `configure.sh` / `configure.cmd` | 配置脚本 |
| `toolchain-gcc.cmake` / `toolchain-clang.cmake` | 工具链配置 |
| `PreLoad.cmake` | CMake 预加载 |
| 各子目录 `CMakeLists.txt` | 子模块构建规则 |

---

## 3. NT 内核 (ntoskrnl/)

**路径：** `ntoskrnl/` (424 个源文件)  
**职责：** Windows NT 内核执行体，实现进程管理、内存管理、I/O 管理、对象管理等

### 3.1 子目录结构

```
ntoskrnl/
├── ke/          # 内核层 (Kernel) — 调度器, 中断, APC, DPC, 线程
├── ps/          # 进程/线程管理 (Process/Thread)
├── mm/          # 内存管理 (Memory Manager)
├── io/          # I/O 管理器 (I/O Manager)
│   ├── iomgr/     # I/O 管理核心
│   └── pnpmgr/    # 即插即用管理器
├── ob/          # 对象管理器 (Object Manager)
├── ex/          # 执行体支持 (Executive) — 同步, 堆, 时间
├── se/          # 安全引用监控器 (Security)
├── cc/          # 缓存管理器 (Cache Controller)
├── cache/       # 缓存实现 (含 section/ 内存映射)
├── fsrtl/       # 文件系统运行时库
├── fstub/       # 文件系统存根
├── rtl/         # 运行时库 (RTL)
├── lpc/         # 本地过程调用 (LPC)
├── config/      # 注册表 (Configuration Manager)
├── dbgk/        # 调试框架 (Debug)
├── po/          # 电源管理 (Power)
├── wmi/         # WMI (Windows Management Instrumentation)
├── kd/          # 内核调试器 (KD)
├── kd64/        # 64-bit 内核调试器
├── kdbg/        # KDBG 调试扩展
├── inbv/        # 启动视频 (Boot Video)
├── vdm/         # 虚拟 DOS 机 (VDM)
├── vf/          # 驱动验证器 (Verifier)
├── ntkrnlmp/    # 多处理器内核支持
├── include/     # 内核内部头文件
├── tests/       # 内核测试
├── ntoskrnl.spec # 导出符号表
└── ntdll.S      # 系统调用入口 (汇编)
```

### 3.2 子系统详解

#### ke/ — 内核层

内核最底层，直接与硬件交互。

| 职责 | 说明 |
|---|---|
| **线程调度** | 优先级调度，就绪队列，上下文切换 |
| **中断处理** | IDT, ISR, IRQL 管理 |
| **APC** | 异步过程调用 (用户/内核模式) |
| **DPC** | 延迟过程调用 |
| **定时器** | 系统定时器，定时器对象 |
| **互斥/事件** | 派遣器对象 (Dispatcher Objects) |
| **异常** | 结构化异常处理 (SEH) |
| **多处理器** | CPU 集，处理器亲和性 |
| 架构特定 | `ke/amd64/`, `ke/arm/`, `ke/i386/` |

#### ps/ — 进程/线程管理

| 职责 | 说明 |
|---|---|
| **进程创建** | `NtCreateProcess`, 进程对象 |
| **线程创建** | `NtCreateThread`, 线程对象 |
| **进程退出** | 进程/线程终止 |
| **作业对象** | Job Object |
| **TOKEN** | 访问令牌管理 |

#### mm/ — 内存管理

| 职责 | 说明 |
|---|---|
| **虚拟内存** | `NtAllocateVirtualMemory`, `NtFreeVirtualMemory` |
| **页面管理** | PFN 数据库，页面文件 |
| **Section** | `NtCreateSection`, 内存映射文件 |
| **工作集** | Working Set 管理 |
| **页面保护** | PAGE_READWRITE, PAGE_EXECUTE 等 |
| **地址空间** | 用户/内核地址空间布局 |
| 架构特定 | `mm/amd64/`, `mm/arm/`, `mm/i386/`, `mm/ARM3/` |

#### io/ — I/O 管理器

| 职责 | 说明 |
|---|---|
| **IRP** | I/O 请求包管理 |
| **设备对象** | `IoCreateDevice`, 设备栈 |
| **驱动加载** | `IoLoadDriver`, 驱动映像加载 |
| **文件对象** | `NtCreateFile`, `NtReadFile`, `NtWriteFile` |
| **即插即用** | 设备枚举，资源分配 |
| **电源** | 设备电源管理 |

#### ob/ — 对象管理器

| 职责 | 说明 |
|---|---|
| **对象命名空间** | `\??`, `\Device`, `\Driver`, `\FileSystem` |
| **对象类型** | 进程、线程、事件、互斥、文件等 |
| **引用计数** | `ObReferenceObject`, `ObDereferenceObject` |
| **安全描述符** | 对象 ACL 管理 |
| **句柄表** | 进程句柄表管理 |

#### se/ — 安全引用监控器

| 职责 | 说明 |
|---|---|
| **访问检查** | `SeAccessCheck` |
| **特权** | `SeSinglePrivilegeCheck` |
| **审计** | 安全审计事件 |
| **令牌** | 访问令牌操作 |

#### ex/ — 执行体支持

| 职责 | 说明 |
|---|---|
| **同步原语** | 互斥体, 信号量, 事件, 定时器 |
| **堆管理** | `ExAllocatePool`, `ExFreePool` |
| **工作项** | `IoAllocateWorkItem` |
| **回调** | 回调对象 |
| **时间** | 系统时间管理 |
| 架构特定 | `ex/amd64/`, `ex/i386/` |

#### config/ — 注册表

| 职责 | 说明 |
|---|---|
| **配置管理** | `NtCreateKey`, `NtSetValueKey`, `NtQueryValueKey` |
| **蜂巢** | 注册表蜂巢 (hive) 管理 |
| **稳定性** | 注册表持久化 |

#### cc/ — 缓存管理器

| 职责 | 说明 |
|---|---|
| **文件缓存** | 延迟写入, 预读 |
| **BCB** | 缓冲控制块 |
| **虚拟地址映射** | 缓存区虚拟地址管理 |

#### lpc/ — 本地过程调用

| 职责 | 说明 |
|---|---|
| **LPC 端口** | `NtCreatePort`, `NtConnectPort` |
| **消息传递** | 客户端/服务器消息 |
| **回调** | LPC 回调机制 |

---

## 4. 硬件抽象层 (hal/)

**路径：** `hal/` (107 个源文件)  
**职责：** 隔离硬件差异，提供统一硬件接口

| 子目录 | 目标架构 |
|---|---|
| `halx86/` | x86 (i386) — 中断控制器, 定时器, DMA, PCI 配置空间 |
| `halarm/` | ARM — ARM 中断控制器, 定时器 |

**HAL 提供的接口：**
- 中断管理 (`HalEnableInterrupt`, `HalDisableInterrupt`)
- 定时器 (`KeQueryPerformanceCounter`)
- DMA 传输 (`HalAllocateCommonBuffer`)
- PCI 配置空间访问 (`HalGetBusData`)
- I/O 端口映射
- CMOS/RTC 访问

---

## 5. 引导加载器 (boot/)

**路径：** `boot/` (189 个源文件)

### FreeLoader

| 组件 | 说明 |
|---|---|
| `freeldr/` | FreeLoader — ReactOS 的引导管理器 |
| `bootdata/` | 引导配置 (boot.ini 风格) |
| `bcd/` | BCD (现代引导配置) |
| `rtl/` | 引导运行时库 |

**FreeLoader 功能：**
- 从 FAT/NTFS/EXT2 分区加载内核
- 支持 multiboot 协议
- VBE 显示模式设置
- 内存映射获取 (BIOS INT 15h/E820)
- ACPI 表检测

---

## 6. Win32 DLL 层 (dll/)

### 6.1 dll/win32/ — Win32 API 实现 (1,947 个源文件)

实现 Windows API 的核心 DLL：

| DLL | 职责 |
|---|---|
| `kernel32/` | Win32 基础 API (进程, 线程, 文件, 内存) |
| `user32/` | 窗口管理, 消息, 输入 |
| `gdi32/` | 图形设备接口 |
| `advapi32/` | 高级 API (注册表, 安全, 服务) |
| `comctl32/` | 通用控件 |
| `comdlg32/` | 通用对话框 |
| `shell32/` | Shell API |
| `ole32/` / `oleaut32/` | COM/OLE 自动化 |
| `msvcrt/` | C 运行时库 |
| `crypt32/` | 加密 API |
| `wininet/` | Internet API |
| `ws2_32/` | Winsock2 (网络) |
| `setupapi/` | 设备安装 API |
| `dbghelp/` | 调试帮助库 |
| `version/` | 版本信息 |
| `imm32/` | 输入法管理器 |
| `uxtheme/` | 主题引擎 |
| `atl/` | Active Template Library |
| `bcrypt/` | 加密原语 (CNG) |
| `rpcrt4/` | RPC 运行时 |
| `winspool/` | 打印后台处理 |
| `ddraw/` | DirectDraw |
| `dinput/` | DirectInput |
| `dplay/` | DirectPlay |
| `dsound/` | DirectSound |
| `opengl32/` | OpenGL |
| 还有 100+ 个 | aclui, activeds, authz, avifil32, browseui, cabinet, cfgmgr32, clusapi, credui, ... |

### 6.2 dll/ntdll/ — NT DLL (17 个源文件)

用户空间到内核的系统调用入口点：

| 子目录 | 职责 |
|---|---|
| `dispatch/` | 系统调用分发 (NtCreateFile, NtReadFile 等) |
| `rtl/` | 运行时库 (字符串, 内存, 安全) |
| `ldr/` | PE 加载器 (DLL 加载/解析) |
| `dbg/` | 调试支持 |
| `etw/` | ETW (事件跟踪) |
| `def/` | 默认实现 |
| `compat/` | 兼容性垫片 |
| `nt_0600/` | NT 6.0 (Vista) 兼容 |

---

## 7. 设备驱动 (drivers/)

### 7.1 文件系统驱动 (drivers/filesystems/)

**路径：** `drivers/filesystems/` (438 个源文件)

| 文件系统 | 路径 | 说明 |
|---|---|---|
| `fastfat` | `fastfat/` | FAT12/16/32 读写 |
| `ntfs` | `ntfs/` | NTFS (部分实现) |
| `cdfs` | `cdfs/` | ISO 9660 (CD-ROM) |
| `ext2` | `ext2/` | ext2 (Linux FS, 只读+部分写) |
| `nfs` | `nfs/` | NFS 客户端 |
| `btrfs` | `btrfs/` | Btrfs (WinBtrfs) |
| `udfs` | `udfs/` | UDF (DVD) |
| `vfatfs` | `vfatfs/` | VFAT (长文件名 FAT) |
| `msfs` | `msfs/` | Mailslot |
| `npfs` | `npfs/` | Named Pipe |
| `mup` | `mup/` | Multiple UNC Provider |
| `fs_rec` | `fs_rec/` | 文件系统识别器 |

### 7.2 网络驱动 (drivers/network/)

**路径：** `drivers/network/` (587 个源文件)

| 组件 | 路径 | 说明 |
|---|---|---|
| `tcpip` | `tcpip/` | TCP/IP 协议栈 |
| `ndis` | `ndis/` | NDIS 网络驱动接口规范 |
| `afd` | `afd/` | Ancillary Function Driver (Winsock 后端) |
| `tdi` | `tdi/` | Transport Driver Interface |
| `tdihelpers` | `tdihelpers/` | TDI 辅助库 |
| `dd` | `dd/` | 网络设备驱动 |
| `lan` | `lan/` | LAN 网络驱动 |
| `netio` | `netio/` | 网络 I/O |
| `ndisuio` | `ndisuio/` | NDIS 用户态 I/O |

### 7.3 存储驱动 (drivers/storage/)

**路径：** `drivers/storage/` (178 个源文件)

| 组件 | 说明 |
|---|---|
| ATA/IDE | IDE 控制器驱动 |
| SCSI | SCSI 端口/微型端口驱动 |
| 存储端口 | StorPort / AtaPort |
| CDROM | CD-ROM 类驱动 |
| 磁盘类 | 磁盘类驱动 |

### 7.4 其他驱动

| 类别 | 路径 | 说明 |
|---|---|---|
| USB | `drivers/usb/` | USB 主机控制器 / 设备驱动 |
| 音频 | `drivers/audio/` | 音频驱动 |
| 输入 | `drivers/input/` | 键盘/鼠标驱动 |
| 显示 | `drivers/video/` | 显卡驱动 (VBE, VGA) |
| 蓝牙 | `drivers/bluetooth/` | 蓝牙驱动 |
| ACPI | `drivers/acpi/` | ACPI 驱动 |
| 电池 | `drivers/battery/` | 电池驱动 |
| HID | `drivers/hid/` | HID 驱动 |
| WDM | `drivers/wdm/` | Windows Driver Model 框架 |
| 加密 | `drivers/crypto/` | 硬件加密驱动 |
| 并行 | `drivers/parallel/` | 并口驱动 |
| 串行 | `drivers/serial/` | 串口驱动 |
| 总线 | `drivers/bus/` | 总线驱动 (PCI, ISA, PnP) |
| 过滤器 | `drivers/filters/` | 过滤驱动 |

---

## 8. 系统服务 (base/services/)

**路径：** `base/services/` (163 个源文件)

| 服务 | 说明 |
|---|---|
| `rpcss/` | RPC 子系统 (服务控制管理器 RPC 端点) |
| `eventlog/` | 事件日志服务 |
| `dhcp` | `dhcpcsvc/` DHCP 客户端 |
| `dnsrslvr/` | DNS 解析器 |
| `svchost/` | 服务宿主进程 |
| `audiosrv/` | 音频服务 |
| `browser/` | 浏览器服务 |
| `netlogon/` | 网络登录服务 |
| `seclogon/` | 辅助登录服务 |
| `schedsvc/` | 任务计划服务 |
| `srvsvc/` | 服务器服务 |
| `tcpsvcs/` | TCP 服务 |
| `umpnpmgr/` | 即插即用管理器 |
| `w32time/` | Windows 时间服务 |
| `telnetd/` | Telnet 服务端 |
| `tftpd/` | TFTP 服务端 |
| `dcomlaunch/` | DCOM 启动服务 |
| `nfsd/` | NFS 守护进程 |
| `shsvcs/` | Shell 服务 |

---

## 9. 系统工具 (base/system/)

**路径：** `base/system/` (112 个源文件)

| 工具 | 说明 |
|---|---|
| `smss/` | 会话管理器子系统 (SMSS) — 启动第一个用户进程 |
| `winlogon/` | Windows 登录 |
| `lsass/` | 本地安全授权子系统 |
| `services/` | 服务控制管理器 (SCM) |
| `logonui/` | 登录 UI |
| `userinit/` | 用户初始化 |
| `cmd/` | 命令提示符 |
| `format/` | 磁盘格式化 |
| `chkdsk/` | 磁盘检查 |
| `diskpart/` | 磁盘分区 |
| `expand/` | 文件解压 |
| `subst/` | 驱动器替换 |
| `autochk/` | 自动磁盘检查 |
| `dllhost/` | COM+ 宿主 |
| `msiexec/` | Windows Installer |
| `regsvr32/` | DLL 注册 |
| `rundll32/` | DLL 运行 |
| `bootok/` | 引导验证 |

---

## 10. 环境子系统 (subsystems/)

**路径：** `subsystems/` (127 个源文件)

| 子系统 | 路径 | 说明 |
|---|---|---|
| **Win32** | `subsystems/win/` | Windows 32-bit 子系统 (CSRSS + Win32k) |
| **POSIX** | `subsystems/mvdm/` | VDM (虚拟 DOS 机) |
| **OS/2** | — | OS/2 兼容 (部分) |
| `csr/` | `subsystems/csr/` | 客户端-服务器运行时子系统 (CSRSS) |

### Win32 子系统架构

```
┌─────────────────────────────────────────────┐
│              用户空间                         │
│  ┌─────────┐  ┌─────────┐  ┌──────────┐    │
│  │ user32  │  │ gdi32   │  │kernel32  │    │
│  │窗口/消息│  │ 图形    │  │ 进程/文件│    │
│  └────┬────┘  └────┬────┘  └────┬─────┘    │
│       │            │            │           │
│       ▼            ▼            ▼           │
│  ┌─────────────────────────────────┐        │
│  │           ntdll.dll             │        │
│  │       (系统调用入口)             │        │
│  └─────────────┬───────────────────┘        │
├────────────────┼────────────────────────────┤
│                ▼  syscall                    │
│  ┌─────────────────────────────────────────┐│
│  │           ntoskrnl.exe                  ││
│  │  ┌──────┐ ┌────┐ ┌────┐ ┌────┐        ││
│  │  │  Ps  │ │ Mm │ │ Io │ │ Ob │ ...    ││
│  │  └──────┘ └────┘ └────┘ └────┘        ││
│  └─────────────────────────────────────────┘│
│  ┌─────────────────────────────────────────┐│
│  │             hal.dll                     ││
│  └─────────────────────────────────────────┘│
└─────────────────────────────────────────────┘
```

---

## 11. SDK (sdk/)

**路径：** `sdk/` (3,823 个源文件)  
**职责：** 头文件、导入库、构建工具

| 子目录 | 说明 |
|---|---|
| `include/` | Windows API 头文件 (ddk, ndk, psdk, reactos) |
| `lib/` | 导入库和运行时库 |
| `tools/` | 构建工具 (hhpasm, mkhive 等) |

---

## 12. 模块 (modules/)

**路径：** `modules/`  
**职责：** 第三方模块集成

| 模块 | 说明 |
|---|---|
| Wine | 从 Wine 项目集成的 DLL 实现 |
| 3rd-party | 其他第三方组件 |

---

## 13. 在 MoQiOS 中的参考价值

| 领域 | 参考内容 |
|---|---|
| **NT 内核架构** | 执行体分层设计 (Ke → Ex → Ps/Mm/Io/Ob/Se) |
| **驱动模型** | WDM/NDIS 驱动框架, IRP 请求包 |
| **文件系统** | ext2/FAT/NTFS 文件系统驱动实现 |
| **网络栈** | NDIS/TDI 网络驱动接口, TCP/IP 协议栈 |
| **对象管理** | 命名空间、引用计数、安全描述符 |
| **LPC/RPC** | 进程间通信机制 |
| **DLL 兼容** | PE 加载器, DLL 解析, Win32 API 实现 |
| **注册表** | 配置管理器设计 |
