#!/usr/bin/env bash
# branding/cursors/build.sh stops cleanly (ADR-0014): the stamp names the colours; SIGTERM (alone, or to the process group
# as the shell does) stops the children and removes the work directory, exit 143, no "Directory not empty"; the work
# directory of a build that was killed (SIGKILL) is removed by the next --clean/--remove/build at once, but never one
# whose build is still running. Builds only under a temporary directory.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/cursors-cancel.XXXXXX")
pids=()
cleanup() { for p in "${pids[@]}"; do kill -KILL -- "-$p" 2>/dev/null || true; done; rm -rf "$tmp"; }
trap cleanup EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
build=$root/branding/cursors/build.sh
name=grassfield-cursors-custom

# --clean needs no tool: stale work directories go, a live build's stays.
mkdir -p "$tmp/clean/.$name.build.999999.aaaaaa" "$tmp/clean/.$name.build.OLDFORMAT" "$tmp/clean/.$name.build.$$.live00" "$tmp/clean/.other.build.999999.zz" "$tmp/clean/$name"
echo x >"$tmp/clean/$name/manifest.hl"
"$build" --clean --out "$tmp/clean" --name "$name"
desc="--clean removes the work directories of dead builds (and old-format names)"
check bash -c '[[ ! -e $1/.$2.build.999999.aaaaaa && ! -e $1/.$2.build.OLDFORMAT ]]' _ "$tmp/clean" "$name"
desc="--clean keeps the work directory of a running build, other themes' directories and the theme"
check bash -c '[[ -d $1/.$2.build.$3.live00 && -d $1/.other.build.999999.zz && -f $1/$2/manifest.hl ]]' _ "$tmp/clean" "$name" "$$"
mkdir -p "$tmp/clean/.$name.build.999999.bbbbbb"
"$build" --remove --out "$tmp/clean" --name "$name"
desc="--remove deletes the theme and the stale work directories"
check bash -c '[[ ! -e $1/$2 && ! -e $1/.$2.build.999999.bbbbbb && -d $1/.$2.build.$3.live00 ]]' _ "$tmp/clean" "$name" "$$"

for tool in hyprcursor-util rsvg-convert python3 setsid pgrep; do
  command -v "$tool" >/dev/null || { echo "SKIP: cursors cancel test, real builds ($tool not installed)"; exit "$fail"; }
done

# A finished build: the stamp holds the colours (lower case).
"$build" --out "$tmp/done" --name "$name" --outline '#FFFF00' --fill '#FF0000' >/dev/null
desc="the stamp holds the colours the theme was built for"
check test "$(cat "$tmp/done/$name/colors")" = "#ffff00 #ff0000"
desc="a finished build leaves no work directory"
check bash -c '[[ -z $(ls -A "$1" | grep "\.build\.") ]]' _ "$tmp/done"


# SIGTERM to the build alone (as from a terminal): children stopped, work directory gone.
for delay in 0.4 1.1; do
  out=$tmp/term-$delay
  setsid "$build" --out "$out" --name "$name" --outline '#00ff00' --fill '#0000ff' >"$tmp/log" 2>&1 &
  pid=$!
  pids+=("$pid")
  sleep "$delay"
  kill -TERM "$pid"
  rc=0
  wait "$pid" || rc=$?
  sleep 0.3
  desc="SIGTERM at ${delay}s: exit 143, no error message (got rc=$rc, log: $(tr '\n' ' ' <"$tmp/log"))"
  check bash -c '[[ $1 == 143 && ! -s $2 ]]' _ "$rc" "$tmp/log"
  desc="SIGTERM at ${delay}s: no work directory and no child process left"
  check bash -c '[[ -z $(ls -A "$1" 2>/dev/null | grep "\.build\.") && $(ps -eo args= | grep -c "[x]cursor-pack.py.*$1\|[r]svg-convert.*$1") == 0 ]]' _ "$out"
done

# The shell's way: setsid, the whole group is signalled.
out=$tmp/group
setsid "$build" --out "$out" --name "$name" --outline '#00ff00' --fill '#0000ff' >"$tmp/log" 2>&1 &
pid=$!
pids+=("$pid")
sleep 0.8
kill -TERM -- "-$pid"
rc=0
wait "$pid" || rc=$?
sleep 0.3
desc="group SIGTERM: stopped, nothing left (rc=$rc)"
check bash -c '[[ -z $(ls -A "$1" 2>/dev/null | grep "\.build\.") && $(ps -eo args= | grep -c "[x]cursor-pack.py.*$1\|[r]svg-convert.*$1") == 0 ]]' _ "$out"

# SIGKILL of the group: the work directory stays (nothing can clean it), no child survives, the next build removes it at once.
out=$tmp/kill
setsid "$build" --out "$out" --name "$name" --outline '#00ff00' --fill '#0000ff' >"$tmp/log" 2>&1 &
pid=$!
pids+=("$pid")
sleep 0.8
kill -KILL -- "-$pid"
wait "$pid" 2>/dev/null || true
sleep 0.3
desc="group SIGKILL: no child process survives"
check bash -c '[[ $(ps -eo args= | grep -c "[x]cursor-pack.py.*$1\|[r]svg-convert.*$1") == 0 ]]' _ "$out"
desc="group SIGKILL: the work directory is left (cleaned by the next start)"
check bash -c '[[ -n $(ls -A "$1" | grep "\.build\.") ]]' _ "$out"
"$build" --clean --out "$out" --name "$name"
desc="the next --clean removes the work directory at once (not after an hour)"
check bash -c '[[ -z $(ls -A "$1" | grep "\.build\.") ]]' _ "$out"
exit "$fail"
