import QtQuick
import Grassfield.Ui
import qs.services

// "About This Computer": read-only facts from /etc/os-release, /proc and lspci.
Dialog {
    id: root

    title: qsTr("About This Computer")
    panelWidth: Tokens.panelAboutWidth

    component Row2: Row {
        id: line
        property string label: ""
        property string value: ""
        width: parent.width
        spacing: Tokens.spacingMd
        visible: value !== ""
        Text {
            textFormat: Text.PlainText
            width: Tokens.panelAboutLabelWidth
            text: line.label
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            horizontalAlignment: Text.AlignRight
        }
        Text {
            textFormat: Text.PlainText
            width: line.width - 100 - Tokens.spacingMd
            text: line.value
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            wrapMode: Text.WordWrap
            Accessible.name: qsTr("%1: %2").arg(line.label).arg(line.value)
        }
    }

    Component.onCompleted: SystemInfo.refresh()
    onRejected: Popups.close()

    content: [
        Row2 {
            label: qsTr("Operating system")
            value: SystemInfo.osName + (SystemInfo.osVersion !== "" ? " " + SystemInfo.osVersion : "")
        },
        Row2 {
            label: qsTr("Grassfield")
            value: SystemInfo.grassfieldVersion
        },
        Row2 {
            label: qsTr("Kernel")
            value: SystemInfo.kernel
        },
        Row2 {
            label: qsTr("Computer")
            value: SystemInfo.hostname
        },
        Row2 {
            label: qsTr("Processor")
            value: SystemInfo.cpu
        },
        Row2 {
            label: qsTr("Memory")
            value: SystemInfo.memory
        },
        Row2 {
            label: qsTr("Graphics")
            value: SystemInfo.graphics
        }
    ]

    buttons: [
        Button {
            text: qsTr("OK")
            primary: true
            focus: true
            onClicked: Popups.close()
        }
    ]
}
