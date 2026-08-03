# MoQiOS 构建系统与工具链

> **文档定位**: 描述 MoQiOS 的编译、链接、镜像打包与启动流程。
> **修订日期**: 2026-08-01
> **关联文档**: [moqios-architecture-current.md](./moqios-architecture-current.md)

---

## 1. 工具链概览

| 工具 | 版本 / 说明 | 用途 |
|---|---|---|
| Zig | 0.16+ | 内核编译、`zig cc` 交叉编译用户 C 程序、构建驱动（`build.zig`） |
| `zig cc` | 内置 | 编译用户态 C 程序（封装 clang） |
| LLD | 内置 (`ld.lld`) | 链接内核与用户程序 |
| `zig cc` (assembler mode) | 内置 | 汇编 `hello*.S`、`ap_trampoline_src.S`（`init.S` 保留为回退，不再参与构建） |
| `zig objcopy` | 内置 | 提取二进制段（用户汇编程序、trampoline 等） |
| `xorriso` | 系统包 | 生成 ISO 镜像 |
| `limine` | 仓库 `limine/` 子目录 | 安装 BIOS/UEFI 引导器 |
| QEMU (x86_64) | 系统包 | 仿真运行 |

`zig build` 是项目的**唯一**构建入口，统一管理上述步骤；不依赖额外的 `make`。

---

## 2. 构建总览

```
                    zig build（仅编译）
                        │
        ┌───────────────┼───────────────┐
        ▼               ▼               ▼
   编译内核          编译用户程序     编译 trampoline
   (moqi-kernel.elf) (hello*, sh,    (ap_trampoline.bin)
                      init)
                        │
                        ▼
        zig build run → tools/qemu_run.sh（打包 + 启动）
                        │
        ┌───────────────┼───────────────┐
        ▼               ▼               ▼
   mkramdisk.sh      xorriso 生成     limine bios-install
   打包 ramdisk.bin   moqios.iso
                        │
                        ▼
                   QEMU 启动
```

注意：`zig build` 本身**不**打包 ramdisk/ISO，也不生成 `disk.img`；ramdisk 与 ISO 打包发生在
`tools/qemu_run.sh`（由 `zig build run` / smoke 脚本调用）中，`disk.img` 是手动维护的构建外资产。

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

- 禁用 SSE/SSE2/MMX 并强制 soft-float：target query `cpu_features = "baseline-sse-sse2-mmx+soft_float"`（`build.zig:164-167`），而非 `-mno-*` 命令行标志
- 禁用红区：`red_zone = false`
- `code_model = .kernel`，对应高 2GB 内核镜像
- `pic = true`（高半区内核按位置无关编译）

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

输出：`zig-out/bin/moqi-kernel.elf`

---

## 4. 用户程序编译

> 实现位置：`build.zig` 中的辅助函数 `addCUserProgram` / `addAsmUserProgram` /
> `addLibcUserProgram`，分别对 `c_programs` / `asm_programs` / `libc_programs`
> 列表循环调用。新增用户程序时只需把程序名追加到对应
> 列表即可，无需复制整段构建步骤（2026-06 重构：从 ~900 行样板收敛至 ~160 行）。

### 4.1 C 程序（hello4–hello44, 裸 C）

`addCUserProgram(b, name)`：用 `zig cc` 交叉编译为静态 freestanding ELF，保存为 `<name>.bin`
装载镜像（输出目录由 `build.zig` 决定，当前为 `user/`）。这些 `.bin` 文件实际仍是 ELF，
内核 loader 会自动识别 ELF/flat binary。
Windows 兼容构建路径不再依赖外部 `strip`；后续可在 CI 中按工具可用性重新启用体积优化。

```
zig cc \
    -target x86_64-freestanding-none \
    -static -nostdlib -ffreestanding -O2 \
    -mstackrealign -Wl,--gc-sections -Wl,-z,norelro \
    -o <name>.bin user/<name>.c
```

注意：C 程序**不使用** `user/user.ld`，由 `zig cc` 默认链接（内置自定义 `_start`）。内核目标仍禁用
SSE；用户态 C 程序不再传 `-mno-sse/-mno-sse2`，因为 Zig 0.15.2 的 compiler-rt 在该组合下会触发
half-float SSE 返回错误。启用跨核用户任务迁移前仍需补齐 FPU/SSE 上下文保存验证。

### 4.1.1 moqi_libc 程序（init, sh, hello10）

