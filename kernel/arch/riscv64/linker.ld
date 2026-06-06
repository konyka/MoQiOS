/* RISC-V 64 kernel skeleton linker script — Milestone 1.
 *
 * QEMU `virt` + OpenSBI (`-bios default`) reserve 0x80000000..0x80200000 for
 * firmware and jump to the next-stage payload at 0x80200000. We link the kernel
 * there. `-kernel kernel.elf` makes QEMU load by program headers (LMA = these
 * addresses) and OpenSBI branches to the ELF entry (_start) in S-mode.
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = 0x80200000;

    .text : ALIGN(4K) {
        *(.text.boot)
        *(.text .text.*)
    }

    .rodata : ALIGN(4K) {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    }

    .data : ALIGN(4K) {
        *(.data .data.*)
        *(.sdata .sdata.*)
    }

    .bss : ALIGN(4K) {
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    }

    . = ALIGN(4K);
    __kernel_end = .;

    /DISCARD/ : {
        *(.eh_frame .eh_frame.*)
        *(.note .note.*)
        *(.comment)
    }
}
