pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui

// Volume/brightness OSD: a compact pill under the menu bar at the top-right (icon + level bar),
// on the active display (Compositor.activeScreenName), a brightness change on the display that changed (Osd.screenName).
// Never takes input.
Variants {
    id: root

    model: Quickshell.screens

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        required property ShellScreen modelData

        // The OSD shows on the active display (macOS), like Banners offsets for it; a brightness change shows on the display that
        // changed (Osd.screenName, ADR-0045 OC-4), which is the active one but for the built-in panel driven from another.
        readonly property bool primary: modelData !== null && modelData.name === Osd.screenName
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
            Accessible.name: Osd.kind === "inputsource" ? qsTr("Input source %1").arg(Osd.label) : Osd.kind === "keyboard" ? qsTr("Keyboard brightness %1%").arg(Math.round(Osd.level * 100)) : Osd.kind === "brightness" ? qsTr("Brightness %1%").arg(Math.round(Osd.level * 100)) : qsTr("Volume %1%").arg(Math.round(Osd.level * 100))

            Behavior on opacity {
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionNormal)
                }
            }

            Material {
                glassClass: "controls"
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

            Text {
                id: sourceName
                visible: Osd.kind === "inputsource"
                textFormat: Text.PlainText
                anchors {
                    left: glyph.right
                    leftMargin: Tokens.spacingMd
                    right: parent.right
                    rightMargin: Tokens.spacingLg
                    verticalCenter: parent.verticalCenter
                }
                text: Osd.label
                elide: Text.ElideRight
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyMenuSize
                font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
                font.weight: Tokens.typographyMenuBoldWeight
            }

            Rectangle {
                id: track
                visible: Osd.kind !== "inputsource"
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

                    // Under Reduce Motion the level jumps; the OSD itself still fades in and out (ADR-0039 step 5).
                    Behavior on width {
                        enabled: !Appearance.reduceMotion
                        NumberAnimation {
                            duration: Appearance.duration(Tokens.motionFast)
                        }
                    }
                }
            }
        }
    }
}
