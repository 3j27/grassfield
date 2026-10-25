#!/usr/bin/env bash
# Pointer-driven checks of the visual-audit-3 surfaces: Settings (a pane click, Back, Forward, the hover on a device row) and Files
# (the search circle expanding). Captures: audit-settings-wifi, audit-settings-back, audit-settings-forward, audit-settings-hover,
# audit-files-search. Coordinates are the 1920x1080 reference output (see settings.en.png / files.en.png of f1-audit.sh).
source "$(dirname "$0")/../lib.sh"
trap '"$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true' EXIT
vs_session
vs_reset
vs_spawn "$VS_DEV/build/grassfield-settings"
vs_wait_clients 1
vs_sleep 2
vs_pointer abs 690 306 sleep 300 click
vs_sleep 1
vs_capture audit-settings-wifi
vs_pointer abs 851 221 sleep 300 click
vs_sleep 1
vs_capture audit-settings-back
vs_pointer abs 885 221 sleep 300 click
vs_sleep 1
vs_capture audit-settings-forward
vs_pointer abs 1000 330 sleep 400
VS_NOPARK=1 vs_capture audit-settings-hover
vs_reset
vs_spawn "$VS_DEV/build/grassfield-files"
vs_wait_clients 1
vs_sleep 2
vs_pointer abs 1388 261 sleep 300 click
vs_sleep 1
vs_capture audit-files-search
