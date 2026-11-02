import QtQuick
import QtQuick.Window
import Grassfield.Ui
import "Store.js" as Store

// An app in a row, a list or the search results (spec SR5): its icon, name, summary and source, and its button. A click,
// Return or Space opens its product page (an item without one, such as a web app our catalog does not list, opens nothing).
FocusScope {
    id: root

    required property var app
    property real iconSize: Tokens.storeLockupIconSize
    property bool showButton: true
    property bool separator: true
    readonly property bool openable: root.app && root.app.page !== false
    // The focus ring is for the keyboard: a click that gives the focus shows none (macOS).
    property bool clicked: false

    signal opened(string id)

    implicitHeight: Math.max(root.iconSize, texts.implicitHeight) + 2 * Tokens.storeLockupPadding
    activeFocusOnTab: root.openable
    Accessible.role: Accessible.Button
    Accessible.name: [root.app.name, Store.sourceLabel(root.app.kind, root.app.repo), root.app.summary].filter(t => t && t !== "").join(", ")
    Accessible.onPressAction: root.open()

    onActiveFocusChanged: if (!activeFocus)
        root.clicked = false

    function open(): void {
        if (root.openable)
            root.opened(root.app.id);
    }

    Keys.onPressed: event => {
        if (ActivationKeys.activation(event.key)) {
            root.open();
            event.accepted = true;
        }
    }

    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: -Tokens.storeLockupHoverInset
        anchors.rightMargin: -Tokens.storeLockupHoverInset
        radius: Tokens.storeLockupHoverRadius
        color: Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity)
        visible: root.openable && hover.hovered
    }

    FocusRing {
        anchors.leftMargin: -Tokens.storeLockupHoverInset - Tokens.controlFocusOutline
        anchors.rightMargin: -Tokens.storeLockupHoverInset - Tokens.controlFocusOutline
        shapeRadius: Tokens.storeLockupHoverRadius
        visible: root.activeFocus && !root.clicked
    }

    AppIcon {
        id: icon
        x: 0
        anchors.verticalCenter: parent.verticalCenter
        size: root.iconSize
        source: root.app.icon || ""
    }

    Column {
        id: texts
        anchors {
            left: icon.right
            leftMargin: Tokens.storeLockupGap
            right: button.visible ? button.left : parent.right
            rightMargin: button.visible ? Tokens.storeLockupGap : 0
            verticalCenter: parent.verticalCenter
        }
        spacing: Tokens.storeLockupLineGap

        Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.app.name
            elide: Text.ElideRight
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.storeLockupNameSize
            font.weight: Tokens.storeLockupNameWeight
            font.letterSpacing: Appearance.tracking(Tokens.storeLockupNameSize)
        }

        Text {
            width: parent.width
            visible: text !== ""
            textFormat: Text.PlainText
            text: root.app.summary || ""
            elide: Text.ElideRight
            color: Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.storeLockupSummarySize
            font.letterSpacing: Appearance.tracking(Tokens.storeLockupSummarySize)
        }

        SourceBadge {
            width: parent.width
            kind: root.app.kind
            repo: root.app.repo || ""
            extra: Store.aurLine(root.app)
        }
    }

    StoreButton {
        id: button
        visible: root.showButton && root.app.kind !== "foreign"
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        app: root.app
    }

    Rectangle {
        visible: root.separator
        anchors.left: texts.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        // One point, as every separator of the apps (ADR-0039 D5, step 24; it was one device pixel).
        height: Tokens.appsBorderWidth
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    HoverHandler {
        id: hover
    }

    TapHandler {
        onTapped: {
            root.clicked = true;
            root.forceActiveFocus(Qt.MouseFocusReason);
            root.open();
        }
    }

    // The context menu of an installed app (spec SR22: Open, Show in Store, Uninstall…), from the window (Main.qml).
    readonly property var host: root.Window.window
    TapHandler {
        acceptedButtons: Qt.RightButton
        onTapped: eventPoint => {
            if (root.host && root.host.showAppMenu !== undefined)
                root.host.showAppMenu(root.app, root, eventPoint.position.x, eventPoint.position.y);
        }
    }
}
