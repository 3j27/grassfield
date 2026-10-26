#!/usr/bin/env bash
# Overview with two desktops that both hold windows: the desktop miniatures of the Spaces bar (visual-audit priority 12).
#   VISUAL_APPEARANCE=dark tests/visual/scenarios/overview-desktops.sh   (the appearance follows the session, see lib.sh)
source "$(dirname "$0")/../lib.sh"
trap '"$VS_ROOT/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true' EXIT
vs_session
vs_reset
vs_foot 'Terminal 1' 50x12
vs_wait_clients 1
vs_foot 'Terminal 2' 60x16
vs_wait_clients 2
"$VS_ROOT/scripts/nestctl" dispatch 'hl.dsp.focus({ workspace = "3" })' >/dev/null
sleep 1
vs_foot 'Terminal 3' 70x18
vs_wait_clients 3
vs_foot 'Terminal 4' 80x20
vs_wait_clients 4
vs_ipc overview open
VS_SETTLE=3 vs_capture overview-desktops
