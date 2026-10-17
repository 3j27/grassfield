pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Launches Grassfield Settings. Lives in a singleton (not in the menu that triggers it) so the launcher
// process survives the menu closing. A missing binary is reported instead of failing silently.
Singleton {
    id: root

    // Emitted when grassfield-settings cannot be found (the caller shows a notice).
    signal missing

    function open(): void {
        const cmd = (Quickshell.env("GRASSFIELD_SETTINGS_CMD") || "grassfield-settings").split(" ");
        launcher.command = ["sh", "-c", "command -v -- \"$1\" >/dev/null 2>&1 || { echo missing; exit 0; }; setsid -f \"$@\" >/dev/null 2>&1", "sh"].concat(cmd);
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
