#!/usr/bin/env bash
# GF-023 / A11Y-03 and GF-032 (PATH part): the Grassfield session loads Omarchy's input defaults (layout from
# /etc/vconsole.conf, compose:caps, repeat rate, numlock) before the user's own input.lua and before Grassfield's pointer
# defaults, falls back to the same defaults when Omarchy's module cannot load, and puts the Omarchy-shell stand-ins first in
# PATH. config/hypr/grassfield/omarchy.lua run by a plain Lua interpreter against a stub of Hyprland's `hl` table and
# fixture Omarchy trees (plus the installed Omarchy when present). Needs `lua`.
# The Lua is Hyprland's own (the liblua its binary needs; 5.5 for Hyprland 0.56 when it is not installed): in Lua 5.5 a
# for-loop variable is const, and a module that assigns to one compiles under 5.4 but fails to load in the session (review
# of the Settings stack: input.lua took the whole session down to Hyprland's emergency config). Every file of
# config/hypr must compile under it; session.lua and dev.lua run whole, also with a broken optional module, and keep their
# lock key and lid handling.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
want=5.5
if hypr=$(command -v Hyprland) && command -v readelf >/dev/null; then
  linked=$(readelf -d "$hypr" 2>/dev/null | sed -n 's/.*(NEEDED).*\[liblua[0-9.]*\.so\.\(5\.[0-9]*\)\].*/\1/p' | head -1)
  [[ -n $linked ]] && want=$linked
fi
lua=
for c in "lua$want" lua; do
  if command -v "$c" >/dev/null && [[ $("$c" -v 2>&1) == "Lua $want."* ]]; then lua=$c; break; fi
done
if [[ -z $lua ]]; then
  if ! command -v lua >/dev/null; then echo "SKIP: no Lua interpreter"; exit 0; fi
  lua=lua
  echo "SKIP: no Lua $want interpreter (the Lua Hyprland runs): the cases run under $(lua -v 2>&1 | cut -d' ' -f1-2); Lua $want NOT VERIFIED"
fi
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/session-input.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

# Every Lua file of the session's configuration compiles under that Lua.
printf '%s\n' 'for _, path in ipairs(arg) do local f, err = loadfile(path); print(f and ("compiled " .. path) or ("error " .. tostring(err))) end' \
  >"$tmp/compile.lua"
