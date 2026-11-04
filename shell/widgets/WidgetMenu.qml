import QtQuick
import Grassfield.Ui

// Context menu of a placed widget: the Weather widget's Edit Location…, its sizes (current one checked), the keyboard moves
// and Remove Widget. `action` carries "weather:location", "size:<size>", "move:<left|right|up|down>" or "remove". `moves` ({direction: enabled}) lists the moves
// this place offers: the four directions on the desktop grid, up and down in the Notifications panel (GF-106: a widget can
// be moved without the pointer); empty offers none.
PopupMenu {
    id: root

    required property var entry
    property var moves: ({})

    signal choose(string action)

    accessibleName: qsTr("Widget menu")
    // No row highlighted until the pointer or a key selects one (macOS).
    currentIndex: -1

    model: {
        const items = [];
        // A widget's own edit item first, as macOS puts "Edit “Weather”": the Weather widget's place (ADR-0045 OC-14), only
        // when Omarchy's omarchy-weather-location is there to save it.
        if (entry.id === "weather" && WeatherSampler.canEditLocation) {
            items.push({id: "weather:location", text: qsTr("Edit Location…")});
            items.push({separator: true});
        }
        const sizes = Registry.sizesOf(entry.id);
        for (let i = 0; i < sizes.length; i++)
            items.push({
                id: "size:" + sizes[i],
                text: Registry.sizeLabel(sizes[i]),
                checked: sizes[i] === entry.size
            });
        const labels = {left: qsTr("Move Left"), right: qsTr("Move Right"), up: qsTr("Move Up"), down: qsTr("Move Down")};
        const dirs = Object.keys(labels).filter(d => d in moves);
        if (dirs.length > 0) {
            items.push({
                separator: true
            });
            for (const d of dirs)
                items.push({id: "move:" + d, text: labels[d], enabled: moves[d] === true});
        }
        items.push({
            separator: true
        });
        items.push({
            id: "remove",
            text: qsTr("Remove Widget"),
            destructive: true
        });
        return items;
    }

    onActivated: item => root.choose(String(item.id))
}
