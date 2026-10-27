#!/usr/bin/env bash
# The generated GTK themes rendered (ADR-0035 D-8, ui/tools/gen-gtk-themes.py): tests/fixtures/gtk-specimen.py shows every
# place GTK's built-in theme draws its accent (a suggested button, a checked box and radio, a switch, a slider, progress and
# level bars, a focused field with selected text, a selected row, tabs, a link) in GTK 3 and GTK 4, on a scratch Xvfb
# display, once with each of GTK's own stylesheets (light, dark, high contrast, high contrast dark: the controls) and once
# with each of the 36 Grassfield themes (GTK_THEME, themes in a scratch XDG_DATA_DIRS). From each screenshot's colour
# histogram:
#  * each of GTK's own stylesheets shows its blue accent: the measure sees it;
#  * every Grassfield theme shows none of it, and shows its selection, accent and link colours;
#  * GTK reports no error in any stylesheet.
# Needs Xvfb, ImageMagick (magick or import + convert), python3 with PyGObject and GTK 3 / GTK 4 introspection data; each
# missing piece is a SKIP. xdotool, when present, gives the window the keyboard (focused-field and backdrop-free colours).
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/gtk-themes.XXXXXX")
xvfb_pid=""
stop_all() { [[ -n $xvfb_pid ]] && kill "$xvfb_pid" 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"; }
trap stop_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
wait_until() { local n=$(($1 * 10)); shift; while ((n-- > 0)); do "$@" && return 0; sleep 0.1; done; return 1; }

for tool in Xvfb python3; do
  command -v "$tool" >/dev/null || { echo "SKIP: gtk_themes needs $tool"; exit 0; }
done
if command -v magick >/dev/null; then shot() { magick import -window root "$1"; }; histogram() { magick "$1" -format %c histogram:info:-; }
elif command -v import >/dev/null && command -v convert >/dev/null; then shot() { import -window root "$1"; }; histogram() { convert "$1" -format %c histogram:info:-; }
else echo "SKIP: gtk_themes needs ImageMagick"; exit 0; fi
versions=()
for v in 3 4; do
  python3 -I -c "import gi; gi.require_version('Gtk', '$v.0'); from gi.repository import Gtk" 2>/dev/null && versions+=("$v") \
    || echo "SKIP: gtk_themes: no GTK $v introspection data (GTK $v not checked)"
done
((${#versions[@]})) || exit 0

mkdir -p "$tmp/share/themes" "$tmp/run" "$tmp/shots"
chmod 700 "$tmp/run"
python3 -I "$root/ui/tools/gen-gtk-themes.py" "$tmp/share/themes" >/dev/null || { echo "FAIL: the themes are generated"; exit 1; }
mapfile -t themes < <(python3 -I "$root/ui/tools/gen-gtk-themes.py" --list)
# The controls: GTK's own stylesheets as themes of their own (the light one is GTK's default, no theme set).
control() { # control <name> <GTK 3 resource> <GTK 4 resource>
  mkdir -p "$tmp/share/themes/$1/gtk-3.0" "$tmp/share/themes/$1/gtk-4.0"
  printf '@import url("resource:///org/gtk/libgtk/theme/%s");\n' "$2" >"$tmp/share/themes/$1/gtk-3.0/gtk.css"
  printf '@import url("resource:///org/gtk/libgtk/theme/%s");\n' "$3" >"$tmp/share/themes/$1/gtk-4.0/gtk.css"
}
control GtkOwn-dark Adwaita/gtk-contained-dark.css Default/Default-dark.css
control GtkOwn-hc HighContrast/gtk-contained.css Default/Default-hc.css
control GtkOwn-hc-dark HighContrast/gtk-contained-inverse.css Default/Default-hc-dark.css

exec 5>"$tmp/display"
Xvfb -displayfd 5 -screen 0 480x780x24 -nolisten tcp >"$tmp/xvfb.log" 2>&1 &
xvfb_pid=$!
wait_until 5 test -s "$tmp/display" || { echo "FAIL: Xvfb starts [$(head -n 1 "$tmp/xvfb.log")]"; exit 1; }
display=:$(head -n 1 "$tmp/display")

render() { # render <gtk version> <theme or stock> <png>: the specimen, focused when xdotool can, then the screen
  local log theme=()
  log=$tmp/shots/$(basename "$3" .png).log
  [[ $2 != stock ]] && theme=(GTK_THEME="$2")
  env -i PATH="$PATH" HOME="$tmp" DISPLAY="$display" GDK_BACKEND=x11 GSK_RENDERER=cairo LIBGL_ALWAYS_SOFTWARE=1 NO_AT_BRIDGE=1 \
    XDG_DATA_DIRS="$tmp/share:/usr/share" XDG_RUNTIME_DIR="$tmp/run" "${theme[@]}" \
    python3 -I "$root/tests/fixtures/gtk-specimen.py" "$1" 6 >"$log" 2>&1 &
  local app=$!
  wait_until 5 grep -q READY "$log"
  if command -v xdotool >/dev/null; then
    local wid
    wid=$(DISPLAY=$display xdotool search --name gtk-specimen 2>/dev/null | head -n 1)
    [[ -n $wid ]] && DISPLAY=$display xdotool windowfocus "$wid" 2>/dev/null
  fi
  sleep 1.2
  DISPLAY=$display shot "$3"
  kill "$app" 2>/dev/null; wait "$app" 2>/dev/null
}
# count <png> <#rrggbb>... : pixels within a small distance of any of the colours
count() {
  local png=$1
  shift
  histogram "$png" | python3 -I -c '
import re, sys
targets = [tuple(int(h[i:i + 2], 16) for i in (1, 3, 5)) for h in sys.argv[1:]]
total = 0
for line in sys.stdin:
    m = re.match(r"\s*(\d+):\s*\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)", line)
    if not m:
        continue
    n = int(m.group(1))
    c = tuple(float(m.group(i)) for i in (2, 3, 4))
    if any(sum((a - b) ** 2 for a, b in zip(c, t)) ** 0.5 <= 4 for t in targets):
        total += n
print(total)' "$@"
}
palette() { # palette <theme>: "selection accent link" of the generator
  python3 -I -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("g", sys.argv[1]); g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
name = sys.argv[2][len("Grassfield-"):]
dark = name.endswith("-dark")
p = g.palette(g.load(), name.removesuffix("-dark").removesuffix("-hc"), dark)
print(p["selection"], p["accent"], p["link"])' "$root/ui/tools/gen-gtk-themes.py" "$1"
}
# GTK's own accent family: GTK 3's Adwaita and HighContrast, GTK 4's Default and Default-hc (the fills, their borders,
# gradients and shades).
gtk_blue=("#3584e4" "#1b6acb" "#15539e" "#2c7fe3" "#4b92e7" "#185fb4" "#1c71d8" "#62a0ea" "#0f3b71" "#194b87" "#1a66c2")

for v in "${versions[@]}"; do
  for own in stock GtkOwn-dark GtkOwn-hc GtkOwn-hc-dark; do
    render "$v" "$own" "$tmp/shots/gtk$v-$own.png"
    own_blue=$(count "$tmp/shots/gtk$v-$own.png" "${gtk_blue[@]}")
    desc="GTK $v, GTK's own stylesheet $own (control): the measure sees its blue accent [$own_blue px]"
    check test "$own_blue" -gt 500
  done
  leftovers=() missing=() errors=()
  for theme in "${themes[@]}"; do
    png=$tmp/shots/gtk$v-$theme.png
    render "$v" "$theme" "$png"
    grep -qiE "parsing error|parser error" "$tmp/shots/gtk$v-$theme.log" && errors+=("$theme")
    read -r selection accent link < <(palette "$theme")
    blue=$(count "$png" "${gtk_blue[@]}")
    ((blue > 20)) && leftovers+=("$theme:$blue")
    sel=$(count "$png" "$selection")
    acc=$(count "$png" "$accent")
    lnk=$(count "$png" "$link")
    ((sel < 300 || acc < 100 || lnk < 15)) && missing+=("$theme:sel=$sel,accent=$acc,link=$lnk")
  done
  desc="GTK $v: no Grassfield theme shows GTK's blue accent [${leftovers[*]:-none}]"
  check test ${#leftovers[@]} -eq 0
  desc="GTK $v: every Grassfield theme shows its selection, accent and link colours [${missing[*]:-all}]"
  check test ${#missing[@]} -eq 0
  desc="GTK $v: no stylesheet error [${errors[*]:-none}]"
  check test ${#errors[@]} -eq 0
done
[[ -n ${GTK_THEMES_KEEP:-} ]] && cp -r "$tmp/shots" "$GTK_THEMES_KEEP"
exit "$fail"
