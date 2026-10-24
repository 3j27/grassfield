pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import "../widgets/ArtUrl.js" as ArtUrl // layering-exception: GF-087

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
    // The nested dev session runs on its own bus (GRASSFIELD_PRIVATE_BUS=1): the owner's players are not on it, only a
    // test player the test starts there.
    readonly property bool privateBus: Quickshell.env("GRASSFIELD_PRIVATE_BUS") === "1"
    // No player in the visual-test fixture (GRASSFIELD_DEV and GRASSFIELD_VISUAL_FIXTURES), unless the bus is private.
    readonly property bool available: (!VisualFixtures.active || privateBus) && player !== null
    readonly property string title: available ? player.trackTitle : ""
    readonly property string artist: available ? player.trackArtist : ""
    readonly property string artUrl: available ? player.trackArtUrl : ""
    // The art URL the views show (ThemeIcons.artSource: a PNG the shell made from the file or the https resource),
    // artDebounceMs after the player last changed it: skipping through tracks fetches only where it stops.
    property string artShown: ""
    readonly property int artDebounceMs: 300
    readonly property bool playing: available && player.isPlaying

    // A GRASSFIELD_DEV session runs on the owner's machine: the transport never drives the real player there. On the
    // private bus only a test player can answer, so the transport is live there.
    readonly property bool devSession: Quickshell.env("GRASSFIELD_DEV") === "1" && !privateBus

    onArtUrlChanged: artDebounce.restart()
    // A player may reuse its art file for the next track: the PNG the shell shows is made again (the current one shows
    // until then). An https URL names its resource: one copy per URL.
    onArtShownChanged: ThemeIcons.refreshFile(ArtUrl.localPath(artShown))
    onTitleChanged: ThemeIcons.refreshFile(ArtUrl.localPath(artShown))

    Timer {
        id: artDebounce
        interval: root.artDebounceMs
        onTriggered: root.artShown = root.artUrl
    }

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
