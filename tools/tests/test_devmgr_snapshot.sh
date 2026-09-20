#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/moqios-devmgr-snapshot-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

cc -std=c11 -Wall -Wextra -Werror -pedantic \
    "$SCRIPT_DIR/test_devmgr_snapshot.c" \
    -o "$test_root/test_devmgr_snapshot"
"$test_root/test_devmgr_snapshot"
