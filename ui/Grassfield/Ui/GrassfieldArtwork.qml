pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes

// Procedurally drawn wallpaper artwork ("Grassfield": sky, sun, layered hills). Original artwork,
// drawn entirely from the constants below; it is not a UI surface, so these colors are
// intentionally not design tokens. Drawn by the desktop Wallpaper and, blurred, by the lock screen.
Item {
    id: root

    // Artwork palette.
    readonly property var art: ({
            skyTop: "#0F2A3F",
            skyMid: "#2F6F7E",
            skyLow: "#E8C98B",
            sun: "#FFF1C2",
            hillFar: "#3E7D5A",
            hillMid: "#2E6B3F",
            hillNear: "#1F4F2C",
            hillFront: "#16391F"
        })

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop {
                position: 0.0
                color: root.art.skyTop
            }
            GradientStop {
                position: 0.55
                color: root.art.skyMid
            }
            GradientStop {
                position: 0.78
                color: root.art.skyLow
            }
        }
    }

    // Sun with a soft radial glow.
    Rectangle {
        id: sun
        width: parent.height * 0.5
        height: width
        radius: width / 2
        x: parent.width * 0.68 - width / 2
        y: parent.height * 0.52 - height / 2
        gradient: RadialGradient {
            GradientStop {
                position: 0.0
                color: root.art.sun
            }
            GradientStop {
                position: 0.35
                color: Qt.alpha(root.art.sun, 0.55)
            }
            GradientStop {
                position: 1.0
                color: Qt.alpha(root.art.sun, 0)
            }
        }
    }

    // Layered hills, far to near; each is a smooth closed curve.
    Repeater {
        model: [
            {
                "color": root.art.hillFar,
                "base": 0.62,
                "amp": 0.10,
                "phase": 0.0
            },
            {
                "color": root.art.hillMid,
                "base": 0.72,
                "amp": 0.09,
                "phase": 1.3
            },
            {
                "color": root.art.hillNear,
                "base": 0.82,
                "amp": 0.08,
                "phase": 2.6
            },
            {
                "color": root.art.hillFront,
                "base": 0.92,
                "amp": 0.06,
                "phase": 4.0
            }
        ]

        Shape {
            id: hill

            required property var modelData

            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
                fillColor: hill.modelData.color
                strokeColor: "transparent"
                startX: 0
                startY: hill.height
                PathLine {
                    x: 0
                    y: hill.height * (hill.modelData.base - hill.modelData.amp * Math.sin(hill.modelData.phase))
                }
                PathCubic {
                    x: hill.width * 0.5
                    y: hill.height * (hill.modelData.base - hill.modelData.amp * Math.sin(hill.modelData.phase + 2.0))
                    control1X: hill.width * 0.18
                    control1Y: hill.height * (hill.modelData.base - hill.modelData.amp * 2.0)
                    control2X: hill.width * 0.34
                    control2Y: hill.height * (hill.modelData.base + hill.modelData.amp)
                }
                PathCubic {
                    x: hill.width
                    y: hill.height * (hill.modelData.base - hill.modelData.amp * Math.sin(hill.modelData.phase + 4.0))
                    control1X: hill.width * 0.68
                    control1Y: hill.height * (hill.modelData.base - hill.modelData.amp * 1.8)
                    control2X: hill.width * 0.84
                    control2Y: hill.height * (hill.modelData.base + hill.modelData.amp * 0.8)
                }
                PathLine {
                    x: hill.width
                    y: hill.height
                }
            }
        }
    }
}
