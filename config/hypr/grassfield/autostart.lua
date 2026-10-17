-- Real-session autostart (ADR-0001). The nested dev session does not use this file.

hl.on("hyprland.start", function()
  -- Hand the session environment to systemd and D-Bus activation (uwsm finalizes the compositor unit).
  local vars = "WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP HYPRLAND_INSTANCE_SIGNATURE GRASSFIELD_SESSION"
  local import_env = "if command -v uwsm >/dev/null; then uwsm finalize " .. vars .. "; else dbus-update-activation-environment --systemd " .. vars .. "; fi"
  hl.exec_cmd(import_env)

  -- Global menus (ADR-0008): the menu bridge starts before the shell and before any application. It stays in
  -- standby (no com.canonical.AppMenu.Registrar) until the shell reports the plugin's appmenu feature, so apps
  -- started without the plugin keep their in-window menus. Apps check for the registrar once, at their start.
  -- The unit's ConditionEnvironment=GRASSFIELD_SESSION=1 reads the environment that the import above hands to
  -- systemd, so it starts only after that import has finished (a separate exec_cmd would race it and be skipped).
  hl.exec_cmd("{ " .. import_env .. "; } && systemctl --user start grassfield-menu-bridge.service")

  -- grassfield-shell runs as a systemd user service so it restarts on crash (gate R1).
  hl.exec_cmd("systemctl --user start grassfield-shell.service")
end)
