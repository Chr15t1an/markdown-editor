#!/usr/bin/env bash
#
# Set the app version everywhere it is written, and add one to the build number.
#
#   scripts/bump-version.sh X.Y.Z
#
# Writes Resources/Info.plist (CFBundleShortVersionString = X.Y.Z, CFBundleVersion + 1),
# Sources/MarkdownCore/MarkdownCore.swift and Tests/MarkdownCoreTests/SmokeTests.swift, then runs
# scripts/check-version.sh. Passing the version the plist already has only aligns the two Swift
# copies and leaves the build number alone. Review with `git diff` and commit; nothing is pushed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 X.Y.Z   (three numbers, e.g. 0.4.0)" >&2
  exit 2
fi

PLIST=Resources/Info.plist
CORE=Sources/MarkdownCore/MarkdownCore.swift
SMOKE=Tests/MarkdownCoreTests/SmokeTests.swift

current="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
if [[ "$current" != "$VERSION" ]]; then
  build=$(( $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST") + 1 ))
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $build" "$PLIST"
  plutil -lint "$PLIST" >/dev/null
fi

sed -i '' -E "s/(static let version = \")[^\"]*(\")/\1$VERSION\2/" "$CORE"
sed -i '' -E "s/(XCTAssertEqual\(MarkdownCore\.version, \")[^\"]*(\"\))/\1$VERSION\2/" "$SMOKE"

scripts/check-version.sh
