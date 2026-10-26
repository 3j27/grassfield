#!/usr/bin/env bash
# In-app popup material (menus, combo popups) in Settings and Files: the popups keep the shell's material, not the window colour
# (Appearance.windowSurface changes the window's own roles only). Run it with VISUAL_APPEARANCE=dark for the dark pair (lib.sh).
# Captures: audit-menu-settings (a combo popup of the Lock Screen pane), audit-menu-files (the context menu of a folder).
source "$(dirname "$0")/../lib.sh"
trap '"$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true' EXIT
vs_session
vs_reset
vs_spawn "$VS_DEV/build/grassfield-settings"
vs_wait_clients 1
vs_sleep 2
vs_pointer abs 690 634 sleep 300 click
vs_sleep 1
vs_capture audit-lock-page
vs_pointer abs 1230 300 sleep 300 click
vs_sleep 1
VS_NOPARK=1 vs_capture audit-menu-settings
vs_reset
vs_spawn "$VS_DEV/build/grassfield-files"
vs_wait_clients 1
vs_sleep 2
vs_pointer abs 900 500 sleep 300 rclick
vs_sleep 1
VS_NOPARK=1 vs_capture audit-menu-files
