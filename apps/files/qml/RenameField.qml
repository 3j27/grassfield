import QtQuick
import Grassfield.Ui

// Inline name editor. Opens with the name selected up to its extension (folders: the whole name).
// Return or leaving the field commits, Esc cancels.
Rectangle {
    id: root

    property string originalName: ""
    property int baseLength: originalName.length
    property int horizontalAlignment: TextInput.AlignLeft
    property bool done: false

    signal committed(string name)
    signal canceled

    implicitHeight: input.implicitHeight + 2 * Tokens.spacingXs / 2
    radius: Tokens.radiusControl / 2
    color: Appearance.windowFill
    border.width: Tokens.controlFocusOutline
    border.color: Appearance.focusRingColor

    function finish(commit: bool): void {
        if (root.done)
            return;
        root.done = true;
        if (commit)
            root.committed(input.text);
        else
            root.canceled();
    }

    TextInput {
        id: input
        TextCursor {}
        anchors.fill: parent
        anchors.leftMargin: Tokens.spacingXs
        anchors.rightMargin: Tokens.spacingXs
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: root.horizontalAlignment
        text: root.originalName
        clip: true
        focus: true
        selectByMouse: true
        color: Appearance.colors.text
        selectionColor: Appearance.highlight
        selectedTextColor: Appearance.highlightText
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.filesIconLabelSize
        Accessible.role: Accessible.EditableText
        Accessible.name: qsTr("Name")

        Component.onCompleted: {
            input.forceActiveFocus();
            input.select(0, Math.min(root.baseLength, input.text.length));
        }
        onActiveFocusChanged: if (!activeFocus) root.finish(true)
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.finish(true);
                event.accepted = true;
            } else if (event.key === Qt.Key_Escape) {
                root.finish(false);
                event.accepted = true;
            } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                root.finish(true);
                event.accepted = true;
            }
        }
    }
}
