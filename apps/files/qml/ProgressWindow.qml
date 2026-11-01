pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// The copy window (FP-68, macOS 27 Finder-Copy): one row per running copy, move or deletion with the document icon,
// "Copying “name” to “Desktop”", the bar, "41.9 MB of 111.6 MB – About 10 seconds" and the stop button (FilesApp.jobs,
// cancelJob). Main.qml shows it once a job has run for Tokens.filesProgressShowDelay and hides it when none is left.
Window {
    id: root

    required property var app

    title: qsTr("Copy")
    width: Tokens.filesProgressWindowWidth
    height: chrome.height + Math.max(1, rows.count) * Tokens.filesProgressRowHeight
    minimumWidth: Tokens.filesProgressWindowWidth
    minimumHeight: height
    maximumHeight: height
    color: Appearance.windowFill
    // ADR-0015: the window draws its own chrome (the titlebar style of grassfield-ui), as Get Info.
    property string gfChromeRole: "info"

    UnifiedToolbar {
        id: chrome
        width: parent.width
        window: root
        style: "titlebar"
        showTitle: false
        doubleClickAction: root.app.titlebarDoubleClick
        canMinimize: root.app.canMinimize
    }

    Column {
        y: chrome.height
        width: parent.width

        Repeater {
            id: rows
            model: root.app.jobs

            delegate: Item {
                id: row
                required property var modelData
                width: root.width
                height: Tokens.filesProgressRowHeight
                Accessible.role: Accessible.ProgressBar
                Accessible.name: row.modelData.title

                Icon {
                    x: Tokens.filesProgressIconInset
                    anchors.verticalCenter: parent.verticalCenter
                    name: "document"
                    size: Tokens.filesProgressIconSize
                    color: Appearance.colors.textSecondary
                }

                Text {
                    textFormat: Text.PlainText
                    x: Tokens.filesProgressTextInset
                    y: Tokens.filesProgressTitleCenter - height / 2
                    width: parent.width - x - Tokens.filesProgressBarEnd
                    elide: Text.ElideMiddle
                    text: row.modelData.title
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }

                // The bar: the accent over a light track; a job that tells no amount fills nothing.
                Rectangle {
                    id: track
                    x: Tokens.filesProgressTextInset
                    y: Tokens.filesProgressBarCenter - height / 2
                    width: parent.width - x - Tokens.filesProgressBarEnd
                    height: Tokens.filesProgressBarHeight
                    radius: height / 2
                    color: Appearance.withAlpha(Appearance.colors.text, Tokens.filesScopePillOpacity / 2)

                    Rectangle {
                        width: row.modelData.percent >= 0 ? track.width * row.modelData.percent / 100 : 0
                        height: parent.height
                        radius: parent.radius
                        color: Appearance.colors.accent
                    }
                }

                Text {
                    textFormat: Text.PlainText
                    x: Tokens.filesProgressTextInset
                    y: Tokens.filesProgressDetailCenter - height / 2
                    width: track.width
                    elide: Text.ElideRight
                    text: row.modelData.detail
                    color: Appearance.colors.textSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }

                // Stop: a filled disc with a cross (Finder).
                Rectangle {
                    width: Tokens.filesProgressStopSize
                    height: width
                    radius: width / 2
                    anchors.right: parent.right
                    anchors.rightMargin: Tokens.filesProgressStopInset
                    y: Tokens.filesProgressBarCenter - height / 2
                    color: Appearance.colors.textSecondary
                    Accessible.role: Accessible.Button
                    Accessible.name: qsTr("Stop")
                    Accessible.onPressAction: root.app.cancelJob(row.modelData.id)

                    Icon {
                        anchors.centerIn: parent
                        name: "close-glyph"
                        size: parent.width - 2
                        color: Appearance.colors.windowBackground
                    }

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -Tokens.spacingXs
                        onClicked: root.app.cancelJob(row.modelData.id)
                    }
                }
            }
        }
    }
}
