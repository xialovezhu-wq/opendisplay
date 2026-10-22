#!/bin/sh
set -eu
test_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
test_binary=$(mktemp "${TMPDIR:-/tmp}/opendisplay-finger-momentum.XXXXXX")
trap 'unlink "$test_binary"' EXIT INT TERM
swiftc "$test_root/iOS/FingerScrollMomentum.swift" \
    "$test_root/tools/tests/finger-scroll-momentum/main.swift" \
    -o "$test_binary"
"$test_binary"
