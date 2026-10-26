#!/usr/bin/env bash
# Electron global menus end to end in the nested session (ADR-0008 amendment 2026-10-25; docs/specs/menu-bridge.md MB2,
# MB12, MB17; compositor FR20).
#
#   Obsidian (Electron, Wayland), offline in a throwaway home (updates disabled, every request sent to a dead proxy), on a
#   one-note vault:
#     - it registers its window with com.canonical.AppMenu.Registrar (bridge log "RegisterWindow from :1.N kept") and the
#       menu bar shows its own menus (File, Edit, View ... Help): the plugin reports the window's client pid, the shell
#       sends open-registered, the bridge serves the registration of that process (bridge log: the window's pid);
#     - File > New Window clicked with the (virtual) pointer opens a second window: an Obsidian click handler that runs
#       only for its focused window, so the action must arrive once the window has the keyboard back (MB12, the plugin's
#       keyboard-focus event); the second window shows Obsidian's menus too, read once its registration settled (no layout
#       failure in the bridge log);
#     - File > Close Window (a role item) closes the second window; the first one shows its menus again;
#     - File > Quit closes the app (process gone).
#   The scenario runs ROUNDS times in the same session (a fresh Obsidian each round): the action's timing is a race
#   against the keyboard's return, which one round cannot show (review of 9ba1d40: a fixed wait failed 1 run in 3).
#   SKIP when obsidian is not installed. Screenshots (round 1): .dev/shots/electron-menus-*.png (scripts/dev/shot.sh).
#
# Usage: tests/integration/electron_menus.sh [ROUNDS]   (default 1; restarts the nested session of this checkout; run it
#                                                       outside the Claude Code sandbox: it starts the nested compositor)
# Exit: 0 PASS (or SKIP), 1 FAIL, 2 environment error. Summary: .dev/electron-menus/run-<stamp>/summary.txt
#
# SAFETY: the registrar, the bridge and Obsidian share the nested shell's PRIVATE bus (.dev/bus.address, checked to be a
# /tmp/dbus-* socket); Obsidian gets the nested Wayland socket only and an isolated home under .dev/isolated (through
# scripts/dev/isolated.sh), with its updates disabled and http(s) sent to 127.0.0.1:9 (no network). hyprctl is used
# read-only through scripts/nestctl; input goes through scripts/dev/pointer.sh (nested only). Obsidian is stopped by its
# process group.
set -uo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
# shellcheck source=../../scripts/dev/pidfile.sh
. "$root/scripts/dev/pidfile.sh"
dev_require_host electron_menus
nested_sock() { dev_nested_target "$dev" && echo "$DEV_NESTED_SOCK"; }
run=$dev/electron-menus/run-$(date +%Y%m%d-%H%M%S)
mkdir -p "$run"
summary=$run/summary.txt
output=GF-REF
class=md.obsidian.Obsidian
fail=0
rounds=${1:-1}
[[ $rounds =~ ^[1-9][0-9]?$ ]] || { echo "usage: electron_menus.sh [ROUNDS 1-99]" >&2; exit 2; }

say() { printf '%s\n' "$*" | tee -a "$summary"; }
check() { # <description> <command...>
  local what=$1
  shift
  if "$@"; then say "  PASS $what"; else say "  FAIL $what"; fail=1; fi
}
die() { say "ENVIRONMENT: $*"; exit 2; }

if ! command -v obsidian >/dev/null; then
  say "SKIP electron menus: obsidian is not installed"
  exit 0
fi
for tool in jq qs grim; do
  command -v "$tool" >/dev/null || die "$tool is needed"
done

# ---- builds ------------------------------------------------------------------------------------------------------
[[ -f $root/compositor/build/grassfield-compositor.so ]] || "$root/compositor/build-direct.sh" plugin || die "plugin build failed"
[[ -x $dev/build/grassfield-menu-bridge ]] || "$root/bridges/menu-bridge/build-direct.sh" >/dev/null || die "bridge build failed"

# ---- helpers -----------------------------------------------------------------------------------------------------
ob_pid=""
stop_obsidian() {
  [[ -n $ob_pid ]] || return 0
  kill -- "-$ob_pid" 2>/dev/null
  sleep 1
  kill -9 -- "-$ob_pid" 2>/dev/null
}
trap 'stop_obsidian; "$root/scripts/dev/nested-down.sh" >/dev/null 2>&1' EXIT

private_bus() {
  local bus
  bus=$(cat "$dev/bus.address" 2>/dev/null) || return 1
  case $bus in unix:path=/tmp/dbus-*) printf '%s\n' "$bus" ;; *) return 1 ;; esac
}

state() { # menu bar test hook (JSON)
  local pid
  pid=$(dev_live_pid "$dev/shell.pid") || return 1
  QT_QPA_PLATFORM=offscreen timeout 5 qs ipc --pid "$pid" call menubar bridgeState "$output" 2>/dev/null
}

wait_for() { # <seconds> <command...>
  local deadline=$((SECONDS + $1))
  shift
  while ((SECONDS < deadline)); do
    "$@" && return 0
    sleep 0.3
  done
  return 1
}

