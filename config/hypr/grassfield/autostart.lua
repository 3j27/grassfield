-- Real-session autostart (ADR-0001). The nested dev session does not use this file.

hl.on("hyprland.start", function()
  -- Make the session environment visible to systemd user services and D-Bus activation.
  hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP HYPRLAND_INSTANCE_SIGNATURE GRASSFIELD_SESSION")

  -- grassfield-shell runs as a systemd user service so it restarts on crash (gate R1).
  hl.exec_cmd("systemctl --user start grassfield-shell.service")

  -- Optional compositor extension, matched to the running Hyprland ABI (ADR-0009).
  hl.exec_cmd("/usr/lib/grassfield/load-compositor")
end)
