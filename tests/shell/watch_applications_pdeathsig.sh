#!/usr/bin/env bash
# Test for shell/launchpad/watch-applications.sh: the watcher dies with its parent (pdeathsig), even
# when the parent is killed with SIGKILL. Uses a temporary XDG tree under .dev/ (or $GRASSFIELD_TEST_TMP).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
command -v inotifywait >/dev/null 2>&1 || { echo "SKIP: watch-applications pdeathsig (inotifywait missing)"; exit 0; }
mkdir -p "$root/.dev"
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-$root/.dev}/watchapps.XXXXXX")
parent=""
cleanup() {
  [[ -n $parent ]] && kill -9 "$parent" 2>/dev/null || true
  [[ -s $tmp/child ]] && kill "$(<"$tmp/child")" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/data/applications"

# The parent stands in for the shell: it starts the watcher and waits.
XDG_DATA_HOME="$tmp/data" XDG_DATA_DIRS="$tmp/none" \
  bash -c 'sh "$1" >/dev/null & echo $! > "$2"; wait' bash "$root/shell/launchpad/watch-applications.sh" "$tmp/child" &
parent=$!

for _ in $(seq 1 50); do [[ -s $tmp/child ]] && break; sleep 0.1; done
child=$(<"$tmp/child")
# The watcher is up (exec'd into inotifywait) before the parent goes away.
for _ in $(seq 1 50); do [[ $(cat "/proc/$child/comm" 2>/dev/null) == inotifywait ]] && break; sleep 0.1; done
[[ $(cat "/proc/$child/comm" 2>/dev/null) == inotifywait ]] || { echo "FAIL: watch-applications did not start inotifywait"; exit 1; }

kill -9 "$parent"
wait "$parent" 2>/dev/null || true
parent=""
for _ in $(seq 1 30); do kill -0 "$child" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$child" 2>/dev/null; then
  echo "FAIL: watch-applications outlived its parent (pid $child)"
  exit 1
fi
echo "PASS: watch-applications dies with its parent"
