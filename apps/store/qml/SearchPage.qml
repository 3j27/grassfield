import QtQuick
import Grassfield.Ui

// The search results (spec SR6): local, while typing, best first; "No Results for “…”" when there are none.
ScrollPage {
    id: root

    property string query: ""
    property var results: []

    signal opened(string id)

    title: root.results.length > 0 ? qsTr("Results for “%1”").arg(root.query) : ""
    Accessible.role: Accessible.Pane
    Accessible.name: root.results.length > 0 ? root.title : empty.text

    function focusFirst(): void {
        grid.focusItem(0);
    }

    AppGrid {
        id: grid
        width: root.contentWidth
        apps: root.results
        onOpened: id => root.opened(id)
    }

    Text {
        id: empty
        visible: root.results.length === 0
        width: root.contentWidth
        topPadding: Tokens.storeEmptyTop
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: qsTr("No Results for “%1”").arg(root.query)
        wrapMode: Text.Wrap
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamilyFor(Tokens.storeEmptyTextSize)
        font.pixelSize: Tokens.storeEmptyTextSize
        font.weight: Tokens.typographyMenuBoldWeight
        Accessible.role: Accessible.AlertMessage
        Accessible.name: text
    }
}
