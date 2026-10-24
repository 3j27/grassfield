#!/usr/bin/env bash
# Mutation run for the Show Desktop and display-unplug fixes (reviews of the shell UX batch): each rule is broken in a COPY of the
# tree and the offline tests must notice. The checks are the BEHAVIOUR tests of the Show Desktop flow (tests/unit/tst_showdesktop.qml,
# tst_showdesktopflow.qml, tst_showdesktopreplay.qml with the sequences recorded from Hyprland, tst_showdesktopglue.qml with the real
# controller), tst_screenchoice.qml, and the two
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
  mkdir -p "$tmp/t/tests/unit"
  cp -r "$root/shell" "$tmp/t/shell"
  # the copy's own ui/ (the QML module Grassfield.Ui), never the one installed under /usr/lib/qt6/qml
  cp -r "$root/ui" "$tmp/t/ui"
  cp "$root/tests/unit/tst_showdesktop.qml" "$root/tests/unit/tst_showdesktopflow.qml" "$root/tests/unit/tst_showdesktopreplay.qml" "$root/tests/unit/tst_showdesktopglue.qml" "$root/tests/unit/tst_screenchoice.qml" "$tmp/t/tests/unit/"
  cp -r "$root/tests/unit/fixtures" "$tmp/t/tests/unit/fixtures"
}
# one qml test file of the copy: a positive result is required (a runner that printed nothing could not start: no pass)
unit() {
  local out
  out=$(cd "$tmp/t" && QT_QPA_PLATFORM=offscreen QML_XHR_ALLOW_FILE_READ=1 timeout 120 /usr/lib/qt6/bin/qmltestrunner -import ui -input "tests/unit/$1" 2>&1)
  grep -qE 'Totals: [1-9][0-9]* passed, 0 failed' <<<"$out" && ! grep -q '^FAIL' <<<"$out"
}
# the offline tests on the copy: 0 when all pass
checks() {
  WIRING_ROOT=$tmp/t "$root/tests/shell/show_desktop_wiring.sh" >/dev/null 2>&1 || return 1
  WIRING_ROOT=$tmp/t "$root/tests/shell/screen_unplug_wiring.sh" >/dev/null 2>&1 || return 1
  unit tst_showdesktop.qml || return 1
  unit tst_showdesktopflow.qml || return 1
  unit tst_showdesktopreplay.qml || return 1
  unit tst_showdesktopglue.qml || return 1
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
K=shell/platform/showdesktop/ShowDesktopController.qml

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

# ---- Compositor.qml: what it tells the controller (wiring) ---------------------------------------------------------------------------
try "R1 the dispatches are deferred with Qt.callLater" $C "dispatch: request => root.dispatchRequest(request)" "dispatch: request => Qt.callLater(root.dispatchRequest, request)"
try "the controller listens to nothing" $C "        eventSource: Hyprland" "        eventSource: null"
try "the focused window is never named" $C "            return focused ? focused.address : \"\";" "            return \"\";"
try "the current Space is never given" $C "readCurrentWorkspace: () => Hyprland.focusedMonitor && Hyprland.focusedMonitor.activeWorkspace ? Hyprland.focusedMonitor.activeWorkspace.id : 0" "readCurrentWorkspace: () => 0"
try "the window list is never reported as loaded" $C "readLoaded: () => !!Hyprland.toplevels && Hyprland.toplevels.values.length > 0" "readLoaded: () => false"
try "the record file gets nothing" $C "                desktopFile.setText(text);" "                desktopFile.setText(\"\");"
try "the keyboard is not handed to the desktop" $C "onFocusDesktopRequested: DesktopState.focusRequested()" "onFocusDesktopRequested: root.focusedToplevel"
try "the screens changing is not forwarded" $C "            showDesktopFlow.screensChanged();" "            root.focusedToplevel;"
try "the record file read is not forwarded" $C "onLoaded: showDesktopFlow.recordsLoaded(desktopFile.text())" "onLoaded: desktopFile.text()"
try "the second press is not forwarded" $C "        showDesktopFlow.press();" "        root.focusedToplevel;"
try "a shell activation never ends Show Desktop" $C "        return showDesktopFlow.endForActivation();" "        return false;"
try "activate() does not end Show Desktop first" $C "        if (root.endShowDesktop()) {
            const chosen" "        if (true) {
            const chosen"
try "the window list is not read again at a press" $C "refreshWindows: () => Hyprland.refreshToplevels()" "refreshWindows: () => root.focusedToplevel"
try "Stages is not given to the controller" $C "        stages: Settings.windowsStages" "        stages: false"

# ---- the controller (the glue, tst_showdesktopglue.qml) ------------------------------------------------------------------------------------
try "G1 the controller runs the dispatches in REVERSE order (hide last)" $K "        for (const request of res.dispatches)
            root.dispatch(request);" "        for (const request of res.dispatches.slice().reverse())
            root.dispatch(request);"
try "G2 activewindowv2 is not forwarded to the flow" $K "            root.handleEvent(event.name, event.data);" "            if (event.name !== \"activewindowv2\")
                root.handleEvent(event.name, event.data);"
try "G4 closewindow is not forwarded" $K "            root.handleEvent(event.name, event.data);" "            if (event.name !== \"closewindow\")
                root.handleEvent(event.name, event.data);"
try "openwindow is not forwarded" $K "            root.handleEvent(event.name, event.data);" "            if (event.name !== \"openwindow\")
                root.handleEvent(event.name, event.data);"
try "the event data is dropped" $K "            root.handleEvent(event.name, event.data);" "            root.handleEvent(event.name, \"\");"
try "G3 the context never names the focused window" $K "            focused: root.readFocused()," "            focused: \"\","
try "the context gives no current Space" $K "            currentWorkspace: root.readCurrentWorkspace()," "            currentWorkspace: 0,"
try "the context drops Stages" $K "            stages: root.stages," "            stages: false,"
try "the context says the window list is loaded when it is not" $K "            loaded: root.readLoaded()," "            loaded: true,"
try "the window list is built for every event" $K "root.step(Flow.onEvent(root.flow, root.context(Flow.needsWindows(root.flow, name, data)), name, data));" "root.step(Flow.onEvent(root.flow, root.context(true), name, data));"
try "the window list is never built for an event" $K "root.context(Flow.needsWindows(root.flow, name, data))" "root.context(false)"
try "the lookback is unbounded" $K "lookbackEvents: 2," "lookbackEvents: 1000000,"
try "the lookback is zero" $K "lookbackEvents: 2," "lookbackEvents: 0,"
try "the recovery bound is unbounded" $K "maxRecover: root.recoverTries," "maxRecover: 1000000,"
try "the record file is never written" $K "        if (res.persist)
            root.persistRequested(ShowDesktop.serialize(res.state.records));" "        if (false)
            root.persistRequested(ShowDesktop.serialize(res.state.records));"
try "the record file gets no records" $K "root.persistRequested(ShowDesktop.serialize(res.state.records));" "root.persistRequested(ShowDesktop.serialize([]));"
try "a timer the flow asks to restart is stopped" $K "                timers[id].restart();" "                timers[id].stop();"
try "the keyboard is never handed to the desktop" $K "        if (res.focusDesktop)
            root.focusDesktopRequested();" "        if (false)
            root.focusDesktopRequested();"
try "the press never reads the window list again" $K "            root.refreshWindows();
            refresh.restart();" "            refresh.restart();"
try "the capture timer is never started" $K "            refresh.restart();" "            refresh.stop();"
try "the activation timer asks the flow for the wrong timer" $K 'root.context(true), "activation"))' 'root.context(true), "check"))'
try "the verify timer asks the flow for the wrong timer" $K 'root.context(true), "verify"))' 'root.context(true), "recover"))'
try "the recover timer asks the flow for the wrong timer" $K 'root.context(true), "recover"))' 'root.context(true), "verify"))'
try "the screens changing is not handed to the flow" $K "root.step(Flow.onScreensChanged(root.flow, root.context(true)));" "root.context(true);"
try "the record file text is not parsed" $K "ShowDesktop.parse(text)" "[]"
try "a shell activation ends nothing" $K "return root.step(Flow.onActivate(root.flow, root.context(true))).ended;" "return false;"

# ---- the flow: an app activating a parked window -------------------------------------------------------------------------------------
try "an activation names a window that is neither parked nor ours" $F "    return (ctx.windows || []).some(w => SD.sameAddress(w.address, a) && w.parked === true);" "    return true;"
try "an activation names only a window this flow sent back (a parked orphan is never focused)" $F "    return (ctx.windows || []).some(w => SD.sameAddress(w.address, a) && w.parked === true);" "    return false;"
try "R4 the focus is asked for whatever the activation named" $F '        if (w.parked !== true) {
            if (mine)
                send(r, Minimized.focusWindowRequest(a));   // it went back with the others and keeps the focus' '        if (w.parked !== true) {
            if (true)
                send(r, Minimized.focusWindowRequest(a));   // it went back with the others and keeps the focus'
try "a window that is still parked is focused (the workspace is shown again)" $F "        } else if (mine) {
            // never ask for the focus" "        } else if (false) {
            // never ask for the focus"
try "a window that is still parked is never looked at again" $F "            if (act.tries < ctx.maxActivationTries) {" "            if (false) {"
try "a window that is still parked is looked at for ever" $F "            if (act.tries < ctx.maxActivationTries) {" "            if (true) {"
try "a parked orphan does not come back" $F "        } else if (ctx.currentWorkspace > 0 && !inRecords(s.records, a)) {" "        } else if (false) {"
try "a parked orphan is not focused" $F "            send(r, Minimized.moveRequest(a, String(ctx.currentWorkspace)));
            send(r, Minimized.focusWindowRequest(a));" "            send(r, Minimized.moveRequest(a, String(ctx.currentWorkspace)));"
try "a parked orphan is focused before it is moved" $F "            send(r, Minimized.moveRequest(a, String(ctx.currentWorkspace)));
            send(r, Minimized.focusWindowRequest(a));" "            send(r, Minimized.focusWindowRequest(a));
            send(r, Minimized.moveRequest(a, String(ctx.currentWorkspace)));"
try "a parked orphan comes back to the Space of the first display" $F "send(r, Minimized.moveRequest(a, String(ctx.currentWorkspace)));
            send(r, Minimized.focusWindowRequest(a));" "send(r, Minimized.moveRequest(a, String(ctx.shown.length > 0 ? ctx.shown[0].workspace : 1)));
            send(r, Minimized.focusWindowRequest(a));"
try "the activation window is not sealed by the hide" $F "            s.activation.sealed = true;   // the workspace is hidden again" "            s.activation.sealed = false;   // the workspace is hidden again"
try "the activation window is not sealed by a move" $F "        if (s.activation.open)
            s.activation.sealed = true;
        return r;
    }
    if (name === \"activewindowv2\") {" "        return r;
    }
    if (name === \"activewindowv2\") {"
try "the window before the workspace event wins over the one after" $F 'const a = act.after !== "" ? act.after : act.before;' 'const a = act.before !== "" ? act.before : act.after;'
try "only the window after the workspace event counts" $F 'before: before, after: "", tries: 0};
            r.timers.activation' 'before: "", after: "", tries: 0};
            r.timers.activation'
try "the controller's look at a window that is still parked is unbounded" $K "maxActivationTries: 3" "maxActivationTries: 1000000"
try "the controller's verify is unbounded" $K "maxVerify: 3," "maxVerify: 1000000,"
try "the window list is not built while an activation is open" $F "    if (state.records.length > 0 || state.verify.records.length > 0 || state.activation.open)" "    if (state.records.length > 0 || state.verify.records.length > 0)"
try "an orphan branch takes a window a record lists" $F "} else if (ctx.currentWorkspace > 0 && !inRecords(s.records, a)) {" "} else if (ctx.currentWorkspace > 0) {"
try "the window before the workspace event has no limit" $F "const before = s.seq - seen.seq <= ctx.lookbackEvents ? seen.address : \"\";" "const before = seen.address;"
try "every event counts for the lookback" $F 'if (COUNTED.indexOf(name) >= 0)
        s.seq++;' 's.seq++;'
try "no event counts for the lookback" $F 'if (COUNTED.indexOf(name) >= 0)
        s.seq++;' 'if (false)
        s.seq++;'
try "the last window named after the workspace event wins" $F 's.activation.after === "" && eligible(s, ctx, a))' 'eligible(s, ctx, a))'
try "the echo of our own show is an activation" $F "            if (s.twin[monitor] === name) {
                delete s.twin[monitor];
                return r;
            }" "            if (false) {
                return r;
            }"
