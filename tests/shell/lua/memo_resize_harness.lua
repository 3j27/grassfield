-- Runs config/hypr/grassfield/placement.lua against a stub `hl` and checks memo_resize (window.update_rules).
-- Usage: lua memo_resize_harness.lua <placement.lua>; prints "PASS|FAIL <name>" lines, exit 1 on any FAIL.
local calls, handlers = {}, {}
hl = {
  dispatch = function(d) calls[#calls + 1] = d end,
  get_windows = function() return {} end,
  on = function(ev, fn) handlers[ev] = fn end,
  dsp = { window = {
    resize = function(a) return { kind = "resize", x = a.x, y = a.y } end,
    move = function(a) return { kind = "move", x = a.x, y = a.y } end,
  } },
}
assert(loadfile(arg[1]))()
local fails, n = 0, 0
local ID = "memo:" .. string.rep("a", 32)
-- area: x 100, y 80, w 1920, h 1050 (1080 - 30 reserved at the top... y 50 + 30)
local mon = { x = 100, y = 50, width = 1920, height = 1080, scale = 1, reserved = { top = 30, bottom = 0, left = 0, right = 0 } }
local function run(tag, monitor)
  n = n + 1
  calls = {}
  handlers["window.update_rules"]({ mapped = true, floating = true, fullscreen = 0, class = "org.grassfield.Memos",
    xdg_tag = tag, address = "0x" .. n, at = { x = 200, y = 200 }, monitor = monitor })
  return calls
end
local function check(name, ok)
  print((ok and "PASS " or "FAIL ") .. name)
  if not ok then fails = fails + 1 end
end

local c = run(ID .. "!400x300", mon)
check("a sane size is resized then moved", #c == 2 and c[1].x == 400 and c[1].y == 300 and c[2].x == 200 and c[2].y == 200)
c = run(ID .. "!16384x16384", mon)
check("an oversize tag is clamped to the work area width and height minus the title bar", #c == 2 and c[1].x == 1920 and c[1].y == 1018)
check("the clamped corner stays inside the area", c[2] ~= nil and c[2].x == 100 and c[2].y == 112)
c = run(ID .. "@-99999,-99999!400x300", mon)
check("a far corner is clamped into the area", #c == 2 and c[2].x == 100 and c[2].y == 112)
c = run(ID .. "!400x300", nil)
check("no monitor: nothing is dispatched", #c == 0)
c = run(ID .. "!400x300", { x = 0, y = 0 })
check("a monitor without a size: nothing is dispatched", #c == 0)
c = run(ID .. "!0x300", mon)
check("a zero width is rejected", #c == 0)
c = run(ID .. "!400x0", mon)
check("a zero height is rejected", #c == 0)
c = run(ID .. "!-5x300", mon)
check("a negative size does not match", #c == 0)
c = run(ID .. "!16385x300", mon)
check("a size over MEMO_SIZE_MAX is rejected", #c == 0)
c = run(ID .. "!99999999999999999999x300", mon)
check("digit overflow is rejected", #c == 0)
c = run(ID .. "!400x300%", mon)
check("a trailing junk character does not match", #c == 0)
c = run("memo:" .. string.rep("A", 32) .. "!400x300", mon)
check("uppercase hex does not match", #c == 0)
local pad = ID .. "@" .. string.rep("1", 96 - #ID - #"@" - #",1!400x300") .. ",1!400x300"
c = run(pad, mon)
check("a valid tag of exactly 96 characters is accepted", #pad == 96 and #c == 2)
local long = ID .. "@" .. string.rep("1", 97 - #ID - #"@" - #",1!400x300") .. ",1!400x300"
c = run(long, mon)
check("a well-formed tag of 97 characters is rejected", #long == 97 and #c == 0)
local t0 = os.clock()
run(ID .. string.rep("1", 1000000), mon)
check("a 1 MB tag is refused quickly", os.clock() - t0 < 0.5)
os.exit(fails == 0 and 0 or 1)
