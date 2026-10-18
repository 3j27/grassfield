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
for tool in nmcli bluetoothctl wpctl touch pacman lspci; do
  # Records the arguments and the locale the tool was started with; a tool named "failing" in the first argument
  # prints a reason on stderr and exits 1.
  cat >"$tmp/bin/$tool" <<EOF
#!/bin/sh
echo "$tool \$*" >> "$tmp/marker"
echo "LC_ALL=\$LC_ALL LANG=\$LANG LANGUAGE=\${LANGUAGE-unset}" >> "$tmp/locale"
case "\$*" in *FAILCASE*) echo "Error: simulated failure" >&2; exit 1;; esac
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
    property var reasons: []

    readonly property string uuid: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
    readonly property var actions: [
        System.wifiRadio(false), System.wifiConnectKnown(root.uuid), System.wifiConnectOpen("Cafe"), System.wifiDisconnect("wlo1"),
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

    readonly property Connections failures: Connections {
        target: root.backend
        function onFailed(tag: string, reason: string): void {
            root.reasons.push(tag + "=" + reason);
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
        console.log("RESULT dev=" + root.backend.devSession + " ok=" + root.okCount + " refused=" + root.refusedCount + " actReturns=" + root.actReturns.join(",") + " runs=" + root.runs.join("|") + " reasons=" + root.reasons.join("|"));
        Qt.quit();
    }

    property var actReturns: []
    property var runs: []

    // Commands that are not in the allow-list: run() must refuse them in every session (no output, nothing started).
    readonly property var stray: [["touch", "x"], ["nmcli", "radio", "wifi", "off"], ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"], ["pacman", "-S", "hyprland"],
        ["pacman", "-Q", "bash"], ["lspci", "-vv"], ["nmcli", "-t", "-f", "802-11-wireless.ssid", "connection", "show", "uuid", "not-a-uuid"]]

    Component.onCompleted: {
        // The 8 fixed queries of the pages, the SSID query of a saved profile, and the 4 commands of the About pane.
        const queries = Object.keys(System.QUERY).map(k => System.QUERY[k]).concat([System.wifiProfileSsidQuery(root.uuid)]);
        const about = [["pacman", "-Q", "hyprland"], ["pacman", "-Q", "quickshell"], ["pacman", "-Q", "quickshell-git"], ["lspci"]];
        // run() takes the same allow-list in both sessions.
        for (const c of about)
            root.runs.push(root.backend.run(c) === "" ? "empty" : "out");
        for (const c of root.stray)
            root.runs.push(root.backend.run(c) === "" ? "empty" : "out");
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
            root.expected = root.actions.length + 1;
            for (const a of root.actions)
                root.actReturns.push(root.backend.act("test", a, "a"));
            // A failing tool reports its reason (stderr) before finished(false).
            root.backend.act("test", ["nmcli", "radio", "wifi", "FAILCASE"], "failing");
            root.actReturns.push(root.backend.act("test", ["touch", "x"], "a"));
        }
        // Always start from a French user locale: the tools must still see C.
        root.actReturns = root.actReturns.slice();
    }
}
EOF

run() { # mode (1 = dev, 0 = real)
  : >"$tmp/marker"
  : >"$tmp/locale"
  QT_FORCE_STDERR_LOGGING=1 PATH="$tmp/bin:$PATH" GRASSFIELD_SETTINGS_QML="$tmp/qml" QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH="$root/ui" \
    timeout 30 scripts/dev/isolated.sh --name settings-guard env GRASSFIELD_DEV="$1" LC_ALL=fr_FR.UTF-8 LANG=fr_FR.UTF-8 LANGUAGE=fr "$root/.dev/build/grassfield-settings" 2>&1
}

out=$(run 1) || true
res=$(grep -E 'RESULT' <<<"$out" || true)
echo "$res"
queries=$(wc -l <"$tmp/marker")
has() { grep -q -- "$1" <<<"$2" && echo 0 || echo 1; }
# 8 fixed queries + the saved-profile SSID query = 9 allowed in the sections; About's 4 commands go through run().
check "dev: the 9 queries run, the 9 actions sent as queries are refused" "$(has 'dev=true ok=9 refused=9' "$res")"
check "dev: only the 9 queries and the 4 About commands reached a tool ($queries)" "$([[ $queries -eq 13 ]] && echo 0 || echo 1)"
check "dev: run() answered the 4 About commands and refused the 7 stray ones" "$(has 'runs=empty|empty|empty|empty|empty|empty|empty|empty|empty|empty|empty' "$res")"
check "dev: no stray command reached a tool" "$(grep -qE 'get-volume|touch|pacman -S|pacman -Q bash|lspci -vv|not-a-uuid|radio wifi off' "$tmp/marker" && echo 1 || echo 0)"
check "tools always see the C locale, whatever the user locale" "$([[ $(sort -u "$tmp/locale") == 'LC_ALL=C LANG=C LANGUAGE=unset' ]] && echo 0 || echo 1)"
check "dev: no action verb reached a tool" "$(grep -qE "radio wifi|connection up|wifi connect|device disconnect|power |bluetoothctl (connect|disconnect)|set-|wifi rescan" "$tmp/marker" && echo 1 || echo 0)"
check "dev: act() returns false for every action" "$(has 'actReturns=false,false,false,false,false,false,false,false,false' "$res")"
check "dev: one log line per suppressed action" "$(has 'dev guard: test suppressed' "$out")"
[[ $fail -eq 0 ]] || echo "$out" | tail -20

out=$(run 0) || true
res=$(grep -E 'RESULT' <<<"$out" || true)
echo "$res"
check "real: the 9 actions run, the failing one reports its reason" "$(has 'dev=false ok=9 refused=1' "$res")"
check "real: failure reason is the tool's stderr line" "$(has 'reasons=failing=Error: simulated failure' "$res")"
check "real: run() takes the same allow-list" "$(has 'runs=empty|empty|empty|empty|empty|empty|empty|empty|empty|empty|empty' "$res")"
check "real: no stray run() command reached a tool" "$(grep -qE 'get-volume|^touch|pacman -S|pacman -Q bash|lspci -vv|not-a-uuid' "$tmp/marker" && echo 1 || echo 0)"
check "real: tools always see the C locale" "$([[ $(sort -u "$tmp/locale") == 'LC_ALL=C LANG=C LANGUAGE=unset' ]] && echo 0 || echo 1)"
check "real: an unknown program is refused" "$(has 'actReturns=true,true,true,true,true,true,true,true,true,false' "$res")"
check "real: touch never ran" "$(grep -q '^touch' "$tmp/marker" && echo 1 || echo 0)"
[[ $fail -eq 0 ]] || echo "$out" | tail -20
exit $fail
