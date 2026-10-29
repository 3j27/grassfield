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
    // The windows that do not fit half of their output (WindowTiling.parseUnfit: the Window menu greys their Full Screen Tile,
    // ADR-0036 D57); [] without one, a malformed reply or tiling-split. Read again when the Window menu opens (refresh()).
    property var unfit: []
    // The generation whose suggestion the fetch waits for (-1: none).
    property real wantedGen: -1
    // A suggestion asked for is on its way (from the notice of its arrangement until its reply is read or the deadline passes):
    // a Split View's picker is pending meanwhile (services/TilingSuggest).
    property bool awaiting: false
    // A fetch was asked while the previous process was still running: start it when that one ends.
    property bool startPending: false
    // The Split View picker the user dismissed ({address, gen} of its suggestion): a later reply does not show it again (its
    // window fills instead).
    property var declined: null
    // A fetch gave up at its deadline: one more is made shortly (the tile groups and the Split View Desktops would otherwise
    // wait for the next notice; re-review of e5bd9d2: a Split View learnt only through a timed-out fetch never filled).
    property bool retried: false

    // The suggestion ends (Esc, a click outside, the lock): nothing more is taken for that arrangement.
    function dismiss(): void {
        if (root.suggestion)
            root.declined = {address: root.suggestion.address, gen: root.suggestion.gen};
        root.wantedGen = -1;
        root.awaiting = false;
        root.suggestion = null;
        Compositor.suggestionAsked = null;
    }

    // The Window menu opens: what fits a half is read again (a window opened or changed its limits since the last reply).
    function refresh(): void {
        if (Compositor.canSplit)
            root.fetch();
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
                root.awaiting = true;
                root.fetch();
                return;
            }
            root.wantedGen = -1;
            root.awaiting = false;
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
            if (Compositor.canSplit) {
                root.fetch();
            } else {
                root.splits = [];
                root.unfit = [];
            }
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
                // A reply that does not read (a fetch killed at its deadline, hyprctl missing) keeps the last Split View
                // Desktops; a reply read lets a later deadline retry again.
                const splits = WindowTiling.parseSplits(text);
                const sg = WindowTiling.parseSuggestion(text);
                // A Split View the shell did not start still shows its picker (D48): its suggestion is taken as if asked. Its
                // member counts as waiting for it from now (awaiting) so that it is not filled meanwhile (TilingSuggest).
                let adopted = root.wantedGen < 0 && Compositor.canLayouts && Compositor.canSplit ? WindowTiling.splitPicker(splits, sg, root.declined) : null;
                if (adopted !== null && root.suggestion !== null && root.suggestion.address === adopted.address && root.suggestion.gen === adopted.gen)
                    adopted = null; // already the one shown: kept as it is
                if (adopted !== null) {
                    Compositor.suggestionAsked = {address: adopted.address, until: Date.now() + WindowTiling.suggestionWaitMs};
                    root.awaiting = true;
                }
                if (Compositor.canSplit && splits !== null)
                    root.splits = splits;
                const unfit = Compositor.canSplit ? WindowTiling.parseUnfit(text) : null;
                if (unfit !== null)
                    root.unfit = unfit;
                if (splits !== null)
                    root.retried = false;
                if (adopted !== null) {
                    root.suggestion = adopted;
                    root.awaiting = false;
                    return;
                }
                if (root.wantedGen < 0)
                    return; // no suggestion wanted, or it ended meanwhile
                const asked = Compositor.suggestionAsked;
                root.suggestion = sg !== null && sg.gen === root.wantedGen && asked !== null && sg.address === asked.address ? sg : null;
                root.awaiting = false; // after the suggestion was shown (or refused): a Split View's picker is that one now
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
    // groups and the Split View Desktops stay as last read (the plugin checks them again at each request), and one more fetch
    // reads them again shortly. Called by the deadline (and by tests/shell/split_view).
    function giveUp(): void {
        root.startPending = false;
        stateFetch.running = false;
        root.wantedGen = -1;
        root.awaiting = false; // a Split View's picker is not on its way any more: its member fills (TilingSuggest)
        root.suggestion = null;
        if (!root.retried && (Compositor.canGroups || Compositor.canSplit)) {
            root.retried = true;
            retry.restart();
        }
    }

    Timer {
        id: fetchDeadline

        interval: WindowTiling.suggestionWaitMs
        onTriggered: root.giveUp()
    }

    Timer {
        id: retry

        interval: WindowTiling.suggestionWaitMs / 3
        onTriggered: root.fetch()
    }
}
