#!/usr/bin/env bash
# Dock folder stacks and shrink to fit (docs/specs/dock.md requirements 24 and 25), on the nested session:
#   stack    a fixture folder kept in the Dock's right section (dock.folders) is a tile left of the Trash; a click opens its stack
#            (popup kind dockstack) as Fan, Grid or List per dock.stackOptions; the items come in the order of the chosen sort
#            (Name, Date Added, Date Modified, Kind) and hidden files never show; Esc closes it. Captures of the three views.
#   fit      with dock.size 96 and 24 running apps with distinct ids the tiles shrink so that the shelf fits the output
#            (`dock fitsize` below `dock sizenow`), and grow back to the setting when the apps are gone.
#   drop     a folder dragged (a real GTK4 drag, tests/visual/fixtures/dragsrc.py, as dock-drops.sh) onto the Dock right of the
#            divider is added to dock.folders and gets a tile; a file dragged there is not added; `dock addfolder` puts a folder at a
#            slot (insertion order); Settings keeps the key.
# Run as a BARE command with a relative path, on the reference machine only; the nested session it starts is torn down on exit.
#   tests/visual/dock-stacks.sh [stack|fit|drop]     (default: all three)
# Captures: .dev/visual/dock-stacks/. Exit status 1 when a check fails.
source "$(dirname "$0")/lib.sh"
set +e

