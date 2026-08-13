#!/bin/sh
set -eu

test_root=$(mktemp -d "${TMPDIR:-/tmp}/moqios-init-supervisor-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

cc -std=c11 -Wall -Wextra -Werror -pedantic \
    tools/tests/test_init_supervisor.c \
    -o "$test_root/test_init_supervisor"
"$test_root/test_init_supervisor"
