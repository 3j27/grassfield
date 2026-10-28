import QtQuick
import Grassfield.Ui

// Software Update as Settings sees it (ADR-0033 d, i; docs/specs/updates.md U8, U10-U14, U19), one per window: the badge of the
// sidebar and of General's row, and what the pane shows.
//   - software-update.json, which the shell alone writes, read whenever it changes (bounded: Backend.readText, then at most
//     1 MiB of JSON). Without a shell, the answer of the check Settings ran itself is kept here, in memory (U10).
//   - A check (U8: the pane opening, unless one finished less than a minute ago; Check Now): the shell is asked over its IPC
//     (`update check user`) and its answer reaches the file; when no shell answers, Settings runs the checker itself.
//   - The channel as `grassfield-channel-set` prints it, read again whenever /etc/pacman.d/grassfield.conf changes (U12: never
//     stored per user); whether this build can set updates up (repository.conf); Omarchy's reboot marker and the running
//     kernel's modules (U14, read only).
//   - The actions, through SystemService (never in a dev session): the channel changes (the polkit dialog: one at a time,
//     Backend.pendingActions), Update Now (Omarchy's terminal, then a check that waits for its update lock), Log Out… and
//     Restart… (grassfield-session-end, after the window's confirmation sheet).
QtObject {
    id: root

    required property var backend
    required property var system

    // Read-only paths, a test seam (tests/unit/tst_settingssoftwareupdate.qml points them at its fixtures).
    property string includeFile: "/etc/pacman.d/grassfield.conf"
    property string repositoryFile: "/usr/share/grassfield/pacman/repository.conf"
    property string rebootMarker: root.backend.homeDir + "/.local/state/omarchy/reboot-required"
    property string kernelReleaseFile: "/proc/sys/kernel/osrelease"
    property string modulesDir: "/usr/lib/modules"

    // software-update.json (SoftwareUpdateLogic.normalize), or Settings' own answer combined into it.
    property var file: SoftwareUpdateLogic.normalize(null)
    // Available releases (owner decision O3: Grassfield's and Omarchy's): the red badge.
    readonly property int count: SoftwareUpdateLogic.releases(root.file)
    readonly property var view: SoftwareUpdateLogic.view(root.file, root.checking)
    // A check runs: the shell's (asked by this window) or Settings' own.
    property bool checking: false
    // When this window last asked for a check (ms), 0 before.
    property double askedAt: 0
    // The file as it was when the shell was asked: its next answer ends `checking`.
    property var askedFile: null
    // stable, beta, custom, repair, off; "" until read or when it cannot be read.
    property string channel: ""
    readonly property bool buildReady: SoftwareUpdateLogic.buildReady(root.backend.readText(root.repositoryFile).text)
    // A Grassfield update in this session waits for a log out (GF-083, written to the file by the shell).
    readonly property bool logoutPending: root.file.logoutPending === true
    property bool restartNeeded: false
    // Update Now started Omarchy's terminal: the button waits for the check that follows (launchCheckMs), which waits for
    // Omarchy's update lock while the update runs, then for the answer after it.
    property bool launched: false
    readonly property bool updateRunning: root.launched || root.file.state === "update-running"
    readonly property bool canUpdate: root.backend.omarchyUpdate === true
    // The channel change that waits for the polkit dialog (Backend.pendingActions); "" when none.
    readonly property string channelTag: "update.channel.act"
    readonly property bool waitingForPermission: (root.backend.pendingActions ?? {})[root.channelTag] !== undefined
    // What the last channel change was for (its failure sentence names it): "setup", "beta", "repair" or "off".
    property string lastAction: ""
    readonly property string channelError: root.system.errors[root.channelTag] ?? ""

    function read(): void {
        const before = root.file;
        const r = root.backend.readText(root.backend.softwareUpdateFile);
        root.file = SoftwareUpdateLogic.fromText(r.ok ? r.text : "");
        if (root.askedFile !== null && SoftwareUpdateLogic.answered(root.askedFile, root.file))
            root.settle();
        if (root.launched && SoftwareUpdateLogic.answered(before, root.file) && root.file.state !== "update-running")
            root.launched = false;
    }

    function settle(): void {
        root.askedFile = null;
        root.checking = false;
        root.deadline.stop();
    }

    function readChannel(): void {
        root.system.query(["/usr/lib/grassfield/grassfield-channel-set"], "update.channel");
    }

    // U14: Omarchy's marker, or the running kernel's modules folder gone (a kernel update): the reboot rule of Omarchy's
    // omarchy-update-restart, read only. An unreadable kernel release says nothing.
    function readRestart(): void {
        const release = root.backend.readText(root.kernelReleaseFile).text.trim();
        const modulesGone = release !== "" && release.indexOf("/") < 0 && !root.backend.readText(root.modulesDir + "/" + release).exists;
        root.restartNeeded = root.backend.readText(root.rebootMarker).exists || modulesGone;
    }

    // U8: the pane opening checks unless a check finished less than paneFreshMs ago or one runs.
    // A stored `update-running` does not hold it back: its waiter may have ended with the session (a reboot or a log out
    // during the update), and a check while Omarchy's lock is still held only joins the waiter (integrator review of a9a5974).
    function checkIfStale(now: double): void {
        const last = Math.max(SoftwareUpdateLogic.timeOf(root.file.checkedAt), root.askedAt);
        if (!root.checking && now - last >= Tokens.softwareUpdatePaneFreshMs)
            root.check();
    }

    function check(): void {
        if (root.checking)
            return;
        root.checking = true;
        root.askedAt = Date.now();
        root.askedFile = root.file;
        root.deadline.restart();
        root.backend.askShellToCheck("update.ask");
    }

    // `verb`: stable, beta, repair or off (grassfield-channel-set); `action`: what it is for (lastAction).
    function setChannel(verb: string, action: string): bool {
        root.lastAction = action;
        return root.system.act("software update: " + action + " (grassfield-channel-set " + verb + ")", ["/usr/lib/grassfield/grassfield-channel-set", verb], root.channelTag);
    }

    function updateNow(): bool {
        if (!root.canUpdate || root.updateRunning || root.file.state === "blocking")
            return false;
        if (!root.system.launch("update now", ["omarchy-launch-floating-terminal-with-presentation", "omarchy-update"]))
            return false;
        root.launched = true;
        root.launchCheck.restart();
        return true;
    }

    function endSession(action: string): bool {
        return root.system.launch(action === "restart" ? "restart" : "log out", ["/usr/lib/grassfield/grassfield-session-end", action === "restart" ? "restart" : "logout"]);
    }

    Component.onCompleted: {
        root.backend.watch(root.backend.softwareUpdateFile);
        root.backend.watch(root.includeFile);
        root.read();
        root.readChannel();
        root.readRestart();
    }

    // The shell's check has no answer in time (it was busy, or it died): the pane stops waiting.
    readonly property Timer deadline: Timer {
        interval: Tokens.softwareUpdateCheckTimeoutMs
        onTriggered: root.settle()
    }

    // After Update Now: the check that finds Omarchy's update lock held, so the shell waits for the update to end (U4, U11).
    readonly property Timer launchCheck: Timer {
        interval: Tokens.softwareUpdateLaunchCheckMs
        onTriggered: {
            root.settle();
            root.check();
        }
    }

    readonly property Connections files: Connections {
        target: root.backend

        function onFileChanged(path: string): void {
            if (path === root.backend.softwareUpdateFile) {
                root.read();
                root.readRestart();
            } else if (path === root.includeFile) {
                root.readChannel();
            }
        }

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === "update.channel") {
                root.channel = ok ? SoftwareUpdateLogic.channelOf(output) : "";
            } else if (tag === "update.ask") {
                // The shell runs (or joins) a check: its answer comes through the file. Anything else: no shell (U10).
                if (!(ok && output.trim() === "ok")) {
                    root.askedFile = null;
                    root.backend.runUpdateChecker("update.run");
                }
            } else if (tag === "update.run") {
                const answer = SoftwareUpdateLogic.parse(output.trim());
                const next = SoftwareUpdateLogic.combine(root.file, answer !== null ? answer : SoftwareUpdateLogic.noAnswer(Date.now(), ok ? "the checker gave no answer" : "the checker could not run"));
                if (next !== null)
                    root.file = next;
                if (root.launched && root.file.state !== "update-running")
                    root.launched = false;
                root.checking = false;
                root.deadline.stop();
            } else if (tag === root.channelTag) {
                // Switching installs nothing (O2); the pane then checks (U12). The value follows the file, watched.
                root.readChannel();
                if (ok) {
                    root.settle();
                    root.check();
                }
            }
        }
    }
}
