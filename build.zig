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

    // --- hello5 user program (C, tests argc/argv) ---
    const hello5_elf = b.addSystemCommand(&.{
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
    hello5_elf.addArg("user/hello5.elf");
    hello5_elf.addFileArg(b.path("user/hello5.c"));
    hello5_elf.setName("compile hello5.c -> ELF");

    const hello5_strip = b.addSystemCommand(&.{
        "strip",
        "-o",
    });
    hello5_strip.addArg("user/hello5.bin");
    hello5_strip.addArg("user/hello5.elf");
    hello5_strip.step.dependOn(&hello5_elf.step);
    hello5_strip.setName("strip hello5.elf");

    b.getInstallStep().dependOn(&hello5_strip.step);

    // --- hello6 user program (C, tests keyboard stdin read) ---
    const hello6_elf = b.addSystemCommand(&.{
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
    hello6_elf.addArg("user/hello6.elf");
    hello6_elf.addFileArg(b.path("user/hello6.c"));
    hello6_elf.setName("compile hello6.c -> ELF");

    const hello6_strip = b.addSystemCommand(&.{
        "strip",
        "-o",
    });
    hello6_strip.addArg("user/hello6.bin");
    hello6_strip.addArg("user/hello6.elf");
    hello6_strip.step.dependOn(&hello6_elf.step);
    hello6_strip.setName("strip hello6.elf");

    b.getInstallStep().dependOn(&hello6_strip.step);

    const hello7_elf = b.addSystemCommand(&.{
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
    hello7_elf.addArg("user/hello7.elf");
    hello7_elf.addFileArg(b.path("user/hello7.c"));
    hello7_elf.setName("compile hello7.c -> ELF");

    const hello7_strip = b.addSystemCommand(&.{
        "strip",
        "-o",
    });
    hello7_strip.addArg("user/hello7.bin");
    hello7_strip.addArg("user/hello7.elf");
    hello7_strip.step.dependOn(&hello7_elf.step);
    hello7_strip.setName("strip hello7.elf");

    b.getInstallStep().dependOn(&hello7_strip.step);

    const hello8_elf = b.addSystemCommand(&.{
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
    hello8_elf.addArg("user/hello8.elf");
    hello8_elf.addFileArg(b.path("user/hello8.c"));
    hello8_elf.setName("compile hello8.c -> ELF");

    const hello8_strip = b.addSystemCommand(&.{
        "strip",
        "-o",
    });
    hello8_strip.addArg("user/hello8.bin");
    hello8_strip.addArg("user/hello8.elf");
    hello8_strip.step.dependOn(&hello8_elf.step);
    hello8_strip.setName("strip hello8.elf");

    b.getInstallStep().dependOn(&hello8_strip.step);

    const sh_elf = b.addSystemCommand(&.{
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
    sh_elf.addArg("user/sh.elf");
    sh_elf.addFileArg(b.path("user/sh.c"));
    sh_elf.setName("compile sh.c -> ELF");

    const sh_strip = b.addSystemCommand(&.{
        "strip",
        "-o",
    });
    sh_strip.addArg("user/sh.bin");
    sh_strip.addArg("user/sh.elf");
    sh_strip.step.dependOn(&sh_elf.step);
    sh_strip.setName("strip sh.elf");

    b.getInstallStep().dependOn(&sh_strip.step);

    const hello9_elf = b.addSystemCommand(&.{
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
    hello9_elf.addArg("user/hello9.elf");
    hello9_elf.addFileArg(b.path("user/hello9.c"));
    hello9_elf.setName("compile hello9.c -> ELF");

    const hello9_strip = b.addSystemCommand(&.{
        "strip",
        "-o",
    });
    hello9_strip.addArg("user/hello9.bin");
    hello9_strip.addArg("user/hello9.elf");
    hello9_strip.step.dependOn(&hello9_elf.step);
    hello9_strip.setName("strip hello9.elf");

    b.getInstallStep().dependOn(&hello9_strip.step);

    const hello10_elf = b.addSystemCommand(&.{
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
    hello10_elf.addArg("user/hello10.elf");
    hello10_elf.addFileArg(b.path("user/hello10.c"));
    hello10_elf.setName("compile hello10.c -> ELF");

    const hello10_strip = b.addSystemCommand(&.{
        "strip",
        "-o",
    });
    hello10_strip.addArg("user/hello10.bin");
    hello10_strip.addArg("user/hello10.elf");
    hello10_strip.step.dependOn(&hello10_elf.step);
    hello10_strip.setName("strip hello10.elf");

    b.getInstallStep().dependOn(&hello10_strip.step);

    const hello11_elf = b.addSystemCommand(&.{
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
    hello11_elf.addArg("user/hello11.elf");
    hello11_elf.addFileArg(b.path("user/hello11.c"));
    hello11_elf.setName("compile hello11.c -> ELF");

    const hello11_strip = b.addSystemCommand(&.{
        "strip",
        "-o",
    });
    hello11_strip.addArg("user/hello11.bin");
    hello11_strip.addArg("user/hello11.elf");
    hello11_strip.step.dependOn(&hello11_elf.step);
    hello11_strip.setName("strip hello11.elf");

    b.getInstallStep().dependOn(&hello11_strip.step);

    const hello12_elf = b.addSystemCommand(&.{
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
    hello12_elf.addArg("user/hello12.elf");
    hello12_elf.addFileArg(b.path("user/hello12.c"));
    hello12_elf.setName("compile hello12.c -> ELF");

    const hello12_strip = b.addSystemCommand(&.{
        "strip",
        "-o",
    });
    hello12_strip.addArg("user/hello12.bin");
    hello12_strip.addArg("user/hello12.elf");
    hello12_strip.step.dependOn(&hello12_elf.step);
    hello12_strip.setName("strip hello12.elf");

    b.getInstallStep().dependOn(&hello12_strip.step);

    const hello13_elf = b.addSystemCommand(&.{
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
    hello13_elf.addArg("user/hello13.elf");
    hello13_elf.addFileArg(b.path("user/hello13.c"));
    hello13_elf.setName("compile hello13.c -> ELF");

    const hello13_strip = b.addSystemCommand(&.{
        "strip",
        "-o",
    });
    hello13_strip.addArg("user/hello13.bin");
    hello13_strip.addArg("user/hello13.elf");
    hello13_strip.step.dependOn(&hello13_elf.step);
    hello13_strip.setName("strip hello13.elf");

    b.getInstallStep().dependOn(&hello13_strip.step);

    const hello14_elf = b.addSystemCommand(&.{
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
    hello14_elf.addArg("user/hello14.elf");
    hello14_elf.addFileArg(b.path("user/hello14.c"));
    hello14_elf.setName("compile hello14.c -> ELF");

    const hello14_strip = b.addSystemCommand(&.{
        "strip",
        "-o",
    });
    hello14_strip.addArg("user/hello14.bin");
    hello14_strip.addArg("user/hello14.elf");
    hello14_strip.step.dependOn(&hello14_elf.step);
    hello14_strip.setName("strip hello14.elf");

    b.getInstallStep().dependOn(&hello14_strip.step);

    const hello15_elf = b.addSystemCommand(&.{
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
    hello15_elf.addArg("user/hello15.elf");
    hello15_elf.addFileArg(b.path("user/hello15.c"));
    hello15_elf.setName("compile hello15.c -> ELF");

    const hello15_strip = b.addSystemCommand(&.{
        "strip",
        "-o",
    });
    hello15_strip.addArg("user/hello15.bin");
    hello15_strip.addArg("user/hello15.elf");
    hello15_strip.step.dependOn(&hello15_elf.step);
    hello15_strip.setName("strip hello15.elf");

    b.getInstallStep().dependOn(&hello15_strip.step);

    const hello16_elf = b.addSystemCommand(&.{
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
    hello16_elf.addArg("user/hello16.elf");
    hello16_elf.addFileArg(b.path("user/hello16.c"));
    hello16_elf.setName("compile hello16.c -> ELF");

    const hello16_strip = b.addSystemCommand(&.{
        "strip",
        "-o",
    });
    hello16_strip.addArg("user/hello16.bin");
    hello16_strip.addArg("user/hello16.elf");
    hello16_strip.step.dependOn(&hello16_elf.step);
    hello16_strip.setName("strip hello16.elf");

    b.getInstallStep().dependOn(&hello16_strip.step);

    const hello17_elf = b.addSystemCommand(&.{
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
    hello17_elf.addArg("user/hello17.elf");
    hello17_elf.addFileArg(b.path("user/hello17.c"));
    hello17_elf.setName("compile hello17.c -> ELF");

    const hello17_strip = b.addSystemCommand(&.{
        "strip",
        "-o",
    });
    hello17_strip.addArg("user/hello17.bin");
    hello17_strip.addArg("user/hello17.elf");
    hello17_strip.step.dependOn(&hello17_elf.step);
    hello17_strip.setName("strip hello17.elf");

    b.getInstallStep().dependOn(&hello17_strip.step);

    const hello18_elf = b.addSystemCommand(&.{
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
    hello18_elf.addArg("user/hello18.elf");
    hello18_elf.addFileArg(b.path("user/hello18.c"));
    hello18_elf.setName("compile hello18.c -> ELF");

    const hello18_strip = b.addSystemCommand(&.{
        "strip",
        "-o",
    });
    hello18_strip.addArg("user/hello18.bin");
    hello18_strip.addArg("user/hello18.elf");
    hello18_strip.step.dependOn(&hello18_elf.step);
    hello18_strip.setName("strip hello18.elf");

    b.getInstallStep().dependOn(&hello18_strip.step);

    const hello19_elf = b.addSystemCommand(&.{
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
    hello19_elf.addArg("user/hello19.elf");
    hello19_elf.addFileArg(b.path("user/hello19.c"));
    hello19_elf.setName("compile hello19.c -> ELF");

    const hello19_strip = b.addSystemCommand(&.{
        "strip",
        "-o",
    });
    hello19_strip.addArg("user/hello19.bin");
    hello19_strip.addArg("user/hello19.elf");
    hello19_strip.step.dependOn(&hello19_elf.step);
    hello19_strip.setName("strip hello19.elf");

    b.getInstallStep().dependOn(&hello19_strip.step);

    const hello20_elf = b.addSystemCommand(&.{
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
    hello20_elf.addArg("user/hello20.elf");
    hello20_elf.addFileArg(b.path("user/hello20.c"));
    hello20_elf.setName("compile hello20.c -> ELF");

    const hello20_strip = b.addSystemCommand(&.{
        "strip",
        "-o",
    });
    hello20_strip.addArg("user/hello20.bin");
    hello20_strip.addArg("user/hello20.elf");
    hello20_strip.step.dependOn(&hello20_elf.step);
    hello20_strip.setName("strip hello20.elf");

    b.getInstallStep().dependOn(&hello20_strip.step);

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
