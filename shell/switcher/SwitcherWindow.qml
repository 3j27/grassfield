pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.platform
import qs.services
import "SwitcherModel.js" as Model

// App switcher surface (spec docs/specs/switcher.md): one overlay window per screen, mapped only on the controller's
// screen while a session runs. It takes the keyboard (exclusive) the moment the session starts, so that it sees the Super
// release itself, and stays transparent until the panel is due (quick switch). The panel is a centred frosted panel with one large icon per app (most recently used first), the selection
// square on the chosen one and its name under the row. Hover selects, a click activates.
Variants {
    id: root

    required property var controller

    model: Quickshell.screens

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        required property ShellScreen modelData

        // Session running on this output: the surface is mapped and holds the keyboard.
        readonly property bool grabbing: root.controller.active && root.controller.screenName === (modelData ? modelData.name : "")
        readonly property bool shown: root.controller.shown && grabbing
        readonly property var layout: Model.grid(root.controller.apps.length, width - 2 * (Tokens.switcherEdgeMargin + Tokens.switcherPadding), Tokens.switcherPitch)
        readonly property int selected: root.controller.selected

        screen: modelData
        // Mapped a moment longer than it holds the keyboard: a layer destroyed while Exclusive leaves the compositor with no
        // keyboard focus (the cancelled switch must give it back).
        visible: release.mapped
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: grabbing ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-switcher"
        // qmllint disable missing-type
        // The whole surface takes input during the switch; nothing once it ended: it stays mapped a moment for the
        // keyboard release, and a click then belongs to the window under it.
        mask: win.grabbing ? null : passThrough
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.shown ? blur : null
        // qmllint enable missing-type

        Region {
            id: blur
            item: panel
            radius: Tokens.switcherPanelRadius
        }

        Region {
            id: passThrough
        }

        KeyboardRelease {
            id: release
            shown: win.grabbing
        }

        // Ended but still mapped (the hold): a press the compositor delivered before the empty mask landed (late whenever the
        // GUI thread was busy) is swallowed here, never handled by the tile under it.
        MouseArea {
            anchors.fill: parent
            z: 1000
            visible: !win.grabbing
            acceptedButtons: Qt.AllButtons
        }

        onGrabbingChanged: {
            if (grabbing)
                keys.forceActiveFocus();
        }

        // A click outside the panel cancels.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onPressed: root.controller.cancel()
        }

        Item {
            id: keys

            // Tab and Q/H are binds of the compositor config (they never reach a client); the rest comes through the grab.
            focus: true
            Keys.onReleased: event => {                // The modifier release (the compositor config's release bind is the second path).
                if (event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R || event.key === Qt.Key_Meta) {
                    event.accepted = true;
                    root.controller.release("");
                }
            }
            Keys.onPressed: event => {                event.accepted = true;
                switch (event.key) {
                case Qt.Key_Escape:
                    root.controller.cancel();
                    break;
                case Qt.Key_Left:
                case Qt.Key_Backtab:
                    root.controller.step(-1, true, "");
                    break;
                case Qt.Key_Right:
                    root.controller.step(1, true, "");
                    break;
                case Qt.Key_Tab:
                    root.controller.step((event.modifiers & Qt.ShiftModifier) !== 0 ? -1 : 1, true, "");
                    break;
                case Qt.Key_Return:
                case Qt.Key_Enter:
                    root.controller.release("");
                    break;
                default:
                    event.accepted = false;
                }
            }
        }

        Item {
            id: panel

            readonly property real cell: Tokens.switcherPitch
            readonly property real nameTop: Tokens.switcherPadding + win.layout.rows * cell + Tokens.switcherNameGap

            anchors.centerIn: parent
            width: win.layout.columns * cell + 2 * Tokens.switcherPadding
            height: nameTop + Tokens.switcherNameHeight + Tokens.switcherPadding
            opacity: win.shown ? 1 : 0
            scale: win.shown || Appearance.reduceMotion ? 1 : Tokens.switcherFadeScale
            Accessible.role: Accessible.List
            Accessible.name: qsTr("Application Switcher")

            Behavior on opacity {
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionFast)
                }
            }

            Behavior on scale {
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionFast)
                    // Arriving: the enter curve (ADR-0039 step 20).
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Appearance.curveEnter
                }
            }

            // Swallows clicks on the panel itself.
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
            }

            // The app's name under the selection: a text surface, the menus' class (ADR-0039 step 22).
            Material {
                glassClass: "menu"
                anchors.fill: parent
                radius: Tokens.switcherPanelRadius
            }

            Repeater {
                model: root.controller.apps

                delegate: Item {
                    id: tile

                    required property var modelData
                    required property int index
                    readonly property bool current: index === win.selected

                    x: Tokens.switcherPadding + (index % win.layout.columns) * panel.cell
                    y: Tokens.switcherPadding + Math.floor(index / win.layout.columns) * panel.cell
                    width: panel.cell
                    height: panel.cell
                    Accessible.role: Accessible.Button
                    Accessible.name: modelData.entry ? Apps.displayName(modelData.entry) : modelData.name
                    Accessible.focused: current
                    Accessible.onPressAction: root.controller.click(index)

                    Rectangle {
                        anchors.centerIn: parent
                        width: Tokens.switcherSelectionSize
                        height: width
                        radius: Tokens.switcherSelectionRadius
                        visible: tile.current
                        // The neutral selection of an item on glass (macOS 27's App Switcher: black at 0.25 in light; one role,
                        // ADR-0039 step 12, G6), no longer the material's rim token.
                        color: Appearance.withAlpha(Appearance.colors.hover, Tokens.materialSelectionOpacity)

                        // macOS 27's App Switcher marks the selection with the neutral plate only (UI audit 2026-11-05 U28):
                        // the switcher is driven by the keyboard from start to end, so the accent ring of step 7 (keyboard
                        // focus) was always on. Under Increase Contrast the shared ring outside the plate stays, the
                        // stronger outline that setting asks for (ADR-0039 step 7).
                        FocusRing {
                            shapeRadius: Tokens.switcherSelectionRadius
                            visible: Appearance.increaseContrast
                        }
                    }

                    TintedIcon {
                        anchors.centerIn: parent
                        size: Tokens.switcherIconSize
                        source: ThemeIcons.appIcon(tile.modelData.icon, "application-x-executable")
                        asynchronous: true
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton
                        // Selection follows the pointer when it moves, not when the panel appears under it.
                        onPositionChanged: root.controller.hover(tile.index)
                        onClicked: root.controller.click(tile.index)
                    }
                }
            }

            Text {
                id: name

                readonly property real center: Tokens.switcherPadding + ((win.selected < 0 ? 0 : win.selected) % win.layout.columns + 0.5) * panel.cell
                readonly property real limit: panel.width - 2 * Tokens.switcherPadding

                width: Math.min(implicitWidth, limit)
                x: Math.max(Tokens.switcherPadding, Math.min(panel.width - Tokens.switcherPadding - width, center - width / 2))
                y: panel.nameTop
                height: Tokens.switcherNameHeight
                // The app's name in the shell's language (Apps.displayName), whatever DockModel copied.
                readonly property var app: root.controller.apps[win.selected]
                text: app ? (app.entry ? Apps.displayName(app.entry) : app.name) : ""
                textFormat: Text.PlainText
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.switcherNameSize
                font.weight: Tokens.typographyMenuBoldWeight
            }
        }
    }
}
