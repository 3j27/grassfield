#!/usr/bin/env bash
# The Omarchy services that Grassfield drops (audit 02 §5.3) and their Grassfield counterparts: crash and low-battery
# notifications, the clickable migrations notice, Night Shift, screenshots, removable media. Logic with fakes (no session,
# no D-Bus, no battery needed) plus static checks of the units, drop-ins, autostart and PKGBUILD that must agree.
set -euo pipefail
export LC_ALL=C; unset GRASSFIELD_LANG LC_MESSAGES  # the helpers translate by locale: the assertions read the English source
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

# --- crash notifications: the notice rules and their fixtures are in tests/shell/crash_watch.sh --------------------------------

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
desc="migrations notice: in a French session the title, text and button are French (GRASSFIELD_LANG fr_FR.UTF-8 or fr; en stays English)"
GRASSFIELD_LANG=fr_FR.UTF-8 migrate "1 2" ""
check bash -c 'grep -q "default=Exécuter -- Migrations Omarchy en attente Cliquez pour exécuter 2 migrations en attente\." "$1/log"' _ "$tmp"
GRASSFIELD_LANG=fr migrate "1" ""
check bash -c 'grep -q "Cliquez pour exécuter 1 migration en attente\." "$1/log"' _ "$tmp"
GRASSFIELD_LANG=en migrate "1" ""
check bash -c 'grep -q "default=Run -- Pending Omarchy migrations Click to run 1 pending migration\." "$1/log"' _ "$tmp"
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
# The Secret Service handover (ADR-0035 D-12): its first phase (a leftover ksecretd lets go of org.freedesktop.secrets) ends
# before the shell starts, so no app opened from the Dock reaches KWallet there; the shell never waits more than 10 s for it.
u=$pk/systemd/grassfield-secrets-handover.service
desc="grassfield-prompter.service, grassfield-secrets-handover.service, grassfield-portal-settings.service and grassfield-security.service (the prompter, the portal backend and the security process not waited for): started before the shell in the same chain, after the menu bridge"
check bash -c 'grep -qF "start grassfield-menu-bridge.service; systemctl --user start --no-block grassfield-prompter.service; systemctl --user start grassfield-secrets-handover.service; systemctl --user start --no-block grassfield-portal-settings.service; systemctl --user start --no-block grassfield-security.service; systemctl --user start grassfield-shell.service;" "$1"' _ "$auto"
desc="grassfield-secrets-handover.service: started by the session, skips itself outside it, NoNewPrivileges, seccomp, installed by the PKGBUILD"
check bash -c 'grep -qx "ConditionEnvironment=GRASSFIELD_SESSION=1" "$1" && grep -qx "NoNewPrivileges=yes" "$1" && grep -qx "SystemCallFilter=@system-service" "$1" && grep -qx "RestrictAddressFamilies=AF_UNIX" "$1" && grep -q "for unit in .*secrets-handover" "$2"' _ "$u" "$pk/arch/PKGBUILD"
desc="grassfield-secrets-handover.service: no core file, no swap, no Qt D-Bus message dump (secret values pass through it)"
check bash -c 'grep -qx "LimitCORE=0" "$1" && grep -qx "MemorySwapMax=0" "$1" && grep -qx "UnsetEnvironment=QDBUS_DEBUG" "$1"' _ "$u"
# In a user unit these options make systemd add PrivateUsers=self (systemd src/core/exec-invoke.c,
# exec_context_need_unprivileged_private_users), and from that namespace /proc/<pid>/exe of the handover's peers cannot be read:
# it would refuse every peer (ADR-0035 decision 2c-6). tests/integration/secrets_handover.sh shows that refusal.
desc="grassfield-secrets-handover.service: none of the options that would put it in a user namespace of its own"
check bash -c '! grep -qE "^(PrivateUsers|PrivateTmp|PrivateDevices|PrivateNetwork|NetworkNamespacePath|PrivateIPC|IPCNamespacePath|PrivateMounts|PrivatePIDs|MountAPIVFS|BindLogSockets|BindPaths|BindReadOnlyPaths|TemporaryFileSystem|RootDirectory|RootImage|ExtensionDirectories|ExtensionImages|ProtectSystem|ProtectHome|ProtectProc|ProcSubset|ProtectKernelTunables|ProtectKernelModules|ProtectKernelLogs|ProtectControlGroups|ProtectClock|ProtectHostname|ReadWritePaths|ReadOnlyPaths|InaccessiblePaths|ExecPaths|NoExecPaths)=" "$1"' _ "$u"
desc="grassfield-secrets-handover.service: Type=notify with a 10 s start limit, no [Install], runs the helper where CMake installs it"
check bash -c 'grep -qx "Type=notify" "$1" && grep -qx "NotifyAccess=main" "$1" && grep -qx "TimeoutStartSec=10" "$1" && ! grep -q "^\[Install\]" "$1" && grep -qx "ExecStart=/usr/lib/grassfield/grassfield-secrets-handover" "$1" && grep -q "RUNTIME DESTINATION lib/grassfield" "$2" && grep -q "cmake --install \"\$srcdir/secrets-handover-build\"" "$3"' _ "$u" "$root/apps/secrets-handover/CMakeLists.txt" "$pk/arch/PKGBUILD"
# The password-prompt bridge (ADR-0035 D-9): it identifies its callers through /proc/<pid>/exe, so no option may put it in a
# user namespace of its own (decision 9-8, as 2c-6); passwords pass through it.
u=$pk/systemd/grassfield-prompter.service
desc="grassfield-prompter.service: skips itself outside the session, NoNewPrivileges, seccomp, AF_UNIX only, no capability"
check bash -c 'grep -qx "ConditionEnvironment=GRASSFIELD_SESSION=1" "$1" && grep -qx "NoNewPrivileges=yes" "$1" && grep -qx "SystemCallFilter=@system-service" "$1" && grep -qx "RestrictAddressFamilies=AF_UNIX" "$1" && grep -qx "CapabilityBoundingSet=" "$1" && grep -qx "MemoryDenyWriteExecute=yes" "$1"' _ "$u"
desc="grassfield-prompter.service: no core file, no swap, no GDBus or Qt message dump, Qt keeps GLib's event loop"
check bash -c 'grep -qx "LimitCORE=0" "$1" && grep -qx "MemorySwapMax=0" "$1" && grep -qx "UnsetEnvironment=G_DBUS_DEBUG G_MESSAGES_DEBUG G_DEBUG QDBUS_DEBUG QT_NO_GLIB" "$1"' _ "$u"
desc="grassfield-prompter.service: none of the options that would put it in a user namespace of its own"
check bash -c '! grep -qE "^(PrivateUsers|PrivateTmp|PrivateDevices|PrivateNetwork|NetworkNamespacePath|PrivateIPC|IPCNamespacePath|PrivateMounts|PrivatePIDs|MountAPIVFS|BindLogSockets|BindPaths|BindReadOnlyPaths|TemporaryFileSystem|RootDirectory|RootImage|ExtensionDirectories|ExtensionImages|ProtectSystem|ProtectHome|ProtectProc|ProcSubset|ProtectKernelTunables|ProtectKernelModules|ProtectKernelLogs|ProtectControlGroups|ProtectClock|ProtectHostname|ReadWritePaths|ReadOnlyPaths|InaccessiblePaths|ExecPaths|NoExecPaths)=" "$1"' _ "$u"
desc="grassfield-prompter.service: the shell's unit is an argument (--peer-unit grassfield-shell.service), the socket directory is kept for the menu bridge, no [Install]"
check bash -c 'grep -qx "ExecStart=/usr/lib/grassfield/grassfield-prompter --peer-unit grassfield-shell.service" "$1" && grep -qx "RuntimeDirectory=grassfield" "$1" && grep -qx "RuntimeDirectoryPreserve=yes" "$1" && grep -qx "UMask=0077" "$1" && ! grep -q "^\[Install\]" "$1" && ! grep -q "^Environment=" "$1"' _ "$u"
desc="grassfield-prompter: installed where its unit runs it, built, tested and packaged by the PKGBUILD, which declares gcr-4"
check bash -c 'grep -q "RUNTIME DESTINATION lib/grassfield" "$1" && grep -q "packaging/systemd/grassfield-prompter.service DESTINATION lib/systemd/user" "$1" && grep -q "cmake --install \"\$srcdir/prompter-build\"" "$2" && grep -q "\"\$srcdir/prompter-build/prompter-unit-tests\"" "$2" && grep -qE "^  depends=\(.* gcr-4\)" "$2" && grep -qE "^ +quickshell gcr-4\)" "$2"' _ "$root/bridges/prompter/CMakeLists.txt" "$pk/arch/PKGBUILD"
# udiskie's password command (ADR-0035 D-9, step 9c): grassfield-askpass, built and installed with the bridge, where the
# automount unit runs it, the disk's name one argument of udiskie's own formatting.
desc="grassfield-automount.service runs udiskie with grassfield-askpass as its password command; the helper is built and installed to /usr/lib/grassfield"
check bash -c 'grep -qxF "ExecStart=/usr/bin/udiskie --automount --no-notify --no-tray --password-prompt \"/usr/lib/grassfield/grassfield-askpass udiskie {device_presentation}\"" "$1" && grep -qF "install(TARGETS grassfield-prompter grassfield-askpass RUNTIME DESTINATION lib/grassfield)" "$2" && grep -qF "add_executable(grassfield-askpass src/askpass.cpp" "$2"' _ "$pk/systemd/grassfield-automount.service" "$root/bridges/prompter/CMakeLists.txt"
for unit in omarchy-crash-watch omarchy-migrate-notify omarchy-update-user-notify; do
  desc="drop-in keeps Omarchy's $unit.service out of the Grassfield session only"
  d=$pk/systemd/$unit.service.d/10-grassfield.conf
  check bash -c 'grep -qx "ConditionEnvironment=!GRASSFIELD_SESSION=1" "$1" && grep -q "$2" "$3"' _ "$d" "$unit" "$pk/arch/PKGBUILD"
