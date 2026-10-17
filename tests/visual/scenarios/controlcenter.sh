#!/usr/bin/env bash
# Control Center open.
source "$(dirname "$0")/../lib.sh"
vs_session
vs_reset
vs_ipc menubar open controlcenter GF-REF
vs_capture controlcenter
