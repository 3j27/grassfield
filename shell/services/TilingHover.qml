pragma Singleton
import QtQuick
import Quickshell
import Grassfield.Ui
import qs.platform
import "../platform/WindowTiling.js" as WindowTiling

// Opens the tiling popover (docs/specs/tiling.md TL22, TL26, TL34): the plugin's tile-hover event (Compositor.tileHover)
// opens popup kind "tiling" under the window's zoom light, the light tiling.popoverLightInset in from its left edge (macOS 27),
// or above it when the output has no room below; the overlay keeps it on the output. "enter"
// (the pointer rested on the light) does not take the place of another open popup; "open" (Super+Ctrl+L) does. "leave" is
// left to the popover, which closes on its own rules (overlay/TilingPopover.qml). It closes here when its window closes and
// when the plugin stops advertising the feature. Nothing opens over the lock (refused first, and by Popups.open), the polkit
// sheet, a full-attention surface or the Dock's keyboard mode (WindowTiling.hoverRefusedBy; the plugin also posts no hover
// while the lock or another Exclusive layer is up or a layer covers the light).
Singleton {
    id: root

    // The window of the open popover ("" when none is open).
    readonly property string address: Popups.kind === "tiling" && Popups.data.address !== undefined ? Popups.data.address : ""
    // The Dock holds the keyboard (its keyboard mode; bound in shell.qml: the Dock is a feature module).
    property bool dockKeyboard: false

    function refusedBy(): string {
        return WindowTiling.hoverRefusedBy({
            locked: SessionState.locked,
            authorizing: SessionState.authorizing,
            holders: Object.keys(FocusReturn.holders),
            dockKeyboard: root.dockKeyboard
        });
    }

    // What happened, for the lock-surfaces harness (it runs without the plugin): "opened", or why not: "lock", "leave", "off"
    // (a hover while "Show layouts when hovering over the green button" is off),
    // "busy" (another popup is open, or this window's), what refuses it (WindowTiling.hoverRefusedBy), "unavailable" (no
    // plugin feature) or "no window". The refusals and the closing of another window's popover come before the plugin's checks.
    function show(hover: var): string {
        if (SessionState.refuses("tiling popover"))
            return "lock";
        if (hover.state === "leave")
            return "leave";
        if (hover.state === "enter" && !Settings.windowsTilingLayouts)
            return "off"; // "Show layouts when hovering over the green button" off (TL32): Super+Ctrl+L and the Window menu still open it
        if (hover.state === "enter" && Popups.active && (Popups.kind !== "tiling" || root.address === hover.address))
            return "busy";
        const refused = root.refusedBy();
        if (refused !== "") {
            console.info("grassfield: tiling popover refused: " + refused + " is open");
            return refused;
        }
        // Another window's popover closes first: the open one never sees its window change under it (its full-screen watch
        // would close the new one, which then opened with no window; integrator review of 4ead6fb).
        if (root.address !== "" && root.address !== hover.address)
            Popups.close();
        if (!Compositor.canTileHover)
            return "unavailable";
        const toplevel = Compositor.toplevelByAddress(hover.address);
        const anchor = toplevel ? Compositor.popoverAnchor(hover.light) : null;
        if (!anchor)
            return "no window";
        Popups.open("tiling", anchor.screen, anchor.x - Tokens.tilingPopoverLightInset, anchor.y, "below", {
            address: hover.address,
            tileable: hover.tileable,
            hover: hover.state === "enter",
            light: anchor.light,
            flipY: anchor.flipY
        });
        return "opened";
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
