pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import Grassfield.Ui
import qs.platform
import qs.services
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
    // The global previews default is Settings.notificationsPreviews; each app may override it
    // (Settings.notificationsAppPreviews, NotificationPrefs.js).
    // The session lock (SessionState mirrors shell/security/lock; false where nothing feeds it).
    readonly property bool sessionLocked: SessionState.locked
    // The session locks: the Notification Center closes (GF-116).
    onSessionLockedChanged: {
        if (sessionLocked && centerOpen)
            closeCenter();
    }
    // Wall clock for relative times, refreshed every 30 s.
    property real nowMs: Date.now()

    // "disabled" (dev session on the shared bus), "starting", "active", "external" (another
    // server owns the name: degraded, banners never appear).
    property string serverState: "starting"
    property bool historyReady: false
    property int counter: 0

    property bool centerOpen: false
    // The output whose column surface has the keyboard, "" for none (set by the content of each output's column).
    property string centerKeyboardScreen: ""
    // Key focus returns to the window active when the center opened (FocusReturn).
    onCenterOpenChanged: {
        if (centerOpen)
            FocusReturn.opened("notification-center");
        else
            FocusReturn.closed("notification-center", true);
    }
    property string centerScreen: ""

    // Dev sessions share the owner's session bus; never register there (GRASSFIELD_PRIVATE_BUS=1
    // runs the nested shell on its own bus, see docs/specs/notifications.md). The shell's one dev gate (SEC-03,
    // follow-up N6): a GRASSFIELD_DEV=1 leaked into a real session (GRASSFIELD_SESSION=1) must not switch the
    // notification server off there.
    readonly property bool devSession: VisualFixtures.dev
    readonly property bool privateBus: Quickshell.env("GRASSFIELD_PRIVATE_BUS") === "1"
    readonly property bool serverEnabled: !devSession || privateBus
    // Test-only IPC hooks (invoke, clearAll, dismissAll): same gate as the visual fixtures (GRASSFIELD_DEV=1 and
    // GRASSFIELD_VISUAL_FIXTURES=1, never with GRASSFIELD_SESSION=1), so nothing outside a test session can drive them.
    readonly property bool testHooks: VisualFixtures.active

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

    // The apps that have sent notifications, for the Settings page (per-app previews): $configDir/notification-apps.json,
    // {"apps": [names]}, rewritten shortly after the set of names changes. Names only, never text.
    readonly property string appsFile: Settings.configDir + "/notification-apps.json"
    readonly property var seenApps: {
        const names = [];
        const seen = {};
        for (const e of history) {
            const k = NotificationPrefs.keyOf(e.appName);
            if (k !== "" && !seen[k]) {
                seen[k] = true;
                names.push(e.appName);
            }
        }
        return names.sort();
    }
    onSeenAppsChanged: {
        if (historyReady)
            appsTimer.restart();
    }

    Timer {
        id: appsTimer
        interval: Tokens.notificationAppsWriteMs
        onTriggered: {
            const text = JSON.stringify({apps: root.seenApps}) + "\n";
            if (text !== appsWriter.lastText) {
                appsWriter.lastText = text;
                appsWriter.setText(text);
            }
        }
    }

    FileView {
        id: appsWriter
        property string lastText: ""
        path: root.appsFile
        printErrors: false
        atomicWrites: true
    }

    ListModel {
        id: centerStore
        dynamicRoles: true
    }

    ListModel {
        id: bannerStore
        dynamicRoles: true
    }

    // ---- API used by the UI ----

    // Whether the title and text of this app's notifications are shown: its own setting, else the global one;
    // "unlocked" hides them while the session is locked. `appName` is the sender's name.
    function previewShown(appName: string): bool {
        const policy = NotificationPrefs.effective(Settings.notificationsAppPreviews, appName, Settings.notificationsPreviews);
        return NotificationPrefs.bodyShown(policy, sessionLocked);
    }

    // macOS with previews off: the app name as the title and a generic "Notification" line, never the sender's title or
    // body (a mail subject or a contact name is as private as the text). The history file keeps the real text (0600).
    function summaryFor(summary: string, appName: string): string {
        return NotificationPrefs.display(previewShown(appName), summary, "", appName, qsTr("Notification")).title;
    }

    // Sanitized body (computed once per entry); the generic line when previews are hidden for this app.
    function bodyFor(bodyHtml: string, appName: string): string {
        return NotificationPrefs.display(previewShown(appName), "", bodyHtml, appName, qsTr("Notification")).body;
    }

    // The sender's picture and action buttons are previews too: hidden with the title and the text.
    function imageFor(image: string, appName: string): string {
        return NotificationPrefs.imageShown(previewShown(appName), image);
    }

    function appIconFor(appIcon: string, appName: string): string {
        return NotificationPrefs.appIconShown(previewShown(appName), appIcon);
    }

    function actionsFor(actionsJson: string, appName: string): string {
        return NotificationPrefs.actionsShown(previewShown(appName), actionsJson);
    }

    // Image (hint) first, then the app icon (theme name or path); "" when none resolves, so the
    // UI falls back to the bell tile without asking Qt for a missing icon. Only local files, the image data the app sent
    // and theme names are ever loaded (History.imageRef, GF-114): never a URL.
    function iconSource(image: string, appIcon: string): string {
        const ref = History.imageRef(image);
        if (ref.kind === "attached")
            return ref.source;
        // A local file: never its own path, only the shell's private copy of it, once made (copySourceOf).
        if (ref.kind === "file") {
            const copy = copySourceOf(History.localPathOf(ref.source));
            if (copy !== "")
                return copy;
        }
        // Quickshell reports a themed app_icon name as image://icon/<name>.
        if (ref.kind === "themed" && Quickshell.hasThemeIcon(ref.name))
            return ref.source;
        // No usable image (none, refused, not copied yet, or a name the theme lacks): the app icon.
        const icon = appIcon;
        if (!icon)
            return "";
        if (icon.startsWith("/") || icon.startsWith("file:"))
            return copySourceOf(History.localPathOf(icon));
        // Only a plain theme name reaches the icon theme (History.safeIconName): Qt also searches its fallback directories,
        // where a name with "/" or ".." named any file (review of 6e24d36). Anything else: the generic notification icon.
        const name = History.safeIconName(icon);
        if (name === "")
            return "";
        // iconPath(name, true) still yields an image://icon URL for a missing icon (Qt then warns
        // and paints a checkerboard), so ask the theme first.
        return Quickshell.hasThemeIcon(name) ? Quickshell.iconPath(name) : "";
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

    // The desktop's Edit Widgets… (macOS model): the Center opens straight on its widget gallery. The Center's column
    // takes the request (galleryWanted) when it is created, or at once when it is already open.
    property bool galleryWanted: false

    function openWidgetGallery(screen: string): void {
        if (SessionState.refuses("widget gallery"))
            return;
        galleryWanted = true;
        if (!centerOpen)
            toggleCenter(screen);
    }

    function toggleCenter(screen: string): void {
        if (centerOpen) {
            closeCenter();
            return;
        }
        // Nothing opens over the lock screen (GF-116): SUPER+N, the clock, a screen corner and IPC alike.
        if (SessionState.refuses("notification center"))
            return;
        centerScreen = screen !== "" ? screen : Compositor.activeScreenName;
        Popups.close();
        centerOpen = true;
    }

    function closeCenter(): void {
        centerOpen = false;
        freshKeys = ({});
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
        // A group that emptied forgets its "Show All": the next notification of that app arrives collapsed.
        const stale = Object.keys(expandedApps).filter(a => !sizes[a]);
        if (stale.length > 0) {
            const kept = Object.assign({}, expandedApps);
            stale.forEach(a => delete kept[a]);
            expandedApps = kept;
        }
        const wantKeys = [];
        const wantMeta = [];
        const wantSig = [];
        const wantApps = [];
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
            wantApps.push(app);
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
        expandedApps = ({});
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
        if (centerOpen) {
            freshKeys[entry.key] = true;
            freshTimer.restart();
        }
        syncShown();
        // Dismissing a live notification costs ~5 ms in the server; after the Notify reply went out.
        if (evicted.length > 0)
            Qt.callLater(() => evicted.forEach(k => finishLive(k)));
    }

    // Keys of the entries that arrived while the Center is open (for the card's entrance animation, taken once by its
    // delegate). They expire a second after the last arrival and when the Center closes: a card created later (scrolled in,
    // revealed by "Show All") never animates in.
    property var freshKeys: ({})

    function takeFresh(key: string): bool {
        const fresh = freshKeys[key] === true;
        delete freshKeys[key];
        return fresh;
    }

    Timer {
        id: freshTimer
        interval: 1000
        onTriggered: root.freshKeys = ({})
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

    // Local image files (an image hint or an app icon path) are never loaded from where the app named them (reviews of
    // 8b2a710 and beebaff): a FIFO or a device blocked the one image loader for good; a check of the named path could be
    // fooled by "?", "#" or "%XX" (Qt reads a URL, not a path) or by a file swapped after the check. Instead a helper
    // process opens the named plain path (History.localPathOf), checks that the OPENED descriptor is a regular file of at
    // most History.MAX_IMAGE_FILE_BYTES (`test -f` and `stat -L` on /proc/self/fd/3), and copies it into the shell's
    // private directory ($XDG_RUNTIME_DIR/grassfield-notification-images, 0700, emptied at start). The Image loads that
    // copy, by a URL built from its number with every segment encoded (History.copySource): a file nobody else writes.
    // Opening a FIFO blocks the helper, never the shell: each file has `timeout 3`. Each intake makes a fresh copy (an app
    // may reuse a path for new content); at most copyWindow copies and copyBudgetBytes bytes are kept, the oldest copies
    // not on a banner are evicted first, and an image that does not fit falls back to the app icon.
    // Without XDG_RUNTIME_DIR no local file is shown. Path -> {state: "pending"|"ok"|"no"|"gone", n}; reassigned on every
    // change so bindings that called iconSource() re-evaluate.
    // One directory per Wayland display: a nested dev shell never empties the real session's directory.
    readonly property string copyDir: {
        const runtime = Quickshell.env("XDG_RUNTIME_DIR");
        const display = String(Quickshell.env("WAYLAND_DISPLAY") || "none").replace(/[^A-Za-z0-9._-]/g, "_");
        return runtime ? runtime + "/grassfield-notification-images-" + display : "";
    }
    property var localCopies: ({})
    property var copyQueue: []
    property var copyBatch: []
    property int copyCounter: 0
    property bool copyDirReady: false
    readonly property int copyWindow: 48
    // At most copyWindow copies and copyBudgetBytes bytes in the directory, across all senders (review of 6e24d36: 60
    // notifications naming one 8 MiB file filled 384 MiB of the session's tmpfs). A test may lower the budget.
    property real copyBudgetBytes: 64 * 1024 * 1024
    // POSIX sh; the directory, the size cap, the copy window, the byte budget, the numbers of the copies to keep (the
    // banners on screen; comma list), then "<n> <path>" pairs as arguments (never interpolated). One line per pair: "ok"
    // when "<dir>/<n>.img" now holds the copy, else "no", followed by the numbers of the copies evicted to make room. The
    // one-file step runs under `timeout 3` (a FIFO named or swapped in blocks only that step), opens the path once and
    // decides on the opened descriptor. It then deletes the oldest copies (lowest number) not in the keep list while the
    // directory would hold more than the window or the budget with this file; when even that would not be enough (a file
    // larger than the budget, or the kept copies fill it) it refuses the file before evicting anything. It copies at most
    // the size it checked.
    readonly property string copyScript: "dir=$1; cap=$2; win=$3; budget=$4; keep=\",$5,\"; shift 5; [ -d \"$dir\" ] && [ ! -L \"$dir\" ] || exit 1; "
        + "one='src=$1; dst=$2; cap=$3; dir=$4; win=$5; budget=$6; keep=$7; [ -f \"$src\" ] || exit 1; exec 3<\"$src\" || exit 1; "
        + "[ -f /proc/self/fd/3 ] || exit 1; s=$(stat -L -c %s /proc/self/fd/3) || exit 1; "
        + "[ \"$s\" -le \"$cap\" ] && [ \"$s\" -le \"$budget\" ] || exit 1; "
        + "while :; do count=0; total=0; kc=0; kt=0; oldest=; for f in \"$dir\"/*.img; do [ -f \"$f\" ] || continue; t=$(stat -c %s \"$f\") || exit 1; "
        + "count=$((count + 1)); total=$((total + t)); b=${f##*/}; b=${b%.img}; case $keep in *\",$b,\"*) kc=$((kc + 1)); kt=$((kt + t)); continue ;; esac; "
        + "if [ -z \"$oldest\" ] || [ \"$b\" -lt \"$oldest\" ]; then oldest=$b; fi; done; "
        + "[ \"$kc\" -lt \"$win\" ] && [ $((kt + s)) -le \"$budget\" ] || exit 1; [ \"$count\" -lt \"$win\" ] && [ $((total + s)) -le \"$budget\" ] && break; "
        + "[ -n \"$oldest\" ] || exit 1; rm -f \"$dir/$oldest.img\" || exit 1; printf \" %s\" \"$oldest\"; done; "
        + "umask 077; head -c \"$s\" <&3 >\"$dst.tmp\" && mv -f \"$dst.tmp\" \"$dst\" && printf \" ok\"'; "
        + "while [ $# -ge 2 ]; do n=$1; p=$2; shift 2; rm -f \"$dir/$n.img.tmp\"; "
        + "out=$(timeout 3 sh -c \"$one\" one \"$p\" \"$dir/$n.img\" \"$cap\" \"$dir\" \"$win\" \"$budget\" \"$keep\" 2>/dev/null); "
        + "case $out in *' ok') echo \"ok${out% ok}\" ;; *) rm -f \"$dir/$n.img.tmp\"; echo \"no$out\" ;; esac; done"

    // The URL of the private copy of `path`, or "" (not copied yet: a copy is requested; refused; or evicted).
    function copySourceOf(path: string): string {
        if (path === "" || copyDir === "")
            return "";
        const entry = localCopies[path];
        if (entry === undefined) {
            Qt.callLater(root.requestCopy, path, false);
            return "";
        }
        return entry.state === "ok" ? History.copySource(copyDir, entry.n) : "";
    }

    // Asks for a copy of `path`; `fresh`: also when the path was already copied, refused or evicted (a new notification
    // naming it). Without `fresh` (shown, e.g. a history row after a restart) only a path never seen in this run is copied:
    // an evicted copy is not re-made on use, so copies never evict each other in a loop; the app icon shows instead. The
    // current copy stays shown until the new one is made.
    function requestCopy(path: string, fresh: bool): void {
        if (path === "" || copyDir === "" || copyQueue.some(q => q.path === path) || copyBatch.some(q => q.path === path))
            return;
        const entry = localCopies[path];
        if (!fresh && entry !== undefined)
            return;
        copyCounter++;
        copyQueue = copyQueue.concat([{path: path, n: copyCounter}]);
        if (entry === undefined || entry.state !== "ok") {
            const next = Object.assign({}, localCopies);
            next[path] = {state: "pending", n: -1};
            localCopies = next;
        }
        runCopies();
    }

    // The numbers of the copies the banners on screen show: never evicted.
    function bannerCopyNumbers(): var {
        const kept = [];
        for (let i = 0; i < bannerStore.count; i++) {
            const row = bannerStore.get(i);
            const ref = History.imageRef(row.image);
            for (const path of [ref.kind === "file" ? History.localPathOf(ref.source) : "", History.localPathOf(row.appIcon || "")]) {
                const entry = path === "" ? undefined : localCopies[path];
                if (entry !== undefined && entry.state === "ok")
                    kept.push(entry.n);
            }
        }
        return kept;
    }

    function runCopies(): void {
        if (!copyDirReady || copier.running || copyQueue.length === 0)
            return;
        copyBatch = copyQueue.slice(0, 16);
        copyQueue = copyQueue.slice(16);
        const args = [];
        for (const q of copyBatch)
            args.push(String(q.n), q.path);
        copier.command = ["sh", "-c", copyScript, "gf-image-copy", copyDir, String(History.MAX_IMAGE_FILE_BYTES), String(copyWindow),
            String(Math.max(0, Math.floor(copyBudgetBytes))), bannerCopyNumbers().join(",")].concat(args);
        copier.running = true;
    }

    // Line i of the helper's output answers copyBatch[i]: "ok" or "no", then the numbers of the copies it evicted (also
    // when the copy then failed). An evicted copy's path keeps a "gone" entry (not shown, not re-made on use; a new
    // notification naming it copies it again).
    function copiesDone(output: string): void {
        const lines = String(output || "").split("\n");
        const next = Object.keys(localCopies).length > 4 * copyWindow ? {} : Object.assign({}, localCopies);
        for (let i = 0; i < copyBatch.length; i++) {
            const q = copyBatch[i];
            const words = String(lines[i] || "").split(" ");
            if (words[0] === "ok") {
                next[q.path] = {state: "ok", n: q.n};
            } else {
                next[q.path] = {state: "no", n: -1};
                console.info("grassfield-notifications: a notification image is not a regular file of at most " + History.MAX_IMAGE_FILE_BYTES + " bytes, or does not fit the " + copyBudgetBytes + "-byte budget of copies; not shown");
            }
            for (const word of words.slice(1)) {
                const evicted = Number(word);
                for (const path in next) {
                    if (next[path].state === "ok" && next[path].n === evicted)
                        next[path] = {state: "gone", n: -1};
                }
            }
        }
        copyBatch = [];
        localCopies = next;
        Qt.callLater(runCopies);
    }

    Process {
        id: copier
        stdout: StdioCollector {
            onStreamFinished: root.copiesDone(text)
        }
    }

    // Empties (and creates, 0700) the private copy directory once at start; copies wait for it.
    Process {
        id: copyPrepare
        running: root.copyDir !== ""
        command: ["sh", "-c", "case $1 in /*/grassfield-notification-images-*) ;; *) exit 1 ;; esac; rm -rf -- \"$1\" && mkdir -m 700 -- \"$1\"", "gf-image-copy-prepare", root.copyDir]
        // Quickshell's qmltypes name QProcess::ExitStatus without exporting it (metadata quirk).
        // qmllint disable signal-handler-parameters
        onExited: code => {
            // qmllint enable signal-handler-parameters
            root.copyDirReady = code === 0;
            if (code !== 0)
                console.warn("grassfield-notifications: the private image directory could not be prepared; local notification images are not shown");
            root.runCopies();
        }
    }

    // The notification's image hint as kept: "" when it is not a local file, image data the app sent or a theme name
    // (History.imageRef, GF-114: a URL is never fetched). Logged with its scheme only, never the reference.
    function keptImage(image: string): string {
        const ref = History.imageRef(image);
        if (ref.kind === "file")
            requestCopy(History.localPathOf(ref.source), true); // shown as a private copy once made (copySourceOf)
        if (ref.kind !== "refused")
            return image;
        console.info("grassfield-notifications: a notification image was refused (" + (History.imageScheme(image) || "no scheme") + "): only local files, attached image data and theme icons are shown");
        return "";
    }

    // An app icon path is shown like an image file, as a private copy (copySourceOf); a name is kept only when it is a
    // plain theme name (History.keptAppIcon, review of 6e24d36); anything else is dropped at intake (the generic icon).
    function checkedAppIcon(icon: string): string {
        const kept = History.keptAppIcon(icon);
        if (kept !== icon)
            console.info("grassfield-notifications: a notification app icon was refused: only plain theme names and local image files are shown");
        if (kept.startsWith("/") || kept.toLowerCase().startsWith("file:"))
            requestCopy(History.localPathOf(kept), true);
        return kept;
    }

    function makeEntry(n: var, key: string): var {
        return {
            key: key,
            nid: n.id,
            appName: n.appName,
            appIcon: checkedAppIcon(n.appIcon),
            image: keptImage(n.image),
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

    // ---- test hooks (IPC, gated by testHooks) ----

    function hookRefused(name: string): string {
        console.warn("notifications: " + name + " is a test hook (GRASSFIELD_DEV=1 and GRASSFIELD_VISUAL_FIXTURES=1 only); refused");
        return "refused: " + name + " is a test hook";
    }

    function hookInvoke(actionId: string): string {
        if (!testHooks)
            return hookRefused("invoke");
        for (const e of history) {
            if (e.nid >= 0) {
                if (actionId === "default")
                    activateDefault(e.key);
                else
                    invokeAction(e.key, actionId);
                return "invoked " + actionId + " on " + e.summary;
            }
        }
        return "no live notification";
    }

    function hookClearAll(): string {
        if (!testHooks)
            return hookRefused("clearAll");
        clearAll();
        return "ok";
    }

    function hookDismissAll(): string {
        if (!testHooks)
            return hookRefused("dismissAll");
        while (bannerCount > 0)
            dismissBanner(bannerModel.get(0).key);
        return "ok";
    }

    IpcHandler {
        target: "notifications"

        function toggleCenter(): void {
            root.toggleCenter("");
        }

        // Test hook: refused outside a dev session (VisualFixtures.dev, SEC-04: another process must not silence
        // notifications, security notices included, behind the user's back). The user's switch is Quick Settings.
        function dnd(on: bool): void {
            if (VisualFixtures.dev)
                root.setDnd(on);
        }

        // Test hook (no pointer in the nested session): runs an action of the newest live
        // notification as a click on its button would ("default" = click on the banner).
        function invoke(actionId: string): string {
            return root.hookInvoke(actionId);
        }

        // Test hook: one-line state (dev session only).
        function status(): string {
            if (!VisualFixtures.dev)
                return "refused";
            return "server=" + root.serverState + " history=" + root.count + " banners=" + root.bannerCount
                + " dnd=" + root.dnd + " center=" + root.centerOpen + " keyboard=" + (root.centerOpen && root.centerKeyboardScreen === root.centerScreen)
                + " keyboardOn=" + (root.centerKeyboardScreen === "" ? "none" : root.centerKeyboardScreen);
        }

        // Test hook: remove every entry (history, banners, Center); the UI has no global Clear All.
        function clearAll(): string {
            return root.hookClearAll();
        }

        // Test hook: dismiss every banner as a swipe would.
        function dismissAll(): string {
            return root.hookDismissAll();
        }
    }
}
