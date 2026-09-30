#!/usr/bin/env bash
#
# Build, bundle and sign "build/Markdown Editor.app". `--install` also copies it to /Applications.
#
# Signing: with a keychain identity named "Markdown Editor Dev" the designated requirement names
# the bundle id, so macOS folder-access (TCC) grants survive rebuilds. Without it the app is signed
# ad-hoc, which works but keys TCC grants to this build's cdhash — expect a ~/Documents prompt after
# every rebuild. The build is never blocked on this.
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
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXE" "$APP/Contents/MacOS/$EXE"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# ---------------------------------------------------------------- sign
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if grep -q "\"$IDENTITY\"" <<<"$IDENTITIES"; then
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
