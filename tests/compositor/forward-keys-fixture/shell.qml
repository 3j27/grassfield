// Part of tests/compositor/forward_keys.sh (NESTED only): an ordinary toplevel window (not a terminal class) that logs every key
// it receives as "[fk-fixture] key=<Qt key code> mods=<Qt modifier mask> text=<text>", and "[fk-fixture] mapped" once visible.
// Qt codes: Left 16777234, Right 16777236, Up 16777235, BackSpace 16777219, Delete 16777223, digits their ASCII code;
// modifiers Shift 33554432, Ctrl 67108864, Alt 134217728, Meta 268435456.
// Run: WAYLAND_DISPLAY=<nested> qs -p <this dir>
import QtQuick
import Quickshell

ShellRoot {
    FloatingWindow {
        id: win

        visible: true
        implicitWidth: 300
        implicitHeight: 200
        title: "forward-keys-fixture"
        color: "#335577"

        Item {
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => {
                console.log("[fk-fixture] key=" + event.key + " mods=" + event.modifiers + " text=" + JSON.stringify(event.text));
                event.accepted = true;
            }
        }

        Component.onCompleted: console.log("[fk-fixture] mapped")
    }
}
