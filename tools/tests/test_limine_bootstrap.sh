#!/bin/bash
# Network-free contract tests for tools/limine_bootstrap.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$PROJECT_DIR/tools/limine_bootstrap.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/moqios-limine-test.XXXXXX")"
FAKE_BIN="$TEST_ROOT/bin"
LOG="$TEST_ROOT/commands.log"

cleanup() {
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/git" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'git %s\n' "$*" >> "$LIMINE_TEST_LOG"
if [ "$1" = "clone" ]; then
    target="${!#}"
    [ "${LIMINE_TEST_CLONE_FAIL:-0}" = "0" ] || exit 41
    mkdir -p "$target/.git"
    printf '%s\n' "${LIMINE_TEST_CLONE_HEAD}" > "$target/.test-head"
    : > "$target/.test-status"
    exit 0
fi
dir="$2"
shift 2
case "$1" in
    rev-parse)
        if [ "$2" = "--is-inside-work-tree" ]; then
            [ -d "$dir/.git" ] || exit 1
            printf 'true\n'
        else
            cat "$dir/.test-head"
        fi
        ;;
    status)
        cat "$dir/.test-status"
        ;;
    *) exit 99 ;;
esac
EOF

cat > "$FAKE_BIN/make" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'make %s\n' "$*" >> "$LIMINE_TEST_LOG"
[ "${LIMINE_TEST_MAKE_FAIL:-0}" = "0" ] || exit 42
dir="$2"
for asset in limine-bios.sys limine-bios-cd.bin limine-uefi-cd.bin BOOTX64.EFI; do
    if [ "$asset" = "BOOTX64.EFI" ] && [ "${LIMINE_TEST_OMIT_BOOTX64:-0}" = "1" ]; then
        continue
    fi
    : > "$dir/$asset"
done
cat > "$dir/limine" <<'UTILITY'
#!/bin/bash
printf 'bios-install %s\n' "$*" >> "$LIMINE_TEST_LOG"
[ "${LIMINE_TEST_BIOS_FAIL:-0}" = "0" ] || exit 43
UTILITY
chmod +x "$dir/limine"
if [ "${LIMINE_TEST_NONEXEC_UTILITY:-0}" = "1" ]; then
    chmod -x "$dir/limine"
fi
EOF
chmod +x "$FAKE_BIN/git" "$FAKE_BIN/make"

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
    if "$@"; then
        record_pass "$name"
    else
        record_fail "$name"
    fi
}

expect_failure() {
    local name="$1"
    shift
    if "$@"; then
        record_fail "$name (unexpected success)"
    else
        record_pass "$name"
    fi
}

assert_log_contains() {
    local name="$1"
    local text="$2"
    if grep -F -- "$text" "$LOG" >/dev/null; then
        record_pass "$name"
    else
        record_fail "$name (missing '$text')"
    fi
}

assert_log_lacks() {
    local name="$1"
    local text="$2"
    if grep -F -- "$text" "$LOG" >/dev/null; then
        record_fail "$name (unexpected '$text')"
    else
        record_pass "$name"
    fi
}

assert_file_contains() {
    local name="$1"
    local file="$2"
    local text="$3"
    if grep -F -- "$text" "$file" >/dev/null; then
        record_pass "$name"
    else
        record_fail "$name (missing '$text')"
    fi
}

assert_output_contains() {
    local name="$1"
    local text="$2"
    assert_file_contains "$name" "$TEST_ROOT/output.log" "$text"
}

reset_case() {
    rm -rf -- "$TEST_ROOT/work"
    mkdir -p "$TEST_ROOT/work"
    : > "$LOG"
    unset LIMINE_TEST_CLONE_FAIL LIMINE_TEST_MAKE_FAIL LIMINE_TEST_BIOS_FAIL \
        LIMINE_TEST_OMIT_BOOTX64 LIMINE_TEST_NONEXEC_UTILITY
}

create_checkout() {
    local dir="$1"
    local head="${2:-aad3edd370955449717a334f0289dee10e2c5f01}"
    mkdir -p "$dir/.git"
    printf '%s\n' "$head" > "$dir/.test-head"
    : > "$dir/.test-status"
    for asset in limine-bios.sys limine-bios-cd.bin limine-uefi-cd.bin BOOTX64.EFI; do
        : > "$dir/$asset"
    done
    cat > "$dir/limine" <<'EOF'
#!/bin/bash
printf 'bios-install %s\n' "$*" >> "$LIMINE_TEST_LOG"
[ "${LIMINE_TEST_BIOS_FAIL:-0}" = "0" ] || exit 43
EOF
    chmod +x "$dir/limine"
}

