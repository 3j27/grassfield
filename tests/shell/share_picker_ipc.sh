#!/usr/bin/env bash
# ADR-0035 D-6 end to end without a compositor: the stand-in (packaging/session-bin/hyprland-share-picker, a scratch copy
# whose stock picker is a recorder) asks the real SharePicker service through the real `qs ipc`, under the real Quickshell
# (tests/shell/share_picker_ipc.d/probe.qml, offscreen), and the shell answers on the one-time socket. A fake hyprctl gives
# the stand-in Hyprland's displays (the shell's own); the shell's Hyprland socket is a fake that knows nothing.
#   1 the shell accepts, connects, gets xdph's two windows and opens the panel (popup kind sharePicker); the user's choice
#     of the display with Remember this choice reaches xdph as `[SELECTION]r/screen:<display>`;
#   2 a window's choice reaches xdph as `[SELECTION]/window:<handle>`; a second request meanwhile is "busy";
#   3 the shell keeps the stand-in waiting past 15 s while the panel is open (its `wait` lines);
#   4 the stand-in ends while the panel is open: the panel and the request go within 1 s;
#   5 another popup in the panel's place: cancelled (nothing reaches xdph), the stand-in ends;
#   6 the session locks while the panel is open: cancelled; a request while locked: "locked", nothing shows;
#   7 requests not of the stand-in's form (an id that is not 128-bit hex, a socket elsewhere): "refused", nothing shows.
# The probe runs as a dev session (status and choose are dev hooks) and the stand-in reaches it through GRASSFIELD_SHELL_DIR
# (honoured in a dev session only). Nothing here can reach a real Hyprland or shell: HYPRLAND_INSTANCE_SIGNATURE and
# XDG_RUNTIME_DIR point at the test's own directory. Prints PASS/FAIL, exits non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
for v in $(compgen -e); do
  case $v in GRASSFIELD_* | QS_*) unset "$v" ;; esac
