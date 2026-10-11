#!/usr/bin/env bash
#
# Check that the live site serves exactly this release: version.json says VERSION, install.sh pins
# SHA256, and the versioned zip hashes to SHA256. Retries for up to WAIT seconds (default 300, the
# _headers cache lifetime) while the deploy propagates. Read-only: GET requests only.
#
#   scripts/check-live-release.sh VERSION SHA256 [BASE_URL]     BASE_URL default https://markdown.chri5tian.com
#
# The CI form of docs/release.md §6. Exit 0 when all three match, 1 when they still don't.
set -euo pipefail

VERSION="${1:?usage: $0 VERSION SHA256 [BASE_URL]}"
SHA256="${2:?usage: $0 VERSION SHA256 [BASE_URL]}"
BASE="${3:-https://markdown.chri5tian.com}"
WAIT="${WAIT:-300}"
CURL=(/usr/bin/curl -fsS --max-time 30 -H 'Cache-Control: no-cache')

deadline=$(( $(date +%s) + WAIT ))
while :; do
  feed="$("${CURL[@]}" "$BASE/version.json?release-check=$(date +%s)" 2>/dev/null || true)"
  live_version="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("version",""))' <<<"$feed" 2>/dev/null || true)"
  live_pin="$("${CURL[@]}" "$BASE/install.sh?release-check=$(date +%s)" 2>/dev/null | sed -n 's/^SHA256="\{0,1\}\([0-9a-f]\{64\}\)"\{0,1\}$/\1/p' || true)"
  live_zip=""
  if [[ "$live_version" == "$VERSION" ]]; then
    live_zip="$("${CURL[@]}" "$BASE/Markdown-Editor-$VERSION.zip" 2>/dev/null | shasum -a 256 | cut -d ' ' -f 1 || true)"
  fi
  echo "version.json: ${live_version:-?}  install.sh SHA256: ${live_pin:-?}  zip: ${live_zip:-?}"
  if [[ "$live_version" == "$VERSION" && "$live_pin" == "$SHA256" && "$live_zip" == "$SHA256" ]]; then
    echo "live: $BASE serves $VERSION ($SHA256)"
    exit 0
  fi
  if (( $(date +%s) >= deadline )); then
    echo "error: $BASE does not serve $VERSION / $SHA256 after ${WAIT}s" >&2
    exit 1
  fi
  sleep 15
done
