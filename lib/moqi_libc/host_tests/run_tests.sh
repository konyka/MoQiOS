#!/bin/sh
# run_tests.sh — build and run the moqi_libc host unit tests.
#
# Compiles the syscall-free parts of moqi_libc (string, printf formatting
# core, malloc free-list) for the HOST and runs assertions against them.
# Uses private zig cache dirs so it can run alongside `zig build`.
set -e
cd "$(dirname "$0")"

export ZIG_LOCAL_CACHE_DIR=${MOQI_TEST_CACHE:-/tmp/moqi-libc-test-cache}
export ZIG_GLOBAL_CACHE_DIR=${MOQI_TEST_GCACHE:-/tmp/moqi-libc-test-gcache}
OUT=${MOQI_TEST_OUT:-/tmp/moqi-libc-test-bin}
mkdir -p "$OUT"

CC="zig cc"
CFLAGS="-O1 -g -Wall -Wextra -Werror -fno-builtin"

fail=0
for t in test_string test_format test_malloc test_args; do
    echo "== $t =="
    $CC $CFLAGS -o "$OUT/$t" "$t.c"
    "$OUT/$t" || fail=1
done

if [ "$fail" -eq 0 ]; then
    echo "ALL HOST TESTS PASS"
else
    echo "HOST TESTS FAILED"
fi
exit $fail
