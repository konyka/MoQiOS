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
STRICT_SMP="${MOQI_SMOKE_STRICT_SMP:-1}"

if ! [[ "$SMP_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: SMP_COUNT must be a positive decimal integer (got '$SMP_COUNT')."
    exit 2
fi
if ! [[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: MOQI_SMOKE_TIMEOUT must be a positive decimal integer (got '$TIMEOUT_SECONDS')."
    exit 2
fi
if [ "$STRICT_SMP" != "0" ] && [ "$STRICT_SMP" != "1" ]; then
    echo "ERROR: MOQI_SMOKE_STRICT_SMP must be 0 or 1 (got '$STRICT_SMP')."
    exit 2
fi

if [ -n "${MOQI_SMOKE_WORK_DIR:-}" ]; then
    SMOKE_WORK_DIR="$MOQI_SMOKE_WORK_DIR"
else
    SMOKE_WORK_DIR="$(mktemp -d "/tmp/moqios-smoke-smp${SMP_COUNT}-XXXXXX")"
fi
LOG_FILE="${MOQI_SMOKE_LOG:-$SMOKE_WORK_DIR/serial.log}"
RUN_LOG="${MOQI_SMOKE_RUN_LOG:-$SMOKE_WORK_DIR/qemu.run.log}"
SMOKE_DISK="${MOQI_SMOKE_DISK:-$SMOKE_WORK_DIR/disk.img}"
PACKAGE_DIR="${MOQI_SMOKE_PACKAGE_DIR:-$SMOKE_WORK_DIR/package}"
SMOKE_ISO_DIR="$PACKAGE_DIR/iso_root"
SMOKE_ISO_FILE="$PACKAGE_DIR/moqios.iso"
SMOKE_USER_BIN_DIR="$PACKAGE_DIR/user_bin"

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

mkdir -p "$SMOKE_WORK_DIR" "$(dirname "$LOG_FILE")" "$(dirname "$RUN_LOG")" "$(dirname "$SMOKE_DISK")"
if [ -z "${MOQI_SMOKE_LOG:-}" ]; then
    rm -f "$LOG_FILE"
fi
if [ -z "${MOQI_SMOKE_RUN_LOG:-}" ]; then
    rm -f "$RUN_LOG"
fi
if [ -z "${MOQI_SMOKE_DISK:-}" ]; then
    rm -f "$SMOKE_DISK"
fi
if [ -z "${MOQI_SMOKE_PACKAGE_DIR:-}" ]; then
    rm -rf "$PACKAGE_DIR"
fi
mkdir -p "$PACKAGE_DIR"
cp --reflink=auto disk.img "$SMOKE_DISK"

MOQI_SMP="$SMP_COUNT" \
MOQI_SERIAL="file:$LOG_FILE" \
MOQI_DISK="$SMOKE_DISK" \
MOQI_ISO_DIR="$SMOKE_ISO_DIR" \
MOQI_ISO_FILE="$SMOKE_ISO_FILE" \
MOQI_USER_BIN_DIR="$SMOKE_USER_BIN_DIR" \
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
    if [ -z "${MOQI_SMOKE_DISK:-}" ]; then
        rm -f "$SMOKE_DISK"
    fi
    if [ -z "${MOQI_SMOKE_PACKAGE_DIR:-}" ]; then
        rm -rf "$PACKAGE_DIR"
    fi
}
trap cleanup EXIT

has_exact_marker() {
    local marker="$1"
    grep -aFxq "$marker" "$LOG_FILE" || grep -aFxq "${marker}"$'\r' "$LOG_FILE"
}

has_capacity_warning() {
    grep -aEq '\[SMP\].*(capacity|resource|limit|limited|unable|cannot|failed)|SMP.*(capacity|resource|limit|limited|unable|cannot|failed)' "$LOG_FILE"
}

cpu_marker_count() {
    local state="$1"
    local line

    line="$(grep -aE "^\\[SMP\\] [1-9][0-9]* CPUs ${state}" "$LOG_FILE" | tail -n 1 || true)"
    line="${line%$'\r'}"
    if [ -n "$line" ]; then
        printf '%s\n' "${line#'[SMP] '}" | cut -d' ' -f1
    fi
}

check_fatal_output() {
    if [ -f "$LOG_FILE" ] && grep -aq "\[SEGFAULT\]" "$LOG_FILE"; then
        echo "FAIL: a process segfaulted during smoke (SMP=$SMP_COUNT)."
        grep -a -A 2 "\[SEGFAULT\]" "$LOG_FILE" | head -20
        echo "Serial log: $LOG_FILE"
        exit 1
    fi
    if { [ -f "$LOG_FILE" ] && grep -aq "KERNEL PANIC" "$LOG_FILE"; } ||
       { [ -f "$RUN_LOG" ] && grep -aq "KERNEL PANIC" "$RUN_LOG"; }; then
        echo "FAIL: the kernel panicked during smoke (SMP=$SMP_COUNT)."
        grep -a -A 4 "KERNEL PANIC" "$LOG_FILE" "$RUN_LOG" 2>/dev/null | head -20 || true
        echo "Serial log: $LOG_FILE"
        exit 1
    fi
}

deadline=$((SECONDS + TIMEOUT_SECONDS))
while [ "$SECONDS" -lt "$deadline" ]; do
    check_fatal_output

    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "ERROR: QEMU exited before smoke markers appeared."
        echo "QEMU log: $RUN_LOG"
        echo "Serial log: $LOG_FILE"
        exit 1
    fi

    if [ -f "$LOG_FILE" ]; then
        detected_count="$(cpu_marker_count detected)"
        selected_count="$(cpu_marker_count selected)"
        online_count="$(cpu_marker_count online)"

        if [ -n "$selected_count" ] && [ "$selected_count" -lt "$SMP_COUNT" ]; then
            if ! has_capacity_warning; then
                echo "FAIL: kernel selected ${selected_count}/${SMP_COUNT} CPUs without a capacity/resource warning marker."
                echo "Serial log: $LOG_FILE"
                exit 1
            fi
            if [ "$STRICT_SMP" = "1" ]; then
                echo "FAIL: kernel selected ${selected_count}/${SMP_COUNT} CPUs due to a capacity/resource limit."
                echo "Serial log: $LOG_FILE"
                exit 1
            fi
        fi
        if [ -n "$selected_count" ] && [ "$selected_count" -gt "$SMP_COUNT" ]; then
            echo "FAIL: kernel selected ${selected_count} CPUs when QEMU was requested to start ${SMP_COUNT}."
            echo "Serial log: $LOG_FILE"
            exit 1
        fi
        if [ -n "$online_count" ] && [ -n "$selected_count" ] && [ "$online_count" -lt "$selected_count" ]; then
            echo "FAIL: kernel CPU startup shortfall: ${online_count}/${selected_count} selected CPUs came online."
            echo "Serial log: $LOG_FILE"
            exit 1
        fi
        if [ -n "$online_count" ] && [ -n "$selected_count" ] && [ "$online_count" -gt "$selected_count" ]; then
            echo "FAIL: kernel reported ${online_count} online CPUs after selecting only ${selected_count}."
            echo "Serial log: $LOG_FILE"
            exit 1
        fi
        if [ -n "$detected_count" ] && [ -n "$selected_count" ] && [ "$selected_count" -gt "$detected_count" ]; then
            echo "FAIL: kernel reported ${selected_count} selected CPUs but only ${detected_count} detected CPUs."
            echo "Serial log: $LOG_FILE"
            exit 1
        fi
    fi

    if [ -f "$LOG_FILE" ] &&
       grep -q "hello21 done" "$LOG_FILE" &&
       grep -q "hello29: PASS" "$LOG_FILE" &&
       grep -q "hello29: fsync PASS" "$LOG_FILE" &&
       grep -q "hello30: brk/mmap PASS" "$LOG_FILE" &&
       grep -q "hello31: child TLS ok" "$LOG_FILE" &&
       grep -q "hello31: TLS PASS" "$LOG_FILE" &&
       grep -q "hello32: SIGSEGV PASS" "$LOG_FILE" &&
       grep -q "hello33: PASS" "$LOG_FILE" &&
       grep -q "hello34: PASS" "$LOG_FILE" &&
       grep -q "hello35: PASS" "$LOG_FILE" &&
       grep -q "hello36: PASS" "$LOG_FILE" &&
       grep -q "hello37: PASS" "$LOG_FILE" &&
       grep -q "hello38: PASS (futex EFAULT/waitv validation)" "$LOG_FILE" &&
       grep -q "hello39: PASS (socket option faults/address lengths)" "$LOG_FILE" &&
       grep -q "hello40: PASS (IPC_SET and rt_sigsuspend EFAULT)" "$LOG_FILE" &&
       grep -q "hello41: PASS" "$LOG_FILE" &&
       grep -q "MoQiOS shell" "$LOG_FILE" &&
        { [ "$STRICT_SMP" = "0" ] || has_exact_marker "[SMP] ${SMP_COUNT} CPUs detected"; } &&
        { [ "$STRICT_SMP" = "0" ] || has_exact_marker "[SMP] ${SMP_COUNT} CPUs selected"; } &&
        { [ "$STRICT_SMP" = "0" ] || has_exact_marker "[SMP] ${SMP_COUNT} CPUs online"; } &&
        { [ "$STRICT_SMP" = "1" ] || { [ -n "${detected_count:-}" ] && [ -n "${selected_count:-}" ] && [ -n "${online_count:-}" ]; }; }; then
        # A healthy run faults nothing and panics nowhere. Checking the markers
        # alone is not enough: a kernel bug can kill an unrelated task while
        # every test still prints its PASS line.
        echo "PASS: MoQiOS x86_64 smoke reached shell after init auto-tests (SMP=$SMP_COUNT)."
        echo "Serial log: $LOG_FILE"
        exit 0
    fi

    sleep 1
done

echo "ERROR: timed out after ${TIMEOUT_SECONDS}s waiting for smoke markers."
echo "Expected serial markers: init PASS markers, 'hello32: SIGSEGV PASS', 'hello38: PASS (futex EFAULT/waitv validation)', 'hello39: PASS (socket option faults/address lengths)', 'hello40: PASS (IPC_SET and rt_sigsuspend EFAULT)', 'hello41: PASS', 'MoQiOS shell', '[SMP] ${SMP_COUNT} CPUs detected', '[SMP] ${SMP_COUNT} CPUs selected', and '[SMP] ${SMP_COUNT} CPUs online'."
echo "QEMU log: $RUN_LOG"
echo "Serial log: $LOG_FILE"
exit 1
