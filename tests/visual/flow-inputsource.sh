#!/usr/bin/env bash
# Input sources on the nested session: Ctrl+Space selects the previous input source and Ctrl+Option+Space the next one on EVERY
# keyboard (config/hypr/grassfield/bindings.lua), only while kb_layout has two layouts or more, and the Input menu of the menu
# bar lists them in the shell's language. Proves, with read-only nestctl queries:
#   1. injection works: a control chord (Control_L + Right, the Next Space bind) is seen by the compositor (keysyms, not "ctrl");
#   2. one layout: no CTRL+SPACE / CTRL+ALT+SPACE bind (Ctrl+Space stays with the applications);
#   3. Settings' keyboard.lua with two layouts: Hyprland reads its configuration again, both binds appear, and the Input menu
#      is in the bar; every keyboard of `devices` changes its active keymap on each chord (printed before and after);
#   4. keyboard.lua with one layout again: the binds disappear on the reload.
# Captures: $VS_SHOTS/flow-inputsource-*.png (the Input menu, Settings > Keyboard).
# Run as a BARE command on a FRESH nested session (a session left by an earlier flow dropped the injected chords once; run
# scripts/dev/nested-down.sh first), optional language:  tests/visual/flow-inputsource.sh [fr]
VISUAL_LANG=${1:-en}
export GRASSFIELD_REF_SCALE=1.25  # the owner's panel (nested-up.sh --ref-scale 1.25); a session already up keeps its own scale
source "$(dirname "$0")/flow-lib.sh"
fl_start inputsource

keyfile=$VS_DEV/config/keyboard.lua
bound() { "$VS_ROOT/scripts/nestctl" binds -j | jq -e --arg k "$1" --argjson m "$2" 'any(.[]; (.key | ascii_downcase) == "space" and .modmask == $m)' >/dev/null; }
ctrl_space() { bound space 4; }       # modmask: shift 1, ctrl 4, alt 8
ctrl_alt_space() { bound space 12; }
locked_binds() { "$VS_ROOT/scripts/nestctl" binds -j | jq -e '[.[] | select((.key | ascii_downcase) == "space" and (.modmask == 4 or .modmask == 12))] | length == 2 and all(.locked)' >/dev/null; }
show_binds() { "$VS_ROOT/scripts/nestctl" binds -j | jq -c '.[] | select((.key | ascii_downcase) == "space" and (.modmask == 4 or .modmask == 12)) | {description, modmask, key, locked}'; }
no_binds() { ! ctrl_space && ! ctrl_alt_space; }
both_binds() { ctrl_space && ctrl_alt_space; }
devices() { "$VS_ROOT/scripts/nestctl" devices -j | jq -r '.keyboards[] | "\(.name)\t\(.layout)\tactive=\(.active_keymap)"'; }
typed() { "$VS_ROOT/scripts/nestctl" devices -j | jq -r '.keyboards[] | select(.name | test("^(power|sleep|lid|video|hl-virtual-keyboard)") | not) | .active_keymap' | sort -u | paste -sd,; }
active_workspace() { "$VS_ROOT/scripts/nestctl" activeworkspace -j | jq -r .id; }

echo "NOTE: uptime: $(uptime)"

# 1. injection on a control: Ctrl+3 is the "Switch to Space 3" bind of Grassfield (a key the compositor answers whatever the
#    layout; Ctrl+arrows need a Space on the same output, which the nested session may not have)
before=$(active_workspace)
fl_chord Control_L 3
after=$(active_workspace)
fl_check "injection works: Control_L+3 switched to Space 3 ($before -> $after)" test "$after" = 3
fl_chord Control_L 2

# 2. one layout (the session's own): nothing bound
fl_check "one layout: Ctrl+Space and Ctrl+Option+Space are not bound ($(devices | head -n 3 | paste -sd';'))" no_binds

# 3. two layouts, as Settings > Keyboard writes them
printf 'return {\n  kb_layout = "fr,us",\n  kb_variant = ",",\n}\n' > "$keyfile"
fl_check_wait "the configuration is read again: both binds appear" 30 both_binds
vs_sleep 2
echo "---- nestctl binds -j (Ctrl+Space, Ctrl+Option+Space):"; show_binds
fl_check "both binds are locked (they also work at the lock screen)" locked_binds
# A second, virtual keyboard (vkbd, its own keymap) stays attached while the chords run: `devices` lists it next to the
# session's keyboard, which is what an xkb group option could not follow.
"$VS_ROOT/tests/tools/vkbd/vkbd.sh" sleep 60000 >/dev/null 2>&1 &
hold=$!
vs_sleep 1.5
echo "---- keyboards before:"; devices
start=$(typed)
fl_note "active keymap(s) of the typed keyboards before: $start"
fl_chord Control_L space
vs_sleep 0.6
one=$(typed)
echo "---- keyboards after Ctrl+Space:"; devices
fl_check "Ctrl+Space changed the active keymap of every typed keyboard together ($start -> $one)" bash -c '[[ $1 != "$2" && $1 != *,* ]]' _ "$one" "$start"
fl_chord Control_L Alt_L space
vs_sleep 0.6
two=$(typed)
echo "---- keyboards after Ctrl+Option+Space:"; devices
fl_check "Ctrl+Option+Space selected the next source on every keyboard ($one -> $two)" bash -c '[[ $1 != "$2" && $1 != *,* ]]' _ "$two" "$one"
fl_chord Control_L space
vs_sleep 0.6
three=$(typed)
fl_check "Ctrl+Space again selects the previous source (two sources: back to $one)" test "$three" = "$one"

kill "$hold" 2>/dev/null

# The Input menu: the sources in the shell's language, the one in use checked
fl_wait 15 bash -c '[[ $("$1" menubar openKind 2>/dev/null) != "refused" ]]' _ "$VS_ROOT/tests/visual/ipc.sh"
vs_ipc menubar open input "$VS_OUTPUT" >/dev/null
vs_sleep 1.5
fl_check "the Input menu opens (popup kind: $(fl_kind))" bash -c '[[ $1 == input@* ]]' _ "$(fl_kind)"
fl_shot input-menu-"$VS_LANG" >/dev/null
vs_ipc menubar close >/dev/null

# Settings > Keyboard
vs_spawn "$VS_DEV/build/grassfield-settings" --section=keyboard
class='org\.grassfield\.Settings'
fl_check_wait "Grassfield Settings opens on Keyboard" 20 fl_has_window "$class"
vs_sleep 2.5
fl_shot settings-keyboard-"$VS_LANG" >/dev/null
fl_close_windows "$class"

# 4. Settings goes back to one layout: the binds disappear with the reload
printf 'return {\n  kb_layout = "us",\n  kb_variant = "",\n}\n' > "$keyfile"
fl_check_wait "Settings leaves one layout, the configuration is read again: both binds disappear" 30 no_binds

fl_done
