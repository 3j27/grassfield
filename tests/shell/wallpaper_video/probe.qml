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
        check(WallpaperState.isVideoBlocked("/v/crash.mp4") && WallpaperState.videoBlockedPaths.length === 1, "marker not turned into a block: " + JSON.stringify(WallpaperState.videoBlockedPaths));
        const s = JSON.parse(stateText());
        check(s.videoStarting === undefined, "the marker stayed in the file");
        check(JSON.stringify(s.videoBlocked) === JSON.stringify(["/v/crash.mp4"]), "the block is not remembered in the file");
        check(WallpaperState.isVideoBlocked("/v/crash.mp4"), "policy: crash.mp4 must be blocked");
        check(!WallpaperState.isVideoBlocked("/v/other.mp4"), "policy: other.mp4 must be free");
        // Two outputs start two videos: both markers go to disk at once, each owned by its output.
        WallpaperState.markVideoStarting("A", "/v/new.mp4");
        WallpaperState.markVideoStarting("B", "/v/second.mp4");
        WallpaperState.markVideoStarting("A", "/v/new.mp4");
    }

    function step2(): void {
        const s = JSON.parse(stateText());
        const paths = (s.videoStarting || []).map(m => m.path).sort();
        check(JSON.stringify(paths) === JSON.stringify(["/v/new.mp4", "/v/second.mp4"]), "markers not written: " + JSON.stringify(paths));
        // One output's pause clears its own marker only, and only when it still names the same video (the old slot of an output
        // pausing after the new one wrote its marker must not clear it).
        WallpaperState.clearVideoStarting("B", "/v/old.mp4");
        WallpaperState.clearVideoStarting("A", "/v/new.mp4");
        WallpaperState.clearVideoStarting("A", "/v/new.mp4");
    }

    function step3(): void {
        const s = JSON.parse(stateText());
        check(s.videoStarting && s.videoStarting.length === 1 && s.videoStarting[0].path === "/v/second.mp4", "A's pause touched B's marker: " + JSON.stringify(s.videoStarting));
        WallpaperState.clearVideoStarting("B", "/v/second.mp4");
        check(JSON.stringify(s.videoBlocked) === JSON.stringify(["/v/crash.mp4"]), "clearing a marker lost the block");
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
        check(WallpaperState.isVideoBlocked("/v/crash.mp4"), "released while an output still shows it");
        WallpaperState.report("A", {state: "ready", file: "", source: "builtin", path: ""});
        WallpaperState.releaseVideo();
        check(!WallpaperState.isVideoBlocked("/v/crash.mp4"), "not released");
    }

    function step4(): void {
        const s = JSON.parse(stateText());
        check(s.videoStarting === undefined, "the markers are not all cleared");
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
