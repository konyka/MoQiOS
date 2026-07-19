# MoQiOS 构建系统与工具链

> **文档定位**: 描述 MoQiOS 的编译、链接、镜像打包与启动流程。
> **修订日期**: 2026-06-16
> **关联文档**: [moqios-architecture-current.md](./moqios-architecture-current.md)

---

## 1. 工具链概览

| 工具 | 版本 / 说明 | 用途 |
|---|---|---|
| Zig | 0.16+ | 内核编译、`zig cc` 交叉编译用户 C 程序、构建驱动（`build.zig`） |
| `zig cc` | 内置 | 编译用户态 C 程序（封装 clang） |
| LLD | 内置 (`ld.lld`) | 链接内核与用户程序 |
| `zig cc` (assembler mode) | 内置 | 汇编 `init.S`、`hello*.S`、`ap_trampoline_src.S` |
| `zig objcopy` | 内置 | 提取二进制段（用户汇编程序、trampoline 等） |
| `xorriso` | 系统包 | 生成 ISO 镜像 |
| `limine` | 仓库 `limine/` 子目录 | 安装 BIOS/UEFI 引导器 |
| QEMU (x86_64) | 系统包 | 仿真运行 |

`zig build` 是项目的**唯一**构建入口，统一管理上述步骤；不依赖额外的 `make`。

---

## 2. 构建总览

```
                    zig build
                        │
        ┌───────────────┼───────────────┬─────────────────┐
        ▼               ▼               ▼                 ▼
   编译内核      编译用户程序     编译 trampoline    打包资产
   (kernel.elf)  (hello*, sh,    (ap_trampoline.bin) (ramdisk.mrd,
                  init)                                disk.img)
        │               │               │                 │
        └───────────────┴───────────┬───┴─────────────────┘
                                    ▼
                              生成 moqios.iso
                                    │
                                    ▼
                              zig build run
                                    │
                                    ▼
                              QEMU 启动
```

---

## 3. 内核编译

### 3.1 目标三元组

```
target = .{
    .cpu_arch  = .x86_64,
    .os_tag    = .freestanding,
    .abi       = .none,
}
code_model = .kernel
```

### 3.2 关键编译选项

- 禁用 SSE/AVX：`-mno-sse -mno-mmx -mno-sse2 -mno-avx`
- 禁用红区：`-mno-red-zone`
- 启用 LTO（可选）
- `code_model = kernel`，对应高 2GB 内核镜像

### 3.3 链接

链接器：LLD，链接脚本：`kernel/linker.ld`

`linker.ld` 关键段：

```
SECTIONS {
    . = 0xFFFFFFFF80000000;
    .text   : { *(.text .text.*) }
    .rodata : { *(.rodata .rodata.*) }
    .data   : { *(.data .data.*) }
    .bss    : { *(.bss .bss.*) *(COMMON) }
    /DISCARD/ : { *(.eh_frame) *(.note.*) }
}
```

输出：`zig-out/bin/kernel.elf`

---

## 4. 用户程序编译

> 实现位置：`build.zig` 中的两个辅助函数 `addCUserProgram` / `addAsmUserProgram`，
> 分别对 `c_programs` / `asm_programs` 列表循环调用。新增用户程序时只需把程序名追加到对应
> 列表即可，无需复制整段构建步骤（2026-06 重构：从 ~900 行样板收敛至 ~160 行）。

### 4.1 C 程序（hello4–hello28, sh）

`addCUserProgram(b, name)`：用 `zig cc` 交叉编译为静态 freestanding ELF，并直接输出到
`user/<name>.bin`。这些 `.bin` 文件实际仍是 ELF，内核 loader 会自动识别 ELF/flat binary。
Windows 兼容构建路径不再依赖外部 `strip`；后续可在 CI 中按工具可用性重新启用体积优化。

```
zig cc \
    -target x86_64-freestanding-none \
    -static -nostdlib -ffreestanding -O2 \
    -Wl,--gc-sections -Wl,-z,norelro \
    -o user/<name>.bin user/<name>.c
```

注意：C 程序**不使用** `user/user.ld`，由 `zig cc` 默认链接（内置自定义 `_start`）。内核目标仍禁用
SSE；用户态 C 程序不再传 `-mno-sse/-mno-sse2`，因为 Zig 0.15.2 的 compiler-rt 在该组合下会触发
half-float SSE 返回错误。启用跨核用户任务迁移前仍需补齐 FPU/SSE 上下文保存验证。

### 4.2 汇编程序（init.S, hello2.S, hello3.S）

`addAsmUserProgram(b, name)`：`zig cc -c` 汇编为 `.o`，再用 `user/user.ld` 链接，最后
`objcopy -O binary` 生成纯二进制。

```
zig cc -target x86_64-freestanding-none -c -o user/<name>.o user/<name>.S
ld.lld -T user/user.ld -o user/<name>.elf user/<name>.o
zig objcopy -O binary user/<name>.elf user/<name>.bin
```

