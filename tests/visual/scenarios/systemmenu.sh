#!/usr/bin/env bash
# System menu (first item of the menu bar) open.
source "$(dirname "$0")/../lib.sh"
vs_session
vs_reset
vs_ipc menubar open system GF-REF
vs_capture systemmenu
