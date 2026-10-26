import QtQuick
import Grassfield.Ui
import "System.js" as System

// The current network under a pane's header row (macOS 27 Wi-Fi): its name, a status line with a coloured dot
// ("Connected"), then on the right a lock when it is secured, its signal and "Details…". Placed as measured
// (docs/audits/settings-parity-2026-10-26.md § Wi-Fi); a 1-pt separator above it.
Item {
    id: root

    property string name: ""
    property string status: ""
    property color dotColor: Appearance.colors.statusOn
    property bool secured: false
    property int strength: 0

    signal detailsRequested

    // Below the separator.
    readonly property real contentTop: root.Positioner.index > 0 ? 1 : 0

    width: parent ? parent.width : implicitWidth
    implicitHeight: root.contentTop + Tokens.settingsWifiCurrentRowHeight
    Accessible.role: Accessible.Grouping
    Accessible.name: root.name
    Accessible.description: [root.status, root.secured ? qsTr("Secured") : qsTr("Open"), qsTr("Signal %1 %").arg(root.strength)].join(", ")

    Rectangle {
        visible: root.contentTop > 0
        x: Tokens.settingsRowInset
        width: parent.width - 2 * Tokens.settingsRowInset
        height: 1
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    Text {
        id: nameText
        textFormat: Text.PlainText
        x: Tokens.settingsRowInset
        y: root.contentTop + Tokens.settingsWifiCurrentNameBaseline - baselineOffset
        width: lock.x - Tokens.spacingSm - x
        elide: Text.ElideRight
        text: root.name
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }

    Rectangle {
        x: Tokens.settingsWifiStatusDotInset
        // Centred on the status text's capitals.
        y: statusText.y + statusText.baselineOffset - fontMetrics.capitalHeight / 2 - height / 2
        width: Tokens.settingsWifiStatusDotSize
        height: width
        radius: width / 2
        color: root.dotColor
    }

    FontMetrics {
        id: fontMetrics
        font: statusText.font
    }

    Text {
        id: statusText
        textFormat: Text.PlainText
        x: Tokens.settingsWifiStatusTextInset
        y: root.contentTop + Tokens.settingsWifiCurrentStatusBaseline - baselineOffset
        width: details.x - Tokens.spacingSm - x
        elide: Text.ElideRight
        text: root.status
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }

    Icon {
        id: lock
        visible: root.secured
        name: "lock-fill"
        size: Tokens.settingsWifiGlyphSize
        color: Appearance.colors.text
        x: signal.x - Tokens.settingsWifiCurrentLockGap - width
        y: root.contentTop + Tokens.settingsWifiCurrentControlsCenter - height / 2
    }

    Icon {
        id: signal
        name: System.wifiGlyph(root.strength)
        size: Tokens.settingsWifiSignalSize
        color: Appearance.colors.text
        x: details.x - Tokens.settingsWifiCurrentSignalGap - width
        y: root.contentTop + Tokens.settingsWifiCurrentControlsCenter - height / 2
    }

    Button {
        id: details
        push: true
        text: qsTr("Details…")
        x: root.width - width - Tokens.settingsRowInset
        y: root.contentTop + Tokens.settingsWifiCurrentControlsCenter - height / 2
        onClicked: root.detailsRequested()
    }
}
