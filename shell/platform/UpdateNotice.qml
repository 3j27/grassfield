pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.lib
import "UpdateNotice.js" as UpdateNotice

// Watches the installed package version against what this session runs (GF-083). `updatePending` turns true once the
// installed version differs from the version the shell started with or from the one the compositor plugin reports; the
// shell root shows one "Log out to finish updating" notice for it. Real session only (a dev session runs the repository,
// not the package). The plugin's version comes from its read-only `grassfield` hyprctl reply once the plugin answered the
// hello; a plugin without the field, or a package without the VERSION file, leaves everything unknown and nothing is shown.
Item {
    id: root

    // Overridable for tests.
    property string versionPath: "/usr/share/grassfield/VERSION"
    property var queryCommand: ["hyprctl", "grassfield"]
    property bool active: Mode.updateNotices
    property bool pluginPresent: Capabilities.pluginPresent

    property string installedVersion: ""
    property string shellVersion: ""
    property string pluginVersion: ""
    readonly property bool updatePending: root.active && UpdateNotice.pending(root.installedVersion, root.shellVersion, root.pluginVersion)

    visible: false

    function ask(): void {
        if (root.active && root.pluginPresent && root.pluginVersion === "" && !query.running)
            query.running = true;
    }

    onPluginPresentChanged: root.ask()
    onActiveChanged: root.ask()
    Component.onCompleted: root.ask()

    FileView {
        id: file
        path: root.active ? root.versionPath : ""
        watchChanges: true
        printErrors: false
        onLoaded: {
            const v = UpdateNotice.fromFile(file.text());
            root.installedVersion = v;
            // The first successful read is what this shell started with; later reads are installs.
            if (root.shellVersion === "")
                root.shellVersion = v;
        }
        onLoadFailed: root.installedVersion = ""
        onFileChanged: file.reload()
    }

    Process {
        id: query
        command: root.queryCommand
        stdout: StdioCollector {
            onStreamFinished: root.pluginVersion = UpdateNotice.fromReply(text)
        }
    }
}
