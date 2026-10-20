pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// The list of the Notifications column (NotificationCenter.qml): the cards grouped by app, newest first. Keyboard focus belongs
// to the cards (never to the view's current item), Tab and Shift+Tab walk them in visual order, a card that leaves the
// displayed rows hands its focus on (Notifications.centerFocusMoved). Layout positions are always the model's: a card whose
// place changed only animates a visual offset back to 0. Its own file so that the tests (tests/shell/notif_center_list) run
// this very component.

ListView {
    id: list

    // The surface host (the column): blur surfaces (addSurface) and the hovered group (hoverApp, hoverCard).
    required property var host
    // The column's focus scope: its gutter (room left of the cards for their x) and the focus fallback.
    required property Item panel
    // The first and the last Tab stop after the list (Edit Widgets, the close circle).
    required property Item editTarget
    required property Item closeTarget
    // Room the footer needs below the list (its height and the gap above it).
    property real bottomReserve: 0
    // Counts the frames of a card sliding out or of the column reflowing (their surfaces move without the list geometry
    // changing), so the blur regions follow the cards.
    property int motionTick: 0
    property bool tickQueued: false

    // Bumps motionTick once per animation frame, however many cards moved in it (every region re-reads its rectangle on a
    // bump: 600 bumps a frame for 200 sliding cards made each frame cost 30 to 50 ms).
    function bumpTick(): void {
        if (list.tickQueued)
            return;
        list.tickQueued = true;
        Qt.callLater(() => {
            list.tickQueued = false;
            list.motionTick++;
        });
    }

    // Round x of a group header that grows into a "Clear All" pill under the pointer or the keyboard focus.
    component GroupClear: Item {
        id: ctl

        property string text: ""
        // False: invisible and not clickable (focus still shows it).
        property bool active: false
        readonly property bool expanded: gcHover.hovered || ctl.activeFocus

        signal clicked

        width: ctl.expanded ? Math.max(height, gcLabel.implicitWidth + 2 * Tokens.spacingSm) : height
        height: Tokens.notificationCloseSize + Tokens.spacingXs
        opacity: ctl.active || ctl.activeFocus || gcHover.hovered ? 1 : 0
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: ctl.text
        Accessible.focusable: true
        Accessible.onPressAction: ctl.clicked()
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                ctl.clicked();
                event.accepted = true;
            }
        }

        Behavior on width {
            NumberAnimation {
                duration: Appearance.duration(Tokens.motionFast)
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.curve
            }
        }

        Behavior on opacity {
            NumberAnimation {
                duration: Appearance.duration(Tokens.motionFast)
            }
        }

        HoverHandler {
            id: gcHover
        }

        Rectangle {
            anchors.fill: parent
            radius: height / 2
            // Same backing as the x of a card (A2: the label must stay legible on any wallpaper).
            color: Appearance.withAlpha(Appearance.colors.materialTint, Tokens.notificationCloseTintOpacity)
            border.width: ctl.activeFocus ? Tokens.controlFocusRing : 1
            border.color: ctl.activeFocus ? Appearance.colors.accent : Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity * Tokens.notificationCloseBorderScale)
        }

        Icon {
            anchors.centerIn: parent
            size: Tokens.notificationCloseSize - Tokens.notificationCloseGlyphInset
            name: "close-glyph"
            opacity: ctl.expanded ? 0 : 1

            Behavior on opacity {
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionFast)
                }
            }
        }

        Text {
            id: gcLabel
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: ctl.text
            opacity: ctl.expanded ? 1 : 0
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            font.weight: Tokens.typographyMenuBoldWeight

            Behavior on opacity {
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionFast)
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            enabled: ctl.opacity > 0
            cursorShape: Qt.ArrowCursor
            onClicked: ctl.clicked()
        }
    }

    topMargin: list.panel.gutter
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    objectName: "notificationList"
    model: Notifications.centerModel
    // Keyboard focus belongs to the cards (focusKey), never to the view's current item: the view moves
    // focus onto the current delegate whenever a row is inserted or removed at or above it, which took it
    // off the focused card.
    currentIndex: -1
    highlightFollowsCurrentItem: false
    keyNavigationEnabled: false
    // Reduce Motion (macOS: slides become fades): nothing moves, cards fade in and out within the
    // capped duration (Appearance.duration); otherwise motion.normal.
    readonly property bool still: Appearance.reduceMotion
    readonly property int moveDuration: still ? 0 : Appearance.duration(Tokens.motionNormal)
    readonly property int fadeDuration: Appearance.duration(Tokens.motionNormal)
    // The cards below a removed or added card slide to their new place: each delegate keeps the layout
    // position the view gives it (always the model's layout) and only animates a visual offset (shift) from
    // where it was to there, so a layout that changes again mid-animation (a card above shrinking, as the
    // Show All button does) can never leave a stale offset. A removed card slides out to the right while it
    // fades (the model already changed: this only animates the delegate the view keeps for it). A card that
    // ARRIVES while the column is open slides in from the right while it fades in, run by the delegate itself
    // (enter).
    remove: Transition {
        ParallelAnimation {
            NumberAnimation {
                property: "slide"
                to: list.still ? 0 : list.width
                duration: list.moveDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.curve
            }

            NumberAnimation {
                property: "opacity"
                to: 0
                duration: list.fadeDuration
            }
        }
    }
    header: Item {
        width: list.width
        height: Notifications.count === 0 ? emptyText.implicitHeight + 2 * Tokens.spacingLg + Tokens.notificationBannerGap : 0
        visible: Notifications.count === 0

        Material {
            id: emptySurface
            x: list.panel.gutter
            width: parent.width - list.panel.gutter
            height: parent.height - Tokens.notificationBannerGap
            radius: Tokens.radiusBanner
            shadowEnabled: false
            Component.onCompleted: list.host.addSurface(emptySurface, true, Tokens.radiusBanner, null)
        }

        Text {
            id: emptyText
            textFormat: Text.PlainText
            x: list.panel.gutter + (parent.width - list.panel.gutter - width) / 2
            y: Tokens.spacingLg
            text: qsTr("No Notifications")
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyTitleSize
            font.weight: Tokens.typographyMenuWeight
        }
    }

    // Focus goes to the card with this key (found by key: the removed delegates stay in the view until their leave
    // animation ends), never to an invisible item; the panel when none is left.
    function focusKey(key: string): void {
        Qt.callLater(() => {
            // Apply the removal first: the layout it triggers would otherwise take the focus away again.
            list.forceLayout();
            for (let pass = 0; key !== "" && pass < 2; pass++) {
                for (let i = 0; i < list.count; i++) {
                    const it = list.itemAtIndex(i);
                    if (it && it.key === key && it.rowItem && !it.removing) {
                        it.rowItem.forceActiveFocus();
                        return;
                    }
                }
                // Not built (outside the viewport and its buffer): bring it in, once.
                const at = Notifications.shownKeys.indexOf(key);
                if (at < 0)
                    break;
                list.positionViewAtIndex(at, ListView.Contain);
                list.forceLayout();
            }
            list.panel.forceActiveFocus();
        });
    }

    // Focus goes to the Show Less (head card of the group) or Show All (its last displayed card) control of an app
    // group, the one that replaces the control just used (macOS keeps the focus on the stack control); to the
    // card `fallback` when that control does not exist.
    function focusControl(app: string, showLess: bool, fallback: string): void {
        Qt.callLater(() => {
            list.forceLayout();
            for (let i = 0; i < list.count; i++) {
                const it = list.itemAtIndex(i);
                if (!it || it.removing || it.appName !== app)
                    continue;
                const ctl = showLess ? it.showLessCtl : it.toggleCtl;
                if (ctl && ctl.visible) {
                    ctl.forceActiveFocus();
                    return;
                }
            }
            list.focusKey(fallback);
        });
    }

    // Tells the model which card holds the keyboard focus, so that it can move the focus when that card
    // leaves the displayed rows (an arrival pushing it out of a collapsed group, Show Less, an expiry...).
    function trackFocus(): void {
        const d = list.focusedDelegate();
        Notifications.centerFocusKey = d && !d.removing ? d.key : "";
    }

    Connections {
        target: list.Window.window
        ignoreUnknownSignals: true

        function onActiveFocusItemChanged(): void {
            list.trackFocus();
        }
    }

    Connections {
        target: Notifications

        function onCenterFocusMoved(key: string): void {
            list.focusKey(key);
        }
    }

    Component.onDestruction: Notifications.centerFocusKey = ""
    // The card (delegate) that holds the keyboard focus, or its x or buttons: null when the focus is elsewhere.
    function focusedDelegate(): Item {
        for (let f = list.Window.activeFocusItem; f; f = f.parent) {
            if (f.rowItem !== undefined && f.key !== undefined)
                return f;
        }
        return null;
    }

    // Tab order. Qt's focus chain follows the order the delegates were CREATED in (cards that arrived later
    // sit above the older ones), so Tab and Shift+Tab are stepped here whenever they would leave a card:
    // the regions are the cards top to bottom (their index), then the widgets (index count), then the
    // footer controls. Inside a card Qt's own order (card, x, buttons) is right and is kept.
    function regionOf(it: Item): int {
        for (let p = it; p; p = p.parent) {
            if (p.rowItem !== undefined && p.key !== undefined && p.removing === false)
                return p.index;
            if (p === list.footerItem)
                return list.count;
        }
        return -1;
    }

    // The last item of the chain that stays in region r, from `from`.
    function lastIn(from: Item, r: int): Item {
        let cur = from;
        for (let n = 0; n < 64; n++) {
            const nx = cur.nextItemInFocusChain(true);
            if (!nx || nx === from || list.regionOf(nx) !== r)
                break;
            cur = nx;
        }
        return cur;
    }

    // The item Tab (forward) or Shift+Tab enters region t at; null when there is no such region.
    function regionEntry(t: int, forward: bool): Item {
        if (t < 0 || t > list.count)
            return null;
        if (t === list.count) {
            const nx = list.footerItem ? list.footerItem.nextItemInFocusChain(true) : null;
            if (!nx || list.regionOf(nx) !== list.count)
                return null;
            return forward ? nx : list.lastIn(nx, list.count);
        }
        let d = list.itemAtIndex(t);
        if (!d) {
            list.positionViewAtIndex(t, ListView.Contain);
            list.forceLayout();
            d = list.itemAtIndex(t);
        }
        if (!d || d.removing)
            return null;
        return forward ? d.rowItem : list.lastIn(d.rowItem, t);
    }

    // Moves the focus one step in visual order. Where Qt's own next item is the right one (inside a card,
    // between the footer controls) that item is focused, exactly as Qt does for Tab.
    function tabStep(forward: bool): void {
        const f = list.Window.activeFocusItem;
        if (!f)
            return;
        const reason = forward ? Qt.TabFocusReason : Qt.BacktabFocusReason;
        let dest = null;
        const r = list.regionOf(f);
        if (r >= 0) {
            const nx = f.nextItemInFocusChain(forward);
            if (nx && list.regionOf(nx) === r) {
                nx.forceActiveFocus(reason);
                return;
            }
            dest = list.regionEntry(r + (forward ? 1 : -1), forward);
            if (!dest)
                dest = forward ? list.editTarget : list.closeTarget;
        } else if (f === panel || f === list || f === list.contentItem) {
            // Nothing focused yet: Tab starts at the top card, Shift+Tab at the last control.
            dest = forward ? list.regionEntry(0, true) : list.closeTarget;
        } else if (f === list.closeTarget && forward) {
            dest = list.regionEntry(0, true);
        } else if (f === list.editTarget && !forward) {
            dest = list.regionEntry(list.count, false);
            if (!dest)
                dest = list.regionEntry(list.count - 1, false);
        }
        if (!dest) {
            const nx = f.nextItemInFocusChain(forward);
            if (nx)
                nx.forceActiveFocus(reason);
            return;
        }
        dest.forceActiveFocus(reason);
    }

    // Rows near the viewport stay alive so Tab can reach them.
    cacheBuffer: Tokens.notificationCenterCache
    delegate: Column {
        id: item

        required property int index
        required property string key
        required property int nid
        required property string appName
        required property string appIcon
        required property string image
        required property string summary
        required property string bodyHtml
        required property real time
        required property int urgency
        required property string actionsJson
        // Group info carried by the rows that need it (see Notifications.syncShown).
        required property int headCount
        required property bool headFirst
        required property int toggleCount

        readonly property bool expanded: Notifications.expandedApps[appName] === true
        // The focusable card (see ListView.focusKey).
        readonly property Item rowItem: row
        // The pointer is over a card of this app.
        readonly property bool groupHot: list.host.hoverApp === appName
        // Slide of the leave animation (list.remove) and whether this delegate is already out of the model.
        property real slide: 0
        property bool removing: false
        // Visual offset of a card whose layout position changed (see above): animated back to 0.
        property real shift: 0
        property real lastY: NaN
        // The Show Less and Show All controls of this card (set by the card body).
        property Item showLessCtl: null
        property Item toggleCtl: null

        // Clears this card, or (group) the entries of its app group that exist now. The model changes at once
        // (history, "No Notifications", persistence); this delegate only animates out. Everything it needs is
        // read first: the clear moves the indices. The focus moves to the next card when it was on the cleared
        // card (or any card of the cleared group) or when `refocus` (keyboard and accessibility paths); a
        // focus on another card stays where it is.
        function clearCard(group: bool, refocus: bool): void {
            if (removing)
                return;
            const at = index;
            const app = appName;
            const held = list.focusedDelegate();
            const lost = held !== null && (group ? held.appName === app : held === item);
            const moves = Notifications.focusMoves;
            if (group)
                Notifications.clearKeys(Notifications.keysOf(app));
            else
                Notifications.clear(key);
            // The model already moved the focus when it left the displayed rows (centerFocusMoved); this is
            // for the paths where the focus was not on the card (accessibility actions).
            if ((refocus || lost) && Notifications.focusMoves === moves)
                list.focusKey(Notifications.focusKeyAfter(at, app));
        }

        // A card on its way out takes no input and gets no focus.
        enabled: !removing
        ListView.onRemove: {
            enter.stop();
            item.removing = true;
        }
        Component.onCompleted: {
            if (Notifications.takeFresh(key))
                enter.start();
        }
        onYChanged: {
            // The layout moved this card (a card above arrived, left or changed height): keep it where it
            // was on screen and glide it to its place. Never during Reduce Motion, nor for the first
            // placement of a new card.
            if (!list.still && !item.removing && !isNaN(item.lastY) && item.lastY !== item.y) {
                item.shift += item.lastY - item.y;
                glide.restart();
            }
            item.lastY = item.y;
            list.bumpTick();
        }
        onOpacityChanged: list.bumpTick()
        onSlideChanged: list.bumpTick()
        onShiftChanged: list.bumpTick()

        transform: [
            Translate {
                x: item.slide
                y: item.shift
            }
        ]

        NumberAnimation {
            id: glide
            target: item
            property: "shift"
            to: 0
            duration: list.moveDuration
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Appearance.curve
        }

        // A new notification arriving while the column is open: slides in from the right and fades in.
        ParallelAnimation {
            id: enter

            NumberAnimation {
                target: item
                property: "slide"
                from: list.still ? 0 : list.width
                to: 0
                duration: list.moveDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.curve
            }

            NumberAnimation {
                target: item
                property: "opacity"
                from: 0
                to: 1
                duration: list.fadeDuration
            }
        }

        width: list.width
        leftPadding: list.panel.gutter
        // Groups are set apart; cards of one group are one banner gap apart.
        topPadding: item.headCount > 0 && !item.headFirst ? Tokens.spacingMd : 0
        bottomPadding: Tokens.notificationBannerGap

        Item {
            id: row

            readonly property bool hovered: rowHover.hovered
            readonly property bool live: item.nid >= 0

            width: item.width - list.panel.gutter
            height: rowLoader.height
            activeFocusOnTab: true
            Accessible.role: Accessible.ListItem
            Accessible.name: item.summary !== "" ? item.summary : Notifications.groupLabel(item.appName)
            Accessible.description: item.appName
            Accessible.focusable: true
            Accessible.onPressAction: row.open()

            function open(): void {
                if (!live)
                    return;
                Notifications.activateDefault(item.key);
                Notifications.closeCenter();
            }

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    row.open();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) {
                    item.clearCard(false, true);
                    event.accepted = true;
                }
            }

            onActiveFocusChanged: {
                if (activeFocus)
                    list.positionViewAtIndex(item.index, ListView.Contain);
            }

            HoverHandler {
                id: rowHover
                onHoveredChanged: list.host.hoverCard(item.appName, hovered)
                // A removed card under the pointer never reports the leave.
                Component.onDestruction: {
                    if (hovered)
                        list.host.hoverCard(item.appName, false);
                }
            }

            TapHandler {
                acceptedButtons: Qt.LeftButton
                enabled: row.live && !closeHover.hovered && !item.removing
                onTapped: row.open()
            }

            // Close (clear) this entry: a small round x on the card's top-left corner, shown on hover or
            // keyboard focus (Tab reaches it after the card; Space or Return clears).
            Item {
                id: closeButton
                z: 1

                x: -list.panel.gutter
                y: -list.panel.gutter
                width: Tokens.notificationCloseSize
                height: width
                opacity: row.hovered || row.activeFocus || closeHover.hovered || closeButton.activeFocus ? 1 : 0
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: qsTr("Close")
                Accessible.description: item.summary
                Accessible.focusable: true
                Accessible.onPressAction: item.clearCard(false, true)
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        item.clearCard(false, true);
                        event.accepted = true;
                    }
                }

                Behavior on opacity {
                    NumberAnimation {
                        duration: Appearance.duration(Tokens.motionFast)
                    }
                }

                HoverHandler {
                    id: closeHover
                    onHoveredChanged: list.host.hoverCard(item.appName, hovered)
                    Component.onDestruction: {
                        if (hovered)
                            list.host.hoverCard(item.appName, false);
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: Appearance.withAlpha(Appearance.colors.materialTint, Tokens.notificationCloseTintOpacity)
                    border.width: closeButton.activeFocus ? Tokens.controlFocusRing : 1
                    border.color: closeButton.activeFocus ? Appearance.colors.accent : Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity * Tokens.notificationCloseBorderScale)
                }

                Icon {
                    anchors.centerIn: parent
                    size: parent.width - Tokens.notificationCloseGlyphInset
                    name: "close-glyph"
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: parent.opacity > 0
                    cursorShape: Qt.ArrowCursor
                    onClicked: item.clearCard(false, false)
                }
            }

            Loader {
                id: rowLoader
                width: parent.width
                sourceComponent: rowBody
            }

            // Keyboard focus ring.
            Rectangle {
                anchors.fill: parent
                radius: Tokens.radiusBanner
                color: "transparent"
                border.width: row.activeFocus ? Tokens.controlFocusRing : 0
                border.color: Appearance.colors.accent
            }

            // One floating card: the group header on the first card of a group, the notification, Show
            // All / Show Less on the last visible card of a group.
            Component {
                id: rowBody

                Item {
                    implicitHeight: cardColumn.implicitHeight + 2 * Tokens.spacingMd

                    Material {
                        id: cardSurface
                        anchors.fill: parent
                        radius: Tokens.radiusBanner
                        shadowEnabled: false
                        Component.onCompleted: list.host.addSurface(cardSurface, true, Tokens.radiusBanner, item)
                    }

                    Column {
                        id: cardColumn
                        x: Tokens.spacingMd
                        y: Tokens.spacingMd
                        width: parent.width - 2 * Tokens.spacingMd
                        spacing: Tokens.spacingSm

                        Item {
                            visible: item.headCount > 0
                            width: parent.width
                            height: visible ? Math.max(clearGroup.height, showLess.implicitHeight) : 0

                            Row {
                                height: parent.height
                                spacing: Tokens.spacingSm

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: Notifications.groupLabel(item.appName)
                                    textFormat: Text.PlainText
                                    color: Appearance.colors.text
                                    font.family: Appearance.fontFamily
                                    font.pixelSize: Tokens.typographyBodySize
                                    font.weight: Tokens.typographyMenuBoldWeight
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    textFormat: Text.PlainText
                                    visible: item.headCount > 1
                                    text: String(item.headCount)
                                    color: Appearance.colors.textSecondary
                                    font.family: Appearance.fontFamily
                                    font.pixelSize: Tokens.typographyBodySize
                                    font.weight: Tokens.typographyMenuWeight
                                }
                            }

                            Row {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Tokens.spacingSm

                                Button {
                                    id: showLess
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: item.expanded && item.headCount > Tokens.notificationCenterGroupCollapsed
                                    opacity: item.groupHot || activeFocus ? 1 : 0
                                    capsule: true
                                    text: qsTr("Show Less")
                                    Component.onCompleted: item.showLessCtl = showLess
                                    onClicked: {
                                        const kbd = showLess.activeFocus;
                                        Notifications.setExpanded(item.appName, false);
                                        if (kbd)
                                            list.focusControl(item.appName, false, item.key);
                                    }

                                    Behavior on opacity {
                                        NumberAnimation {
                                            duration: Appearance.duration(Tokens.motionFast)
                                        }
                                    }
                                }

                                GroupClear {
                                    id: clearGroup
                                    anchors.verticalCenter: parent.verticalCenter
                                    // A single notification has only its own x (macOS): Clear All needs a group.
                                    visible: item.headCount > 1
                                    active: item.groupHot
                                    text: qsTr("Clear All")
                                    onClicked: item.clearCard(true, false)
                                }
                            }
                        }

                        NotificationContent {
                            id: rowContent
                            width: parent.width
                            summary: item.summary
                            appName: item.appName
                            urgency: item.urgency
                            actionsJson: item.actionsJson
                            live: row.live
                            body: Notifications.bodyFor(item.bodyHtml)
                            timeText: Notifications.timeFor(item.time)
                            iconSource: Notifications.iconSource(item.image, item.appIcon)
                            onActionTriggered: actionId => Notifications.invokeAction(item.key, actionId)
                        }

                        Item {
                            visible: item.toggleCount > 0 && !item.expanded
                            width: parent.width
                            height: visible ? toggle.implicitHeight : 0

                            Button {
                                id: toggle
                                anchors.horizontalCenter: parent.horizontalCenter
                                capsule: true
                                text: qsTr("Show All (%1)").arg(item.toggleCount)
                                Component.onCompleted: item.toggleCtl = toggle
                                onClicked: {
                                    const kbd = toggle.activeFocus;
                                    Notifications.setExpanded(item.appName, true);
                                    if (kbd)
                                        list.focusControl(item.appName, true, item.key);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
