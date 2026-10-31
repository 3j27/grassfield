-- Real-session system integration that Omarchy's own session provides and Grassfield would otherwise lose
-- (docs/audits/final-1.0/02-omarchy-compatibility.md §5.3). Loaded by session.lua only: the nested dev session has no
-- lid, no removable media and must never take screenshots of the owner's screen.

-- Screenshots, macOS keys with Super as Command: Command+Shift+3 the screen (the focused display), Command+Shift+4 a
-- selection (a drag, or a click on a window; Esc cancels), Command+Shift+5 and Print the same until the capture toolbar comes
-- (ADR-0035 D-10, owner decision Q4). Grassfield's capture (grim and slurp in Grassfield's colours) saves to the Desktop as
-- macOS names it, copies to the clipboard and shows a notice with "Open in Preview". Bound by keycode (digits need Shift on
-- some layouts).
local function capture(mode)
  return hl.dsp.exec_cmd("/usr/lib/grassfield/grassfield-capture " .. mode)
end
hl.bind("SUPER + SHIFT + code:12", capture("screen"), { description = "Screenshot of the screen" })
hl.bind("SUPER + SHIFT + code:13", capture("selection"), { description = "Screenshot of a selection" })
hl.bind("SUPER + SHIFT + code:14", capture("selection"), { description = "Screenshot of a selection" })
hl.bind("PRINT", capture("selection"), { description = "Screenshot of a selection" })

-- Lid (macOS: closing the lid with an external display keeps the Mac running on that display; without one it sleeps and
-- the screen is locked first). logind decides about suspend; the script locks, and turns the laptop panel off while the lid
-- is closed with an external display. The monitor events reconcile after hot-plug.
local lid = "/usr/lib/grassfield/grassfield-lid"
hl.bind("switch:on:Lid Switch", hl.dsp.exec_cmd(lid .. " closed"), { locked = true })
hl.bind("switch:off:Lid Switch", hl.dsp.exec_cmd(lid .. " opened"), { locked = true })
hl.on("monitor.added", function() hl.exec_cmd(lid .. " reconcile") end)
hl.on("monitor.removed", function() hl.exec_cmd(lid .. " reconcile") end)
