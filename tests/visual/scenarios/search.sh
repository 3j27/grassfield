#!/usr/bin/env bash
# Search with a fixed query.
source "$(dirname "$0")/../lib.sh"
vs_session
vs_reset
vs_ipc search open files
vs_sleep 1.5
vs_capture search
