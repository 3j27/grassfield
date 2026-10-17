#!/usr/bin/env bash
# Direct build of grassfield-menu-bridge with g++ + pkg-config (same sources and flags as CMakeLists.txt).
# Output: .dev/build/grassfield-menu-bridge
# Usage: bridges/menu-bridge/build-direct.sh            the bridge
#        bridges/menu-bridge/build-direct.sh --tests    the unit tests: .dev/build/menu-bridge-unit-tests (gtest)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
out=$root/.dev/build
mkdir -p "$out/menu-bridge-moc"

# GCC 16 warns inside Qt headers (-Wsfinae-incomplete); keep our own warnings visible.
cxxflags=(-std=c++20 -O2 -g -Wall -Wextra -Wno-sfinae-incomplete -fPIC)
logic=("$here/src/Protocol.cpp" "$here/src/Layout.cpp" "$here/src/Safety.cpp" "$here/src/DBusObjects.cpp")

moc=/usr/lib/qt6/moc
[[ -x $moc ]] || moc=$(command -v moc-qt6 || command -v moc)
"$moc" "$here/src/MenuClient.h" -o "$out/menu-bridge-moc/moc_MenuClient.cpp"

if [[ ${1:-} == "--tests" ]]; then
  # shellcheck disable=SC2046
  g++ "${cxxflags[@]}" -I"$here/src" -DGRASSFIELD_MENU_BRIDGE_DBUS_XML="\"$here/dbus/org.grassfield.MenuBridge1.xml\"" \
    $(pkg-config --cflags Qt6Core Qt6DBus) \
    "$root/tests/unit/menu-bridge/tst_menubridge.cpp" "$here/src/MenuClient.cpp" "$out/menu-bridge-moc/moc_MenuClient.cpp" "${logic[@]}" \
    $(pkg-config --libs Qt6Core Qt6DBus) -lgtest -pthread \
    -o "$out/menu-bridge-unit-tests"
  echo "built $out/menu-bridge-unit-tests"
  exit 0
fi

# shellcheck disable=SC2046
g++ "${cxxflags[@]}" -I"$here/src" \
  $(pkg-config --cflags Qt6Core Qt6DBus Qt6Network) \
  "$here/src/main.cpp" "$here/src/Bridge.cpp" "$here/src/MenuClient.cpp" "${logic[@]}" \
  "$out/menu-bridge-moc/moc_MenuClient.cpp" \
  $(pkg-config --libs Qt6Core Qt6DBus Qt6Network) \
  -o "$out/grassfield-menu-bridge"
echo "built $out/grassfield-menu-bridge"
