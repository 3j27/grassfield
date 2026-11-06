#!/usr/bin/env bash
# Direct build of Grassfield Memos with g++ (see CMakeLists.txt; ADR-0051).
# Usage: apps/memos/build-direct.sh [--install-paths]   (.dev/build/grassfield-memos; --install-paths bakes /usr/share)
#        apps/memos/build-direct.sh --tests [--asan]     (.dev/build/memos-unit-tests, or -asan with
#                                                         -fsanitize=address,undefined)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
out=$root/.dev/build
mkdir -p "$out"

# GCC 16 warns inside Qt headers (-Wsfinae-incomplete); keep our own warnings visible.
cxxflags=(-std=c++17 -O2 -Wall -Wextra -Wno-sfinae-incomplete -fPIC "-DGRASSFIELD_VERSION=\"$(tr -d "[:space:]" <"$root/VERSION")\"")
suffix=""
if [[ " $* " == *" --asan "* ]]; then
  cxxflags+=(-g -fsanitize=address,undefined -fno-omit-frame-pointer)
  suffix="-asan"
fi
core=("$here"/src/hyprframes.cpp "$here"/src/memoformatter.cpp "$here"/src/memosapp.cpp "$here"/src/memostore.cpp)
moc=/usr/lib/qt6/moc
[[ -x $moc ]] || moc=$(command -v moc-qt6 || command -v moc)
generated=()
for m in memoformatter memosapp; do
  "$moc" "$here/src/$m.h" -o "$out/moc_memos_$m$suffix.cpp"
  generated+=("$out/moc_memos_$m$suffix.cpp")
done

case ${1:-} in
  --tests)
    # shellcheck disable=SC2046
    g++ "${cxxflags[@]}" -I"$here/src" -I"$here/.." $(pkg-config --cflags Qt6Core Qt6Gui Qt6Quick) \
      "${core[@]}" "${generated[@]}" "$root"/tests/unit/memos/tst_*.cpp \
      $(pkg-config --libs Qt6Core Qt6Gui Qt6Quick) -lgtest -pthread -o "$out/memos-unit-tests$suffix"
    echo "built $out/memos-unit-tests$suffix"
    ;;
  "" | --install-paths)
    defs=()
    if [[ ${1:-} != "--install-paths" ]]; then
      defs+=("-DGRASSFIELD_MEMOS_QML_DIR=\"$here/qml\"")
    fi
    "$moc" "$here/src/memosinstance.h" -o "$out/moc_memos_memosinstance.cpp"
    generated+=("$out/moc_memos_memosinstance.cpp")
    qtver=$(pkg-config --modversion Qt6Gui)
    # windowchrome.h (ADR-0015) needs one Qt private header and libwayland-client.
    # shellcheck disable=SC2046
    g++ "${cxxflags[@]}" "${defs[@]}" -I"$here/src" -I"$here/.." -I"$root/ui/i18n" \
      $(pkg-config --cflags Qt6Gui Qt6Qml Qt6Quick Qt6DBus wayland-client) \
      -I"/usr/include/qt6/QtGui/$qtver" -I"/usr/include/qt6/QtGui/$qtver/QtGui" -I"/usr/include/qt6/QtCore/$qtver" \
      "${core[@]}" "${generated[@]}" "$here/src/main.cpp" \
      $(pkg-config --libs Qt6Gui Qt6Qml Qt6Quick Qt6DBus) -lwayland-client -pthread -o "$out/grassfield-memos"
    echo "built $out/grassfield-memos"
    # A dev session (scripts/dev/devenv.sh puts .dev/share first in XDG_DATA_DIRS) finds the entry and the icon here, so the
    # menu bar and Apps name it and Apps starts this build. Only under .dev/share, never in the owner's data directories.
    if [[ ${1:-} != "--install-paths" ]]; then
      share=$root/.dev/share
      mkdir -p "$share/applications" "$share/icons/hicolor/scalable/apps"
      sed "s|^Exec=grassfield-memos$|Exec=$out/grassfield-memos|" "$here/org.grassfield.Memos.desktop" \
        >"$share/applications/org.grassfield.Memos.desktop"
      cp "$root/branding/icons/apps/org.grassfield.Memos.svg" "$share/icons/hicolor/scalable/apps/"
    fi
    ;;
  *)
    echo "usage: apps/memos/build-direct.sh [--install-paths] | --tests [--asan]" >&2
    exit 2
    ;;
esac
