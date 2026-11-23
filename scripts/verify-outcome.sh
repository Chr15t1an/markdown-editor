#!/usr/bin/env bash
#
# Verifiable outcome for "New windows, and a default notes folder": builds a re-identified test copy
# of the app (bundle id com.chri5tian.markdown-editor.verify, its own preferences domain) into a temp
# folder under $TMPDIR, drives it through the ProbeLog command file, and checks the definition's four
# PASS lines:
#
#   PASS 1  After File › New Window there are two windows, and the new one's sidebar root is the
#           default folder.            (probe `action newWindow:`; the default was set through the
#                                       app's own File › Use as Default Folder action)
#   PASS 2  ⌘N in the new window creates Untitled.md inside the default folder, and the first
#           window's folder and note are unchanged.
#                                      (probe `window 2` + `action newDocument:` — the selector ⌘N
#                                       sends, through that window's responder chain; that ⌘N maps to
#                                       newDocument: is proven by testNewSaveOpenAreAnsweredByTheWindow)
#   PASS 3  Quit with unsaved text in both windows → both notes are saved to disk.
#                                      (both `type` lines, a pre-quit `dump <path>` and `quit` go in one
#                                       append, so one poll runs them back to back: the 1 s autosave
#                                       cannot fire, and the pre-quit state must show both windows
#                                       dirty; `quit` is NSApp.terminate, so applicationShouldTerminate
#                                       is what saves)
#   PASS 4  A plain relaunch (no file) shows the default folder.
#                                      (run 2 passes -lastFolder <elsewhere>, so a launch that ignored
#                                       the default would show the wrong folder)
#
#   scripts/verify-outcome.sh [<worktree>]      default: this script's repo
#
# Needs bash, python3, PlistBuddy and the build toolchain only: no AppleScript, no UI scripting, no
# preference writes from outside the app, nothing under ~/Documents (no privacy prompt), never the
# installed app. At exit it stops every process it started (by the test copy's exact binary path),
# then removes the test preferences domain, the Launch Services row, recent-documents and saved-state
# files, and the temp folder.
# Env: OUTCOME_DEADLINE  overall seconds before giving up as NOT RUN (default 540)
# Exit: 0 all four PASS, 1 a PASS line failed, 2 NOT RUN (build, launch, fixture or setup failure).
set -uo pipefail

WT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
ID=com.chri5tian.markdown-editor.verify
if [[ "$ID" == com.chri5tian.markdown-editor ]]; then echo "NOT RUN: refusing the real bundle id"; exit 2; fi
DEADLINE=$(( $(date +%s) + ${OUTCOME_DEADLINE:-540} ))
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

T="$(cd "$(mktemp -d "${TMPDIR%/}/me-verify.XXXXXX")" && pwd -P)" || { echo "NOT RUN: no temp folder"; exit 2; }
export T
APP="$T/app/Markdown Editor.app"
BIN="$APP/Contents/MacOS/MarkdownEditor"
PIDS=()

stop() {   # stop <pid>: ask, wait ≤10 s, then force
  local pid="$1" i
  kill -0 "$pid" 2>/dev/null || return 0
  kill "$pid" 2>/dev/null
  for i in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.2; done
  kill -9 "$pid" 2>/dev/null
  for i in $(seq 1 25); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.2; done
}

cleanup() {
  local pid
  for pid in ${PIDS[@]+"${PIDS[@]}"} $(pgrep -f "$BIN" 2>/dev/null); do stop "$pid"; done
  defaults delete "$ID" >/dev/null 2>&1
  rm -f "$HOME/Library/Preferences/$ID.plist"   # `defaults delete` leaves an empty plist behind
  [[ -d "$APP" ]] && "$LSREGISTER" -u "$APP" >/dev/null 2>&1
  rm -f "$HOME/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/$ID".sfl*
  rm -rf "$HOME/Library/Saved Application State/$ID.savedState"
  rm -rf "$T"
}
trap cleanup EXIT

notrun() { echo "NOT RUN: $*"; exit 2; }

# pred <state file> <pid or 0> <python expression>: s = state, W = s["windows"], R = realpath, T = temp root.
cat > "$T/pred.py" <<'PY'
import json, os, sys
path, pid, expr = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
    with open(path) as f:
        s = json.load(f)
except Exception:
    sys.exit(1)
if pid and s.get("pid") != pid:
    sys.exit(1)
def R(p):
    return os.path.realpath(p) if p else ""
def read(p):
    try:
        with open(p) as f:
            return f.read()
    except Exception:
        return None
W = s.get("windows", [])
env = dict(s=s, W=W, R=R, T=os.environ["T"], os=os, read=read)
try:
    ok = eval(expr, env)
except Exception:
    ok = False
sys.exit(0 if ok else 1)
PY
pred() { python3 -I "$T/pred.py" "$@"; }

# wait_for <seconds> <state file> <pid> <expr>: 0 when the expression holds, 1 on timeout, exits NOT RUN past the deadline.
wait_for() {
  local until=$(( $(date +%s) + $1 ))
  while :; do
    pred "$2" "$3" "$4" && return 0
    (( $(date +%s) >= DEADLINE )) && notrun "overall deadline (${OUTCOME_DEADLINE:-540}s) passed"
    (( $(date +%s) >= until )) && return 1
    sleep 0.2
  done
}

# cmd <state file> <line>...: one append to the command file (one poll runs the lines back to back).
cmd() { local p="$1"; shift; printf '%s\n' "$@" >> "$p.cmd"; }

exited() {   # exited <pid> <seconds>
  local i
  for i in $(seq 1 $(( $2 * 5 ))); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.2; done
  return 1
}

