pragma ComponentBehavior: Bound
import QtQuick
import QtMultimedia
import Grassfield.Ui
import qs.services

// The video layer of a wallpaper slot (ADR-0016 W7, option V1b). It plays ONLY the H.264 file that grassfield-wallpaper
// transcode wrote (Grassfield's own output at the output's size, at most 30 fps, no audio): no AudioOutput exists here, the
// player loops, and the last frame stays on screen when the video pauses. The poster under it (the slot's Image) shows until the
// first frame, and for as long as the pause policy never lets the video start.
//
// `policy` is the result of WallpaperConfig.playbackState for this output, re-evaluated by its owner on every event (never polled):
//   - "play":   the video plays at full rate;
//   - "settle": the user is idle, so the rate eases to Tokens.wallpaperVideoSettleRate over Tokens.wallpaperVideoSettleMs and then
//               the video pauses (the macOS "settles" feel);
//   - "pause":  locked, a full-screen window, Reduce Motion, the Reduced profile, or battery power without `videoOnBattery`:
//               the player is paused at once. A paused player decodes nothing and keeps its frame.
// Crash safety: before the video first starts, the marker (WallpaperState.markVideoStarting) is written; it is cleared after
// Tokens.wallpaperVideoStableMs of uninterrupted playback, or when the video is deliberately paused or stopped (the shell is then
// plainly alive). A marker found at the next start means the shell died while the video started.
// This item never creates an idle inhibitor: the idle lock still fires while a video plays.
Item {
    id: root

    // file: URL of the transcoded video ("" releases it).
    property url source
    // "fit" or "fill"
    property string fit: "fill"
    // Where the poster frame lies in the video: playback starts there, so that the first frame is the poster.
    property int posterMs: 0
    // "play" | "settle" | "pause" (named `policy`: Item already has a `state`).
    property string policy: "pause"
    // The path the crash marker names (the user's own video).
    property string markerPath: ""

    readonly property bool playing: player.playbackState === MediaPlayer.PlayingState
    // A frame of the video has been shown (the poster is then covered).
    readonly property bool hasFrame: player.playbackState !== MediaPlayer.StoppedState

    signal failed(string message)

    clip: true

    property bool seeked: false

    MediaPlayer {
        id: player
        source: root.source
        loops: MediaPlayer.Infinite
        videoOutput: output
        onMediaStatusChanged: {
            if (mediaStatus === MediaPlayer.LoadedMedia || mediaStatus === MediaPlayer.BufferedMedia) {
                if (!root.seeked && root.posterMs > 0)
                    player.position = root.posterMs;
                root.seeked = true;
                root.sync();
            }
        }
        // qmllint disable signal-handler-parameters
        onErrorOccurred: (error, errorString) => {
            console.warn("wallpaper: the video cannot be played: " + errorString);
            root.failed(errorString);
        }
        // qmllint enable signal-handler-parameters
    }

    VideoOutput {
        id: output
        anchors.fill: parent
        visible: root.hasFrame
        fillMode: root.fit === "fit" ? VideoOutput.PreserveAspectFit : VideoOutput.PreserveAspectCrop
        endOfStreamPolicy: VideoOutput.KeepLastFrame
    }

    onPolicyChanged: sync()
    onSourceChanged: {
        seeked = false;
        settle.stop();
    }

    // The player follows the policy; every change of it, and the media becoming ready, comes here.
    function sync(): void {
        if (root.source.toString() === "")
            return;
        const ready = player.mediaStatus === MediaPlayer.LoadedMedia || player.mediaStatus === MediaPlayer.BufferedMedia || player.mediaStatus === MediaPlayer.StalledMedia || player.mediaStatus === MediaPlayer.EndOfMedia;
        if (root.policy === "play") {
            settle.stop();
            player.playbackRate = 1;
            if (ready && player.playbackState !== MediaPlayer.PlayingState)
                begin();
        } else if (root.policy === "settle") {
            // Idle: ease down and pause. A video that is not playing stays as it is (poster or frozen frame).
            if (player.playbackState === MediaPlayer.PlayingState && !settle.running)
                settle.restart();
        } else {
            settle.stop();
            if (player.playbackState === MediaPlayer.PlayingState)
                player.pause();
            // Paused on purpose, the shell is alive: nothing is starting any more.
            stable.stop();
            WallpaperState.clearVideoStarting();
        }
    }

    function begin(): void {
        // The marker is on disk before the first frame is decoded.
        if (root.markerPath !== "")
            WallpaperState.markVideoStarting(root.markerPath);
        player.play();
        stable.restart();
    }

    // Eases the rate down, then pauses.
    NumberAnimation {
        id: settle
        target: player
        property: "playbackRate"
        to: Tokens.wallpaperVideoSettleRate
        duration: Tokens.wallpaperVideoSettleMs
        onFinished: {
            player.pause();
            stable.stop();
            WallpaperState.clearVideoStarting();
        }
    }

    // Stable playback: the video started without taking the shell down.
    Timer {
        id: stable
        interval: Tokens.wallpaperVideoStableMs
        onTriggered: WallpaperState.clearVideoStarting()
    }

    Component.onDestruction: {
        // Releasing the layer (another wallpaper took over) is a deliberate stop too.
        if (player.playbackState !== MediaPlayer.StoppedState)
            player.stop();
        WallpaperState.clearVideoStarting();
    }
}