done
desc="every helper in packaging/bin and packaging/shims is executable and installed by one PKGBUILD line (regular files only)"
check bash -c 'for f in "$1"/bin/* "$1"/shims/*; do [[ -d $f || -x $f ]] || exit 1; done; grep -qF "find \"\$root/packaging/bin\" -maxdepth 1 -type f -exec install -m755 -t \"\$pkgdir/usr/lib/grassfield/\" {} +" "$1/arch/PKGBUILD" && grep -qF "find \"\$root/packaging/shims\" -maxdepth 1 -type f -exec install -m755 -t \"\$pkgdir/usr/lib/grassfield/omarchy-shims/\" {} +" "$1/arch/PKGBUILD"' _ "$pk"
desc="ADR-0035 D-3: session.lua puts the directory the PKGBUILD installs first in Hyprland's PATH (guard_path)"
check bash -c 'grep -qF "omarchy.guard_path(\"/usr/lib/grassfield/omarchy-shims\", \"/usr/lib/grassfield/session-bin\")" "$1/config/hypr/session.lua" && grep -qF "install -d \"\$pkgdir/usr/lib/grassfield/session-bin\"" "$2/arch/PKGBUILD"' _ "$root" "$pk"
desc="ADR-0035 D-3: the session-bin stand-ins are executable and installed to /usr/lib/grassfield/session-bin"
check bash -c 'for f in "$1"/session-bin/*; do [[ -f $f && -x $f ]] || exit 1; done; grep -qF "find \"\$root/packaging/session-bin\" -maxdepth 1 -type f -exec install -m755 -t \"\$pkgdir/usr/lib/grassfield/session-bin/\" {} +" "$1/arch/PKGBUILD"' _ "$pk"

