pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.lib
import Quickshell.Wayland
import Grassfield.Ui
import qs.platform
import qs.services
import "KeyboardFocus.js" as Focus
import "DesktopSurfaces.js" as Surfaces

// Desktop icons (docs/specs/desktop.md): a layer surface (namespace grassfield-desktop-icons) on the Background layer of
// EVERY screen, above that screen's wallpaper (the layer rule gf-desktop-icons-order in config/hypr/grassfield/windows.lua
// puts it there whatever the mapping order, so also for a display plugged in later) and below the Bottom-layer widgets
// surface (which is never touched from here). The surface takes the whole screen so that a click on empty desktop can
// start a rubber band, focus the desktop and open the desktop menu; the widgets live in a higher layer and keep their own
// input. Nothing animates or repaints on a timer.
// The icons are on one screen (DesktopSurfaces.iconsScreen: the main display, MainDisplay.screenName, ADR-0044; the dev
// override GRASSFIELD_DESKTOP_SCREEN is read there, once), with Show Desktop Items on; the other screens carry the bare-desktop menu only. The surfaces share one
// DesktopFiles: the folder, the slots and the file operations are that screen's.
//
// Keyboard focus (ADR-0012, KeyboardFocus.js): the desktop is click-to-focus. Keyboard interactivity is None
// until a press on the desktop, then OnDemand; it goes back to None when the pointer leaves the surface or the
// keyboard is not granted. Hyprland decides who holds the keyboard; nothing here guesses.
// With the compositor capability "desktop-focus-v2" the plugin gives the keyboard to the clicked window or desktop: the
// kicker and the drop on pointer leave go away and the desktop keeps the keyboard until another click (macOS Finder);
// the file keys are enabled. Live: the capability can be withdrawn (plugin unload) at any time.
Scope {
    id: scope

    // The one place that decides which screen shows the icons.
    readonly property string primaryName: !MainDisplay.ready ? "" : Surfaces.iconsScreen(MainDisplay.screenName, Quickshell.screens.map(s => s.name))

    DesktopFiles {
        id: desktopFiles
    }

    Variants {
        model: Quickshell.screens

        // qmllint disable uncreatable-type
        PanelWindow {
            // qmllint enable uncreatable-type
            id: win

            required property ShellScreen modelData
            // The icons are on this screen (modelData is null while a removed output destroys the window).
            readonly property bool iconsHere: Surfaces.iconsHere(modelData ? modelData.name : "", scope.primaryName, Settings.desktopShowIcons)
            // This display's key for DesktopState.hold, taken once.
            property string holdKey: ""

            property var kb: Focus.initial()
            // The compositor enforces click-to-focus. Requires "desktop-focus-v2": the first policy ("desktop-focus") misreads a
            // click with a perfectly still pointer right after the desktop menu closes, which left file keys acting on the
            // desktop (review of 9e76bd7). Until the plugin advertises v2 the shell keeps its safe mode (file keys off).
            readonly property bool policy: Capabilities.has("desktop-focus-v2")
            // The transient kicker surface is mapped (two phases: mapped, unmapped).
            property bool kickOn: false
            // The surface has the keyboard (wl_keyboard enter): the window is active. activeFocus is not enough, forceActiveFocus sets it on an inactive window.
            readonly property bool hasKeys: view.Window.active

            function feed(event: var): void {
                win.kb = Focus.next(win.kb, event, win.policy);
                if (Focus.rearmAfter(event, win.policy))
                    rearmTimer.restart();
            }

            screen: modelData
            visible: true
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.keyboardFocus: Focus.interactivity(win.kb) === "ondemand" ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
            WlrLayershell.namespace: "grassfield-desktop-icons"

            onHasKeysChanged: {
                win.feed({
                    type: "keys",
                    hasKeys: win.hasKeys
                });
            }
            onVisibleChanged: win.kb = Focus.initial()

            // The menu bar shows the desktop's name while the desktop (or its context menu) holds the keyboard.
            readonly property bool holding: win.visible && (win.hasKeys || win.kb.mode === "menu")
            onHoldingChanged: DesktopState.hold(win.holdKey, win.holding)
            Component.onCompleted: {
                win.holdKey = win.modelData ? win.modelData.name : "";
                DesktopState.hold(win.holdKey, win.holding);
            }
            // The output went away while this desktop held the keyboard: its share of the flag goes with it.
            Component.onDestruction: DesktopState.hold(win.holdKey, false)

            // Show Desktop (Compositor.showDesktop) hands the keyboard to the desktop: arrows and Tab then move between icons.
            Connections {
                target: DesktopState

                function onFocusRequested(): void {
                    win.feed({
                        type: "request"
                    });
                }
            }

            // The policy was withdrawn (plugin unloaded) while the desktop holds the keyboard: the pointer-leave drop
            // is back, and the pointer may already be elsewhere.
            onPolicyChanged: {
                if (!win.policy && !hover.hovered)
                    win.feed({
                        type: "pointerLeft"
                    });
            }

            // Hyprland grants the keyboard to an OnDemand surface only at the next pointer motion (measured: ADR-0012,
            // spike). Mapping and unmapping a transparent 1x1 layer surface makes it re-run its pointer focus logic, so
            // the keyboard arrives without any motion. If it is not granted (the pointer is over a window), give up.
            readonly property bool kicking: Focus.kicking(win.kb, win.policy)
            onKickingChanged: {
                if (win.kicking) {
                    if (!kickTimer.running && !win.kickOn)
                        kickTimer.restart();
                } else {
                    kickTimer.stop();
                    win.kickOn = false;
                }
            }

            // Armed (a press asked for the keyboard): give up when it is not granted in time.
            readonly property bool armed: win.kb.mode === "armed"
            onArmedChanged: {
                if (win.armed)
                    armTimer.restart();
                else
                    armTimer.stop();
            }

            Timer {
                id: kickTimer
                interval: Tokens.desktopIconFocusKickMs
                onTriggered: {
                    win.kickOn = !win.kickOn;
                    if (win.kickOn)
                        restart();
                }
            }

            Timer {
                id: armTimer
                interval: Tokens.desktopIconFocusArmMs
                onTriggered: win.feed({
                    type: "armTimeout"
                })
            }

            // After an outside dismissal of the menu: None for one beat (above), then ask again.
            Timer {
                id: rearmTimer
                interval: Tokens.desktopIconFocusKickMs
                onTriggered: win.feed({
                    type: "press"
                })
            }

            // qmllint disable uncreatable-type
            PanelWindow {
                // qmllint enable uncreatable-type
                id: kicker

                screen: win.modelData
                visible: win.kickOn
                anchors {
                    top: true
                    left: true
                }
                implicitWidth: 1
                implicitHeight: 1
                exclusionMode: ExclusionMode.Ignore
                color: "transparent"
                WlrLayershell.layer: WlrLayer.Background
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                WlrLayershell.namespace: "grassfield-desktop-kicker"
            }

            IconsView {
                id: view
                anchors.fill: parent
                focus: true
                screen: win.modelData
                hostWindow: win
                files: desktopFiles
                iconsHere: win.iconsHere
                keysActive: Focus.keysActive(win.kb)
                fileKeyActions: Focus.fileKeyActions(win.policy) && win.iconsHere
                onFocusEvent: event => win.feed(event)
            }

            Item {
                anchors.fill: parent

                // The wallpaper below no longer sees the pointer: report it for the hot corner re-arm.
                HoverHandler {
                    id: hover
                    onPointChanged: if (hovered && win.modelData)
                        PointerTracker.report(win.modelData.name, point.position.x, point.position.y)
                    onHoveredChanged: if (!hovered)
                        win.feed({
                            type: "pointerLeft"
                        })
                }

                // A left press on the desktop (an icon, empty space) asks for the keyboard. Passive: the icons and
                // the rubber band keep their own handling.
                PointHandler {
                    acceptedButtons: Qt.LeftButton
                    onActiveChanged: if (active)
                        win.feed({
                            type: "press"
                        })
                }
            }
        }
    }
}
