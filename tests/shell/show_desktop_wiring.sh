#!/usr/bin/env bash
# Show Desktop wiring in shell/platform/Compositor.qml (static). Every decision lives in shell/platform/ShowDesktopFlow.js and is
# tested by behaviour (tests/unit/tst_showdesktopflow.qml, tst_showdesktopreplay.qml; nested: tests/shell/show_desktop_nested.sh).
# What is left to check here is that Compositor.qml stays a thin forwarder, so a decision cannot creep back into it unseen:
#  * every call into the flow goes through desktopStep, and the events, the timers, the press, the capture, the file read and the
#    activations are each forwarded to their function of the flow;
#  * desktopStep runs the dispatches with a plain loop, in the order given (no timer, no callLater: the hide must stay first);
#  * the Show Desktop block takes no decision of its own (no ShowDesktop.* rule, no focus request, no Qt.callLater);
#  * a Tokens.showDesktop* name that Tokens.qml does not define.
# WIRING_ROOT (a copy of the tree) is for tests/shell/ux_mutants.sh.
set -uo pipefail
root=${WIRING_ROOT:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel)}
cd "$root" || exit 2
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
f=shell/platform/Compositor.qml
# the Show Desktop block of the singleton
block() { awk '/---- Show Desktop \(macOS/,/"Hide Others"/' "$f"; }

desc="the raw events go to ShowDesktopFlow.onEvent with the name and the data, through desktopStep"
check grep -qF 'root.desktopStep(ShowDesktopFlow.onEvent(root.desktopFlow, root.desktopContext(), event.name, event.data));' "$f"

desc="each timer forwards its own id to ShowDesktopFlow.onTimer (activation, check, verify, recover)"
check bash -c 'for id in activation check verify recover; do grep -qF "root.desktopStep(ShowDesktopFlow.onTimer(root.desktopFlow, root.desktopContext(), \"$id\"))" "$1" || exit 1; done' _ "$f"

desc="the press, the capture, the file read, the screens change and the shell's own activations are forwarded to the flow"
check bash -c 'for c in "ShowDesktopFlow.onPress(" "ShowDesktopFlow.onCapture(" "ShowDesktopFlow.onLoaded(" "ShowDesktopFlow.onScreensChanged(" "ShowDesktopFlow.onActivate("; do grep -qF "$c" "$1" || exit 1; done' _ "$f"

desc="every call into the flow goes through desktopStep (the state is only ever replaced by a result)"
check bash -c 'n=$(grep -c "ShowDesktopFlow\\.on" "$1"); d=$(grep -c "desktopStep(ShowDesktopFlow\\.on" "$1"); [ "$n" -ge 9 ] && [ "$n" = "$d" ] && [ "$(grep -c "root.desktopFlow = " "$1")" = 1 ]' _ "$f"

desc="desktopStep runs the dispatches in the order given with a plain loop, before the file and the timers"
check bash -c 'b=$(awk "/function desktopStep/,/^    }/" "$1"); [ -n "$b" ] && grep -qF "for (const request of res.dispatches)" <<<"$b" && grep -qF "dispatchRequest(request);" <<<"$b" && d=$(grep -n "res.dispatches" <<<"$b" | head -1 | cut -d: -f1) && p=$(grep -n "res.persist" <<<"$b" | head -1 | cut -d: -f1) && t=$(grep -n "res.timers" <<<"$b" | head -1 | cut -d: -f1) && [ "$d" -lt "$p" ] && [ "$p" -lt "$t" ] && ! grep -qE "callLater|Timer|setTimeout" <<<"$b"' _ "$f"

desc="desktopStep writes the record file from the result's records, restarts or stops the timers it names, and hands the keyboard to the desktop when asked"
check bash -c 'b=$(awk "/function desktopStep/,/^    }/" "$1"); grep -qF "if (res.persist && desktopFile.path !== \"\")" <<<"$b" && grep -qF "desktopFile.setText(ShowDesktop.serialize(res.state.records));" <<<"$b" && grep -qF "timers[id].stop();" <<<"$b" && grep -qF "timers[id].restart();" <<<"$b" && grep -qF "if (res.focusDesktop)" <<<"$b" && grep -qF "DesktopState.focusRequested();" <<<"$b" && grep -qF "root.desktopFlow = res.state;" <<<"$b"' _ "$f"

desc="the press reads the window list first when the flow asks for it (refresh), and the second press is the flow's"
check bash -c 'b=$(awk "/function showDesktop\\(/,/^    }/" "$1"); grep -qF "if (res.refresh) {" <<<"$b" && grep -qF "Hyprland.refreshToplevels();" <<<"$b" && grep -qF "desktopRefresh.restart();" <<<"$b"' _ "$f"

desc="the Show Desktop block takes no decision of its own: no callLater, no focus request, no rule of ShowDesktop.js (only the file format and the parking name)"
check bash -c 'b=$(awk "/---- Show Desktop \\(macOS/,/\"Hide Others\"/" "$1"); [ "$(wc -l <<<"$b")" -gt 100 ] && ! grep -qE "Qt.callLater|focusWindowRequest|moveRequest|hideParkingRequest|endsOn|checksSpaces|spaceChanged|toRestore|survivors|stragglerRecords|recoverStep|parkingShownAfter|captureAll" <<<"$b"' _ "$f"

desc="the only focus request next to the flow is activate() giving the focus to the window it activates (after the ending); the other is the plain focus action"
check bash -c 'a=$(awk "/function activate\\(/,/^    }/" "$1" | grep -c "focusWindowRequest("); [ "$(grep -c "focusWindowRequest(" "$1")" = 2 ] && [ "$a" = 1 ]' _ "$f"

desc="activate() and unminimize() end Show Desktop first (before the Stages test, before the focus)"
check bash -c 'awk "/function activate\\(/,/^    }/" "$1" | head -8 | grep -q "root.endShowDesktop()" && awk "/function unminimize/,/^    }/" "$1" | grep -q "root.endShowDesktop()"' _ "$f"

desc="the verify, the check, the activation and the recovery timers are the Tokens ones (no literal interval)"
check bash -c 'for t in desktopActivation desktopCheck desktopVerify desktopRefresh desktopRecover; do awk "/id: $t/,/^    }/" "$1" | grep -qE "interval: Tokens\\.showDesktop" || exit 1; done' _ "$f"

desc="the context carries the bounds and windows the flow needs (lookback, echo, verify and recovery bounds from Tokens)"
check bash -c 'b=$(awk "/function desktopContext/,/^    }/" "$1"); grep -qF "lookbackMs: Tokens.showDesktopCheckMs" <<<"$b" && grep -qF "echoMs: Tokens.showDesktopVerifyMs" <<<"$b" && grep -qF "maxRecover: Tokens.showDesktopRecoverTries" <<<"$b" && grep -qF "windows: toplevelData()" <<<"$b" && grep -qF "now: Date.now()" <<<"$b"' _ "$f"

desc="no removed name is left (the single desktopRecord, desktopHiddenAt, a timing guard, the old imperative functions)"
check bash -c '! grep -nE "desktopRecord\b|desktopHiddenAt|showDesktopGuardMs|captureDesktop|recoverDesktop|endForActivation|activationWatch|parkingShown" "$1"' _ "$f"

desc="every Tokens.showDesktop* the shell uses is defined"
missing=""
for t in $(grep -ohE 'Tokens\.showDesktop[A-Za-z]+' shell/platform/*.qml | sort -u | sed 's/Tokens\.//'); do
  grep -q "property .* $t:" ui/Grassfield/Ui/Tokens.qml || missing+=" $t"
done
check test -z "$missing"

exit $fail