`addLibcUserProgram(b, name, src)`：标志与 `addCUserProgram` 完全相同，额外加
`-Ilib/moqi_libc/include` 并把 `lib/moqi_libc/src/*.c` 一起编译链接。入口约定为
`int main(void)`（crt0 提供 `_start` 与 `exit(main())`），程序内直接使用
libc 的 `print/printf/fork/execve/malloc` 等，不再手写 syscall 内联汇编。
`src` 为源文件路径：大多数程序在 `user/<name>.c`；**init**（PID 1，2026-08 起为
C 实现）源文件位于 `servers/init/main.c`，同样安装为 `zig-out/user/init.bin`，
由 `tools/qemu_run.sh` 打包进 ramdisk 后按文件名 `init` 被内核加载。汇编版
`user/init.S` 保留在源码树中作为回退，但已从 `asm_programs` 移除，不再产生
`init.bin`（避免与 C 版安装冲突）。
库结构与设计见 [user-space.md](./user-space.md) 第 5 节。

```
zig cc \
    -target x86_64-freestanding-none \
    -static -nostdlib -ffreestanding -O2 \
    -mstackrealign -Wl,--gc-sections -Wl,-z,norelro \
    -Ilib/moqi_libc/include \
    -o <name>.bin user/<name>.c lib/moqi_libc/src/*.c
```

输出同样安装到 `zig-out/user/<name>.bin`，与裸 C 程序在 ramdisk 打包与加载路径上
完全一致。moqi_libc 的宿主机单元测试（string/printf 格式化/malloc 空闲链表）经
`lib/moqi_libc/host_tests/run_tests.sh` 运行，使用私有 zig 缓存目录，可与
`zig build` 并行执行。

### 4.2 汇编程序（hello2.S, hello3.S）

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

工具：`tools/mkramdisk.sh`（由 `tools/qemu_run.sh` 在打包阶段调用）

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

1. `qemu_run.sh` 把用户程序装载镜像收集到 `user_bin/`
2. 写入 Header
3. 顺序追加 Entry（计算偏移）
4. 顺序追加 Data
5. 输出为 `iso_root/boot/ramdisk.bin`，随 ISO 由 Limine 作为 module 加载（`limine.conf` 的 `module_path`）

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
    -cdrom moqios.iso \
    -boot order=d \
    -drive file=disk.img,format=raw,if=none,id=disk0 \
    -device virtio-blk-pci,drive=disk0 \
    -drive file=nvme.img,format=raw,if=none,id=nvm0 \
    -device nvme,serial=moqi,drive=nvm0 \
    -netdev user,id=net0 \
    -device e1000,netdev=net0 \
    -smp "$MOQI_SMP" \
    -serial stdio \
    -display none \
    -no-reboot -no-shutdown
