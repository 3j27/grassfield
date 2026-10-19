#!/usr/bin/env bash
# The pointer theme variables reach the processes that are not children of Hyprland (ADR-0014):
#  * real session: autostart.lua names them in the `uwsm finalize` import list;
#  * dev session: scripts/dev/devenv.sh exports them (once, without duplicates) when the dev theme is built;
#  * cursor.lua adds the dev directories to XDG_DATA_DIRS / XCURSOR_PATH only when they are not already there.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/cursor-env.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

for v in XCURSOR_THEME XCURSOR_SIZE HYPRCURSOR_THEME HYPRCURSOR_SIZE; do
  desc="autostart.lua imports $v into systemd/D-Bus"
  check grep -q "vars = vars .* $v\b" "$root/config/hypr/grassfield/autostart.lua"
done

# A throwaway repository with the helper and a stub dev theme: devenv.sh finds its root through git.
fake=$tmp/repo
mkdir -p "$fake/scripts/dev" "$fake/.dev/share/icons/grassfield-cursors"
cp "$root/scripts/dev/devenv.sh" "$fake/scripts/dev/"
touch "$fake/.dev/share/icons/grassfield-cursors/manifest.hl"
git -C "$fake" init -q

env_of() { env -i PATH="$PATH" HOME=/nonexistent "$@" bash -c '. "$1"; . "$1"; env' _ "$fake/scripts/dev/devenv.sh"; }
out=$(env_of)
desc="devenv.sh exports the cursor variables (sourced twice)"
check bash -c 'grep -qx "XCURSOR_THEME=grassfield-cursors" <<<"$1" && grep -qx "XCURSOR_SIZE=24" <<<"$1" && grep -qx "HYPRCURSOR_THEME=grassfield-cursors" <<<"$1" && grep -qx "HYPRCURSOR_SIZE=24" <<<"$1"' _ "$out"
desc="devenv.sh puts the dev icons first in XCURSOR_PATH and XDG_DATA_DIRS, each once"
check bash -c '[[ $(grep -c "^XCURSOR_PATH=$2/.dev/share/icons:" <<<"$1") == 1 && $(grep "^XCURSOR_PATH=" <<<"$1" | grep -o "$2/.dev/share/icons" | wc -l) == 1 && $(grep "^XDG_DATA_DIRS=" <<<"$1" | grep -o "$2/.dev/share" | wc -l) == 1 ]]' _ "$out" "$fake"
out=$(env_of GRASSFIELD_CURSOR_SIZE=32)
desc="GRASSFIELD_CURSOR_SIZE reaches the cursor variables"
check bash -c 'grep -qx "XCURSOR_SIZE=32" <<<"$1" && grep -qx "HYPRCURSOR_SIZE=32" <<<"$1"' _ "$out"
rm -rf "$fake/.dev/share/icons/grassfield-cursors"
out=$(env_of)
desc="without the dev theme devenv.sh sets no cursor variable"
check bash -c '! grep -q "CURSOR" <<<"$1"' _ "$out"

# cursor.lua: no second XDG_DATA_DIRS entry when the helper already added it (needs a Lua interpreter).
if command -v lua >/dev/null; then
  share=$fake/.dev/share
  mkdir -p "$share/icons/grassfield-cursors"
  touch "$share/icons/grassfield-cursors/manifest.hl"
  calls=$(XDG_DATA_DIRS="$share:/usr/share" XCURSOR_PATH="$share/icons:/usr/share/icons" GRASSFIELD_CONFIG_DIR="$fake/config/hypr" lua - "$root/config/hypr/grassfield/cursor.lua" <<'LUA'
_G.grassfield_dev = true
local calls = {}
hl = { env = function(k, v) calls[#calls + 1] = k end }
dofile(arg[1]).apply()
print(table.concat(calls, " "))
LUA
)
  desc="cursor.lua does not export XDG_DATA_DIRS/XCURSOR_PATH again when already present (got: $calls)"
  check bash -c '[[ $1 != *XDG_DATA_DIRS* && $1 != *XCURSOR_PATH* && $1 == *XCURSOR_THEME* ]]' _ "$calls"
else
  echo "SKIP: cursor.lua dedupe (lua not installed)"
fi
exit "$fail"