done
cd "$root"
unset QT_QPA_PLATFORMTHEME
command -v qs >/dev/null || { echo "SKIP: share_picker_ipc: Quickshell (qs) is not installed"; exit 0; }
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
tmp=$(mktemp -d "$root/.dev/share-picker-ipc.XXXXXX" 2>/dev/null || { mkdir -p "$root/.dev" && mktemp -d "$root/.dev/share-picker-ipc.XXXXXX"; })
fake="" shell="" standin="" runtime=""
cleanup() {
  local p
  for p in $fake $shell $standin; do kill "$p" 2>/dev/null || true; done
  rm -rf "$tmp" "$runtime"
}
trap cleanup EXIT
sig=gf-share-picker
# The runtime directory is short and of its own: a Unix socket's path holds at most 107 bytes (the picker's channel is
# <runtime>/grassfield/picker/<32 hex>.sock), and the test's directory can be deep in the tree.
runtime=$(mktemp -d /tmp/gfspi.XXXXXX)
mkdir -p "$runtime/hypr/$sig" "$tmp/cache" "$tmp/state" "$tmp/config" "$tmp/cfg" "$tmp/bin" "$tmp/fake" "$tmp/stock"
chmod 700 "$runtime" "$tmp/cache"
((${#runtime} + 56 <= 107)) || { echo "FAIL: share_picker_ipc: the runtime directory $runtime is too long for a socket"; exit 1; }
for entry in shell/*; do
  [[ $(basename "$entry") == shell.qml ]] || ln -s "$root/$entry" "$tmp/cfg/$(basename "$entry")"
done
cp tests/shell/share_picker_ipc.d/probe.qml "$tmp/cfg/shell.qml"

# The shell's Hyprland: requests answered with nothing, events held.
cat >"$tmp/fake.py" <<'PY'
import os, socket, sys, threading
base = sys.argv[1]
held = []
def answer(c):
    data = c.recv(65536).decode(errors="replace")
    c.sendall(b"[]" if "j/" in data[:8] else b"ok")
    held.append(c)
def serve(name, handler):
    s = socket.socket(socket.AF_UNIX)
    s.bind(os.path.join(base, name))
    s.listen(16)
    while True:
        c, _ = s.accept()
        threading.Thread(target=handler, args=(c,), daemon=True).start()
threading.Thread(target=serve, args=(".socket2.sock", held.append), daemon=True).start()
serve(".socket.sock", answer)
PY
python3 -I "$tmp/fake.py" "$runtime/hypr/$sig" &
fake=$!
for _ in $(seq 50); do [[ -S $runtime/hypr/$sig/.socket.sock && -S $runtime/hypr/$sig/.socket2.sock ]] && break; sleep 0.1; done

base_env=(-u WAYLAND_DISPLAY -u GRASSFIELD_SESSION -u DBUS_SESSION_BUS_ADDRESS -u QS_CONFIG_PATH -u QS_CONFIG_NAME -u QS_MANIFEST
  GRASSFIELD_DEV=1 GRASSFIELD_STATE_HOME="$tmp/state" GRASSFIELD_CONFIG_HOME="$tmp/config" HYPRLAND_INSTANCE_SIGNATURE="$sig"
  XDG_RUNTIME_DIR="$runtime" XDG_CACHE_HOME="$tmp/cache")
# Qt's offscreen platform names its screen only through its configuration file: two displays, as Hyprland names them.
printf '{"screens": [{"name": "DP-1", "x": 0, "y": 0, "width": 800, "height": 600, "logicalDpi": 96, "dpr": 1},
  {"name": "HDMI-A-1", "x": 800, "y": 0, "width": 640, "height": 480, "logicalDpi": 96, "dpr": 1}]}\n' >"$tmp/screens.json"
env "${base_env[@]}" QT_QPA_PLATFORM="offscreen:configfile=$tmp/screens.json" QML_IMPORT_PATH="$root/ui:$root/.dev/build/qml" \
  timeout 300 qs -p "$tmp/cfg" --no-color >"$tmp/shell.log" 2>&1 &
shell=$!
for _ in $(seq 150); do grep -q 'picker-probe: ready' "$tmp/shell.log" && break; sleep 0.1; done
ready=$(grep -o 'picker-probe: ready .*' "$tmp/shell.log" | head -1 || true)
display=$(python3 -I -c 'import json, sys; o = json.loads(sys.argv[1].split(" ")[2]); print(o[-1] if o else "")' "$ready" 2>/dev/null || true)
if [[ $ready != 'picker-probe: ready ["DP-1","HDMI-A-1"] idle' ]]; then
  echo "FAIL: share_picker_ipc: the probe shell did not come up idle with a display [$ready]"
  tail -20 "$tmp/shell.log"
  exit 1
fi
ipc() { env "${base_env[@]}" timeout 5 qs ipc -p "$tmp/cfg" call "$@" 2>&1; }
state() { ipc picker status | python3 -I -c 'import json, sys; d = json.load(sys.stdin); print(sys.argv[1] % d)' "$1"; }

# The stand-in: its stock pickers are recorders; its hyprctl lists the shell's display, unlocked.
sed "s|^STOCK_DIR = \"/usr/bin\"\$|STOCK_DIR = \"$tmp/stock\"|" packaging/session-bin/hyprland-share-picker >"$tmp/bin/hyprland-share-picker"
chmod +x "$tmp/bin/hyprland-share-picker"
printf '#!/bin/sh\necho ran >"%s/stock.ran"\n' "$tmp" >"$tmp/stock/hyprland-share-picker"
printf '#!/bin/sh\n[ "$1 $2" = "-j monitors" ] && printf %s\n' "'[{\"name\": \"$display\", \"width\": 800, \"height\": 600, \"scale\": 1, \"transform\": 0, \"solitaryBlockedBy\": []}]'" >"$tmp/fake/hyprctl"
chmod +x "$tmp/stock/hyprland-share-picker" "$tmp/fake/hyprctl"
windows='123456[HC>]org.gnome.TextEditor[HT>]notes.txt[HE>]0[HA>]777[HC>]firefox[HT>]A page[HE>]0[HA>]'
share() { # runs the stand-in as xdph does; sets `standin`
  rm -f "$tmp/stock.ran" "$tmp/standin.out"
  env "${base_env[@]}" GRASSFIELD_SHELL_DIR="$tmp/cfg" PATH="$tmp/fake:$PATH" XDPH_WINDOW_SHARING_LIST="$windows" \
    "$tmp/bin/hyprland-share-picker" --allow-token >"$tmp/standin.out" 2>"$tmp/standin.err" &
  standin=$!
}
shown_within() { local i; for ((i = 0; i < 60; i++)); do [[ $(state '%(shown)s %(popup)s') == "True sharePicker" ]] && return 0; sleep 0.05; done; return 1; }
ended_within() { local i; for ((i = 0; i < $2 * 20; i++)); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.05; done; return 1; }
idle_within() { local i; for ((i = 0; i < 20; i++)); do [[ $(state '%(open)s %(shown)s %(popup)s') == "False False " ]] && return 0; sleep 0.05; done; return 1; }

# 1.
share
desc="1 the shell accepts, connects, gets xdph's two windows and opens the panel"
check shown_within
desc="1 the windows the shell holds are xdph's, with their handles"
check test "$(state '%(windows)s')" == "[{'handle': '123456', 'appId': 'org.gnome.TextEditor', 'title': 'notes.txt', 'address': ''}, {'handle': '777', 'appId': 'firefox', 'title': 'A page', 'address': ''}]"
desc="1 the user's choice of the display with Remember this choice reaches xdph"
check test "$(ipc picker choose screen "$display" remember)" == ok
ended_within "$standin" 3 || true
check test "$(cat "$tmp/standin.out")" == "[SELECTION]r/screen:$display"
desc="1 the request and the panel are gone, the stock picker never ran, nothing on stderr"
check idle_within
check bash -c '[[ ! -e $1/stock.ran && ! -s $1/standin.err ]]' _ "$tmp"

# 2.
share
shown_within || true
desc="2 a second request while the panel is open: busy"
check test "$(ipc picker request "$(printf '%032x' 1)" "$runtime/grassfield/picker/$(printf '%032x' 2).sock")" == busy
desc="2 a window's choice reaches xdph as its handle"
check test "$(ipc picker choose window 777 no)" == ok
ended_within "$standin" 3 || true
check test "$(cat "$tmp/standin.out")" == "[SELECTION]/window:777"

# 3.
share
shown_within || true
sleep 16.5
desc="3 the panel open for 16.5 s: the stand-in still waits (the shell's wait lines), the panel still open"
check bash -c 'kill -0 "$1" && [[ ! -s $2/standin.out ]]' _ "$standin" "$tmp"
check test "$(state '%(shown)s %(popup)s')" == "True sharePicker"

# 4.
kill -TERM "$standin"
wait "$standin" 2>/dev/null || true
desc="4 the stand-in ends while the panel is open: the panel and the request go within 1 s"
check idle_within

# 5.
share
shown_within || true
desc="5 another popup in the panel's place: cancelled, nothing reaches xdph, the stand-in ends"
check test "$(ipc probe popup forcequit)" == forcequit
check bash -c 'for ((i = 0; i < 60; i++)); do kill -0 "$1" 2>/dev/null || break; sleep 0.05; done; ! kill -0 "$1" 2>/dev/null && [[ ! -s $2/standin.out && ! -e $2/stock.ran ]]' _ "$standin" "$tmp"
check test "$(state '%(open)s %(shown)s')" == "False False"
ipc probe popup "" >/dev/null || true

# 6.
share
shown_within || true
desc="6 the session locks while the panel is open: cancelled, the panel goes, nothing reaches xdph"
check test "$(ipc probe lock on)" == ok
check bash -c 'for ((i = 0; i < 60; i++)); do kill -0 "$1" 2>/dev/null || break; sleep 0.05; done; ! kill -0 "$1" 2>/dev/null && [[ ! -s $2/standin.out ]]' _ "$standin" "$tmp"
check test "$(state '%(open)s %(shown)s %(popup)s')" == "False False "
desc="6 a request while locked: locked, nothing shows"
check test "$(ipc picker request "$(printf '%032x' 3)" "$runtime/grassfield/picker/$(printf '%032x' 4).sock")" == locked
check test "$(state '%(open)s')" == False
ipc probe lock off >/dev/null

# 7.
desc="7 requests not of the stand-in's form are refused and nothing shows: an id that is not 128-bit hex, a socket elsewhere, a name that is not 128-bit hex"
check test "$(ipc picker request "$(printf '%031x' 5)" "$runtime/grassfield/picker/$(printf '%032x' 6).sock")" == refused
check test "$(ipc picker request "$(printf '%032x' 5)" "$tmp/elsewhere/$(printf '%032x' 6).sock")" == refused
check test "$(ipc picker request "$(printf '%032x' 5)" "$runtime/grassfield/picker/../$(printf '%032x' 6).sock")" == refused
check test "$(ipc picker request "$(printf '%032X' 171)" "$runtime/grassfield/picker/$(printf '%032x' 6).sock")" == refused
check test "$(state '%(open)s')" == False

if ((fail)); then tail -20 "$tmp/shell.log"; fi
exit $fail
