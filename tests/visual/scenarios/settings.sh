#!/usr/bin/env bash
# Settings app, Appearance page.
source "$(dirname "$0")/../lib.sh"
vs_session
vs_reset
vs_spawn "$VS_DEV/build/grassfield-settings"
vs_wait_clients 1
vs_sleep 2
vs_capture settings
