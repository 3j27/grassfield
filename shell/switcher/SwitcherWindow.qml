pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import "SwitcherModel.js" as Model

// App switcher panel (spec docs/specs/switcher.md): one overlay window per screen, mapped only on the controller's screen
// while the panel is shown. A centred frosted panel with one large icon per app (most recently used first), the selection
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

        readonly property bool shown: root.controller.shown && root.controller.screenName === modelData.name
        readonly property var layout: Model.grid(root.controller.apps.length, width - 2 * (Tokens.switcherEdgeMargin + Tokens.switcherPadding), Tokens.switcherPitch)
        readonly property int selected: root.controller.selected

        screen: modelData
        visible: shown
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-switcher"
        // qmllint disable missing-type
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.shown ? blur : null
        // qmllint enable missing-type

        Region {
            id: blur
            item: panel
            radius: Tokens.switcherPanelRadius
        }

        onShownChanged: {
            if (shown)
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

            // Fallback for sessions without the compositor key map (the binds consume these keys first).
            focus: true
            Keys.onPressed: event => {
                event.accepted = true;
                switch (event.key) {
                case Qt.Key_Escape:
                    root.controller.cancel();
                    break;
                case Qt.Key_Left:
                case Qt.Key_Backtab:
                    root.controller.step(-1, true);
                    break;
                case Qt.Key_Right:
                    root.controller.step(1, true);
                    break;
                case Qt.Key_Tab:
                    root.controller.step((event.modifiers & Qt.ShiftModifier) !== 0 ? -1 : 1, true);
                    break;
                case Qt.Key_Return:
                case Qt.Key_Enter:
                    root.controller.release();
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
                    easing.type: Easing.OutCubic
                }
            }

            // Swallows clicks on the panel itself.
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
            }

            Material {
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
                    Accessible.name: modelData.name
                    Accessible.focused: current
                    Accessible.onPressAction: root.controller.click(index)

                    Rectangle {
                        anchors.centerIn: parent
                        width: Tokens.switcherSelectionSize
                        height: width
                        radius: Tokens.switcherSelectionRadius
                        visible: tile.current
                        color: Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHighlightOpacity)
                        border.width: Tokens.controlFocusRing
                        border.color: Appearance.colors.accent
                    }

                    Image {
                        anchors.centerIn: parent
                        width: Tokens.switcherIconSize
                        height: width
                        source: Quickshell.iconPath(tile.modelData.icon, "application-x-executable")
                        sourceSize: Qt.size(Tokens.switcherIconSize * 2, Tokens.switcherIconSize * 2)
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        smooth: true
                        mipmap: true
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
                text: root.controller.apps[win.selected] ? root.controller.apps[win.selected].name : ""
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
