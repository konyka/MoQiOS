#!/bin/bash
# Bounded x86_64 QEMU smoke test.
#
# The normal run target intentionally leaves QEMU running for interactive shell
# use. This wrapper captures serial output, waits for the full init test marker
# plus shell banner, then terminates QEMU and returns pass/fail.
#
# Uses a private disk image copy so consecutive/parallel smoke runs cannot
# contend on disk.img's write lock.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

SMP_COUNT="${1:-${MOQI_SMP:-1}}"
TIMEOUT_SECONDS="${MOQI_SMOKE_TIMEOUT:-120}"
LOG_FILE="${MOQI_SMOKE_LOG:-/tmp/moqios-smoke-smp${SMP_COUNT}.log}"
RUN_LOG="${MOQI_SMOKE_RUN_LOG:-/tmp/moqios-smoke-smp${SMP_COUNT}.run.log}"
SMOKE_DISK="${MOQI_SMOKE_DISK:-/tmp/moqios-smoke-smp${SMP_COUNT}.disk.img}"

if ! command -v qemu-system-x86_64 &>/dev/null; then
    echo "ERROR: qemu-system-x86_64 not found."
    exit 1
fi
if ! command -v xorriso &>/dev/null; then
    echo "ERROR: xorriso not found."
    exit 1
fi

if [ "${MOQI_SMOKE_SKIP_BUILD:-0}" != "1" ]; then
    zig build
fi

if [ ! -f disk.img ]; then
    echo "ERROR: disk.img missing (required by virtio-blk smoke path)."
    exit 1
fi

rm -f "$LOG_FILE" "$RUN_LOG" "$SMOKE_DISK"
cp --reflink=auto disk.img "$SMOKE_DISK"

MOQI_SMP="$SMP_COUNT" \
MOQI_SERIAL="file:$LOG_FILE" \
MOQI_DISK="$SMOKE_DISK" \
./tools/qemu_run.sh >"$RUN_LOG" 2>&1 &
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
    rm -f "$SMOKE_DISK"
}
trap cleanup EXIT

deadline=$((SECONDS + TIMEOUT_SECONDS))
while [ "$SECONDS" -lt "$deadline" ]; do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "ERROR: QEMU exited before smoke markers appeared."
        echo "QEMU log: $RUN_LOG"
        echo "Serial log: $LOG_FILE"
        exit 1
    fi

    if [ -f "$LOG_FILE" ] &&
       grep -q "hello21 done" "$LOG_FILE" &&
       grep -q "hello29: PASS" "$LOG_FILE" &&
       grep -q "hello29: fsync PASS" "$LOG_FILE" &&
       grep -q "hello30: brk/mmap PASS" "$LOG_FILE" &&
       grep -q "hello31: child TLS ok" "$LOG_FILE" &&
       grep -q "hello31: TLS PASS" "$LOG_FILE" &&
       grep -q "MoQiOS shell" "$LOG_FILE"; then
        # A healthy run faults nothing and panics nowhere. Checking the markers
        # alone is not enough: a kernel bug can kill an unrelated task while
        # every test still prints its PASS line.
        if grep -q "\[SEGFAULT\]" "$LOG_FILE"; then
            echo "FAIL: markers present but a process segfaulted (SMP=$SMP_COUNT)."
            grep -A 2 "\[SEGFAULT\]" "$LOG_FILE" | head -20
            echo "Serial log: $LOG_FILE"
            exit 1
        fi
        if grep -q "KERNEL PANIC" "$LOG_FILE"; then
            echo "FAIL: markers present but the kernel panicked (SMP=$SMP_COUNT)."
            grep -A 4 "KERNEL PANIC" "$LOG_FILE" | head -20
            echo "Serial log: $LOG_FILE"
            exit 1
        fi
        echo "PASS: MoQiOS x86_64 smoke reached shell after init auto-tests (SMP=$SMP_COUNT)."
        echo "Serial log: $LOG_FILE"
        exit 0
    fi

    sleep 1
done

echo "ERROR: timed out after ${TIMEOUT_SECONDS}s waiting for smoke markers."
echo "Expected serial markers: 'hello21 done', 'hello29: PASS', 'hello29: fsync PASS', 'hello30: brk/mmap PASS', 'hello31: TLS PASS' and 'MoQiOS shell'."
echo "QEMU log: $RUN_LOG"
echo "Serial log: $LOG_FILE"
exit 1
