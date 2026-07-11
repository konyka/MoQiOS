const std = @import("std");

/// Assembly user program: `.S` -> object -> linked ELF -> raw flat binary.
/// Used for hand-written entry stubs that rely on `user/user.ld`.
fn addAsmUserProgram(b: *std.Build, name: []const u8) void {
    const obj = b.addSystemCommand(&.{
        "zig",     "cc",
        "-target", "x86_64-freestanding-none",
        "-c",      "-o",
    });
    obj.addArg(b.fmt("user/{s}.o", .{name}));
    obj.addFileArg(b.path(b.fmt("user/{s}.S", .{name})));
    obj.setName(b.fmt("assemble {s}.S", .{name}));

    const elf = b.addSystemCommand(&.{
        "ld.lld",
        "-T",
        "user/user.ld",
        "-o",
    });
    elf.addArg(b.fmt("user/{s}.elf", .{name}));
    elf.addArg(b.fmt("user/{s}.o", .{name}));
    elf.step.dependOn(&obj.step);
    elf.setName(b.fmt("link {s}.elf", .{name}));

    const bin = b.addSystemCommand(&.{
        "zig",
        "objcopy",
        "-O",
        "binary",
    });
    bin.addArg(b.fmt("user/{s}.elf", .{name}));
    bin.addArg(b.fmt("user/{s}.bin", .{name}));
    bin.step.dependOn(&elf.step);
    bin.setName(b.fmt("objcopy {s} -> raw binary", .{name}));

    b.getInstallStep().dependOn(&bin.step);
}

/// C user program: `.c` -> static freestanding ELF stored as `.bin`.
fn addCUserProgram(b: *std.Build, name: []const u8) void {
    const elf = b.addSystemCommand(&.{
        "zig",               "cc",
        "-target",           "x86_64-freestanding-none",
        "-static",           "-nostdlib",
        "-ffreestanding",    "-O2",
        "-Wl,--gc-sections", "-Wl,-z,norelro",
        "-o",
    });
    elf.addArg(b.fmt("user/{s}.bin", .{name}));
    elf.addFileArg(b.path(b.fmt("user/{s}.c", .{name})));
    elf.setName(b.fmt("compile {s}.c -> ELF bin", .{name}));

    b.getInstallStep().dependOn(&elf.step);
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
        .root_source_file = b.path("kernel/arch/riscv64/start.zig"),
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

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Target CPU architecture. Default x86_64 keeps the existing behavior
    // byte-for-byte; `-Darch=riscv64` builds the cross-ISA port skeleton.
    const arch = b.option([]const u8, "arch", "Target CPU architecture: x86_64 (default) | riscv64") orelse "x86_64";
    if (std.mem.eql(u8, arch, "riscv64")) {
        buildRiscv64(b, optimize);
        return;
    }
    if (!std.mem.eql(u8, arch, "x86_64")) {
        std.debug.panic("unsupported -Darch='{s}' (expected x86_64 | riscv64)", .{arch});
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

    // AP trampoline: precompiled flat binary, embedded via @embedFile in smp.zig
    // Build step to assemble the trampoline source into a raw binary
    const trampoline_obj = b.addSystemCommand(&.{
        "zig",     "cc",
        "-target", "x86-freestanding-none",
        "-c",      "-o",
    });
    trampoline_obj.addArg(".zig-cache/ap_trampoline.o");
    trampoline_obj.addFileArg(b.path("kernel/arch/x86_64/ap_trampoline_src.S"));
    trampoline_obj.setName("assemble ap_trampoline.S");

    const trampoline_elf = b.addSystemCommand(&.{
        "ld.lld", "-m", "elf_i386", "--image-base=0", "-Ttext", "0x8000", "-o",
    });
    trampoline_elf.addArg(".zig-cache/ap_trampoline.elf");
    trampoline_elf.addArg(".zig-cache/ap_trampoline.o");
    trampoline_elf.step.dependOn(&trampoline_obj.step);
    trampoline_elf.setName("link ap_trampoline.elf");

    const trampoline_bin = b.addSystemCommand(&.{
        "zig", "objcopy", "-O", "binary",
    });
    trampoline_bin.addArg(".zig-cache/ap_trampoline.elf");
    trampoline_bin.addArg("kernel/arch/x86_64/ap_trampoline.bin");
    trampoline_bin.step.dependOn(&trampoline_elf.step);
    trampoline_bin.setName("objcopy ap_trampoline -> raw binary");

    // Make kernel depend on trampoline binary being up-to-date
    kernel.step.dependOn(&trampoline_bin.step);

    b.installArtifact(kernel);

    // --- User programs ---
    // Assembly entry stubs (.S -> flat binary via user.ld)
    const asm_programs = [_][]const u8{ "init", "hello2", "hello3" };
    for (asm_programs) |name| addAsmUserProgram(b, name);

    // C programs (.c -> static freestanding ELF stored as .bin)
    const c_programs = [_][]const u8{
        "hello4",  "hello5",  "hello6",  "hello7",  "hello8",  "sh",
        "hello9",  "hello10", "hello11", "hello12", "hello13", "hello14",
        "hello15", "hello16", "hello17", "hello18", "hello19", "hello20",
        "hello21", "hello22", "hello23", "hello24", "hello25", "hello26",
        "hello27", "hello28",
    };
    for (c_programs) |name| addCUserProgram(b, name);

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
    test_module.addImport("byte_order", b.createModule(.{
        .root_source_file = b.path("kernel/lib/byte_order.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }));
    test_module.addImport("fmt_core", b.createModule(.{
        .root_source_file = b.path("kernel/lib/fmt_core.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }));
    test_module.addImport("str", b.createModule(.{
        .root_source_file = b.path("kernel/lib/str.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }));
    const lib_test = b.addTest(.{
        .root_module = test_module,
    });
    const run_lib_tests = b.addRunArtifact(lib_test);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_lib_tests.step);
}