part=${1:-all}
want() { [[ $part == all || $part == "$1" ]]; }
out=$VS_STATE/dock-stacks
was_running=0
vs_nested_running && was_running=1
cleanup() {
  vs_nested_running && { vs_ipc overview close >/dev/null 2>&1 || true; vs_kill_clients || true; }
  (( was_running )) || "$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p "$out"
rm -f "$out"/*

fail=0
check() { if [[ $2 -eq 0 ]]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
cfg=$VS_DEV/config/grassfield/grassfield.json
setting() { # <jq filter assigning the value>
  local tmp
  mkdir -p "$(dirname "$cfg")"
  [[ -s $cfg ]] || echo '{}' >"$cfg"
  tmp=$(mktemp "$cfg.XXXXXX") && jq "$1" "$cfg" >"$tmp" && mv "$tmp" "$cfg"
  sleep 1.2
}
tile_index() { vs_ipc dock tiles | jq -r --arg k "$1" 'index($k)'; }
popup() { vs_ipc dock popup; }
state() { vs_ipc dockstack state; }

vs_session en
vs_reset dark 0.25
vs_ipc dock magnify 1.6 false >/dev/null
vs_ipc dock autohide false >/dev/null
vs_ipc dock position bottom >/dev/null
vs_ipc dock size 48 >/dev/null

if want stack; then
  fix=$VS_DEV/stackfix
  rm -rf "$fix"
  mkdir -p "$fix/Sub"
  : >"$fix/.hidden"
  printf 'x' >"$fix/Sub/inner.txt"
  printf 'a' >"$fix/beta.txt"; touch -d '2026-01-03' "$fix/beta.txt"
  printf 'a' >"$fix/alpha.png.txt"; touch -d '2026-01-05' "$fix/alpha.png.txt"
  printf 'a' >"$fix/gamma.md"; touch -d '2026-01-01' "$fix/gamma.md"
  magick -size 64x64 xc:orange "$fix/photo.png" 2>/dev/null && touch -d '2026-01-04' "$fix/photo.png"
  setting ".dock.folders = [\"$fix\"] | .dock.stackOptions = {}"
  idx=$(tile_index "$fix")
  [[ $idx != null && -n $idx ]]; check "the folder is a tile of the Dock (index $idx)" $?
  tiles=$(vs_ipc dock tiles)
  [[ $(jq -r --arg k "$fix" 'index($k) < index("trash")' <<<"$tiles") == true ]]; check "the folder tile is left of the Trash" $?
  [[ $(jq -r --arg k "$fix" 'index("separator") // index(null) | . != null' <<<"$tiles") == true ]]; check "a divider sits before the folder section" $?

  for v in fan grid list; do
    setting ".dock.stackOptions = {\"$fix\": {\"view\": \"$v\"}}"
    vs_ipc dock stack "$idx" "$VS_OUTPUT" >/dev/null
    sleep 1.5
    [[ $(popup) == dockstack ]]; check "$v: a click on the tile opens the stack" $?
    s=$(state)
    [[ ${s%%|*} == "$v" ]]; check "$v: the stack shows as $v (state $s)" $?
    [[ ${s#*|} != *hidden* ]]; check "$v: hidden files are not listed" $?
    VS_SETTLE=1 vs_capture "dock-stack-$v" >/dev/null
    cp "$VS_SHOTS/dock-stack-$v.en.png" "$out/$v.png" 2>/dev/null
    "$VS_ROOT/scripts/dev/keys.sh" -k Escape >/dev/null 2>&1
    sleep 0.8
    [[ -z $(popup) ]]; check "$v: Esc closes the stack" $?
  done

  # A folder of a Grid or a List opens in place, with a back control (macOS Grid view); a Fan opens it in Files (not tested here).
  for v in grid list; do
    setting ".dock.stackOptions = {\"$fix\": {\"view\": \"$v\", \"sort\": \"name\"}}"
    vs_ipc dock stack "$idx" "$VS_OUTPUT" >/dev/null
    sleep 1.2
    [[ $(vs_ipc dockstack enter Sub) == ok ]]; check "$v: a folder item opens in place" $?
    sleep 1
    [[ $(vs_ipc dockstack depth) == 1 ]]; check "$v: the stack is one folder deep" $?
    [[ $(state) == "$v|inner.txt" ]]; check "$v: the sub-folder's items are listed (state $(state))" $?
    VS_SETTLE=1 vs_capture "dock-stack-$v-nested" >/dev/null
    cp "$VS_SHOTS/dock-stack-$v-nested.en.png" "$out/$v-nested.png" 2>/dev/null
    vs_ipc dockstack back >/dev/null
    sleep 1
    [[ $(vs_ipc dockstack depth) == 0 && $(state) == *Sub* ]]; check "$v: back returns to the stack's own items" $?
    "$VS_ROOT/scripts/dev/keys.sh" -k Escape >/dev/null 2>&1
    sleep 0.6
  done

  for sort in name dateAdded dateModified kind; do
    setting ".dock.stackOptions = {\"$fix\": {\"view\": \"list\", \"sort\": \"$sort\"}}"
    vs_ipc dock stack "$idx" "$VS_OUTPUT" >/dev/null
    sleep 1.2
    s=$(state)
    names=${s#*|}
    case $sort in
      name) [[ $names == "alpha.png.txt,beta.txt,gamma.md,photo.png,Sub" ]]; check "sort by name: $names" $? ;;
      dateModified) [[ $names == alpha.png.txt,photo.png,beta.txt,gamma.md* || $names == Sub,alpha.png.txt,photo.png,beta.txt,gamma.md ]]; check "sort by date modified (newest first): $names" $? ;;
      kind) [[ $names == Sub,* ]]; check "sort by kind: folders first: $names" $? ;;
      dateAdded) [[ -n $names ]]; check "sort by date added lists the items: $names" $? ;;
    esac
    "$VS_ROOT/scripts/dev/keys.sh" -k Escape >/dev/null 2>&1
    sleep 0.6
  done
  setting ".dock.stackOptions = {} | .dock.folders = []"
  [[ $(tile_index "$fix") == null ]]; check "removing the folder from dock.folders removes its tile" $?
  rm -rf "$fix"
fi

if want drop; then
  box=$VS_DEV/dropfix
  rm -rf "$box"
  mkdir -p "$box/Photos" "$box/Docs"
  printf 'x' >"$box/note.txt"
  setting ".dock.folders = [] | .dock.stackOptions = {}"
  # The hook: slots of the insertion order.
  vs_ipc dock addfolder "$box/Docs" 0 >/dev/null
  sleep 1
  vs_ipc dock addfolder "$box/Photos" 0 >/dev/null
  sleep 1
  [[ $(jq -r --arg a "$box/Photos" --arg b "$box/Docs" '.dock.folders == [$a, $b]' "$cfg") == true ]]; check "addfolder at slot 0 puts the new folder first" $?
  setting ".dock.folders = []"
  # A real drag: the pointer is a virtual pointer on the nested compositor, the source a GTK4 window offering text/uri-list.
  sock=$(vs_nested_wayland)
  origin=$("$VS_ROOT/scripts/nestctl" monitors -j | jq -r --arg n "$VS_OUTPUT" '.[] | select(.name == $n) | "\(.x) \(.y)"')
  ox=${origin% *}
  oy=${origin#* }
  drag_onto_divider() { # NAME PATH: drag PATH from a source window to the divider of the Dock, release
    local name=$1 bus="" at i sx sy tx ty sidx wx wy ww wh
    [[ -f $VS_DEV/bus.address ]] && bus=$(<"$VS_DEV/bus.address")
    "$VS_ROOT/scripts/dev/isolated.sh" --name visual --config-home "$VS_DEV/config" --state-home "$VS_DEV/state" -- \
      env WAYLAND_DISPLAY="$sock" DBUS_SESSION_BUS_ADDRESS="${bus:-}" LC_ALL=en_US.UTF-8 GSK_RENDERER=cairo GDK_BACKEND=wayland \
      python3 -I "$VS_HERE/fixtures/dragsrc.py" 12 "$2" >/dev/null 2>"$out/$name.src.log" </dev/null &
    vs_track "$!"
    for i in $(seq 1 40); do
      at=$("$VS_ROOT/scripts/nestctl" clients -j | jq -r '.[] | select(.title == "gfdragsrc") | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"' | head -n 1)
      [[ -n $at ]] && break
      sleep 0.25
    done
    [[ -n $at ]] || { echo "FAIL $name: the drag source window did not appear"; fail=1; return; }
    read -r wx wy ww wh <<<"$at"
    sleep 2
    sidx=$(tile_index separator)
    read -r tx ty <<<"$(vs_ipc dock centre "$sidx" "$VS_OUTPUT")"
    tx=$((tx + 2))
    sx=$((wx - ox + ww / 2))
    sy=$((wy - oy + wh / 2))
    "$VS_ROOT/scripts/dev/pointer.sh" output "$VS_OUTPUT" abs "$sx" "$sy" sleep 200 down sleep 200 drag "$tx" "$ty" sleep 1500 up sleep 400 abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null &
    local ptr=$!
    sleep 1.3
    "$VS_ROOT/scripts/dev/shot.sh" "dock-stacks-$name" "$VS_OUTPUT" >/dev/null
    cp "$VS_DEV/shots/dock-stacks-$name.png" "$out/$name.png" 2>/dev/null
    wait "$ptr"
    sleep 1.5
    local pid
    for pid in $("$VS_ROOT/scripts/nestctl" clients -j | jq -r '.[] | select(.title == "gfdragsrc") | .pid'); do
      dev_may_signal "$pid" && kill "$pid" || true
    done
    sleep 1
  }
  drag_onto_divider folder-drop "$box/Photos"
  [[ $(jq -r --arg a "$box/Photos" '.dock.folders | index($a) != null' "$cfg") == true ]]; check "a folder dropped right of the divider is added to dock.folders" $?
  [[ $(tile_index "$box/Photos") != null ]]; check "and it is a tile of the Dock" $?
  drag_onto_divider file-drop "$box/note.txt"
  [[ $(jq -r '.dock.folders | length' "$cfg") == 1 ]]; check "a file dropped there is not added" $?
  setting ".dock.folders = []"
  rm -rf "$box"
fi

if want fit; then
  setting ".dock.folders = []"
  vs_ipc dock size 96 >/dev/null
  sleep 1
  [[ $(vs_ipc dock fitsize "$VS_OUTPUT") == 96 ]]; check "few apps: the tiles keep the setting (96)" $?
  for i in $(seq 1 24); do vs_spawn foot --app-id "gffit$i"; sleep 0.5; done
  sleep 4
  now=$(vs_ipc dock sizenow)
  fit=$(vs_ipc dock fitsize "$VS_OUTPUT")
  [[ -n $fit && $fit -lt $now ]]; check "24 apps: the tiles shrink below the setting ($fit < $now)" $?
  w=$("$VS_ROOT/scripts/nestctl" monitors -j | jq -r '[.[] | select(.name == "'"$VS_OUTPUT"'") | .width][0]')
  n=$(vs_ipc dock tiles | jq 'length')
  # shelf <= tiles * fit + gaps + padding (every tile counted as an icon, the separators are narrower: a stricter bound)
  shelf=$(( n * fit + (n - 1) * 4 + 20 ))
  [[ $shelf -le $w ]]; check "the shelf fits the output ($shelf <= $w px, $n tiles)" $?
  VS_SETTLE=1 vs_capture dock-fit >/dev/null
  cp "$VS_SHOTS/dock-fit.en.png" "$out/fit.png" 2>/dev/null
  vs_kill_clients
  sleep 4
  [[ $(vs_ipc dock fitsize "$VS_OUTPUT") == 96 ]]; check "the apps are gone: the tiles are back to 96" $?
  vs_ipc dock size 48 >/dev/null
fi
exit $fail
