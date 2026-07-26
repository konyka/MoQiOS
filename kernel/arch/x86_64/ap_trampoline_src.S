/*
 * AP Trampoline — precompiled flat binary embedded via @embedFile.
 *
 * Runs at physical 0x8000 after SIPI (vector 0x08).
 * Transitions: real mode → protected mode → long mode → jump to kernel.
 *
 * Data area at 0x7000 (set by BSP):
 *   0x7000: PML4 physical address (u64)
 *   7010: AP stack top (u64)
 *   7020: GDT pseudo-descriptor (2 limit + 8 base)
 *   7030: Entry function address (u64)
 *   7040: CPU ID (u32)
 *   7050: PerCpu virtual address (u64)
 *   7060: Magic write area (u32, pre-paging)
 *   7070: HHDM offset (u64, M8-5b-0 — reserved for naked apEntry relocation)
 *   7080: AP startup request token (u64)
 *   7088: AP startup acknowledgement token (u64)
 */

.code16
.text
.org 0x00
.global _start
_start:
    cli
    xor %ax, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss

    /* Load temporary GDT */
    lgdt gdt_temp_ptr

    /* Enable protected mode */
    mov %cr0, %eax
    or $0x1, %eax
    mov %eax, %cr0

    /* Far jump to 32-bit code (flushes prefetch queue) */
    ljmpl $0x08, $0x8040

.org 0x40
.code32
pm_entry:
    /* Load 32-bit data segments */
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    mov %ax, %ss

    /* Debug: 'B' — in protected mode */
    mov $0x3F8, %dx
    mov $'B', %al
    outb %al, %dx

    /* Load PML4 into CR3 */
    mov 0x7000, %eax
    mov %eax, %cr3

    /* Enable PAE */
    mov %cr4, %eax
    or $(1 << 5), %eax
    mov %eax, %cr4

    /* Enable long mode (EFER.LME) + No-Execute Enable (EFER.NXE).
       NXE (bit 11) is REQUIRED: the kernel page tables set the NX bit (63) on
       non-executable pages (e.g. the LAPIC MMIO mapping). With NXE=0 bit 63 is
       reserved, so the AP would take a reserved-bit page fault when its cold TLB
       walks any NX entry — the BSP avoids this only because it set NXE at boot. */
    mov $0xC0000080, %ecx
    rdmsr
    or $((1 << 8) | (1 << 11)), %eax
    wrmsr

    /* Enable paging */
    mov %cr0, %eax
    or $(1 << 31), %eax
    mov %eax, %cr0

    /* Far jump to 64-bit code */
    ljmpl $0x18, $0x80B0

.org 0xB0
.code64
lm_entry:
    /* Debug: 'C' — in long mode */
    mov $0x3F8, %dx
    mov $'C', %al
    outb %al, %dx

    /* Load AP stack */
    mov 0x7010, %rsp

    /* Debug: 'D' — stack loaded */
    mov $0x3F8, %dx
    mov $'D', %al
    outb %al, %dx

    /* Jump directly to the kernel entry (HHDM virtual address at 0x7030).
     * M8-5b-0: BSP stores the high-half virt entry + stack so the AP never
     * executes in the identity-mapped low region after this point. */
    mov 0x7030, %rax
    jmp *%rax

.org 0x140
gdt_temp:
    .quad 0                                    /* null */
    .quad 0x00CF9A000000FFFF                   /* 32-bit code: base=0, limit=4GB, G=1, D=1, L=0, exec */
    .quad 0x00CF92000000FFFF                   /* data: base=0, limit=4GB, G=1, B=1, r/w */
    .quad 0x00209A0000000000                   /* 64-bit code: L=1, exec */
gdt_temp_ptr:
    .short 31                     /* limit = 4 entries * 8 - 1 */
    .long 0x8140                  /* base = physical addr of gdt_temp (32-bit) */

.global ap_trampoline_end
ap_trampoline_end:
