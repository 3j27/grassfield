-- Real-session autostart (ADR-0001). The nested dev session does not use this file.

hl.on("hyprland.start", function()
  -- Hand the session environment to systemd and D-Bus activation (uwsm finalizes the compositor unit).
  local vars = "WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP HYPRLAND_INSTANCE_SIGNATURE GRASSFIELD_SESSION"
  hl.exec_cmd("if command -v uwsm >/dev/null; then uwsm finalize " .. vars .. "; else dbus-update-activation-environment --systemd " .. vars .. "; fi")

  -- grassfield-shell runs as a systemd user service so it restarts on crash (gate R1).
  hl.exec_cmd("systemctl --user start grassfield-shell.service")
end)
