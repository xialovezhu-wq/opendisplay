#!/bin/sh
set -eu
test_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
test_binary=$(mktemp "${TMPDIR:-/tmp}/opendisplay-direct-touch.XXXXXX")
trap 'unlink "$test_binary"' EXIT INT TERM
swiftc "$test_root/iOS/DirectTouchState.swift" \
    "$test_root/tools/tests/direct-touch-state/main.swift" \
    -o "$test_binary"
"$test_binary"