```

脚本不使用 `-cpu` / KVM / hostfwd；额外诊断参数可经 `MOQI_EXTRA_QEMU` 追加（例如
`MOQI_EXTRA_QEMU="-d int,cpu_reset -D /tmp/qint.log"`）。NVMe 设备默认挂载
（`MOQI_NVME=0` 可关闭，镜像路径 `MOQI_NVME_IMG`，默认 `nvme.img`；不存在时由
脚本 `truncate -s 8M` 创建，并在首扇区写入 "MoQiNVMe" 模式串供内核启动自检校验）。

| 选项 | 说明 |
|---|---|
| `-M q35` | 现代 Q35 平台（支持 PCIe / ACPI MCFG） |
| `-m 512M` | 512MB 物理内存 |
| `-boot order=d` | 从 CD-ROM（moqios.iso）启动 |
| `-smp N` | CPU 核数；由 `MOQI_SMP` 环境变量控制（默认 2），smoke 脚本将其传给 QEMU |
| `-device virtio-blk-pci` | 虚拟块设备（FAT32/ext2 后端，根盘） |
| `-device nvme` | NVMe 控制器（scratch 镜像，用于 MSI-X 中断驱动 I/O 路径；`MOQI_NVME=0` 关闭） |
| `-device e1000` | Intel 82540 千兆网卡 |
| `-serial stdio` | 串口输出到终端（内核日志）；由 `MOQI_SERIAL` 控制 |
| `-display none` | 无图形窗口，纯串口交互 |

---

## 9. `build.zig` 命令总结

| 命令 | 说明 |
|---|---|
| `zig build` | 仅编译：生成内核镜像与用户程序；ramdisk/ISO 打包由 `tools/qemu_run.sh` 在 run/smoke 时完成 |
| `zig build run` | 编译并启动 QEMU 仿真 |
| `zig build debug` | 启动 QEMU 并在 1234 端口监听 GDB（`-s -S`） |
| `zig build test` | 在主机目标运行 `tests/main.zig` 单元测试，覆盖可脱离硬件执行的共享库逻辑 |
| `zig build smoke` | 单核 QEMU 限时冒烟测试，串口日志需出现 init 自动序列各 PASS 标记（`hello21 done`、`hello29: PASS` … `hello41: PASS`）、序列终点 `hello42: PASS` + `hello42 done`，以及 `MoQiOS shell`；完整判定见 `tools/qemu_smoke.sh`。此外启动早期（定时器 IRQ 使能前）会尝试一次有界 DHCP（G3），日志恰有一行大写结果标记：成功 `[DHCP] lease: a.b.c.d`，失败/无 NIC `[DHCP] no lease, static 10.0.2.15`；内部进度日志为小写 `[dhcp] ` |
| `zig build smoke-smp` | SMP QEMU 限时冒烟测试（默认 `MOQI_SMP=2`），验证 AP 启动路径仍能跑完整个 init 测试序列；`MOQI_SMP=N` 可指定任意正整数核数 |
| `zig build smoke-smp-matrix` | 按 `MOQI_SMOKE_MATRIX_CPUS`（默认 `"1 2 3 4 6 8"`）依次运行各核数冒烟；16 核在 TCG 下需 `MOQI_SMOKE_TIMEOUT=600` |
| `zig build smoke-smp-stress` | 连续执行 `MOQI_SMOKE_RUNS`（默认 5）次指定核数（`MOQI_SMP`，默认 2）冒烟；捕获任务槽复用、共享内核映射和调度时序回归 |
| `zig build -Darch=riscv64 smoke-riscv` | riscv64 M7+SK-156：shared probes + slim BSS + shared user-copy guard + shared idle boot + shared ramdisk parse + virtio + U-mode |
| `zig build -Darch=aarch64 smoke-aarch64` | aarch64 M9-7+SK-156：shared probes + slim BSS + shared user-copy guard + shared idle boot + shared ramdisk parse + default timer + EL0/SVC |

调试连接：

```
gdb zig-out/bin/moqi-kernel.elf
(gdb) target remote :1234
(gdb) c
```

### 9.1 smoke 相关环境变量

| 变量 | 说明 | 默认值 |
|---|---|---|
| `MOQI_SMP` | QEMU 传给内核的 CPU 核数（正整数）；smoke/smoke-smp/smoke-smp-stress 均读此变量 | `1`（smoke），`2`（smoke-smp/smoke-smp-stress） |
| `MOQI_SMOKE_MATRIX_CPUS` | smoke-smp-matrix 要依次测试的核数列表（空格分隔） | `"1 2 3 4 6 8"` |
| `MOQI_SMOKE_RUNS` | smoke-smp-stress 连续运行次数 | `5` |
| `MOQI_SMOKE_TIMEOUT` | 单次 smoke 超时秒数；TCG 下跑 16 核建议设为 600 | `120` |
| `MOQI_SMOKE_STRICT_SMP` | `1`：smoke 检查 "N CPUs online" 与请求核数一致（可因 MADT/资源降级）；`0`：允许部分上线 | `1` |

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
| `nvme.img` | NVMe scratch 镜像（qemu_run.sh 自动创建/写模式串） |
| `ext2.img` | ext2 测试镜像 |
| `.zig-cache/` | Zig 编译缓存 |

---

## 11. 已知构建相关问题

- `zig build run` 默认 TCG（脚本不传 `-enable-kvm`）；TCG 下 AP LAPIC 定时器可能不工作（多核调度无法充分测试，可用 `MOQI_EXTRA_QEMU="-enable-kvm -cpu host"` 或真机验证）。
- `disk.img` 与 `disk.img.bak` 需手动维护。
- 用户程序起始地址为 `0x0`，与某些链接器默认行为冲突，汇编程序必须显式 `-T user/user.ld`。
- `zig build test` 使用主机目标，适合验证无硬件副作用的共享库函数；真正的内核/用户态集成仍以
  `zig build run` 下的 QEMU `hello*` 运行时测试为准。

---

## 12. 未集成源文件清单（孤立模块）

从三个构建根（`kernel/main.zig`、`kernel/riscv64_root.zig`、`kernel/aarch64_root.zig`）出发沿
`@import` 做可达性分析（2026-08-01 重新统计）：`kernel/**/*.zig` 共 **325 个**文件，
**317 个可达（参与编译）**，**8 个孤立**——它们未被任何构建根 `@import`，因此**不会被编译/
类型检查**，也不会进入内核镜像。仅按 x86_64 根（`main.zig`）统计则为 164 可达 / 161 未达，
差值主要是 `kernel/shared/sk*.zig` 共享阶梯模块与非 x86 的 `arch/` 骨架（由 riscv64/aarch64
构建根引入）。

> 上轮（2026-06）清单中的 futex、posix_mq、sysv_msg/sem/shm、mprotect、getdents/poll/select/
> ioctl、dhcp/dns 等文件此后已陆续接线进 syscall 分发表或模块图，不再孤立。

### 分类清单

| 类别 | 文件 | 说明 |
|---|---|---|
| 同步原语 | `sync/rwlock.zig` `sync/seqlock.zig` `sync/ticket_spinlock.zig` | 多种锁实现（尚无树内使用者，2026-08 已修复其缺陷） |
| 内存 | `mm/process_vm.zig` | process_vm_readv/writev（116 行） |
| 其他 | `arch/x86_64/user_mode.zig` `arch/x86_64/vga.zig` | 疑似被现有实现取代的早期模块 |

（`shared/sk5.zig` 与 `kernel/boot_info.zig` 经确认无引用，已于 2026-08 删除。另：
`kernel/host_test.zig` 是 `zig build test` 的专用模块根，只被测试构建引用、刻意不进内核
构建根，统计孤立文件时应排除——见第 13 节。）

### 处理建议

1. **不要直接删除**：这些是作者的在制功能（WIP），删除会丢失已完成工作。
2. **按需逐个集成**：需要某个能力时，将对应文件 `@import` 进相关模块，`zig build` 修正类型
   不匹配，最后补一个 `hello*` 运行时测试。
3. **`vga.zig` / `user_mode.zig`** 需先确认是否已被现有实现取代，若确认废弃可单独清理。
4. 在集成前，这些文件**不应**被视为"已支持的功能"——以"可达即编译"的 317 个文件为准。

---

## 13. 主机端单元测试（`zig build test`）

`zig build test` 以主机目标编译 `tests/main.zig`，直接运行内核源码的单元测试（freestanding
目标无法承载 Zig 的标准 test runner）。当前覆盖 **11 个内核模块**：
`lib/{byte_order,errno,fmt,fmt_core,str}.zig`、`mm/cow_pte.zig`、
`net/{eth,ipv4,ipv6,tcp_util,udp_util}.zig`。

### 工作原理

- **懒 decl 分析**：Zig 只分析被引用到的声明。被测模块顶层可以 `@import` 架构相关文件
  （如 `arch/arch.zig`、serial、pmm、端口 I/O），只要**被测的 decl 本身不触及**这些代码即可。
  因此测试只针对纯函数（checksum、头部 build/parse、序列号比较、格式化等），并且**不要**对
  被测模块调用 `refAllDecls`。
- **一个文件只能属于一个模块**：模块的文件归属沿 `@import` 路径**传递**计算（包括函数体内的
  import）。net 辅助模块共享 `lib/byte_order.zig`，`ipv4.zig` 与 `lib/fmt.zig` 又都经 arch
  闭包触及 `sync/irq_spinlock.zig`、`mm/cow_pte.zig`，所以这些文件无法各自挂为独立测试模块。
  它们统一由 **`kernel/host_test.zig`**（仅测试用，不参与内核构建）作为单一模块根 re-export。
  该文件必须直接位于 `kernel/` 下，否则路径 import 会超出模块根目录。

### 如何新增一个模块的主机测试

1. 在 `kernel/host_test.zig` 加一行 `pub const xxx = @import("...");`（若新文件的路径 import
   闭包与现有模块完全不相交，也可以在 `build.zig` 的 `host_test_modules` 列表中另起一项）。
2. 在 `tests/main.zig` 顶部加 `const xxx = kt.xxx;`，然后编写行为测试（已知向量、
   round-trip、边界条件），校验和等期望值请用独立实现（如 Python 版 RFC 1071）离线计算。
3. 运行 `zig build test`；再跑 `zig build` 确认内核构建不受影响。

如果被测 decl 因一小处内核改动即可变为纯函数（如把纯 helper 下沉到叶子模块），可以做
**行为保持**的最小改动；否则放弃该模块，另选纯模块。

---

## 参考

- [moqios-architecture-current.md](./moqios-architecture-current.md)
- [user-space.md](./user-space.md)
- [moqios-implementation-plan.md](./moqios-implementation-plan.md)
