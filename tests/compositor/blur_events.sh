#!/usr/bin/env bash
# What Hyprland emits on socket2 around the shell's blur push (GF-125), and that the shell neither loops nor drops a real reload.
# Nested only (scripts/nestctl; refuses the main session). Needs a running nested session with the shell:
#   scripts/dev/nested-up.sh ; tests/compositor/blur_events.sh ; scripts/dev/nested-down.sh
#
# Stages (each is a slice of the stamped socket2 log .dev/blur-events/run-*/events.log and of .dev/shell.log):
#   A  the transparency changes (settings file): the shell pushes `hl.config` once; which events does Hyprland emit?
#   B  a real config reload (touch config/hypr/dev.lua): Hyprland emits "configreloaded"; the shell pushes again, once
#   C  Reduce Motion on for 30 s: no repeated push (count the "push motion" / "push blur" lines)
#   D  the answers: a valid push is answered "ok", an unknown key "error: ...", and neither emits a socket2 event
# Exit: 0 PASS, 1 FAIL, 2 environment error.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_nested_target "$dev" || exit 2
sig=$DEV_NESTED_SIG
main=$(cat "$dev/main.instance" 2>/dev/null || true)
if [[ $sig == "$main" || $sig == "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  echo "blur_events: refusing: recorded nested instance is the main session" >&2
  exit 2
fi
for tool in socat jq; do
  command -v "$tool" >/dev/null || { echo "blur_events: $tool is needed" >&2; exit 2; }
done
nestctl() { timeout 10 "$root/scripts/nestctl" "$@"; }

run=$dev/blur-events/run-$(date +%Y%m%d-%H%M%S)
mkdir -p "$run"
events=$run/events.log
summary=$run/summary.txt
shelllog=$dev/shell.log
cfg=$dev/config/grassfield.json
cfg_backup=$run/grassfield.json.orig
cp "$cfg" "$cfg_backup"
fail=0

say() { printf '%s\n' "$*" | tee -a "$summary"; }
check() { # <description> <0|1> [detail]
  if [[ $2 == 0 ]]; then say "  PASS $1${3:+ ($3)}"; else say "  FAIL $1${3:+ ($3)}"; fail=1; fi
}
lines() { [[ -r $1 ]] && wc -l <"$1" || echo 0; }
since() { tail -n +"$(($2 + 1))" "$1" 2>/dev/null; }

socat_pid=""
cleanup() {
  [[ -n $socat_pid ]] && kill "$socat_pid" 2>/dev/null
  cp "$cfg_backup" "$cfg"
}
trap cleanup EXIT

stamp() { local l; while IFS= read -r l; do printf '%s %s\n' "${EPOCHREALTIME/./}" "$l"; done; }
socat -u UNIX-CONNECT:"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr/$sig/.socket2.sock" STDOUT 2>>"$run/socat.err" </dev/null > >(stamp >"$events") &
socat_pid=$!
sleep 0.5

setcfg() { # <jq filter>: edit the nested settings file (the shell follows it live)
  local tmp
  tmp=$(mktemp "$run/cfg.XXXXXX")
  jq "$1" "$cfg" >"$tmp" && mv "$tmp" "$cfg"
}
names() { awk '{print $2}' | sed 's/>>.*//' | sort | uniq -c | sort -rn; }
blur_size() { nestctl -j getoption decoration:blur:size 2>/dev/null | jq -r '.int // empty'; }

say "blur_events $(date '+%F %T') instance $sig"
say "blur size at start: $(blur_size)"

# ---- A: the transparency changes ------------------------------------------------------------------------------
say "A. transparency 0.25 -> 0.6"
e0=$(lines "$events")
l0=$(lines "$shelllog")
setcfg '.material = ((.material // {}) + {transparency: 0.6})'
sleep 3
say "  events:"
since "$events" "$e0" | tee -a "$summary" | sed 's/^/    /'
say "  shell log:"
since "$shelllog" "$l0" | grep -a "push\|rejected" | tee -a "$summary" | sed 's/^/    /'
pushes_a=$(since "$shelllog" "$l0" | grep -ac "push blur size")
say "  blur size now: $(blur_size)"
check "one push for one change" "$((pushes_a == 1 ? 0 : 1))" "$pushes_a pushes"
check "Hyprland has size 26 (12 + 24 x 0.6 = 26.4)" "$([[ $(blur_size) == 26 ]] && echo 0 || echo 1)" "size $(blur_size)"

# ---- B: a real config reload ----------------------------------------------------------------------------------
say "B. real config reload (touch config/hypr/dev.lua)"
e0=$(lines "$events")
l0=$(lines "$shelllog")
touch "$root/config/hypr/dev.lua"
sleep 4
say "  events:"
since "$events" "$e0" | tee -a "$summary" | sed 's/^/    /'
say "  shell log:"
since "$shelllog" "$l0" | grep -a "push\|rejected" | tee -a "$summary" | sed 's/^/    /'
reloads_b=$(since "$events" "$e0" | grep -ac "configreloaded")
pushes_b=$(since "$shelllog" "$l0" | grep -ac "push blur size")
say "  blur size after the reload: $(blur_size)"
check "Hyprland announced the reload" "$((reloads_b >= 1 ? 0 : 1))" "$reloads_b configreloaded"
check "the reload was honoured: the shell pushed the blur again, once" "$((pushes_b == 1 ? 0 : 1))" "$pushes_b pushes"
check "the blur is 26 again after the reload" "$([[ $(blur_size) == 26 ]] && echo 0 || echo 1)" "size $(blur_size)"

# ---- C: Reduce Motion on for 30 s -------------------------------------------------------------------------------
say "C. Reduce Motion on, 30 s"
e0=$(lines "$events")
l0=$(lines "$shelllog")
setcfg '.accessibility = ((.accessibility // {}) + {reduceMotion: true})'
sleep 30
say "  event names:"
since "$events" "$e0" | names | tee -a "$summary" | sed 's/^/    /'
say "  shell log pushes:"
since "$shelllog" "$l0" | grep -a "push" | tee -a "$summary" | sed 's/^/    /'
motion_c=$(since "$shelllog" "$l0" | grep -ac "push motion")
blur_c=$(since "$shelllog" "$l0" | grep -ac "push blur")
check "one motion push for the change, no repeat in 30 s" "$((motion_c == 1 ? 0 : 1))" "$motion_c motion pushes"
check "no blur push from Reduce Motion" "$((blur_c == 0 ? 0 : 1))" "$blur_c blur pushes"
setcfg '.accessibility.reduceMotion = false'
sleep 2

# ---- D: the answers (these payloads are the ones tst_minimized.qml feeds Minimized.blurAnswer) ----------------------------
say "D. answers of the request socket"
e0=$(lines "$events")
ok_reply=$(nestctl dispatch "function() hl.config({ decoration = { blur = { size = 26, passes = 3 } } }) end" 2>&1)
bad_reply=$(nestctl dispatch "function() hl.config({ decoration = { blur = { no_such_key_gf = 1 } } }) end" 2>&1)
sleep 2
say "  valid push answer:   $ok_reply"
say "  unknown key answer:  $bad_reply"
say "  events:"
since "$events" "$e0" | tee -a "$summary" | sed 's/^/    /'
check "a valid push is answered ok" "$([[ $ok_reply == ok ]] && echo 0 || echo 1)"
check "an unknown key is answered with an error" "$([[ $bad_reply == error:* ]] && echo 0 || echo 1)"
check "neither push emitted a socket2 event" "$(( $(since "$events" "$e0" | wc -l) == 0 ? 0 : 1 ))"
check "the blur is still 26" "$([[ $(blur_size) == 26 ]] && echo 0 || echo 1)" "size $(blur_size)"

say "summary: $summary; events: $events"
exit "$fail"
