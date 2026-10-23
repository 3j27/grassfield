pragma Singleton
import QtQuick
import Quickshell.Hyprland
import "InputSource.js" as Logic

// Keyboard layout (input source) changes from the compositor, for the input source HUD of shell/osd (macOS shows the
// input source name when it changes). Event-driven (`activelayout`), never polls. Only a CHANGE of a layout the keyboard
// already had is announced (Logic.step): a session with one layout never shows anything.
QtObject {
    id: root

    // The layout name now ("" until the first event).
    property string layoutName: ""
    property var memory: ({last: {}})

    // The layout changed to `name` (the HUD shows it).
    signal layoutChanged(string name)

    // Test hook: the same path as the compositor's event.
    function feed(data: string): void {
        const event = Logic.parse(data);
        if (!event)
            return;
        const next = Logic.step(memory, event);
        memory = next.state;
        layoutName = event.layout;
        if (next.show)
            layoutChanged(event.layout);
    }

    property Connections events: Connections {
        target: Hyprland

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name === "activelayout")
                root.feed(event.data);
        }
    }
}
