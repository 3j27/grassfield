pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Templates as T
import Grassfield.Ui
import "General.js" as General

// Date & Time > Closest city (macOS): the city of the time zone, as text at rest; typing turns it into a field with the
// cities that match under it (General.cityMatches over timedate1's zones). Down moves into the list, Return or a click picks,
// Escape gives the city back. `picked(zone)` reports the choice; the page applies it (time.zone through polkit, ADR-0026).
TextField {
    id: root

    // timedate1's zone names and the current zone.
    property var zones: []
    property string current: ""
    // The Backend's zone names (zoneInfo), for the territory of each city.
    property var backend: null
    // The current city as the row shows it ("Paris - France").
    readonly property string currentText: root.current !== "" ? root.label(root.current) : ""

    signal picked(string zone)

    readonly property var matches: root.activeFocus && root.text !== root.currentText ? General.cityMatches(root.zones, root.text, Tokens.settingsCityMatches) : []

    function label(zone: string): string {
        const info = root.backend ? root.backend.zoneInfo(zone) : ({});
        const city = General.cityOf(zone);
        return info.territory ? qsTr("%1 - %2").arg(city).arg(info.territory) : city;
    }

    function pick(zone: string): void {
        list.close();
        root.text = root.currentText;
        root.focus = false;
        if (zone !== root.current)
            root.picked(zone);
    }

    text: root.currentText
    width: Math.min(Tokens.settingsGroupLabelWidth * 2, Math.max(Tokens.settingsGroupLabelWidth, contentWidth + leftPadding + rightPadding))
    horizontalAlignment: activeFocus ? TextInput.AlignLeft : TextInput.AlignRight
    // At rest the city reads as a value, in the values' colour (macOS); a field while it is edited.
    color: activeFocus ? Appearance.colors.text : Appearance.windowSecondary
    fieldColor: activeFocus ? (Appearance.dark ? Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity) : Appearance.colors.windowBackground) : "transparent"
    fieldBorder: activeFocus && !Appearance.dark
    leftPadding: activeFocus ? Tokens.spacingSm : 0
    rightPadding: activeFocus ? Tokens.spacingSm : 0
    accessibleName: qsTr("Closest city")

    onCurrentTextChanged: {
        if (!root.activeFocus)
            root.text = root.currentText;
    }
    onActiveFocusChanged: {
        if (activeFocus) {
            root.selectAll();
        } else if (!list.visible) {
            root.text = root.currentText;
        }
    }
    onMatchesChanged: {
        if (root.matches.length > 0 && root.activeFocus)
            list.open();
        else
            list.close();
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape) {
            list.close();
            root.text = root.currentText;
            root.focus = false;
            event.accepted = true;
        } else if ((event.key === Qt.Key_Down || event.key === Qt.Key_Up) && list.visible) {
            menu.currentIndex = event.key === Qt.Key_Down ? 0 : root.matches.length - 1;
            menu.forceActiveFocus();
            event.accepted = true;
        } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && root.matches.length > 0) {
            root.pick(root.matches[0]);
            event.accepted = true;
        }
    }

    T.Popup {
        id: list

        y: root.height + Tokens.spacingXs
        // Under the field, its right edge on the field's (the field ends at the row's inset).
        x: root.width - menu.width
        width: menu.width
        height: menu.height
        padding: 0
        closePolicy: T.Popup.CloseOnEscape | T.Popup.CloseOnPressOutsideParent
        background: Item {}

        onAboutToShow: menu.measure()

        // A Popup resizes its content item, which would replace the menu's own size bindings (ComboBox): the menu sits in a
        // plain Item that takes its size from it.
        contentItem: Item {
            implicitWidth: menu.width
            implicitHeight: menu.height

            PopupMenu {
                id: menu
                accessibleName: qsTr("Cities")
                model: root.matches.map(z => ({id: z, text: root.label(z)}))
                onActivated: item => root.pick(item.id)
                onCloseRequested: {
                    list.close();
                    root.forceActiveFocus();
                }
            }
        }
    }
}
