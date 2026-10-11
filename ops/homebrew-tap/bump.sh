#!/usr/bin/env bash
#
# Point the Homebrew cask at a new release: rewrite `version` and `sha256` in Casks/markdown-editor.rb.
#
#   ops/homebrew-tap/bump.sh X.Y.Z SHA256                   edit this repo's copy, print the diff
#   ops/homebrew-tap/bump.sh X.Y.Z SHA256 <tap-checkout>    edit the tap checkout's copy, print the diff
#   ops/homebrew-tap/bump.sh X.Y.Z SHA256 <tap-checkout> --push
#                                                          ...and commit and push it (the only outward action)
#
# SHA256 is the published zip's (scripts/package-release.sh prints it; the live install.sh pins it).
# Nothing is committed or pushed without --push, whatever tokens are in the environment. The
# release workflow passes --push after the live site is verified to serve this version.
set -euo pipefail

usage() { echo "usage: $0 X.Y.Z SHA256 [tap-checkout [--push]]" >&2; exit 2; }
VERSION="${1:-}"; SHA256="${2:-}"; TAP="${3:-}"; PUSH="${4:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
[[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] || usage
[[ -z "$PUSH" || "$PUSH" == --push ]] || usage
if [[ "$PUSH" == --push && -z "$TAP" ]]; then echo "error: --push needs a tap checkout" >&2; exit 2; fi
(( $# <= 4 )) || usage

if [[ -n "$TAP" ]]; then
  [[ -d "$TAP" ]] || { echo "error: $TAP is not a directory" >&2; exit 1; }
  CASK="$TAP/Casks/markdown-editor.rb"
  mkdir -p "$TAP/Casks"
  # First bump into an empty tap: start from this repo's copy.
  [[ -f "$CASK" ]] || cp "$(dirname "${BASH_SOURCE[0]}")/Casks/markdown-editor.rb" "$CASK"
else
  CASK="$(dirname "${BASH_SOURCE[0]}")/Casks/markdown-editor.rb"
fi

BEFORE="$(mktemp)"
trap 'rm -f "$BEFORE"' EXIT
cp "$CASK" "$BEFORE"
sed -i '' -E \
  -e "s/^(  version )\"[^\"]*\"$/\1\"$VERSION\"/" \
  -e "s/^(  sha256 )\"[0-9a-f]*\"$/\1\"$SHA256\"/" "$CASK"
grep -q "^  version \"$VERSION\"$" "$CASK" && grep -q "^  sha256 \"$SHA256\"$" "$CASK" \
  || { echo "error: could not rewrite version/sha256 in $CASK" >&2; exit 1; }

diff -u "$BEFORE" "$CASK" || true

if [[ "$PUSH" != --push ]]; then
  if cmp -s "$BEFORE" "$CASK"; then echo "$CASK already at $VERSION"; fi
  echo "not pushed (dry run; pass --push to commit and push)"
  exit 0
fi

# --push: commit whatever differs from the tap's HEAD (also a cask an earlier dry run wrote).
if [[ -z "$(git -C "$TAP" status --porcelain -- Casks/markdown-editor.rb)" ]]; then
  echo "$CASK already at $VERSION in the tap; nothing to push"
  exit 0
fi
git -C "$TAP" add Casks/markdown-editor.rb
git -C "$TAP" -c user.name="markdown-editor release" \
  -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  commit -m "markdown-editor $VERSION"
git -C "$TAP" push
echo "pushed markdown-editor $VERSION to $(git -C "$TAP" remote get-url origin)"
