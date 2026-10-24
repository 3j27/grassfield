pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.notifications

// Review of 6e24d36 (minor 1), on the REAL Notifications singleton (scripts/dev/test.sh: `qs -p
// tests/shell/notif_image_budget`, a dev session without the D-Bus server; see the dev-session marker file).
// The private copies of notification images have a total byte budget across all senders (64 MiB; lowered to 3 MiB here):
//  - six 1 MiB images: the three newest are kept, the three oldest are evicted (oldest first), and the directory never
//    holds more than the budget;
//  - an evicted image falls back to the app icon and is not re-made just because it is shown (no eviction loop);
//  - an image larger than the whole budget is refused (the app icon shows) and evicts nothing;
//  - a copy a banner on screen shows is never evicted: the next oldest goes instead;
//  - an image that would not fit even after evicting every copy not on a banner is refused before anything is evicted.
// Prints "notif-image-budget: PASS" or the failures.
ShellRoot {
    id: root

    property var failures: []
    readonly property string dir: Quickshell.env("GRASSFIELD_TEST_TMP") + "/notif-image-budget"
    readonly property real mib: 1024 * 1024
    property int phase: 0
    property int waited: 0
    property var sizes: []

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    function path(name: string): string {
        return dir + "/" + name + ".png";
    }

    function state(name: string): string {
        const e = Notifications.localCopies[path(name)];
        return e === undefined ? "" : e.state;
    }

    function states(names: var): string {
        return names.map(n => n + "=" + state(n)).join(" ");
    }

    function idle(): bool {
        return Notifications.copyQueue.length === 0 && Notifications.copyBatch.length === 0;
    }

    function total(): real {
        return sizes.reduce((a, b) => a + b, 0);
    }

    Process {
        id: setup
        running: true
        command: ["sh", "-c", "set -e; d=$1; rm -rf \"$d\"; mkdir -p \"$d\"; for i in 1 2 3 4 5 6; do head -c 1048576 /dev/zero >\"$d/a$i.png\"; done; "
            + "head -c 4194304 /dev/zero >\"$d/huge.png\"; head -c 2621440 /dev/zero >\"$d/mid.png\"", "sh", root.dir]
        // Quickshell's qmltypes name QProcess::ExitStatus without exporting it (metadata quirk).
        // qmllint disable signal-handler-parameters
        onExited: code => {
            // qmllint enable signal-handler-parameters
            root.check("fixtures created", code === 0);
            Notifications.copyBudgetBytes = 3 * root.mib;
            for (const n of ["a1", "a2", "a3", "a4", "a5", "a6"])
                Notifications.requestCopy(root.path(n), true);
            root.phase = 1;
            poll.start();
        }
    }

    // The sizes of the copies in the private directory, one per line.
    Process {
        id: lister
        command: ["sh", "-c", "for f in \"$1\"/*.img; do [ -f \"$f\" ] && stat -c %s \"$f\"; done; exit 0", "sh", Notifications.copyDir]
        stdout: StdioCollector {
            onStreamFinished: {
                root.sizes = text.split("\n").filter(l => l !== "").map(Number);
                root.listed();
            }
        }
    }

    function listed(): void {
        if (phase === 1) {
            check("six 1 MiB images, 3 MiB budget: the three newest are kept, the oldest evicted (" + states(["a1", "a2", "a3", "a4", "a5", "a6"]) + ")",
                state("a1") === "gone" && state("a2") === "gone" && state("a3") === "gone" && state("a4") === "ok" && state("a5") === "ok" && state("a6") === "ok");
            check("the directory holds at most the budget (" + total() + " bytes in " + sizes.length + " copies)", total() <= 3 * mib && sizes.length === 3);
            check("an evicted image falls back to the app icon", Notifications.iconSource(path("a1"), "") === "");
            check("a kept image shows its copy", Notifications.iconSource(path("a6"), "").endsWith(".img"));
            // Shown again (as a binding re-evaluation would): no copy is re-made.
            for (const n of ["a1", "a2", "a3"])
                Notifications.iconSource(path(n), "");
            phase = 2;
            waited = 0;
            poll.start();
        } else if (phase === 3) {
            check("an image larger than the budget is refused (" + state("huge") + ")", state("huge") === "no");
            check("the refused image falls back to the app icon", Notifications.iconSource(path("huge"), "") === "");
            check("it evicted nothing (" + states(["a4", "a5", "a6"]) + ", " + sizes.length + " copies)", state("a4") === "ok" && state("a5") === "ok" && state("a6") === "ok" && sizes.length === 3);
            // a4 (the oldest kept copy) is on a banner; a new notification names a1 again.
            Notifications.showBanner({key: "budget-banner", nid: 1, appName: "Test", appIcon: "", image: path("a4"), summary: "s", bodyHtml: "", time: Date.now(), urgency: 1, actions: []}, 0);
            Notifications.requestCopy(path("a1"), true);
            phase = 4;
            waited = 0;
            poll.start();
        } else if (phase === 4) {
            check("the banner's copy is kept, the next oldest is evicted (" + states(["a1", "a4", "a5", "a6"]) + ")",
                state("a1") === "ok" && state("a4") === "ok" && state("a5") === "gone" && state("a6") === "ok");
            check("still within the budget (" + total() + " bytes in " + sizes.length + " copies)", total() <= 3 * mib && sizes.length === 3);
            // 2.5 MiB with the banner's 1 MiB kept: cannot fit even after evicting a1 and a6, so neither is evicted.
            Notifications.requestCopy(path("mid"), true);
            phase = 5;
            waited = 0;
            poll.start();
        } else if (phase === 5) {
            check("an image the kept copies leave no room for is refused (" + state("mid") + ")", state("mid") === "no");
            check("and evicts nothing (" + states(["a1", "a4", "a6"]) + ", " + sizes.length + " copies)", state("a1") === "ok" && state("a4") === "ok" && state("a6") === "ok" && sizes.length === 3);
            finish();
        }
    }

    function finish(): void {
        if (failures.length === 0) {
            console.log("notif-image-budget: PASS");
            Qt.exit(0);
        } else {
            console.log("notif-image-budget: FAIL: " + failures.join("; "));
            Qt.exit(1);
        }
    }

    Timer {
        id: poll
        interval: 100
        repeat: true
        onTriggered: {
            root.waited += interval;
            if (root.phase === 1 || root.phase === 4 || root.phase === 5) {
                if (!root.idle() && root.waited < 20000)
                    return;
                stop();
                lister.running = true;
            } else if (root.phase === 2) {
                if (root.waited < 1500)
                    return;
                stop();
                root.check("an evicted image is not re-made because it is shown (" + root.states(["a1", "a2", "a3"]) + ")",
                    root.idle() && root.state("a1") === "gone" && root.state("a2") === "gone" && root.state("a3") === "gone");
                Notifications.requestCopy(root.path("huge"), true);
                root.phase = 3;
                root.waited = 0;
                poll.start();
            } else if (root.phase === 3) {
                if (!root.idle() && root.waited < 20000)
                    return;
                stop();
                lister.running = true;
            }
        }
    }
}
