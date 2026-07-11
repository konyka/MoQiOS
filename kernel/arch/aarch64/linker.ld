/* AArch64 kernel skeleton linker script — Milestone 9 (M1-equivalent).
 *
 * QEMU `virt` with `-kernel` loads the ELF at DRAM base 0x40000000 and jumps
 * to ENTRY in EL1 with x0 = DTB. Link the kernel there.
 */

OUTPUT_ARCH(aarch64)
ENTRY(_start)

SECTIONS
{
    . = 0x40000000;

    .text : ALIGN(4K) {
        *(.text.boot)
        *(.text.vectors)
        *(.text .text.*)
    }

    .rodata : ALIGN(4K) {
        *(.rodata .rodata.*)
    }

    .data : ALIGN(4K) {
        *(.data .data.*)
    }

    .bss : ALIGN(4K) {
        __bss_start = .;
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
