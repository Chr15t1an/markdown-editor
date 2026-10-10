#!/usr/bin/env bash
#
# Build, sign and zip a release of "Markdown Editor", then render the download site.
#
#   scripts/package-release.sh                         build a new zip from the sources
#   RELEASE_ZIP=<path/to/zip> scripts/package-release.sh
#                                                      no build: package that existing zip as-is
#   RELEASE_ZIP=<zip> EXPECTED_SHA256=<sha> scripts/package-release.sh
#                                                      ...and refuse it unless its SHA-256 is <sha>
#
# Outputs (all under build/, which is git-ignored):
#   build/dist/Markdown-Editor-<version>.zip         the release
#   build/dist/Markdown-Editor-<version>.zip.sha256  `shasum -a 256 -c` format
#   build/dist/Markdown-Editor.zip                   version-free copy for the stable "latest" URL
#   build/site/                                      the deployable site (see site/wrangler.jsonc),
#                                                    incl. index.html and install.sh rendered from
#                                                    site/index.template.html and site/install.template.sh
#
# Builds are not bit-for-bit reproducible: the compiled binary's LC_UUID can differ between runs, so
# two runs on the same sources can give different zip SHAs. Each release publishes the SHA-256 of the
# exact zip it ships, and the page and install.sh are rendered from that zip. To re-render the site
# for a version that is already published (without changing the bytes behind its versioned URL),
# pass the published zip as RELEASE_ZIP: it is copied byte for byte, and VERSION comes from the app
# inside it. It must still be signed ad-hoc, hold only "Markdown Editor.app/" with no AppleDouble
# ("._", __MACOSX) entries, and match EXPECTED_SHA256 if set, else the "<zip>.sha256" file beside it
# if there is one (the durable copies under ~/Documents/markdown-editor-releases/ have one).
#
# The release is always signed ad-hoc, even when the "Markdown Editor Dev" identity exists: the site
# and README say "signed ad-hoc", and the zip must not depend on whose keychain built it.
#
set -euo pipefail

# Resolve RELEASE_ZIP before the cd below, so a relative path means "relative to where I ran it".
RELEASE_ZIP="${RELEASE_ZIP:-}"
if [[ -n "$RELEASE_ZIP" ]]; then
  [[ -f "$RELEASE_ZIP" ]] || { echo "error: RELEASE_ZIP=$RELEASE_ZIP is not a file" >&2; exit 1; }
  RELEASE_ZIP="$(cd "$(dirname "$RELEASE_ZIP")" && pwd)/$(basename "$RELEASE_ZIP")"
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."

require_adhoc() {
  local sig_info
  sig_info="$(codesign -dv "$1" 2>&1)"   # captured first: grep -q on a pipe trips pipefail
  if ! grep -qx 'Signature=adhoc' <<<"$sig_info"; then
    echo "error: $1 is not signed ad-hoc; refusing to package it" >&2
    echo "$sig_info" >&2
    exit 1
  fi
}

LATEST="Markdown-Editor.zip"
DIST="build/dist"

if [[ -n "$RELEASE_ZIP" ]]; then
  # ------------------------------------------------------------- existing zip: no build
  # The bytes behind a published versioned URL must not change: check the input is the published zip.
  GOT_SHA="$(shasum -a 256 "$RELEASE_ZIP" | cut -d ' ' -f 1)"
  if [[ -n "${EXPECTED_SHA256:-}" ]]; then
    WANT_SHA="$EXPECTED_SHA256"; WANT_FROM="EXPECTED_SHA256"
  elif [[ -f "$RELEASE_ZIP.sha256" ]]; then
    WANT_SHA="$(cut -d ' ' -f 1 "$RELEASE_ZIP.sha256")"; WANT_FROM="$RELEASE_ZIP.sha256"
  else
    WANT_SHA=""; WANT_FROM=""
  fi
  if [[ -n "$WANT_SHA" && "$GOT_SHA" != "$WANT_SHA" ]]; then
    echo "error: $RELEASE_ZIP has SHA-256 $GOT_SHA, but $WANT_FROM says $WANT_SHA" >&2; exit 1
  fi
  [[ -n "$WANT_SHA" ]] || echo "warning: no EXPECTED_SHA256 and no $RELEASE_ZIP.sha256; make sure $GOT_SHA is the published SHA" >&2

  # ditto -x merges AppleDouble entries back in, so the codesign check below cannot see them, but
  # Terminal `unzip` extracts them as files inside the bundle and breaks the signature.
  ENTRIES="$(zipinfo -1 "$RELEASE_ZIP")"
  if grep -Eq '(^|/)\._|^__MACOSX(/|$)' <<<"$ENTRIES"; then
    echo "error: $RELEASE_ZIP has AppleDouble (._ / __MACOSX) entries; zip it with ditto --norsrc" >&2; exit 1
  fi
  if grep -vq '^Markdown Editor\.app/' <<<"$ENTRIES"; then
    echo "error: $RELEASE_ZIP holds something besides Markdown Editor.app/:" >&2
    grep -v '^Markdown Editor\.app/' <<<"$ENTRIES" | head -5 >&2; exit 1
  fi

  CHECK="$(mktemp -d)"
  trap 'rm -rf "$CHECK"' EXIT
  ditto -x -k "$RELEASE_ZIP" "$CHECK"
  APP_CHECK="$CHECK/Markdown Editor.app"
  [[ -d "$APP_CHECK" ]] || { echo "error: $RELEASE_ZIP does not contain Markdown Editor.app" >&2; exit 1; }
  codesign --verify --strict "$APP_CHECK"
  require_adhoc "$APP_CHECK"
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_CHECK/Contents/Info.plist")"
  ZIP="Markdown-Editor-$VERSION.zip"

  rm -rf "$DIST" && mkdir -p "$DIST"
  cp "$RELEASE_ZIP" "$DIST/$ZIP"
  cp "$RELEASE_ZIP" "$DIST/$LATEST"
  cmp -s "$RELEASE_ZIP" "$DIST/$ZIP" || { echo "error: copy of $RELEASE_ZIP differs" >&2; exit 1; }
  (cd "$DIST" && shasum -a 256 "$ZIP" > "$ZIP.sha256")
