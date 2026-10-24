#!/usr/bin/env bash
# Show Desktop wiring in shell/platform/Compositor.qml (static; the behaviour is tests/unit/tst_showdesktop.qml and the nested
# tests/shell/show_desktop_nested.sh). A stale handler once survived an edit and never ended Show Desktop: this fails on
#  * a Space/window event handler that does not pass the event data and the records to ShowDesktop.endsOn;
#  * a name that no longer exists (the single `desktopRecord`, a timing guard);
#  * a Tokens.showDesktop* name that Tokens.qml does not define;
#  * an ending that asks for focus when it was not the second press (activate() focuses only the window it activates).
set -uo pipefail
root=${WIRING_ROOT:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel)}
cd "$root" || exit 2
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
f=shell/platform/Compositor.qml

desc="the raw-event handler ends Show Desktop with the event data and the records"
check grep -q 'ShowDesktop.endsOn(event.name, event.data, root.desktopRecords)' "$f"

desc="a workspace or monitor event only schedules a look at what each display shows (a focus move raises one too)"
check bash -c 'grep -q "ShowDesktop.checksSpaces(event.name)" "$1" && grep -q "ShowDesktop.spaceChanged(root.desktopRecords, root.shownSpaces())" "$1"' _ "$f"

desc="no removed name is left (desktopRecord, desktopHiddenAt, a timing guard)"
check bash -c '! grep -nE "desktopRecord\b|desktopHiddenAt|showDesktopGuardMs" "$1"' _ "$f"

desc="every Tokens.showDesktop* the shell uses is defined"
missing=""
for t in $(grep -ohE 'Tokens\.showDesktop[A-Za-z]+' shell/platform/*.qml | sort -u | sed 's/Tokens\.//'); do
  grep -q "property .* $t:" ui/Grassfield/Ui/Tokens.qml || missing+=" $t"
done
check test -z "$missing"

desc="every ending except the second press passes refocus=false"
check bash -c 'n=$(grep -c "endShowDesktop(" "$1"); t=$(grep -c "endShowDesktop(true)" "$1"); [ "$(grep -cE "endShowDesktop\(\)" "$1")" = 0 ] && [ "$t" = 1 ] && [ "$n" -ge 4 ]' _ "$f"
desc="every ending is followed by the bounded verify (endShowDesktop restarts it, at most 3 tries)"
check bash -c 'grep -q "desktopVerify.restart()" "$1" && grep -qF "++tries < 3) {" "$1" && grep -q "id: desktopVerify" "$1"' _ "$f"

desc="a new capture stops the verify of the previous ending (three quick presses)"
check bash -c 'awk "/function captureDesktop/,/^    }/" "$1" | grep -q "desktopVerify.stop()"' _ "$f"

desc="a focus request only comes from the second press (endShowDesktop) and from the window that was activated (activate, the desktopActivation timer)"
check bash -c 'n=$(grep -c "focusWindowRequest(" "$1"); a=$(awk "/function endShowDesktop/,/^    }/" "$1" | grep -c "focusWindowRequest("); b=$(awk "/function activate\\(/,/^    }/" "$1" | grep -c "focusWindowRequest("); c=$(awk "/id: desktopActivation/,/^    }/" "$1" | grep -c "focusWindowRequest("); [ "$a" = 1 ] && [ "$b" = 1 ] && [ "$c" = 1 ] && [ "$n" = 4 ]' _ "$f"

desc="every ending hides the parking workspace by STATE and BEFORE the windows move (no frame with the parked windows on screen, never a blind toggle)"
check bash -c 'body=$(awk "/function endShowDesktop/,/^    }/" "$1"); h=$(grep -n "parkingVisible(root.parkingShown)" <<<"$body" | head -1 | cut -d: -f1); d=$(grep -n "hideParkingRequest()" <<<"$body" | head -1 | cut -d: -f1); m=$(grep -n "ShowDesktop.toRestore(" <<<"$body" | head -1 | cut -d: -f1); [ -n "$h" ] && [ -n "$d" ] && [ -n "$m" ] && [ "$h" -lt "$d" ] && [ "$d" -lt "$m" ] && ! grep -q "hideParkingRequest" <(awk "/id: desktopActivation/,/^    }/" "$1")' _ "$f"

desc="the parking workspace state is tracked from every activespecial event, also when Show Desktop is off"
check bash -c 'awk "/function onRawEvent/,/^        }/" "$1" | head -12 | grep -q "ShowDesktop.parkingShownAfter(root.parkingShown"' _ "$f"

desc="the activation ends Show Desktop at once (no timer before the ending) and the timer only asks for the focus"
check bash -c 'awk "/function onRawEvent/,/^        }/" "$1" | grep -q "root.endShowDesktop(false);" && ! awk "/id: desktopActivation/,/^    }/" "$1" | grep -q "endShowDesktop"' _ "$f"

desc="the crash recovery applies ShowDesktop.recoverStep: its moves, its retry (bounded by the step, not by a loop here) and its clear"
check bash -c 'b=$(awk "/function recoverDesktop/,/^    }/" "$1"); grep -q "ShowDesktop.recoverStep(root.desktopRecords, toplevelData(), loaded, root.recoverTries, Tokens.showDesktopRecoverTries)" <<<"$b" && grep -q "step.moves.forEach" <<<"$b" && grep -q "root.recoverTries++" <<<"$b" && grep -q "if (step.retry)" <<<"$b" && grep -q "else if (step.clear)" <<<"$b" && grep -q "const loaded = Hyprland.toplevels" <<<"$b"' _ "$f"

desc="the verify keeps a record for what is still parked at its bound, and a new capture finishes the previous restore and merges its stragglers"
check bash -c 'grep -q "ShowDesktop.stragglerRecords(records, parked)" "$1" && awk "/function captureDesktop/,/^    }/" "$1" | grep -q "records.concat(stragglers)" && awk "/function captureDesktop/,/^    }/" "$1" | grep -q "ShowDesktop.stragglerRecords(desktopVerify.records"' _ "$f"

desc="no activation is read from the focus (a parked window can keep it): only the parking workspace being shown ends it"
check bash -c '! grep -qE "parkedHasFocus|checksActivation" "$1" shell/platform/ShowDesktop.js' _ "$f"

desc="restoring a minimized window and the second press end it (unminimize and showDesktop call endShowDesktop before the Stages test)"
check bash -c 'awk "/function unminimize/,/^    }/" "$1" | grep -q "endShowDesktop(false)" && awk "/function showDesktop\\(/,/^    }/" "$1" | head -4 | grep -q "endShowDesktop(true)"' _ "$f"

exit $fail
