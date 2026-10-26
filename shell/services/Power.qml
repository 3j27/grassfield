pragma Singleton
import QtQuick
import Quickshell
import qs.lib
import qs.platform

// Session power actions behind confirmation dialogs. In the nested dev session
// (GRASSFIELD_DEV=1) sleep, restart and shut down never reach systemctl: they would act on the
// owner's real machine. Log out only ends the nested compositor.
Singleton {
    id: root

    readonly property bool dev: Mode.dev

    function systemctl(verb: string): void {
        if (dev) {
            console.warn("grassfield-shell: dev session, suppressed `systemctl " + verb + "`");
            return;
        }
        Quickshell.execDetached(["systemctl", verb]);
    }

    // Log out, restart and shut down first ask every application to close and wait for the ones that keep their window
    // open to save work (packaging/bin/grassfield-session-end, GF-025). The session only ends when all windows are gone,
    // or when the user chooses "... Anyway" in the notice that names the applications still open.
    function endSession(action: string): void {
        if (dev) {
            console.warn("grassfield-shell: dev session, suppressed grassfield-session-end " + action);
            return;
        }
        Quickshell.execDetached(["/usr/lib/grassfield/grassfield-session-end", action]);
    }

    function sleepNow(): void {
        if (dev)
            Popups.notice(qsTr("Sleep"), qsTr("Development session: Sleep is disabled here so it cannot suspend your real computer."));
        systemctl("suspend");
    }

    // Executes a confirmed action id (see the system menu).
    function run(action: string, args: var): void {
        switch (action) {
        case "restart":
            if (dev)
                Popups.notice(qsTr("Restart"), qsTr("Development session: Restart is disabled here so it cannot reboot your real computer."));
            endSession("restart");
            return;
        case "shutdown":
            if (dev)
                Popups.notice(qsTr("Shut Down"), qsTr("Development session: Shut Down is disabled here so it cannot power off your real computer."));
            endSession("shutdown");
            return;
        case "logout":
            if (dev)
                Compositor.exitSession();
            else
                endSession("logout");
            return;
        case "emptytrash":
            Trash.emptyNow();
            return;
        case "forcequit":
            // One pid (the Force Quit panel) or every process of an app (the Dock menu's Option variant).
            (args.pids ? args.pids : [args.pid]).forEach(p => forceQuit(p));
            return;
        }
        Popups.close();
    }

    // SIGKILL a client by PID (taken from Hyprland window data). Refuses PIDs that are not
    // plain client processes.
    function forceQuit(pid: int): void {
        if (!(pid > 1)) {
            console.warn("grassfield-shell: force quit refused, invalid pid", pid);
            return;
        }
        Quickshell.execDetached(["kill", "-9", String(pid)]);
    }
}
