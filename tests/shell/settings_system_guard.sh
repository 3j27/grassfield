#!/usr/bin/env bash
# Dev guard of the Settings system sections, on the real Backend (apps/settings/src): with GRASSFIELD_DEV=1 only the
# read-only queries run, no action does; without it actions run (and unknown programs are refused).
# The tools are shims first on PATH that only record their arguments, so nothing here can touch the machine.
# Plain shell test: prints PASS/FAIL, exits non-zero on failure. Offscreen, no compositor needed.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
unset QT_QPA_PLATFORMTHEME
fail=0
check() { # name, condition result (0 = ok)
  if [[ $2 -eq 0 ]]; then echo "PASS: settings_system_guard $1"; else echo "FAIL: settings_system_guard $1"; fail=1; fi
}

apps/settings/build-direct.sh >/dev/null
tmp=$(mktemp -d "$root/.dev/settings-guard.XXXXXX" 2>/dev/null || { mkdir -p "$root/.dev" && mktemp -d "$root/.dev/settings-guard.XXXXXX"; })
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/qml"
for tool in nmcli bluetoothctl wpctl touch; do
  cat >"$tmp/bin/$tool" <<EOF
#!/bin/sh
echo "$tool \$*" >> "$tmp/marker"
exit 0
EOF
  chmod +x "$tmp/bin/$tool"
done

sed "s|@SYSTEM_JS@|$root/apps/settings/qml/System.js|" >"$tmp/qml/Main.qml" <<'EOF'
import QtQml
import "file://@SYSTEM_JS@" as System

QtObject {
    id: root
    required property var backend
    required property bool globalMenu
    property string startSection: ""

    property int expected: 0
    property int seen: 0
    property int okCount: 0
    property int refusedCount: 0

    readonly property var actions: [
        System.wifiRadio(false), System.wifiConnectKnown("Home"), System.wifiConnectOpen("Cafe"), System.wifiDisconnect("wlo1"),
        System.btPower(false), System.btConnect("AA:BB:CC:DD:EE:FF", true), System.setDefaultDevice(52), System.setVolume(52, 0.5),
        System.setMute(52, true)
    ]

    readonly property Connections conn: Connections {
        target: root.backend
        function onFinished(tag: string, ok: bool, output: string): void {
            root.seen++;
            if (ok)
                root.okCount++;
            else
                root.refusedCount++;
            if (root.seen >= root.expected)
                root.finish();
        }
    }

    readonly property Timer failsafe: Timer {
        interval: 8000
        running: true
        onTriggered: {
            console.log("RESULT timeout seen=" + root.seen + " expected=" + root.expected);
            Qt.exit(3);
        }
    }

    function finish(): void {
        console.log("RESULT dev=" + root.backend.devSession + " ok=" + root.okCount + " refused=" + root.refusedCount + " actReturns=" + root.actReturns.join(","));
        Qt.quit();
    }

    property var actReturns: []

    Component.onCompleted: {
        const queries = Object.keys(System.QUERY).map(k => System.QUERY[k]);
        if (root.backend.devSession) {
            // Queries must run; actions sent as queries or as actions must not.
            root.expected = queries.length + root.actions.length;
            for (const q of queries)
                root.backend.query(q, "q");
            for (const a of root.actions) {
                root.backend.query(a, "a");
                root.actReturns.push(root.backend.act("test", a, "a"));
            }
        } else {
            // Real session: every action runs; a program outside nmcli, bluetoothctl and wpctl is refused.
            root.expected = root.actions.length;
            for (const a of root.actions)
                root.actReturns.push(root.backend.act("test", a, "a"));
            root.actReturns.push(root.backend.act("test", ["touch", "x"], "a"));
        }
        root.actReturns = root.actReturns.slice();
    }
}
EOF

run() { # mode (1 = dev, 0 = real)
  : >"$tmp/marker"
  PATH="$tmp/bin:$PATH" GRASSFIELD_SETTINGS_QML="$tmp/qml" QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui" \
    timeout 30 scripts/dev/isolated.sh --name settings-guard env GRASSFIELD_DEV="$1" "$root/.dev/build/grassfield-settings" 2>&1
}

out=$(run 1) || { echo "$out"; check "dev session runs" 1; exit 1; }
res=$(grep -E '^(qml: )?RESULT' <<<"$out" || true)
echo "$res"
queries=$(wc -l <"$tmp/marker")
grep -q "dev=true ok=8 refused=9" <<<"$res"; check "dev: the 8 queries run, the 9 actions sent as queries are refused" $?
[[ $queries -eq 8 ]]; check "dev: only the 8 queries reached a tool ($queries)" $?
! grep -qE ' (radio|connection|device|power|connect|disconnect|set-default|set-volume|set-mute)( |$)' "$tmp/marker" \
  && ! grep -q 'rescan' "$tmp/marker"; check "dev: no action verb reached a tool" $?
grep -q "actReturns=false,false,false,false,false,false,false,false,false" <<<"$res"; check "dev: act() returns false for every action" $?
grep -q "dev guard: test suppressed" <<<"$out"; check "dev: one log line per suppressed action" $?

out=$(run 0) || { echo "$out"; check "real session runs" 1; exit 1; }
res=$(grep -E '^(qml: )?RESULT' <<<"$out" || true)
echo "$res"
grep -q "dev=false ok=9 refused=0" <<<"$res"; check "real: the 9 actions run" $?
grep -q "actReturns=true,true,true,true,true,true,true,true,true,false" <<<"$res"; check "real: an unknown program is refused" $?
! grep -q '^touch' "$tmp/marker"; check "real: touch never ran" $?
exit $fail
