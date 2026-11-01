#!/usr/bin/env bash
# The Full Screen and Zoom keys (Super+Ctrl+F, Super+Alt+F) as the Window menu has them (ADR-0040 step 1b's review: in nested
# they zoomed About This Computer, a window of fixed size whose menu greys Zoom and Enter Full Screen). bindings.lua runs in a
# plain Lua interpreter against a stub of Hyprland's `hl` table (as tests/shell/bindings_forward.sh): at each press the bind
# asks the compositor plugin (hl.plugin.grassfield.window_size(mode)) and dispatches what it returns (Hyprland's own
# dispatcher, or a no-op for a window of fixed size: the plugin's decision, core tiling::sizeKeyActs, unit-tested in
# compositor/tests/TilingTest.cpp); without the plugin, when it fails or returns nothing, Hyprland's dispatcher as before
# (gate C2). What Hyprland then does with it is the nested case "fixed keys" of tests/compositor/tiling.sh. Needs `lua`.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
if ! command -v lua >/dev/null; then echo "SKIP: no Lua interpreter"; exit 0; fi
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/size-keys.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
cat >"$tmp/run.lua" <<'LUA'
local repo, plugin = arg[1], arg[2]
local binds, dispatched, asked = {}, {}, {}
local function proxy(path)
  return setmetatable({}, { __index = function(_, k) return proxy(path .. "." .. k) end,
                            __call = function(_, ...) return { dsp = path, args = { ... } } end })
end
local plugins = {}
hl = setmetatable({
  bind = function(keys, d, opts) binds[keys] = { d = d, opts = opts or {} } end,
  dispatch = function(d) dispatched[#dispatched + 1] = d end,
  timer = function() end,
  get_active_window = function() return nil end,
  get_layers = function() return {} end,
  gesture = function() end,
  plugin = plugins,
}, { __index = function() return function() end end })
hl.dsp = proxy("dsp")
-- The plugin as each run has it: present (refusing "fullscreen", accepting "maximized"), absent, failing, or returning nothing.
if plugin == "present" then
  plugins.grassfield = { window_size = function(mode)
    asked[#asked + 1] = mode
    return mode == "fullscreen" and { dsp = "noop" } or { dsp = "plugin:" .. mode }
  end }
elseif plugin == "failing" then
  plugins.grassfield = { window_size = function() error("boom") end }
elseif plugin == "nothing" then
  plugins.grassfield = { window_size = function() return nil end }
end
dofile(repo .. "/config/hypr/grassfield/bindings.lua")

local function press(keys)
  dispatched, asked = {}, {}
  local b = assert(binds[keys], "no bind for " .. keys)
  assert(type(b.d) == "function", keys .. " is not decided at the press")
  b.d()
  local out = {}
  for _, d in ipairs(dispatched) do
    local a = d.args and d.args[1]
    out[#out + 1] = d.dsp .. (a and a.mode and ("(" .. a.mode .. ")") or "")
  end
  return table.concat(out, " ") .. " | asked " .. table.concat(asked, ",")
end
print("zoom " .. press("SUPER + ALT + F"))
print("fullscreen " .. press("SUPER + CTRL + F"))
LUA

run() { lua "$tmp/run.lua" "$root" "$1" 2>&1; }

out=$(run present)
echo "$out" | sed 's/^/  present: /'
desc="with the plugin, Zoom dispatches what window_size(\"maximized\") returns (Hyprland's dispatcher for a resizable window)"
check grep -qx "zoom plugin:maximized | asked maximized" <<<"$out"
desc="with the plugin, Full Screen dispatches what window_size(\"fullscreen\") returns (a no-op for a window of fixed size)"
check grep -qx "fullscreen noop | asked fullscreen" <<<"$out"

for p in absent failing nothing; do
  out=$(run "$p")
  echo "$out" | sed "s/^/  $p: /"
  desc="plugin $p: Zoom is Hyprland's own dispatcher, as before (gate C2)"
  check grep -qx "zoom dsp.window.fullscreen(maximized) | asked " <<<"$out"
  desc="plugin $p: Full Screen is Hyprland's own dispatcher, as before (gate C2)"
  check grep -qx "fullscreen dsp.window.fullscreen(fullscreen) | asked " <<<"$out"
done

desc="the two keys keep their descriptions and are bound once each"
check bash -c 'f="$1/config/hypr/grassfield/bindings.lua"; [ "$(grep -c "^bind(\"SUPER + CTRL + F\", \"Full screen\", window_size(\"fullscreen\"))" "$f")" = 1 ] && [ "$(grep -c "^bind(\"SUPER + ALT + F\", \"Zoom (fill the screen)\", window_size(\"maximized\"))" "$f")" = 1 ]' _ "$root"

exit $fail
