pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.services
import "HotCornerActions.js" as Actions

// Hot corners (docs/specs/desktop.md): four trigger windows per screen; after the dwell time the
// action chosen in grassfield.json hotCorners.<corner> runs (none | overview | notifications | apps | lock).
// Actions call the target surface through `qs ipc` on this shell instance. "apps" is the future
// Apps/Launchpad surface: it is called only when that IPC target exists, otherwise it is a no-op.
Scope {
    id: root

    function actionFor(corner: string): string {
        switch (corner) {
        case "topLeft":
            return Settings.hotCornerTopLeft;
        case "topRight":
            return Settings.hotCornerTopRight;
        case "bottomLeft":
            return Settings.hotCornerBottomLeft;
        case "bottomRight":
            return Settings.hotCornerBottomRight;
        }
        return "none";
    }

    function run(action: string): void {
        const argv = Actions.command(action, Quickshell.processId);
        if (!argv)
            return;
        if (action === "apps") {
            probe.running = true;
            return;
        }
        Quickshell.execDetached(argv);
    }

    // `qs ipc show` lists the registered targets; the Apps call only follows when it is there.
    Process {
        id: probe
        command: ["qs", "ipc", "--pid", String(Quickshell.processId), "show"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (Actions.hasTarget(text, "apps"))
                    Quickshell.execDetached(Actions.command("apps", Quickshell.processId));
            }
        }
    }

    Variants {
        model: Quickshell.screens

        Scope {
            id: perScreen

            required property ShellScreen modelData

            Variants {
                model: ["topLeft", "topRight", "bottomLeft", "bottomRight"]

                HotCorner {
                    required property string modelData

                    screen: perScreen.modelData
                    corner: modelData
                    action: root.actionFor(modelData)
                    onFire: root.run(action)
                }
            }
        }
    }
}
