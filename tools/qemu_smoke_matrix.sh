#!/bin/bash
# Configurable sequential CPU smoke matrix with isolated artifacts per run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

MATRIX_WORK_DIR="${MOQI_SMOKE_MATRIX_WORK_DIR:-$(mktemp -d "/tmp/moqios-smoke-matrix-XXXXXX")}"
MATRIX_COUNTS="${MOQI_SMOKE_MATRIX_CPUS:-1 2 3 4 6 8}"

if [ -z "$MATRIX_COUNTS" ]; then
    echo "ERROR: MOQI_SMOKE_MATRIX_CPUS must contain positive decimal CPU counts."
    exit 2
fi

for smp_count in $MATRIX_COUNTS; do
    if ! [[ "$smp_count" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: MOQI_SMOKE_MATRIX_CPUS contains invalid CPU count '$smp_count'."
        exit 2
    fi
done

run=0
mkdir -p "$MATRIX_WORK_DIR"
for smp_count in $MATRIX_COUNTS; do
    run=$((run + 1))
    run_dir="$(mktemp -d "$MATRIX_WORK_DIR/run-${run}-smp${smp_count}-XXXXXX")"
    echo "[smoke-smp-matrix] SMP=${smp_count} (${run})"
    MOQI_SMOKE_WORK_DIR="$run_dir" \
    MOQI_SMOKE_SKIP_BUILD="${MOQI_SMOKE_SKIP_BUILD:-0}" \
    "$SCRIPT_DIR/qemu_smoke.sh" "$smp_count"
done

echo "PASS: MoQiOS CPU smoke matrix (${MATRIX_COUNTS}) reached shell."