### 4.3 用户链接脚本 `user/user.ld`

起始地址 `0x0`（用户态低地址），标准 ELF 段（`.text`/`.rodata`/`.data`/`.bss`），入口 `_start`。
仅汇编程序经此脚本链接。

---

## 5. AP Trampoline

文件：`kernel/arch/x86_64/ap_trampoline_src.S`

- 16 位实模式 → 32 位保护模式 → 64 位长模式
- 链接到固定物理地址 `0x8000`（页表起始下方）
- 流程：
  1. `zig cc -target x86-freestanding-none -c` 汇编 → `.o`
  2. `ld.lld -m elf_i386 --image-base=0 -Ttext 0x8000` 链接 → ELF
  3. `zig objcopy -O binary` → `ap_trampoline.bin`
  4. 内核启动时 BSP 通过 `memcpy` 把 `.bin` 复制到 `0x8000`，再发 INIT/SIPI

---

## 6. Ramdisk 打包（MRD 格式）

工具：`tools/mkramdisk.sh` 或 `tools/mkimage/`

```
+----------------+
| Header (32B)   | magic 'MRD0' + entry_count + ...
+----------------+
| Entry[0] (80B) | name[64] + offset(u64) + size(u64)
| Entry[1] (80B) | ...
| ...            |
+----------------+
| Data           | 串接所有文件原始数据
+----------------+
```

打包过程：

1. 收集 `user/*.elf` 与必要资产
2. 写入 Header
3. 顺序追加 Entry（计算偏移）
4. 顺序追加 Data
5. 输出到 ramdisk 模块文件，通过 Limine `MODULE` 加载

---

## 7. ISO 生成

工具：`xorriso` + `limine bios-install`

```
xorriso -as mkisofs \
    -b limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    --efi-boot limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    iso_root -o moqios.iso

./limine/limine bios-install moqios.iso
```

`iso_root/` 目录布局：

```
iso_root/
├── boot/
│   ├── limine/
│   │   └── limine.conf
│   ├── moqi-kernel.elf
│   └── ramdisk.bin
└── EFI/BOOT/
    └── BOOTX64.EFI
```

---

## 8. QEMU 启动

脚本：`tools/qemu_run.sh`，由 `zig build run` 调用。

```
qemu-system-x86_64 \
    -M q35 \
    -m 512M \
    -smp 2 \
    -cpu max \
    -enable-kvm \
    -cdrom moqios.iso \
    -drive id=disk0,file=disk.img,if=none,format=raw \
    -device virtio-blk-pci,drive=disk0 \
    -netdev user,id=n0,hostfwd=tcp::2222-:22 \
    -device e1000,netdev=n0 \
    -serial stdio \
    -no-reboot -no-shutdown
```

| 选项 | 说明 |
|---|---|
| `-M q35` | 现代 Q35 平台（支持 PCIe / ACPI MCFG） |
| `-m 512M` | 512MB 物理内存 |
| `-smp 2` | 双核（BSP + AP） |
| `-device virtio-blk-pci` | 虚拟块设备（FAT32/ext2 后端） |
| `-device e1000` | Intel 82540 千兆网卡 |
| `-serial stdio` | 串口输出到终端（内核日志） |

---

## 9. `build.zig` 命令总结

| 命令 | 说明 |
|---|---|
| `zig build` | 仅编译：生成内核镜像、用户程序、ramdisk、ISO |
| `zig build run` | 编译并启动 QEMU 仿真 |
| `zig build debug` | 启动 QEMU 并在 1234 端口监听 GDB（`-s -S`） |
| `zig build test` | 在主机目标运行 `tests/main.zig` 单元测试，覆盖可脱离硬件执行的共享库逻辑 |
| `zig build smoke` | 单核 QEMU 限时冒烟测试，串口日志需出现当前 init 自动序列末尾 `hello21 done` 和 `MoQiOS shell` |
| `zig build smoke-smp` | 双核 QEMU 限时冒烟测试，验证 AP/SMP 启动路径仍能跑完整个 init 测试序列 |
| `zig build smoke-smp-stress` | 默认连续执行 5 次双核冒烟；用于捕获任务槽复用、共享内核映射和调度时序回归。以 `MOQI_SMOKE_RUNS=N` 覆盖次数 |
| `zig build -Darch=riscv64 smoke-riscv` | riscv64 M7+SK-44：shared probes + slim BSS + shared user-copy guard + shared idle boot + shared ramdisk parse + virtio + U-mode |
| `zig build -Darch=aarch64 smoke-aarch64` | aarch64 M9-7+SK-44：shared probes + slim BSS + shared user-copy guard + shared idle boot + shared ramdisk parse + default timer + EL0/SVC |

调试连接：

```
gdb zig-out/bin/moqi-kernel.elf
(gdb) target remote :1234
(gdb) c
```

---

## 10. 常见构建产物

