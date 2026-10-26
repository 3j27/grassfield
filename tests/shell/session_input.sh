#!/usr/bin/env bash
# GF-023 / A11Y-03 and GF-032 (PATH part): the Grassfield session loads Omarchy's input defaults (layout from
# /etc/vconsole.conf, compose:caps, repeat rate, numlock) before the user's own input.lua and before Grassfield's pointer
# defaults, falls back to the same defaults when Omarchy's module cannot load, and puts the Omarchy-shell stand-ins first in
# PATH. config/hypr/grassfield/omarchy.lua run by a plain Lua interpreter against a stub of Hyprland's `hl` table and
# fixture Omarchy trees (plus the installed Omarchy when present). Needs `lua`.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
if ! command -v lua >/dev/null; then echo "SKIP: no Lua interpreter"; exit 0; fi
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/session-input.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

cat >"$tmp/case.lua" <<'LUA'
-- usage: lua case.lua <case> <repo root>
local case, repo = arg[1], arg[2]
local log = { config = {}, env = {}, windows = 0 }
local function proxy(path)
  return setmetatable({}, { __index = function(_, k) return proxy(path .. "." .. k) end,
                            __call = function(_, ...) return { dsp = path, args = { ... } } end })
end
hl = setmetatable({
  config = function(t) log.config[#log.config + 1] = t end,
  env = function(k, v) log.env[k] = v end,
  monitor = function() end,
}, { __index = function(_, k) return function() end end })
hl.dsp = proxy("dsp")
package.path = repo .. "/config/hypr/?.lua;" .. package.path

local function flat(key)  -- the last value set for input.<key> by any hl.config call
  local v
  for _, c in ipairs(log.config) do if c.input and c.input[key] ~= nil then v = c.input[key] end end
  return v
end
local function say(...) print(table.concat({ ... }, " ")) end

local function fixture(dir, input_body)
  os.execute("mkdir -p " .. dir .. "/default/hypr")
  local function put(name, body) local f = assert(io.open(dir .. "/default/hypr/" .. name, "w")); f:write(body); f:close() end
  put("helpers.lua", "o = o or {}\n")
  put("envs.lua", "")
  if input_body then put("input.lua", input_body) end
end

if case == "omarchy-input" then
  -- Omarchy's module sets a French layout; the user's input.lua adds a marker; Grassfield's input.lua must change no kb key.
  local d = os.getenv("TMPCASE")
  fixture(d .. "/omarchy", 'hl.config({ input = { kb_layout = "fr", kb_options = "compose:caps", repeat_rate = 40, numlock_by_default = true } })\n')
  os.execute("mkdir -p " .. d .. "/home/.config/hypr")
  local f = io.open(d .. "/home/.config/hypr/input.lua", "w"); f:write('hl.config({ input = { kb_variant = "user-variant" } })\n'); f:close()
  local m = dofile(repo .. "/config/hypr/grassfield/omarchy.lua")
  say("ok", tostring(m.ok), "input", m.input, "problems", #m.problems)
  say("layout", tostring(flat("kb_layout")), "variant", tostring(flat("kb_variant")), "options", tostring(flat("kb_options")))
  local before = #log.config
  dofile(repo .. "/config/hypr/grassfield/input.lua")
  local bad = {}
  for k in pairs(log.config[#log.config].input) do
    if k:match("^kb_") or k:match("^repeat_") or k:match("numlock") then bad[#bad + 1] = k end
  end
  say("grassfield-input-keyboard-keys", #bad, "added-configs", #log.config - before)
  say("layout-after", tostring(flat("kb_layout")), "order", tostring(flat("kb_variant")))
elseif case == "pointer-order" then
  -- GF-066: Grassfield's pointer defaults and the Settings file go in BEFORE the user's input.lua, which wins.
  local d = os.getenv("TMPCASE")
  fixture(d .. "/omarchy", 'hl.config({ input = { kb_layout = "fr" } })\n')
  os.execute("mkdir -p " .. d .. "/home/.config/hypr " .. d .. "/cfg")
  local f = io.open(d .. "/cfg/mouse-trackpad.lua", "w")
  f:write('return { sensitivity = 0.4, natural_scroll = false, tap_to_click = false, secondary_click = "corner", bogus = 1 }\n'); f:close()
  f = io.open(d .. "/home/.config/hypr/input.lua", "w"); f:write('hl.config({ input = { sensitivity = 0.9, touchpad = { natural_scroll = true } } })\n'); f:close()
  local m = dofile(repo .. "/config/hypr/grassfield/omarchy.lua")
  local function touch(key) local v; for _, c in ipairs(log.config) do if c.input and c.input.touchpad and c.input.touchpad[key] ~= nil then v = c.input.touchpad[key] end end return v end
  say("applied", tostring(m.input_applied), "problems", #m.problems)
  say("user-wins sensitivity", tostring(flat("sensitivity")), "natural_scroll", tostring(touch("natural_scroll")))
  say("settings-file tap", tostring(touch("tap_to_click")), "clickfinger", tostring(touch("clickfinger_behavior")), "follow_mouse", tostring(flat("follow_mouse")))
  -- order of the hl.config calls: kb layout, Grassfield pointer (twice? no: once), then the user's
  local idx = {}
  for i, c in ipairs(log.config) do
    if c.input and c.input.follow_mouse ~= nil then idx.gf = i end
    if c.input and c.input.sensitivity == 0.9 then idx.user = i end
  end
  say("order grassfield-before-user", tostring(idx.gf ~= nil and idx.user ~= nil and idx.gf < idx.user))
elseif case == "pointer-file" then
  -- The Settings file alone (no user input.lua), and invalid files: defaults stay for the bad entries.
  local d = os.getenv("TMPCASE")
  os.execute("mkdir -p " .. d)
  local gi = dofile(repo .. "/config/hypr/grassfield/input.lua")
  local function put(body) local f = io.open(d .. "/x.lua", "w"); f:write(body); f:close(); return gi.settings(d .. "/x.lua") end
  local s = put('return { sensitivity = 5, natural_scroll = "yes", tap_to_click = false, secondary_click = "left" }')
  say("invalid", tostring(s.sensitivity), tostring(s.natural_scroll), tostring(s.tap_to_click), s.secondary_click)
  s = put('os.execute("touch ' .. d .. '/pwned") return {}')
  say("no-code-runs", tostring(io.open(d .. "/pwned") == nil), tostring(s.sensitivity))
  -- Read as text: a loop that never ends is not run (the compositor would stall reading its configuration), its pairs still read.
  s = put('while true do end return { tap_to_click = false }')
  say("never-runs", tostring(s.tap_to_click))
  -- Text inside a string is not a pair; a comment is not read.
  s = put('return {\n  secondary_click = "corner tap_to_click = false",\n  -- natural_scroll = false,\n}\n')
  say("strings-comments", tostring(s.tap_to_click), tostring(s.natural_scroll), s.secondary_click)
  s = put("this is not lua")
  say("broken", tostring(s.sensitivity), tostring(s.natural_scroll))
  s = gi.settings(d .. "/missing.lua")
  say("missing", tostring(s.sensitivity), tostring(s.natural_scroll), s.secondary_click)
elseif case == "keyboard-file" then
  -- Settings > Keyboard: keyboard.lua applies between Omarchy's defaults and the user's input.lua, only the keys it holds.
  local d = os.getenv("TMPCASE")
  fixture(d .. "/omarchy", 'hl.config({ input = { kb_layout = "us", kb_options = "compose:caps", repeat_rate = 40, repeat_delay = 250 } })\n')
  os.execute("mkdir -p " .. d .. "/home/.config/hypr " .. d .. "/cfg")
  local f = io.open(d .. "/cfg/keyboard.lua", "w")
  f:write('return { repeat_rate = 15, repeat_delay = 600, kb_layout = "us,fr", kb_variant = ",bepo", numlock_by_default = false }\n'); f:close()
  f = io.open(d .. "/home/.config/hypr/input.lua", "w"); f:write('hl.config({ input = { repeat_delay = 333 } })\n'); f:close()
  dofile(repo .. "/config/hypr/grassfield/omarchy.lua")
  say("keyboard rate", tostring(flat("repeat_rate")), "delay-user-wins", tostring(flat("repeat_delay")), "layout", tostring(flat("kb_layout")),
      "variant", tostring(flat("kb_variant")), "options", tostring(flat("kb_options")), "numlock", tostring(flat("numlock_by_default")))
  local gi = dofile(repo .. "/config/hypr/grassfield/input.lua")
  local function put(body) local w = io.open(d .. "/k.lua", "w"); w:write(body); w:close(); return gi.keyboard(d .. "/k.lua") end
  local k = put('return { repeat_rate = 0, kb_layout = "de" }')
  say("one-layout", tostring(k.repeat_rate), k.kb_layout, "[" .. tostring(k.kb_variant) .. "]", tostring(k.kb_options))
  k = put('return { repeat_rate = 1.5, repeat_delay = 50, kb_layout = "us,FR", kb_variant = "x" }')
  say("invalid", tostring(next(k)))
  k = put('return { kb_layout = "us,fr,de,es,it" }')
  say("too-many", tostring(k.kb_layout))
  k = put('return { kb_layout = "us,fr", kb_variant = "intl;rm" }')
  say("bad-variant", k.kb_layout, "[" .. k.kb_variant .. "]")
  k = put('os.execute("touch ' .. d .. '/pwned") return { repeat_rate = 10 }')
  say("no-code-runs", tostring(io.open(d .. "/pwned") == nil), tostring(k.repeat_rate))
  k = put('while true do end return { repeat_rate = 25 }')
  say("never-runs", tostring(k.repeat_rate))
  -- What Settings writes (Keyboard.js serialize): one pair a line, a comma after each.
  k = put('-- Generated by Grassfield Settings (Keyboard).\nreturn {\n  repeat_rate = 15,\n  repeat_delay = 600,\n  kb_layout = "us,fr",\n  kb_variant = ",bepo",\n}\n')
  say("generated", tostring(k.repeat_rate), tostring(k.repeat_delay), k.kb_layout, "[" .. k.kb_variant .. "]")
  say("missing", tostring(next(gi.keyboard(d .. "/none.lua"))))
elseif case == "gestures" then
  -- Settings > Trackpad > More Gestures: bindings.lua sets only the gestures the Settings file leaves on.
  local count = {}
  hl.gesture = function(g) local key = g.fingers .. ":" .. g.direction; count[key] = (count[key] or 0) + 1 end
  hl.bind = function() end
  local function run(flags)
    count = {}
    package.loaded["grassfield.input"] = flags and { settings = function() return flags end } or nil
    dofile(repo .. "/config/hypr/grassfield/bindings.lua")
    local keys = {}
    for k in pairs(count) do keys[#keys + 1] = k end
    table.sort(keys)
    return table.concat(keys, " ")
  end
  say("all", run(nil))
  say("spaces-off apps-off", run({ gesture_spaces = false, gesture_overview = true, gesture_apps = false }))
  say("none", "[" .. run({ gesture_spaces = false, gesture_overview = false, gesture_apps = false }) .. "]")
elseif case == "fallback" then
  local d = os.getenv("TMPCASE")
  fixture(d .. "/omarchy", "error('renamed upstream')\n")
  local m = dofile(repo .. "/config/hypr/grassfield/omarchy.lua")
  say("ok", tostring(m.ok), "input", m.input, "problems", #m.problems)
  say("options", tostring(flat("kb_options")), "rate", tostring(flat("repeat_rate")), "delay", tostring(flat("repeat_delay")),
      "numlock", tostring(flat("numlock_by_default")), "layout-set", tostring(flat("kb_layout") ~= nil))
elseif case == "no-omarchy" then
  local m = dofile(repo .. "/config/hypr/grassfield/omarchy.lua")
  say("ok", tostring(m.ok), "reason", tostring(m.reason ~= nil))
elseif case == "bad-monitors" then
  local d = os.getenv("TMPCASE")
  fixture(d .. "/omarchy", "")
  os.execute("mkdir -p " .. d .. "/home/.config/hypr")
  local f = io.open(d .. "/home/.config/hypr/monitors.lua", "w"); f:write("error('boom')\n"); f:close()
  local m = dofile(repo .. "/config/hypr/grassfield/omarchy.lua")
  say("ok", tostring(m.ok), "monitors", tostring(m.monitors), "problems", #m.problems)
elseif case == "real" then
  local m = dofile(repo .. "/config/hypr/grassfield/omarchy.lua")
  say("ok", tostring(m.ok), "input", m.input, "problems", #m.problems, "compose", tostring((flat("kb_options") or ""):find("compose:caps", 1, true) ~= nil),
      "rate", tostring(flat("repeat_rate")), "numlock", tostring(flat("numlock_by_default")))
  for _, p in ipairs(m.problems) do say("problem:", p) end
elseif case == "guard" then
  local d = os.getenv("TMPCASE")
  fixture(d .. "/omarchy", "")
  os.execute("mkdir -p " .. d .. "/shims && touch " .. d .. "/shims/omarchy-restart-shell")
  local m = dofile(repo .. "/config/hypr/grassfield/omarchy.lua")
  say("guarded", tostring(m.guard_path(d .. "/shims")))
  say("PATH", log.env.PATH)
  say("missing-dir", tostring(m.guard_path(d .. "/nope")))
end
LUA

run() { # run <case> [env...]
  local name=$1; shift
  mkdir -p "$tmp/$name/home"
  env -i PATH="$PATH" TMPCASE="$tmp/$name" HOME="$tmp/$name/home" "$@" lua "$tmp/case.lua" "$name" "$root"
}

# The result lines of one case.
out=$(run omarchy-input OMARCHY_PATH="$tmp/omarchy-input/omarchy")
desc="Omarchy's input defaults are loaded (include ok, input=omarchy, no problem)"
check grep -q "^ok true input omarchy problems 0$" <<<"$out"
desc="the layout comes from Omarchy's module and the user's own input.lua is applied after it"
check grep -q "^layout fr variant user-variant options compose:caps$" <<<"$out"
desc="Grassfield's input.lua sets no keyboard key (layout, options, repeat, numlock stay the system's)"
check grep -q "^grassfield-input-keyboard-keys 0 added-configs 1$" <<<"$out"
check grep -q "^layout-after fr " <<<"$out"

out=$(run pointer-order OMARCHY_PATH="$tmp/pointer-order/omarchy" GRASSFIELD_CONFIG_HOME="$tmp/pointer-order/cfg")
desc="GF-066: Grassfield's pointer defaults were applied by the include, before the user's input.lua"
check grep -q "^applied true problems 0$" <<<"$out"
check grep -q "^order grassfield-before-user true$" <<<"$out"
desc="GF-066: the user's input.lua wins over Grassfield's defaults and over the Settings file (sensitivity 0.9, natural scroll on)"
check grep -q "^user-wins sensitivity 0.9 natural_scroll true$" <<<"$out"
desc="GF-066: Settings' Mouse & Trackpad file is applied (tap to click off, corner secondary click), invalid keys ignored"
check grep -q "^settings-file tap false clickfinger false follow_mouse 2$" <<<"$out"
out=$(run pointer-file)
desc="GF-066: out-of-range, mistyped and unknown entries of the Settings file keep the defaults"
check grep -q "^invalid 0 true false two_finger$" <<<"$out"
desc="GF-066: the Settings file is read as text, never run (no os.* call, no endless loop), a broken or missing file means defaults"
check grep -q "^no-code-runs true 0$" <<<"$out"
check grep -q "^never-runs false$" <<<"$out"
desc="GF-066: text inside a string is not a pair, a commented line is not read"
check grep -q "^strings-comments true true two_finger$" <<<"$out"
check grep -q "^broken 0 true$" <<<"$out"
check grep -q "^missing 0 true two_finger$" <<<"$out"

out=$(run keyboard-file GRASSFIELD_CONFIG_HOME="$tmp/keyboard-file/cfg" OMARCHY_PATH="$tmp/keyboard-file/omarchy")
desc="Settings > Keyboard: its file applies after Omarchy (rate 15, two layouts with Ctrl+Space), the user's input.lua still wins (delay 333), numlock is never set"
check grep -q "^keyboard rate 15 delay-user-wins 333 layout us,fr variant ,bepo options compose:caps,shift:both_capslock_cancel,grp:ctrl_space_toggle numlock nil$" <<<"$out"
desc="Settings > Keyboard: one layout gets no switch and an empty variant; 0 turns repeat off"
check grep -q "^one-layout 0 de \[\] nil$" <<<"$out"
desc="Settings > Keyboard: mistyped or out-of-range entries, more than four layouts and a bad variant are left out"
check grep -q "^invalid nil$" <<<"$out"
check grep -q "^too-many nil$" <<<"$out"
check grep -q "^bad-variant us,fr \[,\]$" <<<"$out"
desc="Settings > Keyboard: the file is read as text (nothing in it runs, its pairs are read), a missing file sets nothing"
check grep -q "^no-code-runs true 10$" <<<"$out"
check grep -q "^never-runs 25$" <<<"$out"
desc="Settings > Keyboard: the file as Settings writes it"
check grep -q "^generated 15 600 us,fr \[,bepo\]$" <<<"$out"
check grep -q "^missing nil$" <<<"$out"
out=$(run gestures)
desc="Settings > Trackpad > More Gestures: every gesture without the Settings file, only those left on with it"
check grep -q "^all 3:down 3:horizontal 3:up 4:pinchin 4:pinchout$" <<<"$out"
check grep -q "^spaces-off apps-off 3:down 3:up$" <<<"$out"
check grep -q "^none \[\]$" <<<"$out"
out=$(run fallback OMARCHY_PATH="$tmp/fallback/omarchy")
desc="when Omarchy's input module cannot load, the same defaults are applied (compose:caps, 40/250, numlock) and logged"
check grep -q "^ok true input fallback problems 1$" <<<"$out"
check grep -q "^options compose:caps,shift:both_capslock_cancel rate 40 delay 250 numlock true layout-set true$" <<<"$out"

out=$(run no-omarchy OMARCHY_PATH="$tmp/does-not-exist")
desc="without Omarchy the include reports not ok with a reason and loads nothing"
check grep -q "^ok false reason true$" <<<"$out"

out=$(run bad-monitors OMARCHY_PATH="$tmp/bad-monitors/omarchy")
desc="a broken monitors.lua is reported, the environment and input still load"
check grep -q "^ok true monitors false problems 1$" <<<"$out"

if [[ -r /usr/share/omarchy/default/hypr/input.lua ]]; then
  out=$(run real OMARCHY_PATH=/usr/share/omarchy)
  desc="against the installed Omarchy: input defaults load (compose:caps, repeat 40, numlock), no problem"
  check grep -q "^ok true input omarchy problems 0 compose true rate 40 numlock true$" <<<"$out"
else
  echo "SKIP: Omarchy is not installed here"
fi

out=$(run guard OMARCHY_PATH="$tmp/guard/omarchy" PATH="/usr/local/bin:/usr/bin:$tmp/guard/omarchy/bin:/usr/sbin")
desc="the stand-in directory is first in PATH, Omarchy's bin second, no duplicate"
check grep -q "^PATH $tmp/guard/shims:$tmp/guard/omarchy/bin:/usr/local/bin:/usr/bin:/usr/sbin$" <<<"$out"
desc="no stand-in directory installed: PATH is left alone"
check grep -q "^missing-dir false$" <<<"$out"

exit $fail
