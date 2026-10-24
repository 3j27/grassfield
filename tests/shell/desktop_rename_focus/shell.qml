pragma ComponentBehavior: Bound
import QtQuick
import Quickshell

// Regression test for the desktop icon rename field (docs/specs/desktop.md, "Rename focus").
// After a rename ends (cancelled or committed) the field must lose focus, be disabled, and can never
// commit again, so keys typed afterwards are not swallowed by a hidden field. Run by
// scripts/dev/test.sh: `qs -p tests/shell/desktop_rename_focus` (offscreen); prints
// "desktop-rename-focus: PASS" or the failures. DesktopIcon.qml and IconsLogic.js are symlinks to shell/desktop,
// next to links to the shell modules (DesktopIcon loads its icon through qs.services ThemeIcons).
ShellRoot {
    id: root

    property var failures: []
    property int accepted: 0
    property int phase: 0

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    function inputOf(item: Item): Item {
        for (const c of item.children) {
            if (c.hasOwnProperty("echoMode"))
                return c;
            const r = inputOf(c);
            if (r)
                return r;
        }
        return null;
    }

    FloatingWindow {
        id: win
        visible: true
        implicitWidth: 300
        implicitHeight: 300
        color: "white"

        FocusScope {
            id: scope
            anchors.fill: parent
            focus: true

            Item {
                id: sink
                focus: true
            }

            // The symlinked component is resolved by Quickshell from this directory; qmllint cannot see it.
            // qmllint disable import unresolved-type missing-property
            DesktopIcon {
                id: icon
                name: "file 07.txt"
                isDir: false
                filePath: "/nonexistent/file 07.txt"
                onRenameAccepted: root.accepted++
            }
            // qmllint enable import unresolved-type missing-property
        }
    }

    Timer {
        id: step
        interval: 150
        repeat: true
        running: true
        onTriggered: {
            const field = root.inputOf(icon);
            if (root.phase === 0) {
                root.check("field found", field !== null);
                root.check("hidden field disabled", field && !field.enabled && !field.visible);
                // A hidden field never commits, even if accepted() were somehow emitted.
                field.accepted();
                root.check("hidden accept ignored", root.accepted === 0);
                icon.renaming = true;
            } else if (root.phase === 1) {
                root.check("field enabled while renaming", field.enabled && field.visible);
                root.check("field focused while renaming", field.activeFocus);
                field.accepted();
                root.check("accept while renaming", root.accepted === 1);
                // End the rename the way the view does, then take focus back to the sink.
                icon.renaming = false;
                sink.forceActiveFocus();
            } else if (root.phase === 2) {
                root.check("field lost focus", !field.activeFocus);
                root.check("field disabled after rename", !field.enabled);
                root.check("sink has focus", sink.activeFocus);
                // Re-taking the scope focus must not hand it to the hidden field.
                scope.forceActiveFocus();
                root.check("scope focus stays on sink", sink.activeFocus && !field.activeFocus);
                field.accepted();
                root.check("late accept ignored", root.accepted === 1);
            } else {
                step.running = false;
                if (root.failures.length === 0) {
                    console.log("desktop-rename-focus: PASS");
                    Qt.exit(0);
                } else {
                    console.log("desktop-rename-focus: FAIL " + root.failures.join(", "));
                    Qt.exit(1);
                }
            }
            root.phase++;
        }
    }
}
