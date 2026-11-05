import QtQuick

// Says when the Settings window is active again after it was not (ADR-0045 OC-0.4: Omarchy's terminal or the polkit sheet
// closed, the person comes back): a pane that started a setup reads its state again then. Not when the pane is first shown.
// Hidden: a page's column gives it no room.
Item {
    id: root

    signal returned

    property bool away: false
    property bool ready: false
    readonly property bool windowActive: root.Window.active

    visible: false

    onWindowActiveChanged: {
        if (!root.ready)
            return;
        if (!root.windowActive) {
            root.away = true;
        } else if (root.away) {
            root.away = false;
            root.returned();
        }
    }

    Component.onCompleted: root.ready = true
}
