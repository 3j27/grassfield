#!/usr/bin/env bash
# Gate C2, a mismatched extension (audit plan 1.8, 12-test-evidence-register §7 test 3; ADR-0009 "Amendment
# 2026-10-23"): the nested half of the mismatch test. The offline half (the session never picks a build stamped for
# another Hyprland) is tests/shell/compositor_rebuild.sh; this one loads a mismatched build BY HAND, the case the loader
# cannot prevent (a stamp that lies, a manual load).
#
# The mismatched build: the real plugin compiled from this tree with Hyprland's version.h forced to another commit (a
# header given with -include: version.h is #pragma once, so every translation unit, PluginAPI.hpp's
# __hyprland_api_get_client_hash included, sees that commit). Built once into .dev/abi-mismatch/ (a few minutes, at most
# 3 compilers), then reused; ninja rebuilds it when the sources or the installed headers change.
#
# Checks: Hyprland alive after the load; the plugin refuses itself (Hyprland's plugin list shows it "[inactive: Hyprland
# version mismatch]", its log says "ABI mismatch"); no gfc/1 command or capability (the shell stays "ready degraded");
# exactly the one degraded notice the shell posted before (no second one, notification history unchanged); menu bar and
# Dock mapped; minimize falls back to the shell's (tests/compositor/genie.sh c2); the unload is clean (Hyprland alive,
# the plugin gone from the list).
#
# Usage (bare command; NESTED only): start the session without the extension, then run this:
#   scripts/dev/nested-up.sh --no-plugin
#   tests/compositor/abi_mismatch.sh
# Only this tree's nested instance (scripts/dev/pidfile.sh dev_nested_target refuses the owner's); the load and the
# unload go through scripts/nestctl. Exit: 0 PASS, 1 FAIL, 2 usage or environment.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
work=$dev/abi-mismatch
version_h=${GF_VERSION_H:-/usr/include/hyprland/src/version.h}
foreign=0000000000000000000000000000000000000000

# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 2
sig=$DEV_NESTED_SIG hypr_pid=$DEV_NESTED_PID
shell_pid=$(dev_live_pid "$dev/shell.pid" || true)
[[ -n $shell_pid ]] && kill -0 "$shell_pid" 2>/dev/null || { echo "abi_mismatch: grassfield-shell is not running (scripts/dev/shell-run.sh)" >&2; exit 2; }
for tool in jq cmake ninja; do
  command -v "$tool" >/dev/null || { echo "abi_mismatch: $tool is needed" >&2; exit 2; }
done
[[ -r $version_h ]] || { echo "abi_mismatch: no Hyprland headers ($version_h)" >&2; exit 2; }

nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; }
ipc() { timeout 10 "$root/tests/visual/ipc.sh" "$@"; }
plugins() { nestctl -j plugin list 2>/dev/null | jq -c '[.[]? | select(.name == "grassfield-compositor")]' 2>/dev/null; }
notices() { grep -c 'degraded notice posted' "$dev/shell.log" 2>/dev/null; }
history() { ipc notifications status 2>/dev/null | grep -o 'history=[0-9]*'; }
layer_mapped() { nestctl -j layers 2>/dev/null | jq -e --arg n "$1" '[.. | objects | select(.namespace? == $n)] | length > 0' >/dev/null; }
alive() { kill -0 "$hypr_pid" 2>/dev/null && nestctl -j version >/dev/null 2>&1; }

mkdir -p "$work"
log=$work/run-$(date +%Y%m%d-%H%M%S).log
fail=0
say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$log"; }
check() { # <name> <0|1> [detail]
  if [[ $2 == 0 ]]; then say "PASS: $1${3:+ ($3)}"; else say "FAIL: $1${3:+ ($3)}"; fail=1; fi
}

# ---- preconditions: no extension loaded, the shell degraded and its notice posted ----
[[ $(plugins) == "[]" ]] || { echo "abi_mismatch: grassfield-compositor is loaded (start the session with scripts/dev/nested-up.sh --no-plugin)" >&2; exit 2; }
for _ in $(seq 1 50); do
  [[ $(ipc capabilities status 2>/dev/null) == "ready degraded" && $(notices) -ge 1 ]] && break
  sleep 0.5
done
[[ $(ipc capabilities status 2>/dev/null) == "ready degraded" ]] || { echo "abi_mismatch: the shell is not in degraded mode ($(ipc capabilities status 2>&1))" >&2; exit 2; }
[[ $(notices) -ge 1 ]] || { echo "abi_mismatch: the shell has not posted its degraded notice yet (helloAbsentMs)" >&2; exit 2; }

