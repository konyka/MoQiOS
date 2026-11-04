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
for t in test_string test_malloc test_stdlib test_args test_pthread_dead_reap test_pthread_join_claim; do
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

echo "== test_numconv_abi =="
$CC $CFLAGS -c ../src/numconv.c -o "$OUT/numconv.o"
$CC $CFLAGS -o "$OUT/test_numconv_abi" test_numconv_abi.c "$OUT/numconv.o"
"$OUT/test_numconv_abi" || fail=1

echo "== test_strfunc_abi =="
$CC $CFLAGS -c ../src/strfunc.c -o "$OUT/strfunc.o"
$CC $CFLAGS -o "$OUT/test_strfunc_abi" test_strfunc_abi.c "$OUT/strfunc.o"
"$OUT/test_strfunc_abi" || fail=1

echo "== test_format =="
$CC $CFLAGS -c ../src/strfunc.c -o "$OUT/strfunc_fmt.o"
$CC $CFLAGS -o "$OUT/test_format" test_format.c ../src/string.c "$OUT/strfunc_fmt.o"
"$OUT/test_format" || fail=1

echo "== test_printf_abi =="
$CC $CFLAGS -c ../src/strfunc.c -o "$OUT/strfunc_pf.o"
$CC $CFLAGS -o "$OUT/test_printf_abi" test_printf_abi.c "$OUT/strfunc_pf.o" ../src/string.c
"$OUT/test_printf_abi" || fail=1
# The same test under UBSan: the formatter indexes small scratch buffers, so an index outside them (which the output
# alone would not show) must fail here.
$CC $CFLAGS -fsanitize=undefined -fno-sanitize-trap=undefined -o "$OUT/test_printf_abi_ubsan" test_printf_abi.c "$OUT/strfunc_pf.o" ../src/string.c
"$OUT/test_printf_abi_ubsan" || fail=1

echo "== test_strtod_abi =="
$CC $CFLAGS -c ../src/strtod.c -o "$OUT/strtod.o"
$CC $CFLAGS -o "$OUT/test_strtod_abi" test_strtod_abi.c "$OUT/strtod.o"
"$OUT/test_strtod_abi" || fail=1

echo "== test_file_abi =="
$CC $CFLAGS -c ../src/format.c -o "$OUT/format_file.o"
$CC $CFLAGS -c ../src/strfunc.c -o "$OUT/strfunc_file.o"
$CC $CFLAGS -c ../src/scan.c -o "$OUT/scan_file.o"
$CC $CFLAGS -c ../src/strtod.c -o "$OUT/strtod_file.o"
$CC $CFLAGS -o "$OUT/test_file_abi" test_file_abi.c "$OUT/format_file.o" ../src/string.c "$OUT/strfunc_file.o" "$OUT/scan_file.o" "$OUT/strtod_file.o"
"$OUT/test_file_abi" || fail=1

echo "== test_scanf_abi =="
$CC $CFLAGS -c ../src/scan.c -o "$OUT/scan.o"
$CC $CFLAGS -c ../src/strtod.c -o "$OUT/strtod_sc.o"
$CC $CFLAGS -o "$OUT/test_scanf_abi" test_scanf_abi.c "$OUT/scan.o" "$OUT/strtod_sc.o"
"$OUT/test_scanf_abi" || fail=1
# The same test under UBSan: the engine indexes a 256-entry set table and small scratch buffers by input bytes.
$CC $CFLAGS -fsanitize=undefined -fno-sanitize-trap=undefined -c ../src/scan.c -o "$OUT/scan_ubsan.o"
$CC $CFLAGS -fsanitize=undefined -fno-sanitize-trap=undefined -o "$OUT/test_scanf_abi_ubsan" test_scanf_abi.c "$OUT/scan_ubsan.o" "$OUT/strtod_sc.o"
"$OUT/test_scanf_abi_ubsan" || fail=1

echo "== test_setjmp_abi =="
SJ_RENAME="-Dsetjmp=moqi_setjmp -Dsigsetjmp=moqi_sigsetjmp -Dlongjmp=moqi_longjmp -Dsiglongjmp=moqi_siglongjmp"
$CC $CFLAGS $SJ_RENAME -DMOQI_HOST_TEST_SYSCALL -c ../src/setjmp.c -o "$OUT/setjmp.o"
$CC $CFLAGS $SJ_RENAME -o "$OUT/test_setjmp_abi" test_setjmp_abi.c "$OUT/setjmp.o"
"$OUT/test_setjmp_abi" || fail=1

echo "== test_env_abi =="
$CC $CFLAGS -o "$OUT/test_env_abi" test_env_abi.c ../src/string.c
"$OUT/test_env_abi" || fail=1

echo "== test_algo_abi =="
$CC $CFLAGS -c ../src/algo.c -o "$OUT/algo.o"
$CC $CFLAGS -o "$OUT/test_algo_abi" test_algo_abi.c "$OUT/algo.o"
"$OUT/test_algo_abi" || fail=1

if [ "$fail" -eq 0 ]; then
    echo "ALL HOST TESTS PASS"
else
    echo "HOST TESTS FAILED"
fi
exit $fail
