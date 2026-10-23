#!/usr/bin/env bash
# The compositor extension after a Hyprland update (ADR-0009 options 1 and 3, "Amendment 2026-10-23"; audit GF-033), without
# a compositor and without building anything:
#   - the ABI string of a Hyprland version.h, computed the same way by packaging/arch/grassfield-compositor-rebuild (bash)
#     and config/hypr/grassfield/compositor.lua (Lua), as Hyprland's PluginAPI.hpp computes it (the formula is checked in
#     the installed header when present);
#   - the session's choice (offline part of the C2 mismatch test, plan 1.8): the packaged build, the user's build, and on a
#     stamp mismatch NO build (degraded mode) plus the notice path; Hyprland updated under the session;
#   - the user rebuild: refuses root, refuses symlinks (cache directories, the build's result), installs into the user's
#     cache with 0700 directories and the stamp last, the --session notice (setting off: the command; on: the build, the
#     load into the running Hyprland when its ABI matches, else log in again), a missing toolchain.
# Layer logic (scripts/dev/test.sh). Writes only under a temporary directory; hyprctl and notify-send are replaced.
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
#define GIT_TAG            "v0.57.0"
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
other=fedcba9876543210fedcba9876543210fedcba98_aq_0.15_hu_0.14_hg_0.5_hc_0.1_hlg_0.6
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
packaged_abi=/usr/lib/grassfield/grassfield-compositor.abi
user_abi_of() { echo "/home/u/.cache/grassfield/compositor/$1/grassfield-compositor.abi"; }
choose() { # <packaged stamp|-> <user build ABI dir|-> <user stamp|-> <signature|-> [loaded env path]: prints "<why> <path>"
  luamod "
    local stamps = {}
    if '$1' ~= '-' then stamps['$packaged_abi'] = '$1' end
    if '$2' ~= '-' then stamps['/home/u/.cache/grassfield/compositor/$2/grassfield-compositor.abi'] = '$3' end
    if '${5:-}' ~= '' then stamps[('${5:-}'):gsub('%.so\$', '.abi')] = '$3' end
    local f = io.open('$tmp/version.h'); local vh = f:read('a'); f:close()
    local vars = { HOME = '/home/u', HYPRLAND_INSTANCE_SIGNATURE = ('$4' ~= '-') and '$4' or nil, GRASSFIELD_COMPOSITOR_PLUGIN = '${5:-}' }
    local env = {
      reader = function(p) if p == c.version_h then return vh end; local s = stamps[p]; if s then return s .. '\nsource 1\n' end; return nil end,
      exists = function(p) return stamps[(p:gsub('%.so\$', '.abi'))] ~= nil end,
      getenv = function(n) return vars[n] end,
    }
    local path, why = c.choose(env); print(why .. ' ' .. tostring(path))"
}
sig=0123456789abcdef0123456789abcdef01234567_1792717195_16028387
userpath=/home/u/.cache/grassfield/compositor/$want/grassfield-compositor.so
expect "choice: the packaged build matches" "$(choose "$want" "$want" "$want" "$sig")" "packaged /usr/lib/grassfield/grassfield-compositor.so"
expect "choice: the user's build matches" "$(choose "$other" "$want" "$want" "$sig")" "user $userpath"
expect "choice: mismatch -> nothing is loaded (degraded mode, notice)" "$(choose "$other" - - "$sig")" "no-match nil"
expect "choice: a user build with a wrong stamp is not loaded" "$(choose "$other" "$want" "$other" "$sig")" "no-match nil"
expect "choice: no extension installed" "$(choose - - - "$sig")" "none nil"
expect "choice: a packaged build without a stamp (older package) is not loaded blind" "$(choose "" - - "$sig")" "no-match nil"
expect "choice: no signature: the installed headers decide" "$(choose "$other" "$want" "$want" -)" "user $userpath"
# Hyprland updated under the running session (a config reload): the running commit is the old one.
old_sig=fedcba9876543210fedcba9876543210fedcba98_1792717195_1
expect "choice: updated under the session: the packaged build for the running commit" "$(choose "$other" "$want" "$want" "$old_sig")" "packaged /usr/lib/grassfield/grassfield-compositor.so"
expect "choice: updated under the session: the build loaded at login stays" \
  "$(choose "$want" - "$other" "$old_sig" /home/u/.cache/grassfield/compositor/$other/grassfield-compositor.so)" "loaded /home/u/.cache/grassfield/compositor/$other/grassfield-compositor.so"
expect "choice: updated under the session, nothing for the running commit: nothing until the next login" "$(choose "$want" - - "$old_sig")" "updated nil"
expect "lua: the running commit" "$(luamod "print(c.running_commit('efb50993780079460b0cbed1363e2166a2de1d9f_1792717195_16028387'))")" "efb50993780079460b0cbed1363e2166a2de1d9f"
expect "lua: no commit in a bad signature" "$(luamod "print(c.running_commit('nothing'), c.running_commit(nil))")" "nil	nil"
expect "lua: XDG_CACHE_HOME wins" "$(luamod "print(c.user_build('A', function(n) return ({XDG_CACHE_HOME = '/x', HOME = '/h'})[n] end))")" "/x/grassfield/compositor/A/grassfield-compositor.so"

