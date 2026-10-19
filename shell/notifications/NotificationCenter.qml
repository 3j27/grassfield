pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.services
import qs.widgets

// Notifications column (N7, internal Notification Center): the macOS model. No full-height panel:
// a column of floating glass cards as wide as a banner, at the right under the menu bar, opened from the clock or
// by IPC. No title: the cards grouped by app, newest first (the first card of a group carries the app name, its
// count and, on hover or focus, "Show Less" and a round x that grows into a "Clear All" pill; the last visible
// one carries Show All), then the widgets placed there; a footer of an Edit Widgets pill (gallery overlay,
// docs/specs/widgets.md) and a close circle, centred one spacing.lg below the last card. No permanent global Clear All
// (macOS 26 model): a card shows a round x at its top-left corner on hover or focus; clearing slides the card out
// to the right while it fades, then the column reflows. Every card is its own surface with its own blur region
// (registered by the card, see addSurface). Esc or a click outside the cards closes.
//
// The window exists per screen but its content (a Loader) only while the Center is open on that
// screen, so a closed Center costs nothing. Rows come from the keyed Notifications.centerModel
// (displayed rows only, ordered by group; the first row of a group draws its header), so new notifications never rebuild the list.
// Keyboard: Tab moves between rows and buttons, Return opens the row's default action, Delete or
// Backspace clears the row and moves focus to the next card (the previous one when it was the last); each card's
// x and the group controls are reachable with Tab.
Variants {
    id: root

    model: Quickshell.screens

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        required property ShellScreen modelData

        readonly property bool open: Notifications.centerOpen && Notifications.centerScreen === modelData.name

        screen: modelData
        visible: open
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-notification-center"
        // Everything except the menu bar strip receives input (the clock toggles the panel).
        // qmllint disable missing-type
        mask: Region {
            width: win.width
            height: win.height

            Region {
                width: win.width
                height: Tokens.menubarHeight
                intersection: Intersection.Subtract
            }
        }
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.open && content.item ? blur : null
        // qmllint enable missing-type

        Region {
            id: blur
            regions: content.item ? (content.item as CenterContent).regionList : []
        }

        // A popup (menus, Control Center) takes over.
        Connections {
            target: Popups

            function onKindChanged(): void {
                if (Popups.active)
                    Notifications.closeCenter();
            }
        }

        Loader {
            id: content
            anchors.fill: parent
            active: win.open
            sourceComponent: CenterContent {}
        }

        // Glass pill of the footer.
        component Pill: Item {
            id: pill

            // The CenterContent that owns the blur regions.
            required property var surfaceHost
            property string text: ""

            signal clicked

            implicitWidth: Math.max(Tokens.notificationCenterPillWidth, label.implicitWidth + 2 * Tokens.spacingMd)
            implicitHeight: Tokens.notificationCenterPillHeight
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: pill.text
            Accessible.focusable: true
            Accessible.onPressAction: pill.clicked()
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    pill.clicked();
                    event.accepted = true;
                }
            }

            Material {
                id: pillSurface
                anchors.fill: parent
                radius: height / 2
                shadowEnabled: false
                Component.onCompleted: pill.surfaceHost.addSurface(pillSurface, false, Math.floor(height / 2))
            }

            Text {
                id: label
                anchors.centerIn: parent
                width: Math.min(implicitWidth, parent.width - 2 * Tokens.spacingSm)
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: pill.text
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                font.weight: Tokens.typographyMenuBoldWeight
            }

            Rectangle {
                anchors.fill: parent
                radius: height / 2
                color: "transparent"
                border.width: pill.activeFocus ? Tokens.controlFocusRing : 0
                border.color: Appearance.colors.accent
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: pill.clicked()
            }
        }

        // Round x of a group header that grows into a "Clear All" pill under the pointer or the keyboard focus.
        component GroupClear: Item {
            id: gc

            property string text: ""
            // False: invisible and not clickable (focus still shows it).
            property bool active: false
            readonly property bool expanded: gcHover.hovered || gc.activeFocus

            signal clicked

            width: gc.expanded ? Math.max(height, gcLabel.implicitWidth + 2 * Tokens.spacingSm) : height
            height: Tokens.notificationCloseSize + Tokens.spacingXs
            opacity: gc.active || gc.activeFocus || gcHover.hovered ? 1 : 0
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: gc.text
            Accessible.focusable: true
            Accessible.onPressAction: gc.clicked()
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    gc.clicked();
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
                color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                border.width: gc.activeFocus ? Tokens.controlFocusRing : 0
                border.color: Appearance.colors.accent
            }

            Icon {
                anchors.centerIn: parent
                size: Tokens.notificationCloseSize - Tokens.notificationCloseGlyphInset
                name: "close-glyph"
                opacity: gc.expanded ? 0 : 1

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
                text: gc.text
                opacity: gc.expanded ? 1 : 0
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
                enabled: gc.opacity > 0
                cursorShape: Qt.PointingHandCursor
                onClicked: gc.clicked()
            }
        }

        component CenterContent: Item {
            id: host

            readonly property Item panel: panel
            // One blur region per glass surface (cards, title capsule, widgets, footer).
            readonly property var regionList: regions.instances
            // Slides in from the right edge after creation.
            property bool shown: false
            // Registered glass surfaces: {item, clip (inside the list viewport), radius}. Destroyed items read as null
            // and are dropped the next time a surface registers or the row count changes.
            property var surfaces: []
            // Counts the frames of a card sliding out or of the column reflowing (their surfaces move without the
            // list geometry changing), so the blur regions follow the cards.
            property int motionTick: 0
            // Anything that moves or resizes a surface without changing its own geometry.
            readonly property real tick: list.contentY + list.contentHeight + list.count + list.height + panel.x + panel.y + motionTick
            // App whose group is being cleared (its cards slide out together), and the app the pointer is over (group controls).
            property string leavingApp: ""
            property bool leavingGroup: false
            property string hoverApp: ""

            Timer {
                id: hoverRelease
                interval: Appearance.duration(Tokens.motionFast)
                onTriggered: host.hoverApp = ""
            }

            // A pointer on a card of an app group, or leaving it (a short grace covers the gap between two cards).
            function hoverCard(app: string, over: bool): void {
                if (over) {
                    hoverRelease.stop();
                    hoverApp = app;
                } else if (hoverApp === app) {
                    hoverRelease.restart();
                }
            }

            function addSurface(item: Item, clip: bool, radius: real): void {
                surfaces = surfaces.filter(r => r.item).concat([{item: item, clip: clip, radius: radius}]);
            }

            // Rectangle of a surface in window coordinates, cut to the list viewport for rows.
            function rectOf(rec: var): rect {
                const it = rec.item as Item;
                if (!it)
                    return Qt.rect(0, 0, 0, 0);
                const p = it.mapToItem(null, 0, 0);
                let top = p.y;
                let bottom = p.y + it.height;
                if (rec.clip) {
                    const v = list.mapToItem(null, 0, 0);
                    top = Math.max(top, v.y);
                    bottom = Math.min(bottom, v.y + list.height);
                }
                return Qt.rect(p.x, top, it.width, Math.max(0, bottom - top));
            }

            function overSurface(x: real, y: real): bool {
                for (const rec of surfaces) {
                    const r = rectOf(rec);
                    if (x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height)
                        return true;
                }
                return false;
            }

            Component.onCompleted: {
                shown = true;
                panel.forceActiveFocus();
            }

            Variants {
                id: regions
                model: host.surfaces

                Region {
                    id: region

                    required property var modelData
                    readonly property rect box: {
                        host.tick;
                        return host.rectOf(region.modelData);
                    }

                    x: Math.round(box.x)
                    y: Math.round(box.y)
                    width: Math.round(box.width)
                    height: Math.round(box.height)
                    radius: region.modelData.radius
                }
            }

            // A click outside every card closes; a click on a card or the title capsule does not.
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onPressed: mouse => {
                    if (!host.overSurface(mouse.x, mouse.y))
                        Notifications.closeCenter();
                }
            }

            FocusScope {
                id: panel

                // Widgets: the gallery overlay and the context menu of a placed widget.
                property bool galleryOpen: false
                property var menuEntry: null
                property real menuX: 0
                property real menuY: 0
                property Item menuReturn: null
                // Room left of the cards for the x of a card, which sticks out of its top-left corner (the list is that
                // much wider and taller; the cards keep their place).
                readonly property int gutter: Math.ceil(Tokens.notificationCloseSize / 3)

                function openWidgetMenu(tile: Item, x: real, y: real, entry: var): void {
                    const p = tile.mapToItem(panel, x, y);
                    menuX = p.x;
                    menuY = p.y;
                    menuReturn = tile;
                    menuEntry = entry;
                }

                function closeWidgetMenu(): void {
                    menuEntry = null;
                    if (menuReturn)
                        menuReturn.forceActiveFocus();
                    else
                        panel.forceActiveFocus();
                }

                function applyWidgetMenu(action: string): void {
                    const entry = menuEntry;
                    menuEntry = null;
                    panel.forceActiveFocus();
                    if (!entry)
                        return;
                    if (action === "remove")
                        Widgets.remove(entry.uid);
                    else if (action.startsWith("size:"))
                        Widgets.setSize(entry.uid, action.substring(5));
                }

                x: host.width - width - Tokens.notificationCenterInset + (host.shown ? 0 : width + Tokens.notificationCenterInset)
                y: Tokens.menubarHeight + Tokens.notificationCenterInset
                width: Tokens.notificationCenterWidth
                height: host.height - y - Tokens.notificationCenterInset
                Accessible.role: Accessible.Window
                Accessible.name: qsTr("Notifications")
                Keys.onEscapePressed: Notifications.closeCenter()

                Behavior on x {
                    NumberAnimation {
                        duration: Appearance.duration(Tokens.motionNormal)
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Appearance.curve
                    }
                }

                ListView {
                    id: list
                    x: -panel.gutter
                    y: -panel.gutter
                    topMargin: panel.gutter
                    width: parent.width + panel.gutter
                    // As tall as its content (the area below the last card is outside the list, so a click there closes);
                    // the footer sits one spacing.lg below it, or at the bottom of the column when the list fills it.
                    height: Math.min(contentHeight + topMargin, Math.max(0, parent.height - y - footer.height - Tokens.spacingLg))
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    model: Notifications.centerModel
                    onCountChanged: Qt.callLater(() => host.surfaces = host.surfaces.filter(r => r.item))
                    header: Item {
                        width: list.width
                        height: Notifications.count === 0 ? emptyText.implicitHeight + 2 * Tokens.spacingLg + Tokens.notificationBannerGap : 0
                        visible: Notifications.count === 0

                        Material {
                            id: emptySurface
                            x: panel.gutter
                            width: parent.width - panel.gutter
                            height: parent.height - Tokens.notificationBannerGap
                            radius: Tokens.radiusBanner
                            shadowEnabled: false
                            Component.onCompleted: host.addSurface(emptySurface, true, Tokens.radiusBanner)
                        }

                        Text {
                            id: emptyText
                            textFormat: Text.PlainText
                            x: panel.gutter + (parent.width - panel.gutter - width) / 2
                            y: Tokens.spacingLg
                            text: qsTr("No Notifications")
                            color: Appearance.colors.textSecondary
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyTitleSize
                            font.weight: Tokens.typographyMenuWeight
                        }
                    }
                    footer: widgetsArea

                    // After a card was cleared with the keyboard: focus goes to the card that took its place (the next
                    // one, or the previous when it was the last), never to an invisible item; the panel when none is left.
                    function focusAfterRemoval(at: int): void {
                        Qt.callLater(() => {
                            const n = list.count;
                            const target = n > 0 ? list.itemAtIndex(Math.min(at, n - 1)) : null;
                            if (target && (target as Item).rowItem)
                                ((target as Item).rowItem as Item).forceActiveFocus();
                            else
                                panel.forceActiveFocus();
                        });
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
                        // The focusable card (see ListView.focusAfterRemoval).
                        readonly property Item rowItem: row
                        // The pointer is over a card of this app, or its group is being cleared.
                        readonly property bool groupHot: host.hoverApp === appName
                        readonly property bool groupLeaving: host.leavingGroup && host.leavingApp === appName
                        // Sliding out to the right, fading: the end of the slide really clears the entry(ies).
                        property real slide: 0
                        property bool leaving: false
                        property bool clearGroupAtEnd: false

                        // Clear this card, or (group) the whole app group, after the slide-out.
                        function beginLeave(group: bool, refocus: bool): void {
                            if (leaving)
                                return;
                            leaving = true;
                            clearGroupAtEnd = group;
                            if (group) {
                                host.leavingApp = appName;
                                host.leavingGroup = true;
                            }
                            leaveAnim.refocus = refocus;
                            leaveAnim.start();
                        }

                        function finishLeave(): void {
                            const at = index;
                            if (clearGroupAtEnd) {
                                Notifications.clearApp(appName);
                                host.leavingGroup = false;
                            } else if (!groupLeaving) {
                                Notifications.clear(key);
                            }
                            if (leaveAnim.refocus)
                                list.focusAfterRemoval(at);
                        }

                        onGroupLeavingChanged: {
                            // The other cards of the group slide out with the header card (which clears the group).
                            if (groupLeaving && !leaving) {
                                leaving = true;
                                leaveAnim.refocus = false;
                                leaveAnim.start();
                            }
                        }
                        onYChanged: host.motionTick++

                        transform: Translate {
                            x: item.slide
                        }

                        ParallelAnimation {
                            id: leaveAnim

                            property bool refocus: false

                            NumberAnimation {
                                target: item
                                property: "slide"
                                to: list.width
                                duration: Appearance.duration(Tokens.motionNormal)
                                easing.type: Easing.BezierSpline
                                easing.bezierCurve: Appearance.curve
                            }

                            NumberAnimation {
                                target: item
                                property: "opacity"
                                to: 0
                                duration: Appearance.duration(Tokens.motionNormal)
                            }

                            onFinished: item.finishLeave()
                        }

                        onSlideChanged: host.motionTick++

                        width: list.width
                        leftPadding: panel.gutter
                        // Groups are set apart; cards of one group are one banner gap apart.
                        topPadding: item.headCount > 0 && !item.headFirst ? Tokens.spacingMd : 0
                        bottomPadding: Tokens.notificationBannerGap

                        Item {
                            id: row

                            readonly property bool hovered: rowHover.hovered
                            readonly property bool live: item.nid >= 0

                            width: item.width - panel.gutter
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
                                    item.beginLeave(false, true);
                                    event.accepted = true;
                                }
                            }

                            onActiveFocusChanged: {
                                if (activeFocus)
                                    list.positionViewAtIndex(item.index, ListView.Contain);
                            }

                            HoverHandler {
                                id: rowHover
                                onHoveredChanged: host.hoverCard(item.appName, hovered)
                            }

                            TapHandler {
                                acceptedButtons: Qt.LeftButton
                                enabled: row.live && !closeHover.hovered && !item.leaving
                                onTapped: row.open()
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

                            // Close (clear) this entry: a small round x on the card's top-left corner, shown on hover or
                            // keyboard focus (Tab reaches it after the card; Space or Return clears).
                            Item {
                                id: closeButton

                                x: -panel.gutter
                                y: -panel.gutter
                                width: Tokens.notificationCloseSize
                                height: width
                                opacity: row.hovered || row.activeFocus || closeHover.hovered || closeButton.activeFocus ? 1 : 0
                                activeFocusOnTab: true
                                Accessible.role: Accessible.Button
                                Accessible.name: qsTr("Close")
                                Accessible.description: item.summary
                                Accessible.focusable: true
                                Accessible.onPressAction: item.beginLeave(false, false)
                                Keys.onPressed: event => {
                                    if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                        item.beginLeave(false, true);
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
                                    onHoveredChanged: host.hoverCard(item.appName, hovered)
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
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: item.beginLeave(false, false)
                                }
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
                                        Component.onCompleted: host.addSurface(cardSurface, true, Tokens.radiusBanner)
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
                                                    onClicked: Notifications.setExpanded(item.appName, false)

                                                    Behavior on opacity {
                                                        NumberAnimation {
                                                            duration: Appearance.duration(Tokens.motionFast)
                                                        }
                                                    }
                                                }

                                                GroupClear {
                                                    id: clearGroup
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    active: item.groupHot
                                                    text: qsTr("Clear All")
                                                    onClicked: item.beginLeave(true, true)
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
                                                onClicked: Notifications.setExpanded(item.appName, true)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Widgets: the footer of the list, so they scroll with the notifications. Each is a glass tile.
                Component {
                    id: widgetsArea

                    Column {
                        width: list.width
                        leftPadding: panel.gutter
                        topPadding: Widgets.center.length > 0 ? Tokens.spacingMd : 0

                        Flow {
                            width: parent.width - panel.gutter
                            spacing: Tokens.widgetGap

                            Repeater {
                                model: Widgets.center

                                delegate: WidgetHost {
                                    id: tile

                                    required property var modelData

                                    entry: modelData
                                    cell: (list.width - panel.gutter - Tokens.widgetGap) / 2
                                    onMenuRequested: (x, y) => panel.openWidgetMenu(tile, x, y, modelData)
                                    onRemoveRequested: {
                                        Widgets.remove(modelData.uid);
                                        panel.forceActiveFocus();
                                    }
                                    Component.onCompleted: host.addSurface(tile, true, Tokens.widgetRadius)
                                    onActiveFocusChanged: {
                                        if (!activeFocus)
                                            return;
                                        const top = tile.mapToItem(list.contentItem, 0, 0).y;
                                        if (top < list.contentY)
                                            list.contentY = top;
                                        else if (top + tile.height > list.contentY + list.height)
                                            list.contentY = top + tile.height - list.height;
                                    }
                                }
                            }
                        }
                    }
                }

                // Footer (macOS model): Edit Widgets and the close circle, centred under the column, one spacing.lg below
                // the last card. No Clear All here: it lives on the group headers.
                Row {
                    id: footer
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: Math.min(list.y + list.height + Tokens.spacingLg, parent.height - height)
                    height: Tokens.notificationCenterCloseDisk
                    spacing: Tokens.spacingSm

                    Pill {
                        surfaceHost: host
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Edit Widgets")
                        onClicked: panel.galleryOpen = true
                    }

                    Item {
                        id: closeDisk
                        width: Tokens.notificationCenterCloseDisk
                        height: width
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: qsTr("Close")
                        Accessible.focusable: true
                        Accessible.onPressAction: Notifications.closeCenter()
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                Notifications.closeCenter();
                                event.accepted = true;
                            }
                        }

                        Material {
                            id: closeSurface
                            anchors.fill: parent
                            radius: width / 2
                            shadowEnabled: false
                            Component.onCompleted: host.addSurface(closeSurface, false, Math.floor(width / 2))
                        }

                        Icon {
                            anchors.centerIn: parent
                            size: parent.width - Tokens.notificationCloseGlyphInset
                            name: "close-glyph"
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: width / 2
                            color: "transparent"
                            border.width: closeDisk.activeFocus ? Tokens.controlFocusRing : 0
                            border.color: Appearance.colors.accent
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Notifications.closeCenter()
                        }
                    }
                }

                // Widget context menu (sizes, Remove Widget) at the click or the focused tile.
                MouseArea {
                    anchors.fill: parent
                    visible: panel.menuEntry !== null
                    acceptedButtons: Qt.AllButtons
                    onPressed: panel.closeWidgetMenu()
                }

                Loader {
                    id: widgetMenu
                    active: panel.menuEntry !== null
                    x: Math.max(Tokens.spacingSm, Math.min(panel.menuX, panel.width - width - Tokens.spacingSm))
                    y: Math.max(Tokens.spacingSm, Math.min(panel.menuY, panel.height - height - Tokens.spacingSm))
                    sourceComponent: WidgetMenu {
                        entry: panel.menuEntry
                        onChoose: action => panel.applyWidgetMenu(action)
                        onCloseRequested: panel.closeWidgetMenu()
                        Component.onCompleted: forceActiveFocus()
                    }
                }

                Loader {
                    id: gallery
                    anchors.fill: parent
                    active: panel.galleryOpen
                    sourceComponent: WidgetGallery {
                        screenName: win.modelData.name
                        onClosed: {
                            panel.galleryOpen = false;
                            panel.forceActiveFocus();
                        }
                        Component.onCompleted: forceActiveFocus()
                    }
                }
            }
        }
    }
}
