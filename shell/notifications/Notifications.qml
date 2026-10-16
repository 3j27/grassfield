pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import qs.platform
import qs.services
import "History.js" as History
import "Sanitizer.js" as Sanitizer

// The session's org.freedesktop.Notifications server, banner queue, history (ADR-0004) and
// Notification Center state. Spec: docs/specs/notifications.md.
//
// - banners: [{key}] currently shown (newest first); expiry only hides the banner, the
//   notification stays in the history (and stays actionable while the sender keeps it alive).
// - history: entries as in History.js, newest first, persisted to notifications.json (0600).
Singleton {
    id: root

    // ---- state ----
    property var history: []
    property var banners: []
    readonly property var groups: History.group(history)
    readonly property int count: history.length
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

    // ---- API used by the UI ----

    function bodyFor(entry: var): string {
        return previewsHidden ? "" : Sanitizer.sanitize(entry.body);
    }

    // Image (hint) first, then the app icon (theme name or path); "" when none resolves.
    function iconSource(entry: var): string {
        if (entry.image)
            return entry.image;
        const icon = entry.appIcon;
        if (!icon)
            return "";
        if (icon.startsWith("/"))
            return "file://" + icon;
        if (icon.startsWith("file:"))
            return icon;
        return Quickshell.iconPath(icon, true);
    }

    function timeFor(entry: var): string {
        return History.relativeTime(entry.time, nowMs);
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
    }

    function setDnd(on: bool): void {
        Settings.setNotificationsDnd(on);
    }

    // Banner timed out: hide it only.
    function expireBanner(key: string): void {
        banners = banners.filter(b => b.key !== key);
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
        const n = liveByKey[key];
        if (n) {
            delete liveByKey[key];
            n.dismiss();
        }
        setHistory(History.removeKey(history, key));
    }

    function clear(key: string): void {
        finish(key);
    }

    function clearApp(appName: string): void {
        for (const e of history) {
            if ((e.appName !== "" ? e.appName : "Notification") === appName)
                expireBanner(e.key);
        }
        const doomed = history.filter(e => (e.appName !== "" ? e.appName : "Notification") === appName).map(e => e.key);
        doomed.forEach(k => finishLive(k));
        setHistory(History.removeApp(history, appName));
    }

    function clearAll(): void {
        history.forEach(e => finishLive(e.key));
        banners = [];
        setHistory([]);
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
        if (list && list.length > 0)
            Compositor.activate(list[0]);
    }

    function setHistory(list: var): void {
        history = list;
        saveTimer.restart();
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
        if (isNew) {
            setHistory(History.prune([entry].concat(history), Date.now()).slice());
            pruneLive();
        } else {
            setHistory(history.map(e => e.key === key ? Object.assign({}, entry, {time: e.time}) : e));
        }
        if (!dnd || entry.urgency === 2) {
            const rest = banners.filter(b => b.key !== key);
            banners = [{key: key}].concat(rest);
        }
    }

    // Live notifications whose entry was pruned must not leak.
    function pruneLive(): void {
        for (const k in liveByKey) {
            if (!entryFor(k)) {
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
        if (reason === NotificationCloseReason.CloseRequested)
            setHistory(History.removeKey(history, key));
        else
            setHistory(history.map(e => e.key === key ? Object.assign({}, e, {nid: -1}) : e));
    }

    function updated(key: string, n: var): void {
        const old = entryFor(key);
        if (old)
            setHistory(history.map(e => e.key === key ? Object.assign({}, makeEntry(n, key), {time: e.time}) : e));
    }

    // ---- persistence ----

    function loadHistory(text: string): void {
        // Entries received before the file was read stay on top.
        const restored = History.parse(text, Date.now());
        history = History.prune(history.concat(restored), Date.now());
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
        command: ["sh", "-c", "umask 077; mkdir -p -m 700 \"$1\"; [ -e \"$2\" ] || install -m 600 /dev/null \"$2\"; chmod 600 \"$2\"", "sh", root.stateDir, root.historyPath]
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
            return "server=" + root.serverState + " history=" + root.count + " banners=" + root.banners.length
                + " dnd=" + root.dnd + " center=" + root.centerOpen;
        }

        // Test hook: dismiss every banner as a swipe would.
        function dismissAll(): void {
            root.banners.slice().forEach(b => root.dismissBanner(b.key));
        }
    }
}
