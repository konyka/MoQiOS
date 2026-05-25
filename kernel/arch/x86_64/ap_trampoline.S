/*
 * AP trampoline — position-independent code at physical 0x8000
 *
 * This code is COPIED to 0x8000 by the BSP. All addresses are hardcoded
 * physical addresses — no relocations.
 *
 * Data area at 0x7000 (filled by BSP before starting APs):
 *   0x7000: PML4 physical address (8 bytes)
 *   0x7010: AP kernel stack top (8 bytes, virtual address)
 *   0x7020: GDT pointer (2 bytes limit + 6 bytes base)
 *   0x7030: AP entry point (8 bytes, virtual address)
 *   0x7040: CPU ID (4 bytes)
 *   0x7050: PerCpu virtual address for GS base (8 bytes)
 */

.text
.code16

.global ap_trampoline_start
ap_trampoline_start:
    cli
    xor %ax, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss

    /* Load temporary GDT at physical 0x8100 (after this code block) */
    lgdt 0x8100

    /* Enter protected mode */
    mov %cr0, %eax
    or $1, %eax
    mov %eax, %cr0

    /* Far jump to 32-bit code at physical 0x8030 */
    ljmpl $0x08, $0x8030

    /* Pad to offset 0x30 */
    .space 0x30 - (. - ap_trampoline_start)

/* 32-bit protected mode entry at physical 0x8030 */
.code32
pm_entry:
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    mov %ax, %ss
    mov $0x9000, %esp

    /* Load PML4 (physical address at data area 0x7000) */
    mov 0x7000, %eax
    mov %eax, %cr3

    /* Enable PAE */
    mov %cr4, %eax
    or $(1 << 5), %eax
    mov %eax, %cr4

    /* Enable long mode (EFER bit 8) */
    mov $0xC0000080, %ecx
    rdmsr
    or $(1 << 8), %eax
    wrmsr

    /* Enable paging */
    mov %cr0, %eax
    or $(1 << 31), %eax
    mov %eax, %cr0

    /* Far jump to 64-bit code at identity-mapped 0x8060 */
    ljmpl $0x08, $0x8060

    /* Pad to offset 0x60 */
    .space 0x60 - (. - ap_trampoline_start)

/* 64-bit long mode entry at physical 0x8060 */
.code64
lm_entry:
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    mov %ax, %ss

    /* Load AP stack (virtual address at data area 0x7010) */
    mov 0x7010, %rsp

    /* Load kernel GDT (pointer at data area 0x7020) */
    lgdt 0x7020

    /* Load TSS */
    mov $0x30, %ax
    ltr %ax

    /* Set GS base for PerCpu (address at data area 0x7050) */
    mov 0x7050, %rdx
    mov %rdx, %rax
    shr $32, %rdx
    mov $0xC0000102, %ecx        /* MSR_KERNEL_GS_BASE */
    wrmsr
    mov $0xC0000101, %ecx        /* MSR_GS_BASE */
    wrmsr

    /* Jump to kernel entry point (virtual address at 0x7030) */
    mov 0x7030, %rax
    jmp *%rax

1:  hlt
    jmp 1b

    /* Pad to offset 0x100 for GDT */
    .space 0x100 - (. - ap_trampoline_start)

/* Temporary GDT at physical 0x8100 (offset 0x100) */
gdt_temp:
    .quad 0                       /* null */
    .quad 0x00209A0000000000      /* 64-bit code */
    .quad 0x0000920000000000      /* data */
gdt_temp_ptr:
    .short 23                     /* limit = 3 entries * 8 - 1 */
    .short 0                      /* base bits 0-15 */
    .short 0x8100                 /* base bits 16-31 = physical addr of gdt_temp */

.global ap_trampoline_end
ap_trampoline_end:
