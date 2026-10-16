pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui

// Volume/brightness OSD: a compact pill under the menu bar at the top-right (icon + level bar),
// on the first screen. Never takes input.
Variants {
    id: root

    model: Quickshell.screens

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        required property ShellScreen modelData

        readonly property bool primary: Quickshell.screens.length > 0 && modelData.name === Quickshell.screens[0].name
        readonly property int pad: Tokens.spacingLg

        screen: modelData
        visible: primary && (Osd.shown || pill.opacity > 0)
        anchors {
            top: true
            right: true
        }
        implicitWidth: Tokens.osdWidth + 2 * win.pad
        implicitHeight: pill.y + pill.height + win.pad
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-osd"
        // qmllint disable missing-type
        // Empty input region: clicks go through.
        mask: Region {}
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.visible ? blur : null
        // qmllint enable missing-type

        Region {
            id: blur
            item: pill
            radius: pill.height / 2
        }

        Item {
            id: pill
            x: win.pad
            y: Tokens.menubarHeight + Tokens.osdGap
            width: Tokens.osdWidth
            height: Tokens.osdHeight
            opacity: Osd.shown ? 1 : 0
            Accessible.role: Accessible.ProgressBar
            Accessible.name: Osd.kind === "brightness" ? qsTr("Brightness %1%").arg(Math.round(Osd.level * 100)) : qsTr("Volume %1%").arg(Math.round(Osd.level * 100))

            Behavior on opacity {
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionNormal)
                }
            }

            Material {
                anchors.fill: parent
                radius: pill.height / 2
            }

            Icon {
                id: glyph
                x: Tokens.spacingLg
                anchors.verticalCenter: parent.verticalCenter
                size: Tokens.osdIconSize
                name: Osd.iconName
            }

            Rectangle {
                id: track
                anchors {
                    left: glyph.right
                    leftMargin: Tokens.spacingMd
                    right: parent.right
                    rightMargin: Tokens.spacingLg
                    verticalCenter: parent.verticalCenter
                }
                height: Tokens.osdBarHeight
                radius: height / 2
                color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity * 2)

                Rectangle {
                    width: track.width * (Osd.muted ? 0 : Osd.level)
                    height: parent.height
                    radius: parent.radius
                    color: Appearance.colors.text

                    Behavior on width {
                        NumberAnimation {
                            duration: Appearance.duration(Tokens.motionFast)
                        }
                    }
                }
            }
        }
    }
}
