pragma Singleton
import QtQuick
import Quickshell
import qs.platform

// Shows the tiling suggestions (docs/specs/tiling.md TL28): popup kind "tilingSuggest" over the first empty zone of the layout
// the window that asked is filling, offering the windows that can take it (platform/TilingLink's suggestion; live thumbnails
// in overlay/TilingSuggestions). A pick places that window there (Compositor.pickSuggestion) and the next empty zone follows
// with the plugin's next suggestion; Esc or a click outside ends it. Nothing opens over the lock (refused first, and by
// Popups.open), the polkit sheet, a full-attention surface or the Dock's keyboard mode (TilingHover.refusedBy), nor in place
// of another popup than the tiling popover or the suggestions themselves; it closes when the suggestion ends (another change
// of the tiles, the plugin gone).
Singleton {
    id: root

    readonly property bool shown: Popups.kind === "tilingSuggest"

    // What happened, for the lock-surfaces harness (it runs without the plugin): "opened", or why not: "lock", "none" (no
    // suggestion: an open one closes), "busy" (another popup is open), what refuses it (WindowTiling.hoverRefusedBy through
    // TilingHover.refusedBy) or "no output". The lock is refused first.
    function show(suggestion: var): string {
        if (SessionState.refuses("tiling suggestions"))
            return "lock";
        if (!suggestion) {
            if (root.shown)
                Popups.close();
            return "none";
        }
        if (Popups.active && Popups.kind !== "tiling" && Popups.kind !== "tilingSuggest")
            return "busy";
        const refused = TilingHover.refusedBy();
        if (refused !== "") {
            console.info("grassfield: tiling suggestions refused: " + refused + " is open");
            return refused;
        }
        const screen = Quickshell.screens.find(s => s.name === suggestion.output);
        if (!screen)
            return "no output";
        const zone = suggestion.zones[0];
        Popups.open("tilingSuggest", screen.name, zone.x - screen.x, zone.y - screen.y, "zone", {
            suggestion: suggestion,
            width: zone.w,
            height: zone.h
        });
        return "opened";
    }

    // The window `address` into the zone the suggestions show (the first empty one). False when nothing was sent.
    function pick(address: string): bool {
        const sg = root.shown ? Popups.data.suggestion : null;
        return sg ? Compositor.pickSuggestion(address, sg.layout, sg.zones[0].zone, sg.address) : false;
    }

    // Esc, or a click outside: the suggestions end for that arrangement.
    function dismiss(): void {
        TilingLink.dismiss();
        if (root.shown)
            Popups.close();
    }

    Connections {
        target: TilingLink

        function onSuggestionChanged(): void {
            if (TilingLink.suggestion !== null || root.shown)
                root.show(TilingLink.suggestion);
        }
    }

    // The popup closed another way (a click outside, the lock, another popup in its place): nothing more is suggested.
    Connections {
        target: Popups

        function onKindChanged(): void {
            if (Popups.kind !== "tilingSuggest" && TilingLink.suggestion !== null)
                TilingLink.dismiss();
        }
    }
}
