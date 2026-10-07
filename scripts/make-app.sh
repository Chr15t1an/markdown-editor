#!/usr/bin/env bash
#
# Build, bundle and sign "build/Markdown Editor.app". `--install` also copies it to /Applications.
#
# Signing: with a keychain identity named "Markdown Editor Dev" the designated requirement names
# the bundle id, so macOS folder-access (TCC) grants survive rebuilds. Without it the app is signed
# ad-hoc, which works but keys TCC grants to this build's cdhash — expect a ~/Documents prompt after
# every rebuild. The build is never blocked on this. MARKDOWN_EDITOR_SIGN_ADHOC=1 forces ad-hoc
# signing without the note below (scripts/package-release.sh uses it for public releases).
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAME="Markdown Editor"
EXE="MarkdownEditor"
APP="build/$NAME.app"
BUNDLE_ID="com.chri5tian.markdown-editor"
IDENTITY="${MARKDOWN_EDITOR_SIGN_IDENTITY:-Markdown Editor Dev}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    *) echo "usage: $0 [--install]" >&2; exit 2 ;;
  esac
done

# xcode-select points at the Command Line Tools on this Mac; Xcode's toolchain is needed for XCTest
# and builds much faster. Override per command instead of changing the system setting.
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

plutil -lint Resources/Info.plist >/dev/null

# ---------------------------------------------------------------- build
# Without Xcode, fall back to plain swiftc: on the 2026-10 Mac the Command Line Tools' swift-package
# aborts in dyld, and the newest CLT SDK (MacOSX27) is newer than the CLT compiler, so pin the
# MacOSX.sdk symlink (the SDK the compiler shipped with). No package dependencies, so two calls do it.
build_with_swiftc() {
  local out="build/swiftc"
  local flags=(-sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk -O -swift-version 6
               -target arm64-apple-macosx15.0)
  # The link runs through clang, which takes the SDK *version* stamp from SDKROOT, not swiftc's
  # --sysroot; without this the binary says "sdk 27.0" instead of the pinned SDK's 26.5.
  local -x SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
  rm -rf "$out" && mkdir -p "$out"
  swiftc "${flags[@]}" -module-name MarkdownCore -parse-as-library \
    -emit-module -emit-module-path "$out/MarkdownCore.swiftmodule" \
    -emit-library -static -o "$out/libMarkdownCore.a" Sources/MarkdownCore/*.swift
  swiftc "${flags[@]}" -module-name "$EXE" -I "$out" -L "$out" -lMarkdownCore \
    Sources/MarkdownEditor/*.swift -o "$out/$EXE"
  BIN_DIR="$out"
}

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  swift build -c release --arch arm64
  BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
else
  build_with_swiftc
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXE" "$APP/Contents/MacOS/$EXE"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# ---------------------------------------------------------------- sign
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [[ "${MARKDOWN_EDITOR_SIGN_ADHOC:-0}" == 1 ]]; then
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
elif grep -q "\"$IDENTITY\"" <<<"$IDENTITIES"; then
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  cat >&2 <<MSG
note: signed ad-hoc — no codesigning identity named "$IDENTITY".
      macOS will ask for ~/Documents access again after every rebuild. To make the grant stick,
      create the identity once:
        Keychain Access > Certificate Assistant > Create a Certificate…
          Name: $IDENTITY   Identity Type: Self Signed Root   Certificate Type: Code Signing
      then re-run this script.
MSG
fi

codesign --verify --strict "$APP"

# Stale Launch Services rows caused -10810 on folder opens in the research spike; re-register.
"$LSREGISTER" -f -R "$APP" || true

# ---------------------------------------------------------------- install
if [[ "$INSTALL" == 1 ]]; then
  DEST="/Applications/$NAME.app"
  osascript -e "quit app \"$NAME\"" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x "$EXE" >/dev/null || break
    sleep 0.5
  done
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  codesign --verify --strict "$DEST"
  # Unregister the build copy so `open -a "$NAME"` and the Dock resolve to /Applications.
  "$LSREGISTER" -u "$PWD/$APP" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$DEST" || true
  echo "$DEST"
else
  echo "$PWD/$APP"
fi
