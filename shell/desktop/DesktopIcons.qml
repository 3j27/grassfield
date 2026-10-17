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
        // Click catchers (below) that have rendered and are therefore mapped. Hyprland gives the keyboard
        // to the Exclusive surface that committed last: the menu / rename surface commits Exclusive only
        // once every catcher is up (catchGate), so a catcher never takes the keyboard from it.
        readonly property var catcherScreens: Quickshell.screens.filter(s => s.name !== win.modelData.name)
        property int catchersUp: 0
        // Catchers that have the keyboard (the pointer is on their output), by screen name.
        property var catchersWithKeys: ({})
        readonly property bool catcherHasKeys: Object.keys(win.catchersWithKeys).length > 0

        function setCatcherKeys(name: string, has: bool): void {
            const next = Object.assign({}, win.catchersWithKeys);
            if (has)
                next[name] = true;
            else
                delete next[name];
            win.catchersWithKeys = next;
        }
        readonly property bool catchGate: !Focus.catchersMapped(win.kb) || win.catchersUp >= win.catcherScreens.length
        // The surface has the keyboard (wl_keyboard enter).
        readonly property bool hasKeys: view.Window.active

        // Release phase: when the state goes back to idle the catchers unmap FIRST, the menu / rename surface
        // lets go of the keyboard two frames later. Hyprland then has no Exclusive surface left to hand the
        // keyboard to and falls back to its last window, as without catchers (the other order leaves the
        // keyboard on nobody). `pendingKb` is the state to apply when the release is over.
        property bool catchReleasing: false
        property int releaseFrames: 0
        property var pendingKb: Focus.initial()

        function feed(event: var): void {
            const cur = win.catchReleasing ? win.pendingKb : win.kb;
            const n = Focus.next(cur, event);
            if (win.catchReleasing) {
                win.pendingKb = n;
                if (Focus.catchersMapped(n)) {
                    for (const step of Focus.releaseEnd(n)) {
                        win.kb = step.kb;
                        win.catchReleasing = step.releasing;
                    }
                }
                return;
            }
            if (Focus.catchersMapped(win.kb) && !Focus.catchersMapped(n) && win.catcherScreens.length > 0) {
                win.pendingKb = n;
                win.releaseFrames = 0;
                win.catchReleasing = true;
                win.commitSoon();
                return;
            }
            win.kb = n;
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
        WlrLayershell.keyboardFocus: Focus.interactivity(win.kb) === "exclusive" && win.catchGate ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-desktop-icons"

        onKbChanged: {
            win.handoffFrames = 0;
            if (!Focus.catchersMapped(win.kb))
                win.catchersUp = 0;
            win.commitSoon();
        }
        onCatchGateChanged: win.commitSoon()

        // End of the release phase: two frames after the catchers unmapped.
        Connections {
            target: win.catchReleasing ? view.Window.window : null

            function onFrameSwapped(): void {
                win.releaseFrames++;
                if (win.releaseFrames >= 2) {
                    // Atomic end (KeyboardFocus.releaseEnd): the final state first, then the flag.
                    for (const step of Focus.releaseEnd(win.pendingKb)) {
                        win.kb = step.kb;
                        win.catchReleasing = step.releasing;
                    }
                } else {
                    win.commitSoon();
                }
            }
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

        // Click catchers: while a menu or a rename is active, a transparent full-screen Overlay surface is
        // mapped on every other screen. Hyprland routes the pointer on an output to an Exclusive layer
        // surface of that output only; with the menu / rename Exclusive on the hosting output, nothing on
        // another output would receive a click (and typing would still reach the menu / rename). So the
        // catcher is itself Exclusive: a press on it cancels the menu / rename (never commits, renames
        // or trashes) and the keyboard is released. Hyprland gives the keyboard to the Exclusive surface
        // of the output the pointer is on, so while the pointer is on another output the catcher swallows
        // typing (Esc cancels, nothing else does anything) and the menu / rename get it back as soon as the
        // pointer returns. The catchers unmap when the state is idle again. The click is consumed, like a
        // click outside on this output. No pointer polling.
        Variants {
            model: Focus.catchersShown(win.kb, win.catchReleasing) ? win.catcherScreens : []

            // qmllint disable uncreatable-type
            PanelWindow {
                // qmllint enable uncreatable-type
                id: catcher

                required property ShellScreen modelData

                // Two frames swapped: the surface is mapped (Exclusive) and committed.
                property int frames: 0

                screen: catcher.modelData
                anchors {
                    top: true
                    bottom: true
                    left: true
                    right: true
                }
                exclusionMode: ExclusionMode.Ignore
                color: "transparent"
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
                WlrLayershell.namespace: "grassfield-desktop-catcher"

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                    onPressed: view.cancelInteraction()
                }

                Connections {
                    target: catcher.frames < 2 ? catcherKeys.Window.window : null

                    function onFrameSwapped(): void {
                        catcher.frames++;
                        if (catcher.frames >= 2)
                            win.catchersUp++;
                        else
                            catcherKeys.Window.window.update();
                    }
                }

                Item {
                    id: catcherKeys

                    readonly property bool hasKeys: Window.active

                    focus: true
                    Accessible.ignored: true
                    onHasKeysChanged: win.setCatcherKeys(catcher.modelData.name, hasKeys)
                    Component.onDestruction: win.setCatcherKeys(catcher.modelData.name, false)
                    // Every key is swallowed: nothing typed here may reach the menu or the rename.
                    Keys.onPressed: event => {
                        event.accepted = true;
                        if (event.key === Qt.Key_Escape)
                            view.cancelInteraction();
                    }
                }
            }
        }

        IconsView {
            id: view
            anchors.fill: parent
            screen: win.modelData
            kbMenuMapped: Focus.menuMapped(win.kb)
            kbMenuHoldsKeys: Focus.menuHoldsKeys(win.kb)
            kbGate: win.catchGate
            kbCatcherHasKeys: win.catcherHasKeys
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
