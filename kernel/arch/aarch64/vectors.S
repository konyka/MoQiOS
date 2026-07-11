/* AArch64 EL1 exception vector table — Milestone 9-2/9-5/9-6.
 *
 * VBAR_EL1 points here. Each entry is 0x80 bytes; table is 0x800-aligned.
 * Current-EL SP_ELx: Sync @ 0x200, IRQ @ 0x280
 * Lower-EL AArch64: Sync @ 0x400 (SVC from EL0)
 */

.global exception_vectors
.global sync_el1h_entry
.global irq_el1h_entry
.global sync_el0_entry

.section .text.vectors, "ax", @progbits
.balign 0x800
exception_vectors:
    /* Current EL, SP_EL0 */
    b       hang
    .balign 0x80
    b       hang
    .balign 0x80
    b       hang
    .balign 0x80
    b       hang
    .balign 0x80
    /* Current EL, SP_ELx — Sync / IRQ / FIQ / SError */
    b       sync_el1h_entry
    .balign 0x80
    b       irq_el1h_entry
    .balign 0x80
    b       hang
    .balign 0x80
    b       hang
    .balign 0x80
    /* Lower EL, AArch64 — Sync / IRQ / FIQ / SError */
    b       sync_el0_entry
    .balign 0x80
    b       irq_el1h_entry
    .balign 0x80
    b       hang
    .balign 0x80
    b       hang
    .balign 0x80
    /* Lower EL, AArch32 */
    b       hang
    .balign 0x80
    b       hang
    .balign 0x80
    b       hang
    .balign 0x80
    b       hang

hang:
    wfi
    b       hang

.balign 0x80
sync_el1h_entry:
    sub     sp, sp, #176
    stp     x0, x1, [sp, #0]
    stp     x2, x3, [sp, #16]
    stp     x4, x5, [sp, #32]
    stp     x6, x7, [sp, #48]
    stp     x8, x9, [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    stp     x18, x29, [sp, #144]
    str     x30, [sp, #160]
    mov     x0, sp
    bl      trapHandleSync
    ldr     x30, [sp, #160]
    ldp     x18, x29, [sp, #144]
    ldp     x16, x17, [sp, #128]
    ldp     x14, x15, [sp, #112]
    ldp     x12, x13, [sp, #96]
    ldp     x10, x11, [sp, #80]
    ldp     x8, x9, [sp, #64]
    ldp     x6, x7, [sp, #48]
    ldp     x4, x5, [sp, #32]
    ldp     x2, x3, [sp, #16]
    ldp     x0, x1, [sp, #0]
    add     sp, sp, #176
    eret

.balign 0x80
irq_el1h_entry:
    /* 192-byte frame: GPRs + elr/spsr (needed for preemptive stack switch). */
    sub     sp, sp, #192
    stp     x0, x1, [sp, #0]
    stp     x2, x3, [sp, #16]
    stp     x4, x5, [sp, #32]
    stp     x6, x7, [sp, #48]
    stp     x8, x9, [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    stp     x18, x29, [sp, #144]
    str     x30, [sp, #160]
    mrs     x1, elr_el1
    mrs     x2, spsr_el1
    stp     x1, x2, [sp, #176]
    mov     x0, sp
    bl      trapHandleIrq
    /* x0 = frame to resume (may differ after sched switch). */
    mov     sp, x0
    ldp     x1, x2, [sp, #176]
    msr     elr_el1, x1
    msr     spsr_el1, x2
    ldr     x30, [sp, #160]
    ldp     x18, x29, [sp, #144]
    ldp     x16, x17, [sp, #128]
    ldp     x14, x15, [sp, #112]
    ldp     x12, x13, [sp, #96]
    ldp     x10, x11, [sp, #80]
    ldp     x8, x9, [sp, #64]
    ldp     x6, x7, [sp, #48]
    ldp     x4, x5, [sp, #32]
    ldp     x2, x3, [sp, #16]
    ldp     x0, x1, [sp, #0]
    add     sp, sp, #192
    eret

.balign 0x80
sync_el0_entry:
    sub     sp, sp, #176
    stp     x0, x1, [sp, #0]
    stp     x2, x3, [sp, #16]
    stp     x4, x5, [sp, #32]
    stp     x6, x7, [sp, #48]
    stp     x8, x9, [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    stp     x18, x29, [sp, #144]
    str     x30, [sp, #160]
    mov     x0, sp
    bl      trapHandleSyncEl0
    ldr     x30, [sp, #160]
    ldp     x18, x29, [sp, #144]
    ldp     x16, x17, [sp, #128]
    ldp     x14, x15, [sp, #112]
    ldp     x12, x13, [sp, #96]
    ldp     x10, x11, [sp, #80]
    ldp     x8, x9, [sp, #64]
    ldp     x6, x7, [sp, #48]
    ldp     x4, x5, [sp, #32]
    ldp     x2, x3, [sp, #16]
    ldp     x0, x1, [sp, #0]
    add     sp, sp, #176
    eret
