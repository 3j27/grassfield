#!/usr/bin/env bash
# Quick Settings with the Wi-Fi module opened (detail module in place of the grid).
source "$(dirname "$0")/../lib.sh"
vs_session
vs_reset
vs_ipc menubar open controlcenter GF-REF
vs_sleep 1
# The text of the Wi-Fi capsule opens the detail module (the icon disk toggles Wi-Fi: never clicked).
vs_pointer abs 1700 70 sleep 300 click
vs_sleep 1
vs_capture controlcenter-detail
