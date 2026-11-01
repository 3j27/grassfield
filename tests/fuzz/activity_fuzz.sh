#!/usr/bin/env bash
# Mutation fuzzing of Activity Monitor's readers (review of 5bfd4419, NIT 6): builds tests/fuzz/activity_parsers_fuzz.cpp
# with AddressSanitizer and UndefinedBehaviorSanitizer beside the readers it feeds (apps/activity/src: the projection,
# the journal's unit records, cpu.stat, /proc/net/wireless, a cache size, a desktop entry, a unit's name, Inspect's
# readers) and runs it: no crash, a bounded CPU time per call (the thread's own, so a loaded machine does not fail it), the
# same answer twice, each reader's promises. Scratch files only, nothing of the session read or written. Budget: GF_FUZZ_ITERATIONS (default 2000 per reader), GF_FUZZ_SEED.
# Prints PASS/FAIL lines; exit 0 when every reader passed (a SKIP line without g++ or Qt 6 Core).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
command -v g++ >/dev/null && pkg-config --exists Qt6Core || { echo "SKIP: activity_fuzz (g++ or Qt6Core missing)"; exit 0; }
out=$root/.dev/build
mkdir -p "$out"
src=apps/activity/src
moc=/usr/lib/qt6/moc
[[ -x $moc ]] || moc=$(command -v moc-qt6 || command -v moc)
"$moc" "$src/runtimefiles.h" -o "$out/moc_fuzz_runtimefiles.cpp"
"$moc" "$src/apphistory.h" -o "$out/moc_fuzz_apphistory.cpp"
# shellcheck disable=SC2046
g++ -std=c++17 -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer -fPIC -w \
  -I"$src" -Iapps -Iui/i18n $(pkg-config --cflags Qt6Core) \
  tests/fuzz/activity_parsers_fuzz.cpp "$src/apphistory.cpp" "$src/desktopapps.cpp" "$src/format.cpp" "$src/inspect.cpp" \
  "$src/machine.cpp" "$src/procparse.cpp" "$src/runtimefiles.cpp" "$src/signals.cpp" "$src/textclean.cpp" "$src/units.cpp" \
  "$out/moc_fuzz_runtimefiles.cpp" "$out/moc_fuzz_apphistory.cpp" \
  $(pkg-config --libs Qt6Core) -pthread -o "$out/activity-parsers-fuzz"
env -u DISPLAY -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen ASAN_OPTIONS=detect_leaks=0 "$out/activity-parsers-fuzz"