try "the echo is never recognised (the twin is not noted)" $F "            s.twin[monitor] = otherForm(name);" "            s.twin[monitor] = \"\";"
try "the echo marks the workspace shown" $F "            if (s.twin[monitor] === name) {
                delete s.twin[monitor];
                return r;
            }
            s.twin[monitor] = otherForm(name);
        } else {
            delete s.twin[monitor];
        }
        s.parking = SD.parkingShownAfter(s.parking, name, data);" "            if (s.twin[monitor] === name) {
                delete s.twin[monitor];
                s.parking = SD.parkingShownAfter(s.parking, name, data);
                return r;
            }
            s.twin[monitor] = otherForm(name);
        } else {
            delete s.twin[monitor];
        }
        s.parking = SD.parkingShownAfter(s.parking, name, data);"
try "the twin of a hidden workspace is never forgotten (a new show is taken for an echo)" $F "        } else {
            delete s.twin[monitor];
        }" "        } else {
        }"
try "a records-empty activation opens no naming window" $F "            s.activation = {open: true, sealed: false, before: before, after: \"\", tries: 0};" "            s.activation = {open: s.records.length > 0, sealed: false, before: before, after: \"\", tries: 0};"
try "an ending handled first leaves the workspace shown" $F "                hideByState(s, ctx, r);   // no record (an earlier ending ran first, or it was lost): the workspace is still hidden" "                s.parking = {};"
try "R1 the hide comes after the moves" $F "    hideByState(s, ctx, r);
    const focus = refocus" "    const focus = refocus" "    s.ended = back;" "    hideByState(s, ctx, r);
    s.ended = back;"
