pragma Singleton
import QtQuick
import Quickshell
import Grassfield.Ui
import qs.platform

// Opens the tiling popover (docs/specs/tiling.md TL22, TL26, TL34): the plugin's tile-hover event (Compositor.tileHover)
// opens popup kind "tiling" under the window's zoom light, the light tiling.popoverLightInset in from its left edge (macOS 27),
// or above it when the output has no room below; the overlay keeps it on the output. "enter"
// (the pointer rested on the light) does not take the place of another open popup; "open" (Super+Ctrl+L) does. "leave" is
// left to the popover, which closes on its own rules (overlay/TilingPopover.qml). It closes here when its window closes and
// when the plugin stops advertising the feature. Nothing opens over the lock: Popups.open refuses it first.
Singleton {
    id: root

    // The window of the open popover ("" when none is open).
    readonly property string address: Popups.kind === "tiling" && Popups.data.address !== undefined ? Popups.data.address : ""

    function show(hover: var): void {
        if (hover.state === "leave" || !Compositor.canTileHover)
            return;
        if (hover.state === "enter" && Popups.active && (Popups.kind !== "tiling" || root.address === hover.address))
            return;
        const toplevel = Compositor.toplevelByAddress(hover.address);
        const anchor = toplevel ? Compositor.popoverAnchor(hover.light) : null;
        if (!anchor)
            return;
        Popups.open("tiling", anchor.screen, anchor.x - Tokens.tilingPopoverLightInset, anchor.y, "below", {
            address: hover.address,
            tileable: hover.tileable,
            hover: hover.state === "enter",
            light: anchor.light,
            flipY: anchor.flipY
        });
    }

    Connections {
        target: Compositor

        function onTileHover(hover: var): void {
            root.show(hover);
        }

        function onWindowClosed(address: string): void {
            if (address === root.address)
                Popups.close();
        }

        function onCanTileHoverChanged(): void {
            if (!Compositor.canTileHover && root.address !== "")
                Popups.close();
        }
    }
}
