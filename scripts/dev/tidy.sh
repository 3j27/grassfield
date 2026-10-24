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
if (($# == 0 && force == 0)) && [[ -f $stamp && $(<"$stamp") == "$key" ]]; then
  echo "tidy: up to date (nothing changed since the last passing run; --force runs it again)"
  exit 0
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
printf '%s\n' "${files[@]}" | xargs -P "$(nproc)" -n 1 clang-tidy -p build --quiet >"$out" 2>&1 || rc=$?
findings=$(grep -c -E ': (warning|error): ' "$out" || true)
if ((findings > 0 || rc != 0)); then
  grep -v -E '^[0-9]+ warnings? generated|^Suppressed [0-9]+|^Use -header-filter|^\[[0-9]+/[0-9]+\] Processing' "$out" || true
  echo "tidy: FAIL: $findings finding(s), clang-tidy exit $rc, ${#files[@]} file(s)" >&2
  exit 1
fi
echo "tidy: ok (${#files[@]} files, 0 findings)"
(($# == 0)) && printf '%s' "$key" >"$stamp"
exit 0
