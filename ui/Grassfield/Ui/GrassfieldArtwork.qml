pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import "Artwork.js" as ArtworkLogic

// The Grassfield artworks (ADR-0040 step 2, ID-1), drawn procedurally from the `artwork.*` tokens: Grassfield (sky, sun,
// layered hills) in four phases of the day and two sets, Meadow (grass blades close up), Field Rows (a field seen from
// above) and Ridgeline (one quiet hill line), each in a light and a dark variant (Artwork.js). Crisp at any size; nothing is
// decoded. Without parameters it draws the Grassfield evening of the dark set, the picture the lock and the screen saver keep
// until ADR-0040 step 4a. Drawn by the desktop wallpaper, the Settings tiles and previews.
Item {
    id: root

    // The blades, the bands and the glow reach past the edges: only the picture's own rectangle shows.
    clip: true

    // "grassfield" | "meadow" | "rows" | "ridgeline"; anything else reads as "grassfield".
    property string artwork: "grassfield"
    // Grassfield: "<dawn|day|evening|night>.<light|dark>"; the others: "light" | "dark".
    property string variant: ArtworkLogic.DEFAULT_VARIANT

    // The resolved palette (Artwork.palette) and its flat colour map: the desktop reads `art.skyTop` and `art.skyMid` for the
    // menu bar tone and every colour for the glass backdrop's range.
    readonly property var artPalette: ArtworkLogic.palette(Tokens, root.artwork, root.variant)
    readonly property var art: ArtworkLogic.flat(root.artPalette)

    // ---- the moving variant (ADR-0040 IQ-W3 A, step 9; the Grassfield artwork only) ----
    // `moving`: clouds drift across the sky and the sun's light changes slowly, drawn at `motionMs`. It advances only while
    // `playing` (the lock screen and the screen saver; the desktop draws it still, ADR-0040 step 9 as the integrator decided in
    // the review of e067f26f), by wallpaper.movingFrameMs steps of a Timer, never every frame; paused, it holds where it is. Nothing of it enters the strip under the menu bar (the clouds stay
    // between 0.1 and 0.34 of the height and above the hills), so the bar's tone and gate A2 stay those of the still picture.
    property bool moving: false
    property bool playing: false
    property real motionMs: 0
    readonly property bool movingOn: root.moving && root.artPalette.artwork === "grassfield"
    Timer {
        interval: Tokens.wallpaperMovingFrameMs
        repeat: true
        running: root.movingOn && root.playing
        onTriggered: root.motionMs += interval
    }

    // The sky (Field Rows: its base colour).
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop {
                position: root.artPalette.stops[0][0]
                color: root.artPalette.stops[0][1]
            }
            GradientStop {
                position: root.artPalette.stops[1][0]
                color: root.artPalette.stops[1][1]
            }
            GradientStop {
                position: root.artPalette.stops[2][0]
                color: root.artPalette.stops[2][1]
            }
        }
    }

    // The night's stars (Grassfield at Night), seeded: the same sky on every output.
    Repeater {
        model: root.artPalette.phase === "night" ? ArtworkLogic.stars(7, ArtworkLogic.starCount(root.width, root.height)) : []

        Rectangle {
            required property var modelData

            x: modelData.x * root.width
            y: modelData.y * root.height
            width: modelData.r * 2
            height: width
            radius: width / 2
            color: root.artPalette.sun
            opacity: modelData.alpha
        }
    }

    // The sun (the moon at Night) or Ridgeline's low glow: a soft radial light (a Shape: a Rectangle's gradient is linear only).
    Shape {
        id: glow
        readonly property var spec: root.artPalette.glow
        readonly property real cx: spec ? root.width * spec.x : 0
        readonly property real cy: spec ? root.height * spec.y : 0
        readonly property real r: spec ? root.height * spec.r : 0
        anchors.fill: parent
        visible: spec !== null
        opacity: root.movingOn ? ArtworkLogic.lightAt(root.motionMs, Tokens.wallpaperMovingLightMs, Tokens.wallpaperMovingLightDepth) : 1
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: "transparent"
            fillGradient: RadialGradient {
                centerX: glow.cx
                centerY: glow.cy
                centerRadius: glow.r
                focalX: glow.cx
                focalY: glow.cy
                GradientStop {
                    position: glow.spec ? glow.spec.alphas[0][0] : 0
                    color: Qt.alpha(root.artPalette.sun, glow.spec ? glow.spec.alphas[0][1] : 0)
                }
                GradientStop {
                    position: glow.spec ? glow.spec.alphas[1][0] : 1
                    color: Qt.alpha(root.artPalette.sun, glow.spec ? glow.spec.alphas[1][1] : 0)
                }
                GradientStop {
                    position: glow.spec ? glow.spec.alphas[2][0] : 1
                    color: Qt.alpha(root.artPalette.sun, glow.spec ? glow.spec.alphas[2][1] : 0)
                }
            }
            PathAngleArc {
                centerX: glow.cx
                centerY: glow.cy
                radiusX: glow.r
                radiusY: glow.r
                startAngle: 0
                sweepAngle: 360
            }
        }
    }

    // The moving variant's clouds (seeded: the same sky on every output), under the hills. All four are one translucent
    // layer (the integrator's review of e067f26f, NIT): where clouds or their parts overlap, the union is drawn once, so no
    // cloud's edge shows across another. The layer covers only the clouds' band (Artwork.clouds: between 0.1 and 0.5 of the
    // height) at half the resolution (soft shapes), so its texture costs no more than the four clouds' own layers did.
    Item {
        id: cloudLayer
        readonly property real from: 0.1
        visible: root.movingOn
        y: root.height * cloudLayer.from
        width: root.width
        height: root.height * 0.4
        // An artwork without clouds has no cloudAlpha (the integrator's review of 951a311f, gate Q2): 0 then, never undefined.
        opacity: root.movingOn ? root.artPalette.cloudAlpha : 0
        layer.enabled: root.movingOn
        layer.smooth: true
        layer.textureSize: Qt.size(Math.max(1, Math.ceil(cloudLayer.width / 2)), Math.max(1, Math.ceil(cloudLayer.height / 2)))

        Repeater {
            model: root.movingOn ? ArtworkLogic.clouds(5, 4) : []

            Item {
                id: cloud

                required property var modelData

                x: root.width * ArtworkLogic.cloudX(cloud.modelData, root.motionMs, Tokens.wallpaperMovingCloudMs)
                y: root.height * (cloud.modelData.y - cloudLayer.from)
                width: root.width * cloud.modelData.w
                height: root.height * cloud.modelData.h * 2

                // A long rounded base and three rounded tops.
                Rectangle {
                    y: cloud.height * 0.55
                    width: cloud.width
                    height: cloud.height * 0.45
                    radius: height / 2
                    color: root.artPalette.cloud
                }
                Repeater {
                    model: [[0.1, 0.5], [0.3, 0.85], [0.56, 0.62]]

                    Rectangle {
                        required property var modelData
                        x: cloud.width * modelData[0]
                        y: cloud.height - height
                        width: cloud.height * modelData[1]
                        height: width
                        radius: width / 2
                        color: root.artPalette.cloud
                    }
                }
            }
        }
    }

    // Grassfield: layered hills, far to near; each is a smooth closed curve.
    Repeater {
        model: root.artPalette.artwork === "grassfield" ? [
                {
                    "color": root.artPalette.hills[0],
                    "base": 0.62,
                    "amp": 0.10,
                    "phase": 0.0
                },
                {
                    "color": root.artPalette.hills[1],
                    "base": 0.72,
                    "amp": 0.09,
                    "phase": 1.3
                },
                {
                    "color": root.artPalette.hills[2],
                    "base": 0.82,
                    "amp": 0.08,
                    "phase": 2.6
                },
                {
                    "color": root.artPalette.hills[3],
                    "base": 0.92,
                    "amp": 0.06,
                    "phase": 4.0
                }
            ] : []

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

    // Meadow: four layers of blades, far to near, each layer one path.
    Shape {
        id: meadow
        readonly property bool on: root.artPalette.artwork === "meadow"
        readonly property var blades: on ? ArtworkLogic.meadowBlades(11) : []
        anchors.fill: parent
        visible: on
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: "transparent"
            fillColor: meadow.on ? Qt.alpha(root.artPalette.blades[0], root.artPalette.bladeAlphas[0]) : "transparent"
            PathSvg {
                path: meadow.on ? ArtworkLogic.meadowPath(meadow.blades[0], meadow.width, meadow.height) : ""
            }
        }
        ShapePath {
            strokeColor: "transparent"
            fillColor: meadow.on ? Qt.alpha(root.artPalette.blades[1], root.artPalette.bladeAlphas[1]) : "transparent"
            PathSvg {
                path: meadow.on ? ArtworkLogic.meadowPath(meadow.blades[1], meadow.width, meadow.height) : ""
            }
        }
        ShapePath {
            strokeColor: "transparent"
            fillColor: meadow.on ? Qt.alpha(root.artPalette.blades[2], root.artPalette.bladeAlphas[2]) : "transparent"
            PathSvg {
                path: meadow.on ? ArtworkLogic.meadowPath(meadow.blades[2], meadow.width, meadow.height) : ""
            }
        }
        ShapePath {
            strokeColor: "transparent"
            fillColor: meadow.on ? Qt.alpha(root.artPalette.blades[3], root.artPalette.bladeAlphas[3]) : "transparent"
            PathSvg {
                path: meadow.on ? ArtworkLogic.meadowPath(meadow.blades[3], meadow.width, meadow.height) : ""
            }
        }
    }

    // Field Rows: the bands of one colour in one path each (bands never overlap, so the order does not matter).
    Shape {
        id: rows
        readonly property bool on: root.artPalette.artwork === "rows"
        readonly property var paths: on ? ArtworkLogic.rowsPaths(root.artPalette.bands.length, width, height) : []
        anchors.fill: parent
        visible: on
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: "transparent"
            fillColor: rows.on ? root.artPalette.bands[0] : "transparent"
            PathSvg {
                path: rows.on ? (rows.paths[0] ?? "") : ""
            }
        }
        ShapePath {
            strokeColor: "transparent"
            fillColor: rows.on ? root.artPalette.bands[1] : "transparent"
            PathSvg {
                path: rows.on ? (rows.paths[1] ?? "") : ""
            }
        }
        ShapePath {
            strokeColor: "transparent"
            fillColor: rows.on ? root.artPalette.bands[2] : "transparent"
            PathSvg {
                path: rows.on ? (rows.paths[2] ?? "") : ""
            }
        }
        ShapePath {
            strokeColor: "transparent"
            fillColor: rows.on ? root.artPalette.bands[3] : "transparent"
            PathSvg {
                path: rows.on ? (rows.paths[3] ?? "") : ""
            }
        }
        ShapePath {
            strokeColor: "transparent"
            fillColor: rows.on ? root.artPalette.bands[4] : "transparent"
            PathSvg {
                path: rows.on ? (rows.paths[4] ?? "") : ""
            }
        }
        ShapePath {
            strokeColor: "transparent"
            fillColor: rows.on ? root.artPalette.bands[5] : "transparent"
            PathSvg {
                path: rows.on ? (rows.paths[5] ?? "") : ""
            }
        }
    }

    // Ridgeline: two quiet hill lines under a wide sky.
    Shape {
        id: ridge
        readonly property bool on: root.artPalette.artwork === "ridgeline"
        readonly property var paths: on ? ArtworkLogic.ridgelinePaths(width, height) : []
        anchors.fill: parent
        visible: on
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: "transparent"
            fillColor: ridge.on ? root.artPalette.hills[0] : "transparent"
            PathSvg {
                path: ridge.on ? (ridge.paths[0] ?? "") : ""
            }
        }
        ShapePath {
            strokeColor: "transparent"
            fillColor: ridge.on ? root.artPalette.hills[1] : "transparent"
            PathSvg {
                path: ridge.on ? (ridge.paths[1] ?? "") : ""
            }
        }
    }
}
