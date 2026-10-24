import QtQuick
import Quickshell
import Quickshell.Io
import qs.desktop
import qs.services

// The block of a video that crashed the shell is for the AUTOMATIC restart only (ADR-0016 section 5): the real WallpaperFeed and the real
// settings store, the state folder seeded with a crash marker for /v/crash.mp4. Steps (the config file is replaced from outside, as
// Settings writes it):
//   1. the shell starts with that video as the wallpaper: the first apply keeps the block;
//   2. the same config applied again (an unrelated setting): the block stays (it is not a new choice);
//   3. another wallpaper (builtin): the user's own choice, the block is lifted;
//   4. the video chosen again after that: it plays (not blocked), and a second crash would block it again (not tested here).
//   5. a second video path chosen: unblocked too, and the first one stays as it was.
// The helper does not exist in this session (the feed ends in "helper-missing"), which is all the test needs: the unblocking happens
// before any job. Prints "wallpaper-video-feed: PASS" or FAIL <why>.
ShellRoot {
    id: root

    property string failure: ""
    readonly property string dir: Quickshell.env("GRASSFIELD_TEST_CONFIGS")

    function check(cond: bool, what: string): void {
        if (!cond && failure === "")
            failure = what;
    }

    Process {
        id: copier
    }

    // Replaces grassfield.json by one of the prepared files.
    function use(name: string): void {
        copier.command = ["cp", "-f", dir + "/" + name + ".json", Quickshell.env("GRASSFIELD_CONFIG_HOME") + "/grassfield.json"];
        copier.running = true;
    }

    WallpaperFeed {
        id: feed
        screenInfo: ({name: "T-1", width: 640, height: 360, devicePixelRatio: 1, model: "", serialNumber: ""})
    }

    readonly property var steps: [
        {what: "start: the block of the crashed video is read", run: () => {}, expect: () => {
                root.check(WallpaperState.isVideoBlocked("/v/crash.mp4"), "start: the marker did not become a block");
                root.check(feed.cfg.source === "video" && feed.cfg.path === "/v/crash.mp4", "start: the feed did not read the video config: " + JSON.stringify(feed.cfg));
                root.check(feed.appliedOnce, "start: the feed has not applied");
            }},
        {what: "the same video, an unrelated setting changed: the block stays", run: () => root.use("same-video-fit"), expect: () => {
                root.check(feed.cfg.fit === "fit" && feed.cfg.source === "video", "same: the config was not read: " + JSON.stringify(feed.cfg));
                root.check(WallpaperState.isVideoBlocked("/v/crash.mp4"), "same: an unrelated setting lifted the block");
            }},
        {what: "another wallpaper: the user's choice lifts the block", run: () => root.use("builtin"), expect: () => {
                root.check(feed.cfg.source === "builtin", "builtin: the config was not read: " + JSON.stringify(feed.cfg));
                root.check(!WallpaperState.isVideoBlocked("/v/crash.mp4"), "builtin: the block stayed after another wallpaper was chosen");
            }},
        {what: "the video chosen again: not blocked", run: () => root.use("crash-video"), expect: () => {
                root.check(feed.cfg.source === "video" && feed.cfg.path === "/v/crash.mp4", "again: the config was not read");
                root.check(!WallpaperState.isVideoBlocked("/v/crash.mp4"), "again: the video chosen again is blocked");
            }},
        {what: "block it again by hand, then choose another video: leaving the first lifts its block", run: () => {
                WallpaperState.videoBlockedPaths = ["/v/crash.mp4"];
                root.use("other-video");
            }, expect: () => {
                root.check(feed.cfg.path === "/v/other.mp4", "other: the config was not read: " + JSON.stringify(feed.cfg));
                // Leaving /v/crash.mp4 for another video is a choice too: that block is lifted, and the new one was never blocked.
                root.check(!WallpaperState.isVideoBlocked("/v/crash.mp4"), "other: leaving the video did not lift its block");
                root.check(!WallpaperState.isVideoBlocked("/v/other.mp4"), "other: the new video is blocked");
            }}
    ]
    property int step: -1

    function advance(): void {
        if (step >= 0)
            steps[step].expect();
        step++;
        if (step >= steps.length) {
            console.log(failure === "" ? "wallpaper-video-feed: PASS" : "wallpaper-video-feed: FAIL " + failure);
            Qt.quit();
            return;
        }
        console.log("wallpaper-video-feed: step " + step + " " + steps[step].what);
        steps[step].run();
    }

    // A step gets 2.5 s: the file is replaced, watched, read, the feed's debounce (250 ms) runs, the feed applies.
    Timer {
        id: tick
        interval: 2500
        repeat: true
        running: false
        onTriggered: root.advance()
    }

    // The first step needs the state read and the feed applied.
    Timer {
        interval: 1500
        running: true
        onTriggered: {
            root.advance();
            tick.start();
        }
    }
}
