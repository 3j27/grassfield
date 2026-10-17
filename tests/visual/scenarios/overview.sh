#!/usr/bin/env bash
# Overview with four foot windows of different sizes.
source "$(dirname "$0")/../lib.sh"
vs_session
vs_reset
vs_foot 'Terminal 1' 50x12
vs_wait_clients 1
vs_foot 'Terminal 2' 60x16
vs_wait_clients 2
vs_foot 'Terminal 3' 70x18
vs_wait_clients 3
vs_foot 'Terminal 4' 80x20
vs_wait_clients 4
vs_ipc overview open
VS_SETTLE=2 vs_capture overview
