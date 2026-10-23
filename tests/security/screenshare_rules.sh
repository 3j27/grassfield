#!/usr/bin/env bash
# GF-AUDIT-001 SEC-01 / GF-028: the Grassfield session hides from screen sharing and screencopy every window Omarchy
# hides (`no_screen_share` rules of /usr/share/omarchy/default/hypr/apps/*.lua: 1Password, Bitwarden, ...), by reading
# Omarchy's own rule files (config/hypr/grassfield/privacy.lua). Evaluates privacy.lua with plain `lua` (the Lua 5.5 of
# Hyprland 0.56) and a recording `hl`:
#   omarchy    the installed Omarchy: at least one Grassfield rule per `no_screen_share = true` in Omarchy's files
#              (counted by grep, an independent oracle), the three known password-manager matches among them (SKIP
#              without Omarchy)
#   fixture    a fake Omarchy tree: a new protected app is picked up, table matches kept, other rules ignored, a file
#              that calls os/io stops there without running anything (no marker file), a broken file is skipped; the
#              built-in matches are added anyway, so a 1password.lua that stops before its rule still protects 1Password
#   builtin    no Omarchy rule readable: the built-in password-manager matches apply
#   wiring     core.lua (loaded by session.lua and dev.lua) requires grassfield.privacy
# The nested proof (a window with app_id Bitwarden is black in a capture) is tests/security/lock_privacy.sh `screenshare`.
# Plain shell test: prints PASS/FAIL, exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
fail=0
pass() { echo "PASS: screenshare $*"; }
bad() { echo "FAIL: screenshare $*"; fail=1; }
if ! command -v lua >/dev/null; then
  echo "SKIP: screenshare rules (lua not installed)"
  exit 0
