#!/usr/bin/env bash
# The compositor's ground at the session's start (ADR-0040 ID-2, amended): config/hypr/grassfield/looknfeel.lua starts on the
# ground the shell last gave Hyprland (wallpaper.json `ground`), and on the default artwork's green only without one. The file
# is read only when it is a plain file: a FIFO (an open would block `Hyprland --verify-config` for good), a directory and a
# symlink leave the default, and the configuration still loads within seconds. Run under a plain Lua with a stub of `hl`.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
lua=
for c in lua5.5 lua5.4 lua; do command -v "$c" >/dev/null && { lua=$c; break; }; done
[[ -n $lua ]] || { echo "SKIP: no Lua interpreter"; exit 0; }
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/session-ground.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
cat >"$tmp/case.lua" <<'LUA'
local last
hl = setmetatable({
  config = function(t) if t.misc and t.misc.background_color then last = t.misc.background_color end end,
}, { __index = function(_, k) return function() end end })
dofile(arg[1] .. "/config/hypr/grassfield/looknfeel.lua")
print(last)
LUA
static=$(grep -o 'background_color = "rgba([0-9a-f]*ff)"' "$root/config/hypr/grassfield/looknfeel.lua" | head -1 | sed 's/.*"\(.*\)"/\1/')
run() { # state dir -> prints the last background colour; fails when it takes over 10 s
  GRASSFIELD_STATE_HOME=$1 timeout 10 "$lua" "$tmp/case.lua" "$root"
}
check() { # description expected actual
  if [[ $2 == "$3" ]]; then echo "PASS: $1 ($3)"; else echo "FAIL: $1 (expected $2, got $3)"; fail=1; fi
}

mkdir -p "$tmp/none"
check "no file: the static ground" "$static" "$(run "$tmp/none")"

mkdir -p "$tmp/ok"
printf '{"displays": {}, "shown": {"A": {"mean": "#112233"}}, "ground": "#A5937F"}\n' >"$tmp/ok/wallpaper.json"
check "a plain file: its ground, not an old output's mean" "rgba(a5937fff)" "$(run "$tmp/ok")"

mkdir -p "$tmp/nogr"
printf '{"displays": {}, "shown": {"A": {"mean": "#112233"}}}\n' >"$tmp/nogr/wallpaper.json"
check "no ground in it (an old file): the static ground" "$static" "$(run "$tmp/nogr")"

mkdir -p "$tmp/fifo"
mkfifo "$tmp/fifo/wallpaper.json"
start=$SECONDS
got=$(run "$tmp/fifo" || echo "timeout")
check "a FIFO: the static ground, and no hang" "$static" "$got"
(( SECONDS - start < 8 )) && echo "PASS: the FIFO case took $((SECONDS - start)) s" || { echo "FAIL: the FIFO case took $((SECONDS - start)) s"; fail=1; }

mkdir -p "$tmp/dir/wallpaper.json"
check "a directory: the static ground" "$static" "$(run "$tmp/dir")"

mkdir -p "$tmp/link"
ln -s "$tmp/ok/wallpaper.json" "$tmp/link/wallpaper.json"
check "a symlink: the static ground" "$static" "$(run "$tmp/link")"

mkdir -p "$tmp/it's"
printf '{"ground": "#010203"}\n' >"$tmp/it's/wallpaper.json"
check "a quote in the path is quoted" "rgba(010203ff)" "$(run "$tmp/it's")"
exit $fail
