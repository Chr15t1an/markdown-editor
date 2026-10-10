#!/usr/bin/env bash
#
# Run the test suite. With Xcode installed this is `swift test`; with only the Command Line Tools
# (no XCTest.framework, and a CLT swift-package that aborts in dyld) it builds the suite with plain
# swiftc against a small XCTest shim (scripts/test-support/) and runs it headless.
#
#   scripts/test.sh [filter]     filter = substring of "ClassName.testName", e.g. BlockScannerTests
#
# Env: TEST_BUILD_DIR (default .build/clt-tests), SDK (default the CLT MacOSX.sdk symlink),
#      USE_SWIFT_TEST=1 to force `swift test` (needs Xcode).
#
# CLT path: MarkdownCore and MarkdownEditor (minus main.swift) are built as static libraries with
# -enable-testing; the shim is built as a module named XCTest; support/gen-registry.py lists every
# `func test*` in Tests/ (Swift cannot discover them at runtime); the tests, the registry and
# support/TestMain.swift link into one executable. Exit status 1 when any test fails.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
SUPPORT="$ROOT/scripts/test-support"
FILTER="${1:-}"

if [[ -d /Applications/Xcode.app/Contents/Developer || "${USE_SWIFT_TEST:-0}" == 1 ]]; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
  exec swift test ${FILTER:+--filter "$FILTER"}
fi

SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}"
OUT="${TEST_BUILD_DIR:-$ROOT/.build/clt-tests}"
# Same SDK/target pinning as scripts/make-app.sh; -Onone because tests are a debug build.
FLAGS=(-sdk "$SDK" -Onone -swift-version 6 -target arm64-apple-macosx15.0)
export SDKROOT="$SDK"
mkdir -p "$OUT"

swiftc "${FLAGS[@]}" -module-name MarkdownCore -parse-as-library -enable-testing \
  -emit-module -emit-module-path "$OUT/MarkdownCore.swiftmodule" \
  -emit-library -static -o "$OUT/libMarkdownCore.a" Sources/MarkdownCore/*.swift

# main.swift would start NSApplication.run(); nothing else references its globals.
EDITOR_SOURCES=()
for f in Sources/MarkdownEditor/*.swift; do
  [[ "$(basename "$f")" == "main.swift" ]] || EDITOR_SOURCES+=("$f")
done
swiftc "${FLAGS[@]}" -module-name MarkdownEditor -parse-as-library -enable-testing -I "$OUT" \
  -emit-module -emit-module-path "$OUT/MarkdownEditor.swiftmodule" \
  -emit-library -static -o "$OUT/libMarkdownEditor.a" "${EDITOR_SOURCES[@]}"

swiftc "${FLAGS[@]}" -module-name XCTest -parse-as-library \
  -emit-module -emit-module-path "$OUT/XCTest.swiftmodule" \
  -emit-library -static -o "$OUT/libXCTest.a" "$SUPPORT/XCTestShim.swift"

python3 "$SUPPORT/gen-registry.py" Tests/MarkdownCoreTests "$OUT/registry.swift"
swiftc "${FLAGS[@]}" -module-name MarkdownCoreTests -parse-as-library -I "$OUT" -L "$OUT" \
  -lMarkdownCore -lMarkdownEditor -lXCTest \
  Tests/MarkdownCoreTests/*.swift "$OUT/registry.swift" "$SUPPORT/TestMain.swift" \
  -o "$OUT/MarkdownCoreTests"

# Fixtures land in .build/test-fixtures (fixtureDirectory() in the tests). At exit the runner drops the
# MarkdownCoreTests preference keys (sidebar autosave) that name fixture folders no longer on disk.
exec "$OUT/MarkdownCoreTests" ${FILTER:+"$FILTER"}
