pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "WindowTiling.js" as WindowTiling

// The tiling suggestions' link to the compositor plugin (docs/specs/tiling.md TL28): after the `placed` notice of an
// arrangement the shell asked (Compositor.suggestionAsked: a layout or an arrangement from the popover, the Window menu or the
// keys, or a pick of the suggestions), the suggestion of the `hyprctl grassfield-tiling` reply when it fills that window's
// layout and belongs to that notice; any other change of the tile records ends it (a refusal changes nothing). One fetch at
// a time; services/TilingSuggest shows the suggestion. The same reply gives the tile groups (TL29) and the Split View
// Desktops (TL33): read again after every change of the tile records while the plugin offers tiling-groups or tiling-split.
// Without tiling-layouts, tiling-groups or tiling-split nothing is ever fetched.
Singleton {
    id: root

    // The suggestion to show (WindowTiling.parseSuggestion) or null.
    property var suggestion: null
    // The tile groups of the last reply (WindowTiling.parseGroups: the Dock menu's Show Tile Group, an Overview drop), or
    // null (no reply yet, a malformed one, no tiling-groups).
    property var groups: null
    // The Split View Desktops of the last reply (WindowTiling.parseSplits: the menu bar and the Dock hide on them, the Desktops
    // list each after the one it came from); [] without one, a malformed reply or tiling-split.
    property var splits: []
    // The generation whose suggestion the fetch waits for (-1: none).
    property real wantedGen: -1
    // A fetch was asked while the previous process was still running: start it when that one ends.
    property bool startPending: false

    // The suggestion ends (Esc, a click outside, the lock): nothing more is taken for that arrangement.
    function dismiss(): void {
        root.wantedGen = -1;
        root.suggestion = null;
        Compositor.suggestionAsked = null;
    }

    function fetch(): void {
        fetchDeadline.restart();
        if (stateFetch.running)
            root.startPending = true;
        else
            stateFetch.running = true;
    }

    Connections {
        target: Compositor

        function onTilingNotice(notice: var): void {
            if (notice.reason === "invalid" || notice.reason === "locked")
                return; // a refused request changed nothing: what is shown stays
            const asked = Compositor.suggestionAsked;
            if (notice.reason === "placed" && asked !== null && Date.now() <= asked.until && Compositor.canLayouts) {
                // The shown suggestion stays until the reply says what follows (the next zone, or nothing).
                root.wantedGen = notice.gen;
                root.fetch();
                return;
            }
            root.wantedGen = -1;
            root.suggestion = null;
            if (Compositor.canGroups || Compositor.canSplit)
                root.fetch(); // the groups or the Split View Desktops may have changed
        }

        function onCanLayoutsChanged(): void {
            if (!Compositor.canLayouts)
                root.dismiss();
        }

        function onSuggestionsOnChanged(): void {
            if (!Compositor.suggestionsOn)
                root.dismiss();
        }

        function onCanGroupsChanged(): void {
            if (Compositor.canGroups)
                root.fetch();
            else
                root.groups = null;
        }

        function onCanSplitChanged(): void {
            if (Compositor.canSplit)
                root.fetch();
            else
                root.splits = [];
        }
    }

    Component.onCompleted: {
        if (Compositor.canGroups || Compositor.canSplit)
            root.fetch();
    }

    Process {
        id: stateFetch

        command: ["hyprctl", "grassfield-tiling"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (root.startPending)
                    return; // a newer notice asks again
                fetchDeadline.stop();
                if (Compositor.canGroups)
                    root.groups = WindowTiling.parseGroups(text);
                if (Compositor.canSplit)
                    root.splits = WindowTiling.parseSplits(text) || [];
                if (root.wantedGen < 0)
                    return; // no suggestion wanted, or it ended meanwhile
                const sg = WindowTiling.parseSuggestion(text);
                const asked = Compositor.suggestionAsked;
                root.suggestion = sg !== null && sg.gen === root.wantedGen && asked !== null && sg.address === asked.address ? sg : null;
            }
        }
        onRunningChanged: {
            if (!running && root.startPending) {
                root.startPending = false;
                running = true;
            }
        }
    }

    // A reply that does not come in this time: nothing is shown (a stale suggestion would offer zones that changed); the
    // groups stay as last read (the plugin checks them again at each request).
    Timer {
        id: fetchDeadline

        interval: WindowTiling.suggestionWaitMs
        onTriggered: {
            root.startPending = false;
            stateFetch.running = false;
            root.wantedGen = -1;
            root.suggestion = null;
        }
    }
}
