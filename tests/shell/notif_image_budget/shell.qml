pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.notifications

// Reviews of 6e24d36 (minor 1) and 2dfd992, on the REAL Notifications singleton (scripts/dev/test.sh: `qs -p
// tests/shell/notif_image_budget`, a dev session without the D-Bus server; see the dev-session marker file).
// The private copies of notification images (PNGs the shell made, services/image-copy.py) have a total byte budget
// across all senders (64 MiB; lowered here to 3.5 copies of the test image, `unit` bytes each once re-encoded, so one
// sender's share is 1.75 copies; each image below comes from its own sender, tests/shell/notif_image_fairness covers the
// share):
//  - six such images: the three newest are kept, the three oldest are evicted (oldest first), and the directory never
//    holds more than the budget;
//  - an evicted image falls back to the app icon and is not re-made just because it is shown (no eviction loop);
//  - an image file over the size cap (History.MAX_IMAGE_FILE_BYTES) is refused (the app icon shows) and evicts nothing;
//  - a copy a banner on screen shows is never evicted: the next oldest goes instead;
//  - an image the banners' copies leave no room for is refused before anything is evicted.
// Prints "notif-image-budget: PASS" or the failures.
ShellRoot {
    id: root

    property var failures: []
    readonly property string dir: Quickshell.env("GRASSFIELD_TEST_TMP") + "/notif-image-budget"
    // Bytes of the PNG the helper makes of the test image (measured at setup), and the lowered budget.
    property real unit: 0
    readonly property real budget: Math.floor(3.5 * unit)
    // A 256 x 256 PNG of noise (the same bytes every time): the PNG the helper makes of it has one size, `unit`.
    readonly property string noiseScript: "import random, struct, sys, zlib\nw = 256\nr = random.Random(7)\n"
        + "raw = b''.join(b'\\0' + r.randbytes(w * 4) for _ in range(w))\n"
        + "c = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))\n"
        + "open(sys.argv[1], 'wb').write(b'\\x89PNG\\r\\n\\x1a\\n' + c(b'IHDR', struct.pack('>IIBBBBB', w, w, 8, 6, 0, 0, 0)) + c(b'IDAT', zlib.compress(raw)) + c(b'IEND', b''))\n"
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

    // Each image has its own sender (its file name), so only the global budget applies here.
    function request(name: string): void {
        Notifications.requestCopy(path(name), true, "Sender " + name);
    }

    function banner(name: string): void {
        Notifications.showBanner({key: "budget-" + name, nid: 1, appName: "Sender " + name, appIcon: "", image: path(name), summary: "s", bodyHtml: "", time: Date.now(), urgency: 1, actions: []}, 0);
    }

    function state(name: string): string {
        const e = Notifications.localCopies[path(name)];
        return e === undefined ? "" : e.state;
    }

    function states(names: var): string {
        return names.map(n => n + "=" + state(n)).join(" ");
    }

    // Nothing queued and no batch running (copyBatch is set while the helper runs).
    function idle(): bool {
        return Notifications.copyQueue.length === 0 && Notifications.copyBatch.length === 0;
    }

    function total(): real {
        return sizes.reduce((a, b) => a + b, 0);
    }

    // The images (one noise PNG under several names, and one over the size cap), then the size of the PNG the helper makes
    // of it, printed last.
    Process {
        id: setup
        running: true
        command: ["sh", "-c", "set -e; d=$1; rm -rf \"$d\"; mkdir -p \"$d\"; python3 -I -c \"$3\" \"$d/noise.png\"; for n in a1 a2 a3 a4 a5 a6 c; do cp \"$d/noise.png\" \"$d/$n.png\"; done; "
            + "cp \"$d/noise.png\" \"$d/huge.png\"; head -c 9437184 /dev/zero >>\"$d/huge.png\"; python3 -I \"$2\" file \"$d/noise.png\" 8388608 \"$d/unit.png\"; stat -c %s \"$d/unit.png\"",
            "sh", root.dir, Quickshell.shellPath("services/image-copy.py"), root.noiseScript]
        stdout: StdioCollector {
            onStreamFinished: {
                root.unit = Number(text.trim().split("\n").pop());
                root.check("fixtures created (the re-encoded test image: " + root.unit + " bytes)", root.unit > 100000);
                Notifications.copyBudgetBytes = root.budget;
                for (const n of ["a1", "a2", "a3", "a4", "a5", "a6"])
                    root.request(n);
                root.phase = 1;
                poll.start();
            }
        }
    }

    // The sizes of the copies in the private directory, one per line.
    Process {
        id: lister
        command: ["sh", "-c", "for f in \"$1\"/*.png; do [ -f \"$f\" ] && stat -c %s \"$f\"; done; exit 0", "sh", Notifications.copyDir]
        stdout: StdioCollector {
            onStreamFinished: {
                root.sizes = text.split("\n").filter(l => l !== "").map(Number);
                root.listed();
            }
        }
    }

    function listed(): void {
        if (phase === 1) {
            check("six images, a budget of 3.5: the three newest are kept, the oldest evicted (" + states(["a1", "a2", "a3", "a4", "a5", "a6"]) + ")",
                state("a1") === "gone" && state("a2") === "gone" && state("a3") === "gone" && state("a4") === "ok" && state("a5") === "ok" && state("a6") === "ok");
            check("the directory holds at most the budget (" + total() + " bytes in " + sizes.length + " copies)", total() <= budget && sizes.length === 3);
            check("an evicted image falls back to the app icon", Notifications.iconSource(path("a1"), "") === "");
            check("a kept image shows its copy", Notifications.iconSource(path("a6"), "").endsWith(".png"));
            // Shown again (as a binding re-evaluation would): no copy is re-made.
            for (const n of ["a1", "a2", "a3"])
                Notifications.iconSource(path(n), "");
            phase = 2;
            waited = 0;
            poll.start();
        } else if (phase === 3) {
            check("an image file over the size cap is refused (" + state("huge") + ")", state("huge") === "no");
            check("the refused image falls back to the app icon", Notifications.iconSource(path("huge"), "") === "");
            check("it evicted nothing (" + states(["a4", "a5", "a6"]) + ", " + sizes.length + " copies)", state("a4") === "ok" && state("a5") === "ok" && state("a6") === "ok" && sizes.length === 3);
            // a4 (the oldest kept copy) is on a banner; a new notification names a1 again.
            banner("a4");
            request("a1");
            phase = 4;
            waited = 0;
            poll.start();
        } else if (phase === 4) {
            check("the banner's copy is kept, the next oldest is evicted (" + states(["a1", "a4", "a5", "a6"]) + ")",
                state("a1") === "ok" && state("a4") === "ok" && state("a5") === "gone" && state("a6") === "ok");
            check("still within the budget (" + total() + " bytes in " + sizes.length + " copies)", total() <= budget && sizes.length === 3);
            // The three copies are on banners now: a fourth image of another sender cannot fit, nothing is evicted.
            banner("a1");
            banner("a6");
            request("c");
            phase = 5;
            waited = 0;
            poll.start();
        } else if (phase === 5) {
            check("an image the banners' copies leave no room for is refused (" + state("c") + ")", state("c") === "no");
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
            if (root.phase === 1 || root.phase === 3 || root.phase === 4 || root.phase === 5) {
                // The batch starts later in the turn that asked for it: wait a tick before trusting "idle".
                if ((!root.idle() || root.waited < 300) && root.waited < 20000)
                    return;
                stop();
                lister.running = true;
            } else if (root.phase === 2) {
                if (root.waited < 1500)
                    return;
                stop();
                root.check("an evicted image is not re-made because it is shown (" + root.states(["a1", "a2", "a3"]) + ")",
                    root.idle() && root.state("a1") === "gone" && root.state("a2") === "gone" && root.state("a3") === "gone");
                root.request("huge");
                root.phase = 3;
                root.waited = 0;
                poll.start();
            }
        }
    }
}
