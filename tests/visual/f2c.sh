#!/usr/bin/env bash
# F2c fidelity captures (not a regression scenario: no baselines). Run as a BARE command.
#   tests/visual/f2c.sh banners TAG    light/dark x transparency 0.25/0.6 -> .dev/f2c/banners-TAG-<appearance>-<tr>.png
#   tests/visual/f2c.sh search TAG     query, filter chips and empty state, light and dark -> .dev/f2c/search-TAG-*.png
#   tests/visual/f2c.sh overview TAG   four windows, light and dark -> .dev/f2c/overview-TAG-*.png
#   tests/visual/f2c.sh alerts TAG     alert (Force Quit-free confirm) and sheet -> .dev/f2c/alerts-TAG-*.png
#   tests/visual/f2c.sh gallery TAG    Notification Center and its widget gallery, light and dark -> .dev/f2c/gallery-TAG-*.png
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
    # The Center, and the gallery that opens on it, stay open between iterations (vs_reset does not close them): the dark run
    # used to start with the gallery already open, its click on the pill did nothing and "center" and "gallery" were the same
    # picture (audit 2026-10-25). Each iteration therefore starts, and ends, with the Center closed.
    close_center() {
      local try
      for try in 1 2 3 4 5; do
        [[ $(vs_ipc notifications status) == *center=true* ]] || return 0
        vs_ipc notifications toggleCenter >/dev/null
        vs_sleep 1.5
      done
      [[ $(vs_ipc notifications status) == *center=true* ]] || return 0
      echo "f2c gallery: the Notification Center did not close after 5 tries" >&2
      exit 1
    }
    # Differing pixels of the region where the gallery panel appears (GF-REF 1920x1080: x 30-410, y 400-1075), "ERR" when the
    # comparison could not be made. Elsewhere on the screen banners and clocks change by themselves.
    gallery_diff() {
      magick "$1" -crop 380x675+30+400 +repage "$out/.crop-a.png" 2>/dev/null && magick "$2" -crop 380x675+30+400 +repage "$out/.crop-b.png" 2>/dev/null ||
        { echo ERR; return 0; }
      vs_px_diff "$out/.crop-a.png" "$out/.crop-b.png"
    }
    for ap in light dark; do
      vs_reset "$ap" 0.25
      close_center
      vs_ipc notifications clearAll >/dev/null
      vs_notify
      vs_sleep 2
      for try in 1 2 3 4; do
        [[ $(vs_ipc notifications status) == *center=true* ]] && break
        vs_pointer abs 1850 12 sleep 300 click >/dev/null
        vs_sleep 3
      done
      [[ $(vs_ipc notifications status) == *center=true* ]] || { echo "f2c gallery: the Notification Center did not open ($ap)" >&2; exit 1; }
      shot "gallery-$tag-$ap-center"
      # The "Edit Widgets" pill sits under the last widget, so its row depends on how many notices the Center holds (a start-up
      # notice such as "Compositor extension not loaded" adds a row, 142 px lower): try each known row and keep the first
      # click that opens the gallery (its panel changes at least 5000 pixels of that region, the dark one differed by 28863 over the whole screen, measured). F2C_PILL overrides the first row. No
      # click opening it is a failure, never a "gallery" shot that is the Center again.
      opened=""
      for pill in "${F2C_PILL:-1715 742}" "1715 884" "1715 600"; do
        vs_pointer abs $pill sleep 300 click >/dev/null
        vs_sleep 2
        shot "gallery-$tag-$ap-gallery"
        changed=$(gallery_diff "$out/gallery-$tag-$ap-center.png" "$out/gallery-$tag-$ap-gallery.png")
        if [[ $changed =~ ^[0-9]+$ ]]; then
          if ((changed >= 5000)); then
            opened=$changed
            break
          fi
        else
          echo "f2c gallery: the shots cannot be compared ($changed)" >&2
          exit 1
        fi
      done
      [[ -n $opened ]] || { echo "f2c gallery: no click on the Edit Widgets pill opened the gallery ($ap): $changed px differ in its region" >&2; exit 1; }
      close_center
      vs_ipc notifications clearAll >/dev/null
    done ;;
  *) echo "f2c: unknown surface $surface" >&2; exit 2 ;;
esac