run_prepare() {
    PATH="$FAKE_BIN:$PATH" LIMINE_TEST_LOG="$LOG" \
        LIMINE_TEST_CLONE_HEAD="aad3edd370955449717a334f0289dee10e2c5f01" \
        bash -c 'source "$1"; limine_prepare "$2"' -- "$HELPER" "$1"
}

run_package() {
    PATH="$FAKE_BIN:$PATH" LIMINE_TEST_LOG="$LOG" \
        LIMINE_TEST_CLONE_HEAD="aad3edd370955449717a334f0289dee10e2c5f01" \
        bash -c 'source "$1"; limine_prepare "$2" && limine_bios_install "$2" "$3"' -- \
        "$HELPER" "$1" "$2"
}

run_install() {
    PATH="$FAKE_BIN:$PATH" LIMINE_TEST_LOG="$LOG" \
        bash -c 'source "$1"; limine_bios_install "$2" "$3"' -- "$HELPER" "$1" "$2"
}

reset_case
expect_success "fresh bootstrap succeeds" run_prepare "$TEST_ROOT/work/limine"
assert_log_contains "fresh bootstrap clones pinned tag" "clone --branch v8.7.0-binary --depth 1"
assert_log_contains "fresh bootstrap builds utility" "make -C $TEST_ROOT/work/limine"
[ -d "$TEST_ROOT/work/limine/.git" ] && record_pass "fresh bootstrap atomically creates limine" || record_fail "fresh bootstrap creates limine"

reset_case
create_checkout "$TEST_ROOT/work/limine"
expect_success "clean pinned checkout succeeds" run_prepare "$TEST_ROOT/work/limine"
assert_log_lacks "clean checkout avoids clone" "git clone"
assert_log_contains "clean checkout rebuilds utility" "make -C $TEST_ROOT/work/limine"

reset_case
create_checkout "$TEST_ROOT/work/limine"
printf '# replaced utility\n' > "$TEST_ROOT/work/limine/limine"
chmod +x "$TEST_ROOT/work/limine/limine"
expect_success "replaced executable is rebuilt" run_prepare "$TEST_ROOT/work/limine"
assert_log_contains "preexisting executable still invokes make" "make -C $TEST_ROOT/work/limine"

reset_case
create_checkout "$TEST_ROOT/work/limine"
: > "$TEST_ROOT/work/moqios.iso"
expect_success "valid package runs BIOS install" run_package "$TEST_ROOT/work/limine" "$TEST_ROOT/work/moqios.iso"
assert_log_contains "valid package attempts BIOS install" "bios-install bios-install $TEST_ROOT/work/moqios.iso"

reset_case
create_checkout "$TEST_ROOT/work/limine"
export LIMINE_TEST_MAKE_FAIL=1
expect_failure "rebuild failure blocks utility use" run_package "$TEST_ROOT/work/limine" "$TEST_ROOT/work/moqios.iso"
assert_log_contains "rebuild failure still invokes make" "make -C $TEST_ROOT/work/limine"
assert_log_lacks "rebuild failure prevents BIOS invocation" "bios-install"

reset_case
create_checkout "$TEST_ROOT/work/limine" "deadbeef"
printf 'wrong-commit-sentinel\n' > "$TEST_ROOT/work/limine/limine"
chmod +x "$TEST_ROOT/work/limine/limine"
expect_failure "wrong commit fails" run_package "$TEST_ROOT/work/limine" "$TEST_ROOT/work/moqios.iso"
assert_log_lacks "wrong commit prevents make" "make -C"
assert_log_lacks "wrong commit prevents BIOS invocation" "bios-install"
assert_file_contains "wrong commit leaves utility untouched" "$TEST_ROOT/work/limine/limine" "wrong-commit-sentinel"

reset_case
create_checkout "$TEST_ROOT/work/limine"
printf '?? untracked\n' > "$TEST_ROOT/work/limine/.test-status"
printf 'dirty-checkout-sentinel\n' > "$TEST_ROOT/work/limine/limine"
chmod +x "$TEST_ROOT/work/limine/limine"
expect_failure "dirty or untracked checkout fails" run_package "$TEST_ROOT/work/limine" "$TEST_ROOT/work/moqios.iso"
assert_log_lacks "dirty checkout prevents make" "make -C"
assert_log_lacks "dirty checkout prevents BIOS invocation" "bios-install"
assert_file_contains "dirty checkout leaves utility untouched" "$TEST_ROOT/work/limine/limine" "dirty-checkout-sentinel"

reset_case
mkdir -p "$TEST_ROOT/work/limine"
expect_failure "non-Git directory fails" run_package "$TEST_ROOT/work/limine" "$TEST_ROOT/work/moqios.iso"
assert_log_lacks "non-Git directory prevents make" "make -C"

reset_case
ln -s "$TEST_ROOT/work/elsewhere" "$TEST_ROOT/work/limine"
expect_failure "Limine symlink fails" run_package "$TEST_ROOT/work/limine" "$TEST_ROOT/work/moqios.iso"
assert_log_lacks "symlink prevents git access" "git -C"

