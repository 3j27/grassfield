import QtQuick
import Quickshell
import qs.services

// WallpaperOnline when its commands cannot start or hang (run by tests/shell/wallpaper_online_start_fail.sh with an empty PATH and
// GRASSFIELD_SESSION=1). Quickshell sends no `exited` for a failed start, so the scheduler must leave "scheduled" (nmcli missing:
// not metered, the fetch runs) and "fetching" (helper missing: the fetch fails) by running going back to false, and a hanging
// nmcli or helper is killed after its timeout. Prints "wallpaper-online-start-fail: PASS" or FAIL <why>.
ShellRoot {
    id: root

    property string failure: ""

    function check(cond: bool, what: string): void {
        if (!cond && failure === "")
            failure = what;
    }

    function begin(): void {
        WallpaperOnline.meteredCommand = ["/nonexistent/nmcli"];
        WallpaperOnline.fetchCommandOverride = ["/nonexistent/helper"];
        WallpaperOnline.tryFetch("2026-01-01");
    }

    Component.onCompleted: Qt.callLater(begin)

    // A: neither nmcli nor the helper can start: one fetch attempt, ended as a failure, not stuck.
    Timer {
        interval: 2500
        running: true
        onTriggered: {
            root.check(WallpaperOnline.fetchCount === 1, "a: fetchCount=" + WallpaperOnline.fetchCount);
            root.check(WallpaperOnline.phase === "scheduled", "a: phase=" + WallpaperOnline.phase);
            root.check(WallpaperOnline.lastFailure !== "", "a: no failure recorded");
            // B: nmcli answers "not metered" but the helper hangs: the timeout kills it and the fetch ends.
            WallpaperOnline.meteredCommand = ["/usr/bin/true"];
            WallpaperOnline.fetchCommandOverride = ["/usr/bin/sleep", "30"];
            WallpaperOnline.fetchTimeoutMs = 600;
            WallpaperOnline.tryFetch("2026-01-02");
            second.start();
        }
    }

    Timer {
        id: second
        interval: 3000
        onTriggered: {
            root.check(WallpaperOnline.fetchCount === 2, "b: fetchCount=" + WallpaperOnline.fetchCount);
            root.check(WallpaperOnline.phase === "scheduled", "b: phase=" + WallpaperOnline.phase);
            root.check(WallpaperOnline.lastFailure === "timeout", "b: failure=" + WallpaperOnline.lastFailure);
            // C: nmcli hangs: killed after the timeout, not metered, the fetch runs.
            WallpaperOnline.meteredCommand = ["/usr/bin/sleep", "30"];
            WallpaperOnline.meteredTimeoutMs = 600;
            WallpaperOnline.fetchCommandOverride = ["/nonexistent/helper"];
            WallpaperOnline.tryFetch("2026-01-03");
            third.start();
        }
    }

    Timer {
        id: third
        interval: 3000
        onTriggered: {
            root.check(WallpaperOnline.fetchCount === 3, "c: fetchCount=" + WallpaperOnline.fetchCount);
            root.check(WallpaperOnline.phase === "scheduled", "c: phase=" + WallpaperOnline.phase);
            console.log(root.failure === "" ? "wallpaper-online-start-fail: PASS" : "wallpaper-online-start-fail: FAIL " + root.failure);
            Qt.quit();
        }
    }
}
