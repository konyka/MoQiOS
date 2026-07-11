#!/bin/bash
# Bounded riscv64 QEMU smoke test (Milestone 2+).
#
# Builds (unless skipped), runs the riscv64 kernel under OpenSBI, and checks
# for the M2 completion markers on the serial log.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

TIMEOUT_SECONDS="${MOQI_SMOKE_TIMEOUT:-30}"
LOG_FILE="${MOQI_SMOKE_LOG:-/tmp/moqios-smoke-riscv64.log}"
RUN_LOG="${MOQI_SMOKE_RUN_LOG:-/tmp/moqios-smoke-riscv64.run.log}"

if ! command -v qemu-system-riscv64 &>/dev/null; then
    echo "ERROR: qemu-system-riscv64 not found."
    exit 1
fi

if [ "${MOQI_SMOKE_SKIP_BUILD:-0}" != "1" ]; then
    zig build -Darch=riscv64
fi

rm -f "$LOG_FILE" "$RUN_LOG"

MOQI_SERIAL="file:$LOG_FILE" \
./tools/qemu_run_riscv64.sh >"$RUN_LOG" 2>&1 &
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

deadline=$((SECONDS + TIMEOUT_SECONDS))
while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -f "$LOG_FILE" ] &&
       grep -q "breakpoint trap: OK" "$LOG_FILE" &&
       grep -q "M2 complete" "$LOG_FILE"; then
        echo "PASS: MoQiOS riscv64 M2 smoke (UART16550 + stvec breakpoint)."
        echo "Serial log: $LOG_FILE"
        exit 0
    fi

    # Kernel shuts down via SBI after M2 — QEMU may exit before we poll.
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        if [ -f "$LOG_FILE" ] &&
           grep -q "breakpoint trap: OK" "$LOG_FILE" &&
           grep -q "M2 complete" "$LOG_FILE"; then
            echo "PASS: MoQiOS riscv64 M2 smoke (UART16550 + stvec breakpoint)."
            echo "Serial log: $LOG_FILE"
            exit 0
        fi
        echo "ERROR: QEMU exited before riscv64 smoke markers appeared."
        echo "QEMU log: $RUN_LOG"
        echo "Serial log: $LOG_FILE"
        exit 1
    fi

    sleep 0.2
done

echo "ERROR: timed out after ${TIMEOUT_SECONDS}s waiting for riscv64 smoke markers."
echo "Expected: 'breakpoint trap: OK' and 'M2 complete'."
echo "QEMU log: $RUN_LOG"
echo "Serial log: $LOG_FILE"
exit 1
