#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/moqios-aarch64-run-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$ROOT/zig-out/bin"
touch "$ROOT/zig-out/bin/moqi-kernel-aarch64.elf"
LOG="$TEST_ROOT/qemu.log"
cat > "$TEST_ROOT/bin/qemu-system-aarch64" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$QEMU_LOG"
for arg in "$@"; do
    case "$arg" in dumpdtb=*) printf 'smp=%s mem=%s\n' "$MOQI_SMP" "$MOQI_MEM" > "${arg#dumpdtb=}";; esac
done
EOF
chmod +x "$TEST_ROOT/bin/qemu-system-aarch64"
export PATH="$TEST_ROOT/bin:$PATH" QEMU_LOG="$LOG" MOQI_SERIAL=null MOQI_DTB="$TEST_ROOT/custom.dtb" MOQI_MEM=256M
if MOQI_SMP=0 "$ROOT/tools/qemu_run_aarch64.sh" >/dev/null 2>&1; then exit 1; fi
MOQI_DTB="$TEST_ROOT/auto.dtb" MOQI_SMP=1 "$ROOT/tools/qemu_run_aarch64.sh" >/dev/null 2>&1
MOQI_DTB="$TEST_ROOT/auto.dtb" MOQI_SMP=4 "$ROOT/tools/qemu_run_aarch64.sh" >/dev/null 2>&1
test "$(grep -c 'dumpdtb=' "$LOG")" -eq 2
grep -q 'smp=4 mem=256M' "$TEST_ROOT/auto.dtb"
printf custom > "$TEST_ROOT/custom.dtb"
MOQI_SMP=1 "$ROOT/tools/qemu_run_aarch64.sh" >/dev/null 2>&1
test "$(< "$TEST_ROOT/custom.dtb")" = custom
