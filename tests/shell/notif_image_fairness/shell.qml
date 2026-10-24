pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.notifications

// Review of 2dfd992, on the REAL Notifications singleton (scripts/dev/test.sh: `qs -p tests/shell/notif_image_fairness`,
// a dev session without the D-Bus server; see the dev-session marker file). Every image is the same noise PNG, `unit`
// bytes once re-encoded (services/image-copy.py); the budget is lowered to 3.5 of them (a sender's share: 1.75).
//  A. Copies made in the same helper batch are protected too (the reviewer's batchevict probe): notification 1 arrives
//     alone, then four more of other senders arrive together (one batch); all five are banners on screen. Banners 1-3
//     keep their images, 4 and 5 show their app icon (no room), and no banner's copy is evicted.
//  B. One sender takes at most half the budget: four banners of "Flood" keep one copy (the others show the app icon),
//     and another sender's image still fits; a sender without banners replaces its own older copy, never another
//     sender's older one.
//  C. A copy an open Notification Center row shows is protected like a banner's: three other senders' images later,
//     the row still shows its image.
//  D. The sender map stays bounded (600 names pass) without reusing a number or dropping a sender that has a copy.
// Prints "notif-image-fairness: PASS" or the failures.
ShellRoot {
    id: root

    property var failures: []
    readonly property string dir: Quickshell.env("GRASSFIELD_TEST_TMP") + "/notif-image-fairness"
    property real unit: 0
    readonly property real budget: Math.floor(3.5 * unit)
    readonly property real share: Math.floor(budget / 2)
    // A 256 x 256 PNG of noise (the same bytes every time): the PNG the helper makes of it has one size, `unit`.
    readonly property string noiseScript: "import random, struct, sys, zlib\nw = 256\nr = random.Random(7)\n"
        + "raw = b''.join(b'\\0' + r.randbytes(w * 4) for _ in range(w))\n"
        + "c = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))\n"
        + "open(sys.argv[1], 'wb').write(b'\\x89PNG\\r\\n\\x1a\\n' + c(b'IHDR', struct.pack('>IIBBBBB', w, w, 8, 6, 0, 0, 0)) + c(b'IDAT', zlib.compress(raw)) + c(b'IEND', b''))\n"
    property string phase: "setup"
    property int waited: 0
    property var files: []

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    function path(name: string): string {
        return dir + "/" + name + ".png";
    }

    // A new notification of `sender` with image `name`, shown as a banner (the intake path: keptImage, then showBanner).
    function notify(name: string, sender: string): void {
        Notifications.showBanner({key: "k-" + name, nid: 1, appName: sender, appIcon: "", image: Notifications.keptImage(path(name), sender), summary: name, bodyHtml: "", time: Date.now(), urgency: 2, actions: []}, 0);
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

    // Bytes of the copies of sender `appName` in the private directory ("<n>.<sender>.png").
    function bytesOf(appName: string): real {
        const sid = Notifications.senderIds[appName.toLowerCase()];
        return files.filter(f => f.sid === sid).reduce((a, f) => a + f.size, 0);
    }

    Process {
        id: setup
        running: true
        command: ["sh", "-c", "set -e; d=$1; rm -rf \"$d\"; mkdir -p \"$d\"; python3 -I -c \"$3\" \"$d/noise.png\"; "
            + "for n in a1 a2 a3 a4 a5 f1 f2 f3 f4 o1 q1 q2 c1 d1 d2 d3; do cp \"$d/noise.png\" \"$d/$n.png\"; done; "
            + "python3 -I \"$2\" file \"$d/noise.png\" 8388608 \"$d/unit.png\"; stat -c %s \"$d/unit.png\"",
            "sh", root.dir, Quickshell.shellPath("services/image-copy.py"), root.noiseScript]
        stdout: StdioCollector {
            onStreamFinished: {
                root.unit = Number(text.trim().split("\n").pop());
                root.check("fixtures created (the re-encoded test image: " + root.unit + " bytes)", root.unit > 100000);
                Notifications.copyBudgetBytes = root.budget;
                root.notify("a1", "Burst 1");
                root.phase = "a1";
                poll.start();
            }
        }
    }

    // "size name" of each copy in the private directory.
    Process {
        id: lister
        command: ["sh", "-c", "for f in \"$1\"/*.png; do [ -f \"$f\" ] && printf '%s %s\\n' \"$(stat -c %s \"$f\")\" \"${f##*/}\"; done; exit 0", "sh", Notifications.copyDir]
        stdout: StdioCollector {
            onStreamFinished: {
                root.files = text.split("\n").filter(l => l !== "").map(l => {
                    const [size, name] = l.split(" ");
                    return {size: Number(size), sid: Number(name.split(".")[1])};
                });
                root.listed();
            }
        }
    }

    function listed(): void {
        const total = files.reduce((a, f) => a + f.size, 0);
        if (phase === "burst") {
            check("A: the banners' copies made in one batch are kept, the rest refused (" + states(["a1", "a2", "a3", "a4", "a5"]) + ")",
                state("a1") === "ok" && state("a2") === "ok" && state("a3") === "ok" && state("a4") === "no" && state("a5") === "no");
            check("A: banners 1-3 show their images, 4 and 5 their app icon",
                ["a1", "a2", "a3"].every(n => Notifications.iconSource(path(n), "") !== "") && ["a4", "a5"].every(n => Notifications.iconSource(path(n), "") === ""));
            check("A: within the budget (" + total + " bytes in " + files.length + " copies)", total <= budget && files.length === 3);
            // B: the burst's banners go away; four critical banners of one sender arrive together.
            for (const n of ["a1", "a2", "a3", "a4", "a5"])
                Notifications.expireBanner("k-" + n);
            for (const n of ["f1", "f2", "f3", "f4"])
                notify(n, "Flood");
            phase = "flood";
            waited = 0;
            poll.start();
        } else if (phase === "flood") {
            check("B: one sender's banners keep at most its half of the budget (" + states(["f1", "f2", "f3", "f4"]) + ", " + bytesOf("Flood") + " bytes)",
                state("f1") === "ok" && state("f2") === "no" && state("f3") === "no" && state("f4") === "no" && bytesOf("Flood") <= share);
            check("B: the overflow shows the app icon", ["f2", "f3", "f4"].every(n => Notifications.iconSource(path(n), "") === ""));
            notify("o1", "Other");
            phase = "other";
            waited = 0;
            poll.start();
        } else if (phase === "other") {
            check("B: another sender's image still fits (" + states(["o1", "f1"]) + ")", state("o1") === "ok" && state("f1") === "ok");
            // The banners go away: f1 and o1 stay, older than anything "Quiet" sends, and no longer kept.
            for (const n of ["f1", "f2", "f3", "f4", "o1"])
                Notifications.expireBanner("k-" + n);
            Notifications.requestCopy(path("q1"), true, "Quiet");
            phase = "q1";
            waited = 0;
            poll.start();
        } else if (phase === "q1") {
            Notifications.requestCopy(path("q2"), true, "Quiet");
            phase = "q2";
            waited = 0;
            poll.start();
        } else if (phase === "q2") {
            check("B: a sender over its share replaces its own oldest copy, not another sender's (" + states(["q1", "q2", "o1", "f1"]) + ")",
                state("q1") === "gone" && state("q2") === "ok" && state("o1") === "ok" && state("f1") === "ok");
            check("B: within the budget (" + total + " bytes in " + files.length + " copies), no sender above half of it",
                total <= budget && ["Flood", "Other", "Quiet"].every(s => bytesOf(s) <= share));
            // C: no banner any more; the Notification Center is open and shows one notification with an image.
            Notifications.toggleCenter("");
            check("C: the Notification Center is open", Notifications.centerOpen);
            Notifications.addEntry({key: "c-1", nid: -1, appName: "Center", appIcon: "", image: Notifications.keptImage(path("c1"), "Center"), summary: "c", body: "", bodyHtml: "",
                time: Date.now(), urgency: 1, transient: false, resident: false, actions: [], restored: false});
            phase = "c1";
            waited = 0;
            poll.start();
        } else if (phase === "c1") {
            check("C: the row's image is copied (" + state("c1") + ")", state("c1") === "ok");
            for (const n of ["d1", "d2", "d3"])
                Notifications.requestCopy(path(n), true, "Sender " + n);
            phase = "d";
            waited = 0;
            poll.start();
        } else if (phase === "d") {
            check("C: the open Center row's copy is kept while others are evicted (" + states(["c1", "d1", "d2", "d3"]) + ")",
                state("c1") === "ok" && state("d1") === "gone" && state("d2") === "ok" && state("d3") === "ok");
            check("C: the row still shows its image", Notifications.iconSource(path("c1"), "") !== "");
            Notifications.closeCenter();
            // D: the sender map stays bounded; a sender whose copy is on disk keeps its number; numbers are never reused.
            const center = Notifications.senderIds["center"]; // c1 is still on disk
            let last = 0;
            let monotonic = true;
            for (let i = 0; i < 600; i++) {
                const id = Notifications.senderIdOf("Passing sender " + i);
                monotonic = monotonic && id > last;
                last = id;
            }
            check("D: at most " + Notifications.maxSenderIds + " sender names kept (" + Object.keys(Notifications.senderIds).length + ")", Object.keys(Notifications.senderIds).length <= Notifications.maxSenderIds);
            check("D: new senders always get new numbers", monotonic);
            check("D: a sender with a copy on disk keeps its number (" + center + ", " + Notifications.senderIds["center"] + ")", center !== undefined && Notifications.senderIds["center"] === center);
            finish();
        }
    }

    function finish(): void {
        if (failures.length === 0) {
            console.log("notif-image-fairness: PASS");
            Qt.exit(0);
        } else {
            console.log("notif-image-fairness: FAIL: " + failures.join("; "));
            Qt.exit(1);
        }
    }

    Timer {
        id: poll
        interval: 100
        repeat: true
        onTriggered: {
            root.waited += interval;
            // The batch starts later in the turn that asked for it: wait a little before trusting "idle".
            if ((!root.idle() || root.waited < 300) && root.waited < 20000)
                return;
            stop();
            if (root.phase === "a1") {
                root.check("A: notification 1 is copied alone first (" + root.state("a1") + ")", root.state("a1") === "ok");
                for (let i = 2; i <= 5; i++)
                    root.notify("a" + i, "Burst " + i);
                root.phase = "burst";
                root.waited = 0;
                poll.start();
                return;
            }
            lister.running = true;
        }
    }
}
