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

echo "== test_exit_abi =="
EX_RENAME="-Dexit=moqi_exit -Datexit=moqi_atexit -D_exit=moqi__exit -D_Exit=moqi__Exit"
$CC $CFLAGS $EX_RENAME -Dmalloc=test_malloc -Dfree=test_free -c ../src/exit.c -o "$OUT/exit.o"
$CC $CFLAGS $EX_RENAME -o "$OUT/test_exit_abi" test_exit_abi.c "$OUT/exit.o"
"$OUT/test_exit_abi" || fail=1

echo "== test_signal_abi =="
SG_RENAME="-Dsignal=moqi_signal -Draise=moqi_raise -Dabort=moqi_abort -Dsigaction=moqi_sigaction -Dsigemptyset=moqi_sigemptyset -Dsigfillset=moqi_sigfillset -Dsigaddset=moqi_sigaddset -Dsigdelset=moqi_sigdelset -Dsigismember=moqi_sigismember -Dsigprocmask=moqi_sigprocmask -Dsigpending=moqi_sigpending -Dsigsuspend=moqi_sigsuspend -D_exit=moqi__exit"
$CC $CFLAGS $SG_RENAME -DMOQI_HOST_TEST_SYSCALL -c ../src/signal.c -o "$OUT/signal.o"
$CC $CFLAGS $SG_RENAME -o "$OUT/test_signal_abi" test_signal_abi.c "$OUT/signal.o"
"$OUT/test_signal_abi" || fail=1

echo "== test_assert_abi =="
$CC $CFLAGS -Dwrite=moqi_write -Dabort=moqi_abort -c ../src/assert.c -o "$OUT/assert.o"
$CC $CFLAGS -o "$OUT/test_assert_abi" test_assert_abi.c "$OUT/assert.o"
"$OUT/test_assert_abi" || fail=1
$CC $CFLAGS -o "$OUT/test_assert_ndebug" test_assert_ndebug.c
"$OUT/test_assert_ndebug" || fail=1

echo "== test_posix_abi =="
PX_RENAME="-Dgetuid=moqi_getuid -Dgeteuid=moqi_geteuid -Dgetgid=moqi_getgid -Dgetegid=moqi_getegid -Dgetppid=moqi_getppid -Dalarm=moqi_alarm -Dpause=moqi_pause -Disatty=moqi_isatty -Drmdir=moqi_rmdir -Drename=moqi_rename -Dremove=moqi_remove -Dperror=moqi_perror"
$CC $CFLAGS $PX_RENAME -DMOQI_HOST_TEST_SYSCALL -c ../src/posix.c -o "$OUT/posix.o"
$CC $CFLAGS -o "$OUT/test_posix_abi" test_posix_abi.c "$OUT/posix.o"
"$OUT/test_posix_abi" || fail=1

echo "== test_poll_abi =="
$CC $CFLAGS -Dpoll=moqi_poll -Dppoll=moqi_ppoll -DMOQI_HOST_TEST_SYSCALL -c ../src/poll.c -o "$OUT/poll.o"
$CC $CFLAGS -o "$OUT/test_poll_abi" test_poll_abi.c "$OUT/poll.o"
"$OUT/test_poll_abi" || fail=1

echo "== test_fdops_abi =="
FD_RENAME="-Ddup=moqi_dup -Ddup3=moqi_dup3 -Dfcntl=moqi_fcntl -Dpread=moqi_pread -Dpwrite=moqi_pwrite -Dtruncate=moqi_truncate -Dftruncate=moqi_ftruncate -Dfsync=moqi_fsync -Dfdatasync=moqi_fdatasync -Daccess=moqi_access -Dumask=moqi_umask -Dpipe2=moqi_pipe2 -Dfchdir=moqi_fchdir"
$CC $CFLAGS $FD_RENAME -DMOQI_HOST_TEST_SYSCALL -c ../src/fdops.c -o "$OUT/fdops.o"
$CC $CFLAGS -o "$OUT/test_fdops_abi" test_fdops_abi.c "$OUT/fdops.o"
"$OUT/test_fdops_abi" || fail=1

echo "== test_stat_abi =="
ST_RENAME="-Dstat=moqi_stat -Dlstat=moqi_lstat -Dfstat=moqi_fstat -Dchmod=moqi_chmod -Dfchmod=moqi_fchmod -Dreadlink=moqi_readlink -Dsymlink=moqi_symlink -Dlink=moqi_link"
$CC $CFLAGS $ST_RENAME -DMOQI_HOST_TEST_SYSCALL -c ../src/stat.c -o "$OUT/stat.o"
$CC $CFLAGS -o "$OUT/test_stat_abi" test_stat_abi.c "$OUT/stat.o"
"$OUT/test_stat_abi" || fail=1

echo "== test_sysinfo_abi =="
SI_RENAME="-Duname=moqi_uname -Dgethostname=moqi_gethostname -Dgetrandom=moqi_getrandom -Dgetentropy=moqi_getentropy -Dsysconf=moqi_sysconf -Dgetpagesize=moqi_getpagesize -Dutsname=moqi_utsname"
$CC $CFLAGS $SI_RENAME -DMOQI_HOST_TEST_SYSCALL -c ../src/sysinfo.c -o "$OUT/sysinfo.o"
$CC $CFLAGS -o "$OUT/test_sysinfo_abi" test_sysinfo_abi.c "$OUT/sysinfo.o"
"$OUT/test_sysinfo_abi" || fail=1

