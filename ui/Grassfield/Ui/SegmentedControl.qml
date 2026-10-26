pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Templates as T

// Segmented choice of 2-4 options (QtQuick.Templates Control + one AbstractButton per segment): a light track with the
// selected segment as a raised pill and ordinary text (macOS 27; the accent marks selection in lists and menus only). model: [{id, text}];
// value is the selected id (the host owns it: the control only reports `picked(id)`); Left/Right/Up/Down step through the
// segments. Each segment is a RadioButton for assistive technology.
T.Control {
    id: root

    property var model: []
    property string value: ""
    property string accessibleName: ""

    signal picked(string id)

    readonly property int currentIndex: {
        for (let i = 0; i < root.model.length; i++) {
            if (root.model[i].id === root.value)
                return i;
        }
        return -1;
    }

    implicitWidth: row.implicitWidth
    implicitHeight: Tokens.menuItemHeight + Tokens.spacingSm
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    Accessible.role: Accessible.Grouping
    Accessible.name: root.accessibleName
    Accessible.description: root.currentIndex >= 0 ? root.model[root.currentIndex].text : ""
    Accessible.focusable: true

    function step(direction: int): void {
        if (root.model.length === 0)
            return;
        const next = Math.max(0, Math.min(root.model.length - 1, (root.currentIndex < 0 ? 0 : root.currentIndex) + direction));
        if (next !== root.currentIndex)
            root.picked(root.model[next].id);
    }

    Keys.onPressed: event => {
        if (!root.visible || !root.enabled) {
            event.accepted = ActivationKeys.navigation(event.key);
            return;
        }
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
            root.step(-1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
            root.step(1);
            event.accepted = true;
        }
    }

    // The selected pill sits this far inside the track, on whole pixels, with a concentric radius.
    readonly property int pillInset: 2

    background: Rectangle {
        radius: Tokens.radiusControl
        color: Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity)
        border.width: Appearance.increaseContrast ? Tokens.controlBorderWidth : 0
        border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
    }

    contentItem: Row {
        id: row

        Repeater {
            model: root.model

            delegate: T.AbstractButton {
                id: segment

                required property var modelData
                required property int index
                readonly property bool selected: segment.index === root.currentIndex

                width: Math.ceil(label.implicitWidth + 2 * Tokens.spacingLg)
                height: root.height
                text: segment.modelData.text
                hoverEnabled: true
                // One tab stop for the whole control (the arrow keys move inside it).
                focusPolicy: Qt.NoFocus
                Accessible.role: Accessible.RadioButton
                Accessible.name: segment.modelData.text
                Accessible.checkable: true
                Accessible.checked: segment.selected
                Accessible.onPressAction: if (segment.visible && segment.enabled && root.visible && root.enabled)
                    root.picked(segment.modelData.id)
                Accessible.onToggleAction: if (segment.visible && segment.enabled && root.visible && root.enabled)
                    root.picked(segment.modelData.id)
                onClicked: {
                    root.forceActiveFocus();
                    root.picked(segment.modelData.id);
                }

                background: Item {
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: root.pillInset
                        radius: Tokens.radiusControl - root.pillInset
                        // Selected: a raised pill (white in the light appearance, a lighter grey in the dark one) with a fine
                        // edge; otherwise the hover and press shades.
                        color: segment.selected ? (Appearance.dark ? Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity * 2) : Appearance.colors.windowBackground)
                            : Appearance.withAlpha(Appearance.colors.hover, segment.down ? Tokens.controlPressedOpacity : Tokens.materialHoverOpacity)
                        border.width: segment.selected ? Tokens.controlBorderWidth : 0
                        border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Appearance.separatorOpacity)
                        visible: segment.selected || (root.enabled && (segment.hovered || segment.down))
                    }
                }

                contentItem: Text {
                    id: label
                    textFormat: Text.PlainText
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: segment.text
                    opacity: root.enabled ? 1 : Tokens.materialDisabledOpacity
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyMenuSize
                    font.weight: Tokens.typographyMenuWeight
                }
            }
        }
    }

    FocusGuard {}

    FocusRing {
        visible: root.visualFocus
    }
}
