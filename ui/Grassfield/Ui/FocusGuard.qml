import QtQuick

// Hiding or disabling a control that has the keyboard focus moves the focus to the next control that can take it (macOS:
// the focus never stays on something that cannot act). Put one inside a control; it watches its parent. A control that
// keeps the focus while hidden or disabled (code can still give it) swallows its activation keys as well (each control).
// Not used by Button: a hidden or disabled Button keeps the focus and swallows only its activation keys, so that Escape
// still reaches the dialog around it (the polkit contract, R12).
Item {
    id: root

    readonly property Item control: parent

    visible: false
    enabled: false
    Accessible.ignored: true

    // Qt itself takes the focus off a disabled item (the focus then goes to nobody); the guard remembers it had it.
    property bool hadFocus: false

    function next(): void {
        const c = root.control;
        const target = c.nextItemInFocusChain(true);
        root.hadFocus = false;
        if (target && target !== c)
            target.forceActiveFocus(Qt.TabFocusReason);
        else
            c.focus = false;
    }

    function release(): void {
        const c = root.control;
        if (!(c.visible && c.enabled) && c.activeFocus)
            root.next();
    }

    Connections {
        target: root.control

        function onActiveFocusChanged(): void {
            const c = root.control;
            if (c.activeFocus)
                root.hadFocus = true;
            else if (c.visible && c.enabled)
                root.hadFocus = false;
            else if (root.hadFocus)
                root.next();
        }

        function onVisibleChanged(): void {
            root.release();
        }

        function onEnabledChanged(): void {
            root.release();
        }
    }
}
