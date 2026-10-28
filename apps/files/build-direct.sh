#!/usr/bin/env bash
# Direct build of grassfield-files with g++ (CMake is not installed yet; see CMakeLists.txt).
# Output: .dev/build/grassfield-files. The dev binary reads the repository QML directory.
# Usage: apps/files/build-direct.sh [--install-paths]   (--install-paths bakes /usr/share paths)
#        apps/files/build-direct.sh --tests             (only the unit tests: .dev/build/files-unit-tests, files-kio-tests)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
out=$root/.dev/build
mkdir -p "$out"

# GCC 16 warns inside Qt headers (-Wsfinae-incomplete); keep our own warnings visible.
cxxflags=(-std=c++17 -O2 -Wall -Wextra -Wno-sfinae-incomplete -fPIC "-DGRASSFIELD_VERSION=\"$(tr -d "[:space:]" <"$root/VERSION")\"") # VERSION: the one version source
# Build against the non-deprecated KF6 API only (also hides deprecated declarations in KIO headers).
kfdefs=(-DKF_DISABLE_DEPRECATED_BEFORE_AND_AT=0x061D00)

# KDE Frameworks 6 ship CMake configs only (no pkg-config files): explicit include dirs and libraries.
kf=/usr/include/KF6
kf_includes=()
for d in KIOCore KIOGui KIOWidgets KIO KCoreAddons KService Solid KJobWidgets; do
  kf_includes+=("-I$kf/$d")
done
kf_libs=(-lKF6KIOCore -lKF6KIOGui -lKF6KIOWidgets -lKF6CoreAddons -lKF6Service -lKF6Solid -lKF6JobWidgets)

if [[ ${1:-} == "--tests" ]]; then
  # shellcheck disable=SC2046
  moc=/usr/lib/qt6/moc
  [[ -x $moc ]] || moc=$(command -v moc-qt6 || command -v moc)
  "$moc" "$here/src/tagsearch.h" -o "$out/moc_tests_tagsearch.cpp"
  "$moc" "$here/src/recents.h" -o "$out/moc_tests_recents.cpp"
  # tst_menushortcuts runs Qt.labs.platform menus offscreen (Qml, Widgets, Test) and includes globalmenu.h (DBus).
  g++ "${cxxflags[@]}" -I"$here/src" -I"$root/apps" $(pkg-config --cflags Qt6Core Qt6Gui Qt6Widgets Qt6Qml Qt6DBus Qt6Test) \
    "$root/tests/unit/files/tst_filelogic.cpp" "$root/tests/unit/files/tst_previewqueue.cpp" "$root/tests/unit/files/tst_tags.cpp" \
    "$root/tests/unit/files/tst_tagsearch.cpp" "$root/tests/unit/files/tst_folderstyle.cpp" "$root/tests/unit/files/tst_folderviews.cpp" "$root/tests/unit/files/tst_imagerotate.cpp" "$root/tests/unit/files/tst_imagesize.cpp" "$root/tests/unit/files/tst_recents.cpp" "$root/tests/unit/files/tst_folderprune.cpp" \
    "$root/tests/unit/files/tst_appscope.cpp" "$root/tests/unit/files/tst_runmode.cpp" "$root/tests/unit/files/tst_autoappearance.cpp" "$root/tests/unit/files/tst_launchguard.cpp" \
    "$root/tests/unit/files/tst_menushortcuts.cpp" \
    "$here/src/filelogic.cpp" "$here/src/launchguard.cpp" "$here/src/taglogic.cpp" "$here/src/tagstore.cpp" "$here/src/tagsearch.cpp" "$here/src/folderstylelogic.cpp" "$here/src/folderstylestore.cpp" "$here/src/folderviews.cpp" "$here/src/imagerotate.cpp" "$here/src/imagesize.cpp" "$here/src/recents.cpp" "$out/moc_tests_tagsearch.cpp" "$out/moc_tests_recents.cpp" \
    $(pkg-config --libs Qt6Core Qt6Gui Qt6Widgets Qt6Qml Qt6DBus Qt6Test) -lgtest -lgtest_main -pthread \
    -o "$out/files-unit-tests"
  echo "built $out/files-unit-tests"
  # Grassfield's KIO dialogs (ADR-0035 D-12 a): the logic and real KIO jobs, against KIO's libraries; its own main (a
  # scratch home, offscreen).
  "$moc" "${kf_includes[@]}" "$here/src/kioprompts.h" -o "$out/moc_tests_kioprompts.cpp"
  g++ "${cxxflags[@]}" "${kfdefs[@]}" "-DFILES_SOURCE_DIR=\"$here/src\"" -I"$here/src" -I"$root/apps" "${kf_includes[@]}" \
    $(pkg-config --cflags Qt6Core Qt6Gui Qt6Widgets Qt6DBus Qt6Network) \
    "$root/tests/unit/files/tst_kioprompts.cpp" "$root/tests/unit/files/tst_kiodialogs.cpp" \
    "$here/src/kioprompts.cpp" "$here/src/kiopromptlogic.cpp" "$here/src/filelogic.cpp" "$out/moc_tests_kioprompts.cpp" \
    $(pkg-config --libs Qt6Core Qt6Gui Qt6Widgets Qt6DBus Qt6Network) "${kf_libs[@]}" -lgtest -pthread -o "$out/files-kio-tests"
  echo "built $out/files-kio-tests"
  exit 0
