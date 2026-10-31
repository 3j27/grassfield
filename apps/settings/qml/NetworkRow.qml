import QtQuick
import Grassfield.Ui

// One network of a pane's list (macOS 27 Wi-Fi > Known Network, Other Networks): a check mark for the current one, the name,
// then a lock when it is secured, its signal and a (…) button with the row's actions. The row itself is the main action
// (a click, Space or Return: join it). `rowHeight` is the list's (40 Known Network, 44 Other Networks); a 1-pt separator
// above every row but the first (docs/audits/settings-parity-2026-10-26.md § Wi-Fi).
Item {
    id: root

    property string title: ""
    // Said by assistive technology after the name ("Connected", "Known network").
    property string subtitle: ""
    // The signal glyph (System.wifiGlyph).
    property string leading: ""
    property bool secured: false
    property bool checked: false
    // Joining it: a spinner in the check column.
    property bool busy: false
    property real rowHeight: Tokens.settingsWifiKnownRowHeight
    // The (…) menu: [{id, text, destructive?, enabled?, separator?}]; chosen ids come back as menuChosen(id).
    property var menuItems: []

    signal activated
    signal menuChosen(string id)

    readonly property real contentTop: root.Positioner.index > 0 ? 1 : 0
    // The ring shows for the keyboard's focus only, as a control's visualFocus (PrinterRow): a click focuses the row without it.
    property bool clickFocused: false
    readonly property bool visualFocus: root.activeFocus && !root.clickFocused

    width: parent ? parent.width : implicitWidth
    implicitHeight: root.contentTop + root.rowHeight
    activeFocusOnTab: true
    onActiveFocusChanged: if (!root.activeFocus)
        root.clickFocused = false
    Accessible.role: Accessible.Button
    Accessible.name: root.title
    Accessible.description: root.subtitle
    Accessible.checkable: true
    Accessible.checked: root.checked
    Accessible.focusable: true
    Accessible.onPressAction: root.activated()

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activated();
            event.accepted = true;
        }
    }

    Rectangle {
        visible: root.contentTop > 0
        x: Tokens.settingsRowInset
        width: parent.width - 2 * Tokens.settingsRowInset
        height: 1
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    // The keyboard focus: a ring inside the row.
    Rectangle {
        x: Tokens.controlFocusOutline / 2
        y: root.contentTop + Tokens.controlFocusOutline / 2
        width: parent.width - Tokens.controlFocusOutline
        height: root.rowHeight - Tokens.controlFocusOutline
        visible: root.visualFocus
        radius: Tokens.radiusGroup
        color: "transparent"
        border.width: Tokens.controlFocusOutline
        border.color: Appearance.focusRingColor
    }

    MouseArea {
        anchors.fill: parent
        onClicked: {
            root.clickFocused = true;
            root.forceActiveFocus();
            root.activated();
        }
    }

    Icon {
        visible: root.checked && !root.busy
        name: "checkmark"
        size: Tokens.settingsWifiGlyphSize
        color: Appearance.colors.text
        x: Tokens.settingsWifiCheckInset
        y: root.contentTop + (root.rowHeight - height) / 2
    }

    Spinner {
        visible: root.busy
        x: Tokens.settingsWifiCheckInset
        y: root.contentTop + (root.rowHeight - height) / 2
    }

    Text {
        textFormat: Text.PlainText
        x: Tokens.settingsWifiNameInset
        width: (root.secured ? lock.x : signal.x) - Tokens.spacingSm - x
        y: root.contentTop + (root.rowHeight - height) / 2
        elide: Text.ElideRight
        text: root.title
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }

    Icon {
        id: lock
        visible: root.secured
        name: "lock-fill"
        size: Tokens.settingsWifiGlyphSize
        color: Appearance.colors.text
        x: signal.x - Tokens.settingsWifiLockGap - width
        y: root.contentTop + (root.rowHeight - height) / 2
    }

    Icon {
        id: signal
        name: root.leading
        size: Tokens.settingsWifiSignalSize
        color: Appearance.colors.text
        x: more.x - Tokens.settingsWifiGlyphGap - width
        y: root.contentTop + (root.rowHeight - height) / 2
    }

    MoreButton {
        id: more
        x: root.width - width - Tokens.settingsWifiMoreInset
        y: root.contentTop + (root.rowHeight - height) / 2
        items: root.menuItems
        accessibleName: qsTr("Actions for %1").arg(root.title)
        onChosen: id => root.menuChosen(id)
    }
}
