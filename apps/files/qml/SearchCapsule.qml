import QtQuick
import Grassfield.Ui

// The search field of a Files toolbar (it filters the shown folder): a 36-pt circle that expands to a capsule while it has the
// focus or text (macOS). The browser window's and the Open and Save panels' (FilePanel.qml).
Rectangle {
    id: root

    // The BrowserTab it searches (null: nothing to search).
    required property var tab

    // Open: it has the focus or text.
    readonly property bool expanded: search.activeFocus || search.text !== ""

    function focusField(): void {
        search.forceActiveFocus();
    }

    width: expanded ? Tokens.filesSearchWidth : Tokens.filesToolbarCapsule
    height: Tokens.filesToolbarCapsule
    radius: height / 2
    color: Appearance.buttonFill
    border.width: search.activeFocus ? Tokens.controlFocusOutline : 0
    border.color: Appearance.focusRingColor
    clip: true

    Behavior on width {
        NumberAnimation {
            duration: Appearance.duration(Tokens.motionNormal)
            easing.type: Easing.OutQuad
        }
    }

    // A click on the collapsed circle opens it.
    MouseArea {
        anchors.fill: parent
        enabled: !root.expanded
        cursorShape: Qt.ArrowCursor
        onClicked: search.forceActiveFocus()
    }

    Icon {
        id: searchIcon
        name: "search"
        size: Tokens.menuIconSize
        color: Appearance.colors.textSecondary
        x: root.expanded ? Tokens.spacingMd : (root.width - width) / 2
        anchors.verticalCenter: parent.verticalCenter
    }

    TextInput {
        id: search
        TextCursor {}
        anchors.left: searchIcon.right
        anchors.leftMargin: Tokens.spacingXs
        anchors.right: parent.right
        anchors.rightMargin: Tokens.spacingSm
        anchors.verticalCenter: parent.verticalCenter
        clip: true
        opacity: root.expanded ? 1 : 0
        activeFocusOnTab: true
        color: Appearance.colors.text
        selectionColor: Appearance.highlight
        selectedTextColor: Appearance.highlightText
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
        text: root.tab ? root.tab.searchText : ""
        onTextEdited: root.tab.setSearch(text)
        Accessible.role: Accessible.EditableText
        Accessible.name: qsTr("Search in this folder")
        Accessible.searchEdit: true

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
                root.tab.setSearch("");
                root.tab.focusView();
                event.accepted = true;
            } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (root.tab.activeFolder.count > 0 && root.tab.activeFolder.selectedCount === 0)
                    root.tab.activeFolder.select(0, 0);
                root.tab.focusView();
                event.accepted = true;
            }
        }

        Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            visible: search.text === ""
            text: qsTr("Search")
            color: Appearance.colors.textSecondary
            font: search.font
        }
    }
}
