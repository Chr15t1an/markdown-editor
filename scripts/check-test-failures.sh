#!/usr/bin/env bash
#
# Run the test suite and pass only if every failing test is in scripts/known-test-failures.txt.
#
#   scripts/check-test-failures.sh [filter]      same filter as scripts/test.sh
#
# Reads both output formats: the CLT shim's "FAIL Class.test (…)" lines and XCTest's
# "Test Case '-[Module.Class test]' failed" lines (swift test, when Xcode is installed). Fails when
#   - a test fails that the allowlist does not name, or
#   - the suite did not run (no "Executed N tests" line: a build error or a crash).
# Allowlisted tests that passed are reported, not failed. With GITHUB_STEP_SUMMARY set (Actions),
# the same report is appended to the job summary. TEST_LOG=<file> keeps the full test output.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ALLOW=scripts/known-test-failures.txt
LOG="${TEST_LOG:-$(mktemp)}"

scripts/test.sh "$@" 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}

export LC_ALL=C
failed="$( { sed -n -E 's/^FAIL ([A-Za-z0-9_]+\.[A-Za-z0-9_]+) \(.*/\1/p' "$LOG"
             sed -n -E "s/.*Test Case '-\[[A-Za-z0-9_]+\.([A-Za-z0-9_]+) ([A-Za-z0-9_]+)\]' failed.*/\1.\2/p" "$LOG"
           } | sort -u)"
allowed="$(grep -v -E '^[[:space:]]*(#|$)' "$ALLOW" | sed 's/[[:space:]]*$//' | sort -u)"
executed="$(grep -E -o 'Executed [0-9]+ tests?' "$LOG" | tail -n 1)"
new="$(comm -23 <(printf '%s\n' "$failed" | sed '/^$/d') <(printf '%s\n' "$allowed"))"
passing="$(comm -13 <(printf '%s\n' "$failed" | sed '/^$/d') <(printf '%s\n' "$allowed"))"

verdict=pass
report="### Tests"$'\n'"- ${executed:-no \"Executed\" line}; test.sh exit $status"$'\n'
report+="- failing: $(printf '%s\n' "$failed" | sed '/^$/d' | wc -l | tr -d ' '), allowlisted: $(printf '%s\n' "$allowed" | sed '/^$/d' | wc -l | tr -d ' ')"$'\n'
if [[ -z "$executed" ]]; then
  verdict=fail; report+="- **the suite did not run** (build error or crash; see the log)"$'\n'
fi
if [[ -n "$new" ]]; then
  verdict=fail; report+="- **failing and not allowlisted:**"$'\n'"$(sed 's/^/  - /' <<<"$new")"$'\n'
fi
if [[ "$status" != 0 && -z "$failed" && -n "$executed" ]]; then
  verdict=fail; report+="- **test.sh failed but no failing test was parsed**"$'\n'
fi
if [[ -n "$passing" && -z "${1:-}" ]]; then
  report+="- allowlisted but passed (remove from $ALLOW):"$'\n'"$(sed 's/^/  - /' <<<"$passing")"$'\n'
fi
report+="- verdict: **$verdict**"

echo
echo "$report"
[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "$report" >> "$GITHUB_STEP_SUMMARY"
[[ "$verdict" == pass ]]
