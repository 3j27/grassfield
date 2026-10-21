pragma ComponentBehavior: Bound
import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.services
import qs.store
import "IconsLogic.js" as Logic

// The desktop folder as a model (one instance, owned by DesktopIcons), the persisted icon slots, and every file operation of the desktop
// icons (docs/specs/desktop.md). Nothing here touches a file unless a function below is called by an
// explicit user action; every operation is one argv (gio / cp / wl-copy), never a shell string.
// Folder: $GRASSFIELD_DESKTOP_DIR, else (dev) <state>/desktop-sandbox so a dev shell never reads the
// real desktop, else `xdg-user-dir DESKTOP`, else ~/Desktop.
// Slots: desktop-icons.json in $GRASSFIELD_STATE_HOME (dev) or $XDG_STATE_HOME/grassfield, mode 0600
// in a 0700 directory, written atomically, keyed by file name; names that no longer exist are pruned.
Scope {
    id: root

    readonly property string home: Quickshell.env("HOME")
    readonly property string stateDir: {
        const dev = Quickshell.env("GRASSFIELD_STATE_HOME");
        if (dev)
            return dev;
        const xdg = Quickshell.env("XDG_STATE_HOME");
        return (xdg ? xdg : home + "/.local/state") + "/grassfield";
    }
    readonly property string positionsPath: stateDir + "/desktop-icons.json"

    // Resolved desktop folder ("" until known).
    property string dir: ""
    // [{name, path, isDir}] in name order, "" entries never.
    property var entries: []
    readonly property var names: entries.map(e => e.name)
    // {name: {col, row}}; the view assigns slots, the singleton persists them.
    property var positions: ({})
    property bool positionsLoaded: false
    // A name to select and rename as soon as it shows up (after New Folder).
    property string pendingRename: ""
    // Names with an operation in flight: never pruned meanwhile.
    property var busy: []
    property var releasing: []
    // Last failed operation, for the view (empty when fine).
    property string lastError: ""

    signal renameWanted(string name)
    // New Folder could not create the folder (no rename will follow).
    signal newFolderFailed
    // An accepted rename that the file system refused (the view shows it inline).
    signal renameFailed(string name, string reason)

    // ---- desktop folder ------------------------------------------------------------------------

    function resolve(): void {
        const override = Quickshell.env("GRASSFIELD_DESKTOP_DIR");
        if (override) {
            dir = Logic.desktopDir(override, "", home);
            return;
        }
        if (Quickshell.env("GRASSFIELD_DEV") === "1") {
            // Never the real desktop in a development session.
            dir = stateDir + "/desktop-sandbox";
            return;
        }
        xdg.running = true;
    }

    function path(name: string): string {
        return dir + "/" + name;
    }

    // ---- operations (explicit user actions only) -------------------------------------------------

    // `env`: extra environment of the process (the isolated app homes of a dev session for "open").
    function run(argv: var, label: string, done: var, env: var): void {
        const p = runner.createObject(root, {
            command: argv,
            label: label,
            done: done ? done : null,
            environment: env ? env : ({})
        });
        p.running = true;
    }

    function markBusy(name: string): void {
        busy = busy.concat([name]);
    }

    // The name stays protected from pruning until the folder model has had time to report the file.
    function unmarkBusy(name: string): void {
        releasing = releasing.concat([name]);
        releaseTimer.restart();
    }

    // Move files to the trash (gio trash). `paths` are absolute. In a dev session the trash is the isolated one
    // under .dev/apps-home (XDG_DATA_HOME of Apps.openEnvironment()), never the owner's (ADR-0011).
    function trash(paths: var): void {
        const list = paths.filter(p => typeof p === "string" && p.startsWith("/"));
        if (list.length === 0)
            return;
        run(["gio", "trash", "--"].concat(list), "trash", () => {
            Trash.refresh();
        }, Apps.openEnvironment());
    }

    // Returns "" when started, else the validation reason (see IconsLogic.validateName).
    function rename(name: string, next: string): string {
        const why = Logic.validateName(next, name, names);
        if (why !== "")
            return why;
        positions = Logic.renamed(positions, name, next);
        scheduleSave();
        markBusy(next);
        // gio move (not gio rename) so that a name starting with "-" is not an option.
        run(["gio", "move", "--no-target-directory", "--", path(name), path(next)], "rename", ok => {
            if (!ok) {
                positions = Logic.renamed(positions, next, name);
                lastError = qsTr("Could not rename \"%1\".").arg(name);
                renameFailed(name, lastError);
            }
            unmarkBusy(next);
            scheduleSave();
        });
        return "";
    }

    // Create "untitled folder" (numbered when taken) and ask the view to rename it.
    function newFolder(): void {
        const name = Logic.uniqueName(qsTr("untitled folder"), names);
        pendingRename = name;
        markBusy(name);
        run(["gio", "mkdir", "-p", path(name)], "mkdir", ok => {
            unmarkBusy(name);
            if (!ok) {
                pendingRename = "";
                newFolderFailed();
            }
        });
    }

    // Copy (or move, with `move`) files into the desktop folder under unclaimed names; never overwrites.
    // Returns the names the files will have.
    function importPaths(paths: var, move: bool): var {
        const taken = names.slice();
        const added = [];
        for (const src of paths) {
            if (typeof src !== "string" || !src.startsWith("/") || src === "/")
                continue;
            if (Logic.dirName(src) === dir)
                continue;
            if (src === dir || dir.startsWith(src + "/"))
                continue;
            const name = Logic.uniqueName(Logic.baseName(src), taken);
            taken.push(name);
            added.push(name);
            markBusy(name);
            const dest = path(name);
            // gio move handles directories; cp -a does for copies (gio copy refuses directories).
            const argv = move ? ["gio", "move", "--", src, dest] : ["cp", "-a", "--no-clobber", "--no-target-directory", "--", src, dest];
            run(argv, move ? "move" : "copy", () => unmarkBusy(name));
        }
        return added;
    }

    // Open a file with its default application. A .desktop file is never executed: it opens as text in
    // the default text editor (the GNOME trust model needs metadata::trusted, not implemented in v1).
    function open(name: string): void {
        const p = path(name);
        if (Logic.isLauncher(name)) {
            openAsText(p);
            return;
        }
        Apps.whenScopeKnown(() => root.run(Apps.scoped(Apps.folderAware(["gio", "open", p])), "open", null, Apps.openEnvironment()));
    }

    function openAsText(p: string): void {
        textEditor.target = p;
        textEditor.running = true;
    }

    // Copy file URIs to the clipboard (text/uri-list).
    function copy(paths: var): void {
        if (paths.length === 0)
            return;
        run(["wl-copy", "--type", "text/uri-list", Logic.uriList(paths)], "copy to clipboard", null);
    }

    // ---- positions -------------------------------------------------------------------------------

    function setPositions(next: var): void {
        positions = next;
        scheduleSave();
    }

    function scheduleSave(): void {
        saveTimer.restart();
    }

    function rebuild(): void {
        if (model.status !== FolderListModel.Ready) {
            return;
        }
        const list = [];
        for (let i = 0; i < model.count; i++) {
            const name = String(model.get(i, "fileName"));
            if (name !== "" && name.indexOf("/") < 0)
                list.push({
                    name: name,
                    path: path(name),
                    isDir: model.get(i, "fileIsDir") === true
                });
        }
        entries = list;
        if (positionsLoaded) {
            const keep = Logic.prune(positions, names.concat(busy));
            if (Object.keys(keep).length !== Object.keys(positions).length) {
                positions = keep;
                scheduleSave();
            }
        }
        if (pendingRename !== "" && names.indexOf(pendingRename) >= 0) {
            const n = pendingRename;
            pendingRename = "";
            renameWanted(n);
        }
    }

    Component.onCompleted: {
        resolve();
        prepare.running = true;
    }

    FolderListModel {
        id: model
        folder: root.dir !== "" ? "file://" + Logic.uriPath(root.dir) : "file:///grassfield-desktop-unresolved"
        showDirs: true
        showFiles: true
        showHidden: false
        showDotAndDotDot: false
        showOnlyReadable: false
        sortField: FolderListModel.Name
        onCountChanged: refresh.restart()
        onStatusChanged: refresh.restart()
        onRowsInserted: refresh.restart()
        onRowsRemoved: refresh.restart()
        onDataChanged: refresh.restart()
        onModelReset: refresh.restart()
    }

    Timer {
        id: releaseTimer
        interval: 1000
        onTriggered: {
            const next = root.busy.slice();
            for (const n of root.releasing) {
                const i = next.indexOf(n);
                if (i >= 0)
                    next.splice(i, 1);
            }
            root.releasing = [];
            root.busy = next;
            root.rebuild();
        }
    }

    Timer {
        id: refresh
        interval: 60
        onTriggered: root.rebuild()
    }

    // ---- folder looks (Customize Folder in Files; docs/specs/files.md) ------------------------------------

    // {path: {color, glyph}} from the attribute user.grassfield.folder of the desktop's folders (read with getfattr, one
    // process for all of them; without it the folders just show the global colour), and from the per-user fallback
    // store folder-styles.json next to grassfield.json (FileView; its serial also moves on every attribute write by
    // Files, so one watch covers both).
    property var folderAttributes: ({})
    property var folderStore: ({})
    readonly property string configDir: {
        const dev = Quickshell.env("GRASSFIELD_CONFIG_HOME");
        if (dev)
            return dev;
        const xdgConfig = Quickshell.env("XDG_CONFIG_HOME");
        return (xdgConfig ? xdgConfig : home + "/.config") + "/grassfield";
    }

    // The look of a desktop item by name ({color, glyph}, empty fields for files and folders without one).
    function folderStyle(name: string): var {
        return FolderStyle.lookup(path(name), folderStore, folderAttributes);
    }

    onEntriesChanged: styleRefresh.restart()

    Timer {
        id: styleRefresh
        interval: 150
        onTriggered: {
            const paths = root.entries.filter(e => e.isDir).map(e => root.path(e.name));
            if (paths.length === 0) {
                root.folderAttributes = ({});
                return;
            }
            if (attributes.running)
                styleRefresh.restart();
            else {
                attributes.command = ["getfattr", "-h", "-d", "-e", "hex", "-m", "^user\\.grassfield\\.folder$", "--absolute-names", "--"].concat(paths);
                attributes.running = true;
            }
        }
    }

    Process {
        id: attributes
        stdout: StdioCollector {
            onStreamFinished: root.folderAttributes = FolderStyle.parseGetfattr(text)
        }
        stderr: StdioCollector {}
    }

    // The config directory may not exist yet on a fresh account; the watch needs it (WatchedDir).
    WatchedDir {
        id: configWatch
        path: root.configDir
    }

    FileView {
        id: styleStore
        path: configWatch.ready ? root.configDir + "/folder-styles.json" : ""
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            const r = FolderStyle.parseStore(styleStore.text());
            root.folderStore = r.folders;
            // A write by Files (attribute or store): read the attributes of the shown folders again.
            styleRefresh.restart();
        }
        onLoadFailed: root.folderStore = ({})
    }

    Process {
        id: xdg
        command: ["xdg-user-dir", "DESKTOP"]
        stdout: StdioCollector {
            onStreamFinished: root.dir = Logic.desktopDir("", text, root.home)
        }
        // Quickshell's qmltypes name QProcess::ExitStatus without exporting it (metadata quirk).
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            // qmllint enable signal-handler-parameters
            if (exitCode !== 0 && root.dir === "")
                root.dir = Logic.desktopDir("", "", root.home);
        }
    }

    // Open a text file in the default text editor: look the application up (gio mime), then gtk-launch.
    Process {
        id: textEditor
        property string target: ""
        command: ["gio", "mime", "text/plain"]
        stdout: StdioCollector {
            onStreamFinished: {
                const m = /Default application for .*?:\s*(\S+\.desktop)/.exec(text);
                if (m && textEditor.target !== "")
                    Apps.openDetached(["gtk-launch", m[1].replace(/\.desktop$/, ""), textEditor.target]);
            }
        }
    }

    Component {
        id: runner

        Process {
            id: proc
            property string label: ""
            property var done: null
            stderr: StdioCollector {
                id: err
            }
            // qmllint disable signal-handler-parameters
            onExited: exitCode => {
                // qmllint enable signal-handler-parameters
                const ok = exitCode === 0;
                if (!ok) {
                    console.warn("desktop icons: " + proc.label + " failed (" + exitCode + "): " + err.text.trim());
                    root.lastError = proc.label;
                }
                if (proc.done)
                    proc.done(ok);
                proc.destroy();
            }
        }
    }

    // ---- positions file --------------------------------------------------------------------------

    // Directory 0700, file 0600 before the first write (FileView cannot set modes).
    Process {
        id: prepare
        command: ["sh", "-c", "umask 077; mkdir -p -m 700 \"$1\"; chmod 700 \"$1\"; [ -e \"$2\" ] || install -m 600 /dev/null \"$2\"; chmod 600 \"$2\"", "sh", root.stateDir, root.positionsPath]
        onRunningChanged: {
            if (!running)
                file.path = root.positionsPath;
        }
    }

    FileView {
        id: file
        printErrors: false
        atomicWrites: true
        onLoaded: {
            const r = Logic.parse(file.text());
            if (!r.ok && file.text().trim() !== "") {
                console.warn("desktop icons: " + root.positionsPath + " is not a version 1 file; keeping a copy as .bak and starting empty");
                Quickshell.execDetached(["cp", "-p", root.positionsPath, root.positionsPath + ".bak"]);
            }
            root.positions = r.positions;
            root.positionsLoaded = true;
            root.rebuild();
        }
        onLoadFailed: {
            root.positionsLoaded = true;
            root.rebuild();
        }
    }

    Timer {
        id: saveTimer
        interval: Tokens.desktopIconSaveMs
        onTriggered: {
            if (root.positionsLoaded)
                file.setText(Logic.serialize(root.positions));
        }
    }
}
