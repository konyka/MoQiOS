const std = @import("std");

/// Assembly user program: `.S` -> object -> linked ELF -> raw flat binary.
/// Used for hand-written entry stubs that rely on `user/user.ld`.
fn addAsmUserProgram(b: *std.Build, name: []const u8) void {
    // All artifacts are declared outputs (zig-cache) and installed to
    // zig-out/user/<name>.bin, so the cache tracks them and the source tree
    // stays free of generated files. tools/qemu_run.sh packages the ramdisk
    // from zig-out/user/.
    const obj = b.addSystemCommand(&.{
        "zig",     "cc",
        "-target", "x86_64-freestanding-none",
        "-c",      "-o",
    });
    const obj_out = obj.addOutputFileArg(b.fmt("{s}.o", .{name}));
    obj.addFileArg(b.path(b.fmt("user/{s}.S", .{name})));
    obj.setName(b.fmt("assemble {s}.S", .{name}));

    const elf = b.addSystemCommand(&.{
        "zig", "ld.lld",
        "-T",  "user/user.ld",
        "-o",
    });
    const elf_out = elf.addOutputFileArg(b.fmt("{s}.elf", .{name}));
    elf.addFileArg(obj_out);
    elf.setName(b.fmt("link {s}.elf", .{name}));

    const bin = b.addSystemCommand(&.{
        "zig",
        "objcopy",
        "-O",
        "binary",
    });
    bin.addFileArg(elf_out);
    const bin_out = bin.addOutputFileArg(b.fmt("{s}.bin", .{name}));
    bin.setName(b.fmt("objcopy {s} -> raw binary", .{name}));

    b.getInstallStep().dependOn(&b.addInstallFile(bin_out, b.fmt("user/{s}.bin", .{name})).step);
}

/// C user program: `.c` -> static freestanding ELF stored as `.bin`.
/// Output is a declared cache artifact installed to zig-out/user/<name>.bin.
fn addCUserProgram(b: *std.Build, name: []const u8) void {
    const elf = b.addSystemCommand(&.{
        "zig",            "cc",
        "-target",        "x86_64-freestanding-none",
        "-static",        "-nostdlib",
        "-ffreestanding", "-O2",
        // C user images enter at _start without a CRT call frame. Realign the
        // stack so compiler-generated SSE locals remain safe at that entry.
        "-mstackrealign", "-Wl,--gc-sections",
        "-Wl,-z,norelro", "-o",
    });
    const elf_out = elf.addOutputFileArg(b.fmt("{s}.bin", .{name}));
    elf.addFileArg(b.path(b.fmt("user/{s}.c", .{name})));
    elf.setName(b.fmt("compile {s}.c -> ELF bin", .{name}));

    b.getInstallStep().dependOn(&b.addInstallFile(elf_out, b.fmt("user/{s}.bin", .{name})).step);
}

/// moqi_libc sources linked into every libc-based user program.
const moqi_libc_sources = [_][]const u8{
    "lib/moqi_libc/src/crt0.c",
    "lib/moqi_libc/src/unistd.c",
    "lib/moqi_libc/src/string.c",
    "lib/moqi_libc/src/format.c",
    "lib/moqi_libc/src/stdio.c",
    "lib/moqi_libc/src/malloc.c",
    "lib/moqi_libc/src/sbrk.c",
    "lib/moqi_libc/src/stdlib.c",
    "lib/moqi_libc/src/signal.c",
    "lib/moqi_libc/src/pthread.c",
    "lib/moqi_libc/src/rlimit.c",
};

/// C user program built against moqi_libc: same flags as addCUserProgram,
/// plus the libc include dir and sources. The program's entry point is
/// `int main(void)`; crt0 provides `_start` and `exit(main())`.
/// `src` is the program's C source path (user/ for most programs; init
/// lives in servers/init/).
fn addLibcUserProgram(b: *std.Build, name: []const u8, src: []const u8) void {
    const elf = b.addSystemCommand(&.{
        "zig",            "cc",
        "-target",        "x86_64-freestanding-none",
        "-static",        "-nostdlib",
        "-ffreestanding", "-O2",
        // Same entry/stack rationale as addCUserProgram.
        "-mstackrealign", "-Wl,--gc-sections",
        "-Wl,-z,norelro", "-Ilib/moqi_libc/include",
        "-o",
    });
    const elf_out = elf.addOutputFileArg(b.fmt("{s}.bin", .{name}));
    elf.addFileArg(b.path(src));
    for (moqi_libc_sources) |libc_src| elf.addFileArg(b.path(libc_src));
    elf.setName(b.fmt("compile {s}.c + moqi_libc -> ELF bin", .{name}));

    b.getInstallStep().dependOn(&b.addInstallFile(elf_out, b.fmt("user/{s}.bin", .{name})).step);
}

