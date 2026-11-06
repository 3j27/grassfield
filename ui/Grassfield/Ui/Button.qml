import QtQuick
import QtQuick.Templates as T

// Push button (QtQuick.Templates Button). primary = accent fill (default action), destructive tints the label; both = the
// destructive default, a red fill (colors.destructive) with its white label (UI audit 2026-11-05 U20).
T.Button {
    id: root

    property bool primary: false
    property bool destructive: false
    // Alert style: a capsule, alertButtonHeight tall (a Dialog sets it on its buttons).
    property bool capsule: false
    // macOS 27 push button: a capsule as wide as its label instead of the default's wider rounded rectangle (a row's "Set…").
    property bool push: false
    // macOS 27 sheet button (Print, Open): as tall and as wide as a push button, a rounded rectangle with the
    // control.sheetButtonRadius corner instead of the capsule (the shared Sheet and the shell's sheets set it; ADR-0039 step 10).
    property bool sheet: false
    // The default button is accent only while the window looks key, inside an app window (Appearance.accentShown, UI audit 2026-11-05 U17).
    readonly property bool keyLook: Appearance.accentShown(root.Window.window, root.Window.active)
    // Drawn as the default button: `primary`, and its window looks key (otherwise a plain push button, macOS 27).
    readonly property bool accentFill: root.primary && root.keyLook
    // The corner of the shape: a capsule's half height, a sheet button's own corner, or the control radius.
    readonly property real shapeRadius: root.capsule || root.push ? root.height / 2 : (root.sheet ? Tokens.controlSheetButtonRadius : Tokens.radiusControl)

    // Whole pixels, so that a row of buttons keeps every edge sharp. A push or sheet button is as wide as its label and its padding.
    implicitWidth: root.push || root.sheet ? Math.ceil(label.implicitWidth + 2 * Tokens.controlPushPadding) : Math.ceil(Math.max(Tokens.controlButtonMinWidth, label.implicitWidth + 2 * Tokens.spacingLg))
    // One height for every push button (macOS 27: 24), the alert capsule's own 28 apart (UI audit 2026-11-05 U19: the default
    // form was 32, so a row with one stood taller than a row with a pop-up or a field).
    implicitHeight: root.capsule ? Tokens.controlAlertButtonHeight : Tokens.controlButtonHeight
    // Disabled: the whole button dims, once (callers no longer set an opacity of their own).
    opacity: Appearance.dimsDisabled(root) ? Tokens.materialDisabledOpacity : 1
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
        radius: root.shapeRadius
        color: root.accentFill ? (root.destructive ? Appearance.colors.destructive : Appearance.colors.selection) : Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity)
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
        color: root.accentFill ? (root.destructive ? Appearance.colors.destructiveText : Appearance.colors.selectionText) : (root.destructive ? Appearance.colors.danger : Appearance.colors.text)
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyMenuSize
        font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
        font.weight: Tokens.typographyMenuWeight
    }

    FocusRing {
        shapeRadius: root.shapeRadius
        visible: root.visualFocus
    }
}
