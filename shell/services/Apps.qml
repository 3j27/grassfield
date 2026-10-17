pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../launchpad/Model.js" as Model

// Desktop entry resolution shared by the menu bar and the Dock, and the list of entries that
// Search and Apps may show. Apps are identified by their foreign-toplevel app id mapped to a
// desktop entry, never by window title.
Singleton {
    id: root

    // Bumped when the desktop entry list changes so that bindings calling lookup()/nameFor()
    // re-evaluate (entries load asynchronously after the shell starts).
    property int revision: 0

    // Desktop entry ids hidden by OnlyShowIn / NotShowIn for $XDG_CURRENT_DESKTOP (Quickshell's
    // DesktopEntry exposes NoDisplay only). Built by launchpad/hidden-entries.sh at startup and
    // rebuilt (debounced) whenever DesktopEntries changes, so new entries are filtered without
    // a restart. `hiddenReady` is false until the first run has finished.
    property var hiddenIds: ({})
    property bool hiddenReady: false

    // Emitted when the listed apps may have changed: entries changed and the hidden list is
    // current again. Search and Apps rebuild their records on it.
    signal listChanged

    // Entry a launcher may show: not NoDisplay, not hidden by OnlyShowIn / NotShowIn.
    function isListed(entry: var): bool {
        return !entry.noDisplay && !Model.isHidden(root.hiddenIds, entry.id);
    }

    function refreshHidden(): void {
        if (scan.running)
            scan.again = true;
        else
            scan.running = true;
    }

    Connections {
        target: DesktopEntries

        function onApplicationsChanged(): void {
            root.revision++;
            debounce.restart();
        }
    }

    Timer {
        id: debounce
        interval: 250
        onTriggered: root.refreshHidden()
    }

    Process {
        id: scan
        // Set when entries changed while the script was running: run it once more.
        property bool again: false
        command: ["sh", Quickshell.shellPath("launchpad/hidden-entries.sh")]
        stdout: StdioCollector {
            onStreamFinished: {
                root.hiddenIds = Model.parseHidden(text);
                root.hiddenReady = true;
                root.listChanged();
            }
        }
        onRunningChanged: {
            if (!running && again) {
                again = false;
                running = true;
            }
        }
    }

    Component.onCompleted: scan.running = true

    function lookup(id: string): var {
        revision;
        if (!id)
            return null;
        const byId = DesktopEntries.byId(id);
        return byId ? byId : DesktopEntries.heuristicLookup(id);
    }

    function nameFor(appId: string): string {
        const entry = lookup(appId);
        return entry ? entry.name : appId;
    }
}