/// Build the RISC-V 64 kernel skeleton (cross-ISA port, Milestone 2).
/// Soft-float ABI (lp64): baseline_rv64 with F/D removed so the kernel never
/// touches FP registers. Separate from the x86_64 path until the shared arch
/// interface can host the full kernel (see docs/cross-arch-port-plan.md).
fn buildRiscv64(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const query = std.Target.Query.parse(.{
        .arch_os_abi = "riscv64-freestanding-none",
        // Soft-float: drop F/D from baseline_rv64 → ELF flags show soft-float ABI.
        .cpu_features = "baseline_rv64-f-d",
    }) catch unreachable;
    const target = b.resolveTargetQuery(query);

    const module = b.createModule(.{
        .root_source_file = b.path("kernel/riscv64_root.zig"),
        .target = target,
        .optimize = optimize,
        // medany code model: required for a kernel linked at 0x80200000 (outside
        // the medlow ±2GB-around-0 reachable range).
        .code_model = .medium,
        .red_zone = false,
        .pic = false,
    });

    const kernel = b.addExecutable(.{
        .name = "moqi-kernel-riscv64.elf",
        .root_module = module,
        .use_lld = true,
        .use_llvm = true,
    });
    kernel.setLinkerScript(b.path("kernel/arch/riscv64/linker.ld"));
    b.installArtifact(kernel);

    // Run step (requires qemu-system-riscv; see cross-arch-port-plan.md).
    const run_step = b.step("run", "Build and run the riscv64 kernel in QEMU");
    const run_cmd = b.addSystemCommand(&.{"./tools/qemu_run_riscv64.sh"});
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    const smoke_rv_step = b.step("smoke-riscv", "Run bounded riscv64 M2 QEMU smoke test");
    const smoke_rv_cmd = b.addSystemCommand(&.{"./tools/qemu_smoke_riscv64.sh"});
    smoke_rv_cmd.step.dependOn(b.getInstallStep());
    smoke_rv_cmd.setEnvironmentVariable("MOQI_SMOKE_SKIP_BUILD", "1");
    smoke_rv_step.dependOn(&smoke_rv_cmd.step);
}

