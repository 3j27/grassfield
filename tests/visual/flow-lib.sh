#!/usr/bin/env bash
# Shared helpers for the in-session functional flows (tests/visual/flow-*.sh; source it, do not run it).
#
# A flow uses one module the way a user does (macOS model) in the NESTED session and asserts what happened: the shell's
# own state over its dev IPC (never pixels alone), files on disk, the windows the compositor reports (read-only
# nestctl queries), plus a screenshot per step in $VS_SHOTS/flow-<name>-*.png for the visual check. Pixels are used
# only to prove that something appeared or went away (vs_px_diff against a capture of the same desktop without it).
#
# Everything is built on tests/visual/lib.sh: vs_session starts the nested session when none is up (a flow is run as a
# BARE command, outside the Claude Code sandbox), every IPC goes through tests/visual/ipc.sh and every pointer or
# key press through scripts/dev/pointer.sh, scripts/dev/keys.sh and tests/tools/vkbd/vkbd.sh, all of which refuse
# anything but this tree's verified nested instance (dev_nested_target). Nothing here reaches the owner's session.
#
# Keys: plain keys and text go through wtype (fl_type, fl_key). Chords (Ctrl+...) go through vkbd (fl_chord): wtype
# modifiers never trigger Hyprland binds in the nested session, and vkbd is the sanctioned path.
#
# Output: one line per check, "PASS: ..." or "FAIL: ...", and "NOTE: ..." for what a step could not assert. Exit status 1
# when any check failed (fl_done).

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FL_NAME=${FL_NAME:-flow}
fl_fail=0

fl_check() { # fl_check DESCRIPTION COMMAND...
  local name=$1
  shift
  if "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fl_fail=1; fi
}
fl_note() { echo "NOTE: $*"; }

# fl_wait SECONDS COMMAND...: poll every 0.2 s until the command succeeds.
fl_wait() {
  local limit=$(( $1 * 5 )) i
  shift
  for i in $(seq 1 "$limit"); do "$@" && return 0; sleep 0.2; done
  return 1
}

# fl_check_wait DESCRIPTION SECONDS COMMAND...
fl_check_wait() {
  local name=$1 secs=$2
  shift 2
  if fl_wait "$secs" "$@"; then echo "PASS: $name"; else echo "FAIL: $name"; fl_fail=1; fi
}

fl_key() { "$VS_ROOT/scripts/dev/keys.sh" "$@" >/dev/null; vs_sleep "${FL_KEY_GAP:-0.35}"; }
fl_type() { "$VS_ROOT/scripts/dev/keys.sh" "$1" >/dev/null; vs_sleep "${FL_KEY_GAP:-0.35}"; }
# fl_tap KEYSYM: one key through the virtual keyboard (xkb keysym names: Return, Tab, Left, BackSpace, Escape ...).
fl_tap() { "$VS_ROOT/tests/tools/vkbd/vkbd.sh" tap "$1" >/dev/null; vs_sleep "${FL_KEY_GAP:-0.35}"; }
# fl_chord MOD... KEYSYM: e.g. fl_chord Control_L r, fl_chord Control_L Shift_L n.
fl_chord() {
  local args=() mods=() k last=$# i=0
  for k in "$@"; do
    i=$((i + 1))
    if (( i < last )); then args+=(down "$k" sleep 60); mods=("$k" "${mods[@]}"); else args+=(tap "$k" sleep 60); fi
  done
  for k in "${mods[@]}"; do args+=(up "$k"); done
  "$VS_ROOT/tests/tools/vkbd/vkbd.sh" "${args[@]}" >/dev/null
  vs_sleep "${FL_KEY_GAP:-0.35}"
}

