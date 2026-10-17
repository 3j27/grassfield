#!/usr/bin/env bash
# Plugin titlebar of one foot window (needs compositor/build/grassfield-compositor.so).
source "$(dirname "$0")/../lib.sh"
vs_session
vs_reset
vs_foot 'Terminal' 70x18
vs_wait_clients 1
vs_capture titlebar
