#!/bin/bash
# Contract test for tools/qemu_smoke.sh: when a smoke run fails, the serial log it points the user at must still
# exist afterwards. The cleanup trap used to delete the work directory on every exit, so the "Serial log: ..." line
# of a failing run named a file that was already gone (an intermittent failure then left nothing to look at).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SMOKE="$PROJECT_DIR/tools/qemu_smoke.sh"

pass=0
fail=0
ok() { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# 1. The failure branches must save the log before the cleanup trap removes the work directory.
if grep -q "MOQI_SMOKE_KEEP_FAIL_LOG" "$SMOKE"; then
    ok "qemu_smoke.sh has a failure-log preservation hook"
else
    bad "qemu_smoke.sh has no failure-log preservation hook"
fi

# 2. The cleanup function consults the exit status: a failing run keeps its serial log.
cleanup_body="$(sed -n '/^cleanup() {/,/^}/p' "$SMOKE")"
if printf '%s' "$cleanup_body" | grep -q 'keep_failed_log'; then
    ok "cleanup() calls keep_failed_log"
else
    bad "cleanup() does not call keep_failed_log"
fi

# 3. Behaviour: source the helper and run it against a fake work dir with a log.
helper="$(sed -n '/^keep_failed_log() {/,/^}/p' "$SMOKE")"
if [ -z "$helper" ]; then
    bad "keep_failed_log() is not defined"
else
    work="$(mktemp -d "${TMPDIR:-/tmp}/moqios-keeplog-test.XXXXXX")"
    trap 'rm -rf -- "$work" "${kept:-}"' EXIT
    printf 'hello176: FAIL D\n' > "$work/serial.log"
    kept="$work.kept"
    eval "$helper"
    LOG_FILE="$work/serial.log" MOQI_SMOKE_KEEP_FAIL_LOG="$kept" keep_failed_log 1
    if [ -f "$kept" ] && grep -q 'hello176: FAIL D' "$kept"; then
        ok "a failing exit status copies the serial log to the preserved path"
    else
        bad "a failing exit status did not preserve the serial log"
    fi
    rm -f "$kept"
    LOG_FILE="$work/serial.log" MOQI_SMOKE_KEEP_FAIL_LOG="$kept" keep_failed_log 0
    if [ ! -e "$kept" ]; then
        ok "a passing exit status preserves nothing"
    else
        bad "a passing exit status left a preserved log"
    fi
    rm -f "$kept"
    LOG_FILE="$work/missing.log" MOQI_SMOKE_KEEP_FAIL_LOG="$kept" keep_failed_log 1
    if [ ! -e "$kept" ]; then
        ok "a missing log is tolerated (nothing to preserve)"
    else
        bad "a missing log produced a preserved file"
    fi
fi

# 4. The PASS markers take a while to check and the FAIL check needs the shell banner, so a test that failed before a banner that
# appeared during the marker scan used to be reported as PASS. The PASS branch must re-run the fatal checks before it exits 0.
pass_line="$(grep -n 'echo "PASS: MoQiOS x86_64 smoke' "$SMOKE" | head -1 | cut -d: -f1)"
if [ -n "$pass_line" ] && sed -n "$((pass_line - 1))p" "$SMOKE" | grep -q '^ *check_fatal_output$'; then
    ok "the PASS branch re-runs check_fatal_output right before reporting PASS"
else
    bad "the PASS branch reports PASS without re-running check_fatal_output"
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