# fl_appkey MODS KEY: a shortcut of the focused APP window through wtype (as tests/apps/files_sandbox.sh and
# tests/visual/preview-browse.sh do), e.g. fl_appkey ctrl r, fl_appkey ctrl+shift n. wtype modifiers reach apps but never
# Hyprland binds: for a bind use fl_chord.
fl_appkey() {
  local mods=${1//+/ } key=$2 m args=() rel=()
  for m in $mods; do args+=(-M "$m"); rel=(-m "$m" "${rel[@]}"); done
  "$VS_ROOT/scripts/dev/keys.sh" "${args[@]}" -k "$key" "${rel[@]}" >/dev/null
  vs_sleep "${FL_KEY_GAP:-0.6}"
}

fl_shot() { VS_NOPARK=${FL_NOPARK:-} vs_capture "flow-$FL_NAME-$1"; }

# ---- the compositor's windows (read-only queries) ----------------------------------------------------------------

# fl_clients CLASS_REGEX: "pid<TAB>class<TAB>title" of the mapped windows whose class matches.
fl_clients() {
  "$VS_ROOT/scripts/nestctl" clients -j 2>/dev/null | jq -r --arg re "$1" '.[] | select(.mapped and (.class | test($re))) | "\(.pid)\t\(.class)\t\(.title)"'
}
fl_has_window() { [[ -n $(fl_clients "$1") ]]; }
fl_window_count() { fl_clients "$1" | grep -c . || true; }
fl_window_title() { fl_clients "$1" | head -n 1 | cut -f3; }
fl_title_has() { fl_clients "$1" | cut -f3 | grep -qiE -- "$2"; }

# fl_close_windows CLASS_REGEX: end the processes of those windows (only ones vs_track accepts: the pid and its start time
# are recorded, then vs_kill_clients signals them after dev_may_signal's checks; never the compositor or this script).
fl_close_windows() {
  local pid
  for pid in $(fl_clients "$1" | cut -f1 | sort -u); do
    [[ $pid =~ ^[0-9]+$ ]] && vs_track "$pid"
  done
  vs_kill_clients
}

# ---- shell state over the dev IPC ---------------------------------------------------------------------------------

# fl_json TARGET FUNCTION [ARGS...]: the reply with the one level of quotes qs ipc leaves around a string removed when
# the reply is a JSON string holding JSON.
fl_json() {
  local out
  out=$(vs_ipc "$@" 2>/dev/null) || return 1
  if jq -e 'type == "string"' <<<"$out" >/dev/null 2>&1; then jq -r . <<<"$out"; else printf '%s\n' "$out"; fi
}
# fl_jq TARGET FUNCTION [ARGS...] -- JQ_FILTER: the filter applied to the reply (raw output).
fl_jq() {
  local args=() filter
  while [[ $1 != -- ]]; do args+=("$1"); shift; done
  shift
  filter=$1
  fl_json "${args[@]}" | jq -r "$filter" 2>/dev/null
}
# fl_notif KEY: a value of `notifications status` (server= history= banners= dnd= center= ...).
fl_notif() { vs_ipc notifications status 2>/dev/null | tr ' ' '\n' | sed -n "s/^$1=//p"; }
fl_kind() { vs_ipc menubar openKind 2>/dev/null | tr -d '"'; }
# fl_cc: Quick Settings state of the shell (controlcenter state).
fl_cc() { fl_json controlcenter state | jq -r "$1" 2>/dev/null; }
# fl_cfg FILTER: a value of the dev grassfield.json this tree's shell and apps share.
fl_cfg() { jq -r "$1" "$VS_DEV/config/grassfield.json" 2>/dev/null; }

fl_eq() { [[ $1 == "$2" ]]; } # fl_eq GOT WANT

# ---- start and end ------------------------------------------------------------------------------------------------

# fl_start NAME [appearance]: a nested session in a known state with no window of an earlier run.
fl_start() {
  FL_NAME=$1
  # The session set-up stops the flow on any failure (errexit, as lib.sh has it); the checks that follow never do.
  vs_session >/dev/null
  vs_reset "${2:-dark}" >/dev/null
  set +e
  trap fl_cleanup EXIT
  fl_fail=0
  local covering
  covering=$("$VS_ROOT/scripts/nestctl" clients -j | jq -r --arg n "$VS_OUTPUT" '.[] | select(.mapped) | "\(.class):\(.title)"' | head -n 5 | paste -sd, -)
  [[ -z $covering ]] || fl_note "windows already on the nested session before the flow: $covering"
  fl_focus_output
}

# fl_focus_output: make GF-REF the focused output (surfaces that open on "the focused output" must open there, not on
# WAYLAND-1). The pointer is already parked on GF-REF by vs_reset; this also asks the compositor (nestctl, nested only).
fl_focus_output() {
  "$VS_ROOT/scripts/nestctl" dispatch "hl.dsp.focus({ monitor = '$VS_OUTPUT' })" >/dev/null 2>&1 || true
  vs_pointer abs "$VS_PARK_X" "$VS_PARK_Y" >/dev/null 2>&1 || true
  vs_sleep 0.5
}

# fl_active_is CLASS_REGEX: the window with the keyboard is of that class.
fl_active_is() { [[ $("$VS_ROOT/scripts/nestctl" activewindow -j 2>/dev/null | jq -r '.class // ""') =~ $1 ]]; }

# fl_focus_class CLASS_REGEX: give the first window of that class the keyboard (the compositor's focus, then a click on
# its middle as a fallback) and wait until it has it. Keys typed before that go to whatever else holds the keyboard (the
# desktop icons took a Ctrl+I once), so every flow calls this before it types into an app.
fl_focus_class() {
  local addr n cx cy
  for n in 1 2 3; do
    fl_active_is "$1" && return 0
    addr=$("$VS_ROOT/scripts/nestctl" clients -j 2>/dev/null | jq -r --arg re "$1" '[.[] | select(.mapped and (.class | test($re)))][0].address // empty')
    [[ -n $addr ]] || { sleep 0.5; continue; }
    "$VS_ROOT/scripts/nestctl" dispatch "hl.dsp.focus({ window = 'address:$addr' })" >/dev/null 2>&1 || true
    fl_wait 2 fl_active_is "$1" && return 0
    read -r cx cy <<<"$("$VS_ROOT/scripts/nestctl" clients -j | jq -r --arg a "$addr" '.[] | select(.address == $a) | "\(.at[0] + (.size[0] / 2 | floor)) \(.at[1] + 12)"')"
    [[ -n ${cx:-} ]] && vs_pointer abs "$((cx - $("$VS_ROOT/scripts/nestctl" monitors -j | jq -r --arg n "$VS_OUTPUT" '.[] | select(.name == $n) | .x')))" "$cy" sleep 200 click >/dev/null 2>&1
    fl_wait 2 fl_active_is "$1" && return 0
  done
  fl_active_is "$1"
}

# Ends everything a flow may have left: windows it started, popups, banners, DND, settings it changed.
fl_cleanup() {
  vs_kill_clients
  # Windows the flow's apps opened (also after a failure: an info window must not outlive its flow).
  fl_close_windows '^(org\.grassfield\.(Files|Preview|Settings)|foot)$' 2>/dev/null || true
  vs_ipc menubar close >/dev/null 2>&1 || true
  vs_ipc search close >/dev/null 2>&1 || true
  vs_ipc notifications clearAll >/dev/null 2>&1 || true
  vs_ipc notifications dnd false >/dev/null 2>&1 || true
  vs_ipc widgets clearDesktop >/dev/null 2>&1 || true
  vs_ipc controlcenter appearance dark >/dev/null 2>&1 || true
  vs_ipc controlcenter transparency 0.25 >/dev/null 2>&1 || true
  vs_park >/dev/null 2>&1 || true
}

# The shell log must hold no QML error from this flow.
fl_no_qml_errors() {
  [[ $(grep -cE 'TypeError|ReferenceError|Binding loop' "$VS_DEV/shell.log") == 0 ]]
}

fl_done() {
  fl_check "no QML error in the shell log" fl_no_qml_errors
  if (( fl_fail )); then echo "$FL_NAME: FAILED"; else echo "$FL_NAME: all checks passed"; fi
  exit "$fl_fail"
}
