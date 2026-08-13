#!/bin/sh
set -eu

test_root=$(mktemp -d "${TMPDIR:-/tmp}/moqios-init-spawn-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

cc -std=c11 -Wall -Wextra -Werror \
    tools/tests/test_init_spawn_reporting.c \
    -o "$test_root/test_init_spawn_reporting"
"$test_root/test_init_spawn_reporting"