# launch <run> [args…]: sets P (state file) and PID.
launch() {
  local run="$1" pid; shift
  P="$T/$run.json"
  rm -f "$P" "$P.cmd"
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do kill -0 "$pid" 2>/dev/null && notrun "an earlier test instance ($pid) is still running"; done
  open -n "$APP" --args -ProbeLogPath "$P" -MEUpdateCheckDisabled YES -ApplePersistenceIgnoreState YES "$@" \
    || notrun "open -n failed for $run"
  local until=$(( $(date +%s) + 30 ))
  until [[ -e "$P.cmd" ]] && pred "$P" 0 'isinstance(s.get("pid"), int) and "windows" in s'; do
    (( $(date +%s) >= until )) && notrun "$run: no probe state within 30 s"
    sleep 0.2
  done
  PID="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$P")" || notrun "$run: unreadable pid"
  PIDS+=("$PID")
}

# ---------------------------------------------------------------- build
echo "building the test copy ($ID) into $T/app …"
MARKDOWN_EDITOR_SIGN_ADHOC=1 MARKDOWN_EDITOR_BUNDLE_ID="$ID" MARKDOWN_EDITOR_BUILD_DIR="$T/app" \
  "$WT/scripts/make-app.sh" > "$T/build.log" 2>&1 || { tail -20 "$T/build.log"; notrun "build failed"; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null)" == "$ID" ]] \
  || notrun "the built copy does not carry $ID"
[[ -x "$BIN" && "$BIN" == "$T"/* ]] || notrun "no test binary under $T"

# ---------------------------------------------------------------- fixtures
mkdir -p "$T/notes" "$T/elsewhere" && printf 'stray\n' > "$T/elsewhere/stray.md" || notrun "fixtures"
defaults delete "$ID" >/dev/null 2>&1   # a stale domain from a killed run
NONCE="$$-$(date +%s)"
R1="" R2="" R3="" R4=""

# ---------------------------------------------------------------- run 1
launch run1
cmd "$P" "open $T/notes" "action toggleDefaultFolder:"
wait_for 10 "$P" "$PID" 'R(s["defaultFolder"]) == R(T + "/notes")' || notrun "setup: Use as Default Folder did not store the default"
cmd "$P" "open $T/elsewhere/stray.md"
wait_for 10 "$P" "$PID" 'len(W) == 1 and R(W[0]["folder"]) == R(T + "/elsewhere") and R(W[0]["file"]) == R(T + "/elsewhere/stray.md")' \
  || notrun "setup: stray.md did not open in window 1"

cmd "$P" "action newWindow:"
if wait_for 10 "$P" "$PID" 's["windowCount"] == 2 and len(W) == 2 and R(W[1]["folder"]) == R(T + "/notes")'; then
  R1="PASS: File › New Window → 2 windows, the new one rooted at the default folder"
else
  R1="FAIL: after New Window: $(python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); print("windowCount=%s folders=%s" % (s.get("windowCount"), [w.get("folder") for w in s.get("windows", [])]))' "$P" 2>/dev/null)"
fi

if pred "$P" "$PID" 'len(W) == 2 and W[1]["folder"] != ""'; then
  cmd "$P" "window 2" "action newDocument:"
  if wait_for 10 "$P" "$PID" 'os.path.isfile(T + "/notes/Untitled.md") and R(W[1]["file"]) == R(T + "/notes/Untitled.md") and R(W[0]["folder"]) == R(T + "/elsewhere") and R(W[0]["file"]) == R(T + "/elsewhere/stray.md") and read(T + "/elsewhere/stray.md") == "stray\n"'; then
    R2="PASS: ⌘N (newDocument:) in window 2 created notes/Untitled.md; window 1 still on elsewhere/stray.md"
  else
    R2="FAIL: newDocument: in window 2 did not create notes/Untitled.md with window 1 unchanged"
  fi
  cmd "$P" "window 1" "type alpha-$NONCE" "window 2" "type beta-$NONCE" "dump $T/predump.json" "quit"
  if ! exited "$PID" 15; then
    R3="FAIL: the app did not quit within 15 s"
    stop "$PID"
  elif ! pred "$T/predump.json" "$PID" 'len(W) == 2 and W[0]["dirty"] is True and W[1]["dirty"] is True'; then
    R3="FAIL: not exercised (the pre-quit state did not show both windows dirty)"
  elif pred "$T/predump.json" "$PID" "'alpha-$NONCE' in (read(T + '/elsewhere/stray.md') or '') and 'beta-$NONCE' in (read(T + '/notes/Untitled.md') or '')"; then
    R3="PASS: quit saved the unsaved text of both windows"
  else
    R3="FAIL: after quit stray.md / Untitled.md do not hold the typed text"
  fi
else
  R2="FAIL: not exercised (window 2 has no folder)"
  R3="FAIL: not exercised (window 2 has no folder)"
  cmd "$P" "quit"
  exited "$PID" 15 || stop "$PID"
fi

# ---------------------------------------------------------------- run 2
launch run2 -lastFolder "$T/elsewhere"
if wait_for 10 "$P" "$PID" 's["windowCount"] == 1 and len(W) == 1 and R(W[0]["folder"]) == R(T + "/notes")'; then
  R4="PASS: a plain relaunch shows the default folder"
else
  R4="FAIL: a plain relaunch shows $(python3 -I -c 'import json,sys; print([w.get("folder") for w in json.load(open(sys.argv[1])).get("windows", [])])' "$P" 2>/dev/null)"
fi
cmd "$P" "quit"
exited "$PID" 15 || stop "$PID"

printf '%s\n' "$R1" "$R2" "$R3" "$R4"
for r in "$R1" "$R2" "$R3" "$R4"; do [[ "$r" == PASS:* ]] || exit 1; done
exit 0
