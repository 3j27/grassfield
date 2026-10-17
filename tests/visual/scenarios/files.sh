#!/usr/bin/env bash
# Files app on the sandbox folder.
source "$(dirname "$0")/../lib.sh"
vs_session
vs_reset
vs_spawn "$VS_DEV/build/grassfield-files" "$VS_FILES"
vs_wait_clients 1
vs_sleep 3
# free disk space in the status line
VS_MASK="880,774,1240,792" vs_capture files
