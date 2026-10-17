#!/usr/bin/env bash
# Apps (launchpad) page 1.
source "$(dirname "$0")/../lib.sh"
vs_session
vs_reset
vs_ipc apps open
vs_sleep 1
vs_capture apps