fi
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/screenshare.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# Prints "source <omarchy|builtin>", then one line per applied rule: "<name>|<no_screen_share>|<sorted match>".
cat >"$tmp/run.lua" <<'LUA'
local applied = {}
hl = { window_rule = function(rule) applied[#applied + 1] = rule end }
local M = dofile(arg[1])
print("source " .. M.source)
for _, rule in ipairs(applied) do
  local keys = {}
  for k in pairs(rule.match) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(rule.match[k]) end
  print(rule.name .. "|" .. tostring(rule.no_screen_share) .. "|" .. table.concat(parts, ";"))
end
LUA
run() { # <OMARCHY_PATH>: evaluates privacy.lua there (its prints go to stdout too)
  (cd "$tmp" && env OMARCHY_PATH="$1" lua "$tmp/run.lua" "$root/config/hypr/grassfield/privacy.lua")
}

# --- omarchy: the installed rule set ---
apps=/usr/share/omarchy/default/hypr/apps
if [[ -d $apps ]]; then
  out=$(run /usr/share/omarchy)
  want=$(cat "$apps"/*.lua | grep -c 'no_screen_share = true' || true)
  got=$(grep -c '^gf-no-screen-share-[0-9]*|true|' <<<"$out" || true)
  [[ $out == *"source omarchy"* ]] && pass "omarchy: rules read from Omarchy's files" || bad "omarchy: source is not Omarchy: $out"
  ((want > 0 && got >= want)) && pass "omarchy: $got rules for $want no_screen_share rules in $apps (built-in ones merged)" || bad "omarchy: $got rules, Omarchy has $want"
  for m in 'class=^(1[p|P]assword)$' 'class=^(Bitwarden)$' 'class=chrome-nngceckbapebfimnlniiiahkandclblb-Default'; do
    grep -qF "|true|$m" <<<"$out" && pass "omarchy: protected $m" || bad "omarchy: $m is not protected"
  done
else
  echo "SKIP: screenshare omarchy: $apps not installed (fixture and fallback cases still run)"
fi

# --- fixture: a fake Omarchy tree ---
mkdir -p "$tmp/om/default/hypr/apps"
cat >"$tmp/om/default/hypr/apps/a-vault.lua" <<'LUA'
o.window("^(NewVault)$", { no_screen_share = true, tag = "+floating-window" })
o.window({ class = "^Keep$", title = "^Secret$" }, { no_screen_share = true })
o.window("^Other$", { float = true, tile = true })
hl.layer_rule({ match = { namespace = "x" }, no_anim = true })
o.bind("SUPER + X", "Something", "touch never")
LUA
cat >"$tmp/om/default/hypr/apps/b-evil.lua" <<'LUA'
o.window("^(Evil)$", { no_screen_share = true })
os.execute("touch marker-os")
o.window("^(AfterEvil)$", { no_screen_share = true })
LUA
cat >"$tmp/om/default/hypr/apps/c-io.lua" <<'LUA'
local f = io.open("marker-io", "w")
o.window("^(AfterIo)$", { no_screen_share = true })
LUA
printf 'o.window("^(Broken)$", { no_screen_share = true \n' >"$tmp/om/default/hypr/apps/d-broken.lua"
cat >"$tmp/om/default/hypr/apps/e-require.lua" <<'LUA'
require("os")
o.window("^(AfterRequire)$", { no_screen_share = true })
LUA
out=$(run "$tmp/om")
[[ $out == *"source omarchy"* ]] && pass "fixture: rules read from the fixture" || bad "fixture: source: $out"
grep -qF '|true|class=^(NewVault)$' <<<"$out" && pass "fixture: a new protected app is picked up" || bad "fixture: NewVault missing"
grep -qF '|true|class=^Keep$;title=^Secret$' <<<"$out" && pass "fixture: a table match is kept whole" || bad "fixture: table match missing"
grep -qF '|true|class=^(Evil)$' <<<"$out" && pass "fixture: rules before a stop still count" || bad "fixture: Evil missing"
if grep -qE 'Other|AfterEvil|AfterIo|Broken|AfterRequire' <<<"$(grep '^gf-no-screen-share' <<<"$out")"; then
  bad "fixture: a rule that is not no_screen_share, or one after a stop, was applied"
else
  pass "fixture: only no_screen_share rules up to a stop"
fi
n=$(grep -c '^gf-no-screen-share-' <<<"$out" || true)
((n == 6)) && pass "fixture: exactly 6 rules (3 read, 3 built-in)" || bad "fixture: $n rules"
for m in 'class=^(1[p|P]assword)$' 'class=^(Bitwarden)$' 'class=chrome-nngceckbapebfimnlniiiahkandclblb-Default'; do
  grep -qF "|true|$m" <<<"$out" && pass "fixture: built-in $m applied although the tree does not declare it" || bad "fixture: built-in $m missing"
done
[[ ! -e $tmp/marker-os && ! -e $tmp/marker-io ]] && pass "fixture: os/io calls of an Omarchy file never ran" || bad "fixture: a marker file was created"
grep -q 'stopped reading .*b-evil.lua' <<<"$out" && grep -q 'stopped reading .*d-broken.lua' <<<"$out" \
  && pass "fixture: stops are reported" || bad "fixture: stops not reported: $out"

# --- a 1password.lua that stops before its rule (reviewer note b): 1Password stays protected ---
mkdir -p "$tmp/om2/default/hypr/apps"
printf 'os.execute("touch marker-1p")\no.window("^(1[p|P]assword)$", { no_screen_share = true })\n' >"$tmp/om2/default/hypr/apps/1password.lua"
printf 'o.window("^(Bitwarden)$", { no_screen_share = true })\n' >"$tmp/om2/default/hypr/apps/bitwarden.lua"
out=$(run "$tmp/om2")
grep -qF '|true|class=^(1[p|P]assword)$' <<<"$out" && [[ ! -e $tmp/marker-1p ]] \
  && pass "stopped file: 1Password still protected by the built-in match, nothing of the file ran" || bad "stopped file: 1Password unprotected: $out"
n=$(grep -c '^gf-no-screen-share-' <<<"$out" || true)
((n == 3)) && pass "stopped file: no duplicate rules (3)" || bad "stopped file: $n rules"

# --- builtin: nothing readable ---
out=$(run "$tmp/none")
[[ $out == *"source builtin"* ]] && pass "builtin: reported when no Omarchy rule can be read" || bad "builtin: source: $out"
for m in 'class=^(1[p|P]assword)$' 'class=^(Bitwarden)$' 'class=chrome-nngceckbapebfimnlniiiahkandclblb-Default'; do
  grep -qF "|true|$m" <<<"$out" && pass "builtin: protected $m" || bad "builtin: $m missing"
done

# --- wiring: both sessions load it ---
grep -qx 'require("grassfield.privacy")' config/hypr/grassfield/core.lua && pass "wiring: core.lua requires grassfield.privacy" || bad "wiring: core.lua"
grep -q 'require("grassfield.core")' config/hypr/session.lua && grep -q 'require("grassfield.core")' config/hypr/dev.lua \
  && pass "wiring: session.lua and dev.lua load core.lua" || bad "wiring: a session does not load core.lua"
exit $fail
