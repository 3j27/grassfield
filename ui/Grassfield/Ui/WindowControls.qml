import QtQuick
import "WindowActions.js" as Actions

// The three window lights (close, minimize, zoom) of a Grassfield app window, drawn by the app itself (ADR-0015).
// Place it at the window's top-left corner. It sizes itself to the row of `style` ("unified": 52 pt, first centre at
// 25.75 / 25.75; "titlebar": 32 pt) and draws only the lights, never a bar.
//
// Look (the compositor plugin's titlebar has the same values, from the window.* tokens): 14-pt lights 23 apart; the
// glyphs (x, -, +) appear on all three while the pointer is over the group; an inactive window shows grey lights
// (coloured again under the pointer); a disabled light is grey and inert; a pressed light darkens. Option/Alt held over
// the group turns the zoom glyph into the full-screen arrows and the click into a true full screen. The lights are
// hidden while the window is in full screen.
//
// Actions are plain xdg-toplevel requests made by Qt on `window` (WindowActions.js). Each light also emits a signal first;
// a handler that sets `handled` keeps the default action from running.
//
// Accessibility: each light is an Accessible button named Close, Minimize or Zoom with a press action, so a screen reader
// can read and press them. As on macOS they are not in the Tab chain; the keyboard equivalents are the Window menu of the
// menu bar and Super+W, Super+M and Super+Alt+F.
Item {
    id: root

    // The QtQuick Window these lights belong to. Null: the lights draw and signal but act on nothing.
    property var window: null
    // "unified" or "titlebar".
    property string style: "unified"
    // Follows the window; a host may override it.
    property bool active: root.window ? root.window.active : true
    // A light the window cannot honour is grey and inert (minimize without the compositor plugin, ADR-0015 Q4).
    property bool canClose: true
    property bool canMinimize: true
    property bool canZoom: true
    // The pointer is over the group (a test or a screenshot may set it to pin the hover look).
    property bool hovered: groupHover.hovered
    // Option/Alt was held with the pointer over the group.
    property bool altHeld: false
    // Set by a signal handler to keep the default action from running.
    property bool handled: false

    readonly property bool fullScreen: Actions.isFullScreen(root.window)
    readonly property var geometry: Actions.lightGeometry(root.style, {
        diameter: Tokens.windowLightDiameter,
        gap: Tokens.windowLightGap,
        unifiedCentre: Tokens.windowUnifiedLightCentre,
        titlebarInset: Tokens.windowTitlebarLightInset,
        titlebarHeight: Tokens.windowTitlebarHeight
    })
    // Where the toolbar's own content may start: after the lights and the least gap (0 in full screen: no lights).
    readonly property real contentStart: root.fullScreen ? 0 : root.geometry.x0 + root.geometry.width + Tokens.windowTitleGap
    readonly property alias closeLight: closeItem
    readonly property alias minimizeLight: minimizeItem
    readonly property alias zoomLight: zoomItem

    signal closeRequested
    signal minimizeRequested
    // fullScreen: Option/Alt was held.
    signal zoomRequested(bool fullScreen)

    function closeWindow(): void {
        root.handled = false;
        root.closeRequested();
        if (!root.handled && root.canClose)
            Actions.close(root.window);
    }

    function minimizeWindow(): void {
        root.handled = false;
        root.minimizeRequested();
        if (!root.handled && root.canMinimize)
            Actions.minimize(root.window);
    }

    function zoomWindow(fullScreen: bool): void {
        root.handled = false;
        root.zoomRequested(fullScreen);
        if (!root.handled && root.canZoom)
            Actions.zoom(root.window, fullScreen);
    }

    implicitWidth: root.fullScreen ? 0 : root.geometry.x0 + root.geometry.width
    implicitHeight: root.style === "titlebar" ? Tokens.windowTitlebarHeight : Tokens.windowUnifiedHeight
    visible: !root.fullScreen
    Accessible.role: Accessible.Grouping
    Accessible.name: qsTr("Window controls")

    // The group's hover area: the lights, the gaps between them and the hit slop around.
    Item {
        x: root.geometry.x0 - Tokens.windowLightHitSlop
        y: root.geometry.y0 - Tokens.windowLightHitSlop
        width: root.geometry.width + 2 * Tokens.windowLightHitSlop
        height: Tokens.windowLightDiameter + 2 * Tokens.windowLightHitSlop

        HoverHandler {
            id: groupHover
            onPointChanged: root.altHeld = (point.modifiers & Qt.AltModifier) !== 0
            onHoveredChanged: {
                if (!hovered)
                    root.altHeld = false;
            }
        }
    }

    WindowLight {
        id: closeItem
        discX: root.geometry.x0
        discY: root.geometry.y0
        tint: Tokens.windowCloseColor
        glyph: "close"
        accessibleName: qsTr("Close")
        accessibleDescription: qsTr("Closes the window")
        windowActive: root.active
        groupHovered: root.hovered
        lightEnabled: root.canClose
        onActivated: root.closeWindow()
    }

    WindowLight {
        id: minimizeItem
        discX: root.geometry.x0 + root.geometry.pitch
        discY: root.geometry.y0
        tint: Tokens.windowMinimizeColor
        glyph: "minimize"
        accessibleName: qsTr("Minimize")
        accessibleDescription: qsTr("Minimizes the window to the Dock")
        windowActive: root.active
        groupHovered: root.hovered
        lightEnabled: root.canMinimize
        onActivated: root.minimizeWindow()
    }

    WindowLight {
        id: zoomItem
        discX: root.geometry.x0 + 2 * root.geometry.pitch
        discY: root.geometry.y0
        tint: Tokens.windowZoomColor
        glyph: Actions.zoomGlyph(root.altHeld)
        accessibleName: qsTr("Zoom")
        accessibleDescription: qsTr("Fills the screen below the menu bar, or restores the window. Option-click for full screen")
        windowActive: root.active
        groupHovered: root.hovered
        lightEnabled: root.canZoom
        onActivated: alt => root.zoomWindow(alt)
    }
}
