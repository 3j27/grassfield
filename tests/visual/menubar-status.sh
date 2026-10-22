#!/usr/bin/env bash
# The menu bar's status area on GF-REF (docs/specs/menubar.md): third-party status items (StatusNotifierItem test items on
# the PRIVATE bus), their menu, hover tracking and clicks, the Now Playing item with a test MPRIS player, the Search item
# and crowding with a very long application name. Each check prints PASS/FAIL; captures are in $VS_SHOTS/mbs-*.png
# (dark and light).
#   order          tray items sit left of the system items, in registration order, none overlaps the menus
#   tray-menu      a press on an ItemIsMenu item opens its menu (kind tray)
#   tray-hover     with a tray menu open, moving onto another item with a menu switches to its menu
#   tray-activate  a press on an item that is not ItemIsMenu sends Activate to the application and closes the menu
#   nowplaying     the item shows while the test player plays; its popover's pause button reaches the player
#   search         the Search item opens Search and a second press closes it
#   crowding       a very long application name hides the leftmost optional items and never overlaps the menus
# Usage (bare command): tests/visual/menubar-status.sh
source "$(dirname "$0")/lib.sh"

fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}
kind() { vs_ipc menubar openKind | tr -d '"'; }
is_kind() { [[ $(kind) == "$1@$VS_OUTPUT" ]]; }
closed() { [[ -z $(kind) ]]; }
state() { vs_ipc menubar statusState "$VS_OUTPUT"; }
x_of() { # accessible name -> centre x of that status button
  state | jq -r --arg n "$1" '.status[] | select(.name == $n) | (.x + .w / 2 | floor)' | head -n 1
}
# A press right after the motion that enters a layer surface is not delivered (Hyprland focuses the layer on the motion):
# a real pointer moves first. hover = two motions and a pause, press = hover, then a button down and up. The overlay
# that maps under the pressed button is told a wrong pointer position until the pointer moves (nested: GF-REF sits at
# x=1440, and the overlay saw x-1440, which here was the application title, whose hover switched the menu): the press
# moves 1 px before it lets go, as a real hand does.
hover() { vs_pointer abs "$(($1 - 5))" 12 sleep 200 abs "$1" 12 sleep 500 >/dev/null; }
press() { vs_pointer abs "$(($1 - 5))" 12 sleep 200 abs "$1" 12 sleep 300 down sleep 300 abs "$(($1 + 1))" 12 sleep 300 up >/dev/null; }
names() { state | jq -r '[.status[].name] | join("|")'; }

icons=$VS_STATE/tray-icons
mkdir -p "$icons"
magick -size 64x64 xc:none -fill '#e5484d' -draw 'circle 32,32 32,4' "$icons/red.png"
magick -size 64x64 xc:none -fill '#3b82f6' -draw 'roundrectangle 6,6 58,58 12,12' "$icons/blue.png"
magick -size 64x64 xc:none -fill '#22c55e' -draw 'polygon 32,4 60,56 4,56' "$icons/green.png"
magick -size 300x300 gradient:'#ff7e5f'-'#6a11cb' "$icons/art.png"
rm -f "$VS_STATE"/mbs-*.log "$VS_STATE"/mbs-*.ctl

vs_session >/dev/null
vs_reset >/dev/null
bus=$(<"$VS_DEV/bus.address")

