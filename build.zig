const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

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

    b.installArtifact(kernel);

    // --- User programs (compiled as freestanding flat binaries via as/ld/objcopy) ---
    const init_obj = b.addSystemCommand(&.{
        "zig", "cc",
        "-target", "x86_64-freestanding-none",
        "-c",
        "-o",
    });
    init_obj.addArg("user/init.o");
    init_obj.addFileArg(b.path("user/init.S"));
    init_obj.setName("assemble init.S");

    const init_elf = b.addSystemCommand(&.{
        "ld.lld",
        "-T", "user/user.ld",
        "-o",
    });
    init_elf.addArg("user/init.elf");
    init_elf.addArg("user/init.o");
    init_elf.step.dependOn(&init_obj.step);
    init_elf.setName("link init.elf");

    const init_bin = b.addSystemCommand(&.{
        "objcopy",
        "-O", "binary",
    });
    init_bin.addArg("user/init.elf");
    init_bin.addArg("user/init.bin");
    init_bin.step.dependOn(&init_elf.step);
    init_bin.setName("objcopy init -> raw binary");

    b.getInstallStep().dependOn(&init_bin.step);

    // --- hello2 user program ---
    const hello2_obj = b.addSystemCommand(&.{
        "zig", "cc",
        "-target", "x86_64-freestanding-none",
        "-c",
        "-o",
    });
    hello2_obj.addArg("user/hello2.o");
    hello2_obj.addFileArg(b.path("user/hello2.S"));
    hello2_obj.setName("assemble hello2.S");

    const hello2_elf = b.addSystemCommand(&.{
        "ld.lld",
        "-T", "user/user.ld",
        "-o",
    });
    hello2_elf.addArg("user/hello2.elf");
    hello2_elf.addArg("user/hello2.o");
    hello2_elf.step.dependOn(&hello2_obj.step);
    hello2_elf.setName("link hello2.elf");

    const hello2_bin = b.addSystemCommand(&.{
        "objcopy",
        "-O", "binary",
    });
    hello2_bin.addArg("user/hello2.elf");
    hello2_bin.addArg("user/hello2.bin");
    hello2_bin.step.dependOn(&hello2_elf.step);
    hello2_bin.setName("objcopy hello2 -> raw binary");

    b.getInstallStep().dependOn(&hello2_bin.step);

    // --- hello3 user program ---
    const hello3_obj = b.addSystemCommand(&.{
        "zig", "cc",
        "-target", "x86_64-freestanding-none",
        "-c",
        "-o",
    });
    hello3_obj.addArg("user/hello3.o");
    hello3_obj.addFileArg(b.path("user/hello3.S"));
    hello3_obj.setName("assemble hello3.S");

    const hello3_elf = b.addSystemCommand(&.{
        "ld.lld",
        "-T", "user/user.ld",
        "-o",
    });
    hello3_elf.addArg("user/hello3.elf");
    hello3_elf.addArg("user/hello3.o");
    hello3_elf.step.dependOn(&hello3_obj.step);
    hello3_elf.setName("link hello3.elf");

    const hello3_bin = b.addSystemCommand(&.{
        "objcopy",
        "-O", "binary",
    });
    hello3_bin.addArg("user/hello3.elf");
    hello3_bin.addArg("user/hello3.bin");
    hello3_bin.step.dependOn(&hello3_elf.step);
    hello3_bin.setName("objcopy hello3 -> raw binary");

    b.getInstallStep().dependOn(&hello3_bin.step);

    // --- hello4 user program (C, compiled as ELF) ---
    const hello4_elf = b.addSystemCommand(&.{
        "zig", "cc",
        "-target", "x86_64-freestanding-none",
        "-static",
        "-nostdlib",
        "-ffreestanding",
        "-O2",
        "-mno-sse",
        "-mno-sse2",
        "-Wl,--gc-sections",
        "-Wl,-z,norelro",
        "-o",
    });
    hello4_elf.addArg("user/hello4.elf");
    hello4_elf.addFileArg(b.path("user/hello4.c"));
    hello4_elf.setName("compile hello4.c -> ELF");

    const hello4_strip = b.addSystemCommand(&.{
        "strip",
        "-o",
    });
    hello4_strip.addArg("user/hello4.bin");
    hello4_strip.addArg("user/hello4.elf");
    hello4_strip.step.dependOn(&hello4_elf.step);
    hello4_strip.setName("strip hello4.elf");

    b.getInstallStep().dependOn(&hello4_strip.step);

    // Build and run in QEMU with Limine
    const run_step = b.step("run", "Build and run in QEMU");
    const run_cmd = b.addSystemCommand(&.{"./tools/qemu_run.sh"});
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    // Debug with GDB
    const debug_step = b.step("debug", "Build and run in QEMU with GDB stub");
    const debug_cmd = b.addSystemCommand(&.{"./tools/qemu_run.sh"});
    debug_cmd.step.dependOn(b.getInstallStep());
    debug_cmd.setEnvironmentVariable("MOQI_DEBUG", "1");
    debug_step.dependOn(&debug_cmd.step);

    // Tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("tests/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib_test = b.addTest(.{
        .root_module = test_module,
    });
    const run_lib_tests = b.addRunArtifact(lib_test);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_lib_tests.step);
}