reset_case
export LIMINE_TEST_CLONE_FAIL=1
expect_failure "clone failure propagates" run_package "$TEST_ROOT/work/limine" "$TEST_ROOT/work/moqios.iso"
assert_log_lacks "clone failure prevents make" "make -C"
[ ! -e "$TEST_ROOT/work/limine" ] && record_pass "clone failure cleans only temporary checkout" || record_fail "clone failure leaves destination"

reset_case
create_checkout "$TEST_ROOT/work/limine"
rm -f -- "$TEST_ROOT/work/limine/BOOTX64.EFI"
expect_success "missing required artifact is rebuilt" run_package "$TEST_ROOT/work/limine" "$TEST_ROOT/work/moqios.iso"
assert_log_contains "missing artifact still invokes make" "make -C $TEST_ROOT/work/limine"
assert_log_contains "missing artifact permits install after rebuild" "bios-install bios-install $TEST_ROOT/work/moqios.iso"

reset_case
create_checkout "$TEST_ROOT/work/limine"
rm -f -- "$TEST_ROOT/work/limine/BOOTX64.EFI"
export LIMINE_TEST_OMIT_BOOTX64=1
    if run_package "$TEST_ROOT/work/limine" "$TEST_ROOT/work/moqios.iso" >"$TEST_ROOT/output.log" 2>&1; then
    record_fail "successful make with missing artifact is rejected (unexpected success)"
else
    record_pass "successful make with missing artifact is rejected"
fi
assert_log_contains "missing post-make artifact invokes make" "make -C $TEST_ROOT/work/limine"
assert_log_lacks "missing post-make artifact prevents BIOS invocation" "bios-install"
assert_output_contains "missing post-make artifact reports failure" "Required Limine asset missing"

reset_case
create_checkout "$TEST_ROOT/work/limine"
export LIMINE_TEST_NONEXEC_UTILITY=1
    if run_package "$TEST_ROOT/work/limine" "$TEST_ROOT/work/moqios.iso" >"$TEST_ROOT/output.log" 2>&1; then
    record_fail "successful make with invalid utility is rejected (unexpected success)"
else
    record_pass "successful make with invalid utility is rejected"
fi
assert_log_contains "invalid post-make utility invokes make" "make -C $TEST_ROOT/work/limine"
assert_log_lacks "invalid post-make utility prevents BIOS invocation" "bios-install"
assert_output_contains "invalid post-make utility reports failure" "Limine utility is missing or not executable"

reset_case
create_checkout "$TEST_ROOT/work/limine"
chmod -x "$TEST_ROOT/work/limine/limine"
expect_success "non-executable limine is rebuilt" run_package "$TEST_ROOT/work/limine" "$TEST_ROOT/work/moqios.iso"
assert_log_contains "non-executable utility still invokes make" "make -C $TEST_ROOT/work/limine"
assert_log_contains "non-executable utility permits install after rebuild" "bios-install bios-install $TEST_ROOT/work/moqios.iso"

reset_case
create_checkout "$TEST_ROOT/work/limine"
rm -f -- "$TEST_ROOT/work/limine/limine"
mkdir "$TEST_ROOT/work/limine/limine"
expect_failure "utility directory fails" run_package "$TEST_ROOT/work/limine" "$TEST_ROOT/work/moqios.iso"
assert_log_lacks "utility directory prevents make" "make -C"
assert_log_lacks "utility directory prevents BIOS invocation" "bios-install"

reset_case
create_checkout "$TEST_ROOT/work/limine"
rm -f -- "$TEST_ROOT/work/limine/limine"
ln -s "$TEST_ROOT/work/replaced-utility" "$TEST_ROOT/work/limine/limine"
expect_failure "utility symlink fails" run_package "$TEST_ROOT/work/limine" "$TEST_ROOT/work/moqios.iso"
assert_log_lacks "utility symlink prevents make" "make -C"
assert_log_lacks "utility symlink prevents BIOS invocation" "bios-install"

reset_case
export LIMINE_TEST_MAKE_FAIL=1
expect_failure "make failure propagates" run_package "$TEST_ROOT/work/limine" "$TEST_ROOT/work/moqios.iso"
assert_log_lacks "make failure prevents asset use" "bios-install"

reset_case
create_checkout "$TEST_ROOT/work/limine"
: > "$TEST_ROOT/work/moqios.iso"
export LIMINE_TEST_BIOS_FAIL=1
expect_failure "bios-install failure propagates" run_install "$TEST_ROOT/work/limine" "$TEST_ROOT/work/moqios.iso"
assert_log_contains "bios-install was attempted" "bios-install bios-install $TEST_ROOT/work/moqios.iso"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
