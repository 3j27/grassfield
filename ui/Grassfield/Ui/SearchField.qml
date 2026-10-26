import QtQuick
import QtQuick.Templates as T

// Search field: a capsule TextField (macOS) with the search glyph on its left and a clear button on its right while there is text.
// Escape clears the text first (a second Escape propagates, so a window can close on it); `cleared()` reports it.
TextField {
    id: root

    signal cleared

    fieldRadius: height / 2
    fieldColor: Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity)
    fieldBorder: false
    leftPadding: Tokens.spacingSm + Tokens.menuIconSize + Tokens.spacingSm
    rightPadding: Tokens.spacingSm + (clearButton.visible ? Tokens.menuIconSize + Tokens.spacingSm : 0)
    placeholderText: qsTr("Search")
    inputMethodHints: Qt.ImhNoPredictiveText
    Accessible.searchEdit: true

    function clear(): void {
        if (root.text === "")
            return;
        root.text = "";
        root.cleared();
    }

    Keys.onEscapePressed: event => {
        // A hidden or disabled field does not act on Escape: it propagates (to the dialog around it).
        if (root.text !== "" && root.visible && root.enabled) {
            root.clear();
            event.accepted = true;
        } else {
            event.accepted = false;
        }
    }

    Icon {
        name: "search"
        size: Tokens.menuIconSize
        color: Appearance.colors.textSecondary
        x: Tokens.spacingSm
        anchors.verticalCenter: parent.verticalCenter
    }

    T.AbstractButton {
        id: clearButton
        objectName: "clearButton"
        visible: root.text !== "" && root.enabled
        width: Tokens.menuIconSize + Tokens.spacingSm
        height: parent.height
        anchors.right: parent.right
        focusPolicy: Qt.NoFocus
        hoverEnabled: true
        Accessible.role: Accessible.Button
        Accessible.name: qsTr("Clear search")
        onClicked: root.clear()

        contentItem: Icon {
            name: "close-glyph"
            size: Tokens.menuIconSize - Tokens.spacingXs
            color: clearButton.hovered ? Appearance.colors.text : Appearance.colors.textSecondary
        }
    }
}
