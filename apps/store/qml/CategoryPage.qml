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
        visible: root.shown.length > 0
        width: root.contentWidth
        apps: root.shown
        onOpened: id => root.opened(id)
    }

    // An empty category says so, as the Installed page does (ADR-0039 step 24): no apps of its own, or none from the chosen
    // source.
    Text {
        visible: root.shown.length === 0
        width: root.contentWidth
        topPadding: Tokens.storeEmptyTop
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: root.apps.length === 0 ? qsTr("No apps in this category.") : qsTr("No apps from this source in this category.")
        wrapMode: Text.Wrap
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
        Accessible.role: Accessible.StaticText
        Accessible.name: text
    }
}