files=("$root"/config/hypr/*.lua "$root"/config/hypr/grassfield/*.lua)
compiled=$("$lua" "$tmp/compile.lua" "${files[@]}" 2>&1 || true)
all_compile() { [[ $(grep -c '^compiled ' <<<"$compiled") == "${#files[@]}" ]] && ! grep -q '^error ' <<<"$compiled"; }
desc="every file of config/hypr (${#files[@]}) compiles under $("$lua" -v 2>&1 | cut -d' ' -f1-2)"
check all_compile
grep '^error ' <<<"$compiled" || true

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
local function debug_value(key)  -- the last value set for debug.<key> by any hl.config call
  local v
  for _, c in ipairs(log.config) do if c.debug and c.debug[key] ~= nil then v = c.debug[key] end end
  return v
end

local function fixture(dir, input_body)
  os.execute("mkdir -p " .. dir .. "/default/hypr")
  local function put(name, body) local f = assert(io.open(dir .. "/default/hypr/" .. name, "w")); f:write(body); f:close() end
  put("helpers.lua", "o = o or {}\n")
  put("envs.lua", "")
  if input_body then put("input.lua", input_body) end
end

-- Hermetic: the host's /etc/xkb may define Omarchy 4.5.0's option (then the fallback rightly uses it); these cases test the stock options.
local function hide_host_xkb()
  local open = io.open
  io.open = function(path, mode)
    if path == "/etc/xkb/rules/evdev" or path == "/etc/xkb/symbols/omarchy" then return nil end
    return open(path, mode)
  end
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
  s = put('--[[\n  tap_to_click = false,\n]]\nreturn { natural_scroll = false }\n')
  say("block-comment", tostring(s.tap_to_click), tostring(s.natural_scroll))
  -- 64 KiB that would make a pattern over the whole text quadratic (one run of letters, then short lines of them): read fast.
  local t0 = os.clock()
  put(string.rep("a", 65536))
  put(string.rep(string.rep("b", 199) .. "\n", 327))
  say("bounded-time", tostring(os.clock() - t0 < 1.0))
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
  local m = dofile(repo .. "/config/hypr/grassfield/omarchy.lua")
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
  -- A Latin layout leads (Omarchy's guard): the bindings resolve against the first layout.
  k = put('return { kb_layout = "ru" }')
  say("non-latin-alone", k.kb_layout, "[" .. k.kb_variant .. "]", tostring(k.kb_options))
  k = put('return { kb_layout = "ru,fr", kb_variant = "phonetic,bepo" }')
  say("latin-moves-first", k.kb_layout, "[" .. k.kb_variant .. "]")
  k = put('return { kb_layout = "ru,ua,by,gr" }')
  say("four-non-latin", k.kb_layout, "[" .. k.kb_variant .. "]")
  k = put('return { kb_layout = "de,ru" }')
  say("latin-kept", k.kb_layout, "[" .. k.kb_variant .. "]")
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
  hide_host_xkb()
  fixture(d .. "/omarchy", "error('renamed upstream')\n")
  local m = dofile(repo .. "/config/hypr/grassfield/omarchy.lua")
  say("ok", tostring(m.ok), "input", m.input, "problems", #m.problems)
  say("options", tostring(flat("kb_options")), "rate", tostring(flat("repeat_rate")), "delay", tostring(flat("repeat_delay")),
      "numlock", tostring(flat("numlock_by_default")), "layout-set", tostring(flat("kb_layout") ~= nil))
elseif case == "fallback-non-latin" then
  -- The fallback keeps Omarchy's guard: /etc/vconsole.conf (read through a stub of io.open) names a non-Latin layout.
  local d = os.getenv("TMPCASE")
  fixture(d .. "/omarchy", "error('renamed upstream')\n")
  local f = assert(io.open(d .. "/vconsole.conf", "w")); f:write("KEYMAP=ru\nXKBLAYOUT=ru\nXKBVARIANT=phonetic\n"); f:close()
  hide_host_xkb()
  local open = io.open
  io.open = function(path, mode) return open(path == "/etc/vconsole.conf" and d .. "/vconsole.conf" or path, mode) end
  dofile(repo .. "/config/hypr/grassfield/omarchy.lua")
  say("fallback-layout", tostring(flat("kb_layout")), "[" .. tostring(flat("kb_variant")) .. "]", tostring(flat("kb_options")))
elseif case == "fallback-xkb45" then
  -- Omarchy 4.5.0 defines its own XKB option in /etc/xkb (Caps Lock stays Caps Lock, Shift + Caps Lock is Compose): the fallback
  -- uses it when both files are there (read through a stub of io.open), the stock options otherwise (case "fallback").
  local d = os.getenv("TMPCASE")
  fixture(d .. "/omarchy", "error('renamed upstream')\n")
  local present = os.getenv("XKB45") == "1"
  local f = assert(io.open(d .. "/evdev", "w")); f:write("! option = symbols\n  omarchy:shift_caps_compose = +omarchy(shift_caps_compose)\n"); f:close()
  f = assert(io.open(d .. "/omarchy-symbols", "w")); f:write('xkb_symbols "shift_caps_compose" {};\n'); f:close()
  local map = { ["/etc/xkb/rules/evdev"] = d .. "/evdev", ["/etc/xkb/symbols/omarchy"] = d .. "/omarchy-symbols" }
  local open = io.open
  io.open = function(path, mode)
    if map[path] then return present and open(map[path], mode) or nil end
    return open(path, mode)
  end
  dofile(repo .. "/config/hypr/grassfield/omarchy.lua")
  say("xkb45", tostring(present), tostring(flat("kb_options")))
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
  say("ok", tostring(m.ok), "input", m.input, "problems", #m.problems, "compose", tostring((flat("kb_options") or ""):find("compose:caps", 1, true) ~= nil or (flat("kb_options") or ""):find("omarchy:shift_caps_compose", 1, true) ~= nil),
      "rate", tostring(flat("repeat_rate")), "numlock", tostring(flat("numlock_by_default")))
  for _, p in ipairs(m.problems) do say("problem:", p) end
elseif case:match("^session") or case:match("^dev") then
  -- An entry file whole (TREE/session.lua or TREE/dev.lua). Every hl name it reaches is a callable stub; the compositor
  -- extension's loader is a stub (nothing is chosen, nothing written).
  local d = os.getenv("TMPCASE")
  local binds, gestures = {}, {}
  local function deep(path)
    return setmetatable({}, { __index = function(t, k) local v = deep(path .. "." .. k); rawset(t, k, v); return v end,
                              __call = function(_, ...) return { dsp = path, args = { ... } } end })
  end
  hl = deep("hl")
  hl.config = function(t) log.config[#log.config + 1] = t end
  hl.env = function(k, v) log.env[k] = v end
  hl.bind = function(keys) binds[keys] = true end
  hl.gesture = function(g) gestures[#gestures + 1] = g.fingers .. ":" .. g.direction end
  hl.plugin = { load = function() end }
  package.preload["grassfield.compositor"] = function()
    return { choose = function() return nil, "none" end, verifying = function() return true end, remember = function() end }
  end
  local entry = case:match("^session") and "session" or "dev"
  if entry == "session" then fixture(d .. "/omarchy", 'hl.config({ input = { kb_layout = "us" } })\n') end
  local ok, err = pcall(dofile, os.getenv("TREE") .. "/" .. entry .. ".lua")
  if not ok then say("error", tostring(err)) end
  table.sort(gestures)
  local omarchy = package.loaded["grassfield.omarchy"]
  say(case, "ran", tostring(ok), "lock", tostring(binds["SUPER + CTRL + Q"] == true), "lid", tostring(binds["switch:on:Lid Switch"] == true),
      "pointer", tostring(flat("follow_mouse") ~= nil), "problems", type(omarchy) == "table" and #omarchy.problems or 0,
      "suppress", tostring(debug_value("suppress_errors") == true), "gestures", table.concat(gestures, " "))
  say("PATH", tostring(log.env.PATH))
elseif case == "guard" or case == "guard-again" then
  local d = os.getenv("TMPCASE")
  fixture(d .. "/omarchy", "")
  os.execute("mkdir -p " .. d .. "/shims " .. d .. "/session-bin && touch " .. d .. "/shims/omarchy-restart-shell " .. d .. "/session-bin/hyprland-dialog")
  local m = dofile(repo .. "/config/hypr/grassfield/omarchy.lua")
  say("guarded", tostring(m.guard_path(d .. "/shims")))
  say("PATH", log.env.PATH)
  say("with-session-bin", tostring(m.guard_path(d .. "/shims", d .. "/session-bin")))
  say("PATH-session-bin", log.env.PATH)
  say("no-session-bin", tostring(m.guard_path(d .. "/shims", d .. "/nope")))
  say("PATH-no-session-bin", log.env.PATH)
  say("missing-dir", tostring(m.guard_path(d .. "/nope")))
end
LUA

run() { # run <case> [env...]; a case that stops (a Lua error) is a failure, named with its error
  local name=$1 rc=0; shift
  mkdir -p "$tmp/$name/home"
  env -i PATH="$PATH" TMPCASE="$tmp/$name" HOME="$tmp/$name/home" "$@" "$lua" "$tmp/case.lua" "$name" "$root" >"$tmp/$name.out" 2>&1 || rc=$?
  cat "$tmp/$name.out"
  if ((rc != 0)); then
    echo "FAIL: case $name stopped (exit $rc): $(grep -m1 . <(grep -v '^PASS\|^ok \|^grassfield:' "$tmp/$name.out") | cut -c1-300)" >&2
    : >"$tmp/stopped"
  fi
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
desc="GF-066: a block comment is not read; any 64 KiB file is read in a bounded time (no pattern over the whole text)"
check grep -q "^block-comment true false$" <<<"$out"
check grep -q "^bounded-time true$" <<<"$out"
check grep -q "^broken 0 true$" <<<"$out"
check grep -q "^missing 0 true two_finger$" <<<"$out"

out=$(run keyboard-file GRASSFIELD_CONFIG_HOME="$tmp/keyboard-file/cfg" OMARCHY_PATH="$tmp/keyboard-file/omarchy")
desc="Settings > Keyboard: its file applies after Omarchy (rate 15, two layouts, the options stay Omarchy's), the user's input.lua still wins (delay 333), numlock is never set"
check grep -q "^keyboard rate 15 delay-user-wins 333 layout us,fr variant ,bepo options compose:caps numlock nil$" <<<"$out"
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
desc="Settings > Keyboard: a Latin layout always leads (U.S. before a lone non-Latin one, else the first Latin one moves first, at most four)"
check grep -q "^non-latin-alone us,ru \[,\] nil$" <<<"$out"
check grep -q "^latin-moves-first fr,ru \[bepo,phonetic\]$" <<<"$out"
check grep -q "^four-non-latin us,ru,ua,by \[,,,\]$" <<<"$out"
check grep -q "^latin-kept de,ru \[,\]$" <<<"$out"
out=$(run gestures)
desc="Settings > Trackpad > More Gestures: every gesture without the Settings file, only those left on with it"
check grep -q "^all 3:down 3:horizontal 3:up 4:pinchin 4:pinchout$" <<<"$out"
check grep -q "^spaces-off apps-off 3:down 3:up$" <<<"$out"
check grep -q "^none \[\]$" <<<"$out"
out=$(run fallback OMARCHY_PATH="$tmp/fallback/omarchy")
desc="when Omarchy's input module cannot load, the same defaults are applied (compose:caps, 40/250, numlock) and logged"
check grep -q "^ok true input fallback problems 1$" <<<"$out"
check grep -q "^options compose:caps,shift:both_capslock_cancel rate 40 delay 250 numlock true layout-set true$" <<<"$out"

out=$(run fallback-xkb45 OMARCHY_PATH="$tmp/fallback-xkb45/omarchy" XKB45=1)
desc="the fallback follows Omarchy 4.5.0 (Caps Lock stays Caps Lock, Shift + Caps Lock is Compose) when its XKB option is installed in /etc/xkb"
check grep -q "^xkb45 true omarchy:shift_caps_compose$" <<<"$out"
out=$(run fallback-xkb45 OMARCHY_PATH="$tmp/fallback-xkb45/omarchy" XKB45=0)
desc="... and keeps Omarchy 4.0.6's stock options when it is not"
check grep -q "^xkb45 false compose:caps,shift:both_capslock_cancel$" <<<"$out"

out=$(run fallback-non-latin OMARCHY_PATH="$tmp/fallback-non-latin/omarchy")
desc="the fallback keeps Omarchy's guard: a non-Latin layout gets U.S. first, reached with both Alt keys"
check grep -q "^fallback-layout us,ru \[,phonetic\] compose:caps,shift:both_capslock_cancel,grp:alts_toggle$" <<<"$out"

# One list of non-Latin layouts: Omarchy's (when installed), input.lua's, omarchy.lua's fallback and Settings' Keyboard.js.
words() { tr -c 'a-z\n' ' ' | tr -s ' ' '\n' | { grep . || true; } | sort | tr '\n' ' '; }
in_input=$(sed -n 's/^M\.non_latin = "\(.*\)"$/\1/p' "$root/config/hypr/grassfield/input.lua" | words)
in_fallback=$(sed -n 's/^ *local non_latin = "\(.*\)"$/\1/p' "$root/config/hypr/grassfield/omarchy.lua" | words)
in_settings=$(sed -n '/^var NON_LATIN = \[/,/\];/p' "$root/apps/settings/qml/Keyboard.js" | sed 's/^var NON_LATIN = //' | words)
desc="one list of non-Latin layouts in input.lua, omarchy.lua's fallback and Settings' Keyboard.js ($(wc -w <<<"$in_input") layouts)"
check [ "$(wc -w <<<"$in_input")" -ge 20 -a "$in_input" == "$in_fallback" -a "$in_input" == "$in_settings" ]
# The installed Omarchy and, when GRASSFIELD_TEST_OMARCHY_ALT names one (an Omarchy 4.5.0 checkout, say), that tree too.
omarchy_trees=()
[[ -r /usr/share/omarchy/default/hypr/input.lua ]] && omarchy_trees+=(/usr/share/omarchy)
[[ -n ${GRASSFIELD_TEST_OMARCHY_ALT:-} && -r $GRASSFIELD_TEST_OMARCHY_ALT/default/hypr/input.lua ]] && omarchy_trees+=("$GRASSFIELD_TEST_OMARCHY_ALT")
if ((${#omarchy_trees[@]})); then
  for tree in "${omarchy_trees[@]}"; do
    in_omarchy=$(awk '/^local non_latin_layouts =/ {getline; print}' "$tree/default/hypr/input.lua" | words)
    desc="the list is that of Omarchy's default/hypr/input.lua at $tree"
    check [ "$in_omarchy" == "$in_input" ]
  done
else
  echo "SKIP: Omarchy is not installed here: its list of non-Latin layouts NOT VERIFIED"
fi

out=$(run no-omarchy OMARCHY_PATH="$tmp/does-not-exist")
desc="without Omarchy the include reports not ok with a reason and loads nothing"
check grep -q "^ok false reason true$" <<<"$out"

out=$(run bad-monitors OMARCHY_PATH="$tmp/bad-monitors/omarchy")
desc="a broken monitors.lua is reported, the environment and input still load"
check grep -q "^ok true monitors false problems 1$" <<<"$out"

if ((${#omarchy_trees[@]})); then
  for tree in "${omarchy_trees[@]}"; do
    out=$(run real OMARCHY_PATH="$tree")
    desc="against Omarchy at $tree: input defaults load (compose:caps or Omarchy 4.5.0's omarchy:shift_caps_compose, repeat 40, numlock), no problem"
    check grep -q "^ok true input omarchy problems 0 compose true rate 40 numlock true$" <<<"$out"
  done
else
  echo "SKIP: Omarchy is not installed here"
fi

out=$(run guard OMARCHY_PATH="$tmp/guard/omarchy" PATH="/usr/local/bin:/usr/bin:$tmp/guard/omarchy/bin:/usr/sbin")
desc="the stand-in directory is first in PATH, Omarchy's bin second, no duplicate"
check grep -q "^PATH $tmp/guard/shims:$tmp/guard/omarchy/bin:/usr/local/bin:/usr/bin:/usr/sbin$" <<<"$out"
desc="ADR-0035 D-3: the session-bin directory (hyprland-dialog) comes right after the stand-ins, before Omarchy's bin"
check grep -q "^PATH-session-bin $tmp/guard/shims:$tmp/guard/session-bin:$tmp/guard/omarchy/bin:/usr/local/bin:/usr/bin:/usr/sbin$" <<<"$out"
desc="no session-bin directory installed: only the stand-ins are added"
check grep -q "^PATH-no-session-bin $tmp/guard/shims:$tmp/guard/omarchy/bin:/usr/local/bin:/usr/bin:/usr/sbin$" <<<"$out"
desc="no stand-in directory installed: PATH is left alone"
check grep -q "^missing-dir false$" <<<"$out"
out=$(run guard-again OMARCHY_PATH="$tmp/guard-again/omarchy" PATH="$tmp/guard-again/session-bin:/usr/bin:$tmp/guard-again/shims")
desc="a reload (both directories already in PATH): each appears once, in the same order"
check grep -q "^PATH-session-bin $tmp/guard-again/shims:$tmp/guard-again/session-bin:$tmp/guard-again/omarchy/bin:/usr/bin$" <<<"$out"

# The entry files whole: session.lua (with an Omarchy fixture and the Settings file turning the Spaces swipe off) and
# dev.lua, from the tree, then from a copy whose grassfield/input.lua cannot load. An optional module that fails is logged
# and costs only its own settings: the bindings, the lock key and (session.lua) the lid stay.
cp -r "$root/config/hypr" "$tmp/broken"
printf 'error("input.lua broken on purpose")\n' >"$tmp/broken/grassfield/input.lua"
gestures_off() { mkdir -p "$tmp/$1/cfg"; printf 'return {\n  gesture_spaces = false,\n}\n' >"$tmp/$1/cfg/mouse-trackpad.lua"; }
gestures_off session; gestures_off session-broken; gestures_off dev; gestures_off dev-broken
out=$(run session TREE="$root/config/hypr" OMARCHY_PATH="$tmp/session/omarchy" GRASSFIELD_CONFIG_HOME="$tmp/session/cfg")
desc="session.lua runs whole under Hyprland's Lua: lock key, lid switch, pointer defaults, no problem"
check grep -q "^session ran true lock true lid true pointer true problems 0 " <<<"$out"
desc="ADR-0035 D-2 (decision 3-15): Hyprland's config-error bar stays on, debug.suppress_errors is never set"
check grep -q "^session .* suppress false gestures " <<<"$out"
desc="session.lua: Settings > Trackpad > More Gestures applies in the real session (Spaces swipe off; grassfield.input stays loaded for bindings.lua)"
check grep -q "^session .* gestures 3:down 3:up 4:pinchin 4:pinchout$" <<<"$out"
out=$(run session-broken TREE="$tmp/broken" OMARCHY_PATH="$tmp/session-broken/omarchy" GRASSFIELD_CONFIG_HOME="$tmp/session-broken/cfg")
desc="session.lua with an input.lua that cannot load: the parse goes on, the lock key and the lid switch are bound"
check grep -q "^session-broken ran true lock true lid true pointer false " <<<"$out"
desc="session.lua with an input.lua that cannot load: the failure is logged (and announced as an Omarchy include problem)"
check grep -q "^grassfield: Omarchy include: pointer defaults: .*input.lua broken on purpose" <<<"$out"
check grep -q "^session-broken .* problems 1 suppress false gestures 3:down 3:horizontal 3:up 4:pinchin 4:pinchout$" <<<"$out"
out=$(run dev TREE="$root/config/hypr" GRASSFIELD_CONFIG_DIR="$root/config/hypr" GRASSFIELD_CONFIG_HOME="$tmp/dev/cfg")
desc="dev.lua runs whole under Hyprland's Lua: lock key, pointer defaults, the Settings gestures (no lid: real session only)"
check grep -q "^dev ran true lock true lid false pointer true problems 0 suppress false gestures 3:down 3:up 4:pinchin 4:pinchout$" <<<"$out"
desc="dev.lua: the repository's session-bin (hyprland-dialog's stand-in) is first in the nested compositor's PATH"
check grep -q "^PATH $root/packaging/session-bin:" <<<"$out"
out=$(run dev-broken TREE="$tmp/broken" GRASSFIELD_CONFIG_DIR="$tmp/broken" GRASSFIELD_CONFIG_HOME="$tmp/dev-broken/cfg")
desc="dev.lua with an input.lua that cannot load: logged, the lock key is still bound"
check grep -q "^dev-broken ran true lock true lid false pointer false " <<<"$out"
check grep -q "^grassfield: input: .*input.lua broken on purpose" <<<"$out"

# ADR-0035 D-2 (decision 3-15): no Grassfield config file turns Hyprland's error bar off.
desc="no file of config/hypr sets suppress_errors"
check bash -c '! grep -rn "suppress_errors *=" "$1/config/hypr"' _ "$root"

if [[ -e $tmp/stopped ]]; then echo "FAIL: a case stopped on a Lua error (above)"; fail=1; fi
exit $fail
