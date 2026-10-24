pragma ComponentBehavior: Bound
import QtQuick

// A row of colour swatches (the colour tags of Grassfield Files): each shows its state (0 off, 1 some, 2 on) with a
// mark, the hovered or keyboard-current one gets a ring, and a caption under the row names it. When the row is
// disabled the caption shows `caption` (the reason) instead.
// model: [{color, name, state}]. chosen(index) on a click, or on Return/Space for the current swatch.
// Keyboard (when it has the focus itself; PopupMenu drives currentIndex for its swatch rows): Left/Right move.
FocusScope {
    id: root

    property var model: []
    property int currentIndex: -1
    property int hoveredIndex: -1
    // Shown when nothing is hovered or current; when disabled, the reason.
    property string caption: ""
    property string accessibleName: ""

    signal chosen(int index)
    // The pointer entered a swatch (a host menu moves its keyboard cursor there).
    signal hoveredSwatch(int index)

    readonly property int markedIndex: root.hoveredIndex >= 0 ? root.hoveredIndex : root.currentIndex
    readonly property string captionText: !root.enabled || root.markedIndex < 0 || root.markedIndex >= root.model.length ? root.caption : root.model[root.markedIndex].name

    implicitWidth: Math.max(row.implicitWidth, label.implicitWidth) + 2 * Tokens.menuItemPadding
    implicitHeight: row.implicitHeight + label.implicitHeight + 3 * Tokens.spacingXs
    Accessible.role: Accessible.Grouping
    Accessible.name: root.accessibleName
    Accessible.description: root.enabled ? "" : root.caption

    // The row takes the focus: the ring starts on the chosen swatch (state 2), else on the first one, so the focus is
    // always visible (a custom colour selects no swatch).
    onActiveFocusChanged: {
        if (!root.activeFocus || !root.enabled || root.currentIndex >= 0 || root.model.length === 0)
            return;
        let start = 0;
        for (let i = 0; i < root.model.length; i++) {
            if ((root.model[i].state ?? 0) === 2) {
                start = i;
                break;
            }
        }
        root.currentIndex = start;
    }

    Keys.onPressed: event => {
        const n = root.model.length;
        // A hidden or disabled row picks nothing; the activation keys and the arrows it still holds the focus for are swallowed
        // (Tab, Backtab and Escape are not).
        if (!root.visible || !root.enabled) {
            event.accepted = ActivationKeys.activation(event.key) || ActivationKeys.navigation(event.key);
            return;
        }
        if (n === 0)
            return;
        if (event.key === Qt.Key_Left) {
            root.currentIndex = root.currentIndex <= 0 ? n - 1 : root.currentIndex - 1;
            event.accepted = true;
        } else if (event.key === Qt.Key_Right) {
            root.currentIndex = (root.currentIndex + 1) % n;
            event.accepted = true;
        } else if (ActivationKeys.activation(event.key) && root.currentIndex >= 0) {
            root.chosen(root.currentIndex);
            event.accepted = true;
        }
    }

    FocusGuard {}

    Row {
        id: row
        x: Tokens.menuItemPadding
        y: Tokens.spacingXs
        spacing: Tokens.menuSwatchGap

        Repeater {
            model: root.model

            delegate: Item {
                id: swatch

                required property var modelData
                required property int index
                readonly property int mark: swatch.modelData.state ?? 0

                width: Tokens.menuSwatchSize + 2 * Tokens.menuSwatchRing
                height: width
                Accessible.role: Accessible.CheckBox
                Accessible.name: swatch.modelData.name
                Accessible.checkable: true
                Accessible.checked: swatch.mark === 2
                Accessible.onPressAction: if (root.enabled) root.chosen(swatch.index)

                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: "transparent"
                    border.width: Tokens.menuSwatchRing
                    border.color: Appearance.colors.text
                    visible: root.enabled && root.markedIndex === swatch.index
                }

                Rectangle {
                    anchors.centerIn: parent
                    width: Tokens.menuSwatchSize
                    height: width
                    radius: width / 2
                    color: swatch.modelData.color
                    opacity: root.enabled ? 1 : Tokens.materialDisabledOpacity
                    border.width: Tokens.appsBorderWidth
                    border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)

                    Icon {
                        anchors.centerIn: parent
                        visible: swatch.mark === 2
                        name: "checkmark"
                        size: Tokens.menuIconSize
                        color: Tokens.menuSwatchMark
                    }

                    // Some of the items have it.
                    Rectangle {
                        anchors.centerIn: parent
                        visible: swatch.mark === 1
                        width: parent.width / 2
                        height: Tokens.menuSwatchRing
                        radius: height / 2
                        color: Tokens.menuSwatchMark
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: root.enabled
                    onEntered: {
                        root.hoveredIndex = swatch.index;
                        root.hoveredSwatch(swatch.index);
                    }
                    onExited: {
                        if (root.hoveredIndex === swatch.index)
                            root.hoveredIndex = -1;
                    }
                    onClicked: root.chosen(swatch.index)
                }
            }
        }
    }

    Text {
        id: label
        textFormat: Text.PlainText
        x: Tokens.menuItemPadding
        y: row.y + row.height + Tokens.spacingXs
        width: root.width - 2 * Tokens.menuItemPadding
        text: root.captionText
        elide: Text.ElideRight
        color: Appearance.colors.textSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyCaptionSize
        font.letterSpacing: Appearance.tracking(Tokens.typographyCaptionSize)
    }
}
