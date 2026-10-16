pragma Singleton
import QtQuick
import Quickshell

// Desktop entry resolution shared by the menu bar and the Dock. Apps are identified by their
// foreign-toplevel app id mapped to a desktop entry, never by window title.
Singleton {
    id: root

    function lookup(id: string): var {
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