desc="the install lines skip a directory in packaging/bin (an ignored __pycache__ must neither break nor enter the package)"
check bash -c 'w=$(mktemp -d) && mkdir -p "$w/packaging/bin/__pycache__" "$w/out" && printf "x\n" >"$w/packaging/bin/tool" && root=$w pkgdir=$w/pkg && mkdir -p "$pkgdir/usr/lib/grassfield" && eval "$(grep -F "find \"\$root/packaging/bin\" -maxdepth 1 -type f" "$1/arch/PKGBUILD")" && [[ -x $pkgdir/usr/lib/grassfield/tool && ! -e $pkgdir/usr/lib/grassfield/__pycache__ ]]; rc=$?; rm -rf "$w"; exit $rc' _ "$pk"
desc="the .install scriptlet runs the login check and is declared by the PKGBUILD"
check bash -c 'grep -q "grassfield-login-check" "$1/arch/grassfield-desktop.install" && grep -q "^  install=grassfield-desktop.install" "$1/arch/PKGBUILD" && grep -q "^  backup=(etc/sddm.conf.d/grassfield.conf)" "$1/arch/PKGBUILD"' _ "$pk"
if command -v vercmp >/dev/null; then
  up() { bash -c '. "$1"; post_upgrade "$2" "$3"' _ "$pk/arch/grassfield-desktop.install" "$1" "$2" 2>&1; }
  desc="the .install restart note is printed when upgrading from a version before the by-path shell (0.4.0-12 to 1.0.0rc1-1)"
  check grep -q "restart the shell once" <<<"$(up 1.0.0rc1-1 0.4.0-12)"
  desc="...and on every upgrade from the 0.4.0 series that started the shell by name (0.4.0-12 and older, whatever the new version)"
  check bash -c 'grep -q "restart the shell once" <<<"$1" && grep -q "restart the shell once" <<<"$2"' _ "$(up 0.4.0-13 0.4.0-12)" "$(up 0.4.0-13 0.3.9-1)"
  desc="...and not on later upgrades (1.0.0rc1-1 to 1.0.0rc1-2, 1.0.0 to 1.0.1) nor on a fresh upgrade call without an old version"
  check bash -c '! grep -q "restart the shell once" <<<"$1$2$3$4"' _ "$(up 1.0.0rc1-2 1.0.0rc1-1)" "$(up 0.4.0-14 0.4.0-13)" "$(up 1.0.1-1 1.0.0-1)" "$(up 1.0.1-1 "")"
else
  echo "SKIP: vercmp not installed (the .install upgrade note)"
fi
desc="autostart runs the Omarchy post-boot hooks, the power profile and the lid reconcile (what Omarchy's autostart did)"
check bash -c 'grep -q "omarchy-hook post-boot" "$1" && grep -q "omarchy-powerprofiles-init" "$1" && grep -q "grassfield-lid reconcile" "$1"' _ "$auto"

exit $fail
