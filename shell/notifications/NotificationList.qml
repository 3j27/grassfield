pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "CenterLogic.js" as CenterLogic

// The list of the Notifications column (NotificationCenter.qml): the cards grouped by app, newest first. Keyboard focus belongs
// to the cards and their controls (never to the view's current item), Tab and Shift+Tab walk them in visual order.
// ONE focus invariant covers the whole column (resolveFocus): the element that holds the keyboard focus never disappears from
// under it. Whatever changes the model or the visibility of a control (arrivals, closes, expiries, Show All / Show Less, the
// sender's actions going away...), a resolver runs once per event-loop turn after the change and, when the focused element is
// gone, hidden or disabled, moves the focus to the nearest focusable element of the CURRENT layout; no event carries focus logic
// of its own. Layout positions are always the model's: a card whose place changed only animates a visual offset back to 0. Its
// own file so that the tests (tests/shell/notif_center_list) run this very component.

ListView {
    id: list

    // The surface host (the column): blur surfaces (addSurface) and the hovered group (hoverApp, hoverCard).
    required property var host
    // The column's focus scope: its gutter (room left of the cards for their x) and the focus fallback.
    required property var panel
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
        // Tells whether the card that carries this control can still be acted on (see the delegate's `actable`).
        property var gate: null
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
        // The same guard as its keys below (R12): never a hidden control, a disabled one, or one whose card is leaving.
        Accessible.onPressAction: if (ctl.visible && ctl.enabled && (!ctl.gate || ctl.gate()))
            ctl.clicked()
        Keys.onPressed: event => {
            // A hidden control, or one of a card that left the rows in this very turn, never acts, whatever still holds the focus;
            // its activation keys are swallowed (they would otherwise bubble up to the card and act there) and the resolver is
            // queued; every other key (Escape...) propagates.
            if (!ctl.visible || !ctl.enabled || (ctl.gate && !ctl.gate())) {
                const activation = event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter;
                event.accepted = activation;
                if (activation)
                    list.queueResolve();
                return;
            }
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
    // Keyboard focus belongs to the cards and their controls, never to the view's current item: the view moves
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

    // ---- The focus invariant ----
    // The focus target is a stable identity, never an item: {key (card), role, app, rank (card's rank in its group), cidx}.
    // Roles: "card", "close" (the x), "clearGroup" (header Clear All), "showLess", "showAll", "more", "action:<id>".
    // null while the focus is outside the cards (panel, Edit Widgets, the close circle: those are left alone).
    property var focusId: null
    // The displayed rows ({key, appName}) as of the last settled state: only the visual neighbourhood of a card that is
    // gone (what exists now always comes from the model, never from here).
    property var snapRows: []
    // A control the focus must go to once it exists ({app, role}): Show All hands the focus to Show Less and back (macOS
    // keeps the focus on the stack control).
    property var intent: null
    property bool resolveQueued: false

    // The displayed rows now, in display order.
    function shownRows(): var {
        const out = [];
        for (let i = 0; i < Notifications.centerModel.count; i++) {
            const r = Notifications.centerModel.get(i);
            out.push({key: r.key, appName: r.appName});
        }
        return out;
    }

    function rankIn(rows: var, key: string): int {
        const at = rows.findIndex(r => r.key === key);
        if (at < 0)
            return 0;
        let rank = 0;
        for (let i = 0; i < at; i++) {
            if (rows[i].appName === rows[at].appName)
                rank++;
        }
        return rank;
    }

    // The delegate showing `key` (not one on its way out); with `bringIn`, one outside the viewport and its buffer is built.
    // The delegate at an index and the item that holds the keyboard focus, as untyped values: the delegates carry roles and
    // functions of their own (key, removing, controls...) that a QQuickItem type does not declare.
    function at(i: int): var {
        return list.itemAtIndex(i);
    }

    function activeItem(): var {
        return list.Window.activeFocusItem;
    }

    function delegateFor(key: string, bringIn: bool): var {
        for (let pass = 0; pass < 2; pass++) {
            for (let i = 0; i < list.count; i++) {
                const it = list.at(i);
                if (it && it.key === key && !it.removing)
                    return it;
            }
            const at = bringIn ? list.shownRows().findIndex(r => r.key === key) : -1;
            if (at < 0)
                break;
            list.positionViewAtIndex(at, ListView.Contain);
            list.forceLayout();
        }
        return null;
    }

    // Visible, enabled (a card on its way out is disabled): what a key may act on and focus may rest on.
    function usable(it: var): bool {
        return it !== null && it !== undefined && it.visible && it.enabled;
    }

    // The control `role` of the delegate `d`, or null when it does not exist or is not usable now.
    function controlOf(d: var, role: string): var {
        for (const c of d.controls()) {
            if (c.role === role)
                return list.usable(c.item) ? c.item : null;
        }
        return null;
    }

    // The usable item an identity stands for now, or null.
    function itemOf(who: var): var {
        const d = list.delegateFor(who.key, false);
        return d ? list.controlOf(d, who.role) : null;
    }

    // The identity of the focus when it is on a card or one of its controls (usable or not), else null.
    function identityOf(f: var): var {
        for (let p = f; p; p = p.parent) {
            if (p.rowItem === undefined || p.key === undefined)
                continue;
            // An item that is none of the card's controls (the focus scope a destroyed button left it on) names no element: lost.
            let role = "";
            let cidx = -1;
            let n = 0;
            for (const c of p.controls()) {
                const content = c.role === "more" || c.role.startsWith("action:");
                if (c.item === f) {
                    role = c.role;
                    cidx = content ? n : -1;
                    break;
                }
                if (content)
                    n++;
            }
            return {key: p.key, role: role, app: p.appName, rank: 0, cidx: cidx};
        }
        return null;
    }

    // The focus moved (or something it sat on went away): remember where it is.
    function noteFocus(): void {
        let who = list.identityOf(list.activeItem());
        if (who && who.role === "" && list.focusId !== null && list.focusId.key === who.key)
            who = list.focusId;
        if (who) {
            // The settled rows are the "before" of the next change, unless one is already waiting to be resolved.
            if (!list.resolveQueued)
                list.snapRows = list.shownRows();
            who.rank = list.rankIn(list.snapRows, who.key);
            list.focusId = who;
            if (!list.itemOf(who))
                list.queueResolve();
        } else if (list.focusId !== null) {
            // Focus left the cards on purpose (Edit Widgets, the close circle: forget it), or Qt dropped it onto the list or the
            // panel because the item that held it was destroyed or rebuilt: the resolver gives it back.
            const f = list.activeItem();
            if (f && !list.droppedFocus(f) && list.identityOf(f) === null)
                list.focusId = null;
            else
                list.queueResolve();
        }
    }

    // The focus sits where Qt leaves it when the item that held it goes away: the list, its content or the panel.
    function droppedFocus(f: var): bool {
        return f === list || f === list.contentItem || f === list.panel;
    }

    // The focus is taken to be on this card, whatever holds it now (accessibility paths that act on a card: the clear that
    // follows moves the focus on from there).
    function adopt(key: string, app: string): void {
        list.snapRows = list.shownRows();
        list.focusId = {key: key, role: "card", app: app, rank: list.rankIn(list.snapRows, key), cidx: -1};
    }

    // Show All and Show Less hand the focus to each other.
    function handoff(app: string, role: string): void {
        list.intent = {app: app, role: role};
        list.queueResolve();
    }

    // Runs the resolver once per event-loop turn, however many changes happened in it.
    function queueResolve(): void {
        if (list.resolveQueued)
            return;
        list.resolveQueued = true;
        Qt.callLater(list.resolveFocus);
    }

    // The control an intent names, if it exists now.
    function intentTarget(intent: var): var {
        for (let i = 0; i < list.count; i++) {
            const d = list.at(i);
            if (!d || d.removing || d.appName !== intent.app)
                continue;
            const c = list.controlOf(d, intent.role);
            if (c)
                return c;
        }
        return null;
    }

    // Where the focus goes when the element `who` is gone, hidden or disabled: in the current layout, the same group's slot,
    // else the same card, else the next group, the previous one; null when no card is left.
    function nearestTo(who: var): var {
        let d = list.delegateFor(who.key, true);
        if (!d) {
            // The card left the displayed rows (any number of changes since the last settled state).
            const rows = list.shownRows();
            const key = CenterLogic.focusAfterGone({key: who.key, app: who.app, rank: who.rank}, list.snapRows.map(r => r.key), rows);
            d = key !== "" ? list.delegateFor(key, true) : null;
            if (!d)
                return null;
            // A stack control moves with its group: the one that takes its place keeps the focus. Anything destructive or
            // sender-defined (x, Clear All, actions) never lands under the focus by itself: the card does.
            if (who.role === "showAll" || who.role === "showLess") {
                const c = list.controlOf(d, who.role);
                if (c)
                    return c;
            }
            return list.controlOf(d, "card");
        }
        if (who.cidx >= 0) {
            // The sender's buttons: the one now at the place of the lost one (More revealing the rest lands on the first
            // revealed button), else the card.
            const own = d.controls().filter(c => (c.role === "more" || c.role.startsWith("action:")) && list.usable(c.item));
            if (own.length > 0)
                return own[Math.min(who.cidx, own.length - 1)].item;
        }
        return list.controlOf(d, "card");
    }

    // The focus goes to the panel: whatever holds it inside the list lets go first (the panel's focus scope would otherwise keep
    // the child that already holds it).
    function releaseFocus(): void {
        // An explicit leave: nothing to give back.
        list.focusId = null;
        const chain = [];
        for (let it = list.activeItem(); it && it !== list.panel; it = it.parent)
            chain.push(it);
        chain.forEach(it => it.focus = false);
        list.panel.forceActiveFocus();
    }

    // The resolver: once per turn after any model or visibility change. If the focused element is still there it does nothing;
    // otherwise the focus moves, visibly, to the nearest element that is.
    function resolveFocus(): void {
        list.resolveQueued = false;
        const win = list.Window.window;
        const intent = list.intent;
        list.intent = null;
        if (!win)
            return;
        // Apply the model changes first: the layout they trigger would otherwise move the focus again afterwards.
        list.forceLayout();
        const who = list.focusId;
        if (who === null)
            return;
        const cur = list.itemOf(who);
        if (cur) {
            const f = list.activeItem();
            if (cur.activeFocus) {
                list.settle(cur);
            } else if (f && (list.droppedFocus(f) || list.identityOf(f) !== null)) {
                // The element is still there but the focus fell off it (its button was rebuilt by an update, the card left the rows
                // and came back in the same turn): give it back, so the ring is on it.
                cur.forceActiveFocus();
                list.settle(cur);
            } else {
                list.focusId = null;
            }
            return;
        }
        let target = intent ? list.intentTarget(intent) : null;
        if (!target)
            target = list.nearestTo(who);
        if (target) {
            target.forceActiveFocus();
            list.settle(target);
        } else {
            list.focusId = null;
            list.releaseFocus();
            list.snapRows = list.shownRows();
        }
    }

    // The focus rests on `item` in the settled layout: its identity is rebuilt from the layout as it is NOW (rank in its group,
    // position among the sender's buttons: both move when cards arrive or leave around a card that itself stays), and the settled
    // rows become the "before" of the next change.
    function settle(item: var): void {
        const rows = list.shownRows();
        const who = list.identityOf(item);
        who.rank = list.rankIn(rows, who.key);
        list.focusId = who;
        list.snapRows = rows;
    }

    // The card `key` is one of the displayed rows now (the model, which changes at once, not the delegates, which follow at the
    // next layout).
    function liveKey(key: string): bool {
        return Notifications.shownKeys.indexOf(key) >= 0;
    }

    Connections {
        target: list.Window.window
        ignoreUnknownSignals: true

        function onActiveFocusItemChanged(): void {
            list.noteFocus();
        }
    }

    // Any change of the displayed rows or of what a row shows (a control hidden by a role change).
    Connections {
        target: Notifications.centerModel

        function onRowsInserted(): void {
            list.queueResolve();
        }

        function onRowsRemoved(): void {
            list.queueResolve();
        }

        function onRowsMoved(): void {
            list.queueResolve();
        }

        function onDataChanged(): void {
            list.queueResolve();
        }

        function onModelReset(): void {
            list.queueResolve();
        }
    }

    Component.onCompleted: list.snapRows = list.shownRows()
    // The card (delegate) that holds the keyboard focus, or its x or buttons: null when the focus is elsewhere.
    function focusedDelegate(): var {
        for (let f = list.activeItem(); f; f = f.parent) {
            if (f.rowItem !== undefined && f.key !== undefined)
                return f;
        }
        return null;
    }

    // Tab order. Qt's focus chain follows the order the delegates were CREATED in (cards that arrived later
    // sit above the older ones), so Tab and Shift+Tab are stepped here whenever they would leave a card:
    // the regions are the cards top to bottom (their index), then the widgets (index count), then the
    // footer controls. Inside a card Qt's own order (card, x, buttons) is right and is kept.
    function regionOf(it: var): int {
        for (let p = it; p; p = p.parent) {
            if (p.rowItem !== undefined && p.key !== undefined && p.removing === false)
                return p.index;
            if (p === list.footerItem)
                return list.count;
        }
        return -1;
    }

    // The last item of the chain that stays in region r, from `from`.
    function lastIn(from: var, r: int): var {
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
    function regionEntry(t: int, forward: bool): var {
        if (t < 0 || t > list.count)
            return null;
        if (t === list.count) {
            const nx = list.footerItem ? list.footerItem.nextItemInFocusChain(true) : null;
            if (!nx || list.regionOf(nx) !== list.count)
                return null;
            return forward ? nx : list.lastIn(nx, list.count);
        }
        let d = list.at(t);
        if (!d) {
            list.positionViewAtIndex(t, ListView.Contain);
            list.forceLayout();
            d = list.at(t);
        }
        if (!d || d.removing)
            return null;
        return forward ? d.rowItem : list.lastIn(d.rowItem, t);
    }

    // Moves the focus one step in visual order. Where Qt's own next item is the right one (inside a card,
    // between the footer controls) that item is focused, exactly as Qt does for Tab.
    function tabStep(forward: bool): void {
        const f = list.activeItem();
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
        // The focusable card.
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
        property Item clearGroupCtl: null
        property var contentCtl: null

        // This card can be acted on through `it` (one of its items) right now: the item is visible and enabled and the card is one
        // of the displayed rows. Checked by every key handler at key time, since a change of the same turn is applied to the
        // delegates only by the next layout.
        function actable(it: var): bool {
            return !removing && list.usable(it) && list.liveKey(key);
        }

        // The focusable items of this card in Tab order, usable or not: {role, item}. The focus resolver
        // (NotificationList.resolveFocus) names focus targets by key and role, never by item.
        function controls(): var {
            const out = [
                {role: "card", item: row},
                {role: "close", item: closeButton}
            ];
            if (showLessCtl)
                out.push({role: "showLess", item: showLessCtl});
            if (clearGroupCtl)
                out.push({role: "clearGroup", item: clearGroupCtl});
            if (contentCtl)
                out.push(...contentCtl.focusItems());
            if (toggleCtl)
                out.push({role: "showAll", item: toggleCtl});
            return out;
        }

        // Clears this card, or (group) the entries of its app group that exist now. The model changes at once
        // (history, "No Notifications", persistence); this delegate only animates out. Where the focus goes is
        // the resolver's (it was on this card or its group: it moves on; accessibility paths with the focus
        // elsewhere (`refocus`) move it to the card that follows; a focus on another card stays).
        function clearCard(group: bool, refocus: bool): void {
            if (removing || !list.liveKey(key))
                return;
            if (refocus && list.focusedDelegate() === null)
                list.adopt(key, appName);
            if (group)
                Notifications.clearKeys(Notifications.keysOf(appName));
            else
                Notifications.clear(key);
        }

        // A card on its way out takes no input and gets no focus.
        enabled: !removing
        ListView.onRemove: {
            enter.stop();
            item.removing = true;
            list.queueResolve();
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
                const open = event.key === Qt.Key_Return || event.key === Qt.Key_Enter;
                const clear = event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace;
                if (!open && !clear)
                    return;
                event.accepted = true;
                // The card must still be there, visible and displayed (a change of this very turn may have taken it out before the
                // resolver ran): else nothing happens and the resolver is queued.
                if (!item.actable(row)) {
                    list.queueResolve();
                    return;
                }
                // Return opens only when the card itself has the focus (not from a stray child such as the actions Loader); Delete
                // and Backspace only on the card and its x: on Show All, More, an action or Clear All the key does nothing.
                if (open && row.activeFocus)
                    row.open();
                else if (clear && (row.activeFocus || closeButton.activeFocus))
                    item.clearCard(false, true);
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
                        event.accepted = true;
                        if (item.actable(closeButton))
                            item.clearCard(false, true);
                        else
                            list.queueResolve();
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
                                    onVisibleChanged: list.queueResolve()
                                    onClicked: {
                                        if (!item.actable(showLess)) {
                                            list.queueResolve();
                                            return;
                                        }
                                        const kbd = showLess.activeFocus;
                                        Notifications.setExpanded(item.appName, false);
                                        if (kbd)
                                            list.handoff(item.appName, "showAll");
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
                                    gate: () => item.actable(clearGroup)
                                    Component.onCompleted: item.clearGroupCtl = clearGroup
                                    onVisibleChanged: list.queueResolve()
                                    text: qsTr("Clear All")
                                    onClicked: item.clearCard(true, false)
                                }
                            }
                        }

                        NotificationContent {
                            id: rowContent
                            width: parent.width
                            Component.onCompleted: item.contentCtl = rowContent
                            onControlsChanged: list.queueResolve()
                            summary: item.summary
                            appName: item.appName
                            urgency: item.urgency
                            actionsJson: item.actionsJson
                            live: row.live
                            body: Notifications.bodyFor(item.bodyHtml)
                            timeText: Notifications.timeFor(item.time)
                            iconSource: Notifications.iconSource(item.image, item.appIcon)
                            onActionTriggered: actionId => {
                                if (item.actable(rowContent))
                                    Notifications.invokeAction(item.key, actionId);
                                else
                                    list.queueResolve();
                            }
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
                                onVisibleChanged: list.queueResolve()
                                onClicked: {
                                    if (!item.actable(toggle)) {
                                        list.queueResolve();
                                        return;
                                    }
                                    const kbd = toggle.activeFocus;
                                    Notifications.setExpanded(item.appName, true);
                                    if (kbd)
                                        list.handoff(item.appName, "showLess");
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
