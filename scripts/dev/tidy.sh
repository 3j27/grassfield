#!/usr/bin/env bash
# Gate Q1 (compositor half): clang-tidy over every translation unit of the plugin glue, the core and the tests, with the
# project's config (compositor/.clang-tidy). Any warning or error fails the run (the config only makes analyzer findings
# errors; here every finding counts). Files run in parallel; the compile database comes from compositor/build-direct.sh.
#
#   scripts/dev/tidy.sh [--force] [files...]   (default: every file of the compile database)
#
# A full run takes minutes (the glue includes Hyprland's headers). A passing full run is stamped in
# compositor/build/tidy.stamp with a hash of every source, the tidy config, clang-tidy's and Hyprland's versions; an
# unchanged tree is "up to date" without running (--force, or a clean checkout as in `just release-check`, runs it).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
command -v clang-tidy >/dev/null || { echo "tidy: clang-tidy is not installed" >&2; exit 2; }
force=0
[[ ${1:-} == --force ]] && { force=1; shift; }
"$root/compositor/build-direct.sh" compdb
cd "$root/compositor"
stamp=build/tidy.stamp
key=$({ find src tests protocols .clang-tidy build-direct.sh -type f -print0 | sort -z | xargs -0 sha256sum; clang-tidy --version; pkg-config --modversion hyprland; } | sha256sum | cut -d' ' -f1)
# The key hashes the content, so a pass in one worktree holds for every worktree with the same compositor tree: passing
# keys are also kept in the repository's common git dir, and full runs are serialized there (one at a time across the
# worktrees; a waiting run re-checks the stamps first). Without this every agent worktree re-ran the same minutes-long
# analysis in parallel after merging main (40 clang-tidy processes, load 48 on 8 cores, 2026-10-24).
shared=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)/grassfield-tidy
mkdir -p "$shared"
passed() { [[ -f $stamp && $(<"$stamp") == "$key" ]] || [[ -f $shared/$key ]]; }
if (($# == 0 && force == 0)) && passed; then
  echo "tidy: up to date (nothing changed since the last passing run; --force runs it again)"
  exit 0
fi
exec 9>"$shared/lock"
if ! flock -n 9; then
  echo "tidy: another worktree is running clang-tidy; waiting for it" >&2
  flock 9
  if (($# == 0 && force == 0)) && passed; then
    echo "tidy: up to date (the other run passed on this same tree)"
    exit 0
  fi
fi
if (($# > 0)); then
  files=("$@")
else
  mapfile -t files < <(jq -r '.[].file' build/compile_commands.json)
fi
((${#files[@]} > 0)) || { echo "tidy: empty compile database" >&2; exit 2; }
out=$(mktemp)
trap 'rm -f "$out"' EXIT
rc=0
# Inside the owner's real Grassfield session (every terminal there inherits GRASSFIELD_SESSION=1) clang-tidy runs at the
# lowest priority on two jobs, so a check never makes the session stall (2026-10-25: load 32 on 8 threads during a full run).
jobs=$(nproc)
prio=()
if [[ ${GRASSFIELD_SESSION:-} == 1 ]]; then
  jobs=2
  prio=(nice -n 19)
fi
printf '%s\n' "${files[@]}" | "${prio[@]}" xargs -P "$jobs" -n 1 clang-tidy -p build --quiet >"$out" 2>&1 || rc=$?
findings=$(grep -c -E ': (warning|error): ' "$out" || true)
if ((findings > 0 || rc != 0)); then
  grep -v -E '^[0-9]+ warnings? generated|^Suppressed [0-9]+|^Use -header-filter|^\[[0-9]+/[0-9]+\] Processing' "$out" || true
  echo "tidy: FAIL: $findings finding(s), clang-tidy exit $rc, ${#files[@]} file(s)" >&2
  exit 1
fi
echo "tidy: ok (${#files[@]} files, 0 findings)"
if (($# == 0)); then
  printf '%s' "$key" >"$stamp"
  : >"$shared/$key"
fi
exit 0
