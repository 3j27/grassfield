#!/usr/bin/env bash
# Direct build of grassfield-menu-bridge with g++ + pkg-config (same sources and flags as CMakeLists.txt).
# Output: .dev/build/grassfield-menu-bridge
# Usage: bridges/menu-bridge/build-direct.sh            the bridge
#        bridges/menu-bridge/build-direct.sh --tests    the unit tests: .dev/build/menu-bridge-unit-tests (gtest)
#        bridges/menu-bridge/build-direct.sh --tests --asan   the same with -fsanitize=address,undefined (.dev/build/menu-bridge-unit-tests-asan)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
out=$root/.dev/build
mkdir -p "$out/menu-bridge-moc"

# GCC 16 warns inside Qt headers (-Wsfinae-incomplete); keep our own warnings visible.
cxxflags=(-std=c++20 -O2 -g -Wall -Wextra -Wno-sfinae-incomplete -fPIC "-DGRASSFIELD_VERSION=\"$(tr -d "[:space:]" <"$root/VERSION")\"") # VERSION: the one version source
logic=("$here/src/Protocol.cpp" "$here/src/Layout.cpp" "$here/src/Safety.cpp" "$here/src/Penalties.cpp" "$here/src/DBusObjects.cpp" "$here/src/Launcher.cpp" "$here/src/ScreenSaver.cpp" "$here/src/Registrations.cpp" "$here/src/Ongoing.cpp" "$here/src/OngoingObject.cpp")

moc=/usr/lib/qt6/moc
[[ -x $moc ]] || moc=$(command -v moc-qt6 || command -v moc)
"$moc" "$here/src/MenuClient.h" -o "$out/menu-bridge-moc/moc_MenuClient.cpp"
"$moc" "$here/src/LauncherWatcher.h" -o "$out/menu-bridge-moc/moc_LauncherWatcher.cpp"
"$moc" "$root/apps/ongoing.h" -o "$out/menu-bridge-moc/moc_ongoing.cpp"

if [[ ${1:-} == "--tests" ]]; then
  extra=()
  suffix=""
  if [[ ${2:-} == "--asan" ]]; then
    extra=(-fsanitize=address,undefined -fno-omit-frame-pointer)
    suffix="-asan"
  fi
  # shellcheck disable=SC2046
  g++ "${cxxflags[@]}" "${extra[@]}" -I"$here/src" -I"$root/apps" -DGRASSFIELD_MENU_BRIDGE_DBUS_XML="\"$here/dbus/org.grassfield.MenuBridge1.xml\"" -DGRASSFIELD_ONGOING_DBUS_XML="\"$here/dbus/org.grassfield.Ongoing1.xml\"" \
    -DGRASSFIELD_RUN_MODE_VECTORS="\"$root/tests/fixtures/run-mode-vectors.json\"" \
    $(pkg-config --cflags Qt6Core Qt6DBus) \
    "$root/tests/unit/menu-bridge/tst_menubridge.cpp" "$root/tests/unit/menu-bridge/tst_screensaver.cpp" "$root/tests/unit/menu-bridge/tst_ongoing.cpp" "$here/src/MenuClient.cpp" "$out/menu-bridge-moc/moc_MenuClient.cpp" "$out/menu-bridge-moc/moc_ongoing.cpp" "${logic[@]}" \
    $(pkg-config --libs Qt6Core Qt6DBus) -lgtest -pthread \
    -o "$out/menu-bridge-unit-tests$suffix"
  echo "built $out/menu-bridge-unit-tests$suffix"
  exit 0
fi

# shellcheck disable=SC2046
g++ "${cxxflags[@]}" -I"$here/src" \
  $(pkg-config --cflags Qt6Core Qt6DBus Qt6Network) \
  "$here/src/main.cpp" "$here/src/Bridge.cpp" "$here/src/LauncherWatcher.cpp" "$here/src/MenuClient.cpp" "${logic[@]}" \
  "$out/menu-bridge-moc/moc_MenuClient.cpp" "$out/menu-bridge-moc/moc_LauncherWatcher.cpp" \
  $(pkg-config --libs Qt6Core Qt6DBus Qt6Network) \
  -o "$out/grassfield-menu-bridge"
echo "built $out/grassfield-menu-bridge"
# shellcheck disable=SC2046
g++ "${cxxflags[@]}" -I"$root/apps" -I"$root/ui/i18n" $(pkg-config --cflags Qt6Core Qt6DBus) "$here/src/OngoingCli.cpp" "$out/menu-bridge-moc/moc_ongoing.cpp" \
  $(pkg-config --libs Qt6Core Qt6DBus) -o "$out/grassfield-ongoing"
echo "built $out/grassfield-ongoing"
