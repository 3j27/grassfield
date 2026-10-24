pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Templates as T

// Pop-up button (QtQuick.Templates ComboBox): the current choice on a rounded translucent button with a chevron; the list
// is a Grassfield PopupMenu in a Popup below the button (above it where the window has no room), the current row checked.
// model: [{id, text}]; value is the selected id (the host owns it: the control reports `picked(id)` and shows `value`
// again at once); Space, Return, Enter and the arrow keys open the list.
T.ComboBox {
    id: root

    property string value: ""
    property string accessibleName: ""
    readonly property bool open: root.popup.visible
    // The list (a PopupMenu) of the open pop-up.
    readonly property Item list: menu
    readonly property int valueIndex: {
        const m = root.model;
        for (let i = 0; m && i < m.length; i++) {
            if (m[i].id === root.value)
                return i;
        }
        return -1;
    }

    signal picked(string id)

    textRole: "text"
    valueRole: "id"
    currentIndex: root.valueIndex
    displayText: root.valueIndex >= 0 ? (root.model)[root.valueIndex].text : ""
    implicitWidth: Tokens.settingsPickerWidth
    implicitHeight: Tokens.menuItemHeight + Tokens.spacingSm
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    Accessible.role: Accessible.ComboBox
    Accessible.name: root.accessibleName
    Accessible.description: root.displayText
    Accessible.onPressAction: if (root.visible && root.enabled)
        root.popup.open()

    onPressedChanged: if (pressed)
        root.openedByKey = false

    onModelChanged: root.currentIndex = Qt.binding(() => root.valueIndex)

    // The template steps the selection with the arrows; here every opening key shows the list instead.
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space || event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
            root.openedByKey = true;
            if (root.enabled)
                root.popup.open();
            event.accepted = true;
        }
    }

    background: Rectangle {
        radius: Tokens.radiusControl
        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
        border.width: Appearance.increaseContrast ? Tokens.controlBorderWidth : 0
        border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
        opacity: root.enabled ? 1 : Tokens.materialDisabledOpacity

        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Appearance.withAlpha(Appearance.colors.hover, root.down ? Tokens.controlPressedOpacity : Tokens.materialHoverOpacity)
            visible: root.enabled && (root.hovered || root.down)
        }

        FocusRing {
            visible: root.visualFocus
        }
    }

    contentItem: Text {
        textFormat: Text.PlainText
        leftPadding: Tokens.spacingMd
        rightPadding: Tokens.menuIconSize + Tokens.spacingSm + Tokens.spacingXs
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        text: root.displayText
        opacity: root.enabled ? 1 : Tokens.materialDisabledOpacity
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyMenuSize
        font.weight: Tokens.typographyMenuWeight
    }

    indicator: Icon {
        name: "chevron-down"
        size: Tokens.menuIconSize
        x: root.width - width - Tokens.spacingSm
        y: (root.height - height) / 2
        opacity: root.enabled ? 1 : Tokens.materialDisabledOpacity
    }

    // How the last opening was started: a key (the focus returns to the button with a visible ring) or the pointer.
    property bool openedByKey: false

    popup: T.Popup {
        id: popup

        // The room the list may take: the window minus a margin on every side. A taller list scrolls (macOS: a pop-up taller
        // than the screen scrolls, it never leaves it).
        property real maxHeight: 1e6

        width: menu.width
        height: Math.min(menu.height, popup.maxHeight)
        padding: 0
        closePolicy: T.Popup.CloseOnEscape | T.Popup.CloseOnPressOutside

        // Below the button and right-aligned with it, above it when that does not fit, always inside the window.
        function place(): void {
            const win = root.Window.contentItem;
            if (!win)
                return;
            const margin = Tokens.spacingSm;
            popup.maxHeight = Math.max(Tokens.menuItemHeight, win.height - 2 * margin);
            const at = root.mapToItem(win, 0, 0);
            const w = menu.width;
            const h = Math.min(menu.height, popup.maxHeight);
            const left = Math.max(margin, Math.min(win.width - w - margin, at.x + root.width - w));
            const below = at.y + root.height + Tokens.spacingXs;
            const above = at.y - Tokens.spacingXs - h;
            const top = below + h > win.height - margin && above >= margin ? above : Math.max(margin, Math.min(win.height - h - margin, below));
            popup.x = left - at.x;
            popup.y = top - at.y;
        }

        onAboutToShow: {
            const items = [];
            const m = root.model;
            for (let i = 0; m && i < m.length; i++)
                items.push({id: m[i].id, text: m[i].text, checked: i === root.valueIndex});
            menu.model = items;
            menu.measure();
            menu.currentIndex = Math.max(0, root.valueIndex);
            popup.place();
            scroller.contentY = 0;
            scroller.reveal();
        }
        onOpened: menu.forceActiveFocus()
        // The focus goes back to the button with the reason the list was opened with: a key keeps the ring, the pointer shows none.
        onClosed: {
            root.focus = false;
            root.forceActiveFocus(root.openedByKey ? Qt.TabFocusReason : Qt.MouseFocusReason);
        }

        background: Item {}

        // The menu sits in a Flickable (plain Item content): a Popup resizes its content item, which would replace the menu's
        // own size bindings. The Popup takes its size from the menu, up to maxHeight; beyond that the list scrolls.
        contentItem: Flickable {
            id: scroller

            implicitWidth: menu.width
            implicitHeight: Math.min(menu.height, popup.maxHeight)
            contentWidth: menu.width
            contentHeight: menu.height
            interactive: contentHeight > height
            clip: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}

            // Keeps the row under the keyboard cursor in view.
            function reveal(): void {
                const top = Tokens.menuPadding + menu.currentIndex * Tokens.menuItemHeight;
                const bottom = top + Tokens.menuItemHeight + Tokens.menuPadding;
                if (top < scroller.contentY)
                    scroller.contentY = Math.max(0, top - Tokens.menuPadding);
                else if (bottom > scroller.contentY + scroller.height)
                    scroller.contentY = Math.min(scroller.contentHeight - scroller.height, bottom - scroller.height);
            }

            PopupMenu {
                id: menu
                accessibleName: root.accessibleName
                onCloseRequested: popup.close()
                onCurrentIndexChanged: scroller.reveal()
                onWidthChanged: if (popup.visible) popup.place()
                onHeightChanged: if (popup.visible) popup.place()
                onActivated: item => {
                    popup.close();
                    root.picked(item.id);
                    // Back to what the host holds: it moves `value` if it accepts the choice.
                    root.currentIndex = Qt.binding(() => root.valueIndex);
                }
            }
        }
    }
}
