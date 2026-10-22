pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.platform

// Launches Grassfield Settings. Lives in a singleton (not in the menu that triggers it) so the launcher
// process survives the menu closing. A missing binary is reported instead of failing silently.
Singleton {
    id: root

    // Emitted when grassfield-settings cannot be found (the caller shows a notice).
    signal missing

    function open(): void {
        Apps.whenScopeKnown(() => root.openNow(""));
    }

    // Settings showing one section first (`--section=<id>`: "wallpaper" for the desktop's Change Wallpaper…).
    function openSection(section: string): void {
        Apps.whenScopeKnown(() => root.openNow(section));
    }

    function openNow(section: string): void {
        const cmd = (Quickshell.env("GRASSFIELD_SETTINGS_CMD") || "grassfield-settings").split(" ").concat(section !== "" ? ["--section=" + section] : []);
        // In a real session Settings gets a scope of its own (Apps.scoped): a shell restart never closes it.
        launcher.command = ["sh", "-c", "command -v -- \"$1\" >/dev/null 2>&1 || { echo missing; exit 0; }; shift; setsid -f \"$@\" >/dev/null 2>&1", "sh", cmd[0]].concat(Apps.scoped(cmd));
        // The pointer size and colour theme the user chose (Pointer.launchEnvironment), like every app the shell starts.
        launcher.environment = Pointer.launchEnvironment();
        launcher.running = true;
    }

    Process {
        id: launcher
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim() !== "missing")
                    return;
                console.warn("grassfield: Grassfield Settings is not installed (grassfield-settings not found)");
                root.missing();
            }
        }
    }
}
