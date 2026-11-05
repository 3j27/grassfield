pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import "Registry.js" as Data

// Static registry of the first-party widgets (widgets/1). v1 loads nothing else: a placement whose
// id is not listed here is dropped when widgets.json is read. Manifest data lives in Registry.js
// (mirroring builtin/<id>/manifest.json), the component of each id here.
QtObject {
    readonly property var manifests: Data.MANIFESTS

    function manifest(id: string): var {
        return Data.find(id);
    }

    function sizesOf(id: string): var {
        const m = Data.find(id);
        return m ? m.sizes : [];
    }

    // The widget component of a registered id; "" for an unknown one.
    function source(id: string): url {
        switch (id) {
        case "clock":
            return Qt.resolvedUrl("builtin/clock/Clock.qml");
        case "calendar":
            return Qt.resolvedUrl("builtin/calendar/Calendar.qml");
        case "battery":
            return Qt.resolvedUrl("builtin/battery/Battery.qml");
        case "nowplaying":
            return Qt.resolvedUrl("builtin/nowplaying/NowPlaying.qml");
        case "system":
            return Qt.resolvedUrl("builtin/system/System.qml");
        case "weather":
            return Qt.resolvedUrl("builtin/weather/Weather.qml");
        }
        return "";
    }

    // The names go through qsTranslate with this file's context, not qsTr: in the nested French session qsTr here returned the
    // English source for the first moments of the singleton's life (the gallery's first rows and the placed Clock stayed English
    // while qsTranslate("Registry", ...) in the same call gave the French text; probe of 2026-10-30). The context is the same, the
    // catalog entries too (lupdate reads qsTranslate). tests/shell/widgets_translate_guard.sh holds both files to it.
    function title(id: string): string {
        switch (id) {
        case "clock":
            return qsTranslate("Registry", "Clock");
        case "calendar":
            return qsTranslate("Registry", "Calendar");
        case "battery":
            return qsTranslate("Registry", "Battery");
        case "nowplaying":
            return qsTranslate("Registry", "Now Playing");
        case "system":
            return qsTranslate("Registry", "System");
        case "weather":
            return qsTranslate("Registry", "Weather");
        }
        return id;
    }

    // The gallery's line under a widget's name, for a widget whose data comes from outside this computer; "" otherwise.
    function description(id: string): string {
        switch (id) {
        case "weather":
            // ADR-0045 OC-14: the gallery says where the weather comes from, and where the place comes from.
            return qsTranslate("Registry", "Weather from wttr.in, for the place saved in Omarchy, or else the place wttr.in finds from your IP address.");
        }
        return "";
    }

    function sizeLabel(size: string): string {
        switch (size) {
        case "small":
            return qsTranslate("Registry", "Small");
        case "medium":
            return qsTranslate("Registry", "Medium");
        case "large":
            return qsTranslate("Registry", "Large");
        }
        return size;
    }
}
