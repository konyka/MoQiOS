#!/bin/bash
# Repeated multicore boot-to-shell gate for SMP timing regressions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

RUNS="${MOQI_SMOKE_RUNS:-5}"
SMP_COUNT="${MOQI_SMP:-${MOQI_SMOKE_STRESS_SMP:-2}}"
if ! [[ "$RUNS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: MOQI_SMOKE_RUNS must be a positive integer."
    exit 2
fi
if ! [[ "$SMP_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: MOQI_SMP must be a positive decimal integer (got '$SMP_COUNT')."
    exit 2
fi

if [ -n "${MOQI_SMOKE_STRESS_WORK_DIR:-}" ]; then
    STRESS_WORK_DIR="$MOQI_SMOKE_STRESS_WORK_DIR"
else
    STRESS_WORK_DIR="$(mktemp -d "/tmp/moqios-smoke-stress-smp${SMP_COUNT}-XXXXXX")"
fi
mkdir -p "$STRESS_WORK_DIR"

for ((run = 1; run <= RUNS; run += 1)); do
    run_dir="$(mktemp -d "$STRESS_WORK_DIR/run-${run}-XXXXXX")"
    echo "[smoke-smp-stress] SMP=${SMP_COUNT} run ${run}/${RUNS}"
    MOQI_SMOKE_WORK_DIR="$run_dir" \
    MOQI_SMOKE_SKIP_BUILD="${MOQI_SMOKE_SKIP_BUILD:-0}" \
    "$SCRIPT_DIR/qemu_smoke.sh" "$SMP_COUNT"
done

echo "PASS: ${RUNS} consecutive MoQiOS ${SMP_COUNT}-core smoke runs reached shell."
