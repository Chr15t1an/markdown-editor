#!/usr/bin/env bash
#
# Build, sign and zip a release of "Markdown Editor", then render the download site.
#
# Outputs (all under build/, which is git-ignored):
#   build/dist/Markdown-Editor-<version>.zip         the release
#   build/dist/Markdown-Editor-<version>.zip.sha256  `shasum -a 256 -c` format
#   build/dist/Markdown-Editor.zip                   version-free copy for the stable "latest" URL
#   build/site/                                      the deployable site (see site/wrangler.jsonc)
#
# Builds are not bit-for-bit reproducible: the compiled binary's LC_UUID can differ between runs, so
# two runs on the same sources can give different zip SHAs. Each release publishes the SHA-256 of the
# exact zip it ships, and the page is rendered from that zip.
#
# The release is always signed ad-hoc, even when the "Markdown Editor Dev" identity exists: the site
# and README say "signed ad-hoc", and the zip must not depend on whose keychain built it.
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# --------------------------------------------------------------- build + sign
APP_SRC="$(MARKDOWN_EDITOR_SIGN_ADHOC=1 scripts/make-app.sh | tail -n 1)"
[[ -d "$APP_SRC" ]] || { echo "error: make-app.sh did not print an .app path (got: $APP_SRC)" >&2; exit 1; }
SIG_INFO="$(codesign -dv "$APP_SRC" 2>&1)"   # captured first: grep -q on a pipe trips pipefail
if ! grep -qx 'Signature=adhoc' <<<"$SIG_INFO"; then
  echo "error: $APP_SRC is not signed ad-hoc; refusing to package it" >&2
  echo "$SIG_INFO" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
ZIP="Markdown-Editor-$VERSION.zip"
LATEST="Markdown-Editor.zip"
DIST="build/dist"

# --------------------------------------------------------------- stage
# Copy the app and pin every mtime, so the zip does not also vary with build time.
# (mtimes are not part of the code signature.)
STAGE="build/stage"
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto "$APP_SRC" "$STAGE/$(basename "$APP_SRC")"
find "$STAGE" -exec touch -h -t 202601010000 {} +

# --------------------------------------------------------------- zip
# --norsrc: the default ditto zip carries AppleDouble "._" entries (com.apple.provenance) that
# Terminal `unzip` extracts as real files inside the bundle, which breaks the signature.
rm -rf "$DIST" && mkdir -p "$DIST"
ditto -c -k --norsrc --keepParent "$STAGE/$(basename "$APP_SRC")" "$DIST/$ZIP"
cp "$DIST/$ZIP" "$DIST/$LATEST"
(cd "$DIST" && shasum -a 256 "$ZIP" > "$ZIP.sha256")
rm -rf "$STAGE"

SHA256="$(cut -d ' ' -f 1 "$DIST/$ZIP.sha256")"

# --------------------------------------------------------------- site
# Everything in site/ except the template and the wrangler config is copied as-is; index.html is
# rendered from the template so version, size and SHA always describe the zip deployed beside it.
SITE_OUT="build/site"
rm -rf "$SITE_OUT" && mkdir -p "$SITE_OUT"
for f in site/*; do  # not dotfiles: wrangler keeps a .wrangler/ cache here
  [[ -e "$f" ]] || continue
  case "$(basename "$f")" in
    index.template.html|wrangler.jsonc) ;;
    *) cp -R "$f" "$SITE_OUT/" ;;
  esac
done

BYTES="$(stat -f %z "$DIST/$LATEST")"
SIZE_MB="$(awk -v b="$BYTES" 'BEGIN { printf "%.1f", b / 1000000 }')"  # decimal MB, as Finder shows
sed -e "s|{{VERSION}}|$VERSION|g" \
    -e "s|{{SIZE_MB}}|$SIZE_MB|g" \
    -e "s|{{SHA256}}|$SHA256|g" \
    -e "s|{{ZIP}}|$LATEST|g" \
    site/index.template.html > "$SITE_OUT/index.html"
if grep -q '{{' "$SITE_OUT/index.html"; then
  echo "error: unrendered token in $SITE_OUT/index.html" >&2; exit 1
fi

cp "$DIST/$ZIP" "$DIST/$LATEST" "$DIST/$ZIP.sha256" "$SITE_OUT/"

echo "version  $VERSION"
echo "zip      $PWD/$DIST/$ZIP"
echo "sha256   $SHA256"
echo "site     $PWD/$SITE_OUT"
