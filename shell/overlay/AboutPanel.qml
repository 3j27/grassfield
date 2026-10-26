pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.services

// "About This Computer": read-only facts from /etc/os-release, /proc and lspci.
Dialog {
    id: root

    title: qsTr("About This Computer")
    sheet: true
    panelWidth: Tokens.panelAboutWidth

    // The label column fits the longest shown label ("Operating system" is about 107 pt in English, French runs longer),
    // never narrower than the token: a fixed column let labels overflow the sheet's padding (visual-tahoe audit, sheets).
    readonly property real labelWidth: Math.ceil(Math.max(Tokens.panelAboutLabelWidth, ...Array.from(root.content).map(r => r.labelImplicitWidth ?? 0)))

    component Row2: Row {
        id: line
        property string label: ""
        property string value: ""
        readonly property real labelImplicitWidth: visible ? labelText.implicitWidth : 0
        width: parent.width
        spacing: Tokens.spacingMd
        visible: value !== ""
        Text {
            id: labelText
            textFormat: Text.PlainText
            width: root.labelWidth
            text: line.label
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            horizontalAlignment: Text.AlignRight
        }
        Text {
            textFormat: Text.PlainText
            width: line.width - root.labelWidth - Tokens.spacingMd
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