clients() { "$root/scripts/nestctl" clients -j 2>/dev/null; }
windows() { clients | jq --arg c "$class" '[.[] | select(.class == $c and .mapped)] | length'; }
has_windows() { [[ $(windows) -ge $1 ]]; }
windows_at_most() { [[ $(windows) -le $1 ]]; }
focused_address() { # hex address (no 0x) of the most recently focused Obsidian window
  clients | jq -r --arg c "$class" '[.[] | select(.class == $c)] | sort_by(.focusHistoryID) | .[0].address // "" | ltrimstr("0x")'
}
client_pid() { clients | jq -r --arg c "$class" '[.[] | select(.class == $c)][0].pid // 0'; }
on_wayland() { [[ $(clients | jq --arg c "$class" '[.[] | select(.class == $c and .xwayland)] | length') == 0 ]]; }
exited() { local stat; stat=$(ps -o stat= -p "$1" 2>/dev/null); [[ -z $stat || $stat == Z* ]]; }

menus_are() { # <address> <jq expression over .menus, true when as wanted>
  local s
  s=$(state) || return 1
  jq -e --arg w "$1" ".window == \$w and ($2)" <<<"$s" >/dev/null
}
obsidian_menus='(.menus | index("File")) != null and (.menus | index("Edit")) != null and (.menus | index("Help")) != null and (.menus | length) >= 4'

center_of_title() { # <title> -> "x y" of that bridge title in the bar
  state | jq -r --arg t "$1" '.bar[] | select(.kind == "bridge" and .title == $t) | "\(.x + (.w / 2 | floor)) \(.y + (.h / 2 | floor))"' | head -n 1
}
row_of() { # <regex> -> "x y w h" of the first popup row whose text matches
  state | jq -r --arg r "$1" '[.popup[]? | select(.text | test($r))][0] // empty | "\(.x) \(.y) \(.w) \(.h)"'
}
row_present() { [[ -n $(row_of "$1") ]]; }
point() { "$root/scripts/dev/pointer.sh" output "$output" "$@" >/dev/null; }
click_title() { # <title>
  local xy
  xy=$(center_of_title "$1")
  [[ -n $xy ]] || return 1
  # shellcheck disable=SC2086
  point abs $xy sleep 150 click sleep 300
}
# Opens a title's menu until it shows a row: Obsidian builds its full menu once its vault is loaded, and until then the
# same titles hold a short menu (File: Open Vault..., Close, Quit; one round in ten in a run of 2026-10-26). The menu is
# closed (Escape: the popup holds the keyboard) and opened again, 8 times at most; a try beyond the first is logged.
open_menu_with() { # <title> <row regex>
  local i
  for i in 1 2 3 4 5 6 7 8; do
    if click_title "$1" && wait_for 3 row_present "$2"; then
      ((i > 1)) && say "    ($1 showed '$2' at try $i: the application was still building its menu)"
      return 0
    fi
    "$root/scripts/dev/keys.sh" -k Escape >/dev/null 2>&1
    sleep 1
  done
  return 1
}

click_row() { # <regex>
  local x y w h
  read -r x y w h <<<"$(row_of "$1")"
  [[ -n ${x:-} ]] || return 1
  point abs $((x + w / 3)) $((y + h / 2)) sleep 150 click sleep 300
}
# The bridge log of this run only (the file may hold earlier sessions).
log_from=1
bridge_log() { tail -n "+$log_from" "$dev/menu-bridge.log" 2>/dev/null; }
bridge_log_has() { bridge_log | grep -a -q -E -- "$1"; }

say "electron menus run $run"

# ---- session -----------------------------------------------------------------------------------------------------
"$root/scripts/dev/nested-down.sh" >/dev/null 2>&1
log_from=$(($(wc -l <"$dev/menu-bridge.log" 2>/dev/null || echo 0) + 1))
"$root/scripts/dev/nested-up.sh" --private-bus >"$run/nested-up.log" 2>&1 || die "nested session did not start (see $run/nested-up.log)"
# A log rewritten by the new bridge is shorter than the old one: then all of it is this run's.
(($(wc -l <"$dev/menu-bridge.log" 2>/dev/null || echo 0) + 1 < log_from)) && log_from=1
wait_for 15 test -S "$dev/run/menu-bridge.sock" || die "no bridge socket"
wait_for 20 bridge_log_has "shell connected" || die "the shell did not connect to the bridge"
bus=$(private_bus) || die "no private bus address"
say "  private bus: $bus"
wait_for 15 bridge_log_has "owning com.canonical.AppMenu.Registrar" || die "the bridge does not own the registrar"
point abs 960 600 sleep 200

# ---- Obsidian ----------------------------------------------------------------------------------------------------
say ""
say "[Electron] Obsidian (Electron $(cat /usr/lib/electron43/version 2>/dev/null || echo "?")), $rounds round(s)"
sock=$(nested_sock) || die "no nested Wayland socket"
proxy=http://127.0.0.1:9
failed_rounds=0