/// Build the AArch64 kernel skeleton (cross-ISA port, Milestone 9-1).
/// QEMU `virt` + PL011 console; separate from x86_64 / riscv64 until the
/// shared arch path hosts the full kernel.
fn buildAarch64(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const query = std.Target.Query.parse(.{
        .arch_os_abi = "aarch64-freestanding-none",
        // Drop NEON so compiler-rt memcpy never emits aligned `ldr q0` on
        // unaligned FDT byte streams (would Data-Abort with DFSC=alignment).
        .cpu_features = "baseline-neon",
    }) catch unreachable;
    const target = b.resolveTargetQuery(query);

    const module = b.createModule(.{
        .root_source_file = b.path("kernel/aarch64_root.zig"),
        .target = target,
        .optimize = optimize,
        .red_zone = false,
        .pic = false,
    });
    module.addAssemblyFile(b.path("kernel/arch/aarch64/vectors.S"));

    const kernel = b.addExecutable(.{
        .name = "moqi-kernel-aarch64.elf",
        .root_module = module,
        .use_lld = true,
        .use_llvm = true,
    });
    kernel.setLinkerScript(b.path("kernel/arch/aarch64/linker.ld"));
    b.installArtifact(kernel);

    const run_step = b.step("run", "Build and run the aarch64 kernel in QEMU");
    const run_cmd = b.addSystemCommand(&.{"./tools/qemu_run_aarch64.sh"});
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    const smoke_aa_step = b.step("smoke-aarch64", "Run bounded aarch64 M9 QEMU smoke test");
    const smoke_aa_cmd = b.addSystemCommand(&.{"./tools/qemu_smoke_aarch64.sh"});
    smoke_aa_cmd.step.dependOn(b.getInstallStep());
    smoke_aa_cmd.setEnvironmentVariable("MOQI_SMOKE_SKIP_BUILD", "1");
    smoke_aa_step.dependOn(&smoke_aa_cmd.step);
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Target CPU architecture. Default x86_64 keeps the existing behavior
    // byte-for-byte; `-Darch=riscv64` / `-Darch=aarch64` build port skeletons.
    const arch = b.option([]const u8, "arch", "Target CPU architecture: x86_64 (default) | riscv64 | aarch64") orelse "x86_64";
    if (std.mem.eql(u8, arch, "riscv64")) {
        buildRiscv64(b, optimize);
        return;
    }
    if (std.mem.eql(u8, arch, "aarch64")) {
        buildAarch64(b, optimize);
        return;
    }
    if (!std.mem.eql(u8, arch, "x86_64")) {
        std.debug.panic("unsupported -Darch='{s}' (expected x86_64 | riscv64 | aarch64)", .{arch});
    }

    const query = std.Target.Query.parse(.{
        .arch_os_abi = "x86_64-freestanding-none",
        .cpu_features = "baseline-sse-sse2-mmx+soft_float",
    }) catch unreachable;
    const target = b.resolveTargetQuery(query);

    const module = b.createModule(.{
        .root_source_file = b.path("kernel/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
        .red_zone = false,
        .pic = true,
    });

    const kernel = b.addExecutable(.{
        .name = "moqi-kernel.elf",
        .root_module = module,
        .use_lld = true,
        .use_llvm = true,
    });

    kernel.setLinkerScript(b.path("kernel/linker.ld"));

    // AP trampoline: precompiled flat binary, embedded via @embedFile in smp.zig.
    // All intermediates are declared cache outputs; the final binary reaches the
    // kernel through the module embed path, so a deleted/stale trampoline can
    // never survive a green build.
    const trampoline_obj = b.addSystemCommand(&.{
        "zig",     "cc",
        "-target", "x86-freestanding-none",
        "-c",      "-o",
    });
    const trampoline_obj_out = trampoline_obj.addOutputFileArg("ap_trampoline.o");
    trampoline_obj.addFileArg(b.path("kernel/arch/x86_64/ap_trampoline_src.S"));
    trampoline_obj.setName("assemble ap_trampoline.S");

    const trampoline_elf = b.addSystemCommand(&.{
        "zig", "ld.lld", "-m", "elf_i386", "--image-base=0", "-Ttext", "0x8000", "-o",
    });
    const trampoline_elf_out = trampoline_elf.addOutputFileArg("ap_trampoline.elf");
    trampoline_elf.addFileArg(trampoline_obj_out);
    trampoline_elf.setName("link ap_trampoline.elf");

    const trampoline_bin = b.addSystemCommand(&.{
        "zig", "objcopy", "-O", "binary",
    });
    trampoline_bin.addFileArg(trampoline_elf_out);
    const trampoline_bin_out = trampoline_bin.addOutputFileArg("ap_trampoline.bin");
    trampoline_bin.setName("objcopy ap_trampoline -> raw binary");

    // smp.zig embeds the trampoline via @embedFile("arch/x86_64/ap_trampoline.bin"),
    // which resolves relative to kernel/smp.zig, so copy the cache-tracked binary
    // into the source tree. This step declares no outputs, so it re-runs on every
    // build and restores a deleted or stale ap_trampoline.bin.
    const trampoline_copy = b.addSystemCommand(&.{"cp"});
    trampoline_copy.addFileArg(trampoline_bin_out);
    trampoline_copy.addArg("kernel/arch/x86_64/ap_trampoline.bin");
    trampoline_copy.setName("install ap_trampoline.bin (embed source)");

    kernel.step.dependOn(&trampoline_copy.step);

    b.installArtifact(kernel);

    // --- User programs ---
    // Assembly entry stubs (.S -> flat binary via user.ld).
    // NOTE: user/init.S is retained in the tree as the assembly fallback but
    // is no longer built; init is the C program in servers/init/ below, and
    // only one rule may install zig-out/user/init.bin.
    const asm_programs = [_][]const u8{ "hello2", "hello3" };
    for (asm_programs) |name| addAsmUserProgram(b, name);

    // C programs (.c -> static freestanding ELF stored as .bin)
    const c_programs = [_][]const u8{
        "hello4",  "hello5",  "hello6",  "hello7",  "hello8",
        "hello9",  "hello11", "hello12", "hello13", "hello14",
        "hello15", "hello16", "hello17", "hello18", "hello19",
        "hello20", "hello21", "hello22", "hello23", "hello24",
        "hello25", "hello26", "hello27", "hello28", "hello29",
        "hello30", "hello31", "hello32", "hello33", "hello34",
        "hello35", "hello36", "hello37", "hello38", "hello39",
        "hello40", "hello41", "hello42", "hello43", "hello44",
        "hello46", "hello47", "hello48", "hello49", "hello50",
        "hello51", "hello52", "hello53", "hello54", "hello56",
    };
    for (c_programs) |name| addCUserProgram(b, name);

    // C programs built against moqi_libc (lib/moqi_libc/): entry point is
    // `int main(int argc, char **argv, char **envp)`, libc provides _start
    // (parsing the kernel's SysV initial stack) and the syscall wrappers.
    // init (PID 1) is the C replacement for user/init.S; its source lives in
    // servers/init/, everything else in user/.
    const libc_programs = [_][]const u8{ "sh", "hello10", "hello45", "hello57", "hello58", "hello59", "hello60", "hello61", "hello62", "hello63", "hello64", "hello65", "hello66", "hello67", "hello68", "hello69", "hello70", "hello71", "hello72", "hello73" };
    for (libc_programs) |name| addLibcUserProgram(b, name, b.fmt("user/{s}.c", .{name}));
    addLibcUserProgram(b, "init", "servers/init/main.c");
    addLibcUserProgram(b, "syslogd", "servers/syslogd/main.c");
    addLibcUserProgram(b, "devmgr", "servers/devmgr/main.c");

    // Build and run in QEMU with Limine
    const run_step = b.step("run", "Build and run in QEMU");
    const run_cmd = b.addSystemCommand(&.{"./tools/qemu_run.sh"});
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    const smoke_step = b.step("smoke", "Run bounded single-core QEMU smoke test");
    const smoke_cmd = b.addSystemCommand(&.{ "./tools/qemu_smoke.sh", "1" });
    smoke_cmd.step.dependOn(b.getInstallStep());
    smoke_cmd.setEnvironmentVariable("MOQI_SMOKE_SKIP_BUILD", "1");
    smoke_step.dependOn(&smoke_cmd.step);

    const smoke_smp_step = b.step("smoke-smp", "Run bounded dual-core QEMU smoke test");
    const smoke_smp_cmd = b.addSystemCommand(&.{ "./tools/qemu_smoke.sh", "2" });
    smoke_smp_cmd.step.dependOn(b.getInstallStep());
    smoke_smp_cmd.setEnvironmentVariable("MOQI_SMOKE_SKIP_BUILD", "1");
    smoke_smp_step.dependOn(&smoke_smp_cmd.step);

    const smoke_smp_matrix_step = b.step("smoke-smp-matrix", "Run configurable x86 QEMU CPU-count smoke matrix");
    const smoke_smp_matrix_cmd = b.addSystemCommand(&.{"./tools/qemu_smoke_matrix.sh"});
    smoke_smp_matrix_cmd.step.dependOn(b.getInstallStep());
    smoke_smp_matrix_cmd.setEnvironmentVariable("MOQI_SMOKE_SKIP_BUILD", "1");
    smoke_smp_matrix_step.dependOn(&smoke_smp_matrix_cmd.step);

    const smoke_smp_stress_step = b.step("smoke-smp-stress", "Run repeated configurable multicore QEMU smoke tests");
    const smoke_smp_stress_cmd = b.addSystemCommand(&.{"./tools/qemu_smoke_stress.sh"});
    smoke_smp_stress_cmd.step.dependOn(b.getInstallStep());
    smoke_smp_stress_cmd.setEnvironmentVariable("MOQI_SMOKE_SKIP_BUILD", "1");
    smoke_smp_stress_step.dependOn(&smoke_smp_stress_cmd.step);

    // Debug with GDB
    const debug_step = b.step("debug", "Build and run in QEMU with GDB stub");
    const debug_cmd = b.addSystemCommand(&.{"./tools/qemu_run.sh"});
    debug_cmd.step.dependOn(b.getInstallStep());
    debug_cmd.setEnvironmentVariable("MOQI_DEBUG", "1");
    debug_step.dependOn(&debug_cmd.step);

    // Tests
    // Unit tests run on the host. The freestanding kernel target cannot host
    // Zig's standard test runner, which pulls in compiler-rt/std test helpers.
    const test_module = b.createModule(.{
        .root_source_file = b.path("tests/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    // Host-compilable kernel modules under test. Zig analyzes declarations
    // lazily, so a file may be tested on the host as long as the *tested*
    // decls do not reach arch-specific code (arch/, serial, pmm, port I/O).
    //
    // A Zig file may belong to only one module, and module file-membership
    // follows path imports transitively — even from function bodies — so all
    // tested kernel files share one module rooted at kernel/host_test.zig,
    // which re-exports them. Extending coverage is one `pub const` line in
    // kernel/host_test.zig plus the import alias and tests in
    // tests/main.zig. A second entry here is only possible for a kernel
    // subtree whose path-import closure is fully disjoint from the first.
    const host_test_modules = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "kernel_shared", .path = "kernel/host_test.zig" },
    };
    for (host_test_modules) |m| {
        test_module.addImport(m.name, b.createModule(.{
            .root_source_file = b.path(m.path),
            .target = b.graph.host,
            .optimize = optimize,
        }));
    }
    const lib_test = b.addTest(.{
        .root_module = test_module,
    });
    const run_lib_tests = b.addRunArtifact(lib_test);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_lib_tests.step);
    const run_libc_host_tests = b.addSystemCommand(&.{"./lib/moqi_libc/host_tests/run_tests.sh"});
    test_step.dependOn(&run_libc_host_tests.step);
    const run_init_supervisor_tests = b.addSystemCommand(&.{"./tools/tests/test_init_supervisor.sh"});
    test_step.dependOn(&run_init_supervisor_tests.step);
}
