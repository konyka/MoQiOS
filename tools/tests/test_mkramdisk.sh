#!/bin/bash
# Contract tests for tools/mkramdisk.sh: its file-count limit matches the
# kernel's (kernel/fs/ramdisk.zig MAX_FILES), packs up to that many files, and
# refuses one more.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PACKER="$PROJECT_DIR/tools/mkramdisk.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/moqios-mkramdisk-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

pass=0
fail=0
ok() { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

kernel_limit="$(sed -n 's/^pub const MAX_FILES: u32 = \([0-9]*\);.*/\1/p' "$PROJECT_DIR/kernel/fs/ramdisk.zig")"
script_limit="$(sed -n 's/^MAX_FILES=\([0-9]*\).*/\1/p' "$PACKER")"
if [ -n "$kernel_limit" ] && [ "$kernel_limit" = "$script_limit" ]; then
    ok "packer limit ($script_limit) equals the kernel's ($kernel_limit)"
else
    bad "packer limit '$script_limit' differs from the kernel's '$kernel_limit'"
fi
if [ "${kernel_limit:-0}" -ge 256 ]; then
    ok "the limit leaves headroom beyond the current ~130 programs"
else
    bad "limit $kernel_limit leaves no headroom"
fi

make_dir() {
    local dir="$1" n="$2"
    mkdir -p "$dir"
    for i in $(seq 1 "$n"); do printf 'x' > "$dir/f$i"; done
}

make_dir "$TEST_ROOT/at" "$kernel_limit"
if "$PACKER" "$TEST_ROOT/at" "$TEST_ROOT/at.rd" >/dev/null 2>&1 && [ -s "$TEST_ROOT/at.rd" ]; then
    ok "exactly $kernel_limit files pack"
else
    bad "exactly $kernel_limit files did not pack"
fi

make_dir "$TEST_ROOT/over" $((kernel_limit + 1))
if "$PACKER" "$TEST_ROOT/over" "$TEST_ROOT/over.rd" >/dev/null 2>&1; then
    bad "$((kernel_limit + 1)) files were accepted"
else
    ok "one file over the limit is refused"
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
