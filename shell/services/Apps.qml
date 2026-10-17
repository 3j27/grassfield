pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../launchpad/Model.js" as Model
import "AppLaunch.js" as AppLaunch

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
    // (docs/specs/dock.md, dev notes). Production launches are untouched.
    readonly property bool devSession: Quickshell.env("GRASSFIELD_DEV") === "1"
    readonly property string appsHome: AppLaunch.appsHomeFor(Quickshell.env("GRASSFIELD_STATE_HOME"), Quickshell.env("XDG_RUNTIME_DIR") || "/tmp")

    // Starts a desktop entry or one of its actions. The one launch path of the Dock, Apps, Search and the
    // menus.
    function launch(target: var): void {
        if (!target)
            return;
        if (!devSession) {
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
            "command": command,
            "environment": AppLaunch.isolatedEnvironment(appsHome)
        };
        if (target.workingDirectory)
            context.workingDirectory = target.workingDirectory;
        Quickshell.execDetached(context);
    }

    // Runs a helper that opens files in an application (gio open, xdg-open, gtk-launch): same isolation.
    function openDetached(argv: var): void {
        if (!devSession) {
            Quickshell.execDetached(argv);
            return;
        }
        Quickshell.execDetached({
            "command": argv,
            "environment": AppLaunch.isolatedEnvironment(appsHome)
        });
    }

    // Environment of a Process that opens files in an application: the isolated homes in a dev session.
    function openEnvironment(): var {
        return devSession ? AppLaunch.isolatedEnvironment(appsHome) : ({});
    }

    function nameFor(appId: string): string {
        const entry = lookup(appId);
        return entry ? entry.name : appId;
    }
}
