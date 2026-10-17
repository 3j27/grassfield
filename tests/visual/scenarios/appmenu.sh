#!/usr/bin/env bash
# Application menu of the frontmost app (a foot window) open.
source "$(dirname "$0")/../lib.sh"
vs_session
vs_reset
vs_foot 'Terminal' 60x16
vs_wait_clients 1
vs_ipc menubar open app GF-REF
vs_capture appmenu
