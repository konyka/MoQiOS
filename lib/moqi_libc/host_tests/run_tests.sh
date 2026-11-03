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
CFLAGS="-O1 -g -Wall -Wextra -Werror -fno-builtin -UNDEBUG"

fail=0
for t in test_string test_format test_malloc test_stdlib test_args test_pthread_dead_reap test_pthread_join_claim; do
    echo "== $t =="
    $CC $CFLAGS -o "$OUT/$t" "$t.c"
    "$OUT/$t" || fail=1
done

echo "== test_mkdir_abi =="
$CC $CFLAGS -c ../src/unistd.c -o "$OUT/unistd.o"
$CC $CFLAGS -o "$OUT/test_mkdir_abi" test_mkdir_abi.c "$OUT/unistd.o"
"$OUT/test_mkdir_abi" || fail=1

echo "== test_rlimit_abi =="
$CC $CFLAGS -c ../src/rlimit.c -o "$OUT/rlimit.o"
$CC $CFLAGS -o "$OUT/test_rlimit_abi" test_rlimit_abi.c "$OUT/rlimit.o"
"$OUT/test_rlimit_abi" || fail=1

echo "== test_byteorder =="
$CC $CFLAGS -o "$OUT/test_byteorder" test_byteorder.c
"$OUT/test_byteorder" || fail=1

echo "== test_netdb_abi =="
$CC $CFLAGS -DMOQI_HOST_TEST_SYSCALL -c ../src/netdb.c -o "$OUT/netdb.o"
$CC $CFLAGS -o "$OUT/test_netdb_abi" test_netdb_abi.c "$OUT/netdb.o"
"$OUT/test_netdb_abi" || fail=1

echo "== test_mman_abi =="
$CC $CFLAGS -DMOQI_HOST_TEST_SYSCALL -c ../src/mman.c -o "$OUT/mman.o"
$CC $CFLAGS -o "$OUT/test_mman_abi" test_mman_abi.c "$OUT/mman.o"
"$OUT/test_mman_abi" || fail=1

echo "== test_time_abi =="
$CC $CFLAGS -DMOQI_HOST_TEST_SYSCALL -c ../src/time.c -o "$OUT/time.o"
$CC $CFLAGS -o "$OUT/test_time_abi" test_time_abi.c "$OUT/time.o"
"$OUT/test_time_abi" || fail=1

echo "== test_timeconv_abi =="
$CC $CFLAGS -c ../src/timeconv.c -o "$OUT/timeconv.o"
$CC $CFLAGS -o "$OUT/test_timeconv_abi" test_timeconv_abi.c "$OUT/timeconv.o"
"$OUT/test_timeconv_abi" || fail=1

echo "== test_strptime_abi =="
$CC $CFLAGS -c ../src/timeconv.c -o "$OUT/timeconv_sp.o"
$CC $CFLAGS -o "$OUT/test_strptime_abi" test_strptime_abi.c "$OUT/timeconv_sp.o"
"$OUT/test_strptime_abi" || fail=1

if [ "$fail" -eq 0 ]; then
    echo "ALL HOST TESTS PASS"
else
    echo "HOST TESTS FAILED"
fi
exit $fail