fixture() { # LOGNAME script args...: a test client on the private bus only (GF_TEST_BUS refuses any other)
  local name=$1
  shift
  "$VS_ROOT/scripts/dev/isolated.sh" --name mbs -- env DBUS_SESSION_BUS_ADDRESS="$bus" GF_TEST_BUS=1 python3 -I "$@" --log "$VS_STATE/mbs-$name.log" >/dev/null 2>&1 </dev/null &
  printf "%s %s\n" "$!" "$(dev_start_time "$!" || echo none)" >> "$VS_STATE/mbs-pids"
}
restyle() { # appearance: vs_reset without killing the fixtures (they are tracked in mbs-pids, not in the clients' pids)
  vs_ipc menubar close >/dev/null || true
  vs_ipc search close >/dev/null || true
  vs_ipc controlcenter appearance "$1" >/dev/null
  vs_ipc controlcenter transparency 0.25 >/dev/null
  vs_ipc controlcenter reduceMotion true >/dev/null
  vs_park
}
stop_fixtures() { # only a process whose start time still matches the record, never a compositor (scripts/dev/pidfile.sh)
  local p s
  [[ -f $VS_STATE/mbs-pids ]] || return 0
  while read -r p s; do
    [[ $p =~ ^[0-9]+$ && $s =~ ^[0-9]+$ ]] || continue
    [[ $(dev_start_time "$p") == "$s" ]] || continue
    dev_may_signal "$p" && kill "$p" 2>/dev/null || true
  done < "$VS_STATE/mbs-pids"
  : > "$VS_STATE/mbs-pids"
}
trap stop_fixtures EXIT
waitlog() { local i; for i in $(seq 1 40); do grep -q "$2" "$VS_STATE/mbs-$1.log" 2>/dev/null && return 0; sleep 0.25; done; return 1; }

# The bar lists tray items by id (a-first, b-second, c-third): C (no menu), A, then B, which sits where the
# overlay's pointer glitch (see press) lands on no title.
fixture c "$VS_ROOT/tests/fixtures/status-item.py" --id a-first --title "Item C" --icon "$icons/green.png" --no-menu
waitlog c registered || echo "WARN: item c did not register"
vs_sleep 1
fixture a "$VS_ROOT/tests/fixtures/status-item.py" --id b-second --title "Item A" --icon "$icons/red.png"
waitlog a registered || echo "WARN: item a did not register"
vs_sleep 1
fixture b "$VS_ROOT/tests/fixtures/status-item.py" --id c-third --title "Item B" --only-menu --icon "$icons/blue.png"
waitlog b registered || echo "WARN: item b did not register"
vs_sleep 1
fixture p "$VS_ROOT/tests/fixtures/mpris-player.py" --art "$icons/art.png" --control "$VS_STATE/mbs-p.ctl"
waitlog p ready || echo "WARN: the test player did not start"
vs_sleep 2.5

shoot() { # name: capture and crop the bar's right part and what hangs under it
  vs_capture "$1" >/dev/null
  magick "$VS_SHOTS/$1.$VS_LANG.png" -crop 640x330+1280+0 +repage "$VS_SHOTS/$1.$VS_LANG.png"
}

for ap in dark light; do
  restyle "$ap"
  vs_ipc menubar close >/dev/null
  vs_sleep 0.5
  echo "-- $ap: $(names)"
  if [[ $ap == dark ]]; then
    n=$(names)
    check "order: Item C, Item A, Item B, Now Playing, Network, Volume, Search, Quick Settings, clock" \
      bash -c '[[ "$1" == "Item C|Item A|Item B|Now Playing: Test Song|Network:"*"|Volume:"*"|Search|Quick Settings|Date and time:"* ]]' _ "$n"
    check "no status item overlaps the menus" bash -c 'echo "$1" | jq -e ".menusRight <= (.status[0].x)" >/dev/null' _ "$(state)"
  fi
  shoot "mbs-$ap-rest"

  bx=$(x_of "Item B")
  ax=$(x_of "Item A")
  cx=$(x_of "Item C")
  press "$bx"
  vs_sleep 0.8
  check "tray-menu ($ap): ItemIsMenu opens its menu on press" is_kind tray
  shoot "mbs-$ap-traymenu"
  hover "$ax"
  check "tray-hover ($ap): moving onto Item A switches to its menu" bash -c 'grep -q "abouttoshow" "$1"' _ "$VS_STATE/mbs-a.log"
  is_kind tray && echo "PASS: tray-hover ($ap): menu still open on Item A" || { echo "FAIL: tray-hover ($ap)"; fail=1; }
  press "$cx"
  vs_sleep 0.6
  check "tray-activate ($ap): Item C gets Activate and no menu stays open" bash -c 'grep -q "^activate" "$1"' _ "$VS_STATE/mbs-c.log"
  closed || { echo "FAIL: menu still open after Activate"; fail=1; }

  vs_park
  vs_ipc menubar open nowplaying "$VS_OUTPUT" >/dev/null
  vs_sleep 1
  check "nowplaying ($ap): popover open" is_kind nowplaying
  shoot "mbs-$ap-nowplaying"
  if [[ $ap == dark ]]; then
    # The pause button is the middle of the popover's transport row: 49 px left of the item's centre, 142 px down.
    px=$(x_of "Now Playing: Test Song")
    vs_pointer abs "$((px - 55))" 142 sleep 300 abs "$((px - 49))" 142 sleep 300 down sleep 200 up >/dev/null
    vs_sleep 0.8
    check "nowplaying: the popover's pause button reaches the player" bash -c 'grep -qx "pause" "$1"' _ "$VS_STATE/mbs-p.log"
  fi
  vs_ipc menubar close >/dev/null
  vs_sleep 0.4

  sx=$(x_of "Search")
  press "$sx"
  vs_sleep 1.2
  check "search ($ap): the Search item opens Search" bash -c '[[ "$1" == *"open\":true"* || "$1" == *"\"open\": true"* ]]' _ "$(vs_ipc search status)"
  vs_capture "mbs-$ap-search" >/dev/null
  vs_ipc search close >/dev/null
  vs_sleep 0.6
