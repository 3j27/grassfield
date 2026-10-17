// Part of tests/compositor/appmenu.sh (NESTED only): calls hl.plugin.grassfield.appmenu(address) the way the
// shell's platform layer does (Hyprland.dispatch, ADR-0007), for a valid window address (GF_APPMENU_ADDRESS,
// hex), then for an invalid string and for a number that is not a window; the plugin must post one appmenu
// event for the first call only. The socket2 events are captured by the calling script; this file only logs.
// Run: WAYLAND_DISPLAY=<nested> HYPRLAND_INSTANCE_SIGNATURE=<nested> GF_APPMENU_ADDRESS=<hex> qs -p <this dir>
import QtQuick
import Quickshell
import Quickshell.Hyprland

ShellRoot {
    id: root

    // Validated before it is put into Lua (never trust the environment).
    readonly property string address: {
        const a = Quickshell.env("GF_APPMENU_ADDRESS") ?? "";
        return /^(0x)?[0-9a-fA-F]{1,16}$/.test(a) ? a.replace(/^0x/, "") : "";
    }

    Connections {
        target: Hyprland

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name === "grassfield")
                console.log("[appmenu-reemit] rawEvent grassfield>>" + event.data);
        }
    }

    Timer {
        interval: 300
        running: true
        onTriggered: {
            if (root.address === "") {
                console.log("[appmenu-reemit] no valid GF_APPMENU_ADDRESS");
                Qt.quit();
                return;
            }
            console.log("[appmenu-reemit] dispatch appmenu(0x" + root.address + ")");
            Hyprland.dispatch("hl.plugin.grassfield.appmenu(\"0x" + root.address + "\")");
            Hyprland.dispatch("hl.plugin.grassfield.appmenu(\"0xnot-hex\")");
            Hyprland.dispatch("hl.plugin.grassfield.appmenu(\"0x1\")");
            done.start();
        }
    }

    Timer {
        id: done

        interval: 1500
        onTriggered: Qt.quit()
    }
}
