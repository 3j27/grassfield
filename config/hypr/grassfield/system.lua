-- Real-session system integration that Omarchy's own session provides and Grassfield would otherwise lose
-- (docs/audits/final-1.0/02-omarchy-compatibility.md §5.3). Loaded by session.lua only: the nested dev session has no
-- lid, no removable media and must never take screenshots of the owner's screen.

-- Screenshots, macOS keys with Super as Command: Command+Shift+3 whole screen, Command+Shift+4 selection, Command+Shift+5
-- the capture picker. Omarchy's capture tool (grim and slurp; the picture goes to Pictures and the clipboard) does the work.
-- Bound by keycode (digits need Shift on some layouts).
local function capture(mode)
  return hl.dsp.exec_cmd("omarchy-capture-screenshot " .. mode)
end
hl.bind("SUPER + SHIFT + code:12", capture("fullscreen"), { description = "Screenshot of the screen" })
hl.bind("SUPER + SHIFT + code:13", capture("region"), { description = "Screenshot of a selection" })
hl.bind("SUPER + SHIFT + code:14", capture("smart"), { description = "Screenshot picker" })
hl.bind("PRINT", capture("smart"), { description = "Screenshot picker" })

-- Lid (macOS: closing the lid with an external display keeps the Mac running on that display; without one it sleeps and
-- the screen is locked first). logind decides about suspend; the script locks, and turns the laptop panel off while the lid
-- is closed with an external display. The monitor events reconcile after hot-plug.
local lid = "/usr/lib/grassfield/grassfield-lid"
hl.bind("switch:on:Lid Switch", hl.dsp.exec_cmd(lid .. " closed"), { locked = true })
hl.bind("switch:off:Lid Switch", hl.dsp.exec_cmd(lid .. " opened"), { locked = true })
hl.on("monitor.added", function() hl.exec_cmd(lid .. " reconcile") end)
hl.on("monitor.removed", function() hl.exec_cmd(lid .. " reconcile") end)
