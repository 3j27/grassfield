import QtQuick
import QtQuick.Templates as T

// Search field (macOS 27, an app window's sidebar and toolbar): a RimmedCapsule without an outline: the sidebar's is a flat
// grey field, a toolbar's (`toolbar: true`) a white capsule lifted by a soft shadow like the other toolbar items; toolbar.searchHeight tall, the search glyph on its left and a clear button on its
// right while there is text (ADR-0039 step 14: the one search field of Settings, Activity Monitor and the shared controls).
// Escape clears the text first (a second Escape propagates, so a window can close on it); `cleared()` reports it.
TextField {
    id: root

    signal cleared

    // In a window's toolbar: a lifted white capsule instead of the sidebar's flat field.
    property bool toolbar: false

    implicitHeight: Tokens.toolbarSearchHeight
    fieldRadius: height / 2
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

    background: RimmedCapsule {
        field: !root.toolbar

        FocusRing {
            shapeRadius: root.fieldRadius
            visible: root.activeFocus
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
