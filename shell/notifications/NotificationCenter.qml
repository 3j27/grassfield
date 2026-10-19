pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.services
import qs.widgets
import "CenterLogic.js" as CenterLogic

// Notifications column (N7, internal Notification Center): the macOS model. No full-height panel:
// a column of floating glass cards as wide as a banner, at the right under the menu bar, opened from the clock or
// by IPC. No title: the cards grouped by app, newest first (the first card of a group carries the app name, its
// count and, on hover or focus, "Show Less" and a round x that grows into a "Clear All" pill; the last visible
// one carries Show All), then the widgets placed there; a footer of an Edit Widgets pill (gallery overlay,
// docs/specs/widgets.md) and a close circle, centred one spacing.lg below the last card. No permanent global Clear All
// (macOS 26 model): a card shows a round x at its top-left corner on hover or focus. A clear takes effect in the
// model at once (history, "No Notifications", persistence); the column only animates it: the removed cards slide out
// to the right while they fade (ListView remove transition) and the cards below slide up (displaced), so closing
// the column mid-animation never loses a clear. A card that arrives while the column is open slides in and fades in.
// Reduce Motion: nothing slides, cards only fade (Appearance.duration caps the fade). Every card is its own surface with its own blur region
// (registered by the card, see addSurface). Esc or a click outside the cards closes.
//
// The window exists per screen but its content (a Loader) only while the Center is open on that
// screen, so a closed Center costs nothing. Rows come from the keyed Notifications.centerModel
// (displayed rows only, ordered by group; the first row of a group draws its header), so new notifications never rebuild the list.
// Keyboard: Tab moves between rows and buttons in visual order (tabStep), Return opens the row's default action, Delete or
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
                Component.onCompleted: pill.surfaceHost.addSurface(pillSurface, false, Math.floor(height / 2), null)
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
                cursorShape: Qt.ArrowCursor
                onClicked: pill.clicked()
            }
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

        component CenterContent: Item {
            id: host

            readonly property Item panel: panel
            // One blur region per glass surface (cards, title capsule, widgets, footer).
            readonly property var regionList: regions.instances
            // Slides in from the right edge after creation.
            property bool shown: false
            // Registered glass surfaces: {id, item, clip (inside the list viewport), radius, fader (the card whose
            // opacity the blur follows, or null)}. Destroyed items read as null and are dropped a little after a row
            // left, and when a surface registers. Every record carries a unique id: Variants ignores (and warns
            // about) equal values, which dead records ({item: null, ...}) otherwise are.
            property var surfaces: []
            property int surfaceSeq: 0
            // Counts the frames of a card sliding out or of the column reflowing (their surfaces move without the
            // list geometry changing), so the blur regions follow the cards.
            property int motionTick: 0
            property bool tickQueued: false
            // Bumps motionTick once per animation frame, however many cards moved in it (every region re-reads its rectangle
            // on a bump: 600 bumps a frame for 200 sliding cards made each frame cost 30 to 50 ms).
            function bumpTick(): void {
                if (tickQueued)
                    return;
                tickQueued = true;
                Qt.callLater(() => {
                    host.tickQueued = false;
                    host.motionTick++;
                });
            }
            // Anything that moves or resizes a surface without changing its own geometry.
            readonly property real tick: list.contentY + list.contentHeight + list.count + list.height + panel.x + panel.y + motionTick
            // The app the pointer is over (group controls), and how many hover handlers of each app are active.
            property string hoverApp: ""
            property var hoverCounts: ({})

            Timer {
                id: hoverRelease
                interval: Appearance.duration(Tokens.motionFast)
                onTriggered: {
                    if (!CenterLogic.isHovered(host.hoverCounts, host.hoverApp))
                        host.hoverApp = "";
                }
            }

            // Drops the records of destroyed cards (their slide-out has ended).
            Timer {
                id: pruneSurfaces
                interval: 2 * Appearance.duration(Tokens.motionNormal) + 1
                onTriggered: host.surfaces = host.surfaces.filter(r => r.item)
            }

            // A pointer on a card of an app group (the card or the x on its corner), or leaving it (a short grace
            // covers the gap between two cards). Counted per hover handler: the x sticks out of the card, so the pointer
            // can enter the x before it leaves the card or the other way round.
            function hoverCard(app: string, over: bool): void {
                hoverCounts = CenterLogic.hoverStep(hoverCounts, app, over);
                if (over) {
                    hoverRelease.stop();
                    hoverApp = app;
                } else if (hoverApp === app && !CenterLogic.isHovered(hoverCounts, app)) {
                    hoverRelease.restart();
                }
            }

            function addSurface(item: Item, clip: bool, radius: real, fader: Item): void {
                surfaceSeq++;
                surfaces = surfaces.filter(r => r.item).concat([{id: surfaceSeq, item: item, clip: clip, radius: radius, fader: fader}]);
            }

            // Rectangle of a surface in window coordinates, cut to the list viewport for rows (left and right too: a card
            // sliding out stops at the column edge) and shrunk about its centre as its card fades, so the blur never
            // outlives the glass.
            function rectOf(rec: var): rect {
                const it = rec.item as Item;
                if (!it)
                    return Qt.rect(0, 0, 0, 0);
                // A card that has faded out has no glass left: nothing to map.
                const fade = rec.fader as Item;
                if (fade && fade.opacity <= 0)
                    return Qt.rect(0, 0, 0, 0);
                const p = it.mapToItem(null, 0, 0);
                let left = p.x;
                let right = p.x + it.width;
                let top = p.y;
                let bottom = p.y + it.height;
                if (rec.clip) {
                    const v = list.mapToItem(null, 0, 0);
                    left = Math.max(left, v.x);
                    right = Math.min(right, v.x + list.width);
                    top = Math.max(top, v.y);
                    bottom = Math.min(bottom, v.y + list.height);
                }
                const w = Math.max(0, right - left);
                const h = Math.max(0, bottom - top);
                const fader = rec.fader as Item;
                const f = fader ? Math.max(0, Math.min(1, fader.opacity)) : 1;
                return Qt.rect(left + w * (1 - f) / 2, top + h * (1 - f) / 2, w * f, h * f);
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

                // Tab and Shift+Tab reach every card in visual order (ListView.tabStep). A shortcut, because Qt moves the
                // focus along its own chain as soon as the focused item leaves the key unhandled, before any parent
                // sees it. Off while the widget gallery or a widget menu has the keyboard.
                Shortcut {
                    sequence: "Tab"
                    enabled: win.open && !panel.galleryOpen && panel.menuEntry === null
                    onActivated: list.tabStep(true)
                }

                Shortcut {
                    sequences: ["Shift+Tab", "Backtab"]
                    enabled: win.open && !panel.galleryOpen && panel.menuEntry === null
                    onActivated: list.tabStep(false)
                }

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
                    // Keyboard focus belongs to the cards (focusKey), never to the view's current item: the view moves
                    // focus onto the current delegate whenever a row is inserted or removed at or above it, which took it
                    // off the focused card.
                    currentIndex: -1
                    highlightFollowsCurrentItem: false
                    keyNavigationEnabled: false
                    onCountChanged: pruneSurfaces.restart()
                    // Reduce Motion (macOS: slides become fades): nothing moves, cards fade in and out within the
                    // capped duration (Appearance.duration); otherwise motion.normal.
                    readonly property bool still: Appearance.reduceMotion
                    readonly property int moveDuration: still ? 0 : Appearance.duration(Tokens.motionNormal)
                    readonly property int fadeDuration: Appearance.duration(Tokens.motionNormal)
                    // The cards below a removed or added card slide to their new place, a removed card slides out to the
                    // right while it fades (the model already changed: these only animate the delegates the view keeps for
                    // it). A card that ARRIVES while the column is open slides in from the right while it fades in, run by the
                    // delegate itself (enter): the view's own `add` transition also runs for the rows a "Show All" reveals and
                    // left the cards at stale positions when the row above changed height. A transition can be cut short by
                    // the next one (a burst of arrivals): displaced and move take slide and opacity to their final values
                    // (0 and 1), or a card would stay half in.
                    displaced: Transition {
                        ParallelAnimation {
                            NumberAnimation {
                                property: "y"
                                duration: list.moveDuration
                                easing.type: Easing.BezierSpline
                                easing.bezierCurve: Appearance.curve
                            }

                            NumberAnimation {
                                property: "slide"
                                to: 0
                                duration: list.moveDuration
                                easing.type: Easing.BezierSpline
                                easing.bezierCurve: Appearance.curve
                            }

                            NumberAnimation {
                                property: "opacity"
                                to: 1
                                duration: list.fadeDuration
                            }
                        }
                    }
                    move: Transition {
                        ParallelAnimation {
                            NumberAnimation {
                                property: "y"
                                duration: list.moveDuration
                                easing.type: Easing.BezierSpline
                                easing.bezierCurve: Appearance.curve
                            }

                            NumberAnimation {
                                property: "slide"
                                to: 0
                                duration: list.moveDuration
                                easing.type: Easing.BezierSpline
                                easing.bezierCurve: Appearance.curve
                            }

                            NumberAnimation {
                                property: "opacity"
                                to: 1
                                duration: list.fadeDuration
                            }
                        }
                    }
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
                            x: panel.gutter
                            width: parent.width - panel.gutter
                            height: parent.height - Tokens.notificationBannerGap
                            radius: Tokens.radiusBanner
                            shadowEnabled: false
                            Component.onCompleted: host.addSurface(emptySurface, true, Tokens.radiusBanner, null)
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

                    // Focus goes to the card with this key (found by key: the removed delegates stay in the view until their leave
                    // animation ends), never to an invisible item; the panel when none is left.
                    function focusKey(key: string): void {
                        Qt.callLater(() => {
                            // Apply the removal first: the layout it triggers would otherwise take the focus away again.
                            list.forceLayout();
                            for (let i = 0; key !== "" && i < list.count; i++) {
                                const it = list.itemAtIndex(i);
                                if (it && it.key === key && it.rowItem) {
                                    it.rowItem.forceActiveFocus();
                                    return;
                                }
                            }
                            panel.forceActiveFocus();
                        });
                    }
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
                                dest = forward ? editPill : closeDisk;
                        } else if (f === panel || f === list || f === list.contentItem) {
                            // Nothing focused yet: Tab starts at the top card, Shift+Tab at the last control.
                            dest = forward ? list.regionEntry(0, true) : closeDisk;
                        } else if (f === closeDisk && forward) {
                            dest = list.regionEntry(0, true);
                        } else if (f === editPill && !forward) {
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
                        readonly property bool groupHot: host.hoverApp === appName
                        // Slide of the leave animation (list.remove) and whether this delegate is already out of the model.
                        property real slide: 0
                        property bool removing: false

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
                            if (group)
                                Notifications.clearKeys(Notifications.keysOf(app));
                            else
                                Notifications.clear(key);
                            if (refocus || lost)
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
                        onYChanged: host.bumpTick()
                        onOpacityChanged: host.bumpTick()
                        onSlideChanged: host.bumpTick()

                        transform: Translate {
                            x: item.slide
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
                                onHoveredChanged: host.hoverCard(item.appName, hovered)
                                // A removed card under the pointer never reports the leave.
                                Component.onDestruction: {
                                    if (hovered)
                                        host.hoverCard(item.appName, false);
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
                                    onHoveredChanged: host.hoverCard(item.appName, hovered)
                                    Component.onDestruction: {
                                        if (hovered)
                                            host.hoverCard(item.appName, false);
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
                                        Component.onCompleted: host.addSurface(cardSurface, true, Tokens.radiusBanner, item)
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
                                    Component.onCompleted: host.addSurface(tile, true, Tokens.widgetRadius, null)
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
                    onYChanged: host.bumpTick()

                    // Glides with the cards when the list shrinks or grows.
                    Behavior on y {
                        NumberAnimation {
                            duration: Appearance.duration(Tokens.motionNormal)
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: Appearance.curve
                        }
                    }

                    Pill {
                        id: editPill
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
                            Component.onCompleted: host.addSurface(closeSurface, false, Math.floor(width / 2), null)
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
                            cursorShape: Qt.ArrowCursor
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
