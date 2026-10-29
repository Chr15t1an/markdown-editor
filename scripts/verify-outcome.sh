#!/usr/bin/env bash
#
# Verifiable outcome for image viewing in the sidebar: wait for the `Test` workflow run on the
# worktree's HEAD sha (public GitHub API) and pass only when that run concluded `success` and the
# image tests exist in HEAD's tree.
#
#   scripts/verify-outcome.sh <worktree>
#
# HEAD must already be pushed (CI runs on push). Needs bash, git, curl and python3 only.
# Env: OUTCOME_WAIT     seconds to wait for the run to finish (default 1500)
#      OUTCOME_POLL     seconds between API polls (default 20)
#      OUTCOME_MISSING_WAIT  give up early when no run has appeared for this long (default 300)
#      GH_TOKEN / GITHUB_TOKEN  sent as a bearer token when set (off-proxy rate limit); optional
#      OUTCOME_SKIP_TEST_NAMES=1  check CI only (phases before the image tests exist)
#      OUTCOME_REPO     owner/repo (default Chr15t1an/markdown-editor)
#      OUTCOME_SHA      check this sha instead of HEAD (testing the script itself)
# Exit: 0 PASS, 1 FAIL (run failed, or a named test is missing), 2 NOT RUN (no run, still running
# at the deadline, or the API could not be read).
set -uo pipefail

WT="${1:?usage: $0 <worktree>}"
REPO="${OUTCOME_REPO:-Chr15t1an/markdown-editor}"
WAIT="${OUTCOME_WAIT:-1500}"
POLL="${OUTCOME_POLL:-20}"
MISSING_WAIT="${OUTCOME_MISSING_WAIT:-300}"
WORKFLOW_NAME="Test"
WORKFLOW_PATH=".github/workflows/test.yml"
TESTS=(
  testListsImagesBesideMarkdown
  testResolveImageOpensItsFolder
  testRestorableFileAcceptsAnImage
  testRelaunchRestoresAnImage
  testThumbnailIsOrientedAndDownsampled
)

if ! sha="${OUTCOME_SHA:-$(git -C "$WT" rev-parse HEAD 2>/dev/null)}" || [[ -z "$sha" ]]; then
  echo "NOT RUN: $WT is not a git worktree"
  exit 2
fi
echo "sha: $sha"

# CI runs on push: a sha no remote branch has will never get a run.
if [[ -z "${OUTCOME_SHA:-}" ]] && ! git -C "$WT" branch -r --contains "$sha" 2>/dev/null | grep -q .; then
  git -C "$WT" fetch -q origin 2>/dev/null || true
  if ! git -C "$WT" branch -r --contains "$sha" 2>/dev/null | grep -q .; then
    echo "NOT RUN: HEAD $sha is not on any origin branch (push it first)"
    exit 2
  fi
fi

missing=()
if [[ "${OUTCOME_SKIP_TEST_NAMES:-0}" != 1 ]]; then
  for t in "${TESTS[@]}"; do
    git -C "$WT" grep -q -E "func $t\(" "$sha" -- Tests/ || missing+=("$t")
  done
fi

# The newest Test run for the sha decides. Prints one line: "success <url>", "pending <url>", "failure <conclusion> <url>" or "missing".
read -r -d '' PICK <<'PY'
import json, sys
name, path = sys.argv[1], sys.argv[2]
runs = [r for r in json.load(sys.stdin).get("workflow_runs", [])
        if r.get("name") == name or r.get("path") == path]
runs.sort(key=lambda r: r.get("id", 0), reverse=True)
if not runs:
    print("missing")
elif runs[0].get("status") != "completed":
    print("pending", runs[0]["html_url"])
elif runs[0].get("conclusion") == "success":
    print("success", runs[0]["html_url"])
else:
    print("failure", runs[0].get("conclusion") or "unknown", runs[0]["html_url"])
PY

api="https://api.github.com/repos/$REPO/actions/runs?head_sha=$sha&per_page=100"
auth=()
token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[[ -n "$token" ]] && auth=(-H "Authorization: Bearer $token")
started=$(date +%s)
deadline=$(( $(date +%s) + WAIT ))
state="" url=""
while :; do
  if json="$(curl -fsS --max-time 30 -H 'Accept: application/vnd.github+json' ${auth[@]+"${auth[@]}"} "$api")" \
     && line="$(python3 -c "$PICK" "$WORKFLOW_NAME" "$WORKFLOW_PATH" <<<"$json")"; then
    read -r state a b <<<"$line"
    case "$state" in
      success|pending) url="$a" ;;
      failure) url="$b"; conclusion="$a" ;;
    esac
  else
    state="error"
  fi
  [[ "$state" == success || "$state" == failure ]] && break
  if (( $(date +%s) >= deadline )); then break; fi
  if [[ "$state" == missing ]] && (( $(date +%s) - started >= MISSING_WAIT )); then break; fi
  echo "waiting: $state ${url:-} ($(( deadline - $(date +%s) ))s left)"
  sleep "$POLL"
done

echo "run: ${url:-none}"
case "$state" in
  success)
    if (( ${#missing[@]} > 0 )); then
      echo "FAIL: CI passed but these tests are not in HEAD: ${missing[*]}"
      exit 1
    fi
    echo "PASS: $WORKFLOW_NAME succeeded on $sha${OUTCOME_SKIP_TEST_NAMES:+ (test names not checked)}"
    exit 0 ;;
  failure)
    echo "FAIL: $WORKFLOW_NAME concluded ${conclusion:-failure} on $sha — $url"
    exit 1 ;;
  *)
    echo "NOT RUN: no finished $WORKFLOW_NAME run for $sha after $(( $(date +%s) - started ))s (last state: ${state:-none})"
    exit 2 ;;
esac
