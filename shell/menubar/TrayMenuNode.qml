pragma ComponentBehavior: Bound
import QtQuick
import Quickshell

// One level of a status item's DBusMenu as PopupMenu rows: `rows` is [{text, enabled, checked, separator, submenu, entry}],
// `entry` is the DBusMenu entry a choice triggers. Submenus are nested nodes (a handful of levels at most), opened (and
// announced to the application with AboutToShow) by their QsMenuOpener as soon as the parent's rows exist.
Item {
    id: node

    // QsMenuHandle: the item's menu (null: no rows) or the entry that owns a submenu.
    property var handle: null
    property int depth: 0
    readonly property int maxDepth: 4

    readonly property var entries: opener.children ? opener.children.values : []
    // Bumped when a child node appears or goes: `rows` reads the nodes, which are not properties.
    property int childrenRevision: 0
    readonly property var rows: {
        node.childrenRevision;
        const out = [];
        for (let i = 0; i < node.entries.length; i++) {
            const e = node.entries[i];
            if (e.isSeparator) {
                out.push({separator: true});
                continue;
            }
            const row = {
                text: e.text,
                enabled: e.enabled,
                // Qt.Checked is 2; a plain entry (buttonType None) shows no mark.
                checked: e.buttonType !== 0 && e.checkState === 2,
                entry: e
            };
            if (e.hasChildren && node.depth < node.maxDepth) {
                const child = kids.objectAt(i) as Slot;
                row.submenu = child ? child.rows : [];
            }
            out.push(row);
        }
        return out;
    }

    // The loader of a submenu's own node and the rows it produced.
    component Slot: Loader {
        required property var modelData
        readonly property var rows: item ? (item as TrayMenuNode).rows : []
    }

    QsMenuOpener {
        id: opener
        menu: node.handle
    }

    Instantiator {
        id: kids
        model: node.depth < node.maxDepth ? node.entries : []
        onObjectAdded: node.childrenRevision++
        onObjectRemoved: node.childrenRevision++

        delegate: Slot {
            id: slot

            active: slot.modelData.hasChildren
            source: "TrayMenuNode.qml"
            onLoaded: {
                const n = item as TrayMenuNode;
                n.handle = slot.modelData;
                n.depth = node.depth + 1;
            }
        }
    }
}