try "the hide is a blind toggle" $F "    if (!SD.parkingVisible(s.parking))
        return;
    send(r, SD.hideParkingRequest());" "    send(r, SD.hideParkingRequest());"
try "the hide does not forget the shown state (a second ending toggles again)" $F "    send(r, SD.hideParkingRequest());
    s.parking = {};" "    send(r, SD.hideParkingRequest());"
try "an activation ends with a focus request for the refocus window" $F "                log(r, \"info\", \"Show Desktop ends: \" + name);
                ending(s, ctx, r, false);
            } else {" "                log(r, \"info\", \"Show Desktop ends: \" + name);
                ending(s, ctx, r, true);
            } else {"
try "every ending asks for focus" $F "const focus = refocus ? SD.focusTarget(records, ctx.shown) : \"\";" "const focus = SD.focusTarget(records, ctx.shown);"
try "an ending sends the windows to the Space shown now" $F "        mine.forEach(a => send(r, Minimized.moveRequest(a, String(record.workspace))));" "        mine.forEach(a => send(r, Minimized.moveRequest(a, String(ctx.currentWorkspace))));"
try "the verify sends the windows to the Space shown now" $F "        stuck.forEach(a => send(r, Minimized.moveRequest(a, String(record.workspace))));" "        stuck.forEach(a => send(r, Minimized.moveRequest(a, String(ctx.currentWorkspace))));"
try "the recovery sends the windows to the Space shown now" $F "send(r, Minimized.moveRequest(m.address, String(m.workspace))));" "send(r, Minimized.moveRequest(m.address, String(ctx.currentWorkspace))));"

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
    s.ended = [];
    r.timers.verify = \"stop\";" "    s.ended = [];"
try "R2 the stragglers are read after the verify records are cleared" $F "    let stragglers = [];
    if (s.verify.records.length > 0) {" "    let stragglers = [];
    s.verify = {records: [], tries: 0};
    if (s.verify.records.length > 0) {"
try "the stragglers are moved back at the capture (visible during the new Show Desktop)" $F "        stragglers = SD.stragglerRecords(s.verify.records, parkedNow);" "        stragglers = SD.stragglerRecords(s.verify.records, parkedNow);
        stragglers.forEach(rec => rec.windows.forEach(w => send(r, Minimized.moveRequest(w.address, String(rec.workspace)))));"
try "the stragglers are not merged into the new records" $F "    s.records = records.concat(stragglers);" "    s.records = records;"
try "the verify's end keeps the windows it sent back as ours (a window parked later is waited for, never focused)" $F "    s.verify = {records: [], tries: 0};
    s.ended = [];   // the windows are back" "    s.verify = {records: [], tries: 0};   // the windows are back"
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
