#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/gaocipan-export-build.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/module-cache" -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos14.0 Sources/ReportExporter.swift Tests/ReportExporterTests.swift -o "$test_dir/report-export-tests"
"$test_dir/report-export-tests"
