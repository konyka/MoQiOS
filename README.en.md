# MoQiOS

An x86_64-first operating system kernel written in Zig, using the Limine boot protocol, with multiprocess support, FAT32/ext2 filesystems, a network stack, signal handling, and an interactive shell. riscv64 and aarch64 currently provide separately tested porting skeletons.

[中文文档](./README.md)

## Project Status

**Current Progress**: x86_64 M11+ with multiple extension features; riscv64/aarch64 porting skeletons have dedicated QEMU smoke gates.

| Milestone | Feature | Status |
|---|---|---|
| M1 | Kernel boot + serial output + GDT/IDT | ✅ |
| M2 | Physical memory management + paging + HHDM | ✅ |
| M3 | Scheduler + context switching (round-robin) | ✅ |
| M4 | User-space processes + syscall entry (syscall/sysret) | ✅ |
| M5 | Multiprocess + spawn + ELF loader | ✅ |
| M6 | PCI device enumeration | ✅ |
| M7 | virtio-blk driver + FAT32 filesystem (read/write) | ✅ |
| M8 | e1000 NIC driver + ARP/IPv4/ICMP/UDP network stack | ✅ |
| M9 | Pipes (pipe) + dup2 + interactive shell | ✅ |
| M10 | fork + execve + address space cloning | ✅ |
| M11+ | Signals, environment variables, directory ops, chdir/getcwd, fstat/unlink | ✅ |
| Extensions | ext2, tmpfs/procfs, TCP sockets, SMP/work-stealing, IPv6, capabilities | ✅ on x86_64 |
| Extensions | CPU-count-adaptive SMP: MADT-detected → resource-bounded selection → IST allocated per selected CPU | ✅ on x86_64 |
| Porting | riscv64 and aarch64 shared-probe/boot skeletons | In progress |

> **2026-07-26 CPU-count-adaptive SMP**: `kernel/smp.zig` now reads the MADT at boot, selects as many
> APs as task slots and kernel capacity allow (up to `MAX_CPUS = 256`, bounded by xAPIC u8 IDs), and
> allocates 3×16 KiB IST backing only for selected CPUs. Dense logical IDs (0…N-1) are separated from
> xAPIC hardware IDs. x2APIC/type-9 entries are unsupported and skipped. AP startup remains serialized.
> Targeted TLB IPIs wait only for online CPUs. Smoke matrix verified: 1/2/3/4/6/8 cores pass by default;
> 12/16-core runs pass with `MOQI_SMOKE_TIMEOUT=600` (TCG). 8-core 3-run stress passed. riscv64/aarch64
> smoke pass. ReleaseFast builds pass. Run: `zig build smoke-smp-matrix` or
> `MOQI_SMOKE_MATRIX_CPUS="1 2 4 8" zig build smoke-smp-matrix`.

**Kernel**: ~63,000 lines Zig | **User programs**: ~3,600 lines C/ASM | **Tests**: host unit tests + QEMU smoke gates (`smoke`, `smoke-smp`, `smoke-smp-matrix`, `smoke-smp-stress`)

## Canonical Disk Fixture

The tracked `disk.img` is a canonical x86 test fixture. Its checked-in `disk.img.manifest`
records the tracked HEAD blob provenance (format, filename, byte count, and raw-byte
SHA-256). `tools/qemu_run.sh` validates it before Limine/ISO/NVMe side effects, and
`tools/qemu_smoke.sh` validates it before making its private copy. This detects fixture
integrity drift; it does not claim reproducible disk-image generation.

With `MOQI_DISK` unset or empty, canonical validation is required. A non-empty
`MOQI_DISK` remains a caller-owned override: it only needs to be a regular file and is not
compared with the canonical manifest. Validate the checked-in fixture and run its offline
contracts with `tools/disk_fixture.sh disk.img.manifest disk.img` and
`bash tools/tests/test_disk_fixture.sh`.

## Features

### Process Management
- Multiprocess scheduling (round-robin with priority)
- `fork()` — full address space COW cloning
- `execve()` — ELF loading with argv support
- `waitpid()` — parent waits for child exit
- `spawn()` — load and start programs from ramdisk
- Signal mechanism: kill, sigaction, sigreturn, sigprocmask
- Ctrl+C (SIGINT) keyboard interrupt, shell ignores SIGINT

