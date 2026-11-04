import QtQuick
import Grassfield.Ui
import qs.platform
import qs.services

// The Input menu (macOS: the input source's flag or abbreviation in the menu bar, popup kind "input"): the input sources with a
// check on the one in use, a separator, and Open Keyboard Settings… (Settings > Keyboard, where Input Sources is edited).
// Choosing a source switches every keyboard (InputSource.select); Control-Space and Control-Option-Space do the same from the
// keyboard (config/hypr/grassfield/bindings.lua).
PopupMenu {
    id: root

    accessibleName: qsTr("Input menu")
    currentIndex: -1

    model: InputSource.sources.map((source, i) => ({
                id: "source-" + i,
                text: InputSource.nameOf(source),
                checked: i === InputSource.activeIndex
            })).concat([
        {
            id: "separator",
            separator: true
        },
        {
            id: "settings",
            text: qsTr("Open Keyboard Settings…")
        }
    ])

    onCloseRequested: Popups.close()
    onMenuStepRequested: direction => Popups.stepMenu(direction)

    onActivated: item => {
        if (item.id === "settings")
            SettingsApp.openSection("keyboard");
        else if (item.id.indexOf("source-") === 0)
            InputSource.select(Number(item.id.slice(7)));
        Popups.close();
    }
}
