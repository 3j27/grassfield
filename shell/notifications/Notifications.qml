pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import Grassfield.Ui
import qs.platform
import qs.services
import "CenterLogic.js" as CenterLogic
import "History.js" as History
import "Sanitizer.js" as Sanitizer

// The session's org.freedesktop.Notifications server, banner queue, history (ADR-0004) and
// Notification Center state. Spec: docs/specs/notifications.md.
//
// - history: plain array of entries as in History.js (+ bodyHtml, sanitized once on arrival),
//   newest first, persisted to notifications.json (0600). Not bound to by the UI.
// - centerModel / bannerModel: keyed ListModels the UI views. They are updated in place
//   (insert / remove / set by key), never rebuilt, so a new notification costs O(entries) JS
//   and no delegate churn.
// - Banner expiry only hides the banner; the notification stays in the history (and stays
//   actionable while the sender keeps it alive). One Timer per shown banner lives here, not in
//   the delegates, so hover pauses exactly the timer that matters.
Singleton {
    id: root

    // ---- state ----
    property var history: []
    property int count: 0
    readonly property ListModel centerModel: centerStore
    readonly property ListModel bannerModel: bannerStore
    readonly property int bannerCount: bannerStore.count
    readonly property bool dnd: Settings.notificationsDnd
    readonly property bool previewsHidden: Settings.notificationsPreviews === "never"
    // Wall clock for relative times, refreshed every 30 s.
    property real nowMs: Date.now()

    // "disabled" (dev session on the shared bus), "starting", "active", "external" (another
    // server owns the name: degraded, banners never appear).
    property string serverState: "starting"
    property bool historyReady: false
    property int counter: 0

    property bool centerOpen: false
    // Key focus returns to the window active when the center opened (FocusReturn).
    onCenterOpenChanged: {
        if (centerOpen)
            FocusReturn.opened("notification-center");
        else
            FocusReturn.closed("notification-center", true);
    }
    property string centerScreen: ""

    // Dev sessions share the owner's session bus; never register there (GRASSFIELD_PRIVATE_BUS=1
    // runs the nested shell on its own bus, see docs/specs/notifications.md).
    readonly property bool devSession: Quickshell.env("GRASSFIELD_DEV") === "1"
    readonly property bool privateBus: Quickshell.env("GRASSFIELD_PRIVATE_BUS") === "1"
    readonly property bool serverEnabled: !devSession || privateBus

    // GRASSFIELD_STATE_HOME (dev) wins; otherwise $XDG_STATE_HOME/grassfield.
    readonly property string stateDir: {
        const dev = Quickshell.env("GRASSFIELD_STATE_HOME");
        if (dev)
            return dev;
        const xdg = Quickshell.env("XDG_STATE_HOME");
        return (xdg ? xdg : Quickshell.env("HOME") + "/.local/state") + "/grassfield";
    }
    readonly property string historyPath: stateDir + "/notifications.json"

    // Live Notification objects by entry key (not reactive).
    property var liveByKey: ({})
    // Banner expiry timers by key (not reactive).
    property var bannerTimers: ({})
    // Keys of banners under the pointer (a timer recreated by an update starts paused).
    property var heldKeys: ({})

    ListModel {
        id: centerStore
        dynamicRoles: true
    }

    ListModel {
        id: bannerStore
        dynamicRoles: true
    }

    // ---- API used by the UI ----

    // Sanitized body (computed once per entry); empty when previews are hidden.
    function bodyFor(bodyHtml: string): string {
        return previewsHidden ? "" : bodyHtml;
    }

    // Image (hint) first, then the app icon (theme name or path); "" when none resolves, so the
    // UI falls back to the bell tile without asking Qt for a missing icon.
    function iconSource(image: string, appIcon: string): string {
        if (image) {
            // An absolute local path (image://icon//abs/path or a plain path) loads as given.
            const local = History.absoluteImage(image);
            if (local !== "")
                return local;
            // Quickshell reports a themed app_icon name as image://icon/<name>.
            const themed = "image://icon/";
            if (image.startsWith(themed) && image.indexOf("?") < 0) {
                let name = "";
                try {
                    name = decodeURIComponent(image.slice(themed.length));
                } catch (e) {
                    return "";
                }
                return Quickshell.hasThemeIcon(name) ? image : "";
            }
            return image;
        }
        const icon = appIcon;
        if (!icon)
            return "";
        if (icon.startsWith("/"))
            return "file://" + icon;
        if (icon.startsWith("file:"))
            return icon;
        // iconPath(name, true) still yields an image://icon URL for a missing icon (Qt then warns
        // and paints a checkerboard), so ask the theme first.
        return Quickshell.hasThemeIcon(icon) ? Quickshell.iconPath(icon) : "";
    }

    // "now", "5m ago", "3h ago", "2d ago" (translatable).
    function timeFor(time: real): string {
        const r = History.relativeParts(time, nowMs);
        switch (r.unit) {
        case "m":
            return qsTr("%1m ago").arg(r.n);
        case "h":
            return qsTr("%1h ago").arg(r.n);
        case "d":
            return qsTr("%1d ago").arg(r.n);
        default:
            return qsTr("now");
        }
    }

    function groupLabel(appName: string): string {
        return appName !== "" ? appName : qsTr("Notification");
    }

    function entryFor(key: string): var {
        for (let i = 0; i < history.length; i++) {
            if (history[i].key === key)
                return history[i];
        }
        return null;
    }

    function isLive(key: string): bool {
        const e = entryFor(key);
        return e !== null && e.nid >= 0;
    }

    // Shell-originated notice (no D-Bus involved, works with the server disabled): a transient,
    // non-actionable entry plus a banner. Normal urgency, so Do Not Disturb silences it.
    // Returns its key (for clear()).
    function postInternal(summary: string, body: string): string {
        counter++;
        const key = Date.now() + "-" + counter;
        const entry = {
            key: key,
            nid: -1,
            appName: "Grassfield",
            appIcon: "",
            image: "",
            summary: summary,
            body: body,
            bodyHtml: Sanitizer.sanitize(body),
            time: Date.now(),
            urgency: 1,
            transient: true,
            resident: false,
            actions: [],
            restored: false
        };
        addEntry(entry);
        if (!dnd)
            showBanner(entry, Tokens.notificationBannerTimeout);
        return key;
    }

    function toggleCenter(screen: string): void {
        if (centerOpen) {
            closeCenter();
            return;
        }
        centerScreen = screen !== "" ? screen : (Quickshell.screens.length > 0 ? Quickshell.screens[0].name : "");
        Popups.close();
        centerOpen = true;
    }

    function closeCenter(): void {
        centerOpen = false;
        if (Object.keys(expandedApps).length > 0) {
            expandedApps = ({});
            syncShown();
        }
    }

    function setDnd(on: bool): void {
        Settings.setNotificationsDnd(on);
    }

    // Banner timed out: hide it only.
    function expireBanner(key: string): void {
        const i = indexOfKey(bannerStore, key);
        if (i >= 0) {
            bannerStore.remove(i);
            bannerKeys.splice(i, 1);
        }
        delete heldKeys[key];
        dropTimer(key);
        syncBannerTimers();
    }

    // Hover or drag on a banner pauses its expiry.
    function holdBanner(key: string, held: bool): void {
        if (held)
            heldKeys[key] = true;
        else
            delete heldKeys[key];
        const t = bannerTimers[key];
        if (t)
            t.held = held;
    }

    // User dismissed the banner (x or drag): tell the sender, keep the history entry.
    function dismissBanner(key: string): void {
        expireBanner(key);
        const n = liveByKey[key];
        if (n)
            n.dismiss();
    }

    // Activates the default action (if any) and the sender's window; clears the entry.
    function activateDefault(key: string): void {
        const n = liveByKey[key];
        if (n) {
            const action = (n.actions || []).find(a => a.identifier === "default");
            if (action)
                action.invoke();
            focusSender(n);
        }
        finish(key);
    }

    function invokeAction(key: string, actionId: string): void {
        const n = liveByKey[key];
        if (!n)
            return;
        const action = (n.actions || []).find(a => a.identifier === actionId);
        if (action)
            action.invoke();
        if (n.resident)
            expireBanner(key);
        else
            finish(key);
    }

    // Removes one entry from banners and history and closes the live notification.
    function finish(key: string): void {
        expireBanner(key);
        finishLive(key);
        setHistory(History.removeKey(history, key));
    }

    function clear(key: string): void {
        finish(key);
    }

    // After the model dropped the card that was at slot `at` (or the group of `app`, whose first card was there): the key of
    // the card that takes the keyboard focus, read from the UPDATED displayed rows (CenterLogic.focusAfterClear).
    function focusKeyAfter(at: int, app: string): string {
        const rows = [];
        for (let i = 0; i < centerStore.count; i++) {
            const r = centerStore.get(i);
            rows.push({key: r.key, appName: r.appName});
        }
        return CenterLogic.focusAfterClear(rows, at, app);
    }

    // Keys of the entries of an app right now (the snapshot a group clear acts on).
    function keysOf(appName: string): var {
        return history.filter(e => e.appName === appName).map(e => e.key);
    }

    // Clears exactly these entries (a snapshot taken when the user clicked): an entry of the same app that arrived
    // since stays. Takes effect at once: history, banners, Center model, persistence.
    function clearKeys(keys: var): void {
        const doomed = {};
        keys.forEach(k => doomed[k] = true);
        history.forEach(e => {
            if (doomed[e.key]) {
                expireBanner(e.key);
                finishLive(e.key);
            }
        });
        setHistory(history.filter(e => !doomed[e.key]));
    }

    function clearApp(appName: string): void {
        clearKeys(keysOf(appName));
    }

    function clearAll(): void {
        history.forEach(e => finishLive(e.key));
        while (bannerStore.count > 0)
            expireBanner(bannerStore.get(0).key);
        setHistory([]);
    }

    // ---- models ----

    function indexOfKey(model: var, key: string): int {
        if (model === bannerStore)
            return bannerKeys.indexOf(key);
        for (let i = 0; i < model.count; i++) {
            if (model.get(i).key === key)
                return i;
        }
        return -1;
    }

    // Model row for an entry (no `body`: only the sanitized text goes to the UI).
    function rowOf(e: var): var {
        return {
            key: e.key,
            nid: e.nid,
            appName: e.appName,
            appIcon: e.appIcon,
            image: e.image ? e.image : "",
            summary: e.summary,
            bodyHtml: e.bodyHtml,
            time: e.time,
            urgency: e.urgency,
            actionsJson: JSON.stringify(e.actions || [])
        };
    }

    // The Center model holds only the rows that are DISPLAYED (first `notificationCenterGroupCollapsed`
    // of each app group, all of an expanded group), so collapsed rows never get a delegate. The full
    // order lives in two JS arrays (row i = centerKeys[i], centerApps[i]; grouped by app, newest group
    // first, newest row first inside a group); the shown rows are kept in sync by syncShown(), which
    // touches the model only where the displayed set changed (a few rows per Notify).
    property var centerKeys: []
    property var centerApps: []
    // Mirrors of centerStore: key and meta signature of each shown row.
    property var shownKeys: []
    property var shownSig: []
    // App names whose group is expanded ("Show All"); reset when the Center closes.
    property var expandedApps: ({})
    // Same for bannerStore (keys, newest first).
    property var bannerKeys: []

    function setExpanded(app: string, on: bool): void {
        const next = Object.assign({}, expandedApps);
        next[app] = on;
        expandedApps = next;
        syncShown();
    }

    // Reconciles centerStore with the displayed subset of centerKeys. Per-row group info travels as
    // roles of the rows that need it: headCount (> 0 on the first row of a group: draws the group
    // header), headFirst (that group is the top one), toggleCount (> 0 on the row that carries
    // Show All / Show Less). A role is only written when its value changed.
    function syncShown(): void {
        const collapsed = Tokens.notificationCenterGroupCollapsed;
        const sizes = {};
        for (const a of centerApps)
            sizes[a] = (sizes[a] || 0) + 1;
        const wantKeys = [];
        const wantMeta = [];
        const wantSig = [];
        const seen = {};
        for (let i = 0; i < centerKeys.length; i++) {
            const app = centerApps[i];
            const rank = seen[app] || 0;
            seen[app] = rank + 1;
            const expanded = expandedApps[app] === true;
            if (rank >= collapsed && !expanded)
                continue;
            const size = sizes[app];
            const meta = {
                headCount: rank === 0 ? size : 0,
                headFirst: rank === 0 && i === 0,
                toggleCount: size > collapsed && rank === (expanded ? size - 1 : collapsed - 1) ? size : 0
            };
            wantKeys.push(centerKeys[i]);
            wantMeta.push(meta);
            wantSig.push(meta.headCount + "|" + meta.headFirst + "|" + meta.toggleCount);
        }
        const want = {};
        wantKeys.forEach(k => want[k] = true);
        for (let i = shownKeys.length - 1; i >= 0; i--) {
            if (!want[shownKeys[i]]) {
                centerStore.remove(i);
                shownKeys.splice(i, 1);
                shownSig.splice(i, 1);
            }
        }
        for (let i = 0; i < wantKeys.length; i++) {
            if (shownKeys[i] !== wantKeys[i]) {
                const j = shownKeys.indexOf(wantKeys[i], i + 1);
                if (j > i) {
                    centerStore.move(j, i, 1);
                    shownKeys.splice(i, 0, shownKeys.splice(j, 1)[0]);
                    shownSig.splice(i, 0, shownSig.splice(j, 1)[0]);
                } else {
                    centerStore.insert(i, Object.assign(rowOf(entryFor(wantKeys[i])), wantMeta[i]));
                    shownKeys.splice(i, 0, wantKeys[i]);
                    shownSig.splice(i, 0, wantSig[i]);
                    continue;
                }
            }
            if (shownSig[i] !== wantSig[i]) {
                centerStore.set(i, wantMeta[i]);
                shownSig[i] = wantSig[i];
            }
        }
    }

    // New (newest) entry: on top, followed by the rest of its group. Call syncShown() afterwards.
    function addToCenter(e: var): void {
        const start = centerApps.indexOf(e.appName);
        const at = start >= 0 ? start : 0;
        centerKeys.splice(at, 0, e.key);
        centerApps.splice(at, 0, e.appName);
        if (at > 0) {
            let size = 0;
            while (at + 1 + size < centerApps.length && centerApps[at + 1 + size] === e.appName)
                size++;
            centerKeys.unshift(...centerKeys.splice(at, size + 1));
            centerApps.unshift(...centerApps.splice(at, size + 1));
        }
    }

    // Drops rows whose entry left the history (removal, pruning). Call syncShown() afterwards.
    // Returns the number of rows dropped (0 takes the fast path: no work when the sizes agree).
    // `pending` entries of history are not in the arrays yet (the caller inserts them next).
    function syncRemovals(pending: int): int {
        if (centerKeys.length + pending === history.length)
            return 0;
        let dropped = 0;
        const alive = {};
        history.forEach(e => alive[e.key] = true);
        for (let i = centerKeys.length - 1; i >= 0; i--) {
            if (!alive[centerKeys[i]]) {
                centerKeys.splice(i, 1);
                centerApps.splice(i, 1);
                dropped++;
            }
        }
        return dropped;
    }

    // Call syncShown() afterwards.
    function removeFromCenter(key: string): void {
        const i = centerKeys.indexOf(key);
        if (i < 0)
            return;
        centerKeys.splice(i, 1);
        centerApps.splice(i, 1);
    }

    function clearCenter(): void {
        centerStore.clear();
        centerKeys = [];
        centerApps = [];
        shownKeys = [];
        shownSig = [];
    }

    function rebuildCenter(): void {
        clearCenter();
        for (const g of History.group(history)) {
            g.items.forEach(e => {
                centerKeys.push(e.key);
                centerApps.push(e.appName);
            });
        }
        syncShown();
    }

    function addEntry(entry: var): void {
        const before = history;
        history = History.pushNewest(history, entry, Date.now());
        count = history.length;
        saveTimer.restart();
        // Only the tail can fall out: drop exactly those rows, without scanning the whole model.
        const dropped = before.length + 1 - history.length;
        const evicted = [];
        for (let i = 0; i < dropped; i++)
            evicted.push(before[before.length - 1 - i].key);
        evicted.forEach(k => removeFromCenter(k));
        syncRemovals(1);
        addToCenter(entry);
        syncShown();
        // Dismissing a live notification costs ~5 ms in the server; after the Notify reply went out.
        if (evicted.length > 0)
            Qt.callLater(() => evicted.forEach(k => finishLive(k)));
    }

    function updateEntry(key: string, entry: var): void {
        let found = false;
        history = history.map(e => {
            if (e.key !== key)
                return e;
            found = true;
            return Object.assign({}, entry, {time: e.time});
        });
        if (!found)
            return;
        saveTimer.restart();
        const row = rowOf(entryFor(key));
        const ci = shownKeys.indexOf(key);
        if (ci >= 0)
            centerStore.set(ci, row);
        const bi = indexOfKey(bannerStore, key);
        if (bi >= 0) {
            bannerStore.set(bi, row);
            dropTimer(key);
            syncBannerTimers();
        }
    }

    function setHistory(list: var): void {
        history = list;
        count = list.length;
        saveTimer.restart();
        if (list.length === 0)
            clearCenter();
        else if (syncRemovals(0) > 0)
            syncShown();
    }

    // ---- banners ----

    function showBanner(entry: var, timeoutMs: int): void {
        const old = indexOfKey(bannerStore, entry.key);
        if (old >= 0) {
            bannerStore.remove(old);
            bannerKeys.splice(old, 1);
        }
        dropTimer(entry.key);
        bannerStore.insert(0, Object.assign(rowOf(entry), {timeout: timeoutMs}));
        bannerKeys.unshift(entry.key);
        syncBannerTimers();
    }

    function dropTimer(key: string): void {
        const t = bannerTimers[key];
        if (t) {
            delete bannerTimers[key];
            t.running = false;
            t.destroy();
        }
    }

    // Only the banners that are shown (first N) run a timer; queued ones wait their turn.
    function syncBannerTimers(): void {
        const wanted = {};
        const n = Math.min(bannerStore.count, Tokens.notificationBannerMaxVisible);
        for (let i = 0; i < n; i++) {
            const row = bannerStore.get(i);
            wanted[row.key] = true;
            if (!bannerTimers[row.key] && row.timeout > 0)
                bannerTimers[row.key] = bannerTimer.createObject(root, {key: row.key, interval: row.timeout, held: heldKeys[row.key] === true});
        }
        for (const k in bannerTimers) {
            if (!wanted[k])
                dropTimer(k);
        }
    }

    // ---- internals ----

    function finishLive(key: string): void {
        const n = liveByKey[key];
        if (n) {
            delete liveByKey[key];
            n.dismiss();
        }
    }

    function focusSender(n: var): void {
        if (!n.desktopEntry)
            return;
        const list = Compositor.toplevelsFor(n.desktopEntry);
        if (list && list.length > 0) {
            FocusReturn.skip();
            Compositor.activate(list[0]);
        }
    }

    function actionsOf(n: var): var {
        return (n.actions || []).map(a => ({id: a.identifier, text: a.text}));
    }

    function makeEntry(n: var, key: string): var {
        return {
            key: key,
            nid: n.id,
            appName: n.appName,
            appIcon: n.appIcon,
            image: n.image,
            summary: n.summary,
            body: n.body,
            bodyHtml: Sanitizer.sanitize(n.body),
            time: Date.now(),
            urgency: n.urgency === NotificationUrgency.Critical ? 2 : (n.urgency === NotificationUrgency.Low ? 0 : 1),
            transient: n.transient,
            resident: n.resident,
            actions: actionsOf(n),
            restored: false
        };
    }

    // A notification arrived from the server.
    function accept(n: var): void {
        n.tracked = true;
        let key = "";
        for (const k in liveByKey) {
            if (liveByKey[k] === n)
                key = k;
        }
        const isNew = key === "";
        if (isNew) {
            counter++;
            key = Date.now() + "-" + counter;
            liveByKey[key] = n;
            tracker.createObject(root, {notif: n, key: key});
        }
        const entry = makeEntry(n, key);
        if (isNew)
            addEntry(entry);
        else
            updateEntry(key, entry);
        if (!dnd || entry.urgency === 2) {
            // Notification.expireTimeout is in milliseconds (see History.bannerTimeout).
            showBanner(entry, History.bannerTimeout(entry.urgency, n.expireTimeout, Tokens.notificationBannerTimeout));
        }
    }

    // Live notifications whose entry was pruned must not leak.
    function pruneLive(): void {
        const kept = {};
        history.forEach(e => kept[e.key] = true);
        for (const k in liveByKey) {
            if (!kept[k]) {
                const n = liveByKey[k];
                delete liveByKey[k];
                n.dismiss();
            }
        }
    }

    // The sender (or we) closed the notification.
    function closed(key: string, reason: int): void {
        delete liveByKey[key];
        expireBanner(key);
        if (reason === NotificationCloseReason.CloseRequested) {
            setHistory(History.removeKey(history, key));
        } else {
            // An entry that was pruned meanwhile has nothing left to update.
            const hi = history.findIndex(e => e.key === key);
            if (hi < 0)
                return;
            const next = history.slice();
            next[hi] = Object.assign({}, history[hi], {nid: -1});
            history = next;
            saveTimer.restart();
            const ci = shownKeys.indexOf(key);
            if (ci >= 0)
                centerStore.set(ci, {nid: -1});
        }
    }

    function updated(key: string, n: var): void {
        if (entryFor(key))
            updateEntry(key, makeEntry(n, key));
    }

    // ---- persistence ----

    function loadHistory(text: string): void {
        // Entries received before the file was read stay on top.
        const restored = History.parse(text, Date.now());
        restored.forEach(e => e.bodyHtml = Sanitizer.sanitize(e.body));
        history = History.prune(history.concat(restored), Date.now());
        count = history.length;
        rebuildCenter();
        historyReady = true;
    }

    function checkOwner(output: string): void {
        const match = /PID=(\d+)/.exec(output);
        if (match && parseInt(match[1], 10) === Quickshell.processId) {
            serverState = "active";
        } else {
            serverState = "external";
            console.warn("notifications: org.freedesktop.Notifications is owned by another process; banners and history are off (degraded)");
        }
    }

    Component.onCompleted: {
        if (!serverEnabled) {
            serverState = "disabled";
            console.info("notifications: dev session on the shared bus; server disabled (use GRASSFIELD_PRIVATE_BUS=1)");
        }
        prepare.running = true;
    }

    // The state directory and the history file are created with restrictive modes before the
    // first write: FileView cannot set modes, and its atomic write only keeps the mode of an
    // existing target.
    Process {
        id: prepare
        command: ["sh", "-c", "umask 077; mkdir -p -m 700 \"$1\"; chmod 700 \"$1\"; [ -e \"$2\" ] || install -m 600 /dev/null \"$2\"; chmod 600 \"$2\"", "sh", root.stateDir, root.historyPath]
        onRunningChanged: {
            if (!running)
                file.path = root.historyPath;
        }
    }

    FileView {
        id: file
        printErrors: false
        atomicWrites: true
        onLoaded: root.loadHistory(file.text())
        onLoadFailed: root.historyReady = true
    }

    Timer {
        id: saveTimer
        interval: 400
        onTriggered: {
            if (root.historyReady && root.serverState !== "external")
                file.setText(History.serialize(root.history, Date.now()));
        }
    }

    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: {
            root.nowMs = Date.now();
            const kept = History.prune(root.history, root.nowMs);
            if (kept.length !== root.history.length) {
                root.setHistory(kept);
                root.pruneLive();
            }
        }
    }

    Component {
        id: bannerTimer

        Timer {
            required property string key
            property bool held: false

            running: !held
            repeat: false
            onTriggered: root.expireBanner(key)
        }
    }

    // One tracker per live notification: forwards replacement updates and closing.
    Component {
        id: tracker

        QtObject {
            id: t

            required property var notif
            required property string key

            property Connections watch: Connections {
                target: t.notif

                function onClosed(reason: int): void {
                    root.closed(t.key, reason);
                    t.destroy();
                }

                function onSummaryChanged(): void {
                    root.updated(t.key, t.notif);
                }

                function onBodyChanged(): void {
                    root.updated(t.key, t.notif);
                }

                function onActionsChanged(): void {
                    root.updated(t.key, t.notif);
                }
            }
        }
    }

    Instantiator {
        active: root.serverEnabled
        model: 1

        delegate: NotificationServer {
            keepOnReload: false
            bodySupported: true
            bodyMarkupSupported: true
            bodyHyperlinksSupported: false
            bodyImagesSupported: false
            actionsSupported: true
            actionIconsSupported: false
            imageSupported: true
            persistenceSupported: true
            inlineReplySupported: false
            onNotification: n => root.accept(n)
            Component.onCompleted: ownerCheck.start()
        }
    }

    Timer {
        id: ownerCheck
        interval: 1500
        onTriggered: ownerProbe.running = true
    }

    Process {
        id: ownerProbe
        command: ["busctl", "--user", "status", "org.freedesktop.Notifications"]
        stdout: StdioCollector {
            onStreamFinished: root.checkOwner(text)
        }
    }

    IpcHandler {
        target: "notifications"

        function toggleCenter(): void {
            root.toggleCenter("");
        }

        function dnd(on: bool): void {
            root.setDnd(on);
        }

        // Test hook (no pointer in the nested session): runs an action of the newest live
        // notification as a click on its button would ("default" = click on the banner).
        function invoke(actionId: string): string {
            for (const e of root.history) {
                if (e.nid >= 0) {
                    if (actionId === "default")
                        root.activateDefault(e.key);
                    else
                        root.invokeAction(e.key, actionId);
                    return "invoked " + actionId + " on " + e.summary;
                }
            }
            return "no live notification";
        }

        // Test hook: one-line state.
        function status(): string {
            return "server=" + root.serverState + " history=" + root.count + " banners=" + root.bannerCount
                + " dnd=" + root.dnd + " center=" + root.centerOpen;
        }

        // Test hook: remove every entry (history, banners, Center); the UI has no global Clear All. Dev and test
        // sessions only (GRASSFIELD_DEV=1): in a real session nothing outside the shell may wipe the history.
        function clearAll(): void {
            if (!root.devSession) {
                console.warn("notifications: clearAll is a test hook (GRASSFIELD_DEV=1 only); refused");
                return;
            }
            root.clearAll();
        }

        // Test hook: dismiss every banner as a swipe would.
        function dismissAll(): void {
            while (root.bannerCount > 0)
                root.dismissBanner(root.bannerModel.get(0).key);
        }
    }
}