# ---- the user rebuild on temporary directories ----
lib=$tmp/lib src=$tmp/src tools=$tmp/tools cache=$tmp/cache conf=$tmp/conf notes=$tmp/notes.log
mkdir -p "$lib" "$src" "$tools" "$conf"
printf 'cmake_minimum_required(VERSION 3.27)\n' >"$src/CMakeLists.txt"
echo "0.5.0-1" >"$src/VERSION"
printf 'plugin\n' >"$lib/grassfield-compositor.so"
echo "$other" >"$lib/grassfield-compositor.abi"
for t in cmake g++ make pkg-config hyprwayland-scanner; do printf '#!/bin/sh\nexit 0\n' >"$tools/$t"; chmod +x "$tools/$t"; done
printf '#!/bin/sh\necho "$@" >>"%s/hyprctl.log"\necho ok\n' "$tmp" >"$tmp/hyprctl-ok"
printf '#!/bin/sh\necho "error: plugin refused"\nexit 1\n' >"$tmp/hyprctl-no"
chmod +x "$tmp/hyprctl-ok" "$tmp/hyprctl-no"
run() { # [env ...] -- args: the script with the test environment
  env GF_VERSION_H="$tmp/version.h" GF_LIB_DIR="$lib" GF_SRC_DIR="$src" GF_TOOLS_PATH="$tools" XDG_CACHE_HOME="$cache" \
    GRASSFIELD_CONFIG_HOME="$conf" GF_NOTIFY_LOG="$notes" GF_TEST_FAKE_BUILD=1 HYPRLAND_INSTANCE_SIGNATURE= "$@" >"$tmp/out" 2>&1
}
dest=$cache/grassfield/compositor/$want

run GF_TEST_UID=0 "$script"; rc=$?
expect "root: refused" "$rc $(grep -c 'refusing to run as root' "$tmp/out")" "1 1"
[[ ! -e $cache ]] && pass "root: nothing written" || bad "root: nothing written"
run GF_TEST_UID=0 "$script" --session; rc=$?
expect "root: --session refused too" "$rc" 1
expect "root: --print-abi still answers (it only reads)" "$(GF_TEST_UID=0 "$script" --print-abi "$tmp/version.h")" "$want"
if command -v fakeroot >/dev/null; then
  # makepkg's package() runs under fakeroot (uid 0): the package's stamp must still be written; a build never runs there,
  # and the test override cannot lift the refusal.
  expect "fakeroot: --print-abi (the PKGBUILD's stamp)" "$(fakeroot -- "$script" --print-abi "$tmp/version.h")" "$want"
  run fakeroot -- env GF_TEST_UID=1000 "$script"; rc=$?
  expect "fakeroot: a build is refused, GF_TEST_UID cannot lift it" "$rc $(grep -c 'refusing to run as root' "$tmp/out")" "1 1"
fi

run "$script" --check; rc=$?
expect "--check: no build matches -> exit 1" "$rc" 1

run "$script"; rc=$?
expect "build: exit 0" "$rc" 0
[[ -f $dest/grassfield-compositor.so && ! -L $dest/grassfield-compositor.so ]] && pass "build: installed in the user's cache" || bad "build: installed in the user's cache ($(cat "$tmp/out"))"
expect "build: its stamp" "$(head -n 1 "$dest/grassfield-compositor.abi" 2>/dev/null) / $(sed -n 2p "$dest/grassfield-compositor.abi" 2>/dev/null)" "$want / source 0.5.0-1"
expect "build: 0700 directories" "$(stat -c %a "$cache/grassfield" "$cache/grassfield/compositor" "$dest" | tr '\n' ' ')" "700 700 700 "
expect "build: no temporary file left" "$(find "$cache/grassfield/compositor" -name '.*' -not -name .lock | wc -l)" 0
grep -q "Log out and back in" "$tmp/out" && pass "build: says how to use it" || bad "build: says how to use it"
run "$script" --check; rc=$?
expect "--check: the user's build matches -> exit 0" "$rc $(tail -n 1 "$tmp/out")" "0 match: $dest/grassfield-compositor.so"
run "$script"; rc=$?
expect "build again: nothing to build" "$rc $(grep -c 'nothing to build' "$tmp/out")" "0 1"

