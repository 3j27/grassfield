#!/usr/bin/env bash
# Mutation run for the Show Desktop and display-unplug fixes (reviews of the shell UX batch): each fix is reverted in a COPY of
# the tree and the offline tests must notice: tests/shell/show_desktop_wiring.sh, tests/shell/screen_unplug_wiring.sh and
# tests/unit/tst_showdesktop.qml. The unmutated copy must pass them all; every mutant must make at least one fail. The real
# tree is never touched. Prints one line per mutant and "ux_mutants: N of N killed".
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root" || exit 2
unset QT_QPA_PLATFORMTHEME
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/uxmut.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

fresh() { # a new copy of what the checks read
  rm -rf "$tmp/t"
  mkdir -p "$tmp/t/ui/Grassfield/Ui" "$tmp/t/tests/unit"
  cp -r "$root/shell" "$tmp/t/shell"
  cp "$root/ui/Grassfield/Ui/Tokens.qml" "$tmp/t/ui/Grassfield/Ui/Tokens.qml"
  cp "$root/tests/unit/tst_showdesktop.qml" "$tmp/t/tests/unit/"
}
# the offline tests on the copy: 0 when all pass
checks() {
  WIRING_ROOT=$tmp/t "$root/tests/shell/show_desktop_wiring.sh" >/dev/null 2>&1 || return 1
  WIRING_ROOT=$tmp/t "$root/tests/shell/screen_unplug_wiring.sh" >/dev/null 2>&1 || return 1
  local out
  out=$(cd "$tmp/t" && QT_QPA_PLATFORM=offscreen QML_XHR_ALLOW_FILE_READ=1 timeout 120 /usr/lib/qt6/bin/qmltestrunner -input tests/unit/tst_showdesktop.qml 2>&1)
  # a positive result is required: a runner that printed nothing (could not start) is no pass
  grep -qE 'Totals: [1-9][0-9]* passed, 0 failed' <<<"$out" && ! grep -q '^FAIL' <<<"$out"
}
# mutate FILE OLD NEW: literal replacement in the copy; OLD must exist
mutate() {
  python3 -I -c '
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if old not in s:
    sys.exit("mutant does not apply: " + old[:60])
open(p, "w").write(s.replace(old, new, 1))
' "$tmp/t/$1" "$2" "$3"
}

fresh
checks && echo "baseline: the unmutated copy passes every offline check" || { echo "FAIL baseline: the unmutated copy does not pass"; exit 1; }

total=0
killed=0
survivors=()
try() { # try NAME FILE OLD NEW [OLD2 NEW2]: one or two literal replacements in the copy
  total=$((total + 1))
  fresh
  if ! mutate "$2" "$3" "$4" || { [[ -n ${5:-} ]] && ! mutate "$2" "$5" "$6"; }; then echo "ERROR: $1: the mutant does not apply"; survivors+=("$1 (does not apply)"); return; fi
  if checks; then echo "SURVIVED: $1"; survivors+=("$1"); else echo "killed:   $1"; killed=$((killed + 1)); fi
}

REPL='ScreenChoice.replacement(root.screenName, Compositor.focusedScreenName, Quickshell.screens.map(s => s.name))'
try "Popups handler assigns Compositor.activeScreenName" shell/services/Popups.qml "root.screenName = $REPL;" "root.screenName = Compositor.activeScreenName;"
try "Switcher handler assigns Compositor.activeScreenName" shell/switcher/Switcher.qml "root.screenName = $REPL;" "root.screenName = Compositor.activeScreenName;"
try "Notifications handler assigns Compositor.activeScreenName" shell/notifications/Notifications.qml "root.centerScreen = ScreenChoice.replacement(root.centerScreen, Compositor.focusedScreenName, Quickshell.screens.map(s => s.name));" "root.centerScreen = Compositor.activeScreenName;"
try "Apps handler assigns Compositor.activeScreenName" shell/launchpad/AppsController.qml "root.screenName = $REPL;" "root.screenName = Compositor.activeScreenName;"
try "Search handler removed" shell/search/Search.qml "function onScreensChanged(): void {" "function onScreensChangedUnused(): void {"
try "SearchPanel null guard reverted" shell/search/SearchPanel.qml 'root.controller.screenName === (modelData ? modelData.name : "")' "root.controller.screenName === modelData.name"
try "Dock null guard reverted" shell/dock/Dock.qml "root.keyboardMode && win.screen && win.screen.name === root.keyboardScreen" "root.keyboardMode && win.screen.name === root.keyboardScreen"
try "recoverDesktop without retry" shell/platform/Compositor.qml "if (step.retry) {" "if (false) {"
try "recoverDesktop without the loaded gate" shell/platform/Compositor.qml "const loaded = Hyprland.toplevels && Hyprland.toplevels.values.length > 0;" "const loaded = true;"
try "recoverDesktop unbounded" shell/platform/Compositor.qml "root.recoverTries, Tokens.showDesktopRecoverTries)" "root.recoverTries, 1000000)"
try "recoverStep: no loaded gate" shell/platform/ShowDesktop.js "    if (!loaded)
        return last" "    if (false)
        return last"
