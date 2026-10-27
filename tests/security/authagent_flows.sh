#!/usr/bin/env bash
# The polkit agent's behaviour, offscreen (reviews of f513b3b, b5d7657 and 38dbfe8): the real shell/security/polkit/AuthAgent.qml
# with its Quickshell types replaced by plain QML (authagent_flows.d/make_harness.py; the logic untouched), beside the real
# sheet and model, driven by authagent_flows.d/flows.qml and sink.qml with real key and mouse events through the request orders
# Quickshell 0.3.1 produces: a request replacing the open one, back-to-back requests, the lock, the screen saver. Nothing typed
# for one request may reach another one's field or the window underneath. No compositor, no polkit, no PAM.
#
#   tests/security/authagent_flows.sh              the tests: PASS / FAIL
#   tests/security/authagent_flows.sh --mutants    also each mutant below, which the tests must catch ("MUTANT <name>: CAUGHT")
#
# Scratch copies under .dev/ (removed on exit); the working tree is never edited. QMLTESTRUNNER overrides the runner's path.
# Exit 0 PASS, 1 FAIL, 2 environment error; SKIP (exit 0) without qmltestrunner or python3.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
runner=${QMLTESTRUNNER:-/usr/lib/qt6/bin/qmltestrunner}
d=$root/tests/security/authagent_flows.d
[[ -x $runner ]] || { echo "SKIP: authagent_flows needs qmltestrunner ($runner)"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: authagent_flows needs python3"; exit 0; }
mutants=0
case ${1:-} in
  "") ;;
  --mutants) mutants=1 ;;
  *) echo "usage: authagent_flows.sh [--mutants]" >&2; exit 2 ;;
esac
mkdir -p "$root/.dev"
scratch=$(mktemp -d "$root/.dev/authagent-flows.XXXXXX") || { echo "ENVIRONMENT: no scratch directory"; exit 2; }
trap 'rm -rf "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
unset QT_QPA_PLATFORMTHEME
export QT_QPA_PLATFORM=offscreen

# qs.security and qs.lib are the real folders; qs.services holds the real SessionState and a ThemeIcons that finds no icon.
mkdir -p "$scratch/qsroot/qs/services"
ln -s "$root/shell/security" "$scratch/qsroot/qs/security"
ln -s "$root/shell/lib" "$scratch/qsroot/qs/lib"
cp "$root/shell/services/SessionState.qml" "$d/ThemeIcons.qml" "$scratch/qsroot/qs/services/"
printf 'module qs.services\nsingleton SessionState 1.0 SessionState.qml\nsingleton ThemeIcons 1.0 ThemeIcons.qml\n' >"$scratch/qsroot/qs/services/qmldir"

# run <dir with AuthAgent.qml, AuthDialog.qml, AuthDialogModel.qml>: generates the harness and runs the tests; the output on
# stdout, 0 when every case passed and no QML runtime error was printed (gate Q2's failures, in the generated copies too).
run() {
  local src=$1 case_dir=$scratch/run out
  rm -rf "$case_dir"
  mkdir -p "$case_dir/polkit"
  python3 -I "$d/make_harness.py" "$src/AuthAgent.qml" "$case_dir/polkit/AgentUnderTest.qml" || return 1
  cp "$src/AuthDialog.qml" "$src/AuthDialogModel.qml" "$case_dir/polkit/"
  # The test files are named without tst_ in the tree, so the tests/security run does not load them without the harness.
  cp "$d/flows.qml" "$case_dir/tst_flows.qml"
  cp "$d/sink.qml" "$case_dir/tst_sink.qml"
  out=$(cd "$case_dir" && "$runner" -import "$root/ui" -import "$scratch/qsroot" -input . 2>&1)
  echo "$out"
  ! grep -q '^FAIL' <<<"$out" && grep -qE '^Totals: [0-9]+ passed, 0 failed' <<<"$out" &&
    ! grep -qE '^QWARN.*(TypeError|ReferenceError|Binding loop|Unable to assign|is not a function|is not a constructor)' <<<"$out"
}

