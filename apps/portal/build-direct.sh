#!/usr/bin/env bash
# Direct build of grassfield-portal with g++ (see CMakeLists.txt). Output: .dev/build/grassfield-portal, which reads the
# repository's Files QML directory (apps/files/qml). It links the Files library that apps/files/build-direct.sh --core builds.
# Usage: apps/portal/build-direct.sh                   (the backend)
#        apps/portal/build-direct.sh --install-paths   (the installed QML directory baked in)
#        apps/portal/build-direct.sh --tests           (the unit tests: .dev/build/portal-unit-tests)
#        apps/portal/build-direct.sh --tests --asan    (the same with -fsanitize=address,undefined: .dev/build/portal-unit-tests-asan;
#                                                       the probe's threads outlive a FileChooser that goes)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
out=$root/.dev/build
mode=${1:-}
mkdir -p "$out"
"$root/apps/files/build-direct.sh" --core >/dev/null

cxxflags=(-std=c++17 -O2 -Wall -Wextra -Wno-sfinae-incomplete -fPIC "-DGRASSFIELD_VERSION=\"$(tr -d "[:space:]" <"$root/VERSION")\"")
sanitize=() suffix=""
if [[ $mode == --tests && ${2:-} == --asan ]]; then
  sanitize=(-g -fsanitize=address,undefined -fno-omit-frame-pointer)
  suffix="-asan"
fi
kfdefs=(-DKF_DISABLE_DEPRECATED_BEFORE_AND_AT=0x061D00)
kf=/usr/include/KF6
kf_includes=()
for d in KIOCore KIOGui KIOWidgets KIO KCoreAddons KService Solid KJobWidgets KWindowSystem; do
  kf_includes+=("-I$kf/$d")
done
kf_libs=(-lKF6KIOCore -lKF6KIOGui -lKF6KIOWidgets -lKF6CoreAddons -lKF6Service -lKF6Solid -lKF6JobWidgets -lKF6WindowSystem)
read -r -a qt_cflags <<<"$(pkg-config --cflags Qt6Widgets Qt6Gui Qt6Qml Qt6Quick Qt6DBus Qt6Network Qt6Test wayland-client) -I/usr/include/qt6/QtGui/$(pkg-config --modversion Qt6Gui) -I/usr/include/qt6/QtGui/$(pkg-config --modversion Qt6Gui)/QtGui -I/usr/include/qt6/QtCore/$(pkg-config --modversion Qt6Gui)"
read -r -a qt_libs <<<"$(pkg-config --libs Qt6Widgets Qt6Gui Qt6Qml Qt6Quick Qt6DBus Qt6Network wayland-client)"
moc=/usr/lib/qt6/moc
[[ -x $moc ]] || moc=$(command -v moc-qt6 || command -v moc)
"$moc" "${kf_includes[@]}" "$here/src/requesthost.h" -o "$out/moc_portal_requesthost.cpp"
"$moc" "${kf_includes[@]}" "$here/src/filechooser.h" -o "$out/moc_portal_filechooser.cpp"
"$moc" "${kf_includes[@]}" "$here/src/access.h" -o "$out/moc_portal_access.cpp"

defs=()
sources=("$here/src/requesthost.cpp" "$here/src/filechooser.cpp" "$here/src/access.cpp" "$here/src/chooserlogic.cpp"
         "$here/src/panelstate.cpp" "$out/moc_portal_requesthost.cpp" "$out/moc_portal_filechooser.cpp" "$out/moc_portal_access.cpp")
target=$out/grassfield-portal
case $mode in
  --tests)
    # tst_filechooser.cpp declares its fakes in the file itself (its own moc, included at its end).
    "$moc" "$root/tests/unit/portal/tst_filechooser.cpp" -o "$out/tst_filechooser.moc"
    "$moc" "$root/tests/unit/portal/tst_access.cpp" -o "$out/tst_access.moc"
    sources+=("$root/tests/unit/portal/tst_chooserlogic.cpp" "$root/tests/unit/portal/tst_panelstate.cpp" "$root/tests/unit/portal/tst_filechooser.cpp"
              "$root/tests/unit/portal/tst_access.cpp")
    target=$out/portal-unit-tests$suffix ;;
  --install-paths) sources+=("$here/src/main.cpp") ;;
  "") sources+=("$here/src/main.cpp"); defs+=("-DGRASSFIELD_FILES_QML_DIR=\"$root/apps/files/qml\"") ;;
  *) echo "usage: $0 [--install-paths | --tests [--asan]]" >&2; exit 2 ;;
esac

objdir=$out/portal-obj${mode:+-${mode#--}}$suffix
mkdir -p "$objdir"
pids=() objs=()
for src in "${sources[@]}"; do
  obj=$objdir/$(basename "${src%.cpp}").o
  objs+=("$obj")
  g++ "${cxxflags[@]}" "${sanitize[@]}" "${kfdefs[@]}" "${defs[@]}" -I"$here/src" -I"$root/apps/files/src" -I"$root/apps" -I"$root/ui/i18n" -I"$out" \
    "${kf_includes[@]}" "${qt_cflags[@]}" -c "$src" -o "$obj" &
  pids+=($!)
done
status=0
for pid in "${pids[@]}"; do wait "$pid" || status=1; done
[[ $status -eq 0 ]] || { echo "build-direct: compilation failed" >&2; exit 1; }
extra=()
[[ $mode == --tests ]] && extra=(-lgtest -pthread -lQt6Test)
g++ "${sanitize[@]}" "${objs[@]}" "$out/libgrassfield-files-core.a" "${qt_libs[@]}" "${kf_libs[@]}" "${extra[@]}" -o "$target"
echo "built $target"
