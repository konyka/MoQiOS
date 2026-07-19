#!/bin/bash
# Bounded aarch64 QEMU smoke test (Milestone 9-1).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

TIMEOUT_SECONDS="${MOQI_SMOKE_TIMEOUT:-20}"
LOG_FILE="${MOQI_SMOKE_LOG:-/tmp/moqios-smoke-aarch64.log}"
RUN_LOG="${MOQI_SMOKE_RUN_LOG:-/tmp/moqios-smoke-aarch64.run.log}"

if ! command -v qemu-system-aarch64 &>/dev/null; then
    echo "ERROR: qemu-system-aarch64 not found."
    exit 1
fi

if [ "${MOQI_SMOKE_SKIP_BUILD:-0}" != "1" ]; then
    zig build -Darch=aarch64
fi

rm -f "$LOG_FILE" "$RUN_LOG"

MOQI_SERIAL="file:$LOG_FILE" \
./tools/qemu_run_aarch64.sh >"$RUN_LOG" 2>&1 &
QEMU_PID=$!

cleanup() {
    if kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        for _ in 1 2 3 4 5; do
            kill -0 "$QEMU_PID" 2>/dev/null || break
            sleep 0.2
        done
        if kill -0 "$QEMU_PID" 2>/dev/null; then
            kill -9 "$QEMU_PID" 2>/dev/null || true
        fi
        wait "$QEMU_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass_markers() {
    [ -f "$LOG_FILE" ] &&
        grep -q "FDT OK" "$LOG_FILE" &&
        grep -q "M9-1 complete" "$LOG_FILE" &&
        grep -q "brk trap: OK" "$LOG_FILE" &&
        grep -q "M9-2 complete" "$LOG_FILE" &&
        grep -q "page-fault trap: OK" "$LOG_FILE" &&
        grep -q "M9-3 complete" "$LOG_FILE" &&
        grep -q "timer firings=" "$LOG_FILE" &&
        grep -q "M9-4 complete" "$LOG_FILE" &&
        grep -q "timer IRQ firings=" "$LOG_FILE" &&
        grep -q "M9-5 complete" "$LOG_FILE" &&
        grep -q "hello from U" "$LOG_FILE" &&
        grep -q "M9-6 complete" "$LOG_FILE" &&
        grep -q "preemptive switches=" "$LOG_FILE" &&
        grep -q "M9-7 complete" "$LOG_FILE" &&
        grep -q "\[SK-2\] shared kernel subset: OK" "$LOG_FILE" &&
        grep -q "\[SK-3\] shared allowlist: OK" "$LOG_FILE" &&
        grep -q "\[SK-4\] portable irq_spinlock: OK" "$LOG_FILE" &&
        grep -q "\[SK-6\] unified pmm+slab: OK" "$LOG_FILE" &&
        grep -q "\[SK-7\] serial via arch facade: OK" "$LOG_FILE" &&
        grep -q "\[SK-8\] paging/tsc/tlb via facade: OK" "$LOG_FILE" &&
        grep -q "\[SK-9\] idt/gdt/syscall/io via facade: OK" "$LOG_FILE" &&
        grep -q "\[SK-10\] smp/acpi/pci isolated: OK" "$LOG_FILE" &&
        grep -q "\[SK-11\] sched/task via paging+syscall facade: OK" "$LOG_FILE" &&
        grep -q "\[SK-12\] shared sched create+idle callable: OK" "$LOG_FILE" &&
        grep -q "\[SK-13\] shared InterruptFrame+anchor: OK" "$LOG_FILE" &&
        grep -q "\[SK-14\] software-frame enter: OK" "$LOG_FILE" &&
        grep -q "\[SK-15\] shared preempt: OK" "$LOG_FILE" &&
        grep -q "\[SK-16\] shared milestone preempt: OK" "$LOG_FILE" &&
        grep -q "\[SK-17\] shared sched queue+pick: OK" "$LOG_FILE" &&
        grep -q "\[SK-18\] shared sched wake+block: OK" "$LOG_FILE" &&
        grep -q "\[SK-19\] shared sleepOn+sched_boot: OK" "$LOG_FILE" &&
        grep -q "\[SK-20\] portable sleepOn switch: OK" "$LOG_FILE" &&
        grep -q "\[SK-21\] shared subsystem boot: OK" "$LOG_FILE" &&
        grep -q "\[SK-22\] portable timerTick: OK" "$LOG_FILE" &&
        grep -q "\[SK-23\] irq ticks wired to timeslice: OK" "$LOG_FILE" &&
        grep -q "\[SK-24\] irq software-frame preempt: OK" "$LOG_FILE" &&
        grep -q "\[SK-25\] shared portable mm boot: OK" "$LOG_FILE" &&
        grep -q "\[SK-26\] user timer IRQ visible: OK" "$LOG_FILE" &&
        grep -q "\[SK-27\] user trapframe preempt: OK" "$LOG_FILE" &&
        grep -q "\[SK-28\] dual-user trapframe preempt: OK" "$LOG_FILE" &&
        grep -q "\[SK-29\] sched native-user preempt: OK" "$LOG_FILE" &&
        grep -q "\[SK-30\] timeslice native-user preempt: OK" "$LOG_FILE" &&
        grep -q "\[SK-31\] default timer native-user preempt: OK" "$LOG_FILE" &&
        grep -q "\[SK-32\] shared sk probes+slab boot: OK" "$LOG_FILE" &&
        grep -q "\[SK-33\] shared page_cache boot: OK" "$LOG_FILE" &&
        grep -q "\[SK-34\] shared tmpfs+random boot: OK" "$LOG_FILE" &&
        grep -q "\[SK-35\] shared cpu surfaces+symbol table: OK" "$LOG_FILE" &&
        grep -q "\[SK-36\] probe ladder cleanup: OK" "$LOG_FILE" &&
        grep -q "\[SK-37\] slim task/symbol footprint: OK" "$LOG_FILE" &&
        grep -q "\[SK-38\] slim env buffers: OK" "$LOG_FILE" &&
        grep -q "\[SK-39\] slim fd table: OK" "$LOG_FILE" &&
        grep -q "\[SK-40\] portable copy_from_user: OK" "$LOG_FILE" &&
        grep -q "\[SK-41\] user write via shared copy: OK" "$LOG_FILE" &&
        grep -q "\[SK-42\] shared idle boot fragment: OK" "$LOG_FILE" &&
        grep -q "\[SK-43\] shared ramdisk parse: OK" "$LOG_FILE" &&
        grep -q "\[SK-44\] shared elf header parse: OK" "$LOG_FILE" &&
        grep -q "\[SK-45\] shared user stack build: OK" "$LOG_FILE" &&
        grep -q "\[SK-46\] shared writeback cache: OK" "$LOG_FILE" &&
        grep -q "\[SK-47\] shared ipv4 header/checksum: OK" "$LOG_FILE" &&
        grep -q "\[SK-48\] shared ipv6 header/pseudo-csum: OK" "$LOG_FILE"
}

deadline=$((SECONDS + TIMEOUT_SECONDS))
while [ "$SECONDS" -lt "$deadline" ]; do
    if pass_markers; then
        echo "PASS: MoQiOS aarch64 M9-7+SK-48 smoke (shared probes + slim footprint/env + default timer + EL0/SVC)."
        echo "Serial log: $LOG_FILE"
        exit 0
    fi

    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        if pass_markers; then
            echo "PASS: MoQiOS aarch64 M9-7+SK-48 smoke (shared probes + slim footprint/env + default timer + EL0/SVC)."
            echo "Serial log: $LOG_FILE"
            exit 0
        fi
        echo "ERROR: QEMU exited before aarch64 smoke markers appeared."
        echo "QEMU log: $RUN_LOG"
        echo "Serial log: $LOG_FILE"
        exit 1
    fi

    sleep 0.2
done

echo "ERROR: timed out after ${TIMEOUT_SECONDS}s waiting for aarch64 smoke markers."
echo "Expected: SK-2..SK-4 + SK-6..SK-48 shared markers + M9-1..M9-7 markers."
echo "QEMU log: $RUN_LOG"
echo "Serial log: $LOG_FILE"
exit 1
