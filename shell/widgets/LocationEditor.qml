pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// The Weather widget's Edit Location… (ADR-0045 OC-14): a popover on the menus' glass where the widget's menu was (macOS 27
// edits a widget in a popover beside it): the place to look up, prefilled with Omarchy's saved one, a line saying what an
// empty field means, Cancel and Done. Return or Done saves it through WeatherSampler.setLocation (Omarchy's own
// `omarchy-weather-location --set <name>`, `--clear` when empty: back to the place wttr.in finds from the IP address); Esc,
// Cancel or a click outside (the host's) closes without saving. The host places it, gives it the keyboard and a blur region
// of its shape (`surface`, Tokens.radiusPopover: a popover's corner, as the Emoji & Symbols popover's).
FocusScope {
    id: root

    signal closed

    readonly property Item surface: glass

    width: Tokens.widgetWeatherEditorWidth
    height: column.implicitHeight + 2 * Tokens.spacingMd
    Accessible.role: Accessible.Dialog
    Accessible.name: qsTr("Weather location")
    Keys.onEscapePressed: root.closed()

    function save(): void {
        WeatherSampler.setLocation(field.text);
        root.closed();
    }

    Material {
        id: glass
        glassClass: "menu"
        anchors.fill: parent
        radius: Tokens.radiusPopover
    }

    // Clicks on the popover stay on it.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
    }

    Column {
        id: column
        x: Tokens.spacingMd
        y: Tokens.spacingMd
        width: root.width - 2 * Tokens.spacingMd
        spacing: Tokens.spacingSm

        WidgetLabel {
            width: parent.width
            text: qsTr("Location")
            font.weight: Tokens.typographyTitleWeight
        }

        TextField {
            id: field
            width: parent.width
            focus: true
            text: WeatherSampler.location.name
            placeholderText: qsTr("City or place")
            accessibleName: qsTr("Location")
            maximumLength: Tokens.widgetWeatherLocationMaxChars
            onAccepted: root.save()
            Component.onCompleted: selectAll()
        }

        WidgetLabel {
            width: parent.width
            text: qsTr("Leave it empty to use the place wttr.in finds from your IP address.")
            size: Tokens.typographyCaptionSize
            color: Appearance.colors.textSecondary
            wrapMode: Text.WordWrap
            elide: Text.ElideNone
        }

        Row {
            anchors.right: parent.right
            spacing: Tokens.spacingSm

            Button {
                push: true
                text: qsTr("Cancel")
                onClicked: root.closed()
            }

            Button {
                push: true
                primary: true
                text: qsTr("Done")
                onClicked: root.save()
            }
        }
    }
}
