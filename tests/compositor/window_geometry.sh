# Real window geometry for the compositor scenarios (sourced by them; not a scenario itself). GF-006: the soak and the
# input test used to aim at a fixed titlebar position (y = 250) that no window has any more; they now read each
# window's rectangle from `hyprctl -j clients` and aim at ITS titlebar.
#
# Needs (set by the caller before use): root, sig (nested instance signature), out (output name); and
# titlebar_geometry.sh sourced (GF_TB_* metrics from Theme.hpp). Read-only hyprctl queries only.
# Coordinates are logical px relative to the output's top-left corner (what scripts/dev/pointer.sh `output <name> abs`
# takes). The rectangle is the surface box: the titlebar spans [y - GF_TB_HEIGHT, y) above it.
#
#   gf_geom_init                    reads the output's id and origin (GF_OUT_ID GF_OUT_X GF_OUT_Y); fails when not found
#   gf_geom_filter <pid> <id> <ox> <oy>   stdin: `hyprctl -j clients`; prints "x y w h" of that client's mapped, visible
#                                   window on that output, nothing when there is none (pure; tested offline)
#   gf_window_geom <pid> [wait_ms]  polls until the window of <pid> is mapped (default 3000 ms); prints "x y w h"
#   gf_window_gone <pid> [wait_ms]  true once no mapped window of <pid> exists any more (default 2000 ms)
#   gf_bar_point <x> <y> <w> <h>    prints "x y" of the titlebar's middle (grab point of a drag, double-click target)
#   gf_button_point <kind> <x> <y> <w> <h>   kind close|min|zoom: prints "x y" of that button's centre

gf_geom_init() {
  GF_OUT_ID="" GF_OUT_X="" GF_OUT_Y=""
  read -r GF_OUT_ID GF_OUT_X GF_OUT_Y < <(HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j monitors 2>/dev/null \
    | jq -r --arg o "$out" '.[] | select(.name == $o) | "\(.id) \(.x) \(.y)"')
  [[ -n $GF_OUT_ID && -n $GF_OUT_X && -n $GF_OUT_Y ]]
}

gf_geom_filter() { # <pid> <output id> <output x> <output y>
  jq -r --argjson p "$1" --argjson m "$2" --argjson ox "$3" --argjson oy "$4" '
    [.[] | select(.pid == $p and .mapped == true and .hidden != true and .monitor == $m
                  and ((.workspace.name // "") | startswith("special:") | not))][0]
    | select(. != null) | "\(.at[0] - $ox) \(.at[1] - $oy) \(.size[0]) \(.size[1])"'
}

gf_window_geom() { # <pid> [wait_ms]
  local deadline=$(($(date +%s%3N) + ${2:-3000})) g
  while :; do
    g=$(HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j clients 2>/dev/null | gf_geom_filter "$1" "$GF_OUT_ID" "$GF_OUT_X" "$GF_OUT_Y")
    [[ -n $g ]] && { echo "$g"; return 0; }
    (($(date +%s%3N) > deadline)) && return 1
    sleep 0.05
  done
}

gf_window_gone() { # <pid> [wait_ms]
  local deadline=$(($(date +%s%3N) + ${2:-2000}))
  while :; do
    HYPRLAND_INSTANCE_SIGNATURE=$sig timeout 5 hyprctl -j clients 2>/dev/null \
      | jq -e --argjson p "$1" '[.[] | select(.pid == $p and .mapped == true)] | length == 0' >/dev/null 2>&1 && return 0
    (($(date +%s%3N) > deadline)) && return 1
    sleep 0.05
  done
}

gf_geom_moved() { # <"x y w h"> <"x y w h">: true when origin and size differ by 20 px or more in sum (moved or resized)
  awk -v a="$1" -v b="$2" 'BEGIN { split(a, p, " "); split(b, q, " "); d = 0; for (i = 1; i <= 4; i++) { v = p[i] - q[i]; d += (v < 0 ? -v : v) } exit !(d >= 20) }'
}

gf_bar_point() { # <x> <y> <w> <h>
  echo "$(($1 + $3 / 2)) $(($2 - GF_TB_MID))"
}

gf_button_point() { # <close|min|zoom> <x> <y> <w> <h>
  local dx
  case $1 in
    close) dx=$GF_TB_CLOSE_X ;;
    min) dx=$GF_TB_MIN_X ;;
    zoom) dx=$GF_TB_ZOOM_X ;;
    *) return 2 ;;
  esac
  echo "$(($2 + dx)) $(($3 - GF_TB_MID))"
}
