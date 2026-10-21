pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.platform
import "../launchpad/Model.js" as Model
import "AppLaunch.js" as AppLaunch
import "../dock/DockModel.js" as DockModel

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

    // In-place edits of an existing .desktop file (not reported by DesktopEntries.applicationsChanged):
    // watched with inotifywait when it is installed, one line per change. Without it the list is
    // refreshed only when an entry is added or removed (documented limitation, docs/specs/apps.md).
    Process {
        id: watch
        running: true
        command: ["sh", Quickshell.shellPath("launchpad/watch-applications.sh")]
        stdout: SplitParser {
            onRead: debounce.restart()
        }
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

    // ---- launching ------------------------------------------------------------------------------

    // A GRASSFIELD_DEV session (nested, on the owner's machine) must never start an app with the
    // owner's profiles: apps launched by the shell get their own XDG config, cache, state and data homes
    // (docs/specs/dock.md, dev notes). Production launches keep the user's environment (and get a scope of their own,
    // scopedLaunch).
    readonly property bool devSession: Quickshell.env("GRASSFIELD_DEV") === "1"
    readonly property string appsHome: AppLaunch.appsHomeFor(Quickshell.env("GRASSFIELD_STATE_HOME"), Quickshell.env("XDG_RUNTIME_DIR") || "/tmp")

    // A real Grassfield session (uwsm, GRASSFIELD_SESSION=1, not a dev session) with uwsm's app launcher: every
    // application the shell starts gets a scope of its own (AppLaunch.scopedArgv), never the shell's unit.
    readonly property bool realSession: Quickshell.env("GRASSFIELD_SESSION") === "1" && !devSession
    property bool uwsmApp: false
    readonly property bool scopedLaunch: realSession && uwsmApp

    // The detection of uwsm-app is asynchronous (a Process), so an application started in the first moments of the shell
    // would escape its scope. Every application start therefore goes through whenScopeKnown(): it runs at once when the
    // answer is known (always in a dev session) and is queued until the answer arrives otherwise.
    property bool scopeKnown: !realSession
    property var scopeWaiting: []

    function whenScopeKnown(fn: var): void {
        if (scopeKnown)
            fn();
        else
            scopeWaiting = scopeWaiting.concat([fn]);
    }

    function settleScope(): void {
        if (scopeKnown)
            return;
        scopeKnown = true;
        const waiting = scopeWaiting;
        scopeWaiting = [];
        for (const fn of waiting)
            fn();
    }

    Process {
        running: root.realSession
        command: ["sh", "-c", "command -v uwsm-app"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.uwsmApp = text.trim() !== "";
                root.settleScope();
            }
        }
        // sh could not even start: launches must not wait for ever (they start unscoped).
        // Quickshell's qmltypes name QProcess::ExitStatus without exporting it (metadata quirk).
        // qmllint disable signal-handler-parameters
        onExited: root.settleScope()
        // qmllint enable signal-handler-parameters
    }

    // argv of an application start: in its own scope in a real session (AppLaunch.scopedArgv).
    function scoped(argv: var): var {
        return AppLaunch.scopedArgv(argv, scopedLaunch);
    }

    // Starts a desktop entry or one of its actions. The one launch path of the Dock, Apps, Search and the
    // menus.
    function launch(target: var): void {
        if (!target)
            return;
        whenScopeKnown(() => root.launchNow(target));
    }

    function launchNow(target: var): void {
        const environment = launchEnvironment();
        // Nothing to add to the environment of the shell and no scope to start: Quickshell's own execute().
        if (Object.keys(environment).length === 0 && !scopedLaunch) {
            target.execute();
            return;
        }
        let command = AppLaunch.stripFieldCodes(target.command);
        if (command.length === 0)
            return;
        // Entries that run in a terminal: the default terminal wrapper, as Quickshell's execute() does.
        if (target.runInTerminal === true)
            command = ["xdg-terminal-exec"].concat(command);
        const context = {
            "command": scoped(command),
            "environment": environment
        };
        if (target.workingDirectory)
            context.workingDirectory = target.workingDirectory;
        Quickshell.execDetached(context);
    }

    // MimeType keys of the desktop entries and the shared MIME database (dock/mime-data.sh), rebuilt with the entry list.
    // Until it has loaded nothing accepts a drop.
    property var mimeData: DockModel.parseMimeData("")

    Process {
        id: mimeScan
        property bool again: false
        command: ["sh", Quickshell.shellPath("dock/mime-data.sh")]
        stdout: StdioCollector {
            onStreamFinished: root.mimeData = DockModel.parseMimeData(text)
        }
        onRunningChanged: {
            if (!running && again) {
                again = false;
                running = true;
            }
        }
    }

    Connections {
        target: root

        function onListChanged(): void {
            if (mimeScan.running)
                mimeScan.again = true;
            else
                mimeScan.running = true;
        }
    }

    // Real types ({path: type}) of the paths hovered by a drag, looked up off the UI path with dock/file-types.sh (a folder
    // may carry an extension, so every path is looked at) and cached for the drag: cleared a moment after the last tile is left.
    property var hoverTypes: ({})
    property var hoverWanted: []

    Process {
        id: hoverScan
        property var paths: []
        stdout: StdioCollector {
            onStreamFinished: {
                const found = DockModel.parseResolved(hoverScan.paths, text);
                root.hoverTypes = Object.assign({}, root.hoverTypes, found);
            }
        }
        onRunningChanged: {
            if (!running)
                root.scanHover();
        }
    }

    function scanHover(): void {
        if (hoverScan.running)
            return;
        const todo = DockModel.unknownPaths(hoverWanted, hoverTypes).slice(0, 32);
        hoverWanted = [];
        if (todo.length === 0)
            return;
        hoverScan.paths = todo;
        hoverScan.command = ["timeout", "10", "sh", Quickshell.shellPath("dock/file-types.sh")].concat(todo);
        hoverScan.running = true;
    }

    Timer {
        id: hoverClear
        interval: 1500
        onTriggered: root.hoverTypes = ({})
    }

    // A drag entered a tile: start resolving the real types of its paths (nothing runs for a tile that opens nothing).
    function hoverEnter(entry: var, paths: var): void {
        hoverClear.stop();
        if (DockModel.dropVerdict(entry, paths, mimeData, null) === "no")
            return;
        hoverWanted = hoverWanted.concat(DockModel.unknownPaths(paths, hoverTypes));
        scanHover();
    }

    // A drag left a tile or was dropped: forget the cached types shortly after (a drag over the next tile reuses them).
    function hoverLeave(): void {
        hoverClear.restart();
    }

    // "yes" / "no" / "pending" for the tile of `entry` and the hovered `paths` (reads hoverTypes: bindings update when
    // the lookup finishes).
    function hoverVerdict(entry: var, paths: var): string {
        return DockModel.dropVerdict(entry, paths, mimeData, hoverTypes);
    }

    // Drop jobs waiting for the real types of the paths ({entry, paths}), only when the drop came before the lookup finished.
    property var typeJobs: []
    property var typeJob: null

    Process {
        id: typeScan
        stdout: StdioCollector {
            onStreamFinished: {
                const job = root.typeJob;
                root.typeJob = null;
                if (job)
                    root.openWith(job.entry, job.paths, DockModel.parseResolved(job.paths, text));
                root.nextTypeJob();
            }
        }
    }

    function nextTypeJob(): void {
        if (typeScan.running || typeJobs.length === 0)
            return;
        typeJob = typeJobs[0];
        typeJobs = typeJobs.slice(1);
        typeScan.command = ["timeout", "10", "sh", Quickshell.shellPath("dock/file-types.sh")].concat(typeJob.paths);
        typeScan.running = true;
    }

    // Files dropped on an app tile. The real types looked up while hovering decide at once: "yes" opens, "no" refuses (the
    // drag source gets a cancel). Only a drop that came before the lookup finished (or from a source that hands its data over
    // at the drop) is accepted and resolved afterwards. True when the drop is accepted.
    function dropOnApp(entry: var, paths: var): bool {
        if (!entry || !paths || paths.length === 0)
            return false;
        const verdict = DockModel.dropVerdict(entry, paths, mimeData, hoverTypes);
        hoverLeave();
        if (verdict === "yes")
            return openWith(entry, paths, hoverTypes);
        if (verdict === "no" || typeJobs.length >= 4)
            return false;
        typeJobs = typeJobs.concat([{entry: entry, paths: Array.from(paths)}]);
        nextTypeJob();
        return true;
    }

    // Opens files with a desktop entry (files dropped on a Dock tile): the entry command with its file field codes
    // filled in per the Desktop Entry spec (DockModel.commandsForFiles; a command without one never gets the files
    // appended), the launch environment (isolated in a dev session, pointer size). Refused unless the app can open every
    // file.
    function openWith(entry: var, files: var, resolved: var): bool {
        if (!entry || !DockModel.acceptsFiles(entry, files, mimeData, resolved))
            return false;
        const commands = DockModel.commandsForFiles(DockModel.entryArgs(entry), files);
        const environment = launchEnvironment();
        whenScopeKnown(() => {
            for (const c of commands) {
                if (c.length === 0)
                    continue;
                const context = {"command": root.scoped(entry.runInTerminal === true ? ["xdg-terminal-exec"].concat(c) : c)};
                if (Object.keys(environment).length > 0)
                    context.environment = environment;
                if (entry.workingDirectory)
                    context.workingDirectory = entry.workingDirectory;
                Quickshell.execDetached(context);
            }
        });
        return commands.length > 0;
    }

    // Work started by a popup menu that closes at once (the popup, and any Process it owns, is destroyed when it closes):
    // owned by this singleton, or detached, so that it survives the menu (Dock menu: Open at Login, Show in Files).
    function writeAutostart(path: string, text: string): void {        Quickshell.execDetached(["sh", Quickshell.shellPath("overlay/write-autostart.sh"), path, text]);
    }

    function removeAutostart(path: string): void {
        Quickshell.execDetached(["rm", "-f", "--", path]);
    }

    // Opens the folder of an executable (`command -v`, `readlink -f`) in Files (through the dev open policy in a dev session).
    function revealExecutable(program: string): void {
        if (program === "" || reveal.running)
            return;
        reveal.program = program;
        reveal.running = true;
    }

    Process {
        id: reveal
        property string program: ""
        command: ["sh", "-c", 'p=$(command -v -- "$1") && dirname -- "$(readlink -f -- "$p")"', "sh", program]
        stdout: StdioCollector {
            onStreamFinished: {
                const dir = text.trim();
                if (dir !== "")
                    root.openDetached(["gio", "open", dir]);
            }
        }
    }

    // Dev open policy (ADR-0011, scripts/dev/open-policy.sh): folders open in Grassfield Files, files Preview can show
    // in Grassfield Preview, both started directly with the isolated environment; everything else is refused. Set by
    // scripts/dev/shell-run.sh. Without it a dev session opens nothing.
    readonly property string openPolicy: Quickshell.env("GRASSFIELD_OPEN_POLICY") || ""

    // A real Grassfield session opens every folder in Grassfield Files, whatever the user's default handler is (macOS: the
    // Finder is the file manager of the system). `gio open` and `xdg-open` argv become services/open-real.sh calls there;
    // a dev session keeps the open policy and gets the argv back unchanged.
    function folderAware(argv: var): var {
        return AppLaunch.folderAwareArgv(argv, Quickshell.shellPath("services/open-real.sh"), realSession);
    }

    // Runs a helper command. Helpers that open a file in an application (gio open, xdg-open, gtk-launch) follow the
    // dev open policy in a dev session: GIO never starts an app there (a D-Bus activatable default handler such as
    // Nautilus would run in the owner's session with the owner's profile). Other helpers (gio trash) get the isolated
    // environment. A real session runs the command unchanged, in a scope of its own (the application it opens lives there).
    function openDetached(argv: var): void {
        if (!devSession) {
            const environment = launchEnvironment();
            const open = folderAware(argv);
            whenScopeKnown(() => {
                if (Object.keys(environment).length === 0)
                    Quickshell.execDetached(root.scoped(open));
                else
                    Quickshell.execDetached({
                        "command": root.scoped(open),
                        "environment": environment
                    });
            });
            return;
        }
        devOpen(argv);
    }

    // A short helper that is not an application (gio trash): never in a scope of its own, only an application is. Same
    // isolated environment and dev policy as openDetached.
    function runHelper(argv: var): void {
        if (devSession) {
            devOpen(argv);
            return;
        }
        const environment = launchEnvironment();
        if (Object.keys(environment).length === 0)
            Quickshell.execDetached(argv);
        else
            Quickshell.execDetached({
                "command": argv,
                "environment": environment
            });
    }

    function devOpen(argv: var): void {
        const request = AppLaunch.openRequest(argv);
        if (request === null) {
            Quickshell.execDetached({
                "command": argv,
                "environment": launchEnvironment()
            });
            return;
        }
        if (request.refuse !== undefined || openPolicy === "") {
            console.warn("open refused in dev: " + (request.refuse !== undefined ? request.refuse : "no open policy helper"));
            return;
        }
        Quickshell.execDetached({
            "command": [openPolicy].concat(request.targets),
            "environment": launchEnvironment()
        });
    }

    // Environment of a Process that runs a helper opening files (gio open, gio trash): the isolated homes in a dev
    // session. Such a Process still resolves `gio` on the shell's own PATH, where scripts/dev/shell-run.sh puts the
    // open shims first (a dev `gio open` follows the open policy even in code that does not call openDetached).
    function openEnvironment(): var {
        return launchEnvironment();
    }

    // Environment added to every application the shell starts: the isolated homes in a dev session, and the pointer
    // size the user chose when it differs from the session's (XCURSOR_SIZE and HYPRCURSOR_SIZE; applications read them
    // when they start, so open ones keep their size). Never the owner's systemd or uwsm environment.
    function launchEnvironment(): var {
        return AppLaunch.mergeEnvironment(devSession ? AppLaunch.isolatedEnvironment(appsHome) : ({}), Pointer.launchEnvironment());
    }

    function nameFor(appId: string): string {
        const entry = lookup(appId);
        return entry ? entry.name : appId;
    }
}
