pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.services
import qs.widgets
import "../../Weather.js" as WeatherLogic

// Weather widget (ADR-0045 OC-14), macOS 27's layout on Grassfield's widget glass. Small: the place (and the location arrow
// when wttr.in found it from the IP address), the current temperature large, then at the bottom the condition's symbol, its
// name and the day's high and low. Medium: the same place and temperature at the left, the symbol, condition and high and
// low at the right, and under them a row of Now and the next forecast hours (wttr.in gives one every three hours), each
// with its symbol and temperature. The data is the shared WeatherSampler's (wttr.in's report for Omarchy's saved place);
// this widget only shows it and, while it is shown and placed (never as a gallery preview), counts as one of its users.
// Failure: "Weather unavailable" and the last good values in the secondary colour. °F for the formats of the United States
// (region.formats, else the session's), °C everywhere else. Texts go through qsTranslate with this file's context, as the
// Clock does (Registry.qml: qsTr stayed English in the first moments of a French session).
WidgetBase {
    id: root

    readonly property var report: WeatherSampler.report
    readonly property string status: WeatherSampler.status
    readonly property bool greyed: status === "unavailable"
    readonly property bool fahrenheit: WeatherLogic.useFahrenheit(Settings.regionFormats !== "auto" ? Settings.regionFormats : Qt.locale().name)
    readonly property bool twelveHours: WeatherLogic.usesTwelveHours(Qt.locale().timeFormat(Locale.ShortFormat))
    readonly property var current: report ? report.current : null
    readonly property var now: current ? WeatherLogic.condition(current.code, current.night) : ({key: "unknown", symbol: "cloud"})
    readonly property string placeText: WeatherSampler.place !== "" ? WeatherSampler.place : qsTranslate("Weather", "Current Location")
    readonly property string tempText: WeatherLogic.tempText(current ? WeatherLogic.pick({c: current.tempC, f: current.tempF}, fahrenheit) : null)
    readonly property string rangeText: report && report.high && report.low ? qsTranslate("Weather", "H:%1 L:%2").arg(WeatherLogic.tempText(WeatherLogic.pick(report.high, fahrenheit))).arg(WeatherLogic.tempText(WeatherLogic.pick(report.low, fahrenheit))) : ""
    // The line under the symbol: the condition, or what keeps it from being known.
    readonly property string conditionText: {
        if (status === "unavailable")
            return qsTranslate("Weather", "Weather unavailable");
        if (!report)
            return root.preview ? "" : qsTranslate("Weather", "Loading…");
        return root.conditionName(now.key, current.night);
    }
    // Now and the next forecast slots (medium).
    readonly property var columns: {
        if (!report)
            return [];
        const out = [{label: qsTranslate("Weather", "Now"), symbol: now.symbol, temp: tempText}];
        const hours = report.hours.slice(0, Tokens.widgetWeatherHours - 1);
        for (const h of hours)
            out.push({label: root.hourLabel(h.minutes), symbol: WeatherLogic.condition(h.code, h.night).symbol, temp: WeatherLogic.tempText(WeatherLogic.pick(h, fahrenheit))});
        return out;
    }
    readonly property color valueColor: greyed ? Appearance.colors.textSecondary : Appearance.colors.text

    Accessible.role: Accessible.StaticText
    Accessible.name: report ? qsTranslate("Weather", "Weather, %1, %2, %3").arg(placeText).arg(tempText).arg(conditionText) + (rangeText !== "" ? ", " + rangeText : "") : qsTranslate("Weather", "Weather, %1").arg(conditionText !== "" ? conditionText : placeText)

    // macOS's names of the conditions (Weather.js keys).
    function conditionName(key: string, night: bool): string {
        switch (key) {
        case "clear":
            return night ? qsTranslate("Weather", "Clear") : qsTranslate("Weather", "Sunny");
        case "partlyCloudy":
            return qsTranslate("Weather", "Partly Cloudy");
        case "cloudy":
            return qsTranslate("Weather", "Cloudy");
        case "fog":
            return qsTranslate("Weather", "Fog");
        case "drizzle":
            return qsTranslate("Weather", "Drizzle");
        case "freezingDrizzle":
            return qsTranslate("Weather", "Freezing Drizzle");
        case "rain":
            return qsTranslate("Weather", "Rain");
        case "heavyRain":
            return qsTranslate("Weather", "Heavy Rain");
        case "freezingRain":
            return qsTranslate("Weather", "Freezing Rain");
        case "sleet":
            return qsTranslate("Weather", "Sleet");
        case "snow":
            return qsTranslate("Weather", "Snow");
        case "heavySnow":
            return qsTranslate("Weather", "Heavy Snow");
        case "blowingSnow":
            return qsTranslate("Weather", "Blowing Snow");
        case "blizzard":
            return qsTranslate("Weather", "Blizzard");
        case "thunderstorms":
            return qsTranslate("Weather", "Thunderstorms");
        }
        return "";
    }

    // A forecast slot's hour in the place's own time: "5PM" on a 12-hour clock (macOS), two digits on a 24-hour one ("03",
    // "03 h" in French).
    function hourLabel(minutes: int): string {
        const h = Math.floor(minutes / 60) % 24;
        if (root.twelveHours)
            return (h < 12 ? qsTranslate("Weather", "%1AM") : qsTranslate("Weather", "%1PM")).arg(h % 12 === 0 ? 12 : h % 12);
        return qsTranslate("Weather", "%1", "an hour of a 24-hour clock in the row of forecast hours").arg(String(h).padStart(2, "0"));
    }

    // Counts with the shared sampler while shown and placed. Deferred: the host gives `preview` and `active` just after the
    // widget is made, and a preview must never count, even for a moment (a count starts a fetch).
    property bool registered: false
    function register(): void {
        const want = root.active && !root.preview;
        if (want === registered)
            return;
        registered = want;
        WeatherSampler.users += want ? 1 : -1;
    }
    onActiveChanged: register()
    onPreviewChanged: register()
    Component.onCompleted: Qt.callLater(register)
    Component.onDestruction: {
        if (registered)
            WeatherSampler.users -= 1;
    }

    // The place, with the location arrow after it when the place is the IP address's (macOS: My Location).
    component Place: Row {
        id: placeRow

        property real maxWidth: 0

        spacing: Tokens.spacingXs

        WidgetLabel {
            id: placeLabel
            width: Math.min(implicitWidth, placeRow.maxWidth - (arrow.visible ? arrow.width + placeRow.spacing : 0))
            text: root.placeText
            size: Tokens.typographyTitleSize
            font.weight: Tokens.typographyTitleWeight
        }

        Icon {
            id: arrow
            anchors.verticalCenter: placeLabel.verticalCenter
            visible: WeatherSampler.byIp
            name: "location"
            size: Tokens.widgetWeatherArrowSize
            color: Appearance.colors.text
        }
    }

    // Top left: the place and the temperature (both sizes).
    Column {
        x: root.padding
        y: root.padding
        width: root.isSmall ? root.width - 2 * root.padding : (root.width - 2 * root.padding) / 2
        spacing: 0

        Place {
            maxWidth: parent.width
        }

        WidgetLabel {
            width: parent.width
            text: root.tempText
            size: Tokens.widgetWeatherTempSize
            font.weight: Tokens.typographySmallWeight
            color: root.valueColor
        }
    }

    // Small: the symbol, the condition and the high and low at the bottom left.
    Column {
        visible: root.isSmall
        x: root.padding
        y: root.height - root.padding - height
        width: root.width - 2 * root.padding
        spacing: Tokens.spacingXs

        Icon {
            visible: root.report !== null
            name: root.now.symbol
            size: Tokens.widgetWeatherSymbolSize
            color: root.valueColor
        }

        WidgetLabel {
            width: parent.width
            visible: text !== ""
            text: root.conditionText
            font.weight: Tokens.typographyTitleWeight
            color: root.greyed || !root.report ? Appearance.colors.textSecondary : Appearance.colors.text
        }

        WidgetLabel {
            width: parent.width
            visible: text !== ""
            text: root.rangeText
            font.weight: Tokens.typographyTitleWeight
            color: root.valueColor
        }
    }

    // Medium: the symbol, the condition and the high and low at the top right.
    Column {
        visible: root.isMedium
        x: root.width / 2
        y: root.padding
        width: root.width / 2 - root.padding
        spacing: Tokens.spacingXs

        Icon {
            anchors.right: parent.right
            visible: root.report !== null
            name: root.now.symbol
            size: Tokens.widgetWeatherSymbolSize
            color: root.valueColor
        }

        WidgetLabel {
            width: parent.width
            horizontalAlignment: Text.AlignRight
            visible: text !== ""
            text: root.conditionText
            font.weight: Tokens.typographyTitleWeight
            color: root.greyed || !root.report ? Appearance.colors.textSecondary : Appearance.colors.text
        }

        WidgetLabel {
            width: parent.width
            horizontalAlignment: Text.AlignRight
            visible: text !== ""
            text: root.rangeText
            font.weight: Tokens.typographyTitleWeight
            color: root.valueColor
        }
    }

    // Medium: Now and the next hours, evenly spread along the bottom.
    Row {
        visible: root.isMedium && root.columns.length > 0
        x: root.padding
        y: root.height - root.padding - height
        width: root.width - 2 * root.padding

        Repeater {
            model: root.columns

            Column {
                id: column

                required property var modelData

                width: (root.width - 2 * root.padding) / Math.max(1, Tokens.widgetWeatherHours)
                spacing: Tokens.spacingXs

                WidgetLabel {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: column.modelData.label
                    size: Tokens.typographyCaptionSize
                    font.weight: Tokens.typographyTitleWeight
                    color: Appearance.colors.textSecondary
                }

                Icon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: column.modelData.symbol
                    size: Tokens.widgetWeatherHourSymbolSize
                    color: root.valueColor
                }

                WidgetLabel {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: column.modelData.temp
                    font.weight: Tokens.typographyTitleWeight
                    color: root.valueColor
                }
            }
        }
    }
}