else
  # ------------------------------------------------------------- build + sign
  APP_SRC="$(MARKDOWN_EDITOR_SIGN_ADHOC=1 scripts/make-app.sh | tail -n 1)"
  [[ -d "$APP_SRC" ]] || { echo "error: make-app.sh did not print an .app path (got: $APP_SRC)" >&2; exit 1; }
  require_adhoc "$APP_SRC"

  VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
  ZIP="Markdown-Editor-$VERSION.zip"

  # ------------------------------------------------------------- stage
  # Copy the app and pin every mtime, so the zip does not also vary with build time.
  # (mtimes are not part of the code signature.)
  STAGE="build/stage"
  rm -rf "$STAGE" && mkdir -p "$STAGE"
  ditto "$APP_SRC" "$STAGE/$(basename "$APP_SRC")"
  find "$STAGE" -exec touch -h -t 202601010000 {} +

  # ------------------------------------------------------------- zip
  # --norsrc: the default ditto zip carries AppleDouble "._" entries (com.apple.provenance) that
  # Terminal `unzip` extracts as real files inside the bundle, which breaks the signature.
  rm -rf "$DIST" && mkdir -p "$DIST"
  ditto -c -k --norsrc --keepParent "$STAGE/$(basename "$APP_SRC")" "$DIST/$ZIP"
  cp "$DIST/$ZIP" "$DIST/$LATEST"
  (cd "$DIST" && shasum -a 256 "$ZIP" > "$ZIP.sha256")
  rm -rf "$STAGE"
fi

SHA256="$(cut -d ' ' -f 1 "$DIST/$ZIP.sha256")"

# --------------------------------------------------------------- site
# Everything in site/ except the templates and the wrangler config is copied as-is; index.html and
# install.sh are rendered from their templates so version, size and SHA always describe the zip
# deployed beside them.
SITE_OUT="build/site"
rm -rf "$SITE_OUT" && mkdir -p "$SITE_OUT"
for f in site/*; do  # not dotfiles: wrangler keeps a .wrangler/ cache here
  [[ -e "$f" ]] || continue
  case "$(basename "$f")" in
    index.template.html|install.template.sh|wrangler.jsonc) ;;
    *) cp -R "$f" "$SITE_OUT/" ;;
  esac
done

BYTES="$(stat -f %z "$DIST/$LATEST")"
SIZE_MB="$(awk -v b="$BYTES" 'BEGIN { printf "%.1f", b / 1000000 }')"  # decimal MB, as Finder shows
render() {  # render <template> <output>
  sed -e "s|{{VERSION}}|$VERSION|g" \
      -e "s|{{SIZE_MB}}|$SIZE_MB|g" \
      -e "s|{{SHA256}}|$SHA256|g" \
      -e "s|{{ZIP_VERSIONED}}|$ZIP|g" \
      -e "s|{{ZIP}}|$LATEST|g" \
      "$1" > "$2"
  if grep -q '{{' "$2"; then
    echo "error: unrendered token in $2" >&2; exit 1
  fi
}
render site/index.template.html "$SITE_OUT/index.html"
render site/install.template.sh "$SITE_OUT/install.sh"
/bin/bash -n "$SITE_OUT/install.sh"   # macOS's bash 3.2: what `curl | bash` runs, whatever is on PATH

cp "$DIST/$ZIP" "$DIST/$LATEST" "$DIST/$ZIP.sha256" "$SITE_OUT/"

echo "version  $VERSION"
echo "zip      $PWD/$DIST/$ZIP"
echo "sha256   $SHA256"
echo "site     $PWD/$SITE_OUT"
