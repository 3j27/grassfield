#!/usr/bin/env bash
# Settings > Wallpaper in French (ADR-0016): the pane with a picture chosen, to read the French strings and check that none
# is clipped. Pictures are generated under .dev/wallpapers-e2e (shared with wallpaper.sh).
# Usage (bare command): tests/visual/wallpaper-fr.sh      Capture: $VS_SHOTS/wallpaper-fr-*.fr.png
export VISUAL_LANG=fr
source "$(dirname "$0")/lib.sh"

pics=$VS_DEV/wallpapers-e2e
mkdir -p "$pics"
gen() { [[ -f $pics/$1 ]] || ffmpeg -loglevel error -y -f lavfi -i "$2" -frames:v 1 -q:v 3 "$pics/$1"; }
gen a.jpg "gradients=s=1920x1080:seed=3:n=4:speed=0"
gen b.jpg "mandelbrot=size=1920x1080"
gen c.jpg "testsrc2=size=1920x1080"
export GRASSFIELD_PICTURES_DIR=$pics

vs_session fr
vs_reset
vs_spawn "$VS_DEV/build/grassfield-settings" --section=wallpaper
vs_wait_clients 1
vs_sleep 3
vs_pointer abs 897 688 sleep 300 click >/dev/null
vs_sleep 4
vs_capture wallpaper-fr-picture
# The folder case: the options that apply to it (interval, shuffle) are in the pane.
cfg=$VS_DEV/config/grassfield.json
jq --arg p "$pics" '.wallpaper = {source: "folder", path: $p, fit: "fit", interval: "15m", shuffle: true}' "$cfg" > "$cfg.new" && mv "$cfg.new" "$cfg"
vs_sleep 5
vs_capture wallpaper-fr-folder
vs_kill_clients
