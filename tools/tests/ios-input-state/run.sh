#!/bin/sh
set -eu
test_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
test_build=$(mktemp -d "${TMPDIR:-/tmp}/opendisplay-input-test.XXXXXX")
trap 'rm -rf "$test_build"' EXIT INT TERM
swiftc "$test_root/iOS/RemoteInputState.swift" \
    "$test_root/tools/tests/ios-input-state/main.swift" \
    -o "$test_build/input-state-tests"
"$test_build/input-state-tests"
