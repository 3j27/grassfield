-- Per-application window rules (ADR-0045 OC-12): the rules of Omarchy's default/hypr/apps/*.lua that still hold in a
-- floating-first session (ADR-0002) with Grassfield's own placement (placement.lua), stacking (stacking.lua) and title bars
-- (windows.lua, the compositor plugin). The Grassfield session does not load Omarchy's window rules (its tiling, opacity and
-- tag rules would fight Grassfield's look), so each rule kept is written here, copied from the Omarchy 4.0.6 file it cites
-- (basecamp/omarchy@237f1b4, MIT, Copyright (c) David Heinemeier Hansson; pinned in docs/upstream/omarchy.lock:
-- default/hypr/apps/battlenet.lua, default/hypr/apps/davinci-resolve.lua, default/hypr/apps/geforce.lua,
-- default/hypr/apps/moonlight.lua, default/hypr/apps/retroarch.lua, default/hypr/apps/steam.lua,
-- default/hypr/apps/telegram.lua, default/hypr/apps/pip.lua, default/hypr/apps/webcam-overlay.lua):
-- its match unchanged, and only the effects that still make sense. tests/shell/app_rules.sh holds every rule to the effects
-- the cited Omarchy file gives that match (nothing invented, nothing changed) and refuses the effects listed as not ported.
--
-- Not ported, and why:
--   - `float`, `center`: every window floats (windows.lua gf-float-all) and Hyprland centres a new floating window.
--   - `size` of an application's own window (Steam 1100x700 and its Friends List, LocalSend 1100x700, Battle.net's
--     launcher 1280x800, the password managers' 875x600): macOS model, an application decides its own size and a window
--     that arrives with a size keeps it; placement.lua fits it to the screen.
--   - `fullscreen` at map (DaVinci Resolve's main window, Moonlight, RetroArch): a window opens as a window, full screen is
--     the user's choice (Ctrl-Super-F, the green button) or the application's own setting.
--   - `opacity`, `tag` (Omarchy's default-opacity, floating-window, terminal, browser and pip tags), `border_size`,
--     `rounding`, `no_dim`: Omarchy's look; Grassfield's windows are opaque (looknfeel.lua) with one radius (windows.lua).
--   - browser.lua: tiling of browsers, opacity, and the screen-sharing indicator sent to a special workspace (a workspace
--     rule, and Grassfield's Show Desktop parks windows in a special workspace of its own).
--   - jetbrains.lua (`no_follow_mouse`): Grassfield is click-to-focus (input.lua: follow_mouse = 2, mouse_refocus = false),
--     so the pointer never moves the keyboard focus, the case that rule is for.
--   - hermes.lua (border, opacity of Hermes' frameless HUD): Omarchy's look; whether that HUD should lose the plugin's title
--     bar is a client-chrome question (windows.lua), answered there per verified application.
--   - Google Meet's Picture-in-Picture (pip.lua): its title also fits a browser window showing a Meet tab.
--   - Picture-in-Picture `size` and `move`: Grassfield keeps the size such a window asks for (placement.lua,
--     tests/compositor/window_placement.sh) where Hyprland places it.
--   - system.lua, terminals.lua, omarchy-shell.lua, qemu.lua (opacity), screenshot-selection.lua (already windows.lua
--     gf-capture-selection-no-anim), 1password.lua and bitwarden.lua (their screen-share protection is privacy.lua's).
--
-- `idle_inhibit = "fullscreen"`: the screen does not dim, lock or sleep while that window is full screen, as macOS keeps a
-- full-screen game or stream awake; the shell's idle (shell/security/idle, IdleMonitor with respectInhibitors) honours
-- Hyprland's inhibitors. Loaded by core.lua in both the real and the nested session, after privacy.lua. Every rule is applied
-- on its own (a rule Hyprland refuses is printed to its log and costs only that rule). Returns { rules = { <rule>... },
-- failed = { "<name>: <error>"... } }.

local M = { rules = {}, failed = {} }

-- Each entry: the Omarchy file (default/hypr/apps/<source>) and the rule as hl.window_rule takes it.
local RULES = {
  -- battlenet.lua: the installer draws Blizzard's own frame; the window manager adds none (no title bar, border, blur or
  -- shadow). The launcher keeps its own size.
  { source = "battlenet.lua", name = "gf-app-battlenet-setup",
    match = { class = "^steam_app_battlenet$", title = "^Battle\\.net Setup$" },
    decorate = false, no_blur = true, no_shadow = true },
  -- davinci-resolve.lua: Resolve's menus and dialogs are windows of their own that close when they lose the focus; they keep
  -- it while they show. Its main window and the Project Manager do not.
  { source = "davinci-resolve.lua", name = "gf-app-resolve-focus",
    match = { class = ".*[Rr]esolve.*" },
    stay_focused = true },
  { source = "davinci-resolve.lua", name = "gf-app-resolve-main-focus",
    match = { class = ".*[Rr]esolve.*", title = "^(DaVinci Resolve( Studio)? - .+|Project Manager)$" },
    stay_focused = false },
  -- geforce.lua, moonlight.lua, retroarch.lua, steam.lua: a full-screen game or stream keeps the screen awake.
  { source = "geforce.lua", name = "gf-app-geforce-now-idle",
    match = { class = "GeForceNOW" },
    idle_inhibit = "fullscreen" },
  { source = "moonlight.lua", name = "gf-app-moonlight-idle",
    match = { class = "com.moonlight_stream.Moonlight" },
    idle_inhibit = "fullscreen" },
  { source = "retroarch.lua", name = "gf-app-retroarch-idle",
    match = { class = "com.libretro.RetroArch" },
    idle_inhibit = "fullscreen" },
  { source = "steam.lua", name = "gf-app-steam-idle",
    match = { class = "steam" },
    idle_inhibit = "fullscreen" },
  -- telegram.lua: a new message does not take the focus (macOS: an application asking for attention bounces in the Dock;
  -- Grassfield's misc.focus_on_activate is on for every other window, looknfeel.lua).
  { source = "telegram.lua", name = "gf-app-telegram-no-focus-steal",
    match = { class = "org.telegram.desktop" },
    focus_on_activate = false },
  -- pip.lua: Picture-in-Picture stays above the other windows on every desktop and keeps its proportions when resized
  -- (macOS). Its size is its own (above).
  { source = "pip.lua", name = "gf-app-pip",
    match = { title = "(Picture.?in.?[Pp]icture)" },
    pin = true, keep_aspect_ratio = true },
  -- webcam-overlay.lua: Omarchy's camera overlay of a screen recording (`omarchy-capture-screenrecording`, mpv with a
  -- dedicated app id) at its corner, sized from the display's height, over every desktop, without taking the focus. A pinned
  -- window is not refitted by placement.lua.
  { source = "webcam-overlay.lua", name = "gf-app-webcam-small",
    match = { class = "^WebcamOverlay-small$" },
    size = { "(monitor_h*4/25)", "(monitor_h*9/50)" },
    move = { "(monitor_w-monitor_h*4/25-40)", "(monitor_h-monitor_h*9/50-40)" } },
  { source = "webcam-overlay.lua", name = "gf-app-webcam-medium",
    match = { class = "^WebcamOverlay-medium$" },
    size = { "(monitor_h*2/9)", "(monitor_h/4)" },
    move = { "(monitor_w-monitor_h*2/9-40)", "(monitor_h-monitor_h/4-40)" } },
  { source = "webcam-overlay.lua", name = "gf-app-webcam-large",
    match = { class = "^WebcamOverlay-large$" },
    size = { "(monitor_h*3/10)", "(monitor_h*27/80)" },
    move = { "(monitor_w-monitor_h*3/10-40)", "(monitor_h-monitor_h*27/80-40)" } },
  { source = "webcam-overlay.lua", name = "gf-app-webcam",
    match = { class = "^WebcamOverlay-(small|medium|large)$", title = "^WebcamOverlay$" },
    pin = true, no_initial_focus = true },
}

for _, entry in ipairs(RULES) do
  local rule = {}
  for key, value in pairs(entry) do
    if key ~= "source" then
      rule[key] = value
    end
  end
  local ok, err = pcall(hl.window_rule, rule)
  if ok then
    M.rules[#M.rules + 1] = entry
  else
    M.failed[#M.failed + 1] = entry.name .. ": " .. tostring(err)
    print("grassfield: application rule " .. entry.name .. " (Omarchy " .. entry.source .. ") refused: " .. tostring(err))
  end
end

return M
