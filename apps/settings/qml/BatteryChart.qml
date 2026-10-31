pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Battery > Battery Level (macOS 27): the plot of four bands with its value labels, one bar per time bucket (Power.bars),
// the charging strip under the bars of the charging times, dashed lines at each time label, and the date under them. Placed as
// measured (docs/audits/settings-parity-2026-10-26.md § Battery); drawn with rectangles (whole points, no canvas).
Item {
    id: root

    property string title: ""
    // [{level (0-100, -1 for none), charging}]
    property var bars: []
    // [{text}] spread evenly across the plot, each at a line.
    property var timeLabels: []
    property string dateText: ""

    readonly property real plotHeight: 4 * Tokens.settingsChartBand
    readonly property real plotBottom: Tokens.settingsChartTop + root.plotHeight
    readonly property real step: root.bars.length > 0 ? Tokens.settingsChartWidth / root.bars.length : 0
    readonly property color lineColor: Appearance.withAlpha(Appearance.colors.text, Tokens.settingsChartGridOpacity)

    width: parent ? parent.width : implicitWidth
    implicitWidth: Tokens.settingsContentMaxWidth
    implicitHeight: Math.round(root.plotBottom + Tokens.settingsChartAxisBaseline + (root.dateText !== "" ? Tokens.settingsChartDateGap : 0) + Tokens.settingsChartBottom)
    Accessible.role: Accessible.Chart
    Accessible.name: root.title

    Text {
        textFormat: Text.PlainText
        x: Tokens.settingsRowInset
        y: Tokens.settingsChartTitleBaseline - baselineOffset
        text: root.title
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
        font.weight: Tokens.typographyMenuBoldWeight
    }

    // The bands' lines and their values (100 %, 50 %, 0 %).
    Repeater {
        model: 5

        Item {
            id: band
            required property int index
            readonly property real lineY: Tokens.settingsChartTop + band.index * Tokens.settingsChartBand

            Rectangle {
                x: Tokens.settingsChartInset
                y: band.lineY
                width: Tokens.settingsChartWidth + 1
                height: Tokens.appsBorderWidth
                color: root.lineColor
            }

            Text {
                textFormat: Text.PlainText
                visible: band.index % 2 === 0
                x: Tokens.settingsChartLabelInset
                y: band.lineY + 0.5 - height / 2
                text: qsTr("%1 %").arg(100 - band.index * 25)
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.settingsChartLabelSize
            }
        }
    }

    // The time lines: solid at both ends, dashed between, down through the time labels.
    Repeater {
        model: root.timeLabels.length + 1

        Item {
            id: column
            required property int index
            readonly property real lineX: Tokens.settingsChartInset + column.index * Tokens.settingsChartWidth / Math.max(1, root.timeLabels.length)
            readonly property bool edge: column.index === 0 || column.index === root.timeLabels.length
            readonly property real lineBottom: root.plotBottom + Tokens.settingsChartAxisBaseline + Tokens.settingsChartLabelGap

            Rectangle {
                visible: column.edge
                x: column.lineX
                y: Tokens.settingsChartTop
                width: Tokens.appsBorderWidth
                height: column.lineBottom - Tokens.settingsChartTop
                color: root.lineColor
            }

            Repeater {
                model: column.edge ? 0 : Math.floor((column.lineBottom - Tokens.settingsChartTop) / (2 * Tokens.settingsChartDash))

                Rectangle {
                    required property int index
                    x: column.lineX
                    y: Tokens.settingsChartTop + index * 2 * Tokens.settingsChartDash
                    width: Tokens.appsBorderWidth
                    height: Tokens.settingsChartDash
                    color: root.lineColor
                }
            }

            Text {
                textFormat: Text.PlainText
                visible: column.index < root.timeLabels.length
                x: column.lineX + Tokens.settingsChartLabelGap
                y: root.plotBottom + Tokens.settingsChartAxisBaseline - baselineOffset
                text: column.index < root.timeLabels.length ? root.timeLabels[column.index].text : ""
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.settingsChartLabelSize
            }
        }
    }

    // The bars and, under the charging ones, the strip.
    Repeater {
        model: root.bars

        Item {
            id: bar
            required property var modelData
            required property int index
            readonly property real barX: Tokens.settingsChartInset + bar.index * root.step + Tokens.settingsChartBarGap

            Rectangle {
                visible: bar.modelData.level >= 0
                x: bar.barX
                width: Math.max(1, root.step - Tokens.settingsChartBarGap)
                height: Math.max(1, Math.round(root.plotHeight * bar.modelData.level / 100))
                y: root.plotBottom - height
                color: Appearance.colors.statusOn
            }

            Rectangle {
                visible: bar.modelData.level >= 0 && bar.modelData.charging
                x: bar.barX
                y: root.plotBottom + Tokens.settingsChartChargeTop
                width: root.step
                height: Tokens.settingsChartChargeHeight
                color: Appearance.colors.statusOn
            }
        }
    }

    Text {
        textFormat: Text.PlainText
        visible: root.dateText !== ""
        x: Tokens.settingsChartInset + Tokens.settingsChartLabelGap
        y: root.plotBottom + Tokens.settingsChartAxisBaseline + Tokens.settingsChartDateGap - baselineOffset
        text: root.dateText
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.settingsChartLabelSize
    }
}
