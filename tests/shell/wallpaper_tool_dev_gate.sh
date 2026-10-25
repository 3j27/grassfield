#!/usr/bin/env bash
# grassfield-wallpaper: the --base-url loopback door (tests only) follows the one run-mode rule (ADR-0019, apps/runmode.h):
# open in a dev session (GRASSFIELD_DEV=1, no GRASSFIELD_SESSION), closed everywhere else, and in particular closed in a
# packaged session where a GRASSFIELD_DEV=1 leaked (GRASSFIELD_SESSION=1). Refusals happen before any request; the one open
# case talks to a closed loopback port only (nothing leaves the machine). Exit 0 when every check passes.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
apps/wallpaper-tool/build-direct.sh >/dev/null
helper=$root/.dev/build/grassfield-wallpaper
mkdir -p "$root/.dev"
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-$root/.dev}/wpgate.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() {
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fail=1; fi
}

out=$tmp/cache/wallpapers/online/commons
fetch() { # env assignments..., prints the exit code
  local rc=0
  env -u GRASSFIELD_DEV -u GRASSFIELD_SESSION "$@" timeout 20 "$helper" fetch commons --date 2026-10-20 --out "$out" \
    --base-url "http://127.0.0.1:1" >"$tmp/stdout" 2>"$tmp/stderr" </dev/null || rc=$?
  echo "$rc"
}

rc=$(fetch GRASSFIELD_DEV=1 GRASSFIELD_SESSION=1)
check "a leaked GRASSFIELD_DEV=1 in a packaged session refuses the base URL (exit 2, $rc)" test "$rc" = 2
check "the refusal names the dev rule" grep -q "only for a dev session" "$tmp/stderr" "$tmp/stdout"

rc=$(fetch GRASSFIELD_SESSION=1)
check "a packaged session refuses the base URL (exit 2, $rc)" test "$rc" = 2

rc=$(fetch FOO=bar)
check "no dev value refuses the base URL (exit 2, $rc)" test "$rc" = 2

rc=$(fetch GRASSFIELD_DEV=1 GRASSFIELD_SESSION=0)
check "a dev session with GRASSFIELD_SESSION=0 passes the gate (not exit 2, $rc)" test "$rc" != 2

rc=$(fetch GRASSFIELD_DEV=1)
check "a dev session passes the gate (not exit 2, $rc)" test "$rc" != 2
exit $fail
