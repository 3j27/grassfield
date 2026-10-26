pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import qs.lib
import Quickshell.Services.Mpris
import Grassfield.Ui
import qs.platform
import "../widgets/ArtUrl.js" as ArtUrl // layering-exception: GF-087
import "MediaLogic.js" as Logic

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
    // test player the test starts there (Mode.ownBus: not dev, or dev on a private bus).
    // No player in the visual-test fixture (GRASSFIELD_DEV and GRASSFIELD_VISUAL_FIXTURES), unless the bus is private.
    readonly property bool available: (!VisualFixtures.active || Mode.ownBus) && player !== null
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
    readonly property bool devSession: !Mode.ownBus

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

    // macOS: a click on the Now Playing artwork or title opens the app that plays (MediaLogic.openPlan: the player's
    // Raise() when it can, the app's window when it is minimized or Raise() is missing, else the desktop entry).
    // `fromOverlay`: the click came from a panel of the overlay window, which holds the keyboard exclusively until it is
    // gone; Hyprland refuses to focus a window meanwhile, so the focus waits for `closelayer` of `grassfield-overlay`
    // (the Dock menu's mechanism, Compositor.layerClosed, at most Tokens.dockMenuLayerWait ms).
    function openPlayerApp(fromOverlay: bool): void {
        if (!available || SessionState.locked)
            return;
        const id = Logic.appIdOf(player.desktopEntry);
        const entry = Apps.lookup(id !== "" ? id : player.identity);
        // The windows the Dock groups under this entry (the same lookup: StartupWMClass and Flatpak ids included).
        const all = Compositor.toplevels ? Compositor.toplevels.values : [];
        const wins = entry ? all.filter(t => {
            const e = Apps.lookup(t.appId);
            return e && e.id === entry.id;
        }) : (id !== "" ? Compositor.toplevelsFor(id) : []);
        const plan = Logic.openPlan(player.canRaise, entry !== null && entry !== undefined, wins.map(t => ({minimized: Compositor.isMinimized(t)})));
        const run = () => {
            if (plan === "raise") {
                if (!devGuarded("raise"))
                    player.raise();
            } else if (plan === "activate") {
                Compositor.activate(Compositor.mostRecent(wins));
            } else if (plan === "launch") {
                Apps.launch(entry);
            }
        };
        if (Logic.skipsFocusReturn(fromOverlay, plan))
            FocusReturn.skip();
        if (fromOverlay === true && (plan === "raise" || plan === "activate")) {
            deferred = run;
            layerWait.restart();
        } else {
            run();
        }
    }

    property var deferred: null

    function runDeferred(): void {
        const f = deferred;
        deferred = null;
        layerWait.stop();
        // A session that locked meanwhile is never acted on.
        if (f && !SessionState.locked)
            f();
    }

    Timer {
        id: layerWait
        interval: Tokens.dockMenuLayerWait
        onTriggered: root.runDeferred()
    }

    Connections {
        target: SessionState

        function onLockedChanged(): void {
            if (SessionState.locked) {
                root.deferred = null;
                layerWait.stop();
            }
        }
    }

    Connections {
        target: Compositor

        function onLayerClosed(namespace: string): void {
            if (root.deferred && namespace === "grassfield-overlay")
                root.runDeferred();
        }
    }
}
