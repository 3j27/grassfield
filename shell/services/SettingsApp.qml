pragma Singleton
import QtQuick
import Quickshell
import qs.lib
import qs.platform
import Quickshell.Io

// Launches Grassfield Settings. Lives in a singleton (not in the menu that triggers it) so the launcher
// process survives the menu closing. A missing binary is reported instead of failing silently. Settings is one instance per
// user (apps/settings/src/settingsinstance.h): a launch while it runs hands its section or --about to it and leaves, so the
// one Settings window comes to that page instead of a second one opening.
Singleton {
    id: root

    // Emitted when grassfield-settings cannot be found (the caller shows a notice).
    signal missing

    function open(): void {
        Apps.whenScopeKnown(() => root.openNow([]));
    }

    // Settings showing one section first (`--section=<id>`: "wallpaper" for the desktop's Change Wallpaper…).
    // `display` (optional): an output name, which Wallpaper opens on (`--display=<output>`; a running Settings gets
    // `wallpaper@<output>` over D-Bus from the second launch). Output names only: anything else is not passed.
    function openSection(section: string, display: var): void {
        const args = section !== "" ? ["--section=" + section] : [];
        if (section !== "" && typeof display === "string" && /^[A-Za-z0-9._:-]{1,64}$/.test(display))
            args.push("--display=" + display);
        Apps.whenScopeKnown(() => root.openNow(args));
    }

    // About This Computer (ADR-0040 ID-19): Settings' own small window (`--about`, role "info"). An open one comes forward,
    // once the Grassfield menu's layer has gone; a start while Settings runs makes it in that process, or finds it still
    // mapping, so there is never a second one.
    function openAbout(): void {
        const shown = Compositor.taggedToplevel("org.grassfield.Settings", "info");
        if (shown) {
            Compositor.activateAfterLayer(shown, "grassfield-overlay");
            return;
        }
        Apps.whenScopeKnown(() => root.openNow(["--about"]));
    }

    // `args`: Settings' own options after the command.
    function openNow(args: var): void {
        const cmd = (Mode.devValue("SETTINGS_CMD") || "grassfield-settings").split(" ").concat(args);
        // In a real session Settings gets a scope of its own (Apps.scoped): a shell restart never closes it.
        launcher.command = ["sh", "-c", "command -v -- \"$1\" >/dev/null 2>&1 || { echo missing; exit 0; }; shift; setsid -f \"$@\" >/dev/null 2>&1", "sh", cmd[0]].concat(Apps.scoped(cmd));
        // The pointer size and colour theme the user chose, and GTK_USE_PORTAL, like every app the shell starts.
        launcher.environment = Apps.ownAppEnvironment();
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
