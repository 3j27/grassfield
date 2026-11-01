import QtQuick
import Grassfield.Ui
import qs.services

// The screen-sharing indicator's menu (ADR-0035 D-6, step 7b; spec system-dialogs.md SP8): one row per share running now,
// named by what the picker chose when the shell answered it (a share an app restored with its token had no picker: "Screen or
// window"); stopping belongs to the app that shares (the portal gives the shell no way to end another app's stream).
PopupMenu {
    id: root

    function describe(what: var): string {
        if (!what)
            return qsTr("Screen or window");
        if (what.kind === "window")
            return what.title !== "" ? qsTr("Window: %1").arg(what.title) : qsTr("A window");
        if (what.kind === "region")
            return qsTr("Part of %1").arg(what.value);
        return qsTr("Entire screen: %1").arg(what.value);
    }

    accessibleName: qsTr("Screen Sharing")
    currentIndex: -1

    model: [
        {
            id: "title",
            text: qsTr("Screen Sharing"),
            header: true
        }
    ].concat(SharePicker.streams.map(id => ({
                id: "stream-" + id,
                text: root.describe(SharePicker.labels[id]),
                iconName: "screen-share",
                enabled: false
            }))).concat([
        {
            id: "separator",
            separator: true
        },
        {
            id: "hint",
            text: qsTr("To stop sharing, use the app that shares."),
            enabled: false
        }
    ])

    onCloseRequested: Popups.close()
    onMenuStepRequested: direction => Popups.stepMenu(direction)
    onActivated: Popups.close()
}
