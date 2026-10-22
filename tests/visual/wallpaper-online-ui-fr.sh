#!/usr/bin/env bash
# The French captures of tests/visual/wallpaper-online-ui.sh (a bare command, like wallpaper-fr.sh).
export VISUAL_LANG=fr
exec "$(dirname "$0")/wallpaper-online-ui.sh"
