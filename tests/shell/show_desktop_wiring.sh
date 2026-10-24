#!/usr/bin/env bash
# Show Desktop wiring in shell/platform/Compositor.qml (static; the behaviour is tests/unit/tst_showdesktop.qml and the nested
# tests/shell/show_desktop_nested.sh). A stale handler once survived an edit and never ended Show Desktop: this fails on
#  * a Space/window event handler that does not pass the event data and the records to ShowDesktop.endsOn;
#  * a name that no longer exists (the single `desktopRecord`, a timing guard);
#  * a Tokens.showDesktop* name that Tokens.qml does not define;
#  * an ending that asks for focus when it was not the second press (activate() focuses only the window it activates).
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root" || exit 2
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
f=shell/platform/Compositor.qml

desc="the raw-event handler ends Show Desktop with the event data and the records"
check grep -q 'ShowDesktop.endsOn(event.name, event.data, root.desktopRecords)' "$f"

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
exit $fail