| 路径 | 说明 |
|---|---|
| `zig-out/bin/moqi-kernel.elf` | x86_64 内核镜像 |
| `zig-out/bin/moqi-kernel-riscv64.elf` | riscv64 skeleton 内核镜像 |
| `user/*.elf` | 用户程序 ELF |
| `user/*.bin` | 用户程序装载镜像；C 程序当前为静态 freestanding ELF，汇编入口程序为 flat binary |
| `user_bin/` | 复制后的可执行文件目录 |
| `iso_root/boot/ramdisk.bin` | 打包好的 ramdisk |
| `moqios.iso` | 最终 ISO |
| `disk.img` | virtio-blk 后端磁盘镜像 |
| `ext2.img` | ext2 测试镜像 |
| `.zig-cache/` | Zig 编译缓存 |

---

## 11. 已知构建相关问题

- `zig build run` 在无 KVM 环境下，AP LAPIC 定时器可能不工作（多核调度无法测试，应使用 `-enable-kvm` 或真机）。
- `disk.img` 与 `disk.img.bak` 需手动维护（参见 `tools/mkimage/`）。
- 用户程序起始地址为 `0x0`，与某些链接器默认行为冲突，汇编程序必须显式 `-T user/user.ld`。
- `zig build test` 使用主机目标，适合验证无硬件副作用的共享库函数；真正的内核/用户态集成仍以
  `zig build run` 下的 QEMU `hello*` 运行时测试为准。

---

## 12. 未集成源文件清单（孤立模块）

从 `kernel/main.zig` 出发沿 `@import` 做可达性分析（2026-06），121 个 `.zig` 文件中 **88 个可达
（参与编译）**，**33 个孤立**——它们未被任何模块 `@import`，因此**不会被编译/类型检查**，也不
会进入内核镜像。这些多为已写好但尚未接线到 syscall 分发表/模块图的**完整功能实现**（非空壳）。

> 经 `zig ast-check` 校验：33 个文件中 32 个语法/AST 完好；唯一例外
> `kernel/net/dns.zig` 误用了不存在的内建 `@memcmp`，已修正为手动字节比较（现 33/33 通过）。
>
> ⚠️ 注意：`ast-check` 仅验证语法与基本语义，**未**针对当前内核 API 做完整类型检查。真正接线
> 前仍需逐个 `@import` 并 `zig build` 验证其对 `task`/`vfs`/`paging` 等模块的调用是否匹配现状。

### 分类清单

| 类别 | 文件 | 说明 |
|---|---|---|
| 同步原语 | `sync/futex.zig` `sync/rwlock.zig` `sync/seqlock.zig` `sync/ticket_spinlock.zig` | futex（FUTEX_WAIT/WAKE 等，307 行）与多种锁实现 |
| 文件系统 | `fs/getdents.zig` `fs/poll.zig` `fs/select.zig` `fs/ioctl.zig` `fs/fcntl.zig` `fs/statx.zig` `fs/readlink.zig` `fs/readv.zig` `fs/splice.zig` `fs/copy_file_range.zig` `fs/file_lock.zig` `fs/aio.zig` `fs/inotify.zig` `fs/io_sched.zig` | getdents64/poll/select/ioctl 等 VFS 扩展 syscall |
| IPC | `ipc/posix_mq.zig` `ipc/sysv_msg.zig` `ipc/sysv_sem.zig` `ipc/sysv_shm.zig` | POSIX 消息队列 + System V msg/sem/shm |
| 内存 | `mm/mprotect.zig` `mm/process_vm.zig` | mprotect 与 process_vm_readv/writev |
| 进程 | `proc/credentials.zig` `proc/pgrp.zig` `proc/misc_syscall.zig` `arch/x86_64/clone.zig` | setuid 族 / 进程组 / clone |
| 网络 | `net/dhcp.zig` `net/dns.zig` | DHCP 客户端 / DNS 解析器 |
| 其他 | `arch/x86_64/user_mode.zig` `arch/x86_64/vga.zig` `boot_info.zig` | 疑似被现有实现取代的早期模块 |

### 处理建议

1. **不要直接删除**：这些是作者的在制功能（WIP），删除会丢失大量已完成工作。
2. **按需逐个集成**：需要某个 syscall 时，将对应文件 `@import` 进相关模块、在 syscall 分发表登记
   编号，再 `zig build` 修正类型不匹配，最后补一个 `hello*` 运行时测试。
3. **`boot_info.zig` / `vga.zig` / `user_mode.zig`** 需先确认是否已被现有实现取代，若确认废弃可单独清理。
4. 在集成前，这些文件**不应**被视为"已支持的功能"——README/架构文档以"可达即编译"的 88 个文件为准。

---

## 参考

- [moqios-architecture-current.md](./moqios-architecture-current.md)
- [user-space.md](./user-space.md)
- [moqios-implementation-plan.md](./moqios-implementation-plan.md)
