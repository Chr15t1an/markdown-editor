#!/usr/bin/env bash
#
# Print the CHANGELOG.md section for one version (the lines under its heading, up to the next
# "## " heading), without the heading itself. Exits 1 if there is no such section or it is empty.
#
#   scripts/changelog-section.sh X.Y.Z [CHANGELOG.md]
#
# Heading format: "## X.Y.Z — YYYY-MM-DD" (also "## X.Y.Z" alone). The release workflow uses the
# output verbatim as the GitHub Release notes; ops/announce/post.py reads the same section.
set -euo pipefail

VERSION="${1:?usage: $0 X.Y.Z [CHANGELOG.md]}"
FILE="${2:-$(dirname "${BASH_SOURCE[0]}")/../CHANGELOG.md}"

section="$(awk -v v="$VERSION" '
  /^## / { if (inside) exit; split($0, w, " "); if (w[2] == v) { inside = 1; next } }
  inside { print }
' "$FILE" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')"

if [[ -z "${section//[[:space:]]/}" ]]; then
  echo "error: no \"## $VERSION\" section in $FILE (add one; see the header of CHANGELOG.md)" >&2
  exit 1
fi
printf '%s\n' "$section"
