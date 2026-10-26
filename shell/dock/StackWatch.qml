pragma ComponentBehavior: Bound
import QtQuick

// The pile of a folder kept in the Dock as a stack: `newest`, the first `keep` entries of the folder in the stack's own order
// (`sort`). One per folder for the whole Dock. All of the work is the helper's (ADR-0025, shell/dock/StackHelper.qml,
// apps/stack-helper): it lists the folder, keeps the window of the first `keep + reserve` entries (30: the margin keeps the
// removal of shown items from calling for a scan), watches the folder, and writes the window when it changed. Nothing of the
// folder is kept or sorted here.
QtObject {
    id: root

    property string folder: ""
    property string sort: "dateAdded"
    property int keep: 3
    property int reserve: 27
    // [{path, isDir}] in the stack's order.
    property var newest: []
    // True while the folder is watched.
    readonly property bool watching: root.helper.watching

    readonly property StackHelper helper: StackHelper {
        folder: root.folder
        sort: root.sort
        limit: root.keep + root.reserve
        // the margin: removals shorten the window for free until fewer than keep + 3 entries are left, then one scan refills it
        low: root.keep + 3
        onArrived: root.newest = root.helper.entries.slice(0, root.keep).map(e => ({path: e.path, isDir: e.isDir}))
    }
}