done

# Crowding, part way: a long name that leaves room for some of the optional items hides the leftmost ones only.
restyle dark
partial=$(printf 'verylongapplicationname%.0s' $(seq 1 9))
vs_spawn foot -c "$VS_HERE/fixtures/foot.ini" -a "$partial" -T mbs-partial --window-size-chars 40x10 sh -c "exec sleep 100000"
vs_wait_clients 1 >/dev/null || true
vs_sleep 2
n=$(names)
echo "-- part way: $n"
check "crowding (part way): Item C (leftmost) is hidden, Search (rightmost optional) stays" bash -c '[[ "$1" != *"Item C"* && "$1" == *"Search"* ]]' _ "$n"
check "crowding (part way): no status item overlaps the menus" bash -c 'echo "$1" | jq -e ".menusRight <= (.status[0].x)" >/dev/null' _ "$(state)"
vs_capture mbs-dark-partial >/dev/null
magick "$VS_SHOTS/mbs-dark-partial.$VS_LANG.png" -crop 1920x40+0+0 +repage "$VS_SHOTS/mbs-dark-partial.$VS_LANG.png"
vs_kill_clients

# Crowding: a very long application name takes the bar's width.
restyle dark
long=$(printf 'verylongapplicationname%.0s' $(seq 1 12))
vs_spawn foot -c "$VS_HERE/fixtures/foot.ini" -a "$long" -T mbs-long --window-size-chars 40x10 sh -c "exec sleep 100000"
vs_wait_clients 1 >/dev/null || true
vs_sleep 2
n=$(names)
echo "-- crowded: $n"
check "crowding: Item A is hidden first (leftmost optional)" bash -c '[[ "$1" != *"Item A"* ]]' _ "$n"
check "crowding: Quick Settings and the clock stay" bash -c '[[ "$1" == *"Quick Settings|Date and time:"* ]]' _ "$n"
check "crowding: no status item overlaps the menus" bash -c 'echo "$1" | jq -e ".menusRight <= (.status[0].x)" >/dev/null' _ "$(state)"
vs_capture mbs-dark-crowded >/dev/null
magick "$VS_SHOTS/mbs-dark-crowded.$VS_LANG.png" -crop 1920x40+0+0 +repage "$VS_SHOTS/mbs-dark-crowded.$VS_LANG.png"
vs_reset dark 0.25
n=$(names)
check "crowding: the items return when the app is gone" bash -c '[[ "$1" == *"Item A"* ]]' _ "$n"

exit $fail