real=$scratch/real
mkdir -p "$real"
cp "$root/shell/security/polkit/AuthAgent.qml" "$root/shell/security/polkit/AuthDialog.qml" "$root/shell/security/polkit/AuthDialogModel.qml" "$real/"
out=$(run "$real")
rc=$?
grep -E '^(PASS|FAIL|Totals)' <<<"$out" | grep -vE '^PASS   : qmltestrunner::[A-Za-z]+::(initTestCase|cleanupTestCase)\(\)'
if ((rc != 0)); then
  grep -E '^(QWARN|QDEBUG|   Loc|   Actual|   Expected)|error|Error' <<<"$out" | head -40
  echo "FAIL: authagent_flows"
  exit 1
fi
((mutants)) || { echo "PASS: authagent_flows"; exit 0; }

# Each mutant brings back a defect a review found: its name, the file, then pairs of a text that must occur once and what
# replaces it ('#'-separated, \n a newline). The tests must fail on every one. The sheet focusing its field at another moment
# (the check of 38dbfe8's M3) is no longer one: the sink takes the focus back (lock_surfaces.sh pins those call sites).
status=0
while IFS= read -r line; do
  [[ -n $line ]] || continue
  IFS='#' read -r -a f <<<"$line"
  name=${f[0]}
  m=$scratch/mutant
  rm -rf "$m"
  cp -a "$real" "$m"
  python3 -I - "$m/${f[1]}" "${f[@]:2}" <<'PY' || { echo "MUTANT $name: NOT APPLIED (a text is not there once)"; status=1; continue; }
import sys
path, pairs = sys.argv[1], [a.replace("\\n", "\n") for a in sys.argv[2:]]
text = open(path).read()
if not pairs or len(pairs) % 2:
    sys.exit(4)
for old, new in zip(pairs[0::2], pairs[1::2]):
    if text.count(old) != 1:
        sys.exit(3)
    text = text.replace(old, new)
open(path, "w").write(text)
PY
  if run "$m" >/dev/null; then echo "MUTANT $name: NOT CAUGHT"; status=1; else echo "MUTANT $name: CAUGHT"; fi
done <<'EOF_MUTANTS'
no-refocus (38dbfe8 MEDIUM-A)#AuthAgent.qml#onActiveFocusChanged: if (!activeFocus && root.sinkingKeys && win.takesKeys)#onActiveFocusChanged: if (false)
typing-read-late (38dbfe8 LOW-2 M1)#AuthAgent.qml#const typing = (follows && win.takesKeys) || root.sinkingKeys;#let typing = false;#        root.userFocused = false;\n        root.sinkingKeys = typing;#        root.userFocused = false;\n        typing = (follows && win.takesKeys) || root.sinkingKeys;\n        root.sinkingKeys = typing;
lock-keeps-sink (38dbfe8 LOW-2 M2)#AuthAgent.qml#            root.sinkingKeys = false;\n            if (dialogModel.active) {#            if (dialogModel.active) {
no-linger (38dbfe8 MEDIUM-B)#AuthAgent.qml#const typing = (follows && win.takesKeys) || root.sinkingKeys;#const typing = follows && win.takesKeys;
unmapped-linger (38dbfe8 MEDIUM-B)#AuthAgent.qml#visible: shown || root.lingering#visible: shown
linger-ends-request-sink#AuthAgent.qml#        interval: dialogModel.heldAfterUnlockMs\n        onTriggered: if (root.lingering)#        interval: dialogModel.heldAfterUnlockMs\n        onTriggered: if (true)
no-escape (38dbfe8 LOW-1)#AuthAgent.qml#                else if (event.key === Qt.Key_Escape)\n                    dialogModel.cancel();#                else if (event.key === Qt.Key_Escape)\n                    ;
linger-arrival-unheld#AuthAgent.qml#(follows || typing || dialogModel.arrivesHeld(#(follows || dialogModel.arrivesHeld(
no-sink (b5d7657 MEDIUM-2)#AuthAgent.qml#const typing = (follows && win.takesKeys) || root.sinkingKeys;#const typing = false;
EOF_MUTANTS
((status == 0)) && echo "PASS: authagent_flows (and every mutant caught)" || echo "FAIL: authagent_flows mutants"
exit "$status"