# ---- the mismatched build ----
say "building the mismatched extension (log: $work/build.log)"
printf '%s\n' '// tests/compositor/abi_mismatch.sh: Hyprland'"'"'s version.h with another commit (forced first include).' \
  '#pragma once' "#include \"$version_h\"" '#undef GIT_COMMIT_HASH' "#define GIT_COMMIT_HASH \"$foreign\"" >"$work/foreign-abi.h.new"
cmp -s "$work/foreign-abi.h.new" "$work/foreign-abi.h" 2>/dev/null && rm -f "$work/foreign-abi.h.new" || mv -f "$work/foreign-abi.h.new" "$work/foreign-abi.h"
if ! { cmake -S "$root/compositor" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DGRASSFIELD_BUILD_TESTS=OFF \
    -DGRASSFIELD_OUTPUT_DIR="$work/out" -DCMAKE_CXX_FLAGS="-include $work/foreign-abi.h" >"$work/build.log" 2>&1 \
    && nice -n 10 cmake --build "$work/build" --target grassfield-compositor --parallel 3 >>"$work/build.log" 2>&1; }; then
  echo "abi_mismatch: the mismatched build failed (see $work/build.log)" >&2
  exit 2
fi
so=$work/out/grassfield-compositor.so
real_commit=$(sed -n 's/^#define[[:space:]]*GIT_COMMIT_HASH[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$version_h")
# No pipe into grep -q under pipefail: grep stops at the first match and the writer dies of SIGPIPE (status 141).
grep -qaF -- "$foreign" "$so" && ! grep -qaF -- "$real_commit" "$so"
check "the build carries the foreign commit, not the running one" $? "$foreign"

# The extension is unloaded at exit whatever happens: the next scenario expects the session as it found it.
loaded=""
trap '[[ -n $loaded ]] && nestctl plugin unload "$so" >/dev/null 2>&1' EXIT

n0=$(notices) h0=$(history)
say "before the load: degraded notices $n0, ${h0:-history unknown}"

# ---- the load ----
out=$(nestctl plugin load "$so" 2>&1)
loaded=1
say "plugin load: $out"
sleep 2
alive
check "Hyprland alive after the load" $? "pid $hypr_pid"
entry=$(plugins)
[[ $(jq -r '.[0].description // ""' <<<"$entry") == *"[inactive: Hyprland version mismatch]"* ]]
check "the extension refuses itself (plugin list)" $? "$entry"
hyprlog=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/hyprland.log
grep -q "ABI mismatch: Hyprland .* vs plugin built for $foreign" "$hyprlog" 2>/dev/null
check "its log names both ABIs" $? "$(grep -m1 -o 'ABI mismatch[^;]*' "$hyprlog" 2>/dev/null)"
features=$(nestctl -j grassfield 2>/dev/null | jq -r '.features // empty | join(",")' 2>/dev/null)
[[ -z $features ]]
check "no gfc/1 command or feature registered" $? "${features:-none}"
sleep 3
[[ $(ipc capabilities status 2>/dev/null) == "ready degraded" ]]
check "the shell stays degraded" $? "$(ipc capabilities status 2>&1)"
[[ $(notices) == "$n0" && $(history) == "$h0" ]]
check "exactly the one degraded notice (none added)" $? "notices $(notices), $(history)"
layer_mapped grassfield-menubar
check "menu bar mapped" $?
layer_mapped grassfield-dock
check "Dock mapped" $?

# ---- minimize falls back (the shell's special:minimized), with the mismatched extension loaded ----
say "minimize fallback: tests/compositor/genie.sh c2"
"$root/tests/compositor/genie.sh" c2 >>"$log" 2>&1
rc=$?
if ((rc == 2)); then
  say "NOT VERIFIED: minimize fallback (genie.sh c2 could not run, see $log)"
  ((fail == 0)) && fail=2
else
  check "minimize falls back to the shell (genie.sh c2)" "$((rc != 0))"
fi

# ---- the unload ----
out=$(nestctl plugin unload "$so" 2>&1)
loaded=""
say "plugin unload: $out"
sleep 1
alive
check "Hyprland alive after the unload" $? "pid $hypr_pid"
[[ $(plugins) == "[]" ]]
check "the extension is gone from the plugin list" $?
[[ $(notices) == "$n0" ]]
check "still one degraded notice" $? "notices $(notices)"

if ((fail == 0)); then say "abi_mismatch: PASS"; elif ((fail == 2)); then say "abi_mismatch: INCOMPLETE"; else say "abi_mismatch: FAIL"; fi
say "abi_mismatch: log $log"
exit "$fail"
