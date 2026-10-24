pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.services

// Probe of tests/security/theme_icon_files.sh, part 6 (media art over https, offline: a local HTTPS server at PROBE_BASE,
// trusted through CURL_CA_BUNDLE). Through the REAL ThemeIcons.artSource, as both Now Playing views use it:
//  - unlocked: an https art URL becomes a PNG the shell made and its Image loads;
//  - locked (SessionState.locked): a new URL is not fetched (no request, no entry), the art already made still shows;
//  - unlocked again: the held URL is fetched (the binding asks again);
//  - three URLs asked in one turn (skipping through tracks): only the newest is fetched, the older ones are forgotten.
// Prints "probe:" lines and "probe: done", then exits.
ShellRoot {
    id: root

    readonly property string base: Quickshell.env("PROBE_BASE")
    property string phase: "unlocked"
    property int waited: 0
    property string lockedUrl: ""

    function stateOf(url: string): string {
        const e = ThemeIcons.copies["url:" + url];
        return e === undefined ? "none" : e.state;
    }

    function cls(source: string): string {
        return source === "" ? "none" : (source.startsWith("file://") && source.indexOf("/grassfield-icons-") > 0 && source.endsWith(".png") ? "copy" : "other:" + source);
    }

    function idle(): bool {
        return ThemeIcons.queue.length === 0 && ThemeIcons.batch.length === 0 && ThemeIcons.activeRun === null;
    }

    FloatingWindow {
        visible: true
        implicitWidth: 100
        implicitHeight: 40

        Image {
            id: shown
            width: 16
            height: 16
            asynchronous: true
            source: ThemeIcons.artSource(root.base + "/ok.png")
        }

        Image {
            id: held
            x: 20
            width: 16
            height: 16
            asynchronous: true
            source: root.lockedUrl !== "" ? ThemeIcons.artSource(root.lockedUrl) : ""
        }
    }

    Timer {
        interval: 100
        repeat: true
        running: true
        onTriggered: {
            root.waited += interval;
            if (root.phase === "unlocked") {
                if ((root.stateOf(root.base + "/ok.png") !== "ok" || shown.status !== Image.Ready) && root.waited < 20000)
                    return;
                console.log("probe: unlocked class=" + root.cls(shown.source.toString()) + " status=" + shown.status);
                SessionState.locked = true;
                root.lockedUrl = root.base + "/locked.png";
                root.phase = "locked";
                root.waited = 0;
            } else if (root.phase === "locked") {
                if (root.waited < 2000)
                    return;
                console.log("probe: locked source=" + root.cls(held.source.toString()) + " entry=" + root.stateOf(root.lockedUrl) + " cached=" + root.cls(ThemeIcons.artSource(root.base + "/ok.png")));
                SessionState.locked = false;
                root.phase = "unlock";
                root.waited = 0;
            } else if (root.phase === "unlock") {
                if ((root.stateOf(root.lockedUrl) !== "ok" || held.status !== Image.Ready) && root.waited < 20000)
                    return;
                console.log("probe: after-unlock class=" + root.cls(held.source.toString()) + " status=" + held.status);
                // Skipping through three tracks in one turn.
                for (const name of ["a", "b", "c"])
                    ThemeIcons.artSource(root.base + "/" + name + ".png");
                root.phase = "newest";
                root.waited = 0;
            } else if (root.phase === "newest") {
                if ((!root.idle() || root.waited < 500) && root.waited < 20000)
                    return;
                console.log("probe: newest a=" + root.stateOf(root.base + "/a.png") + " b=" + root.stateOf(root.base + "/b.png") + " c=" + root.stateOf(root.base + "/c.png"));
                console.log("probe: done");
                Qt.exit(0);
            }
        }
    }
}
