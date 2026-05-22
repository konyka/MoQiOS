# MoQiOS

An x86_64 operating system kernel written in Zig, using the Limine boot protocol, with multiprocess support, FAT32 read/write filesystem, network stack, signal handling, and an interactive shell.

[中文文档](./README.md)

## Project Status

**Current Progress**: M11+ (M1–M10 milestones fully complete, plus multiple extension features)

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

**Kernel**: ~11,600 lines Zig | **User programs**: ~2,300 lines C/ASM | **Tests**: 18 automated + shell

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

## Quick Start

### Prerequisites

- Zig 0.16.0+
- QEMU (qemu-system-x86_64)
- xorriso (for ISO creation)

### Build & Run

```bash
zig build run
```

### Build Only

```bash
zig build
```

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
