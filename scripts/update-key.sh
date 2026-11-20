#!/usr/bin/env bash
#
# The release-signing key behind in-app updates (Install and Relaunch).
#
#   scripts/update-key.sh create   make a new Ed25519 key, store it in the login keychain, and write
#                                  its public half into Resources/Info.plist (MEUpdatePublicKey).
#                                  Refuses if a key is already stored.
#   scripts/update-key.sh public   print the stored key's public half
#   scripts/update-key.sh check    exit 0 if the stored key matches Resources/Info.plist
#   scripts/update-key.sh tool     build the signer and print its path (used by package-release.sh)
#
# The private key never touches disk or the terminal: it goes from the signer straight into the
# keychain (service "markdown-editor-update-key", account "release"), and package-release.sh reads it
# back with `security find-generic-password -w`. In CI set the MARKDOWN_EDITOR_UPDATE_KEY secret
# instead (the same base64 string). Back the key up somewhere safe (1Password): without it no new
# release can update installed apps in place — they fall back to Download until users reinstall a
# build carrying a new public key.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

SERVICE="markdown-editor-update-key"
ACCOUNT="release"
TOOL="build/tools/update-sign"

build_tool() {
  local sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
  local -a flags=(-O -swift-version 6 -target arm64-apple-macosx15.0)
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  elif [[ -d "$sdk" ]]; then
    flags+=(-sdk "$sdk"); export SDKROOT="$sdk"   # same pinning as make-app.sh
  fi
  mkdir -p "$(dirname "$TOOL")"
  if [[ ! -x "$TOOL" || scripts/update-sign/main.swift -nt "$TOOL" || Sources/MarkdownCore/UpdateFeed.swift -nt "$TOOL" ]]; then
    swiftc "${flags[@]}" -module-name UpdateSign scripts/update-sign/main.swift Sources/MarkdownCore/UpdateFeed.swift -o "$TOOL" >&2
  fi
}

stored_key() { security find-generic-password -s "$SERVICE" -a "$ACCOUNT" -w 2>/dev/null; }

case "${1:-}" in
  create)
    if stored_key >/dev/null; then echo "error: a key is already stored (keychain service $SERVICE); not replacing it" >&2; exit 1; fi
    build_tool
    security add-generic-password -s "$SERVICE" -a "$ACCOUNT" -l "Markdown Editor update signing key" \
      -w "$("$TOOL" generate)"
    PUB="$(MARKDOWN_EDITOR_UPDATE_KEY="$(stored_key)" "$TOOL" public)"
    /usr/libexec/PlistBuddy -c "Delete :MEUpdatePublicKey" Resources/Info.plist 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :MEUpdatePublicKey string $PUB" Resources/Info.plist
    echo "stored in keychain ($SERVICE); public key written to Resources/Info.plist: $PUB"
    ;;
  public)
    build_tool
    MARKDOWN_EDITOR_UPDATE_KEY="${MARKDOWN_EDITOR_UPDATE_KEY:-$(stored_key)}" "$TOOL" public
    ;;
  check)
    build_tool
    want="$(/usr/libexec/PlistBuddy -c 'Print :MEUpdatePublicKey' Resources/Info.plist)"
    got="$(MARKDOWN_EDITOR_UPDATE_KEY="${MARKDOWN_EDITOR_UPDATE_KEY:-$(stored_key)}" "$TOOL" public)"
    [[ "$want" == "$got" ]] || { echo "error: signing key's public half ($got) is not Info.plist's MEUpdatePublicKey ($want)" >&2; exit 1; }
    echo "signing key matches Info.plist"
    ;;
  tool)
    build_tool
    echo "$PWD/$TOOL"
    ;;
  *) echo "usage: $0 create | public | check | tool" >&2; exit 2 ;;
esac
