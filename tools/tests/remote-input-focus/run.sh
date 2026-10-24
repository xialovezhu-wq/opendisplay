#!/bin/sh
set -eu
test_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
test_binary=$(mktemp "${TMPDIR:-/tmp}/opendisplay-input-focus.XXXXXX")
trap 'unlink "$test_binary"' EXIT INT TERM
swiftc "$test_root/iOS/RemoteInputFocusRecovery.swift" \
    "$test_root/tools/tests/remote-input-focus/main.swift" \
    -o "$test_binary"
"$test_binary"