try "recoverStep: unbounded" shell/platform/ShowDesktop.js "const last = tries + 1 >= maxTries;" "const last = false;"
try "recoverStep: clears at the bound with windows parked" shell/platform/ShowDesktop.js "return {moves: moves, retry: !last, clear: false};" "return {moves: moves, retry: !last, clear: last};"
try "recoverStep: no retry" shell/platform/ShowDesktop.js "return {moves: moves, retry: !last, clear: false};" "return {moves: moves, retry: false, clear: false};"
try "ending without the hide" shell/platform/Compositor.qml "            Hyprland.dispatch(ShowDesktop.hideParkingRequest());
            root.parkingShown = ({});" "            root.parkingShown = ({});"
try "ending hides by a blind toggle" shell/platform/Compositor.qml "if (ShowDesktop.parkingVisible(root.parkingShown)) {" "if (true) {"
try "ending hides after the windows moved" shell/platform/Compositor.qml "        if (ShowDesktop.parkingVisible(root.parkingShown)) {
            Hyprland.dispatch(ShowDesktop.hideParkingRequest());
            root.parkingShown = ({});
        }
        const windows = toplevelData();" "        const windows = toplevelData();" "        root.desktopEndedAddresses = back;" "        if (ShowDesktop.parkingVisible(root.parkingShown)) {
            Hyprland.dispatch(ShowDesktop.hideParkingRequest());
            root.parkingShown = ({});
        }
        root.desktopEndedAddresses = back;"
try "activation ends only after the timer" shell/platform/Compositor.qml "        onTriggered: {
            root.activationWatch = false;" "        onTriggered: {
            root.endShowDesktop(false);
            root.activationWatch = false;"
try "activation reads the stale activeToplevel" shell/platform/Compositor.qml "            const a = root.activatedAddress;" "            const a = Hyprland.activeToplevel ? Hyprland.activeToplevel.address : \"\";"
try "activation takes every later activewindowv2" shell/platform/Compositor.qml "                root.activatedAddress = event.data;
                root.activationWatch = false;" "                root.activatedAddress = event.data;"
try "the parking state is not tracked" shell/platform/Compositor.qml "root.parkingShown = ShowDesktop.parkingShownAfter(root.parkingShown, event.name, event.data);" "root.parkingShown = root.parkingShown;"
try "verify dropped from the ending" shell/platform/Compositor.qml "        desktopVerify.restart();
        return true;" "        return true;"
try "verify unbounded" shell/platform/Compositor.qml "++tries < 3" "++tries < 3000"
try "capture does not stop the verify" shell/platform/Compositor.qml "        desktopVerify.stop();
        desktopVerify.records = [];" "        desktopVerify.records = [];"
try "stray focus request in the ending" shell/platform/Compositor.qml "        root.desktopEndedAddresses = back;" "        root.desktopEndedAddresses = back;
        if (back.length > 0)
            dispatchRequest(Minimized.focusWindowRequest(back[0]));"
try "stragglers lost at the verify bound" shell/platform/Compositor.qml "root.desktopRecords = ShowDesktop.stragglerRecords(records, parked);" "root.desktopRecords = [];"
try "stragglers not merged into the new capture" shell/platform/Compositor.qml "root.desktopRecords = records.concat(stragglers);" "root.desktopRecords = records;"
try "the second press does not end it before the Stages test" shell/platform/Compositor.qml "        if (endShowDesktop(true))
            return;
        if (Settings.windowsStages)" "        if (Settings.windowsStages)
            return;
        if (endShowDesktop(true))
            return;
        if (false)"

echo "ux_mutants: $killed of $total killed"
if ((killed != total)); then printf 'survivors: %s\n' "${survivors[@]}"; exit 1; fi
exit 0