fi

defs=()
if [[ ${1:-} != "--install-paths" ]]; then
  defs+=("-DGRASSFIELD_FILES_QML_DIR=\"$here/qml\"")
fi

# QObjects with Q_OBJECT need moc.
moc=/usr/lib/qt6/moc
[[ -x $moc ]] || moc=$(command -v moc-qt6 || command -v moc)
mocs=()
for h in foldermodel placesmodel filesapp tagsearch recents kioprompts; do
  "$moc" "${kf_includes[@]}" "$here/src/$h.h" -o "$out/moc_files_$h.cpp"
  mocs+=("$out/moc_files_$h.cpp")
done

# Compile the translation units in parallel (KIO headers are heavy), then link.
objdir=$out/files-obj
mkdir -p "$objdir"
read -r -a qt_cflags <<<"$(pkg-config --cflags Qt6Widgets Qt6Gui Qt6Qml Qt6Quick Qt6DBus Qt6Network wayland-client) -I/usr/include/qt6/QtGui/$(pkg-config --modversion Qt6Gui) -I/usr/include/qt6/QtGui/$(pkg-config --modversion Qt6Gui)/QtGui -I/usr/include/qt6/QtCore/$(pkg-config --modversion Qt6Gui)"
read -r -a qt_libs <<<"$(pkg-config --libs Qt6Widgets Qt6Gui Qt6Qml Qt6Quick Qt6DBus Qt6Network wayland-client)"
sources=("$here/src/main.cpp" "$here/src/filesapp.cpp" "$here/src/foldermodel.cpp" "$here/src/placesmodel.cpp"
  "$here/src/imageproviders.cpp" "$here/src/filelogic.cpp" "$here/src/launchguard.cpp" "$here/src/taglogic.cpp" "$here/src/tagstore.cpp"
  "$here/src/tagsearch.cpp" "$here/src/folderstylelogic.cpp" "$here/src/folderstylestore.cpp" "$here/src/folderviews.cpp" "$here/src/imagerotate.cpp" "$here/src/imagesize.cpp" "$here/src/recents.cpp"
  "$here/src/kioprompts.cpp" "$here/src/kiopromptlogic.cpp" "${mocs[@]}")
pids=() objs=()
for src in "${sources[@]}"; do
  obj=$objdir/$(basename "${src%.cpp}").o
  objs+=("$obj")
  g++ "${cxxflags[@]}" "${kfdefs[@]}" "${defs[@]}" -I"$here/src" -I"$here/.." -I"$root/ui/i18n" -I"$out" "${kf_includes[@]}" "${qt_cflags[@]}" \
    -c "$src" -o "$obj" &
  pids+=($!)
done
status=0
for pid in "${pids[@]}"; do wait "$pid" || status=1; done
[[ $status -eq 0 ]] || { echo "build-direct: compilation failed" >&2; exit 1; }
g++ "${objs[@]}" "${qt_libs[@]}" "${kf_libs[@]}" -o "$out/grassfield-files"
echo "built $out/grassfield-files"
