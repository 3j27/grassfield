import QtQuick
import QtQuick.Templates as T
import Grassfield.Ui

// The search field of a Files toolbar: a 36-pt circle that expands to a capsule while it has the focus or text (macOS).
// The browser window's searches (ADR-0027: BrowserTab.setSearch shows a search location); the Open and Save panels'
// (FilePanel.qml) filters the shown folder. The toolbar's lifted white capsule (step 14's RimmedCapsule) as a button and once open, the
// shared focus ring outside it, and the shared field's clear button (ADR-0039 step 23).
RimmedCapsule {
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

    width: expanded ? root.expandedWidth : Tokens.toolbarCapsule
    height: Tokens.toolbarCapsule

    // A size that changes in place: the move curve (ADR-0039 step 20).
    Behavior on width {
        NumberAnimation {
            duration: Appearance.duration(Tokens.motionNormal)
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Appearance.curve
        }
    }

    FocusRing {
        shapeRadius: root.height / 2
        visible: search.activeFocus
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
        color: Appearance.windowSecondary
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
            color: Appearance.windowSecondary
            font: search.font
        }
    }

    // The shared field's clear button (SearchField): the text goes, the field keeps the focus.
    T.AbstractButton {
        id: clearButton
        objectName: "clearButton"
        visible: root.expanded && search.text !== ""
        width: Tokens.menuIconSize + Tokens.spacingSm
        height: parent.height
        anchors.right: parent.right
        anchors.rightMargin: Tokens.spacingXs
        focusPolicy: Qt.NoFocus
        hoverEnabled: true
        Accessible.role: Accessible.Button
        Accessible.name: qsTr("Clear search")
        onClicked: {
            root.tab.setSearch("");
            search.forceActiveFocus();
        }

        contentItem: Icon {
            name: "close-glyph"
            size: Tokens.menuIconSize - Tokens.spacingXs
            color: clearButton.hovered ? Appearance.colors.text : Appearance.windowSecondary
        }
    }
}