### Filesystem
- **Ramdisk**: read-only filesystem loaded at boot
- **FAT32**: virtio-blk disk read/write support
  - File creation, reading, writing (arbitrary-size I/O)
  - File deletion (unlink) with FAT cluster chain freeing
  - Directory listing (listdir)
- Pipes (pipe) + dup2 for I/O redirection
- Per-process file descriptor table

### Network Stack
- **e1000** gigabit NIC driver (PCI, MMIO, interrupts)
- **ARP**: address resolution with ARP cache
- **IPv4**: checksum computation, packet encapsulation
- **ICMP**: Echo Reply (ping response)
- **UDP**: sendto/recvfrom, 5 network syscalls
- Verified with QEMU SLIRP networking (ARP reply + ICMP ping)

### Memory Management
- PMM (Physical Memory Manager) — page-level alloc/free
- Paging — 4-level page tables (PML4), user/kernel address space isolation
- HHDM (Higher-Half Direct Map) — direct physical memory access
- `mmap` / `munmap` — user-space memory mapping
- `brk` — heap management

### Shell Features
- Command execution (fork + execve)
- Pipelines (`|`) and I/O redirection (`>`, `<`)
- Built-in commands: `echo`, `ls`, `cd`, `pwd`, `export`, `env`, `help`, `pid`, `exit`
- Environment variables: `export VAR=value`, `$VAR` expansion
- Ctrl+C signal handling

## Syscall Table

| # | Name | Description |
|---|---|---|
| 1 | write | Write to file descriptor |
| 2 | exit | Exit process |
| 4 | getpid | Get process ID |
| 5 | spawn | Start program from ramdisk |
| 6 | waitpid | Wait for child process |
| 7 | brk | Adjust program break |
| 8 | mmap | Map memory |
| 9 | open | Open file |
| 10 | read | Read from file descriptor |
| 11 | close | Close file descriptor |
| 12 | munmap | Unmap memory |
| 13 | sigaction | Set signal handler |
| 14 | sigprocmask | Set signal mask |
| 15 | sigreturn | Return from signal handler |
| 22 | pipe | Create pipe |
| 33 | dup2 | Duplicate file descriptor |
| 57 | fork | Clone process |
| 59 | execve | Replace process image |
| 62 | kill | Send signal |
| 63 | uname | Get system information |
| 96 | gettimeofday | Get time of day |
| 100-104 | net_* | Network ops (send/recv/udp_send/udp_recv/poll) |
| 105 | getenv | Get environment variable |
| 106 | setenv | Set environment variable |
| 107 | listdir | List directory contents |
| 108 | chdir | Change working directory |
| 109 | getcwd | Get current working directory |
| 110 | fstat | Get file metadata |
| 111 | unlink | Delete file |
| 228 | clock_gettime | Get high-resolution time |

## Test Programs

| Test | Feature |
|---|---|
| hello2 | Minimal user program (serial output) |
| hello3 | Ramdisk file read |
| hello4 | Multiprocess spawn |
| hello5 | Command-line arguments (argc/argv) |
| hello7 | ELF loading |
| hello8 | Pipe communication |
| hello9 | fork parent/child |
| hello10 | fork + execve combination |
| hello11 | execve target (minimal ELF) |
| hello12 | FAT32 file write |
| hello13 | Signal handling (SIGUSR1) |
| hello14 | ARP network communication |
| hello15 | UDP data send |
| hello16 | Environment variables (setenv/getenv/fork inheritance) |
| hello17 | execve argv passing verification |
| hello18 | chdir/getcwd/fstat/uname |
| hello19–hello21 | TCP setup and init smoke tail |
| hello22–hello28 | TCP socket, ext2, mkdir/unlink and directory integration tests |
| hello89 | epoll_pwait/epoll_pwait2 temporary signal masks, timeouts, and argument boundaries |

## Quick Start

### Prerequisites

