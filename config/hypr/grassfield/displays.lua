-- Display choices made in Settings > Displays (ADR-0031). Required by session.lua after grassfield.omarchy (the user's
-- monitors.lua), and by dev.lua: a display Settings set takes its values, the others keep the user's rules.
--
-- Two files, both data read line by line and checked field by field (nothing in them is ever run):
--   displays.conf       $GRASSFIELD_CONFIG_HOME, else $XDG_CONFIG_HOME/grassfield, else ~/.config/grassfield: the kept choices
--   display trial       $XDG_RUNTIME_DIR/grassfield-display-trial.conf ($GRASSFIELD_STATE_HOME/display-trial.conf in the
--                       nested dev session): a change on trial, first line "trial <id> until <unix time>", applied in place
--                       of displays.conf until then. The shell reloads the configuration to apply it and to take it back.
-- One line per display: v1 <TAB> desc:<description> <TAB> <W>x<H>@<Hz> <TAB> <X>x<Y> <TAB> <scale> <TAB> <transform>.

local M = { applied = 0, trial = nil, problems = {} }

local function problem(msg)
  M.problems[#M.problems + 1] = msg
  print("grassfield: " .. msg)
end

local function env(name)
  local v = os.getenv(name)
  return (v and v ~= "") and v or nil
end

function M.conf_path()
  local dir = env("GRASSFIELD_CONFIG_HOME")
  if not dir then
    local xdg = env("XDG_CONFIG_HOME") or ((env("HOME") or "") .. "/.config")
    dir = xdg .. "/grassfield"
  end
  return dir .. "/displays.conf"
end

function M.trial_path(dev)
  if dev then
    local state = env("GRASSFIELD_STATE_HOME")
    return state and (state .. "/display-trial.conf") or nil
  end
  local run = env("XDG_RUNTIME_DIR")
  return run and (run .. "/grassfield-display-trial.conf") or nil
end

local function int_in(s, lo, hi)
  local n = tonumber(s)
  return n ~= nil and n == math.floor(n) and n >= lo and n <= hi
end

-- One line to an hl.monitor rule, or nil and why.
function M.parse_line(line)
  local fields = {}
  for f in (line .. "\t"):gmatch("([^\t]*)\t") do
    fields[#fields + 1] = f
  end
  if #fields ~= 6 or fields[1] ~= "v1" then
    return nil, "not six fields of version v1"
  end
  local desc = fields[2]:match("^desc:(.+)$")
  if not desc or #desc > 160 or desc:find("[%c\127]") then
    return nil, "bad description"
  end
  local w, h, hz = fields[3]:match("^(%d+)x(%d+)@(%d+%.?%d*)$")
  if not w or not int_in(w, 1, 16384) or not int_in(h, 1, 16384) or not tonumber(hz) or tonumber(hz) < 1 or tonumber(hz) > 1000 then
    return nil, "bad mode"
  end
  local x, y = fields[4]:match("^(%-?%d+)x(%-?%d+)$")
  if not x or not int_in(x, -32768, 32768) or not int_in(y, -32768, 32768) then
    return nil, "bad position"
  end
  local scale = fields[5]:match("^%d+%.?%d*$") and tonumber(fields[5])
  if not scale or scale < 0.5 or scale > 4 then
    return nil, "bad scale"
  end
  if not fields[6]:match("^[0-7]$") then
    return nil, "bad transform"
  end
  return { output = "desc:" .. desc, mode = fields[3], position = fields[4], scale = scale, transform = tonumber(fields[6]) }
end

local function lines_of(path)
  local f = path and io.open(path, "r")
  if not f then
    return nil
  end
  local out = {}
  for line in f:lines() do
    out[#out + 1] = line
  end
  f:close()
  return out
end

-- The rules of a list of lines; `first` is the line number of lines[1] in its file (for the journal).
local function rules_of(lines, first, name)
  local rules = {}
  for i, line in ipairs(lines) do
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local rule, why = M.parse_line(line)
      if rule then
        rules[#rules + 1] = rule
      else
        problem(name .. " line " .. (first + i - 1) .. ": " .. why)
      end
    end
  end
  return rules
end

-- The trial's rules while it runs, else nil.
function M.trial_rules(path, now)
  local lines = lines_of(path)
  if not lines or #lines == 0 then
    return nil
  end
  local id, deadline = lines[1]:match("^trial (%w+) until (%d+)$")
  if not id then
    return nil
  end
  -- At its deadline second the trial is over (the shell's countdown ends then too, DisplaysFile.action).
  if tonumber(deadline) <= now then
    problem("display trial " .. id .. " is past its deadline: not applied")
    return nil
  end
  M.trial = id
  local rest = {}
  for i = 2, #lines do
    rest[#rest + 1] = lines[i]
  end
  return rules_of(rest, 2, "display trial")
end

function M.apply(dev, now)
  local rules = M.trial_rules(M.trial_path(dev), now)
  if not rules then
    local lines = lines_of(M.conf_path())
    rules = lines and rules_of(lines, 1, "displays.conf") or {}
  end
  for _, rule in ipairs(rules) do
    local ok, err = pcall(hl.monitor, rule)
    if ok then
      M.applied = M.applied + 1
    else
      problem("display " .. rule.output .. ": " .. tostring(err))
    end
  end
end

M.apply(_G.grassfield_dev == true, os.time())
return M
