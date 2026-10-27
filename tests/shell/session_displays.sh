#!/usr/bin/env bash
# ADR-0031: config/hypr/grassfield/displays.lua turns Settings > Displays' data files into hl.monitor rules. Run by a plain
# Lua interpreter against a stub of Hyprland's `hl` table: the kept choices, a running trial in their place, a trial past its
# deadline or with a bad first line ignored, every malformed field refused line by line (the others still apply), the paths
# of a real and of a nested dev session, a rule Hyprland refuses, text that looks like Lua staying text, and the bounds (a trial
# at most 60 s ahead, at most 16 displays, at most 8 KiB read of a file). Needs `lua`.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
if ! command -v lua >/dev/null; then echo "SKIP: no Lua interpreter"; exit 0; fi
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/session-displays.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0

cat >"$tmp/case.lua" <<'LUA'
-- usage: lua case.lua <repo root> <dev 0|1> [refuse]: requires the module once and prints one line per rule, then the problems.
local repo, dev, refuse = arg[1], arg[2] == "1", arg[3]
local rules = {}
hl = { monitor = function(r)
  if refuse and r.output == refuse then error("refused by the stub") end
  rules[#rules + 1] = r
end }
_G.grassfield_dev = dev
package.path = repo .. "/config/hypr/?.lua;" .. package.path
local M = require("grassfield.displays")
for _, r in ipairs(rules) do
  print(string.format("rule %s|%s|%s|%s|%d", r.output, r.mode, r.position, tostring(r.scale), r.transform))
end
print("trial " .. tostring(M.trial))
for _, p in ipairs(M.problems) do print("problem " .. p) end
LUA

T=$'\t'
good1="v1${T}desc:BOE 0x0BCA${T}2880x1800@120.00${T}0x0${T}1.6${T}0"
good2="v1${T}desc:Dell Inc. DELL U2720Q 7XXXX${T}3840x2160@60${T}1800x-200${T}1.5${T}1"
run() { # dev, [refuse]: the output of one parse with the test's environment
  env -i PATH="$PATH" HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" ${XDG_CONFIG_HOME:+XDG_CONFIG_HOME=$XDG_CONFIG_HOME} \
    ${GCH:+GRASSFIELD_CONFIG_HOME=$GCH} ${GSH:+GRASSFIELD_STATE_HOME=$GSH} lua "$tmp/case.lua" "$root" "$@" | grep -v '^grassfield: '
}
check() { # name, output, expected (exact)
  if [[ $2 == "$3" ]]; then echo "PASS: session_displays $1"; else echo "FAIL: session_displays $1"; diff <(echo "$3") <(echo "$2") || true; fail=1; fi
}
reset() { rm -rf "$tmp/home" "$tmp/run" "$tmp/dev" "$tmp/xdg"; mkdir -p "$tmp/home/.config/grassfield" "$tmp/run" "$tmp/dev/config" "$tmp/dev/state" "$tmp/xdg/grassfield"; unset GCH GSH XDG_CONFIG_HOME; }
now=$(date +%s)

reset
check "no file: no rule" "$(run 0)" "trial nil"

reset
printf '%s\n' "# kept choices" "$good1" "" "$good2" >"$tmp/home/.config/grassfield/displays.conf"
check "the kept choices become rules, comments and blank lines skipped" "$(run 0)" "rule desc:BOE 0x0BCA|2880x1800@120.00|0x0|1.6|0
rule desc:Dell Inc. DELL U2720Q 7XXXX|3840x2160@60|1800x-200|1.5|1
trial nil"

reset
{
  echo "$good1"
  echo "v2${T}desc:A${T}1920x1080@60${T}0x0${T}1${T}0"
  echo "v1${T}desc:A${T}1920x1080@60${T}0x0${T}1"
  echo "v1${T}name:A${T}1920x1080@60${T}0x0${T}1${T}0"
  echo "v1${T}desc:${T}1920x1080@60${T}0x0${T}1${T}0"
  printf 'v1\tdesc:A\x01B\t1920x1080@60\t0x0\t1\t0\n'
  echo "v1${T}desc:A${T}preferred${T}0x0${T}1${T}0"
  echo "v1${T}desc:A${T}99999x1080@60${T}0x0${T}1${T}0"
  echo "v1${T}desc:A${T}1920x1080@0${T}0x0${T}1${T}0"
  echo "v1${T}desc:A${T}1920x1080@60${T}auto${T}1${T}0"
  echo "v1${T}desc:A${T}1920x1080@60${T}0x40000${T}1${T}0"
  echo "v1${T}desc:A${T}1920x1080@60${T}0x0${T}9${T}0"
  echo "v1${T}desc:A${T}1920x1080@60${T}0x0${T}auto${T}0"
  echo "v1${T}desc:A${T}1920x1080@60${T}0x0${T}1${T}8"
  echo "v1${T}desc:$(printf 'x%.0s' {1..161})${T}1920x1080@60${T}0x0${T}1${T}0"
  echo "$good2"
} >"$tmp/home/.config/grassfield/displays.conf"
check "every malformed line is refused with its number, the good ones still apply" "$(run 0)" "rule desc:BOE 0x0BCA|2880x1800@120.00|0x0|1.6|0
rule desc:Dell Inc. DELL U2720Q 7XXXX|3840x2160@60|1800x-200|1.5|1
trial nil
problem displays.conf line 2: not six fields of version v1
problem displays.conf line 3: not six fields of version v1
problem displays.conf line 4: bad description
problem displays.conf line 5: bad description
problem displays.conf line 6: bad description
problem displays.conf line 7: bad mode
problem displays.conf line 8: bad mode
problem displays.conf line 9: bad mode
problem displays.conf line 10: bad position
problem displays.conf line 11: bad position
problem displays.conf line 12: bad scale
problem displays.conf line 13: bad scale
problem displays.conf line 14: bad transform
problem displays.conf line 15: bad description"

reset
echo "$good1" >"$tmp/home/.config/grassfield/displays.conf"
printf '%s\n' "trial a1b2 until $((now + 15))" "v1${T}desc:BOE 0x0BCA${T}2880x1800@60.00${T}0x0${T}2${T}0" >"$tmp/run/grassfield-display-trial.conf"
check "a running trial applies in place of the kept choices" "$(run 0)" "rule desc:BOE 0x0BCA|2880x1800@60.00|0x0|2|0
trial a1b2"

printf '%s\n' "trial a1b2 until $((now - 1))" "v1${T}desc:BOE 0x0BCA${T}2880x1800@60.00${T}0x0${T}2${T}0" >"$tmp/run/grassfield-display-trial.conf"
check "a trial past its deadline is ignored" "$(run 0)" "rule desc:BOE 0x0BCA|2880x1800@120.00|0x0|1.6|0
trial nil
problem display trial a1b2 is past its deadline: not applied"

for head in "kept a1b2" "trial a1b2" "trial a-b until $((now + 15))" "trial a1b2 until soon"; do
  printf '%s\n' "$head" "v1${T}desc:BOE 0x0BCA${T}2880x1800@60.00${T}0x0${T}2${T}0" >"$tmp/run/grassfield-display-trial.conf"
  check "a trial whose first line is \"$head\" is ignored" "$(run 0)" "rule desc:BOE 0x0BCA|2880x1800@120.00|0x0|1.6|0
trial nil"
done

printf '%s\n' "trial c3 until $((now + 15))" "v1${T}desc:BOE 0x0BCA${T}2880x1800@60.00${T}0x0${T}2${T}9" "$good2" >"$tmp/run/grassfield-display-trial.conf"
check "a trial's bad line is refused with its line number" "$(run 0)" "rule desc:Dell Inc. DELL U2720Q 7XXXX|3840x2160@60|1800x-200|1.5|1
trial c3
problem display trial line 2: bad transform"

# Paths: a real session reads the runtime directory and ignores a leaked GRASSFIELD_STATE_HOME; the nested session reads
# only its dev state directory. GRASSFIELD_CONFIG_HOME, then XDG_CONFIG_HOME, then ~/.config.
reset
printf '%s\n' "trial r1 until $((now + 15))" "$good2" >"$tmp/run/grassfield-display-trial.conf"
printf '%s\n' "trial d1 until $((now + 15))" "$good1" >"$tmp/dev/state/display-trial.conf"
GSH="$tmp/dev/state"
check "real session: the runtime trial, never the dev one" "$(run 0 | grep '^trial')" "trial r1"
check "nested dev session: the dev trial, never the runtime one" "$(run 1 | grep '^trial')" "trial d1"
unset GSH
check "nested dev session without GRASSFIELD_STATE_HOME: no trial" "$(run 1 | grep '^trial')" "trial nil"
rm "$tmp/run/grassfield-display-trial.conf"
echo "$good1" >"$tmp/home/.config/grassfield/displays.conf"
echo "$good2" >"$tmp/xdg/grassfield/displays.conf"
echo "v1${T}desc:Dev${T}1440x900@60${T}0x0${T}1${T}0" >"$tmp/dev/config/displays.conf"
check "~/.config/grassfield without XDG_CONFIG_HOME" "$(run 0 | head -1)" "rule desc:BOE 0x0BCA|2880x1800@120.00|0x0|1.6|0"
XDG_CONFIG_HOME="$tmp/xdg"
check "XDG_CONFIG_HOME/grassfield" "$(run 0 | head -1)" "rule desc:Dell Inc. DELL U2720Q 7XXXX|3840x2160@60|1800x-200|1.5|1"
GCH="$tmp/dev/config"
check "GRASSFIELD_CONFIG_HOME first" "$(run 0 | head -1)" "rule desc:Dev|1440x900@60|0x0|1|0"

# A rule Hyprland refuses costs only itself; text that looks like Lua is a display name, never code.
reset
printf '%s\n' "$good1" "$good2" >"$tmp/home/.config/grassfield/displays.conf"
out=$(run 0 'desc:BOE 0x0BCA')
check "a refused rule is reported, the next one applies" "$(grep -c '^rule' <<<"$out") $(grep -c 'problem display desc:BOE 0x0BCA: .*refused by the stub' <<<"$out")" "1 1"
printf '%s\n' "v1${T}desc:x\"); os.execute(\"touch $tmp/pwned\") --${T}1920x1080@60${T}0x0${T}1${T}0" >"$tmp/home/.config/grassfield/displays.conf"
out=$(run 0)
check "Lua-looking text stays a display name and runs nothing" "$(head -1 <<<"$out") $([[ -e $tmp/pwned ]] && echo ran || echo inert)" "rule desc:x\"); os.execute(\"touch $tmp/pwned\") --|1920x1080@60|0x0|1|0 inert"

# Bounds, as Settings writes the files: a trial at most 60 s ahead, at most 16 displays, at most 8 KiB read of either file.
reset
echo "$good1" >"$tmp/home/.config/grassfield/displays.conf"
printf '%s\n' "trial a60 until $((now + 60))" "$good2" >"$tmp/run/grassfield-display-trial.conf"
check "a trial 60 s ahead applies" "$(run 0 | grep '^trial')" "trial a60"
for until in $((now + 120)) 999999999999 99999999999999999999999999999999; do
  printf '%s\n' "trial far until $until" "$good2" >"$tmp/run/grassfield-display-trial.conf"
  check "a trial ending more than 60 s ahead ($until) is not applied, the kept choices are" "$(run 0)" "rule desc:BOE 0x0BCA|2880x1800@120.00|0x0|1.6|0
trial nil
problem display trial far ends more than 60 seconds ahead: not applied"
done
rm "$tmp/run/grassfield-display-trial.conf"
for i in $(seq 1 20); do echo "v1${T}desc:Panel $i${T}1920x1080@60${T}$((i * 1920))x0${T}1${T}0"; done >"$tmp/home/.config/grassfield/displays.conf"
out=$(run 0)
check "at most 16 displays apply, the 17th line on is reported" "$(grep -c '^rule' <<<"$out") $(grep '^problem' <<<"$out")" \
  "16 problem displays.conf line 17: more than 16 displays: the rest is not applied"
{ echo "$good1"; printf '#%.0s' $(seq 1 9000); echo; echo "$good2"; } >"$tmp/home/.config/grassfield/displays.conf"
out=$(run 0)
check "a displays.conf longer than 8 KiB: its first 8 KiB are read, the cut line dropped, reported" "$out" "rule desc:BOE 0x0BCA|2880x1800@120.00|0x0|1.6|0
trial nil
problem displays.conf is longer than 8192 bytes: the rest is not read"
head -c 5000000 /dev/zero | tr '\0' 'a' >"$tmp/home/.config/grassfield/displays.conf"
printf '%s\n' "trial big until $((now + 15))" "$good2" >"$tmp/run/grassfield-display-trial.conf"
head -c 5000000 /dev/zero | tr '\0' '\n' >>"$tmp/run/grassfield-display-trial.conf"
start=$EPOCHREALTIME
out=$(run 0)
elapsed=$(awk -v a="$start" -v b="$EPOCHREALTIME" 'BEGIN { print (b - a < 2) ? "bounded" : "slow " (b - a) " s" }')
check "files of 5 MB are read in a bounded time (only their first 8 KiB)" "$elapsed $(grep -c '^rule' <<<"$out") $(grep -c 'longer than 8192 bytes' <<<"$out")" "bounded 1 1"

exit $fail
