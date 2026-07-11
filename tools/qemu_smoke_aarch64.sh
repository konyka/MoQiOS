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
        grep -q "\[SK-5\] shared pmm+slab: OK" "$LOG_FILE"
}

deadline=$((SECONDS + TIMEOUT_SECONDS))
while [ "$SECONDS" -lt "$deadline" ]; do
    if pass_markers; then
        echo "PASS: MoQiOS aarch64 M9-7+SK-5 smoke (shared pmm+slab + EL0/SVC + preempt sched)."
        echo "Serial log: $LOG_FILE"
        exit 0
    fi

    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        if pass_markers; then
            echo "PASS: MoQiOS aarch64 M9-7+SK-5 smoke (shared pmm+slab + EL0/SVC + preempt sched)."
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
echo "Expected: SK-2..SK-5 shared markers + M9-1..M9-7 markers."
echo "QEMU log: $RUN_LOG"
echo "Serial log: $LOG_FILE"
exit 1
