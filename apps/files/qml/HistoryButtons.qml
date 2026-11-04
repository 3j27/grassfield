import QtQuick

// The pointer's and the keyboard's Back and Forward of a Files window: a mouse's side buttons (Qt.BackButton and
// Qt.ForwardButton) and the XF86Back and XF86Forward keys do what Cmd-[ and Cmd-] do (macOS Finder). The item covers its
// window, so the buttons work over every view and the sidebar; it takes no other button, no key, and no focus.
Item {
    id: root

    // The BrowserTab whose history moves (null: nothing happens).
    property var tab: null
    // False while the window's keys belong to another window.
    property bool live: true

    anchors.fill: parent
    z: 1000

    function back(): void {
        if (root.live && root.tab && root.tab.canBack)
            root.tab.back();
    }

    function forward(): void {
        if (root.live && root.tab && root.tab.canForward)
            root.tab.forward();
    }

    TapHandler {
        acceptedButtons: Qt.BackButton
        acceptedDevices: PointerDevice.Mouse
        onTapped: root.back()
    }
    TapHandler {
        acceptedButtons: Qt.ForwardButton
        acceptedDevices: PointerDevice.Mouse
        onTapped: root.forward()
    }
    Shortcut {
        sequences: ["Back"]
        enabled: root.live
        onActivated: root.back()
    }
    Shortcut {
        sequences: ["Forward"]
        enabled: root.live
        onActivated: root.forward()
    }
}
