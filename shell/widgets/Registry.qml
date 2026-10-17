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
        }
        return "";
    }

    function title(id: string): string {
        switch (id) {
        case "clock":
            return qsTr("Clock");
        case "calendar":
            return qsTr("Calendar");
        case "battery":
            return qsTr("Battery");
        case "nowplaying":
            return qsTr("Now Playing");
        case "system":
            return qsTr("System");
        }
        return id;
    }

    function sizeLabel(size: string): string {
        switch (size) {
        case "small":
            return qsTr("Small");
        case "medium":
            return qsTr("Medium");
        case "large":
            return qsTr("Large");
        }
        return size;
    }
}
