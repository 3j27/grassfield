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
