# Titlebar geometry for the compositor scenarios (sourced by them; not a scenario itself).
# Read from the plugin's single source, compositor/src/core/Theme.hpp, so the scenarios follow every change of the
# titlebar metrics. Integers (rounded), in logical px relative to the window's surface box (`hyprctl clients` at/size):
#   GF_TB_HEIGHT   titlebar height: the bar spans [y - GF_TB_HEIGHT, y) above the surface
#   GF_TB_MID      bar middle, this far above the surface's top edge
#   GF_TB_CLOSE_X  close button centre, this far right of the surface's left edge (the bar starts at the surface's x)
#   GF_TB_MIN_X    minimize button centre
#   GF_TB_ZOOM_X   zoom button centre
# Usage: . "$root/tests/compositor/titlebar_geometry.sh" || exit 2   ($root: the repository root)

gf_tb_theme=${root:?titlebar_geometry.sh: set root first}/compositor/src/core/Theme.hpp
read -r GF_TB_HEIGHT GF_TB_MID GF_TB_CLOSE_X GF_TB_MIN_X GF_TB_ZOOM_X < <(awk '
  /inline constexpr double k(TitlebarHeight|ButtonDiameter|ButtonSpacing|ButtonInsetLeft) *=/ {
    name = $4; value = $6; sub(/;.*/, "", value); v[name] = value + 0; n++
  }
  END {
    if (n != 4 || v["kTitlebarHeight"] <= 0 || v["kButtonDiameter"] <= 0) exit 1
    h = v["kTitlebarHeight"]; d = v["kButtonDiameter"]; pitch = d + v["kButtonSpacing"]; c = v["kButtonInsetLeft"] + d / 2
    printf "%d %d %d %d %d\n", h + 0.5, h / 2 + 0.5, c + 0.5, c + pitch + 0.5, c + 2 * pitch + 0.5
  }' "$gf_tb_theme")
unset gf_tb_theme
[[ ${GF_TB_HEIGHT:-0} -gt 0 && ${GF_TB_ZOOM_X:-0} -gt 0 ]] || { echo "titlebar_geometry.sh: could not read the titlebar metrics from Theme.hpp" >&2; return 1; }
