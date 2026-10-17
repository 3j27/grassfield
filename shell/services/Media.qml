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

    function togglePlaying(): void {
        if (available && player.canTogglePlaying)
            player.togglePlaying();
    }

    function next(): void {
        if (available && player.canGoNext)
            player.next();
    }

    function previous(): void {
        if (available && player.canGoPrevious)
            player.previous();
    }
}
