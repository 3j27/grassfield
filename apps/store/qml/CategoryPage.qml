import QtQuick
import Grassfield.Ui
import "Store.js" as Store

// One category (spec SR8): its apps by name, and a source filter (All, then each source present) when there is more than one.
ScrollPage {
    id: root

    property string categoryTitle: ""
    property var apps: []
    property string kind: ""

    signal opened(string id)
    signal kindPicked(string kind)

    readonly property var kinds: Store.kindsIn(root.apps)
    readonly property var shown: root.kind === "" ? root.apps : root.apps.filter(a => a.kind === root.kind)

    title: root.categoryTitle
    Accessible.role: Accessible.Pane
    Accessible.name: root.title

    SegmentedControl {
        visible: root.kinds.length > 1
        accessibleName: qsTr("Source")
        model: [{id: "", text: qsTr("All")}].concat(root.kinds.map(k => ({id: k, text: Store.kindTitle(k)})))
        value: root.kind
        onPicked: id => root.kindPicked(id)
    }

    AppGrid {
        width: root.contentWidth
        apps: root.shown
        onOpened: id => root.opened(id)
    }
}
