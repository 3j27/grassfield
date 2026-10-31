pragma ComponentBehavior: Bound
import QtQuick

// Reports the first rendered frame of the window it sits in to Usable (gate P5). Zero-sized and invisible: it draws
// nothing. `active` false (a window that is not shown) tells Usable not to wait for this window. `armed` false (the menu
// bar before the session's entrance, ADR-0040 step 6: its content is still at opacity 0) defers the report to the first
// frame after it is armed.
Item {
    id: probe

    required property string kind
    required property string screenName
    property bool active: true
    property bool armed: true

    width: 0
    height: 0
    visible: false

    onActiveChanged: if (!active)
        Usable.report(kind, screenName, false)
    Component.onCompleted: if (!active)
        Usable.report(kind, screenName, false)

    Connections {
        id: first

        property bool done: false

        target: first.done || !probe.active || !probe.armed ? null : probe.Window.window

        function onFrameSwapped(): void {
            first.done = true;
            Usable.report(probe.kind, probe.screenName, true);
        }
    }
}