scenario() { # <round>: one Obsidian from start to Quit; returns 1 when a check of the round failed
  local r=$1 fail_before=$fail name=el-obsidian cfg vault first cpid second
  log_round=$(($(wc -l <"$dev/menu-bridge.log" 2>/dev/null || echo 0) + 1))
  rm -rf "${dev:?}/isolated/$name"
  cfg=$dev/isolated/$name/config/obsidian
  vault=$run/vault-$r
  mkdir -p "$cfg" "$vault"
  printf '# A note\n' >"$vault/note.md"
  jq -n --arg p "$vault" '{updateDisabled: true, vaults: {"656c6d656e757331": {path: $p, ts: 1, open: true}}}' >"$cfg/obsidian.json"
  http_proxy=$proxy https_proxy=$proxy all_proxy=$proxy no_proxy="" WAYLAND_DISPLAY=$sock DBUS_SESSION_BUS_ADDRESS=$bus \
    ELECTRON_OZONE_PLATFORM_HINT=wayland \
    setsid "$root/scripts/dev/isolated.sh" --name "$name" -- obsidian --proxy-server=127.0.0.1:9 >"$run/obsidian-$r.out" 2>&1 </dev/null &
  ob_pid=$!

  check "[$r] Obsidian window mapped" wait_for 40 has_windows 1
  check "[$r] Obsidian runs on Wayland (not XWayland)" on_wayland
  first=$(focused_address)
  cpid=$(client_pid)
  say "  [$r] window $first \"$(clients | jq -r --arg c "$class" '[.[] | select(.class == $c)][0].title // ""')\", client pid $cpid (started $ob_pid)"
  check "[$r] Obsidian registered its window with the registrar (bridge log)" wait_for 20 round_log_has "registrar: RegisterWindow from :[0-9.]+ kept"
  check "[$r] menu bar shows Obsidian's own menus (File, Edit ... Help)" wait_for 20 menus_are "$first" "$obsidian_menus"
  say "  [$r] bar: $(state | jq -c '[.bar[] | if .kind == "bridge" then .title else .kind end]')"
  check "[$r] the bridge served the registration to the window's client pid $cpid" round_log_has "window $first: menu :[0-9.]+ /com/canonical/menu/[0-9A-F]+ \(pid $cpid,"
  ((r == 1)) && say "  screenshot: $("$root/scripts/dev/shot.sh" electron-menus-bar "$output")"

  check "[$r] File menu open with New Window" open_menu_with File '^New Window$'
  ((r == 1)) && say "  File rows: $(state | jq -c '[.popup[]?.text]')"
  ((r == 1)) && say "  screenshot: $("$root/scripts/dev/shot.sh" electron-menus-file "$output")"
  click_row '^New Window$'
  check "[$r] pointer click on File > New Window opened a second window (focused-window click handler)" wait_for 15 has_windows 2
  second=$(focused_address)
  check "[$r] the second window shows Obsidian's menus" wait_for 20 menus_are "$second" '(.menus | index("File")) != null'
  check "[$r] no layout failure in the bridge log (registrations served once settled)" test -z "$(round_log | grep -a 'GetLayout on .*failed\|refused: this application')"

  check "[$r] second window's File menu open with Close Window" open_menu_with File '^Close( Window)?$'
  click_row '^Close( Window)?$'
  check "[$r] pointer click on File > Close Window closed the second window" wait_for 15 windows_at_most 1
  check "[$r] the remaining window shows Obsidian's menus again" wait_for 20 menus_are "$first" "$obsidian_menus"

  check "[$r] File menu open with Quit" open_menu_with File '^Quit$'
  click_row '^Quit$'
  check "[$r] pointer click on File > Quit closed every window" wait_for 15 windows_at_most 0
  check "[$r] Obsidian exited" wait_for 15 exited "$ob_pid"
  round_log | grep -a "registrar\|window .*menu\|activate\|registered" | tail -n 12 >>"$summary"
  stop_obsidian
  check "[$r] no process of Obsidian's group left" test -z "$(pgrep -g "$ob_pid" 2>/dev/null)"
  ob_pid=""
  ((fail == fail_before))
}

# The bridge log of the current round only.
log_round=1
round_log() { tail -n "+$log_round" "$dev/menu-bridge.log" 2>/dev/null; }
round_log_has() { round_log | grep -a -q -E -- "$1"; }

for r in $(seq 1 "$rounds"); do
  if scenario "$r"; then say "  round $r: PASS"; else say "  round $r: FAIL"; failed_rounds=$((failed_rounds + 1)); fi
  point abs 960 600 sleep 200
done
say "rounds: $rounds, failed: $failed_rounds"
bridge_log >"$run/menu-bridge.log"
cp "$dev/shell.log" "$run/shell.log"

# ---- cleanup -----------------------------------------------------------------------------------------------------
"$root/scripts/dev/nested-down.sh" >"$run/nested-down.log" 2>&1
trap - EXIT
say ""
if ((fail)); then
  say "RESULT: FAIL (summary $summary)"
  exit 1
fi
say "RESULT: PASS (summary $summary)"
exit 0
