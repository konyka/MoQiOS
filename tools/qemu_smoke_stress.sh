#!/bin/bash
# Repeated dual-core boot-to-shell gate for SMP timing regressions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

RUNS="${MOQI_SMOKE_RUNS:-5}"
if ! [[ "$RUNS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: MOQI_SMOKE_RUNS must be a positive integer."
    exit 2
fi

for ((run = 1; run <= RUNS; run += 1)); do
    echo "[smoke-smp-stress] run ${run}/${RUNS}"
    MOQI_SMOKE_LOG="/tmp/moqios-smoke-smp2-${run}.log" \
    MOQI_SMOKE_RUN_LOG="/tmp/moqios-smoke-smp2-${run}.run.log" \
    MOQI_SMOKE_DISK="/tmp/moqios-smoke-smp2-${run}.disk.img" \
    MOQI_SMOKE_SKIP_BUILD="${MOQI_SMOKE_SKIP_BUILD:-0}" \
    "$SCRIPT_DIR/qemu_smoke.sh" 2
done

echo "PASS: ${RUNS} consecutive MoQiOS dual-core smoke runs reached shell."
