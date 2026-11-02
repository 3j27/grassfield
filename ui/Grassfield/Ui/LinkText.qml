import QtQuick

// A link drawn as underlined plain text (never rich text). It does not open anything itself: `activated` is the only way it
// acts, from the pointer, Return, Enter, Space or an assistive technology's press, so the host decides how an address is
// opened (as an argument vector, never a shell string). Visible keyboard focus: the shared ring around the text, after a key
// only (KeyFocus; ADR-0039 step 7).
Item {
    id: root

    property string text: ""
    // What the link goes to, read by assistive technologies ("Licence: CC BY-SA 4.0, https://...").
    property string target: ""
    property int maximumLineCount: 3

    signal activated

    readonly property bool hovered: mouse.containsMouse

    // The natural width comes from TextMetrics (one line), not from the wrapping Text, whose implicitWidth changes as it wraps.
    implicitWidth: Math.ceil(metrics.advanceWidth)
    implicitHeight: label.implicitHeight
    activeFocusOnTab: true
    Accessible.role: Accessible.Link
    Accessible.name: root.text
    Accessible.description: root.target
    Accessible.focusable: true
    // A hidden or disabled link never activates, by key or by assistive technology; a key it still holds the focus for is
    // swallowed (and FocusGuard hands the focus on).
    Accessible.onPressAction: if (root.visible && root.enabled)
        root.activated()

    Keys.onPressed: event => {
        if (ActivationKeys.activation(event.key)) {
            if (root.visible && root.enabled)
                root.activated();
            event.accepted = true;
        }
    }

    FocusGuard {}

    TextMetrics {
        id: metrics
        font: label.font
        text: root.text
    }

    KeyFocus {
        id: keyFocus
    }

    // The ring keeps a little room around the text.
    Item {
        anchors.fill: parent
        anchors.margins: -Tokens.spacingXs

        FocusRing {
            visible: keyFocus.active
        }
    }

    Text {
        id: label
        width: root.width
        textFormat: Text.PlainText
        wrapMode: Text.WrapAnywhere
        maximumLineCount: root.maximumLineCount
        elide: Text.ElideRight
        text: root.text
        font.underline: true
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            root.forceActiveFocus();
            root.activated();
        }
    }
}
