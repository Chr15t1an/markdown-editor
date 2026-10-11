#!/usr/bin/env bash
#
# Check the live download site against the release in build/ (docs/release.md §6).
#
#   scripts/verify-live.sh                     compare the live site with build/dist's zip
#   EXPECTED_SHA256=<sha> scripts/verify-live.sh
#                                              ...or with an explicit SHA (build/ wiped)
#   BASE_URL=https://... scripts/verify-live.sh
#
# Prints PASS/FAIL per check and exits non-zero if any check fails. Read-only: it downloads, it does
# not install. The real one-liner install is a separate step (docs/release.md §6).
set -uo pipefail

cd "$(dirname "$0")/.."

BASE_URL="${BASE_URL:-https://markdown.chri5tian.com}"
CURL=/usr/bin/curl
V="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
ZIP="Markdown-Editor-$V.zip"

if [[ -z "${EXPECTED_SHA256:-}" ]]; then
  if [[ ! -f "build/dist/$ZIP" ]]; then
    echo "No build/dist/$ZIP; set EXPECTED_SHA256 to the published SHA-256." >&2
    exit 2
  fi
  EXPECTED_SHA256="$(shasum -a 256 "build/dist/$ZIP" | cut -d' ' -f1)"
fi

failures=0
check() { # check <name> <ok:0|1> [detail]
  if [[ "$2" == 0 ]]; then printf 'PASS  %s\n' "$1"; else printf 'FAIL  %s  %s\n' "$1" "${3:-}"; failures=$((failures + 1)); fi
}
status() { "$CURL" -s -o /dev/null -w '%{http_code}' "$BASE_URL$1"; }

echo "Checking $BASE_URL for v$V (SHA-256 ${EXPECTED_SHA256:0:12}…)"

for path in / "/$ZIP" "/$ZIP.sha256" /Markdown-Editor.zip /install.sh /style.css \
            /favicon.svg /favicon-32.png /apple-touch-icon.png /app-icon-512.png \
            /screenshot.png /screenshot-dark.png; do
  code="$(status "$path")"
  [[ "$code" == 200 ]]; check "200 $path" $? "got $code"
done

zip_headers="$("$CURL" -sI "$BASE_URL/$ZIP")"
grep -qi '^content-disposition: attachment' <<<"$zip_headers"; check "zip is content-disposition: attachment" $?

for path in "/$ZIP" /Markdown-Editor.zip; do
  got="$("$CURL" -s "$BASE_URL$path" | shasum -a 256 | cut -d' ' -f1)"
  [[ "$got" == "$EXPECTED_SHA256" ]]; check "SHA-256 of $path" $? "got $got"
done

page="$("$CURL" -s "$BASE_URL/")"
grep -q "v$V" <<<"$page"; check "page shows v$V" $?
grep -q "$EXPECTED_SHA256" <<<"$page"; check "page shows the SHA-256" $?

sh_headers="$("$CURL" -sI "$BASE_URL/install.sh")"
grep -qi '^content-type: text/plain' <<<"$sh_headers"; check "install.sh is text/plain" $?
grep -qi '^cache-control: public, max-age=300' <<<"$sh_headers"; check "install.sh is max-age=300" $?
! grep -qi '^content-disposition' <<<"$sh_headers"; check "install.sh has no content-disposition" $?
grep -q "^SHA256=\"$EXPECTED_SHA256\"" <<<"$("$CURL" -s "$BASE_URL/install.sh")"
check "install.sh SHA256= line matches" $?

if (( failures )); then echo "$failures check(s) failed."; exit 1; fi
echo "All checks passed. Next: the real one-liner install (docs/release.md §6)."
