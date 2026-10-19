pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Services.Mpris

// Active MPRIS player: the first one that is playing, else the first one. null when none runs.
Singleton {
    id: root

    readonly property var players: Mpris.players ? Mpris.players.values : []
    readonly property var player: {
        for (let i = 0; i < players.length; i++) {
            if (players[i].isPlaying)
                return players[i];
        }
        return players.length > 0 ? players[0] : null;
    }
    // No player in the visual-test fixture (GRASSFIELD_DEV and GRASSFIELD_VISUAL_FIXTURES).
    readonly property bool available: !VisualFixtures.active && player !== null
    readonly property string title: available ? player.trackTitle : ""
    readonly property string artist: available ? player.trackArtist : ""
    readonly property string artUrl: available ? player.trackArtUrl : ""
    readonly property bool playing: available && player.isPlaying

    // A GRASSFIELD_DEV session runs on the owner's machine: the transport never drives the real player there.
    readonly property bool devSession: Quickshell.env("GRASSFIELD_DEV") === "1"

    function devGuarded(what: string): bool {
        if (devSession)
            console.info("dev guard: media " + what + " suppressed");
        return devSession;
    }

    function togglePlaying(): void {
        if (devGuarded("toggle"))
            return;
        if (available && player.canTogglePlaying)
            player.togglePlaying();
    }

    function next(): void {
        if (devGuarded("next"))
            return;
        if (available && player.canGoNext)
            player.next();
    }

    function previous(): void {
        if (devGuarded("previous"))
            return;
        if (available && player.canGoPrevious)
            player.previous();
    }
}
