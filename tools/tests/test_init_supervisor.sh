#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/moqios-init-supervisor-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

cc -std=c11 -Wall -Wextra -Werror -pedantic \
    "$SCRIPT_DIR/test_init_supervisor.c" \
    -o "$test_root/test_init_supervisor"
"$test_root/test_init_supervisor"
