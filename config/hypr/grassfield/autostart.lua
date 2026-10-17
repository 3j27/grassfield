-- Real-session autostart (ADR-0001). The nested dev session does not use this file.

hl.on("hyprland.start", function()
  -- Hand the session environment to systemd and D-Bus activation (uwsm finalizes the compositor unit).
  local vars = "WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP HYPRLAND_INSTANCE_SIGNATURE GRASSFIELD_SESSION"
  local import_env = "if command -v uwsm >/dev/null; then uwsm finalize " .. vars .. "; else dbus-update-activation-environment --systemd " .. vars .. "; fi"

  -- Both units have ConditionEnvironment=GRASSFIELD_SESSION=1, which reads the environment that the import hands to
  -- systemd: they start only after that import has finished (a separate exec_cmd would race it and be skipped).
  -- One command, one import, then the units in order.
  --
  -- Global menus (ADR-0008): the menu bridge starts before the shell and before any application. It stays in
  -- standby (no com.canonical.AppMenu.Registrar) until the shell reports the plugin's appmenu feature, so apps
  -- started without the plugin keep their in-window menus. Apps check for the registrar once, at their start.
  --
  -- grassfield-shell runs as a systemd user service so it restarts on crash (gate R1). It starts even when the
  -- import or the bridge failed (";"): the bar then shows T0.
  hl.exec_cmd("{ " .. import_env .. "; } && systemctl --user start grassfield-menu-bridge.service; systemctl --user start grassfield-shell.service")
end)