# Symlinks are refused: a cache directory, a planted plugin, the build's own result.
rm -rf "$cache"
mkdir -p "$cache" "$tmp/elsewhere"
ln -s "$tmp/elsewhere" "$cache/grassfield"
run "$script"; rc=$?
expect "symlinked cache directory: refused" "$rc $(grep -c 'is a symlink' "$tmp/out")" "1 1"
[[ -z $(ls -A "$tmp/elsewhere") ]] && pass "symlinked cache directory: nothing written through it" || bad "symlinked cache directory: nothing written through it"
rm -f "$cache/grassfield"
mkdir -p "$dest" && chmod 700 "$cache/grassfield" "$cache/grassfield/compositor" "$dest"
ln -s "$lib/grassfield-compositor.so" "$dest/grassfield-compositor.so"
echo "$want" >"$dest/grassfield-compositor.abi"
run "$script" --check; rc=$?
expect "a planted symlink is not a build" "$rc" 1
rm -rf "$cache"
run GF_TEST_FAKE_BUILD=symlink "$script"; rc=$?
expect "the build's result is a symlink: refused" "$rc $(grep -c 'not a regular file' "$tmp/out")" "1 1"
[[ ! -e $dest/grassfield-compositor.so ]] && pass "the build's result is a symlink: nothing installed" || bad "the build's result is a symlink: nothing installed"

# --session, the setting off: one notice with the Hyprland version and the command; nothing built.
rm -rf "$cache" "$notes"
run "$script" --session; rc=$?
expect "--session, setting off: exit 0, one notice" "$rc $(wc -l <"$notes")" "0 1"
grep -q "critical.*Hyprland v0.57.0.*Run grassfield-compositor-rebuild in a terminal" "$notes" && pass "--session, setting off: the notice names the version and the command" || bad "--session, setting off: the notice ($(cat "$notes"))"
[[ ! -e $dest ]] && pass "--session, setting off: nothing built" || bad "--session, setting off: nothing built"

# --session, the setting on: built, then loaded into the running Hyprland when its commit is the build's.
printf '{"windows": {"rebuildExtension": true}}\n' >"$conf/grassfield.json"
rm -f "$notes" "$tmp/hyprctl.log"
run HYPRLAND_INSTANCE_SIGNATURE="$sig" GF_HYPRCTL="$tmp/hyprctl-ok" "$script" --session; rc=$?
expect "--session, setting on: exit 0, built" "$rc $([[ -f $dest/grassfield-compositor.so ]] && echo built)" "0 built"
expect "--session, setting on: loaded into the running Hyprland" "$(cat "$tmp/hyprctl.log" 2>/dev/null)" "plugin load $dest/grassfield-compositor.so"
grep -q "titlebars, minimize and global menus are back" "$notes" && pass "--session, setting on: says it is back" || bad "--session, setting on: says it is back ($(cat "$notes"))"
rm -rf "$cache" "$notes" "$tmp/hyprctl.log"
run HYPRLAND_INSTANCE_SIGNATURE="$old_sig" GF_HYPRCTL="$tmp/hyprctl-ok" "$script" --session; rc=$?
[[ ! -e $tmp/hyprctl.log ]] && pass "--session: another Hyprland runs: not loaded" || bad "--session: another Hyprland runs: not loaded"
grep -q "Log out and back in" "$notes" && pass "--session: another Hyprland runs: log in again" || bad "--session: another Hyprland runs: log in again ($(cat "$notes"))"
rm -rf "$cache" "$notes"
run HYPRLAND_INSTANCE_SIGNATURE="$sig" GF_HYPRCTL="$tmp/hyprctl-no" "$script" --session; rc=$?
grep -q "Log out and back in" "$notes" && pass "--session: Hyprland refuses the load: log in again" || bad "--session: Hyprland refuses the load: log in again"
rm -rf "$cache" "$notes"
rm -f "$tools/hyprwayland-scanner"
run "$script" --session; rc=$?
expect "--session: missing toolchain: exit 1" "$rc" 1
grep -q "critical.*could not be built for Hyprland v0.57.0" "$notes" && pass "--session: missing toolchain: says so" || bad "--session: missing toolchain: says so ($(cat "$notes"))"
printf '#!/bin/sh\nexit 0\n' >"$tools/hyprwayland-scanner" && chmod +x "$tools/hyprwayland-scanner"
printf '{"windows": {"rebuildExtension": "yes"}}\n' >"$conf/grassfield.json"
rm -rf "$cache" "$notes"
run "$script" --session; rc=$?
[[ ! -e $dest ]] && pass "--session: a setting that is not exactly true builds nothing" || bad "--session: a setting that is not exactly true builds nothing"

# The packaged build matches: nothing to do in any mode.
echo "$want" >"$lib/grassfield-compositor.abi"
rm -rf "$cache" "$notes"
run "$script" --session; rc=$?
expect "packaged build matches: --session says nothing" "$rc $([[ -e $notes ]] && echo notice || echo quiet)" "0 quiet"
run "$script" --check; rc=$?
expect "packaged build matches: --check exit 0" "$rc $(tail -n 1 "$tmp/out")" "0 match: $lib/grassfield-compositor.so"

run "$script" --bogus; rc=$?
expect "unknown option: usage, exit 2" "$rc" 2

((fail == 0)) && echo "PASS: compositor_rebuild"
exit "$fail"
