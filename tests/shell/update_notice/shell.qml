pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.platform

// GF-083 on the REAL UpdateNotice component (scripts/dev/test.sh: `qs -p tests/shell/update_notice`, offscreen; prints
// "update-notice: PASS" or the failures). The plugin's reply is a fixed `printf`, the installed version a fixture file.
// - plugin older than the package: pending;
// - spelling only (1.0.0rc1 vs 1.0.0-rc1): not pending;
// - a reply without the version field (older plugin) and a missing VERSION file: not pending (capability check);
// - not active (dev session): never pending, whatever the files say.
ShellRoot {
    id: root

    property var failures: []

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    readonly property string withVersion: '{"v":"gfc/1","type":"capabilities","features":["a"],"version":"1.0.0rc1"}'
    readonly property string withoutVersion: '{"v":"gfc/1","type":"capabilities","features":["a"]}'

    UpdateNotice {
        id: older
        active: true
        pluginPresent: true
        versionPath: Quickshell.shellPath("installed-new.txt")
        queryCommand: ["printf", "%s", root.withVersion]
    }

    UpdateNotice {
        id: spelling
        active: true
        pluginPresent: true
        versionPath: Quickshell.shellPath("installed-same.txt")
        queryCommand: ["printf", "%s", root.withVersion]
    }

    UpdateNotice {
        id: oldPlugin
        active: true
        pluginPresent: true
        versionPath: Quickshell.shellPath("installed-same.txt")
        queryCommand: ["printf", "%s", root.withoutVersion]
    }

    UpdateNotice {
        id: noFile
        active: true
        pluginPresent: true
        versionPath: Quickshell.shellPath("does-not-exist.txt")
        queryCommand: ["printf", "%s", root.withVersion]
    }

    UpdateNotice {
        id: dev
        active: false
        pluginPresent: true
        versionPath: Quickshell.shellPath("installed-new.txt")
        queryCommand: ["printf", "%s", root.withVersion]
    }

    UpdateNotice {
        id: noPlugin
        active: true
        pluginPresent: false
        versionPath: Quickshell.shellPath("installed-new.txt")
        queryCommand: ["printf", "%s", root.withVersion]
    }

    function run(): void {
        check("older plugin reads its version", older.pluginVersion === "1.0.0rc1");
        check("older plugin than the package: pending", older.updatePending === true);
        check("spelling only: not pending", spelling.pluginVersion === "1.0.0rc1" && spelling.updatePending === false);
        check("a plugin without the version field: not pending", oldPlugin.pluginVersion === "" && oldPlugin.updatePending === false);
        check("no VERSION file: not pending", noFile.installedVersion === "" && noFile.updatePending === false);
        check("dev session: never pending", dev.updatePending === false && dev.pluginVersion === "");
        // Without the plugin only the shell's own version is known, and it is the installed one.
        check("no plugin yet: asks nothing, not pending", noPlugin.pluginVersion === "" && noPlugin.updatePending === false);
    }

    Timer {
        interval: 1500
        running: true
        onTriggered: {
            root.run();
            if (root.failures.length === 0) {
                console.log("update-notice: PASS");
                Qt.exit(0);
            } else {
                console.log("update-notice: FAIL " + root.failures.join(", "));
                Qt.exit(1);
            }
        }
    }
}
