import QtQuick
import QtQuick.Templates as T

// Push button (QtQuick.Templates Button). primary = accent fill (default action), destructive tints the label.
T.Button {
    id: root

    property bool primary: false
    property bool destructive: false
    // Alert style: a capsule, alertButtonHeight tall (a Dialog sets it on its buttons).
    property bool capsule: false
    // macOS push button: buttonHeight (24) tall instead of the roomier default (a sheet sets it on its buttons).
    property bool push: false

    // Whole pixels, so that a row of buttons keeps every edge sharp.
    implicitWidth: Math.ceil(Math.max(Tokens.controlButtonMinWidth, label.implicitWidth + 2 * Tokens.spacingLg))
    implicitHeight: root.capsule ? Tokens.controlAlertButtonHeight : (root.push ? Tokens.controlButtonHeight : Tokens.menuItemHeight + Tokens.spacingSm)
    // Disabled: the whole button dims, once (callers no longer set an opacity of their own).
    opacity: root.enabled ? 1 : Tokens.materialDisabledOpacity
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    Accessible.role: Accessible.Button
    Accessible.name: root.text
    // An assistive technology's press (AT-SPI "press" action) goes through the same guard as the keys and the pointer.
    Accessible.onPressAction: root.activate()
    // A hidden or disabled Button ignores the assistive-technology toggle as well (main's Button did).
    Accessible.onToggleAction: root.activate()

    // The Button's only way to act for the keys and the accessibility press: a hidden or disabled Button never acts, whatever
    // asks or still holds the focus (R12: the polkit sheet's Allow). Returns whether it acted.
    function activate(): bool {
        if (!root.visible || !root.enabled)
            return false;
        root.clicked();
        return true;
    }

    Keys.onPressed: event => {
        if (!ActivationKeys.activation(event.key))
            return;
        // A hidden or disabled button never acts (activate()); its activation keys are swallowed all the same (they would
        // otherwise bubble up to a parent that acts on them). Every other key (Escape above all) propagates.
        root.activate();
        event.accepted = true;
    }

    background: Rectangle {
        radius: root.capsule ? height / 2 : Tokens.radiusControl
        color: root.primary ? Appearance.colors.selection : Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity)
        // Increase Contrast: the border token carries a stronger value then.
        border.width: Appearance.increaseContrast ? Tokens.controlBorderWidth : 0
        border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)

        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Appearance.withAlpha(Appearance.colors.hover, root.down ? Tokens.controlPressedOpacity : Tokens.materialHoverOpacity)
            visible: root.enabled && (root.hovered || root.down)
        }
    }

    contentItem: Text {
        id: label
        textFormat: Text.PlainText
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: root.text
        color: root.primary ? Appearance.colors.selectionText : (root.destructive ? Appearance.colors.danger : Appearance.colors.text)
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyMenuSize
        font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
        font.weight: Tokens.typographyMenuWeight
    }

    FocusRing {
        shapeRadius: root.capsule ? root.height / 2 : Tokens.radiusControl
        visible: root.visualFocus
    }
}
