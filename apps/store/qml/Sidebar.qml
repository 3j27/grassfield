pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Grassfield.Ui

// The Store's sidebar (spec SR1, macOS 27): flush with the window, the lights over it, the search field under them, then
// Discover, the catalog's sections, Categories and Updates (rows 38 pt apart, the glyph in the accent colour, the selected
// row a grey pill with its label in bold), and at the bottom the local user's row, which opens Installed.
FocusScope {
    id: root

    required property var win
    // The selected row's fill: the measured neutral while the window is key, the inactive selection while it is not (ADR-0039
    // step 24, as Settings' sidebar in step 17).
    readonly property color selectionFill: Appearance.looksKey(root.Window.window, root.Window.active) ? Appearance.withAlpha(Appearance.colors.text, Tokens.storeSidebarSelectionOpacity)
                                                              : Appearance.withAlpha(Appearance.colors.hover, Appearance.inactiveSelectionOpacity)
    // [{key, title, icon}]
    property var items: []
    property string selectedKey: ""
    property var user: ({})
    property bool installedShown: false
    readonly property alias search: search
    readonly property alias list: list

    signal picked(string key)
    signal accountPicked
    signal queryEdited(string text)
    signal queryAccepted

    width: Tokens.storeSidebarWidth

    function step(direction: int): void {
        let index = root.items.findIndex(i => i.key === root.selectedKey);
        index = Math.max(0, Math.min(root.items.length - 1, index + direction));
        if (root.items.length > 0)
            root.picked(root.items[index].key);
    }

    // Edge to edge and a step darker than the page, with no dividing line (macOS 27).
    Rectangle {
        anchors.fill: parent
        color: Appearance.colors.sidebarFill
    }

    UnifiedToolbar {
        id: toolbar
        width: parent.width
        window: root.win
        showTitle: false
        canMinimize: root.win.backend.canMinimize
        doubleClickAction: root.win.backend.titlebarDoubleClick
    }

    // The shared search field (ADR-0039 step 24: the rimmed 28-pt capsule with a clear button, Settings' field), centred in the
    // 29-pt slot measured on macOS 27 Discover. Return searches (and asks the AUR, SR7), Down moves to the list, Escape clears
    // the field and, once it is empty, leaves it for the list (SR6: the field lets that Escape through to its host here).
    Item {
        x: Tokens.storeSidebarInset
        y: Tokens.storeSidebarSearchTop
        width: parent.width - 2 * Tokens.storeSidebarInset
        height: Tokens.storeSidebarSearchHeight
        Keys.onEscapePressed: event => {
            list.forceActiveFocus();
            event.accepted = true;
        }

        SearchField {
            id: search
            width: parent.width
            anchors.verticalCenter: parent.verticalCenter
            activeFocusOnTab: true
            persistentSelection: true
            maximumLength: Tokens.storeSearchMaxLength
            accessibleName: qsTr("Search apps")
            onTextEdited: root.queryEdited(text)
            onCleared: root.queryEdited("")
            Keys.onReturnPressed: event => {
                root.queryAccepted();
                event.accepted = true;
            }
            Keys.onEnterPressed: event => {
                root.queryAccepted();
                event.accepted = true;
            }
            Keys.onDownPressed: event => {
                list.keyboardRing = true;
                list.forceActiveFocus();
                event.accepted = true;
            }
        }
    }

    ListView {
        id: list
        x: Tokens.storeSidebarInset
        y: Tokens.storeSidebarListTop
        width: parent.width - 2 * Tokens.storeSidebarInset
        height: account.y - y - Tokens.spacingSm
        model: root.items
        spacing: 0
        clip: true
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds
        keyNavigationEnabled: false
        activeFocusOnTab: true
        Accessible.role: Accessible.List
        Accessible.name: qsTr("Sidebar")

        // The ring is for the keyboard (macOS): it shows with the first key that moves the selection and goes with the focus.
        property bool keyboardRing: false
        onActiveFocusChanged: if (!activeFocus)
            keyboardRing = false

        Keys.onPressed: event => {
            keyboardRing = true;
            if (event.key === Qt.Key_Up) {
                root.step(-1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Down) {
                root.step(1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Home && root.items.length > 0) {
                root.picked(root.items[0].key);
                event.accepted = true;
            } else if (event.key === Qt.Key_End && root.items.length > 0) {
                root.picked(root.items[root.items.length - 1].key);
                event.accepted = true;
            }
        }

        delegate: Item {
            id: row
            required property var modelData
            required property int index
            readonly property bool selected: row.modelData.key === root.selectedKey

            // The number of apps with an update, on the Updates row (SR25: the Store's only count; no Dock badge, ST8).
            readonly property int count: row.modelData.count || 0

            width: ListView.view.width
            height: Tokens.storeSidebarRowHeight
            Accessible.role: Accessible.ListItem
            Accessible.name: row.count > 0 ? qsTr("%1, %2").arg(row.modelData.title).arg(row.count) : row.modelData.title
            Accessible.selectable: true
            Accessible.selected: row.selected
            Accessible.onPressAction: root.picked(row.modelData.key)

            Rectangle {
                anchors.fill: parent
                radius: Tokens.storeSidebarRowRadius
                // A window that is not key draws its selection lighter, as Settings' (ADR-0039 steps 17 and 24).
                color: row.selected ? root.selectionFill
                     : (hover.hovered ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent")
            }

            Rectangle {
                anchors.fill: parent
                anchors.margins: -Tokens.controlFocusOutline
                radius: Tokens.storeSidebarRowRadius + Tokens.controlFocusOutline
                visible: row.selected && list.activeFocus && list.keyboardRing
                color: "transparent"
                border.width: Tokens.controlFocusOutline
                border.color: Appearance.focusRingColor
            }

            Icon {
                id: glyph
                x: Math.round(Tokens.storeSidebarIconCentre - Tokens.storeSidebarInset - width / 2)
                anchors.verticalCenter: parent.verticalCenter
                name: row.modelData.icon
                size: Tokens.storeSidebarIconSize
                color: Appearance.colors.accentInk
            }

            Text {
                x: Tokens.storeSidebarLabelX - Tokens.storeSidebarInset
                anchors.verticalCenter: parent.verticalCenter
                width: (count.visible ? count.x - Tokens.spacingSm : parent.width - Tokens.spacingSm) - x
                textFormat: Text.PlainText
                text: row.modelData.title
                elide: Text.ElideRight
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.storeSidebarLabelSize
                // Regular when selected too, as Files and Settings (UI audit 2026-11-05, LOW): the pill marks it.
                font.weight: Tokens.typographyMenuWeight
                font.letterSpacing: Appearance.tracking(Tokens.storeSidebarLabelSize)
            }

            Text {
                id: count
                anchors.right: parent.right
                anchors.rightMargin: Tokens.spacingSm
                anchors.verticalCenter: parent.verticalCenter
                visible: row.count > 0
                textFormat: Text.PlainText
                text: row.count
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.storeSidebarLabelSize
                font.letterSpacing: Appearance.tracking(Tokens.storeSidebarLabelSize)
                font.features: {"tnum": 1}
            }

            HoverHandler {
                id: hover
            }

            TapHandler {
                onTapped: {
                    list.keyboardRing = false;
                    list.forceActiveFocus(Qt.MouseFocusReason);
                    root.picked(row.modelData.key);
                }
            }
        }
    }

    // The local user (SR1): the picture of AccountsService, else the initials in a grey circle, and the full name in bold.
    // It opens Installed: the closest real list to macOS's account page (there is no account).
    FocusScope {
        id: account
        x: Tokens.storeSidebarInset
        y: parent.height - Tokens.storeAccountBottom - Tokens.storeAccountCircle - (Tokens.storeAccountRowHeight - Tokens.storeAccountCircle) / 2
        width: parent.width - 2 * Tokens.storeSidebarInset
        height: Tokens.storeAccountRowHeight
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: qsTr("%1: Installed apps").arg(root.user.name || "")
        Accessible.onPressAction: root.accountPicked()
        Keys.onPressed: event => {
            if (ActivationKeys.activation(event.key)) {
                root.accountPicked();
                event.accepted = true;
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: Tokens.storeSidebarRowRadius
            color: root.installedShown ? root.selectionFill
                 : (accountHover.hovered ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent")
        }

        // The keyboard's ring only (ADR-0039 step 24, G7).
        FocusRing {
            shapeRadius: Tokens.storeSidebarRowRadius
            visible: accountFocus.active
        }

        KeyFocus {
            id: accountFocus
        }

        Rectangle {
            id: circle
            x: Tokens.storeAccountInset - Tokens.storeSidebarInset
            anchors.verticalCenter: parent.verticalCenter
            width: Tokens.storeAccountCircle
            height: width
            radius: width / 2
            color: Tokens.storeAccountCircleFill

            Text {
                anchors.centerIn: parent
                visible: picture.status !== Image.Ready
                textFormat: Text.PlainText
                text: root.user.initials || ""
                color: Tokens.storeAccountInitials
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.storeAccountInitialsSize
                font.weight: Tokens.typographyMenuBoldWeight
            }

            Image {
                id: picture
                anchors.fill: parent
                source: root.user.picture || ""
                sourceSize: Qt.size(width * 2, height * 2)
                asynchronous: true
                fillMode: Image.PreserveAspectCrop
                visible: false
            }

            // The picture cut to the circle.
            Rectangle {
                id: mask
                anchors.fill: parent
                radius: width / 2
                visible: false
                layer.enabled: true
            }

            MultiEffect {
                anchors.fill: parent
                visible: picture.status === Image.Ready
                source: picture
                maskEnabled: true
                maskSource: mask
            }
        }

        Text {
            anchors.left: circle.right
            anchors.leftMargin: Tokens.storeAccountNameGap
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.user.name || ""
            elide: Text.ElideRight
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.storeSidebarLabelSize
            // The title weight, as Settings' account name (UI audit 2026-11-05, LOW).
            font.weight: Tokens.typographyTitleWeight
        }

        HoverHandler {
            id: accountHover
        }

        TapHandler {
            onTapped: root.accountPicked()
        }
    }
}
