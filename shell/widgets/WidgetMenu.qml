import QtQuick
import Grassfield.Ui

// Context menu of a placed widget: its sizes (current one checked) and Remove Widget.
// `action` carries "size:<size>" or "remove".
PopupMenu {
    id: root

    required property var entry

    signal choose(string action)

    accessibleName: qsTr("Widget menu")
    currentIndex: 0

    model: {
        const items = [];
        const sizes = Registry.sizesOf(entry.id);
        for (let i = 0; i < sizes.length; i++)
            items.push({id: "size:" + sizes[i], text: Registry.sizeLabel(sizes[i]), checked: sizes[i] === entry.size});
        items.push({separator: true});
        items.push({id: "remove", text: qsTr("Remove Widget"), destructive: true});
        return items;
    }

    onActivated: item => root.choose(String(item.id))
}
