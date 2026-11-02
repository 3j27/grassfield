pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Templates as T

// Pop-up button (QtQuick.Templates ComboBox): the current choice on a rounded translucent button with a chevron; the list
// is a Grassfield PopupMenu in a Popup below the button (above it where the window has no room), the current row checked.
// model: [{id, text}]; value is the selected id (the host owns it: the control reports `picked(id)` and shows `value`
// again at once); Space, Return, Enter and the arrow keys open the list.
// `inline`: the pop-up of a settings row (macOS 27 System Settings): the value as plain text, then a round disc with two
// chevrons; no button behind the text.
T.ComboBox {
    id: root

    property string value: ""
    property bool inline: false
    // The least width of the button form (a pop-up that hugs its widest choice sets a smaller one).
    property real minimumWidth: Tokens.settingsPickerWidth
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
    // Wide enough for the longest choice (a long translation is never cut to "Si la place le pe…").
    // Whole device pixels, so that the disc and the next control in a row stay on the pixel grid (a 3.5-pt inset stays 3.5 at 2x).
    readonly property real pixelRatio: Math.max(1, Screen.devicePixelRatio)
    implicitWidth: Math.ceil((root.inline ? widest + Tokens.settingsPopupIndicatorGap + Tokens.settingsPopupIndicatorSize + Tokens.settingsPopupInset
        : Math.max(root.minimumWidth, widest + Tokens.spacingMd + Tokens.menuIconSize + Tokens.spacingSm + Tokens.spacingXs + Tokens.spacingSm)) * root.pixelRatio) / root.pixelRatio
    property real widest: 0
    function measureItems(): void {
        let w = 0;
        for (let i = 0; i < sizer.count; i++) {
            const t = sizer.itemAt(i) as Text;
            if (t)
                w = Math.max(w, t.implicitWidth);
        }
        root.widest = w;
    }
    Repeater {
        id: sizer
        model: root.model
        onItemAdded: root.measureItems()
        onItemRemoved: root.measureItems()

        delegate: Text {
            required property var modelData
            visible: false
            textFormat: Text.PlainText
            text: modelData.text !== undefined ? modelData.text : ""
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyMenuSize
            font.weight: Tokens.typographyMenuWeight
            onImplicitWidthChanged: root.measureItems()
        }
    }
    implicitHeight: root.inline ? Tokens.settingsPopupIndicatorSize : Tokens.menuItemHeight + Tokens.spacingSm
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    Accessible.role: Accessible.ComboBox
    Accessible.name: root.accessibleName
    Accessible.description: root.displayText
    Accessible.onPressAction: if (root.visible && root.enabled)
        root.popup.open()

    onPressedChanged: if (pressed)
        root.openedByKey = false

    // A combo that is hidden or disabled closes its list (macOS), and nothing it holds can pick any more.
    onVisibleChanged: if (!root.visible)
        root.popup.close()
    onEnabledChanged: if (!root.enabled)
        root.popup.close()

    FocusGuard {}

    onModelChanged: root.currentIndex = Qt.binding(() => root.valueIndex)

    // The template steps the selection with the arrows; here every opening key shows the list instead.
    Keys.onPressed: event => {
        if (!root.visible || !root.enabled) {
            if (ActivationKeys.activation(event.key) || event.key === Qt.Key_Down || event.key === Qt.Key_Up)
                event.accepted = true;
            return;
        }
        if (ActivationKeys.activation(event.key) || event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
            root.openedByKey = true;
            root.popup.open();
            event.accepted = true;
        }
    }

    background: Rectangle {
        radius: root.inline ? height / 2 : Tokens.radiusControl
        color: root.inline ? "transparent" : Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity)
        // Increase Contrast outlines the bezel; the inline pop-up has none (its text starts at the edge), so its disc takes the
        // outline instead.
        border.width: Appearance.increaseContrast && !root.inline ? Tokens.controlBorderWidth : 0
        border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
        opacity: root.enabled ? 1 : Tokens.materialDisabledOpacity

        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Appearance.withAlpha(Appearance.colors.hover, root.down ? Tokens.controlPressedOpacity : Tokens.materialHoverOpacity)
            visible: !root.inline && root.enabled && (root.hovered || root.down)
        }

        FocusRing {
            visible: root.visualFocus
            shapeRadius: root.inline ? root.height / 2 : Tokens.radiusControl
        }
    }

    contentItem: Text {
        textFormat: Text.PlainText
        leftPadding: root.inline ? 0 : Tokens.spacingMd
        rightPadding: root.inline ? Tokens.settingsPopupIndicatorGap + Tokens.settingsPopupIndicatorSize + Tokens.settingsPopupInset : Tokens.menuIconSize + Tokens.spacingSm + Tokens.spacingXs
        horizontalAlignment: root.inline ? Text.AlignRight : Text.AlignLeft
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        text: root.displayText
        opacity: root.enabled ? 1 : Tokens.materialDisabledOpacity
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyMenuSize
        font.weight: Tokens.typographyMenuWeight
    }

    indicator: Item {
        // Whole device pixels: the measured inset (3.5) would put the disc's edges between two pixels at scale 1.
        x: Math.round((root.inline ? root.width - width - Tokens.settingsPopupInset : root.width - width - Tokens.spacingSm) * root.pixelRatio) / root.pixelRatio
        y: (root.height - height) / 2
        width: root.inline ? Tokens.settingsPopupIndicatorSize : Tokens.menuIconSize
        height: width
        opacity: root.enabled ? 1 : Tokens.materialDisabledOpacity

        // The inline disc: the text colour at a low alpha, a step stronger under the pointer or while pressed.
        Rectangle {
            visible: root.inline
            anchors.fill: parent
            radius: width / 2
            border.width: Appearance.increaseContrast ? Tokens.controlBorderWidth : 0
            border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
            color: Appearance.withAlpha(Appearance.colors.text, root.down ? Tokens.settingsPopupIndicatorOpacity + Tokens.controlPressedOpacity / 2
                : root.hovered && root.enabled ? Tokens.settingsPopupIndicatorOpacity + Tokens.materialHoverOpacity : Tokens.settingsPopupIndicatorOpacity)
        }

        Icon {
            anchors.centerIn: parent
            name: root.inline ? "chevron-up-down" : "chevron-down"
            size: root.inline ? Tokens.settingsPopupGlyphSize : Tokens.menuIconSize
        }
    }

    // How the last opening was started: a key (the focus returns to the button with a visible ring) or the pointer.
    property bool openedByKey: false

    popup: T.Popup {
        id: popup

        // The room the list may take: the window minus a margin on every side. A taller list scrolls (macOS: a pop-up taller
        // than the screen scrolls, it never leaves it).
        property real maxHeight: Infinity
        property real maxWidth: Infinity

        width: Math.min(menu.width, popup.maxWidth)
        height: Math.min(menu.height, popup.maxHeight)
        padding: 0
        closePolicy: T.Popup.CloseOnEscape | T.Popup.CloseOnPressOutside

        // Below the button and right-aligned with it, above it when that does not fit, always inside the window.
        // The window's content item: the top of the parent chain.
        function windowItem(): Item {
            let win = root as Item;
            while (win.parent)
                win = win.parent;
            return win;
        }

        function place(): void {
            const win = popup.windowItem();
            const margin = Tokens.spacingSm;
            popup.maxHeight = Math.max(0, win.height - 2 * margin);
            popup.maxWidth = Math.max(0, win.width - 2 * margin);
            const at = root.mapToItem(win, 0, 0);
            const w = Math.min(menu.width, popup.maxWidth);
            const h = Math.min(menu.height, popup.maxHeight);
            const left = Math.max(margin, Math.min(win.width - w - margin, at.x + root.width - w));
            const below = at.y + root.height + Tokens.spacingXs;
            const above = at.y - Tokens.spacingXs - h;
            const top = below + h > win.height - margin && above >= margin ? above : Math.max(margin, Math.min(win.height - h - margin, below));
            popup.x = left - at.x;
            popup.y = top - at.y;
        }

        // The widest label that fits the window: the rest of a longer one is elided (macOS), not cut off by the window edge.
        TextMetrics {
            id: metrics
            elide: Text.ElideRight
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyMenuSize
            font.weight: Tokens.typographyMenuWeight
        }

        onAboutToShow: {
            const items = [];
            const m = root.model;
            const room = popup.windowItem().width - 2 * Tokens.spacingSm;
            metrics.elideWidth = Math.max(1, room - 2 * Tokens.menuPadding - 2 * Tokens.menuItemPadding - Tokens.menuIconSize - 2 * Tokens.spacingSm);
            for (let i = 0; m && i < m.length; i++) {
                metrics.text = m[i].text;
                items.push({id: m[i].id, text: metrics.elidedText, checked: i === root.valueIndex});
            }
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
            // Not back on a combo that was hidden or disabled meanwhile.
            if (!root.visible || !root.enabled)
                return;
            root.focus = false;
            root.forceActiveFocus(root.openedByKey ? Qt.TabFocusReason : Qt.MouseFocusReason);
        }

        background: Item {}

        // The menu sits in a Flickable (plain Item content): a Popup resizes its content item, which would replace the menu's
        // own size bindings. The Popup takes its size from the menu, up to maxHeight; beyond that the list scrolls.
        contentItem: Flickable {
            id: scroller

            implicitWidth: Math.min(menu.width, popup.maxWidth)
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
                    if (!root.visible || !root.enabled)
                        return;
                    root.picked(item.id);
                    // Back to what the host holds: it moves `value` if it accepts the choice.
                    root.currentIndex = Qt.binding(() => root.valueIndex);
                }
            }
        }
    }
}
