pragma Singleton
import QtQuick
import Quickshell
import qs.lib
import Quickshell.Services.SystemTray
import "StatusLogic.js" as Logic

// StatusNotifierItem host (macOS menu extras: third-party status items). Quickshell's SystemTray owns the watcher and
// the host; the bar draws `items`, one slot per live, active item with an icon. Items are identified by their object
// (one per service and path), never by id: Chromium and Electron apps register several items with the same id.
//
// A dev session on the owner's session bus never touches SystemTray (the host would try to own the owner's
// org.kde.StatusNotifierWatcher); the nested session runs on its own bus (GRASSFIELD_PRIVATE_BUS=1), as the
// notification server does.
Singleton {
    id: root

    readonly property bool enabled: Mode.ownBus
    readonly property var items: root.enabled ? SystemTray.items.values.filter(Logic.trayShown) : []

    function alive(item: var): bool {
        return root.items.indexOf(item) >= 0;
    }
}
