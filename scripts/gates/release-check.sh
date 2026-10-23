#!/usr/bin/env bash
# `just release-check`: the named local equivalent of CI (decision D-6). It checks what HEAD contains, not what the working
# tree happens to hold: a `git archive HEAD` snapshot is unpacked into a fresh temporary directory (made a throwaway git
# repository, since the scripts locate the repository root with git) and every step runs there:
#
#   1 check      `just check` of the snapshot: config, schema, qmllint, shaders, i18n, scripts, inventory, version
#                coherence, clang-tidy (full run, no stamp), gitleaks of the snapshot
#   2 test       `just test` of the snapshot (QML unit tests, gtest suites, compositor and bridge logic, inventory gate)
#   3 coverage   scripts/gates/coverage.sh: line coverage of the compositor core and the menu bridge logic (Q3, >= 70 %)
#   4 secrets    gitleaks over the WHOLE history of this repository (gate S1)
#   5 plugin     the compositor plugin built with CMake/Ninja against the INSTALLED Hyprland headers
#   6 plugin-rc  the same against rc-channel headers, only when --rc-headers is given (gate C3)
#
#   scripts/gates/release-check.sh [--rc-headers ROOT] [--keep] [--only step[,step...]]
#     --rc-headers ROOT   an extracted rc-channel hyprland package: ROOT/usr/include/hyprland and
#                         ROOT/usr/share/pkgconfig/hyprland.pc (e.g. `bsdtar -xf hyprland-*.pkg.tar.zst -C ROOT`)
#     --keep              keep the temporary directory (default: removed; the logs are always kept)
#     --only STEPS        run only these steps (debugging; the verdict then says "partial")
#
# Run it as a BARE command: `just test` needs the host (the 4 D-Bus cases SKIP inside the Claude sandbox, and the
# summary says how many cases skipped). Uncommitted changes are not in the snapshot and are reported.
# Output: a summary table with the result and seconds of every step, the commit, and the log directory
# (.dev/release-check/<timestamp>/). Exit: 0 every step passed (and, without --only, all ran); 1 a step failed;
# 2 usage or environment error.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
rc_headers="" keep=0 only=""
while (($#)); do
  case $1 in
    --rc-headers) shift; rc_headers=$1 ;;
    --keep) keep=1 ;;
    --only) shift; only=$1 ;;
    -h | --help) sed -n '2,/^set -uo/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    *) echo "release-check: unknown argument $1 (--help)" >&2; exit 2 ;;
  esac
  shift
done
for tool in git tar just gitleaks cmake ninja python3 jq; do
  command -v "$tool" >/dev/null || { echo "release-check: $tool is needed" >&2; exit 2; }
done
if [[ -n $rc_headers ]]; then
  [[ -f $rc_headers/usr/share/pkgconfig/hyprland.pc && -d $rc_headers/usr/include/hyprland ]] \
    || { echo "release-check: $rc_headers has no usr/share/pkgconfig/hyprland.pc and usr/include/hyprland" >&2; exit 2; }
fi

commit=$(git -C "$root" rev-parse HEAD)
stamp=$(date +%Y%m%d-%H%M%S)
logs=$root/.dev/release-check/$stamp
mkdir -p "$logs"
work=$(mktemp -d "${TMPDIR:-/tmp}/gf-release-check.XXXXXX")
cleanup() { ((keep)) || rm -rf "$work"; }
trap cleanup EXIT
src=$work/src
mkdir -p "$src"
git -C "$root" archive --format=tar HEAD | tar -x -C "$src"
git -C "$src" init -q -b main
git -C "$src" add -A
git -C "$src" -c user.name=release-check -c user.email=release-check@localhost commit -q -m "snapshot of $commit"
dirty=$(git -C "$root" status --porcelain | wc -l)
echo "release-check: snapshot of $commit in $src ($dirty uncommitted path(s) in $root are NOT in it); logs: $logs"

declare -a names=() results=() secs=() notes=()
want() { [[ -z $only || ",$only," == *",$1,"* ]]; }
step() { # <name> <command...>: runs in the snapshot, logs to $logs/<name>.log
  local name=$1 t0 rc
  shift
  want "$name" || return 0
  echo "release-check: [$name] running..."
  t0=$(date +%s)
  (cd "$src" && "$@") >"$logs/$name.log" 2>&1
  rc=$?
  names+=("$name") secs+=("$(($(date +%s) - t0))")
  if ((rc == 0)); then results+=(PASS); else results+=("FAIL($rc)"); fi
  notes+=("")
}
note() { notes[${#notes[@]} - 1]=$1; }

step check just check
step test just test
if want test && [[ ${#names[@]} -gt 0 ]]; then
  skips=$(grep -a -E '^summary: [0-9]+ check\(s\) SKIPPED|^summary: no check skipped' "$logs/test.log" | tail -n 1)
  idx=$((${#names[@]} - 1))
  [[ ${names[$idx]} == test ]] && notes[idx]=${skips:-"no skip summary found"}
fi
step coverage scripts/gates/coverage.sh
if want coverage && [[ ${names[${#names[@]} - 1]:-} == coverage ]]; then
  notes[${#notes[@]} - 1]=$(grep -a -E '^coverage (compositor src/core|menu-bridge):' "$logs/coverage.log" | sed 's/^coverage //' | paste -sd ';' -)
fi
step secrets gitleaks detect --source "$root" --no-banner --redact
step plugin just plugin-build
if [[ -n $rc_headers ]]; then
  want plugin && cp "$src/compositor/build/grassfield-compositor.so" "$work/stock.so" 2>/dev/null
  step plugin-rc env PKG_CONFIG_PATH="$rc_headers/usr/share/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$rc_headers" \
    sh -c 'cmake -S compositor -B compositor/build-rc -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo && cmake --build compositor/build-rc'
fi

echo
printf '%-10s %-9s %6s  %s\n' step result sec notes
fail=0
for i in "${!names[@]}"; do
  printf '%-10s %-9s %6s  %s\n' "${names[$i]}" "${results[$i]}" "${secs[$i]}" "${notes[$i]}"
  [[ ${results[$i]} == PASS ]] || fail=1
done
echo "commit $commit; snapshot built in $src; logs in $logs"
if [[ -z $rc_headers ]] && want plugin; then echo "plugin-rc: NOT RUN (no --rc-headers): gate C3 is not covered by this run"; fi
if ((fail)); then
  echo "release-check: FAIL (see the logs above; first lines of each failing step follow)"
  for i in "${!names[@]}"; do
    [[ ${results[$i]} == PASS ]] || { echo "--- ${names[$i]}:"; tail -n 15 "$logs/${names[$i]}.log"; }
  done
  exit 1
fi
if [[ -n $only ]]; then echo "release-check: PASS (partial: only $only)"; exit 0; fi
echo "release-check: PASS"