- Zig 0.16.0+
- git (needed with network for the first Limine bootstrap; an existing `limine/` must be a clean checkout)
- make (needed to build the `limine` utility in a fresh checkout)
- QEMU (qemu-system-x86_64)
- xorriso (for ISO creation)

`tools/qemu_run.sh` pins Limine to the `v8.7.0-binary` tag and requires commit
`aad3edd370955449717a334f0289dee10e2c5f01`. A fresh download is cloned into a temporary sibling
and verified before it becomes `limine/`; an existing directory must be a clean Git checkout and
must not be a symlink. This historical binary tag has no official release checksum or signature;
the pinned commit is not cryptographic identity authentication. The local bootstrap contract test
does not use QEMU or the network:

```bash
bash tools/tests/test_limine_bootstrap.sh
```

### Build & Run

```bash
zig build run
```

### Build Only

```bash
zig build
```

### Verification

```bash
zig build test
zig build smoke
zig build smoke-smp
zig build -Darch=riscv64 smoke-riscv
zig build -Darch=aarch64 smoke-aarch64
```

`zig build test` is the canonical host test gate: it runs both the Zig unit tests in
`tests/main.zig` and the moqi_libc C host tests in `lib/moqi_libc/host_tests/run_tests.sh`.
Register new host-runnable tests in one of those suites. GitHub CI runs the same command through
`tools/observe_test_duration.py` for pushes and pull requests (host-tests job), printing one
non-gating JSONL duration observation in the log. Durations are observational only,
not comparable baseline or regression data. Since 2026-08-14 a `smoke-qemu` CI job runs the
QEMU boot-to-shell gate under TCG (`zig build smoke` single-core and `zig build smoke-smp`
dual-core), cloning Limine at its pinned commit and verifying disk.img against the manifest;
see the build documentation for the schema, local commands, and QEMU status limitation.

See [docs/build-and-toolchain.md](docs/build-and-toolchain.md) for markers, timeouts, and known limits.

### Project Structure

```
MoQiOS/
├── kernel/
│   ├── arch/x86_64/     # Architecture-specific (GDT, IDT, syscall, paging)
│   ├── drivers/         # Drivers (e1000, virtio_blk, keyboard)
│   ├── fs/              # Filesystems (VFS, FAT32, ramdisk)
│   ├── mm/              # Memory management (PMM, paging, HHDM, user_space)
│   ├── net/             # Network stack (ARP, IPv4, ICMP, UDP)
│   ├── proc/            # Process management (task, sched, loader, signal)
│   └── debug/           # Debug (serial, kernel_diag)
├── user/                # User programs
│   ├── init.S           # Init process (launches all tests)
│   ├── sh.c             # Interactive shell
│   └── hello*.c         # Test programs
├── tools/
│   ├── qemu_run.sh      # QEMU launch script
│   └── mkramdisk.sh     # Ramdisk packaging tool
├── boot/                # Limine boot configuration
├── docs/
│   ├── moqios-architecture-current.md  # Current implementation architecture (Chinese)
│   ├── moqios-design.md                # Long-term design goals (Chinese)
│   └── moqios-implementation-plan.md   # Implementation plan (Chinese)
├── build.zig            # Build configuration
└── kernel/linker.ld     # Kernel linker script
```

## Technical Details

- **Boot**: Limine Boot Protocol with HHDM direct mapping
- **Scheduler**: Round-robin, 16-page (64KB) kernel stacks, user/kernel thread support
- **Memory**: 4-level page tables, user space 0x0000000000–0x7FFFFFFFFFFF, kernel higher-half mapping
- **Interrupts**: IDT 256 vectors, timer/keyboard/NIC interrupts, syscall via MSR (LSTAR)
- **Network**: e1000 legacy descriptors, Rx/Tx ring buffers, interrupt-driven
- **Build**: `zig build` compiles kernel + user programs, `zig cc` cross-compiles user C programs

## License

MIT License

## Acknowledgments

- [Limine](https://github.com/limine-bootloader/limine) — Bootloader
- [Zig](https://ziglang.org/) — Systems programming language
- [OSDev Wiki](https://wiki.osdev.org/) — OS development reference
