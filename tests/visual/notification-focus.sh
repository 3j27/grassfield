#!/usr/bin/env bash
# Notifications column: the keyboard focus after an app replaces its notification (same id) and drops another action while an action
# button holds the focus (focus resolver, docs/specs/notifications.md). The buttons are rebuilt by the update; the ring must stay on the
# button "Mark Read". Captures before and after (.dev/visual/shots/notification-focus-*.en.png); not part of the baseline run.
# Private bus only. Run it as a BARE command (nested session).
source "$(dirname "$0")/lib.sh"
vs_session
vs_reset
bus=$(<"$VS_DEV/bus.address")
case $bus in
unix:path=/tmp/dbus-*) ;;
*) echo "notification-focus: refusing: unexpected bus address $bus" >&2; exit 1 ;;
esac
notify() {
  gdbus call --address "$bus" --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
    --method org.freedesktop.Notifications.Notify Mail "$1" "" "Anna Martin" "Are we still on for lunch tomorrow?" "$2" '{}' 0
}
id=$(notify 0 "['a','Reply','b','Mark Read','c','Archive']" | sed -E 's/^\(uint32 ([0-9]+),\)$/\1/')
[[ $id =~ ^[0-9]+$ ]] || { echo "notification-focus: no notification id ($id)" >&2; exit 1; }
vs_sleep 1
# Open the column from the clock, then Tab: card, its x, Reply, Mark Read.
vs_pointer abs 1850 12 sleep 300 click
vs_sleep 1
for _ in 1 2 3 4; do "$VS_ROOT/scripts/dev/keys.sh" -k Tab; vs_sleep 0.2; done
vs_capture notification-focus-before
# The app replaces the notification and drops "Reply": the focused button is rebuilt.
notify "$id" "['b','Mark Read','c','Archive']" >/dev/null
vs_sleep 1
vs_capture notification-focus-after
echo "notification-focus: captures in $VS_SHOTS"
