#!/usr/bin/env bash
# Mutation check of the polkit sheet's "answer once" guards (tests/security/tst_authdialog.qml, R12): every mutant below
# must make the offscreen test FAIL, the unmutated sources must PASS. Offscreen only (no compositor, no polkit, no PAM).
#
#   tests/security/mutate_authdialog.sh [runs]    each mutant runs <runs> times (default 3): "MUTANT <name>: CAUGHT n/n"
#
# Mutants are applied to a scratch copy of ui/, shell/ and the test under .dev/ (removed on exit, INT and TERM); the working
# tree is never edited. Exit 0 when the control passed every run and every mutant was caught in every run, 1 otherwise.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
runs=${1:-3}
[[ $runs =~ ^[1-9][0-9]?$ ]] || { echo "mutate_authdialog: runs must be 1-99" >&2; exit 2; }
mkdir -p "$root/.dev"
scratch=$(mktemp -d "$root/.dev/mutate-authdialog.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
unset QT_QPA_PLATFORMTHEME
export QT_QPA_PLATFORM=offscreen

# Fresh copy of the sources and the test (the test imports ../../shell/security/polkit; `qs.security` through qs -> shell).
# branding/icons/symbolic too: ui/Grassfield/Ui/icons links to it, and test_10 loads ../../branding/icons/symbolic/lock.svg
# (without it the unmutated control fails and every "CAUGHT" would prove nothing; follow-up N9).
fresh() {
  rm -rf "$scratch/src"
  mkdir -p "$scratch/src/tests/security" "$scratch/src/qsroot" "$scratch/src/branding/icons"
  cp -a "$root/ui" "$root/shell" "$scratch/src/"
  cp -a "$root/branding/icons/symbolic" "$scratch/src/branding/icons/"
  cp "$root/tests/security/tst_authdialog.qml" "$scratch/src/tests/security/"
  ln -s "$scratch/src/shell" "$scratch/src/qsroot/qs"
}

# mutate <file under src> <text to find> <replacement>: fails unless the text occurs exactly once.
mutate() {
  python3 -I - "$scratch/src/$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1:4]
text = open(path).read()
if text.count(old) != 1:
    sys.exit(3)
open(path, 'w').write(text.replace(old, new))
PY
}

# Runs the test <runs> times; prints "<failing runs>|<first FAIL line>".
failing_runs() {
  local i out n=0 first=""
  for i in $(seq 1 "$runs"); do
    out=$(cd "$scratch/src" && /usr/lib/qt6/bin/qmltestrunner -import ui -import qsroot -input tests/security/tst_authdialog.qml 2>&1)
    if grep -q '^FAIL' <<<"$out" || ! grep -qE '^Totals: [0-9]+ passed, 0 failed' <<<"$out"; then
      n=$((n + 1))
      [[ -n $first ]] || first=$(grep -m1 -E '^FAIL' <<<"$out" | cut -c1-170)
    fi
  done
  echo "$n|$first"
}

status=0
fresh
IFS='|' read -r n first < <(failing_runs)
if ((n == 0)); then echo "CONTROL unmutated sources: PASS $runs/$runs"; else echo "CONTROL unmutated sources: FAIL in $n/$runs runs: $first"; status=1; fi

# check <name> (<file> <old> <new>)...: all edits applied together, then the test must fail in every run.
check() {
  local name=$1
  shift
  fresh
  while (($# >= 3)); do
    mutate "$1" "$2" "$3" || { echo "MUTANT $name: STALE (text not found exactly once in $1)"; status=1; return; }
    shift 3
  done
  IFS='|' read -r n first < <(failing_runs)
  if ((n == runs)); then echo "MUTANT $name: CAUGHT $n/$runs | $first"; else echo "MUTANT $name: SURVIVED in $((runs - n))/$runs runs"; status=1; fi
}

BT=ui/Grassfield/Ui/Button.qml
# Button.activate(): the one guard of every activation path (keys, accessibility press, pointer).
GUARD="        if (!root.visible || !root.enabled)
            return false;"
check "B1 Button guard ignores enabled" $BT "$GUARD" "        if (!root.visible)
            return false;"
check "B2 Button guard ignores visible" $BT "$GUARD" "        if (!root.enabled)
            return false;"
check "B3 Button guard removed" $BT "$GUARD" ""
check "A1 accessibility press bypasses the guard" $BT \
  "    Accessible.onPressAction: root.activate()" "    Accessible.onPressAction: root.clicked()"
check "K1 activation keys bypass the guard" $BT \
  "        root.activate();
        event.accepted = true;" "        root.clicked();
        event.accepted = true;"
check "D1 Allow stays enabled while the answer is checked" shell/security/polkit/AuthDialog.qml \
  "                enabled: root.model.canSubmit" "                enabled: true"
# ADR-0045 OC-6 (security review): while PAM awaits a device and asks nothing, the field takes no key; the prompt gives it back.
check "D2 the field takes keys while PAM awaits a device" shell/security/polkit/AuthDialog.qml \
  "                enabled: root.inputEnabled && !root.model.awaitingDevice" "                enabled: root.inputEnabled"
check "D3 the prompt does not give the field the keys back" shell/security/polkit/AuthDialog.qml \
  "            if (!root.model.awaitingDevice)
                root.focusField();" ""
check "M1 the model answers twice (no canSubmit check)" shell/security/polkit/AuthDialogModel.qml \
  "if (!active || !canSubmit || password.length === 0) {" "if (!active || password.length === 0) {"
# The field's busy check alone is backed by the model's canSubmit (defence in depth, by design): only both together send twice.
check "F1+M1 the field ignores busy and the model ignores canSubmit" \
  shell/security/PasswordField.qml "        if (!root.enabled || root.busy)
            return;" "        if (!root.enabled)
            return;" \
  shell/security/polkit/AuthDialogModel.qml "if (!active || !canSubmit || password.length === 0) {" "if (!active || password.length === 0) {"
exit $status
