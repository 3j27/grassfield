import QtQuick
import Quickshell
import Grassfield.Ui
import qs.services

// The video wallpaper's state rules (ADR-0016 W7, run by tests/shell/wallpaper_video.sh with a state folder that holds a crash
// marker for /v/crash.mp4): the marker found at start blocks that video and is removed from the file; the marker of a video that
// starts is on disk at once and gone when it is cleared; lockStill answers the poster of a ready video and nothing outside the
// cache; a blocked video is released only when no output shows it. Prints "wallpaper-video: PASS" or FAIL <why>.
ShellRoot {
    id: root

    property string failure: ""

    function check(cond: bool, what: string): void {
        if (!cond && failure === "")
            failure = what;
    }

    function stateText(): string {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", "file://" + WallpaperState.stateFile, false);
        xhr.send();
        return xhr.responseText;
    }

    // Writes are asynchronous: each step waits for the previous write to land.
    property int step: 0
    readonly property var steps: [step1, step2, step3, step4, step5]

    function step1(): void {
        if (!WallpaperState.stateReady) {
            step = 0; // not read yet: try again at the next tick
            return;
        }
        check(WallpaperState.videoBlocked === "/v/crash.mp4", "marker not turned into a block: " + WallpaperState.videoBlocked);
        const s = JSON.parse(stateText());
        check(s.videoStarting === undefined, "the marker stayed in the file");
        check(s.videoBlocked === "/v/crash.mp4", "the block is not remembered in the file");
        check(WallpaperConfig.videoBlocked(WallpaperState.videoBlocked, "/v/crash.mp4"), "policy: crash.mp4 must be blocked");
        check(!WallpaperConfig.videoBlocked(WallpaperState.videoBlocked, "/v/other.mp4"), "policy: other.mp4 must be free");
        // A video that starts: its marker goes to disk at once.
        WallpaperState.markVideoStarting("/v/new.mp4");
    }

    function step2(): void {
        const s = JSON.parse(stateText());
        check(s.videoStarting && s.videoStarting.path === "/v/new.mp4", "marker not written");
        WallpaperState.clearVideoStarting();
    }

    function step3(): void {
        const s = JSON.parse(stateText());
        check(s.videoStarting === undefined, "marker not cleared");
        check(s.videoBlocked === "/v/crash.mp4", "clearing the marker lost the block");
        // The lock's still.
        const v = WallpaperState.videoDir;
        const p = WallpaperState.preparedDir;
        WallpaperState.report("A", {state: "ready", file: v + "/0123.jpg", source: "video", path: "/v/crash.mp4", video: v + "/0123.mp4", progress: -1});
        WallpaperState.report("B", {state: "ready", file: p + "/4567.jpg", source: "file", path: "/p/x.jpg"});
        WallpaperState.report("C", {state: "ready", file: "/etc/passwd"});
        WallpaperState.report("D", {state: "preparing", file: p + "/4567.jpg"});
        WallpaperState.report("E", {state: "ready", file: p + "/../../../etc/passwd"});
        WallpaperState.report("F", {state: "ready", file: ""});
        check(WallpaperState.lockStill("A") === v + "/0123.jpg", "the poster of a ready video: " + WallpaperState.lockStill("A"));
        check(WallpaperState.lockStill("B") === p + "/4567.jpg", "the prepared picture");
        for (const o of ["C", "D", "E", "F", "none"])
            check(WallpaperState.lockStill(o) === "", "lockStill(" + o + ") must be empty: " + WallpaperState.lockStill(o));
        const keep = WallpaperState.currentVideoFiles();
        check(keep.indexOf(v + "/0123.mp4") >= 0 && keep.indexOf(v + "/0123.jpg") >= 0, "the video and its poster are kept: " + JSON.stringify(keep));
        // Still the wallpaper of output A: not released. Another wallpaper there: released.
        WallpaperState.releaseVideo();
        check(WallpaperState.videoBlocked === "/v/crash.mp4", "released while an output still shows it");
        WallpaperState.report("A", {state: "ready", file: "", source: "builtin", path: ""});
        WallpaperState.releaseVideo();
        check(WallpaperState.videoBlocked === "", "not released");
    }

    function step4(): void {
        const s = JSON.parse(stateText());
        check(s.videoBlocked === undefined, "the release is not in the file");
    }

    function step5(): void {
        console.log(failure === "" ? "wallpaper-video: PASS" : "wallpaper-video: FAIL " + failure);
        Qt.quit();
    }

    Timer {
        interval: 1200
        repeat: true
        running: true
        onTriggered: {
            if (root.step < root.steps.length)
                root.steps[root.step++]();
        }
    }
}
