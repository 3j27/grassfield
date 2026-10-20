#!/usr/bin/env bash
# Notifications column: the keyboard focus after an app replaces its notification (same id) and drops another action while an action
# button holds the focus (focus resolver, docs/specs/notifications.md). The buttons are rebuilt by the update; the ring must stay on the
# button "Mark Read". Captures before and after (.dev/visual/shots/notification-focus-*.en.png); not part of the baseline run.
# The script FAILS (exit 1) when no focus ring is drawn on the expected button: it waits for the ring (up to 10 captures per step, the
# column is reopened up to 3 times), then checks the pixels of the capture (saturated accent pixels in the button row, their left edge).
# Private bus only. Run it as a BARE command with a relative path: tests/visual/notification-focus.sh
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

# ring_stats FILE: "COUNT MINX MAXX" of the green-dominant pixels (the accent ring of the fixture session; the buttons, the card and
# the text are grey or white, the sub-pixel fringes of the text are orange and blue) in the button row of the first card
# (x 1600..1900, y 128..168 of the 1920x1080 capture).
ring_stats() {
  magick "$1" -crop 300x40+1600+128 +repage txt:- | awk -F'[(),: ]+' '
    /^[0-9]+,[0-9]+:/ {
      x = $1 + 1600; r = $3; g = $4; b = $5
      if (g > 120 && g > r + 50 && g > b + 30) { n++; if (minx == "" || x < minx) minx = x; if (x > maxx) maxx = x }
    }
    END { printf "%d %d %d\n", n, (minx == "" ? 0 : minx), maxx }'
}

# wait_ring NAME LO HI: capture until the ring is drawn with its left edge in [LO, HI] (the button "Mark Read"); 0 when it is.
wait_ring() {
  local name=$1 lo=$2 hi=$3 try file count minx maxx
  for try in 1 2 3 4 5 6 7 8 9 10; do
    vs_capture "$name" >/dev/null
    file=$VS_SHOTS/$name.$VS_LANG.png
    read -r count minx maxx < <(ring_stats "$file")
    echo "notification-focus: $name try $try: ring pixels $count, x $minx..$maxx"
    if ((count >= 150 && minx >= lo && minx <= hi)); then
      return 0
    fi
    vs_sleep 0.7
  done
  return 1
}

id=$(notify 0 "['a','Reply','b','Mark Read','c','Archive']" | sed -E 's/^\(uint32 ([0-9]+),\)$/\1/')
[[ $id =~ ^[0-9]+$ ]] || { echo "notification-focus: no notification id ($id)" >&2; exit 1; }
vs_sleep 1
ok=0
for attempt in 1 2 3; do
  # Open the column from the clock, then Tab: card, its x, Reply, Mark Read.
  vs_pointer abs 1850 12 sleep 300 click
  vs_sleep 1
  for _ in 1 2 3 4; do "$VS_ROOT/scripts/dev/keys.sh" -k Tab; vs_sleep 0.2; done
  # Mark Read: left edge about x 1691 before the update.
  if wait_ring notification-focus-before 1675 1705; then
    ok=1
    break
  fi
  echo "notification-focus: no ring on Mark Read (attempt $attempt): closing and reopening the column" >&2
  "$VS_ROOT/scripts/dev/keys.sh" -k Escape
  vs_sleep 1
done
((ok == 1)) || { echo "notification-focus: FAIL: no focus ring on Mark Read before the update" >&2; exit 1; }
# The app replaces the notification and drops "Reply": the focused button is rebuilt and moves left.
notify "$id" "['b','Mark Read','c','Archive']" >/dev/null
vs_sleep 1
# Mark Read: left edge about x 1617 after the update.
wait_ring notification-focus-after 1600 1635 || { echo "notification-focus: FAIL: no focus ring on Mark Read after the update" >&2; exit 1; }
echo "notification-focus: PASS (captures in $VS_SHOTS)"
