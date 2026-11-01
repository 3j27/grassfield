import QtQuick
import Grassfield.Ui

// The search field of a Files toolbar: a 36-pt circle that expands to a capsule while it has the focus or text (macOS).
// The browser window's searches (ADR-0027: BrowserTab.setSearch shows a search location); the Open and Save panels'
// (FilePanel.qml) filters the shown folder.
Rectangle {
    id: root

    // The BrowserTab it searches (null: nothing to search).
    required property var tab

    // Open: it has the focus or text.
    readonly property bool expanded: search.activeFocus || search.text !== ""
    // Its width when open (the browser window widens it while a search is shown: FP-22).
    property real expandedWidth: Tokens.filesSearchWidth

    function focusField(): void {
        search.forceActiveFocus();
    }

    width: expanded ? root.expandedWidth : Tokens.filesToolbarCapsule
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
        anchors.right: clearButton.visible ? clearButton.left : parent.right
        anchors.rightMargin: clearButton.visible ? 0 : Tokens.spacingSm
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
        Accessible.name: root.tab && root.tab.chooser ? qsTr("Search in this folder") : qsTr("Search")
        Accessible.searchEdit: true

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
                root.tab.setSearch("");
                root.tab.focusView();
                event.accepted = true;
            } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (!root.tab.chooser)
                    root.tab.flushSearch();
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

    // Clears the field (and ends a typed search), as the shared SearchField's clear button.
    MouseArea {
        id: clearButton
        visible: root.expanded && search.text !== ""
        width: Tokens.menuIconSize + Tokens.spacingSm
        height: parent.height
        anchors.right: parent.right
        anchors.rightMargin: Tokens.spacingXs
        Accessible.role: Accessible.Button
        Accessible.name: qsTr("Clear search")
        Accessible.onPressAction: root.tab.setSearch("")
        onClicked: {
            root.tab.setSearch("");
            search.forceActiveFocus();
        }

        Icon {
            anchors.centerIn: parent
            name: "close-glyph"
            size: Tokens.menuIconSize - Tokens.spacingXs
            color: Appearance.colors.textSecondary
        }
    }
}
