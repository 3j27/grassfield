pragma Singleton
import QtQuick
import Quickshell
import qs.platform

// Session power actions behind confirmation dialogs. In the nested dev session
// (GRASSFIELD_DEV=1) sleep, restart and shut down never reach systemctl: they would act on the
// owner's real machine. Log out only ends the nested compositor.
Singleton {
    id: root

    readonly property bool dev: Quickshell.env("GRASSFIELD_DEV") === "1"

    function systemctl(verb: string): void {
        if (dev) {
            console.warn("grassfield-shell: dev session, suppressed `systemctl " + verb + "`");
            return;
        }
        Quickshell.execDetached(["systemctl", verb]);
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
            systemctl("reboot");
            return;
        case "shutdown":
            if (dev)
                Popups.notice(qsTr("Shut Down"), qsTr("Development session: Shut Down is disabled here so it cannot power off your real computer."));
            systemctl("poweroff");
            return;
        case "logout":
            Compositor.exitSession();
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
