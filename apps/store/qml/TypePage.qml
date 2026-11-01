import QtQuick
import Grassfield.Ui

// The apps that open a type of document (ADR-0035 5c-3; spec SR6): what Files' "Search the Store" asks for when no
// application opens a document (`--page=type:<type>`). Those whose app data names the type come first, then those that
// open a parent of it (any text for a source file); "No apps in the Store open “…” documents." when there is none.
ScrollPage {
    id: root

    // StoreBackend::typeSearch: {type, description, apps}.
    property var search: ({})
    readonly property var apps: root.search.apps || []
    readonly property string description: root.search.description || root.search.type || ""

    signal opened(string id)

    title: root.apps.length > 0 ? qsTr("Apps for “%1” Documents").arg(root.description) : ""
    Accessible.role: Accessible.Pane
    Accessible.name: root.apps.length > 0 ? root.title : empty.text

    AppGrid {
        width: root.contentWidth
        apps: root.apps
        onOpened: id => root.opened(id)
    }

    Text {
        id: empty
        visible: root.apps.length === 0
        width: root.contentWidth
        topPadding: Tokens.storeEmptyTop
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: qsTr("No apps in the Store open “%1” documents.").arg(root.description)
        wrapMode: Text.Wrap
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamilyFor(Tokens.storeEmptyTextSize)
        font.pixelSize: Tokens.storeEmptyTextSize
        font.weight: Tokens.typographyMenuBoldWeight
        Accessible.role: Accessible.AlertMessage
        Accessible.name: text
    }
}
