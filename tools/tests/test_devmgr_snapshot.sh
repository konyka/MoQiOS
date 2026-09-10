#!/bin/sh
set -eu

test_root=$(mktemp -d "${TMPDIR:-/tmp}/moqios-devmgr-snapshot-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

cc -std=c11 -Wall -Wextra -Werror -pedantic \
    tools/tests/test_devmgr_snapshot.c \
    -o "$test_root/test_devmgr_snapshot"
"$test_root/test_devmgr_snapshot"
