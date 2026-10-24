#!/usr/bin/env bash
# Show Desktop wiring in shell/platform/Compositor.qml (static). The rules are a pure reducer, shell/platform/ShowDesktopFlow.js,
# tested by behaviour (tests/unit/tst_showdesktopflow.qml, tst_showdesktopreplay.qml with sequences recorded from Hyprland); the
# glue that runs it (events in, dispatches/timers/record file out) is shell/platform/showdesktop/ShowDesktopController.qml, loaded
# offscreen by tests/unit/tst_showdesktopglue.qml. What is left to check here is the last, thin layer: that Compositor.qml hands the
# controller the real Hyprland, how to read the window list and the Spaces, where to dispatch and where the record file is, and
# takes no decision of its own; plus two things a behaviour test cannot see (no clock in the flow, Tokens for every wait).
# WIRING_ROOT (a copy of the tree) is for tests/shell/ux_mutants.sh.
set -uo pipefail
root=${WIRING_ROOT:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel)}
cd "$root" || exit 2
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
f=shell/platform/Compositor.qml
c=shell/platform/showdesktop/ShowDesktopController.qml

desc="the controller gets the real Hyprland as its event source"
check grep -qF 'eventSource: Hyprland' "$f"

desc="the controller reads the window list, the Spaces, the focused window, the current Space and the loaded state from the real objects"
check bash -c 'for c in "readWindows: () => root.toplevelData()" "readShown: () => root.shownSpaces()" "readFocused: () =>" "focused ? focused.address : \"\"" "readCurrentWorkspace: () => Hyprland.focusedMonitor && Hyprland.focusedMonitor.activeWorkspace ? Hyprland.focusedMonitor.activeWorkspace.id : 0" "readLoaded: () => !!Hyprland.toplevels && Hyprland.toplevels.values.length > 0" "stages: Settings.windowsStages"; do grep -qF "$c" "$1" || { echo "missing: $c"; exit 1; }; done' _ "$f"

desc="the controller dispatches through dispatchRequest, reads the window list through Hyprland, writes the record file and hands the keyboard to the desktop"
check bash -c 'for c in "dispatch: request => root.dispatchRequest(request)" "refreshWindows: () => Hyprland.refreshToplevels()" "desktopFile.setText(text);" "onFocusDesktopRequested: DesktopState.focusRequested()"; do grep -qF "$c" "$1" || { echo "missing: $c"; exit 1; }; done' _ "$f"

desc="the press, the shell's own activations, the screens changing and the record file read are forwarded to the controller"
check bash -c 'for c in "showDesktopFlow.press();" "return showDesktopFlow.endForActivation();" "showDesktopFlow.screensChanged();" "onLoaded: showDesktopFlow.recordsLoaded(desktopFile.text())"; do grep -qF "$c" "$1" || { echo "missing: $c"; exit 1; }; done' _ "$f"

desc="the Show Desktop block takes no decision of its own: no callLater, no flow call, no focus request, no rule of ShowDesktop.js"
check bash -c 'b=$(awk "/---- Show Desktop \\(macOS/,/\"Hide Others\"/" "$1"); [ "$(wc -l <<<"$b")" -gt 60 ] && ! grep -qE "Qt.callLater|ShowDesktopFlow\\.on[A-Z]|focusWindowRequest|moveRequest|hideParkingRequest|endsOn|checksSpaces|spaceChanged|toRestore|survivors|stragglerRecords|recoverStep|parkingShownAfter|captureAll|Date.now" <<<"$b"' _ "$f"

desc="the only focus requests in the Compositor are activate() giving the focus to the window it activates (after the ending) and the plain focus action"
check bash -c 'a=$(awk "/function activate\\(/,/^    }/" "$1" | grep -c "focusWindowRequest("); [ "$(grep -c "focusWindowRequest(" "$1")" = 2 ] && [ "$a" = 1 ]' _ "$f"

desc="activate() and unminimize() end Show Desktop first (before the Stages test, before the focus)"
check bash -c 'awk "/function activate\\(/,/^    }/" "$1" | head -8 | grep -q "root.endShowDesktop()" && awk "/function unminimize/,/^    }/" "$1" | grep -q "root.endShowDesktop()"' _ "$f"

desc="no clock in the flow, its rules or its controller (what is right before is counted in events, an echo is matched to its event, waits are timers)"
check bash -c '! grep -nE "Date\\.now|new Date|performance\\.now|getTime\\(" shell/platform/ShowDesktopFlow.js shell/platform/ShowDesktop.js shell/platform/showdesktop/ShowDesktopController.qml' _

desc="no clock in the Show Desktop block of the Compositor either"
check bash -c '! awk "/---- Show Desktop \\(macOS/,/\"Hide Others\"/" "$1" | grep -nE "Date\\.now|new Date"' _ "$f"

desc="every wait of the controller is a Tokens one (no literal interval)"
check bash -c 'for p in "property int checkMs: Tokens.showDesktopCheckMs" "property int verifyMs: Tokens.showDesktopVerifyMs" "property int refreshMs: Tokens.showDesktopRefreshMs" "property int recoverMs: Tokens.showDesktopRecoverMs" "property int recoverTries: Tokens.showDesktopRecoverTries"; do grep -qF "$p" "$1" || exit 1; done; for t in activation check verify refresh recover; do awk "/id: $t\$/,/^    }/" "$1" | grep -qE "interval: root\\.[a-z]+Ms" || exit 1; done' _ "$c"

desc="no removed name is left (the single desktopRecord, desktopHiddenAt, a timing guard, the old imperative functions)"
check bash -c '! grep -nE "desktopRecord\b|desktopHiddenAt|showDesktopGuardMs|captureDesktop|recoverDesktop|endForActivation\\(\\): void|activationWatch|parkingShown|desktopStep|desktopContext|echoMs|hideAt" "$1"' _ "$f"

desc="every Tokens.showDesktop* the shell uses is defined"
missing=""
for t in $(grep -ohE 'Tokens\.showDesktop[A-Za-z]+' shell/platform/*.qml shell/platform/showdesktop/*.qml | sort -u | sed 's/Tokens\.//'); do
  grep -q "property .* $t:" ui/Grassfield/Ui/Tokens.qml || missing+=" $t"
done
check test -z "$missing"

exit $fail
