pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.UPower
import Grassfield.Ui
import qs.platform

// Top bar, one per screen. Left: Grassfield mark and the focused app name (application
// menus arrive with the menu bridge, so none are shown). Right: battery (when present), clock.
Variants {
    id: root

    model: Quickshell.screens

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        required property ShellScreen modelData

        readonly property var focusedEntry: {
            const id = Compositor.focusedAppId;
            if (id === "")
                return null;
            const byId = DesktopEntries.byId(id);
            return byId ? byId : DesktopEntries.heuristicLookup(id);
        }
        readonly property string appName: {
            if (Compositor.focusedAppId === "")
                return qsTr("Desktop");
            return focusedEntry ? focusedEntry.name : Compositor.focusedClass;
        }

        screen: modelData
        anchors {
            top: true
            left: true
            right: true
        }
        implicitHeight: Tokens.menubarHeight
        exclusiveZone: Tokens.menubarHeight
        color: "transparent"
        focusable: false
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "grassfield-menubar"
        // Quickshell qmltypes name this property's type PendingRegion/FileViewAdapter without exporting it (metadata quirk).
        // qmllint disable missing-type
        BackgroundEffect.blurRegion: material.blurActive ? blurRegion : null
        // qmllint enable missing-type

        Region {
            id: blurRegion
            item: material
            radius: material.radius
        }

        SystemClock {
            id: clock
            precision: SystemClock.Minutes
        }

        Material {
            id: material
            anchors.fill: parent
            radius: Tokens.radiusMenuBar
            shadowEnabled: false
            highlightEnabled: false
            borderEnabled: false

            // Hairline along the bottom edge instead of a full border.
            Rectangle {
                anchors {
                    left: parent.left
                    right: parent.right
                    bottom: parent.bottom
                }
                height: 1
                color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
            }

            Row {
                id: leftRow
                anchors {
                    left: parent.left
                    leftMargin: Tokens.spacingSm
                    verticalCenter: parent.verticalCenter
                }
                spacing: Tokens.menubarItemPadding

                // Grassfield mark (decorative until the system menu exists).
                Item {
                    id: mark
                    width: Tokens.menubarIconSize
                    height: Tokens.menubarIconSize
                    anchors.verticalCenter: parent.verticalCenter
                    Accessible.role: Accessible.Graphic
                    Accessible.name: qsTr("Grassfield")

                    Shape {
                        anchors.fill: parent
                        preferredRendererType: Shape.CurveRenderer
                        // Own leaf glyph on a 14 x 14 grid.
                        scale: Tokens.menubarIconSize / 14
                        transformOrigin: Item.TopLeft

                        ShapePath {
                            fillColor: Appearance.colors.text
                            strokeColor: "transparent"
                            PathSvg {
                                path: "M12.6 1.2 C5.6 1.2 2.2 4.6 2.2 8.6 C2.2 9.6 2.5 10.5 3 11.3 L1.4 12.9 L2.4 13.9 L4 12.3 C4.8 12.8 5.7 13 6.7 13 C10.7 13 12.6 8.4 12.6 1.2 Z"
                            }
                        }
                    }
                }

                Text {
                    id: appNameText
                    anchors.verticalCenter: parent.verticalCenter
                    text: win.appName
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyMenuSize
                    font.weight: Tokens.typographyMenuBoldWeight
                    elide: Text.ElideRight
                    Accessible.role: Accessible.StaticText
                    Accessible.name: qsTr("Active application: %1").arg(win.appName)
                }
            }

            Row {
                anchors {
                    right: parent.right
                    rightMargin: Tokens.spacingMd
                    verticalCenter: parent.verticalCenter
                }
                spacing: Tokens.menubarItemPadding

                Text {
                    id: batteryText
                    readonly property var device: UPower.displayDevice
                    visible: device !== null && device.isPresent && device.isLaptopBattery
                    anchors.verticalCenter: parent.verticalCenter
                    text: device ? qsTr("%1%").arg(Math.round(device.percentage * 100)) : ""
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyMenuSize
                    font.weight: Tokens.typographyMenuWeight
                    Accessible.role: Accessible.StaticText
                    Accessible.name: qsTr("Battery %1").arg(text)
                }

                Text {
                    id: clockText
                    anchors.verticalCenter: parent.verticalCenter
                    text: Qt.formatDateTime(clock.date, qsTr("ddd d MMM")) + " "
                        + Qt.formatTime(clock.date, Qt.locale().timeFormat(Locale.ShortFormat))
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyMenuSize
                    font.weight: Tokens.typographyMenuWeight
                    Accessible.role: Accessible.StaticText
                    Accessible.name: qsTr("Date and time: %1").arg(text)
                }
            }
        }
    }
}
