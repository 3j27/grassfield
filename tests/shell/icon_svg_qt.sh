#!/usr/bin/env bash
# FINDINGS 4 (first real session): Qt's SVG renderer logged "Could not resolve property" for a composed upstream app icon on
# every load. This runs Qt's own parser (tests/tools/svgcheck.cpp) over every composed apps/places icon and fails on any
# warning, so the class cannot return silently. Theme: $GRASSFIELD_ICON_THEME_DIR, else .dev/share/icons/grassfield-icons
# (scripts/dev/icons.sh); the sweep is skipped when none exists. Qt6Svg and g++ are needed, else the whole test is skipped.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/svgqt.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
theme=${GRASSFIELD_ICON_THEME_DIR:-}
if [[ -z $theme && -d $root/.dev/share/icons/grassfield-icons/base/apps ]]; then theme=$root/.dev/share/icons/grassfield-icons; fi
if ! command -v g++ >/dev/null || ! pkg-config --exists Qt6Svg Qt6Gui; then
  echo "SKIP: icon SVGs under Qt (g++ or Qt6Svg missing)"
  exit 0
fi
g++ -std=c++17 -fPIC -o "$tmp/svgcheck" "$root/tests/tools/svgcheck.cpp" $(pkg-config --cflags --libs Qt6Svg Qt6Gui Qt6Core)
export QT_QPA_PLATFORMTHEME=
export QT_QPA_PLATFORM=offscreen

# The checker itself: a construct Qt cannot resolve is reported, a plain icon is not (fixtures written here).
printf '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8" fill="#000"/></svg>\n' >"$tmp/good.svg"
printf 'not svg\n' >"$tmp/broken.svg"
desc="the checker accepts a plain SVG and rejects a file Qt cannot load"
check bash -c '"$1" "$2" >/dev/null && ! "$1" "$3" >/dev/null' _ "$tmp/svgcheck" "$tmp/good.svg" "$tmp/broken.svg"

# The composer's cleaning step (packaging/arch/icons-compose.py clean_svg) on the constructs found in the real session.
cat >"$tmp/dangling.svg" <<'EOF2'
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="8" height="8"><defs><pattern xlink:href="#gone" id="f"/><linearGradient id="g"><stop offset="0" stop-color="#f00"/><stop offset="1" stop-color="#00f"/></linearGradient></defs><rect width="8" height="4" fill="url(#f)"/><rect y="4" width="8" height="4" fill="url(#missing)"/><rect x="1" width="2" height="2" style="fill:url(#missing2)"/><rect x="2" y="2" width="4" height="4" fill="url(#g)"/></svg>
EOF2
cp "$tmp/dangling.svg" "$tmp/cleaned.svg"
desc="Qt rejects the construct (a dangling pattern and missing paint server) before cleaning"
check bash -c '! "$1" "$2" >/dev/null' _ "$tmp/svgcheck" "$tmp/dangling.svg"
cleaned=$(python3 -I -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("c", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.clean_svg(sys.argv[2]), m.clean_svg(sys.argv[2]))' "$root/packaging/arch/icons-compose.py" "$tmp/cleaned.svg")
desc="clean_svg changes the file once (then reports no change)"
check test "$cleaned" = "True False"
desc="the cleaned file loads under Qt without a warning and keeps the valid gradient fill"
check bash -c '"$1" "$2" >/dev/null && grep -q "fill=\"url(#g)\"" "$2" && ! grep -q "url(#f)\|url(#missing" "$2"' _ "$tmp/svgcheck" "$tmp/cleaned.svg"

if [[ -z $theme ]]; then
  echo "SKIP: no composed grassfield-icons theme under .dev here (run scripts/dev/icons.sh)"
  exit "$fail"
fi
mapfile -t files < <(find -L "$theme/base/apps" "$theme/base/places" "$theme/scalable" "$theme/extra" -type f -name '*.svg' 2>/dev/null | sort)
# Scope: paint references to a missing server ("property: <id>"). Other upstream quirks (forward xlink:href between gradients,
# oversized images) are not this class and are not asserted here.
desc="Qt resolves every paint reference of the ${#files[@]} composed app, place and own icons of $theme"
out=$("$tmp/svgcheck" "${files[@]}" 2>&1 || true)
check bash -c '! grep -qE "Could not resolve property: [A-Za-z0-9_.-]+$" <<<"$1"' _ "$out"
grep -E "Could not resolve property: [A-Za-z0-9_.-]+$|^checked" <<<"$out" | head -20 || true
exit "$fail"
