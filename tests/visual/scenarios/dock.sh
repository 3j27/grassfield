#!/usr/bin/env bash
# Dock with magnification, pointer fixed over the second icon.
source "$(dirname "$0")/../lib.sh"
vs_session
vs_reset
vs_ipc dock magnify 1.7 true
vs_ipc dock hover 927
vs_capture dock
