#!/usr/bin/env bash
# Mutation run for the Show Desktop and display-unplug fixes (reviews of the shell UX batch): each rule is broken in a COPY of the
# tree and the offline tests must notice. The checks are the BEHAVIOUR tests of the Show Desktop flow (tests/unit/tst_showdesktop.qml,
# tst_showdesktopflow.qml, tst_showdesktopreplay.qml with the sequences recorded from Hyprland), tst_screenchoice.qml, and the two
# wiring scripts (tests/shell/show_desktop_wiring.sh keeps Compositor.qml a thin forwarder, screen_unplug_wiring.sh the handlers).
# The unmutated copy must pass them all; every mutant must make at least one fail. The real tree is never touched. Prints one line
# per mutant and "ux_mutants: N of N killed".
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
  cp "$root/tests/unit/tst_showdesktop.qml" "$root/tests/unit/tst_showdesktopflow.qml" "$root/tests/unit/tst_showdesktopreplay.qml" "$root/tests/unit/tst_screenchoice.qml" "$tmp/t/tests/unit/"
  cp -r "$root/tests/unit/fixtures" "$tmp/t/tests/unit/fixtures"
}
# one qml test file of the copy: a positive result is required (a runner that printed nothing could not start: no pass)
unit() {
  local out
  out=$(cd "$tmp/t" && QT_QPA_PLATFORM=offscreen QML_XHR_ALLOW_FILE_READ=1 timeout 120 /usr/lib/qt6/bin/qmltestrunner -input "tests/unit/$1" 2>&1)
  grep -qE 'Totals: [1-9][0-9]* passed, 0 failed' <<<"$out" && ! grep -q '^FAIL' <<<"$out"
}
# the offline tests on the copy: 0 when all pass
checks() {
  WIRING_ROOT=$tmp/t "$root/tests/shell/show_desktop_wiring.sh" >/dev/null 2>&1 || return 1
  WIRING_ROOT=$tmp/t "$root/tests/shell/screen_unplug_wiring.sh" >/dev/null 2>&1 || return 1
  unit tst_showdesktop.qml || return 1
  unit tst_showdesktopflow.qml || return 1
  unit tst_showdesktopreplay.qml || return 1
  unit tst_screenchoice.qml
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

F=shell/platform/ShowDesktopFlow.js
S=shell/platform/ShowDesktop.js
C=shell/platform/Compositor.qml

# ---- display unplug -------------------------------------------------------------------------------------------------------------
REPL='ScreenChoice.replacement(root.screenName, Compositor.focusedScreenName, Quickshell.screens.map(s => s.name))'
try "Popups handler assigns Compositor.activeScreenName" shell/services/Popups.qml "root.screenName = $REPL;" "root.screenName = Compositor.activeScreenName;"
try "Switcher handler assigns Compositor.activeScreenName" shell/switcher/Switcher.qml "root.screenName = $REPL;" "root.screenName = Compositor.activeScreenName;"
try "Notifications handler assigns Compositor.activeScreenName" shell/notifications/Notifications.qml "root.centerScreen = ScreenChoice.replacement(root.centerScreen, Compositor.focusedScreenName, Quickshell.screens.map(s => s.name));" "root.centerScreen = Compositor.activeScreenName;"
try "Apps handler assigns Compositor.activeScreenName" shell/launchpad/AppsController.qml "root.screenName = $REPL;" "root.screenName = Compositor.activeScreenName;"
try "Search handler removed" shell/search/Search.qml "function onScreensChanged(): void {" "function onScreensChangedUnused(): void {"
try "SearchPanel null guard reverted" shell/search/SearchPanel.qml 'root.controller.screenName === (modelData ? modelData.name : "")' "root.controller.screenName === modelData.name"
try "Dock null guard reverted" shell/dock/Dock.qml "root.keyboardMode && win.screen && win.screen.name === root.keyboardScreen" "root.keyboardMode && win.screen.name === root.keyboardScreen"
try "ScreenChoice.replacement moves state off a live screen" shell/platform/ScreenChoice.js "    if (!gone(current, names))" "    if (gone(current, names))"

# ---- Compositor.qml stays a thin forwarder -----------------------------------------------------------------------------------------
try "R1 the dispatches are deferred with Qt.callLater" $C "            dispatchRequest(request);" "            Qt.callLater(root.dispatchRequest, request);"
try "the dispatches run after the timers" $C "        for (const request of res.dispatches)
            dispatchRequest(request);
        if (res.persist && desktopFile.path !== \"\")
            desktopFile.setText(ShowDesktop.serialize(res.state.records));" "        if (res.persist && desktopFile.path !== \"\")
            desktopFile.setText(ShowDesktop.serialize(res.state.records));
        for (const request of res.dispatches)
            dispatchRequest(request);"
try "the record file is not written" $C "if (res.persist && desktopFile.path !== \"\")" "if (false && desktopFile.path !== \"\")"
try "the file gets no records" $C "desktopFile.setText(ShowDesktop.serialize(res.state.records));" "desktopFile.setText(ShowDesktop.serialize([]));"
try "a timer the flow stops is restarted" $C "                timers[id].stop();" "                timers[id].restart();"
try "the events are not forwarded to the flow" $C "root.desktopStep(ShowDesktopFlow.onEvent(root.desktopFlow, root.desktopContext(), event.name, event.data));" "root.desktopFlow = root.desktopFlow;"
try "the activation timer asks for the wrong timer id" $C 'root.desktopContext(), "activation"))' 'root.desktopContext(), "check"))'
try "the verify timer is never forwarded" $C 'root.desktopContext(), "verify"))' 'root.desktopContext(), "recover"))'
try "the recovery context has no bound" $C "maxRecover: Tokens.showDesktopRecoverTries" "maxRecover: 1000000"
try "the echo window is zero" $C "echoMs: Tokens.showDesktopVerifyMs" "echoMs: 0"
try "the lookback is unbounded" $C "lookbackMs: Tokens.showDesktopCheckMs" "lookbackMs: 1000000000"
try "activate() does not end Show Desktop first" $C "        if (root.endShowDesktop()) {
            const chosen" "        if (true) {
            const chosen"
try "the press does not read the window list again" $C "            Hyprland.refreshToplevels();
            desktopRefresh.restart();" "            desktopRefresh.restart();"

# ---- the flow: an app activating a parked window -------------------------------------------------------------------------------------
try "R4 the activation filter removed (timer)" $F '        if (a !== "" && s.ended.some(x => SD.sameAddress(x, a)))
            send(r, Minimized.focusWindowRequest(a));' '        if (a !== "")
            send(r, Minimized.focusWindowRequest(a));'
try "R4 the after-event filter removed" $F "s.ended.some(x => x === a))
                s.activation.after = a;" "true)
                s.activation.after = a;"
try "the focus seen is not restricted to the records" $F "            if (inRecords(s.records, a))
                s.focusSeen" "            if (a !== \"\")
                s.focusSeen"
try "the activation window is not sealed by the hide" $F "            s.activation.sealed = true;" "            s.activation.sealed = false;"
try "the window before the workspace event wins over the one after" $F 'const a = act.after !== "" ? act.after : act.before;' 'const a = act.before !== "" ? act.before : act.after;'
try "only the window after the workspace event counts" $F 'before: ctx.now - seen.at <= ctx.lookbackMs ? seen.address : "", after: ""};' 'before: "", after: ""};'
try "the window before the workspace event has no time limit" $F "ctx.now - seen.at <= ctx.lookbackMs ? seen.address : \"\"" "seen.address"
try "the echo of our own hide is an activation" $F "        if (shows && ctx.now - s.hideAt < ctx.echoMs)
            return r;   // the echo of our own hide (both event forms are posted for one change)" "        if (false)
            return r;"
try "an ending handled first leaves the workspace shown" $F "                hideByState(s, ctx, r);   // an earlier ending ran first: the workspace is still hidden by state" "                s.parking = {};"
try "R1 the hide comes after the moves" $F "    hideByState(s, ctx, r);
    const focus = refocus" "    const focus = refocus" "    s.ended = back;" "    hideByState(s, ctx, r);
    s.ended = back;"
try "the hide is a blind toggle" $F "    if (!SD.parkingVisible(s.parking))
        return;
    send(r, SD.hideParkingRequest());" "    send(r, SD.hideParkingRequest());"
try "the hide does not note the time (the echo toggles again)" $F "    s.hideAt = ctx.now;" "    s.hideAt = -1e12;"
try "an activation ends with a focus request for the refocus window" $F "                log(r, \"info\", \"Show Desktop ends: \" + name);
                ending(s, ctx, r, false);" "                log(r, \"info\", \"Show Desktop ends: \" + name);
                ending(s, ctx, r, true);"
try "every ending asks for focus" $F "const focus = refocus ? SD.focusTarget(records, ctx.shown) : \"\";" "const focus = SD.focusTarget(records, ctx.shown);"

# ---- the flow: the other endings, presses, captures -----------------------------------------------------------------------------------
try "a new window does not end it" $F "    if (SD.endsOn(name, data, s.records)) {" "    if (false) {"
try "a workspace event does not schedule the check" $F "    } else if (SD.checksSpaces(name)) {
        r.timers.check = \"restart\";" "    } else if (false) {
        r.timers.check = \"restart\";"
try "the check ends it without a Space change" $F "if (s.records.length > 0 && SD.spaceChanged(s.records, ctx.shown)) {" "if (s.records.length > 0) {"
try "the screens changing schedules nothing" $F "    if (r.state.records.length > 0)
        r.timers.check = \"restart\";" "    if (false)
        r.timers.check = \"restart\";"
try "a closed window stays in the records" $F 'if (name === "closewindow") {' 'if (name === "closewindowX") {'
try "the second press does not end it before the Stages test" $F "    if (ending(s, ctx, r, true))
        return r;
    if (ctx.stages || s.pending)
        return r;" "    if (ctx.stages || s.pending)
        return r;
    if (ending(s, ctx, r, true))
        return r;"
try "a press while one is pending is taken again" $F "    if (ctx.stages || s.pending)
        return r;" "    if (ctx.stages)
        return r;"
try "the ending does not start the verify" $F "    s.verify = {records: records, tries: 0};
    r.timers.verify = \"restart\";
    return true;" "    s.verify = {records: records, tries: 0};
    return true;"

# ---- the flow: verify, stragglers -------------------------------------------------------------------------------------------------------
try "verify unbounded" $F "if (again > 0 && s.verify.tries < ctx.maxVerify) {" "if (again > 0) {"
try "the verify does not send what is parked back" $F "        stuck.forEach(a => send(r, Minimized.moveRequest(a, String(record.workspace))));" "        stuck.forEach(a => a);"
try "the verify bound gives the stragglers no record" $F "        s.records = s.records.concat(strandedOnly(s.verify.records, parked, s.records));
        r.persist = true;" "        r.persist = true;"
try "the verify bound replaces a record that is on" $F "s.records = s.records.concat(strandedOnly(s.verify.records, parked, s.records));" "s.records = SD.stragglerRecords(s.verify.records, parked);"
try "the verify bound duplicates the windows of a live record" $F "s.records = s.records.concat(strandedOnly(s.verify.records, parked, s.records));" "s.records = s.records.concat(SD.stragglerRecords(s.verify.records, parked));"
try "the verify bound does not persist" $F "        s.records = s.records.concat(strandedOnly(s.verify.records, parked, s.records));
        r.persist = true;" "        s.records = s.records.concat(strandedOnly(s.verify.records, parked, s.records));"
try "capture does not stop the verify" $F "    s.verify = {records: [], tries: 0};
    r.timers.verify = \"stop\";
    const records = SD.captureAll" "    const records = SD.captureAll"
try "R2 the stragglers are read after the verify records are cleared" $F "    let stragglers = [];
    if (s.verify.records.length > 0) {" "    let stragglers = [];
    s.verify = {records: [], tries: 0};
    if (s.verify.records.length > 0) {"
try "the stragglers are moved back at the capture (visible during the new Show Desktop)" $F "        stragglers = SD.stragglerRecords(s.verify.records, parkedNow);" "        stragglers = SD.stragglerRecords(s.verify.records, parkedNow);
        stragglers.forEach(rec => rec.windows.forEach(w => send(r, Minimized.moveRequest(w.address, String(rec.workspace)))));"
try "the stragglers are not merged into the new records" $F "    s.records = records.concat(stragglers);" "    s.records = records;"
try "the capture does not park the windows" $F "    records.forEach(rec => rec.windows.forEach(w => send(r, Minimized.moveRequest(w.address, SD.PARKING))));" "    records.forEach(rec => rec.windows.forEach(w => w));"

# ---- crash recovery ------------------------------------------------------------------------------------------------------------------------
try "R3 recovery clears the record at the bound" $F '    } else {
        log(r, "warn", "Show Desktop: windows left over' '    } else {
        s.records = [];
        r.persist = true;
        log(r, "warn", "Show Desktop: windows left over'
try "recovery without retry" $F "    if (step.retry) {
        r.timers.recover = \"restart\";" "    if (false) {
        r.timers.recover = \"restart\";"
try "recovery sends nothing back" $F "    step.moves.forEach(m => send(r, Minimized.moveRequest(m.address, String(m.workspace))));" "    step.moves.forEach(m => m);"
try "recovery does not count its steps" $F "    s.recoverTries++;" "    s.recoverTries = 0;"
try "recovery does not clear the record when all is back" $F "    } else if (step.clear) {
        s.records = [];
        r.persist = true;" "    } else if (step.clear) {
        r.persist = true;"
try "recovery starts nothing at load" $F "        s.recoverTries = 0;
        r.timers.recover = \"restart\";" "        s.recoverTries = 0;"
try "recoverStep: no loaded gate" $S "    if (!loaded)
        return last" "    if (false)
        return last"
try "recoverStep: unbounded" $S "const last = tries + 1 >= maxTries;" "const last = false;"
try "recoverStep: clears at the bound with windows parked" $S "return {moves: moves, retry: !last, clear: false};" "return {moves: moves, retry: !last, clear: last};"
try "recoverStep: no retry" $S "return {moves: moves, retry: !last, clear: false};" "return {moves: moves, retry: false, clear: false};"
try "parkingShownAfter v2 name index" $S "        name = parts[1];
        monitor = parts.slice(2).join(\",\");" "        name = parts[0];
        monitor = parts.slice(1).join(\",\");"

echo "ux_mutants: $killed of $total killed"
if ((killed != total)); then printf 'survivors: %s\n' "${survivors[@]}"; exit 1; fi
exit 0
