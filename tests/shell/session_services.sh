#!/usr/bin/env bash
# The Omarchy services that Grassfield drops (audit 02 §5.3) and their Grassfield counterparts: crash and low-battery
# notifications, the clickable migrations notice, Night Shift, screenshots, removable media. Logic with fakes (no session,
# no D-Bus, no battery needed) plus static checks of the units, drop-ins, autostart and PKGBUILD that must agree.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/session-services.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
pk=$root/packaging

# --- low battery -------------------------------------------------------------------------------------------------------
cat >"$tmp/battery.py" <<'PY'
import importlib.machinery, importlib.util, os, sys, tempfile
sys.dont_write_bytecode = True  # no __pycache__ in packaging/bin (it would be packaged)
loader = importlib.machinery.SourceFileLoader("battery", sys.argv[1] + "/packaging/bin/grassfield-battery-watch")
spec = importlib.util.spec_from_loader("battery", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
last, out = None, []
for cap, status in [(25, "Discharging"), (20, "Discharging"), (19, "Discharging"), (12, "Discharging"), (10, "Discharging"), (9, "Discharging"),
                    (5, "Discharging"), (4, "Discharging"), (5, "Charging"), (18, "Discharging"), (22, "Discharging"), (15, "Discharging"), (3, "Full")]:
    level, last = m.next_warning(last, cap, status)
    out.append(str(level))
print("levels", " ".join(out))
d = tempfile.mkdtemp()
print("no battery", m.read_battery(d))
os.makedirs(d + "/BAT0"); open(d + "/BAT0/capacity", "w").write("17\n"); open(d + "/BAT0/status", "w").write("Discharging\n")
print("battery", m.read_battery(d))
os.environ["GRASSFIELD_POWER_SUPPLY"] = d + "/none"
print("exit-without-battery", m.main())
PY
out=$(python3 -I "$tmp/battery.py" "$root")
desc="low battery: one warning each time the charge falls through 20, 10 and 5 percent; re-armed by charging or going above 20"
check grep -qx "levels None 20 None None 10 None 5 None None 20 None 20 None" <<<"$out"
desc="low battery: reads sysfs, and a machine without a battery exits cleanly"
check bash -c 'grep -qx "no battery None" <<<"$1" && grep -qx "battery (17, .Discharging.)" <<<"$1" && grep -qx "exit-without-battery 0" <<<"$1"' _ "$out"

# --- crash notifications -----------------------------------------------------------------------------------------------
cat >"$tmp/crash.py" <<'PY'
import importlib.machinery, importlib.util, os, sys
sys.dont_write_bytecode = True  # no __pycache__ in packaging/bin (it would be packaged)
loader = importlib.machinery.SourceFileLoader("crash", sys.argv[1] + "/packaging/bin/grassfield-crash-watch")
spec = importlib.util.spec_from_loader("crash", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
uid = os.getuid(); last = {}
def e(**kw):
    d = {"_UID": str(uid), "COREDUMP_PID": "123", "COREDUMP_EXE": "/usr/bin/firefox", "COREDUMP_COMM": "firefox-bin"}; d.update(kw); return d
print("name", m.interesting(e(), uid, last, 1000.0))
print("comm-fallback", m.interesting(e(COREDUMP_EXE="", COREDUMP_COMM="thing"), uid, last, 1000.0))
print("other-user", m.interesting(e(_UID=str(uid + 1)), uid, last, 1000.0))
print("bad-pid", m.interesting(e(COREDUMP_PID="x; rm"), uid, last, 1000.0))
last["firefox"] = 1000.0
print("deduped", m.interesting(e(), uid, last, 1030.0))
print("deduped-9min", m.interesting(e(), uid, last, 1000.0 + 540))
print("after-window", m.interesting(e(), uid, last, 1000.0 + 601))
print("cap", m.under_cap([0.0, 10.0, 20.0, 30.0, 40.0, 50.0], 100.0), m.under_cap([0.0, 10.0, 20.0, 30.0, 40.0, 50.0], 3700.0), m.under_cap([0.0] * 5, 100.0))
print("own", m.interesting(e(COREDUMP_EXE="/usr/lib/grassfield/grassfield-crash-watch"), uid, last, 5000.0))
PY
out=$(python3 -I "$tmp/crash.py" "$root")
desc="crash notifications: this user's crashes only, named by the executable, one per program per 10 minutes, at most 6 an hour, never our own"
check bash -c 'grep -qx "name firefox" <<<"$1" && grep -qx "comm-fallback thing" <<<"$1" && grep -qx "other-user None" <<<"$1" && grep -qx "bad-pid None" <<<"$1" && grep -qx "deduped None" <<<"$1" && grep -qx "deduped-9min None" <<<"$1" && grep -qx "after-window firefox" <<<"$1" && grep -qx "cap False True True" <<<"$1" && grep -qx "own None" <<<"$1"' _ "$out"

# --- migrations notice (clickable) -------------------------------------------------------------------------------------
mkdir -p "$tmp/bin"
cat >"$tmp/bin/omarchy-migrate" <<'SH'
#!/bin/sh
printf '%s\n' $FAKE_PENDING
SH
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/busctl"
printf '#!/bin/sh\necho "notify-send $*" >>"$FAKE_LOG"\nprintf "%%s" "$FAKE_ANSWER"\n' >"$tmp/bin/notify-send"
printf '#!/bin/sh\necho "systemd-run $*" >>"$FAKE_LOG"\n' >"$tmp/bin/systemd-run"
chmod +x "$tmp/bin"/*
migrate() { : >"$tmp/log"; FAKE_LOG=$tmp/log FAKE_PENDING="$1" FAKE_ANSWER="$2" XDG_RUNTIME_DIR=$tmp PATH="$tmp/bin:/usr/bin:/bin" bash "$pk/bin/grassfield-migrate-notify" >/dev/null 2>&1 || true; }
desc="migrations notice: a click (default action) opens Omarchy's migration terminal through the user manager"
migrate "1 2" default
check bash -c 'grep -q "notify-send .*-A default=Run .*Click to run 2 pending migrations" "$1/log" && grep -q "systemd-run --user --collect --quiet -- omarchy-launch-floating-terminal-with-presentation omarchy-migrate" "$1/log"' _ "$tmp"
desc="migrations notice: dismissed without a click starts nothing"
migrate "1" ""
check bash -c 'grep -q "Click to run 1 pending migration\." "$1/log" && ! grep -q systemd-run "$1/log"' _ "$tmp"
desc="migrations notice: nothing pending, nothing shown"
migrate "" ""
check bash -c '[[ ! -s "$1/log" ]]' _ "$tmp"

# --- Night Shift ---------------------------------------------------------------------------------------------------------
cat >"$tmp/bin/hyprctl" <<'SH'
#!/bin/sh
# hyprctl hyprsunset temperature [N]
if [ -n "${3:-}" ]; then echo "$3" >"$FAKE_DIR/temp"; echo ok; else cat "$FAKE_DIR/temp"; fi
SH
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/pgrep"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/hyprsunset"
chmod +x "$tmp/bin"/*
printf '#!/bin/sh\nFAKE_DIR=%s PATH=%s/bin:/usr/bin:/bin exec bash %s/bin/grassfield-nightshift "$@"\n' "$tmp" "$tmp" "$pk" >"$tmp/ns"
chmod +x "$tmp/ns"
echo 6500 >"$tmp/temp"
desc="Night Shift: status, toggle on (4000 K), toggle off (6500 K), explicit on/off"
check bash -c '[[ $("$1" status) == off ]] && "$1" toggle && [[ $("$1" status) == on && $(cat "$2/temp") == 4000 ]] && "$1" toggle && [[ $("$1" status) == off && $(cat "$2/temp") == 6500 ]] && "$1" on && [[ $(cat "$2/temp") == 4000 ]] && "$1" off && [[ $(cat "$2/temp") == 6500 ]]' _ "$tmp/ns" "$tmp"

# --- screenshots, autostart, units, packaging ---------------------------------------------------------------------------
sys=$root/config/hypr/grassfield/system.lua
desc="screenshots: Super+Shift+3/4/5 (by keycode) and Print run Omarchy's capture tool (screen, selection, picker)"
check bash -c 'grep -q "SUPER + SHIFT + code:12\", capture(\"fullscreen\")" "$1" && grep -q "SUPER + SHIFT + code:13\", capture(\"region\")" "$1" && grep -q "SUPER + SHIFT + code:14\", capture(\"smart\")" "$1" && grep -q "bind(\"PRINT\"" "$1" || grep -q "hl.bind(\"PRINT\", capture(\"smart\")" "$1"' _ "$sys"

auto=$root/config/hypr/grassfield/autostart.lua
for unit in crash-watch battery-watch migrate-notify automount; do
  desc="grassfield-$unit.service: started by the session, skips itself outside it, hardened, installed by the PKGBUILD"
  u=$pk/systemd/grassfield-$unit.service
  check bash -c 'grep -q "grassfield-$3.service" "$1" && grep -qx "ConditionEnvironment=GRASSFIELD_SESSION=1" "$2" && grep -qx "NoNewPrivileges=yes" "$2" && grep -qx "ProtectSystem=strict" "$2" && grep -qx "PrivateTmp=yes" "$2" && grep -q "grassfield-\$unit.service" "$4" && grep -q "for unit in .*$3" "$4"' _ "$auto" "$u" "$unit" "$pk/arch/PKGBUILD"
done
for unit in omarchy-crash-watch omarchy-migrate-notify omarchy-update-user-notify; do
  desc="drop-in keeps Omarchy's $unit.service out of the Grassfield session only"
  d=$pk/systemd/$unit.service.d/10-grassfield.conf
  check bash -c 'grep -qx "ConditionEnvironment=!GRASSFIELD_SESSION=1" "$1" && grep -q "$2" "$3"' _ "$d" "$unit" "$pk/arch/PKGBUILD"
done
desc="every helper in packaging/bin and packaging/shims is executable and installed by one PKGBUILD line (regular files only)"
check bash -c 'for f in "$1"/bin/* "$1"/shims/*; do [[ -d $f || -x $f ]] || exit 1; done; grep -qF "find \"\$root/packaging/bin\" -maxdepth 1 -type f -exec install -m755 -t \"\$pkgdir/usr/lib/grassfield/\" {} +" "$1/arch/PKGBUILD" && grep -qF "find \"\$root/packaging/shims\" -maxdepth 1 -type f -exec install -m755 -t \"\$pkgdir/usr/lib/grassfield/omarchy-shims/\" {} +" "$1/arch/PKGBUILD"' _ "$pk"

desc="the install lines skip a directory in packaging/bin (an ignored __pycache__ must neither break nor enter the package)"
check bash -c 'w=$(mktemp -d) && mkdir -p "$w/packaging/bin/__pycache__" "$w/out" && printf "x\n" >"$w/packaging/bin/tool" && root=$w pkgdir=$w/pkg && mkdir -p "$pkgdir/usr/lib/grassfield" && eval "$(grep -F "find \"\$root/packaging/bin\" -maxdepth 1 -type f" "$1/arch/PKGBUILD")" && [[ -x $pkgdir/usr/lib/grassfield/tool && ! -e $pkgdir/usr/lib/grassfield/__pycache__ ]]; rc=$?; rm -rf "$w"; exit $rc' _ "$pk"
desc="the .install scriptlet runs the login check and is declared by the PKGBUILD"
check bash -c 'grep -q "grassfield-login-check" "$1/arch/grassfield-desktop.install" && grep -q "^  install=grassfield-desktop.install" "$1/arch/PKGBUILD" && grep -q "^  backup=(etc/sddm.conf.d/grassfield.conf)" "$1/arch/PKGBUILD"' _ "$pk"
desc="autostart runs the Omarchy post-boot hooks, the power profile and the lid reconcile (what Omarchy's autostart did)"
check bash -c 'grep -q "omarchy-hook post-boot" "$1" && grep -q "omarchy-powerprofiles-init" "$1" && grep -q "grassfield-lid reconcile" "$1"' _ "$auto"

exit $fail
