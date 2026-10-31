import QtQuick

// Whether an item that is not a Control holds the keyboard's focus or a pointer's: a Control has `visualFocus`, a plain Item,
// FocusScope, ListView or Text has only `activeFocus`, which a click that calls forceActiveFocus() sets too. Put one inside the
// focusable item and show its FocusRing with `visible: keyFocus.active`: the ring is for keyboard focus only (ADR-0039 step 7,
// G7). A press on the item (any button, touch) marks its focus as the pointer's until the item loses it; the press itself is
// only watched (a passive PointHandler), so the item's own MouseArea or TapHandler keeps every click. A host that moves the focus
// to another item after a pointer action (a popover that opens on a click) sets that item's `pointer` first.
Item {
    id: root

    // The item whose focus is judged: the one this sits in.
    property Item target: parent
    // True while the target has the active focus and no press on it came before.
    readonly property bool active: root.target !== null && root.target.activeFocus && !root.pointer
    // A press on the target since it last lost the focus.
    property bool pointer: false

    anchors.fill: parent
    // Above the target's own MouseArea or TapHandler wherever it is declared: the press is watched before they take it.
    z: Number.MAX_SAFE_INTEGER
    Accessible.ignored: true

    PointHandler {
        acceptedButtons: Qt.AllButtons
        onActiveChanged: {
            if (active)
                root.pointer = true;
        }
    }

    Connections {
        target: root.target

        function onActiveFocusChanged(): void {
            if (!root.target.activeFocus)
                root.pointer = false;
        }
    }
}
