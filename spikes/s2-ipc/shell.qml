// Spike S2 (throwaway): does a Quickshell dispatch reach grassfield-compositor, and does its
// socket2 event come back? Run against the NESTED instance only:
//   WAYLAND_DISPLAY=<nested> HYPRLAND_INSTANCE_SIGNATURE=<nested> timeout 10 qs -p spikes/s2-ipc/shell.qml
// Two dispatch forms are tried, 2 s apart, so each received event can be attributed by time:
//   t≈0.5 s  legacy plugin dispatcher  "grassfield:hello"             (HyprlandAPI::addDispatcherV2)
//   t≈2.5 s  Lua plugin function       "hl.plugin.grassfield.hello()" (HyprlandAPI::addLuaFunction)
// Result on Hyprland 0.56.2 (Lua config) + Quickshell 0.3.1: the legacy form fails with
// `return hl.dispatch(grassfield:hello)` "function arguments expected"; the Lua form returns the
// capabilities event. The plugin therefore only registers the Lua function.
import QtQuick
import Quickshell
import Quickshell.Hyprland

ShellRoot {
    id: root

    property real t0: Date.now()

    function stamp(): string {
        return "t=" + ((Date.now() - root.t0) / 1000).toFixed(2) + "s";
    }

    Connections {
        target: Hyprland

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name === "grassfield")
                console.log("[s2-ipc] " + root.stamp() + " rawEvent " + event.name + ">>" + event.data);
        }
    }

    Timer {
        interval: 500
        running: true
        onTriggered: {
            console.log("[s2-ipc] " + root.stamp() + " usingLua=" + Hyprland.usingLua);
            console.log("[s2-ipc] " + root.stamp() + " dispatch legacy: grassfield:hello");
            Hyprland.dispatch("grassfield:hello");
            luaTimer.start();
        }
    }

    Timer {
        id: luaTimer

        interval: 2000
        onTriggered: {
            console.log("[s2-ipc] " + root.stamp() + " dispatch lua: hl.plugin.grassfield.hello()");
            Hyprland.dispatch("hl.plugin.grassfield.hello()");
        }
    }
}
