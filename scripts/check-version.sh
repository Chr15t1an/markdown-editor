#!/usr/bin/env bash
#
# Check that every copy of the app version agrees, and print it.
#
#   scripts/check-version.sh
#
# Source of truth: Resources/Info.plist CFBundleShortVersionString. The same string must appear in
# Sources/MarkdownCore/MarkdownCore.swift (MarkdownCore.version) and in the test that asserts it,
# Tests/MarkdownCoreTests/SmokeTests.swift. Prints each copy, exits 1 if they disagree, and on
# success prints the version alone as the last line (the release workflow reads it with tail -n 1).
# scripts/bump-version.sh writes all three.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PLIST=Resources/Info.plist
CORE=Sources/MarkdownCore/MarkdownCore.swift
SMOKE=Tests/MarkdownCoreTests/SmokeTests.swift

plist_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
plist_build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
core_version="$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' "$CORE")"
smoke_version="$(sed -n 's/.*XCTAssertEqual(MarkdownCore\.version, "\([^"]*\)").*/\1/p' "$SMOKE")"

echo "$PLIST  $plist_version (build $plist_build)"
echo "$CORE  ${core_version:-<not found>}"
echo "$SMOKE  ${smoke_version:-<not found>}"

if [[ "$core_version" != "$plist_version" || "$smoke_version" != "$plist_version" ]]; then
  echo "error: version copies disagree; Info.plist says $plist_version (fix with scripts/bump-version.sh $plist_version)" >&2
  exit 1
fi
echo "$plist_version"
