#!/usr/bin/env bash
# The compositor extension's rebuild path (ADR-0009 amendment 2026-10-23, audit GF-033), without building anything:
#   - the ABI string of a Hyprland version.h, computed the same way by packaging/arch/grassfield-compositor-rebuild (bash)
#     and config/hypr/grassfield/compositor.lua (Lua), as Hyprland's PluginAPI.hpp computes it (the formula is checked in
#     the installed header when present);
#   - the session's choice of a build (packaged, rebuilt, none matching, Hyprland updated under the session);
#   - the script's decisions on temporary directories: packaged build matches, rebuild (a fake build), rebuilt build
#     already current, new sources, missing toolchain, no sources, no headers, the hook never failing, --check, --clean.
# Layer logic (scripts/dev/test.sh). Writes only under a temporary directory.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
script=$root/packaging/arch/grassfield-compositor-rebuild
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/compositor-rebuild.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
pass() { echo "PASS: compositor_rebuild: $1"; }
bad() { echo "FAIL: compositor_rebuild: $1"; fail=1; }
expect() { if [[ $2 == "$3" ]]; then pass "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

command -v lua >/dev/null || { echo "SKIP: compositor_rebuild: lua is not installed"; exit 0; }
luamod() { # <lua chunk using `c` (the module)>
  lua -e "package.path = '$root/config/hypr/?.lua;' .. package.path; local c = require('grassfield.compositor'); $1"
}

# ---- the ABI string ----
cat >"$tmp/version.h" <<'EOF'
#pragma once
#define GIT_COMMIT_HASH    "0123456789abcdef0123456789abcdef01234567"
#define GIT_BRANCH         "v0.57.0"
#define AQUAMARINE_VERSION "0.16.2"
// clang-format off
#define AQUAMARINE_VERSION_MAJOR 0
#define AQUAMARINE_VERSION_MINOR 16
// clang-format on
#define HYPRLANG_VERSION     "0.7.0"
#define HYPRUTILS_VERSION    "0.15.10"
#define HYPRCURSOR_VERSION   "0.1.13"
#define HYPRGRAPHICS_VERSION "1"
EOF
want=0123456789abcdef0123456789abcdef01234567_aq_0.16_hu_0.15_hg_1_hc_0.1_hlg_0.7
expect "bash: the ABI of a version.h" "$("$script" --print-abi "$tmp/version.h")" "$want"
expect "lua: the same ABI" "$(luamod "local f = io.open('$tmp/version.h'); print(c.abi(f:read('a')))")" "$want"
grep -v HYPRLANG_VERSION "$tmp/version.h" >"$tmp/partial.h"
"$script" --print-abi "$tmp/partial.h" >/dev/null 2>&1 && bad "bash: a missing field is an error" || pass "bash: a missing field is an error"
expect "lua: a missing field gives nil" "$(luamod "local f = io.open('$tmp/partial.h'); print(c.abi(f:read('a')))")" "nil"
real=/usr/include/hyprland/src/version.h
if [[ -r $real ]]; then
  expect "bash and lua agree on the installed Hyprland" "$("$script" --print-abi "$real")" "$(luamod "local f = io.open('$real'); print(c.abi(f:read('a')))")"
fi
api=/usr/include/hyprland/src/plugins/PluginAPI.hpp
if [[ -r $api ]]; then
  formula=$(tr -d ' \n' <"$api")
  [[ $formula == *'GIT_COMMIT_HASH}+"_aq_"+stripPatch(AQUAMARINE_VERSION)+"_hu_"+stripPatch(HYPRUTILS_VERSION)+"_hg_"+stripPatch(HYPRGRAPHICS_VERSION)+"_hc_"+stripPatch(HYPRCURSOR_VERSION)+"_hlg_"+stripPatch(HYPRLANG_VERSION)'* ]] \
    && pass "Hyprland's PluginAPI.hpp still computes the hash this way" \
    || bad "Hyprland's PluginAPI.hpp computes its client hash differently: update abi_of and compositor.lua"
fi

# ---- the session's choice (compositor.lua) ----
choose() { # <packaged stamp|-> <rebuilt stamp|-> <signature|false>: prints "<why> <path>"
  luamod "
    local stamps = { ['/usr/lib/grassfield/grassfield-compositor.abi'] = '$1', ['/var/lib/grassfield/compositor/grassfield-compositor.abi'] = '$2' }
    local f = io.open('$tmp/version.h'); local vh = f:read('a'); f:close()
    local env = {
      reader = function(p) if p == c.version_h then return vh end; local s = stamps[p]; if s and s ~= '-' then return s .. '\nsource 1\n' end; return nil end,
      exists = function(p) local s = stamps[(p:gsub('%.so\$', '.abi'))]; return s ~= nil and s ~= '-' end,
      signature = $3,
    }
    local path, why = c.choose(env); print(why .. ' ' .. tostring(path))"
}
other=fedcba9876543210fedcba9876543210fedcba98_aq_0.15_hu_0.14_hg_0.5_hc_0.1_hlg_0.6
sig="'0123456789abcdef0123456789abcdef01234567_1792717195_16028387'"
expect "choice: the packaged build matches" "$(choose "$want" "$other" "$sig")" "packaged /usr/lib/grassfield/grassfield-compositor.so"
expect "choice: the rebuilt build matches" "$(choose "$other" "$want" "$sig")" "rebuilt /var/lib/grassfield/compositor/grassfield-compositor.so"
expect "choice: none matches -> the packaged one (it refuses and notifies)" "$(choose "$other" "$other" "$sig")" "no-match /usr/lib/grassfield/grassfield-compositor.so"
expect "choice: no packaged build, the rebuilt one does not match" "$(choose - "$other" "$sig")" "none nil"
expect "choice: a packaged build without a stamp (older package) is loaded as before" "$(choose - - false)" "none nil"
expect "choice: no signature: the installed headers decide" "$(choose "$other" "$want" false)" "rebuilt /var/lib/grassfield/compositor/grassfield-compositor.so"
# Hyprland updated under the running session (a config reload): the running commit is the old one, the build for it stays.
old_sig="'fedcba9876543210fedcba9876543210fedcba98_1792717195_1'"
expect "choice: Hyprland updated under the session: the build for the running Hyprland" "$(choose "$other" "$want" "$old_sig")" "packaged /usr/lib/grassfield/grassfield-compositor.so"
expect "lua: the running commit" "$(luamod "print(c.running_commit('efb50993780079460b0cbed1363e2166a2de1d9f_1792717195_16028387'))")" "efb50993780079460b0cbed1363e2166a2de1d9f"
expect "lua: no commit in a bad signature" "$(luamod "print(c.running_commit('nothing'), c.running_commit(nil))")" "nil	nil"
expect "lua: strip_patch" "$(luamod "print(c.strip_patch('0.15.0'), c.strip_patch('1'), c.strip_patch('0.1'))")" "0.15	1	0"

# ---- the script on temporary directories ----
lib=$tmp/lib state=$tmp/state src=$tmp/src tools=$tmp/tools
mkdir -p "$lib" "$src" "$tools"
printf 'cmake_minimum_required(VERSION 3.27)\n' >"$src/CMakeLists.txt"
echo "0.5.0-1" >"$src/VERSION"
printf 'plugin\n' >"$lib/grassfield-compositor.so"
for t in cmake g++ make pkg-config hyprwayland-scanner; do printf '#!/bin/sh\nexit 0\n' >"$tools/$t"; chmod +x "$tools/$t"; done
run() { GF_VERSION_H=$tmp/version.h GF_LIB_DIR=$lib GF_STATE_DIR=$state GF_SRC_DIR=$src GF_TOOLS_PATH=$tools GF_TEST_FAKE_BUILD=1 "$script" "$@" >"$tmp/out" 2>&1; }
status() { sed -n "s/^$1=//p" "$state/status" 2>/dev/null; }

echo "$want" >"$lib/grassfield-compositor.abi"
mkdir -p "$state" && printf 'stale\n' >"$state/grassfield-compositor.so" && printf 'old\n' >"$state/grassfield-compositor.abi"
run; rc=$?
expect "packaged matches: exit 0" "$rc" 0
expect "packaged matches: status" "$(status result)" packaged
[[ ! -e $state/grassfield-compositor.so ]] && pass "packaged matches: a stale rebuilt build is removed" || bad "packaged matches: a stale rebuilt build is removed"

echo "$other" >"$lib/grassfield-compositor.abi"
run; rc=$?
expect "mismatch: rebuilt, exit 0" "$rc" 0
expect "mismatch: status" "$(status result) $(status reason)" "rebuilt built"
expect "mismatch: the rebuilt build's stamp" "$(head -n 1 "$state/grassfield-compositor.abi") / $(sed -n 2p "$state/grassfield-compositor.abi")" "$want / source 0.5.0-1"
[[ -x $state/grassfield-compositor.so ]] && pass "mismatch: the rebuilt build is installed" || bad "mismatch: the rebuilt build is installed"
grep -q "log out and back in" "$tmp/out" && pass "mismatch: the result is said" || bad "mismatch: the result is said ($(cat "$tmp/out"))"
run; rc=$?
expect "rebuilt build current: no new build" "$rc $(status result) $(status reason)" "0 rebuilt match"
echo "0.5.0-2" >"$src/VERSION"
run; rc=$?
expect "new sources: built again" "$rc $(status reason) $(sed -n 2p "$state/grassfield-compositor.abi")" "0 built source 0.5.0-2"

rm -f "$state/grassfield-compositor.so" "$state/grassfield-compositor.abi"
rm -f "$tools/hyprwayland-scanner"
run; rc=$?
expect "missing toolchain: exit 1" "$rc" 1
expect "missing toolchain: status" "$(status result) $(status reason)" "failed missing-toolchain: hyprwayland-scanner"
run --hook; rc=$?
expect "missing toolchain: the hook never fails the transaction" "$rc" 0
grep -q "titlebars, minimize and global menus stay off" "$tmp/out" && pass "missing toolchain: the hook says what is off" || bad "missing toolchain: the hook says what is off"
printf '#!/bin/sh\nexit 0\n' >"$tools/hyprwayland-scanner" && chmod +x "$tools/hyprwayland-scanner"

mv "$src/CMakeLists.txt" "$src/CMakeLists.off"
run; rc=$?
expect "no sources: failed" "$rc $(status result) $(status reason)" "1 failed no-sources"
mv "$src/CMakeLists.off" "$src/CMakeLists.txt"

GF_VERSION_H=$tmp/none.h GF_LIB_DIR=$lib GF_STATE_DIR=$state GF_SRC_DIR=$src GF_TOOLS_PATH=$tools GF_TEST_FAKE_BUILD=1 "$script" --hook >"$tmp/out" 2>&1; rc=$?
expect "no Hyprland headers: hook exit 0, status unavailable" "$rc $(status result)" "0 unavailable"

run --check; rc=$?
expect "--check: none matches -> exit 1" "$rc" 1
run; run --check; rc=$?
expect "--check: the rebuilt build matches -> exit 0" "$rc $(tail -n 1 "$tmp/out")" "0 match: rebuilt"
run --clean; rc=$?
[[ $rc == 0 && ! -e $state ]] && pass "--clean removes the build made here and its status" || bad "--clean removes the build made here and its status (rc $rc)"

if [[ $(id -u) != 0 ]]; then
  "$script" --hook >"$tmp/out" 2>&1; rc=$?
  expect "not root: the hook exits 0 and says so" "$rc $(grep -c 'run as root' "$tmp/out")" "0 1"
  "$script" >/dev/null 2>&1; rc=$?
  expect "not root: a manual run fails" "$rc" 1
fi
"$script" --bogus >/dev/null 2>&1; rc=$?
expect "unknown option: usage, exit 2" "$rc" 2

((fail == 0)) && echo "PASS: compositor_rebuild"
exit "$fail"