echo "== test_errno_abi =="
$CC $CFLAGS -Dstrerror=moqi_strerror -c ../src/strfunc.c -o "$OUT/strfunc_errno.o"
$CC $CFLAGS -o "$OUT/test_errno_abi" test_errno_abi.c "$OUT/strfunc_errno.o"
"$OUT/test_errno_abi" || fail=1

echo "== test_select_abi =="
$CC $CFLAGS -Dselect=moqi_select -Dpselect=moqi_pselect -DMOQI_HOST_TEST_SYSCALL -c ../src/select.c -o "$OUT/select.o"
$CC $CFLAGS -o "$OUT/test_select_abi" test_select_abi.c "$OUT/select.o"
"$OUT/test_select_abi" || fail=1

echo "== test_epoll_abi =="
$CC $CFLAGS -Depoll_event=moqi_epoll_event -Depoll_data=moqi_epoll_data -Depoll_data_t=moqi_epoll_data_t -Depoll_create1=moqi_epoll_create1 -Depoll_ctl=moqi_epoll_ctl -Depoll_wait=moqi_epoll_wait -Depoll_pwait=moqi_epoll_pwait -DMOQI_HOST_TEST_SYSCALL -c ../src/epoll.c -o "$OUT/epoll.o"
$CC $CFLAGS -o "$OUT/test_epoll_abi" test_epoll_abi.c "$OUT/epoll.o"
"$OUT/test_epoll_abi" || fail=1

echo "== test_getopt_abi =="
GO_RENAME="-Dgetopt=moqi_getopt -Dgetopt_long=moqi_getopt_long -Dgetopt_long_only=moqi_getopt_long_only -Doptarg=moqi_optarg -Doptind=moqi_optind -Dopterr=moqi_opterr -Doptopt=moqi_optopt -Dgetenv=moqi_getenv_stub"
$CC $CFLAGS $GO_RENAME -DMOQI_HOST_TEST_SYSCALL -c ../src/getopt.c -o "$OUT/getopt.o"
$CC $CFLAGS $GO_RENAME -o "$OUT/test_getopt_abi" test_getopt_abi.c "$OUT/getopt.o"
"$OUT/test_getopt_abi" || fail=1
$CC $CFLAGS $GO_RENAME -o "$OUT/test_getopt_long_abi" test_getopt_long_abi.c "$OUT/getopt.o"
"$OUT/test_getopt_long_abi" || fail=1

echo "== test_dirent_abi =="
DE_RENAME="-Dopendir=moqi_opendir -Dreaddir=moqi_readdir -Dclosedir=moqi_closedir -Drewinddir=moqi_rewinddir -Dtelldir=moqi_telldir -Dseekdir=moqi_seekdir -Ddirfd=moqi_dirfd -Ddirent=moqi_dirent -DDIR=MOQI_DIR -D__moqi_dir=__moqi_dir_t"
$CC $CFLAGS $DE_RENAME -DMOQI_HOST_TEST_SYSCALL -c ../src/dirent.c -o "$OUT/dirent.o"
$CC $CFLAGS $DE_RENAME -o "$OUT/test_dirent_abi" test_dirent_abi.c "$OUT/dirent.o"
"$OUT/test_dirent_abi" || fail=1

echo "== test_system_abi =="
SY_RENAME="-Dsystem=moqi_system -D_exit=moqi__exit -Dsigaction=moqi_sigaction -Dsigprocmask=moqi_sigprocmask -Dsignal=moqi_signal -Draise=moqi_raise -Dabort=moqi_abort -Dsigemptyset=moqi_sigemptyset -Dsigfillset=moqi_sigfillset -Dsigaddset=moqi_sigaddset -Dsigdelset=moqi_sigdelset -Dsigismember=moqi_sigismember -Dsigpending=moqi_sigpending -Dsigsuspend=moqi_sigsuspend"
$CC $CFLAGS $SY_RENAME -DMOQI_HOST_TEST_SYSCALL -c ../src/system.c -o "$OUT/system.o"
$CC $CFLAGS $SY_RENAME -DMOQI_HOST_TEST_SYSCALL -c ../src/signal.c -o "$OUT/signal_sy.o"
$CC $CFLAGS $SY_RENAME -o "$OUT/test_system_abi" test_system_abi.c "$OUT/system.o" "$OUT/signal_sy.o"
"$OUT/test_system_abi" || fail=1

echo "== test_ctype_abi =="
$CC $CFLAGS -o "$OUT/test_ctype_abi" test_ctype_abi.c
"$OUT/test_ctype_abi" || fail=1

echo "== test_math_abi =="
$CC $CFLAGS -c ../src/math.c -o "$OUT/math.o"
$CC $CFLAGS -o "$OUT/test_math_abi" test_math_abi.c "$OUT/math.o"
"$OUT/test_math_abi" || fail=1
# Bit-level code with shifts by computed amounts: the same test under UBSan.
$CC $CFLAGS -fsanitize=undefined -fno-sanitize-trap=undefined -c ../src/math.c -o "$OUT/math_ubsan.o"
$CC $CFLAGS -fsanitize=undefined -fno-sanitize-trap=undefined -o "$OUT/test_math_abi_ubsan" test_math_abi.c "$OUT/math_ubsan.o"
"$OUT/test_math_abi_ubsan" || fail=1

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
