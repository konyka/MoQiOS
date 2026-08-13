#!/bin/bash
# Offline contract tests for canonical disk fixture validation and preflights.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECKER="$PROJECT_DIR/tools/disk_fixture.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/moqios-disk-fixture-test.XXXXXX")"

cleanup() {
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

pass=0
fail=0

record_pass() {
    printf 'PASS: %s\n' "$1"
    pass=$((pass + 1))
}

record_fail() {
    printf 'FAIL: %s\n' "$1" >&2
    fail=$((fail + 1))
}

expect_success() {
    local name="$1"
    shift
    if "$@"; then record_pass "$name"; else record_fail "$name"; fi
}

expect_failure() {
    local name="$1"
    shift
    if "$@"; then record_fail "$name (unexpected success)"; else record_pass "$name"; fi
}

assert_absent() {
    local name="$1" path="$2"
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then record_pass "$name"; else record_fail "$name"; fi
}

make_case() {
    local name="$1"
    CASE_DIR="$TEST_ROOT/$name"
    mkdir -p "$CASE_DIR"
    DISK="$CASE_DIR/disk.img"
    MANIFEST="$CASE_DIR/disk.img.manifest"
    # Include NUL, high-bit bytes, newlines, and trailing data to prove raw-byte hashing.
    printf '\x00fixture\xff\nbytes\x80\x01' > "$DISK"
    SIZE="$(wc -c < "$DISK" | tr -d '[:space:]')"
    HASH="$(sha256sum "$DISK" | cut -d ' ' -f1)"
    cat > "$MANIFEST" <<EOF
format_version=1
filename=disk.img
size=$SIZE
sha256=$HASH
EOF
}

check_case() {
    "$CHECKER" "$MANIFEST" "$DISK"
}

make_case valid
BEFORE="$(stat -c '%s:%Y' "$DISK")"
expect_success "valid manifest and binary fixture pass" check_case
AFTER="$(stat -c '%s:%Y' "$DISK")"
if [ "$BEFORE" = "$AFTER" ]; then record_pass "checker performs no mutation"; else record_fail "checker performs no mutation"; fi

make_case missing-manifest
rm -f "$MANIFEST"
expect_failure "missing manifest fails" check_case

make_case malformed-version
printf 'format_version=one\nfilename=disk.img\nsize=%s\nsha256=%s\n' "$SIZE" "$HASH" > "$MANIFEST"
expect_failure "malformed version fails" check_case

make_case unsupported-version
printf 'format_version=2\nfilename=disk.img\nsize=%s\nsha256=%s\n' "$SIZE" "$HASH" > "$MANIFEST"
expect_failure "unsupported version fails" check_case

make_case missing-field
printf 'format_version=1\nfilename=disk.img\nsize=%s\n' "$SIZE" > "$MANIFEST"
expect_failure "missing field fails" check_case

make_case duplicate-field
printf 'format_version=1\nfilename=disk.img\nsize=%s\nsha256=%s\nsize=%s\n' "$SIZE" "$HASH" "$SIZE" > "$MANIFEST"
expect_failure "duplicate field fails" check_case

make_case unknown-field
printf 'format_version=1\nfilename=disk.img\nsize=%s\nsha256=%s\nextra=value\n' "$SIZE" "$HASH" > "$MANIFEST"
expect_failure "unknown field fails" check_case

make_case wrong-filename
printf 'format_version=1\nfilename=other.img\nsize=%s\nsha256=%s\n' "$SIZE" "$HASH" > "$MANIFEST"
expect_failure "wrong filename fails" check_case

make_case bad-size
printf 'format_version=1\nfilename=disk.img\nsize=01\nsha256=%s\n' "$HASH" > "$MANIFEST"
expect_failure "bad size format fails" check_case

make_case bad-hash
printf 'format_version=1\nfilename=disk.img\nsize=%s\nsha256=not-a-sha256\n' "$SIZE" > "$MANIFEST"
expect_failure "bad hash format fails" check_case

make_case missing-disk
rm -f "$DISK"
expect_failure "canonical missing disk fails" check_case

make_case symlink-disk
mv "$DISK" "$CASE_DIR/target.img"
ln -s target.img "$DISK"
expect_failure "canonical symlink disk fails" check_case

make_case nonregular-disk
rm -f "$DISK"
mkdir "$DISK"
expect_failure "canonical nonregular disk fails" check_case

make_case size-mismatch
printf x >> "$DISK"
mkdir -p "$CASE_DIR/bin"
cat > "$CASE_DIR/bin/sha256sum" <<'EOF'
#!/bin/bash
printf 'called\n' >> "$HASHER_LOG"
exit 99
EOF
chmod +x "$CASE_DIR/bin/sha256sum"
HASHER_LOG="$CASE_DIR/hasher.log" PATH="$CASE_DIR/bin:$PATH" expect_failure "size mismatch fails before hashing" check_case
assert_absent "size mismatch does not invoke hasher" "$CASE_DIR/hasher.log"

make_case hash-mismatch
printf X | dd of="$DISK" bs=1 seek=1 conv=notrunc status=none
expect_failure "hash mismatch fails" check_case

make_case binary-hash
expect_success "complete binary-data hash passes" check_case

setup_preflight_project() {
    local name="$1"
    PREFLIGHT="$TEST_ROOT/$name"
    mkdir -p "$PREFLIGHT/tools" "$PREFLIGHT/fake-bin" "$PREFLIGHT/zig-out/bin"
    : > "$PREFLIGHT/zig-out/bin/moqi-kernel.elf"
    cp "$PROJECT_DIR/tools/qemu_run.sh" "$PREFLIGHT/tools/qemu_run.sh"
    cp "$PROJECT_DIR/tools/qemu_smoke.sh" "$PREFLIGHT/tools/qemu_smoke.sh"
    cp "$PROJECT_DIR/tools/disk_fixture.sh" "$PREFLIGHT/tools/disk_fixture.sh"
    cat > "$PREFLIGHT/tools/limine_bootstrap.sh" <<'EOF'
limine_prepare() { printf 'limine_prepare\n' >> "$PREFLIGHT_LOG"; }
limine_bios_install() { printf 'limine_bios_install\n' >> "$PREFLIGHT_LOG"; }
EOF
    cat > "$PREFLIGHT/fake-bin/cp" <<'EOF'
#!/bin/bash
printf 'cp %s\n' "$*" >> "$PREFLIGHT_LOG"
exit 0
EOF
    cat > "$PREFLIGHT/fake-bin/qemu-system-x86_64" <<'EOF'
#!/bin/bash
printf 'qemu\n' >> "$PREFLIGHT_LOG"
EOF
    cat > "$PREFLIGHT/fake-bin/xorriso" <<'EOF'
#!/bin/bash
printf 'xorriso\n' >> "$PREFLIGHT_LOG"
EOF
    cat > "$PREFLIGHT/fake-bin/truncate" <<'EOF'
#!/bin/bash
printf 'truncate %s\n' "$*" >> "$PREFLIGHT_LOG"
EOF
    cat > "$PREFLIGHT/fake-bin/dd" <<'EOF'
#!/bin/bash
printf 'dd %s\n' "$*" >> "$PREFLIGHT_LOG"
EOF
    chmod +x "$PREFLIGHT/fake-bin"/*
    PREFLIGHT_LOG="$PREFLIGHT/events.log"
    export PREFLIGHT_LOG
}

assert_log_absent() {
    local name="$1" text="$2"
    if [ ! -f "$PREFLIGHT_LOG" ] || ! grep -Fq -- "$text" "$PREFLIGHT_LOG"; then
        record_pass "$name"
    else
        record_fail "$name"
    fi
}

setup_preflight_project qemu-run-default
expect_failure "qemu_run default preflight rejects missing canonical disk" bash -c 'cd "$1" && PATH="$2:$PATH" ./tools/qemu_run.sh' _ "$PREFLIGHT" "$PREFLIGHT/fake-bin"
assert_log_absent "qemu_run default fails before Limine bootstrap" limine_prepare
assert_log_absent "qemu_run default fails before ISO staging" cp
assert_log_absent "qemu_run default fails before NVMe creation or stamping" truncate
assert_log_absent "qemu_run default fails before NVMe stamp" dd
assert_log_absent "qemu_run default fails before QEMU" qemu

setup_preflight_project qemu-run-empty
expect_failure "qemu_run empty MOQI_DISK validates canonical" bash -c 'cd "$1" && PATH="$2:$PATH" MOQI_DISK="" ./tools/qemu_run.sh' _ "$PREFLIGHT" "$PREFLIGHT/fake-bin"
assert_log_absent "qemu_run empty override fails before Limine bootstrap" limine_prepare
assert_log_absent "qemu_run empty override fails before ISO staging" cp
assert_log_absent "qemu_run empty override fails before NVMe creation" truncate
assert_log_absent "qemu_run empty override fails before QEMU" qemu

setup_preflight_project qemu-smoke-default
expect_failure "qemu_smoke default preflight rejects missing canonical disk" bash -c 'cd "$1" && PATH="$2:$PATH" MOQI_SMOKE_SKIP_BUILD=1 ./tools/qemu_smoke.sh' _ "$PREFLIGHT" "$PREFLIGHT/fake-bin"
assert_log_absent "qemu_smoke fails before private disk copy" cp

setup_preflight_project qemu-run-custom
printf custom > "$PREFLIGHT/custom.img"
expect_failure "custom regular MOQI_DISK bypasses canonical manifest validation" bash -c 'cd "$1" && PATH="$2:$PATH" MOQI_DISK=custom.img ./tools/qemu_run.sh' _ "$PREFLIGHT" "$PREFLIGHT/fake-bin"
if grep -Fq limine_prepare "$PREFLIGHT_LOG" 2>/dev/null; then
    record_pass "custom regular MOQI_DISK retains regular-file behavior"
else
    record_fail "custom regular MOQI_DISK retains regular-file behavior"
fi

setup_preflight_project qemu-run-custom-missing
expect_failure "custom missing MOQI_DISK remains rejected as nonregular" bash -c 'cd "$1" && PATH="$2:$PATH" MOQI_DISK=missing.img ./tools/qemu_run.sh' _ "$PREFLIGHT" "$PREFLIGHT/fake-bin"
assert_log_absent "custom missing MOQI_DISK fails before Limine bootstrap" limine_prepare

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
