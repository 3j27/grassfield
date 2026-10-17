pragma Singleton
import QtQuick
import Quickshell

// Desktop entry resolution shared by the menu bar and the Dock. Apps are identified by their
// foreign-toplevel app id mapped to a desktop entry, never by window title.
Singleton {
    id: root

    // Bumped when the desktop entry list changes so that bindings calling lookup()/nameFor()
    // re-evaluate (entries load asynchronously after the shell starts).
    property int revision: 0

    Connections {
        target: DesktopEntries

        function onApplicationsChanged(): void {
            root.revision++;
        }
    }

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
