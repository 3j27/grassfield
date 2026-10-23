import QtQuick
import Quickshell
import qs.desktop
import qs.services

// The video layer's state machine (WallpaperSlot.qml with WallpaperVideo.qml) on the offscreen platform with a real clip (tests/shell/wallpaper_video_player.sh
// generates it): it starts when the policy says play, pauses at once for pause, eases and pauses for settle, and resumes from every
// one of those, in every order the policy can take. Prints "wallpaper-video-player: PASS" or FAIL <why>.
ShellRoot {
    id: root

    property string failure: ""
    property string log: ""

    function check(cond: bool, what: string): void {
        if (!cond && failure === "")
            failure = what;
    }

    // The slot of the desktop wallpaper with its video layer, as Wallpaper.qml builds it: the poster is the picture, the video is
    // played once the slot is on screen and as the policy says.
    WallpaperSlot {
        id: video
        width: 320
        height: 180
        opacity: 1
        kind: "picture"
        url: "file://" + Quickshell.env("GRASSFIELD_TEST_POSTER")
        video: "file://" + Quickshell.env("GRASSFIELD_TEST_CLIP")
        videoPath: Quickshell.env("GRASSFIELD_TEST_CLIP")
        markerOwner: "T"
        onScreen: true
        playPolicy: root.policy
        readonly property bool playing: video.videoPlaying
    }

    property string policy: "pause"

    // Each step sets the policy, then (later) says what the player must be doing.
    readonly property var steps: [
        {policy: "play", playing: true, what: "first start"},
        {policy: "pause", playing: false, what: "pause (battery, locked, Reduce Motion...)"},
        {policy: "play", playing: true, what: "resume after a pause"},
        {policy: "settle", playing: false, what: "idle: eases down and pauses"},
        {policy: "play", playing: true, what: "resume after settling"},
        {policy: "pause", playing: false, what: "pause again"},
        {policy: "pause", playing: false, what: "pause twice"},
        {policy: "play", playing: true, what: "resume again"},
        {policy: "play", playing: true, what: "play twice"}
    ]
    property int step: -1
    property int waited: 0

    function advance(): void {
        step++;
        waited = 0;
        if (step >= steps.length) {
            console.log(failure === "" ? "wallpaper-video-player: PASS" : "wallpaper-video-player: FAIL " + failure);
            Qt.quit();
            return;
        }
        console.log("wallpaper-video-player: step " + step + " " + steps[step].what);
        policy = steps[step].policy;
    }

    Component.onCompleted: Qt.callLater(advance)

    // Looks twice a second; a step is done when the player is in the wanted state (at most 12 s), then it must STAY there 1 s.
    Timer {
        interval: 500
        repeat: true
        running: true
        property int stable: 0
        onTriggered: {
            if (root.step < 0 || root.step >= root.steps.length)
                return;
            const want = root.steps[root.step].playing;
            if (video.playing === want) {
                stable++;
                if (stable >= 3) {
                    stable = 0;
                    root.advance();
                }
            } else {
                stable = 0;
                root.waited += 500;
                if (root.waited > 12000) {
                    root.check(false, "step " + root.step + " (" + root.steps[root.step].what + "): playing=" + video.playing + ", wanted " + want);
                    root.advance();
                }
            }
        }
    }
}
