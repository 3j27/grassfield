#!/usr/bin/env bash
# F2c fidelity captures (not a regression scenario: no baselines). Run as a BARE command.
#   tests/visual/f2c.sh banners TAG    light/dark x transparency 0.25/0.6 -> .dev/f2c/banners-TAG-<appearance>-<tr>.png
#   tests/visual/f2c.sh search TAG     query, filter chips and empty state, light and dark -> .dev/f2c/search-TAG-*.png
#   tests/visual/f2c.sh overview TAG   four windows, light and dark -> .dev/f2c/overview-TAG-*.png
#   tests/visual/f2c.sh alerts TAG     alert (Force Quit-free confirm) and sheet -> .dev/f2c/alerts-TAG-*.png
# Output goes to .dev/f2c/ only.
source "$(dirname "$0")/lib.sh"
surface=${1:?surface}
tag=${2:?tag}
out=$VS_ROOT/.dev/f2c
mkdir -p "$out"

# shot NAME: capture the current state into .dev/f2c/NAME.png
shot() {
  VS_SHOTS=$out VS_LANG="$1" VS_SETTLE=${VS_SETTLE:-1} vs_capture f2c >/dev/null
  mv "$out/f2c.$1.png" "$out/$1.png"
}

vs_session
bus=$(<"$VS_DEV/bus.address")
case $surface in
  banners)
    for ap in light dark; do
      for tr in 0.25 0.6; do
        vs_reset "$ap" "$tr"
        vs_ipc notifications clearAll >/dev/null
        DBUS_SESSION_BUS_ADDRESS=$bus notify-send -a "Mail" -t 24000 "Anna Martin" "Are we still on for lunch tomorrow? I booked the table near the window for noon and can move it if needed."
        DBUS_SESSION_BUS_ADDRESS=$bus notify-send -a "Calendar" -t 24000 -A "open=Open" -A "snooze=Snooze" "Design review" "Starts in 10 minutes in Room 4." &
        vs_sleep 3
        shot "banners-$tag-$ap-$tr"
        vs_ipc notifications clearAll >/dev/null
      done
    done ;;
  search)
    for ap in light dark; do
      vs_reset "$ap" 0.25
      vs_ipc search open files >/dev/null
      vs_sleep 2
      shot "search-$tag-$ap-results"
      vs_ipc search close >/dev/null
      vs_ipc search open "e" >/dev/null
      vs_sleep 2
      shot "search-$tag-$ap-chips"
      # Keyboard: Tab through the groups until the ring reaches the chips, then Right to the second chip.
      for try in 1 2 3 4 5 6; do
        [[ $(vs_ipc search status) == *'"zone":"chips"'* ]] && break
        "$VS_ROOT/scripts/dev/keys.sh" -k Tab >/dev/null
        vs_sleep 0.5
      done
      "$VS_ROOT/scripts/dev/keys.sh" -k Right >/dev/null
      vs_sleep 1
      shot "search-$tag-$ap-chipfocus"
      "$VS_ROOT/scripts/dev/keys.sh" -k space >/dev/null
      vs_sleep 1
      shot "search-$tag-$ap-chipspace"
      vs_ipc search close >/dev/null
      vs_ipc search open zzqqxx >/dev/null
      vs_sleep 2.5
      shot "search-$tag-$ap-noresults"
      vs_ipc search close >/dev/null
      vs_ipc search open "" >/dev/null
      vs_sleep 1.5
      shot "search-$tag-$ap-empty"
      vs_ipc search close >/dev/null
    done ;;
  overview)
    for ap in light dark; do
      vs_reset "$ap" 0.25
      vs_foot 'Terminal 1' 50x12
      vs_wait_clients 1
      vs_foot 'Terminal 2' 60x16
      vs_wait_clients 2
      vs_ipc overview open >/dev/null
      VS_SETTLE=2 shot "overview-$tag-$ap"
      vs_ipc overview close >/dev/null
    done ;;
  alerts)
    for ap in dark light; do
      vs_reset "$ap" 0.25
      vs_ipc search open restart >/dev/null
      vs_sleep 4
      "$VS_ROOT/scripts/dev/keys.sh" -k Return >/dev/null
      vs_sleep 4
      shot "alerts-$tag-$ap-confirm"
      "$VS_ROOT/scripts/dev/keys.sh" -k Escape >/dev/null
      vs_ipc menubar close >/dev/null
      vs_ipc menubar panel forcequit GF-REF >/dev/null
      vs_sleep 4
      shot "alerts-$tag-$ap-forcequit"
      vs_ipc menubar close >/dev/null
      vs_ipc menubar panel about GF-REF >/dev/null
      vs_sleep 4
      shot "alerts-$tag-$ap-about"
      vs_ipc menubar close >/dev/null
    done ;;
  gallery)
    for ap in light dark; do
      vs_reset "$ap" 0.25
      vs_ipc notifications clearAll >/dev/null
      vs_notify
      vs_sleep 2
      for try in 1 2 3 4; do
        [[ $(vs_ipc notifications status) == *center=true* ]] && break
        vs_pointer abs 1850 12 sleep 300 click >/dev/null
        vs_sleep 3
      done
      shot "gallery-$tag-$ap-center"
      vs_pointer abs ${F2C_PILL:-1715 742} sleep 300 click >/dev/null
      vs_sleep 2
      shot "gallery-$tag-$ap-gallery"
      vs_ipc notifications clearAll >/dev/null
    done ;;
  *) echo "f2c: unknown surface $surface" >&2; exit 2 ;;
esac
