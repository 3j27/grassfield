pragma Singleton
import QtQuick
import Quickshell
import qs.lib
import Quickshell.Io

// Night Shift (warmer screen colours) through packaging/bin/grassfield-nightshift on|off|status (hyprsunset behind it).
// Interface used: `grassfield-nightshift status` prints `on` or `off`; `on` / `off` set it (exit 0 when applied). It
// is available when the helper and hyprsunset are installed; otherwise the switch is hidden (never a fake toggle).
// There is no event source: the state is read when Quick Settings opens and after each change.
// In a GRASSFIELD_DEV session nothing is changed (hyprsunset is the owner's, shared with the nested instance).
Singleton {
    id: root

    property bool available: false
    property bool on: false
    // The helper reported a failure on the last change (hyprsunset missing or not starting).
    property bool failed: false
    readonly property bool devSession: Mode.dev
    signal devSuppressed

    function refresh(): void {
        if (!reader.running)
            reader.running = true;
    }

    function setOn(value: bool): void {
        if (devSession) {
            console.info("dev guard: night shift " + (value ? "on" : "off") + " suppressed");
            devSuppressed();
            return;
        }
        if (!available || setter.running)
            return;
        setter.command = ["grassfield-nightshift", value ? "on" : "off"];
        setter.running = true;
    }

    // "on" / "off" from `status`, or "" when the helper or hyprsunset is missing.
    Process {
        id: reader
        command: ["sh", "-c", "command -v grassfield-nightshift >/dev/null && command -v hyprsunset >/dev/null && grassfield-nightshift status"]
        stdout: StdioCollector {
            onStreamFinished: {
                const t = text.trim();
                root.available = t === "on" || t === "off";
                root.on = t === "on";
            }
        }
    }

    Process {
        id: setter
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            root.failed = exitCode !== 0;
            root.refresh();
        }
        // qmllint enable signal-handler-parameters
    }

    Component.onCompleted: refresh()
}
