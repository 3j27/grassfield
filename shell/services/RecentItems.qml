pragma Singleton
import QtQuick
import Quickshell
import qs.lib
import Quickshell.Io
import "RecentItemsLogic.js" as Logic
import "../search/Files.js" as Files // layering-exception: GF-087
import "../dock/DockModel.js" as DockModel // layering-exception: GF-087

// Recent Items of the Grassfield menu (macOS Apple menu > Recent Items): the applications the shell launched (every
// launch goes through Apps.launch: Dock, Apps, Search, menus) and the recently used documents (recently-used.xbel, read
// only: other applications share it). Clear Menu empties the applications and hides the documents used before it,
// without touching that file. State: $GRASSFIELD_STATE_HOME or $XDG_STATE_HOME/grassfield/recent-items.json (0600).
Singleton {
    id: root

    // Settings > Menu Bar > Recent items (macOS: Recent documents, applications, and servers); 0 hides the submenu.
    readonly property int max: Settings.menubarRecentItems
    readonly property string home: Quickshell.env("HOME")
    // Documents outside this root ($HOME; in a dev session never $HOME, see Apps.searchRoot) are not listed.
    readonly property string filesRoot: Apps.searchRoot
    // Dev session: the dev apps-home, never the owner's recent files.
    readonly property string dataHome: Apps.dataHome
    readonly property string stateDir: Mode.stateDir
    readonly property string statePath: stateDir + "/recent-items.json"

    property var state: ({apps: [], clearedAt: 0})
    property var documentList: []

    readonly property var applications: {
        void Apps.revision;
        // Named in the shell's language (Apps.displayName).
        return Logic.applications(root.state, root.max, id => {
            const entry = Apps.lookup(id);
            return entry ? {name: Apps.displayName(entry)} : null;
        });
    }
    readonly property var documents: Logic.documents(root.documentList, root.state, root.max)

    // The documents `entry` (a desktop entry) opened, for its Dock menu (RecentItemsLogic.documentsForApp).
    function documentsFor(entry: var, max: int): var {
        if (!entry)
            return [];
        const args = DockModel.entryArgs(entry);
        return Logic.documentsForApp(root.documentList, {name: entry.name ? String(entry.name) : "", cmd: args.length > 0 ? String(args[0]) : ""}, root.state, max);
    }

    // The submenu rows of the Grassfield menu (PopupMenu model).
    function menu(): var {
        return Logic.menu(root.applications, root.documents, {
            applications: qsTr("Applications"),
            documents: qsTr("Documents"),
            clear: qsTr("Clear Menu")
        });
    }

    function clear(): void {
        root.state = Logic.cleared(root.state, Date.now());
        save();
    }

    function save(): void {
        if (stateFile.path !== "")
            stateFile.setText(JSON.stringify(root.state));
    }

    Connections {
        target: Apps

        function onLaunched(appId: string): void {
            root.state = Logic.withLaunch(root.state, appId, Date.now(), 50);
            root.save();
        }
    }

    Process {
        id: prepare
        running: true
        command: ["sh", "-c", "umask 077; mkdir -p -m 700 \"$1\"; chmod 700 \"$1\"; [ -e \"$2\" ] || install -m 600 /dev/null \"$2\"; chmod 600 \"$2\"", "sh", root.stateDir, root.statePath]
        onRunningChanged: {
            if (!running)
                stateFile.path = root.statePath;
        }
    }

    FileView {
        id: stateFile
        printErrors: false
        atomicWrites: true
        onLoaded: {
            try {
                root.state = Logic.normalize(JSON.parse(stateFile.text() || "{}"));
            } catch (e) {
                root.state = Logic.normalize(null);
            }
        }
    }

    FileView {
        id: recentFile
        path: root.dataHome + "/recently-used.xbel"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.documentList = Files.parseXbel(recentFile.text(), root.filesRoot)
    }
}
