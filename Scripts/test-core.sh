#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h:h}"
TASK_BUILD="$(mktemp -d /private/tmp/GaoCiPan-core-build.XXXXXX)"
trap 'rm -rf "$TASK_BUILD"' EXIT
swiftc -swift-version 6 -target arm64-apple-macosx14.0 \
  -module-cache-path "$TASK_BUILD/module-cache" \
  "$TASK_ROOT/Sources/NTFSAnalyzer.swift" "$TASK_ROOT/Tests/NTFSCoreTests.swift" \
  -o "$TASK_BUILD/ntfs-core-tests"
"$TASK_BUILD/ntfs-core-tests"
