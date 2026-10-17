pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.services
import "KeyboardFocus.js" as Focus

// Desktop icons (docs/specs/desktop.md): their own layer surface (namespace grassfield-desktop-icons)
// on the Background layer of the primary screen, mapped after the wallpaper so it sits above it and
// below the Bottom-layer widgets surface (which is never touched from here). The surface takes the
// whole screen so that a click on empty desktop can start a rubber band and focus the desktop; the
// widgets live in a higher layer and keep their own input. Nothing animates or repaints on a timer.
// Primary screen: the first one, or the output named by GRASSFIELD_DESKTOP_SCREEN (dev only).
Variants {
    model: Quickshell.screens.filter(s => s.name === (Quickshell.env("GRASSFIELD_DESKTOP_SCREEN") || Quickshell.screens[0].name))

    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        required property ShellScreen modelData

        // Keyboard safe mode (KeyboardFocus.js, docs/specs/desktop.md): this surface is None, except
        // Exclusive while a rename field is active. The context menu has its own window (Exclusive while
        // open). Nothing here re-takes the keyboard: after a menu or a rename it is whatever Hyprland decides.
        property var kb: Focus.initial()
        // Frames swapped since the hand-off phase started (the surface commit goes out within two).
        property int handoffFrames: 0
        // The surface has the keyboard (wl_keyboard enter).
        readonly property bool hasKeys: view.Window.active

        function feed(event: var): void {
            win.kb = Focus.next(win.kb, event);
        }

        // Layer state reaches the compositor with the next surface commit: render one now, so a
        // change never waits for an unrelated repaint.
        function commitSoon(): void {
            const w = view.Window.window;
            if (w)
                w.update();
        }

        screen: modelData
        visible: Settings.desktopShowIcons
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Background
        WlrLayershell.keyboardFocus: Focus.interactivity(win.kb) === "exclusive" ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-desktop-icons"

        onKbChanged: {
            win.handoffFrames = 0;
            win.commitSoon();
        }
        onHasKeysChanged: win.feed({
            type: "keys",
            hasKeys: win.hasKeys
        })
        onVisibleChanged: win.kb = Focus.initial()

        // The hand-off menu -> rename ends by frames, even if the keyboard never arrives (e.g. a locked
        // session): first the Exclusive commit of this surface goes out (the menu window then lets go),
        // then the menu window unmaps once this surface had the time to receive the keyboard.
        Connections {
            target: win.kb.handoff !== "" ? view.Window.window : null

            function onFrameSwapped(): void {
                win.handoffFrames++;
                if (win.handoffFrames >= 2)
                    win.feed({
                        type: win.kb.handoff === "commit" ? "committed" : "settled"
                    });
                else
                    win.commitSoon();
            }
        }

        IconsView {
            id: view
            anchors.fill: parent
            screen: win.modelData
            kbMenuMapped: Focus.menuMapped(win.kb)
            kbMenuHoldsKeys: Focus.menuHoldsKeys(win.kb)
            onFocusEvent: event => win.feed(event)
        }

        Item {
            anchors.fill: parent

            // The wallpaper below no longer sees the pointer: report it for the hot corner re-arm.
            HoverHandler {
                id: hover
                onPointChanged: if (hovered)
                    PointerTracker.report(win.modelData.name, point.position.x, point.position.y)
            }
        }
    }
}
