import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml" as SettingsQml

// Settings > Notifications and Focus as macOS 27 lays them out (docs/audits/settings-parity-2026-10-26.md § Notifications,
// § Focus): the header card at the measured places, Notification Center's pop-ups, the apps as rows that open their sub-pane
// (an untrusted name never becomes a path to an icon), the app's sub-pane writing its keys, and Do Not Disturb in Focus.
TestCase {
    id: testCase
    name: "SettingsNotifications"
    width: 508
    height: 1400
    visible: true
    when: windowShown

    Component {
        id: storeComponent
        QtObject {
            property var values: Object.assign({}, SettingsContract.ALL_DEFAULTS)
            property var writes: []
            function value(key: string): var {
                return values[key];
            }
            function setMany(entries: var): bool {
                writes.push(entries);
                values = Object.assign({}, values, entries);
                return true;
            }
            function set(key: string, v: var): bool {
                const e = {};
                e[key] = v;
                return setMany(e);
            }
        }
    }

    Component {
        id: backendComponent
        QtObject {
            property string configFile: "/home/u/.config/grassfield/grassfield.json"
            property var files: ({})
            signal fileChanged(string path)
            function readText(p: string): var {
                return files[p] !== undefined ? {exists: true, ok: true, text: files[p]} : {exists: false, ok: true, text: ""};
            }
            function watch(p: string): bool {
                return true;
            }
        }
    }

    Component {
        id: notificationsComponent
        SettingsQml.NotificationsPage {
            width: 508
            height: 1400
        }
    }

    Component {
        id: appComponent
        SettingsQml.NotificationAppPage {
            width: 508
            height: 800
        }
    }

    Component {
        id: focusComponent
        SettingsQml.FocusPage {
            width: 508
            height: 800
        }
    }

    Component {
        id: dndComponent
        SettingsQml.DoNotDisturbPage {
            width: 508
            height: 800
        }
    }

    function make(apps) {
        const files = {};
        files["/home/u/.config/grassfield/notification-apps.json"] = JSON.stringify({apps: apps || ["Mail", "Terminal"]});
        const store = createTemporaryObject(storeComponent, testCase);
        const backend = createTemporaryObject(backendComponent, testCase, {files: files});
        const page = createTemporaryObject(notificationsComponent, testCase, {store: store, backend: backend});
        verify(page);
        return {store: store, backend: backend, page: page};
    }

    function find(item, pred) {
        if (!item)
            return null;
        if (pred(item))
            return item;
        const kids = item.children || [];
        for (let i = 0; i < kids.length; i++) {
            const hit = find(kids[i], pred);
            if (hit)
                return hit;
        }
        if (item.contentItem && item.contentItem !== item) {
            const hit = find(item.contentItem, pred);
            if (hit)
                return hit;
        }
        return null;
    }

    function all(item, pred, out) {
        out = out || [];
        if (!item)
            return out;
        if (pred(item))
            out.push(item);
        for (const k of (item.children || []))
            all(k, pred, out);
        return out;
    }

    function named(root, name) {
        return find(root, i => i.accessibleName === name);
    }

    function last(store) {
        return store.writes[store.writes.length - 1];
    }

    function test_headerCard() {
        const t = make();
        waitForRendering(t.page);
        const card = find(t.page.contentItem, i => i.title === "Notifications" && i.icon === "bell");
        verify(card);
        compare(card.mapToItem(t.page.contentItem, 0, 0).y, Tokens.settingsContentTop);
        const title = find(card, i => i.text === "Notifications" && i.font !== undefined);
        compare(title.x, Tokens.settingsBannerTextX);
        compare(title.y + title.baselineOffset, Tokens.settingsBannerTitleBaseline);
    }

    function test_notificationCenter() {
        const t = make();
        const previews = named(t.page.contentItem, "Show previews");
        verify(previews.inline);
        previews.picked("never");
        compare(last(t.store), {"notifications.previews": "never"});
        const history = named(t.page.contentItem, "Keep history");
        verify(history.inline);
        history.picked("day");
        compare(last(t.store), {"notifications.history": "day"});
        // Do Not Disturb is in Focus now.
        verify(!named(t.page.contentItem, "Do Not Disturb"));
    }

    function test_appRows() {
        const t = make(["Mail", "/etc/passwd", "Chat App"]);
        waitForRendering(t.page);
        const rows = all(t.page.contentItem, i => i.useAppIcon === true && i.text !== undefined);
        compare(rows.map(r => r.text), ["/etc/passwd", "Chat App", "Mail"].sort());
        for (const r of rows) {
            compare(r.height, Tokens.settingsLargeRowHeight + (r === rows[0] ? 0 : 1));
            compare(r.subtitle, "Banners");
        }
        // A name that is not an icon name is never handed to the icon provider (it could be a path).
        compare(t.page.iconFor("/etc/passwd"), "");
        compare(t.page.iconFor("Chat App"), "chat-app");
        compare(t.page.iconFor("Mail"), "mail");
        // Its own settings show under its name.
        t.store.set("notifications.appStyles", NotificationPrefs.withStyle(t.page.styles, "Mail", "alerts"));
        t.store.set("notifications.appPreviews", NotificationPrefs.withValue(t.page.overrides, "Mail", "never"));
        compare(rows.find(r => r.text === "Mail").subtitle, "Alerts, previews: Never");
        let asked = "";
        t.page.appRequested.connect(name => asked = name);
        const mail = rows.find(r => r.text === "Mail");
        mail.forceActiveFocus();
        keyClick(Qt.Key_Space);
        compare(asked, "Mail");
    }

    function test_noApps() {
        const t = make([]);
        verify(find(t.page.contentItem, i => i.text === "Apps appear here after they send a notification."));
    }

    function test_appSubPane() {
        const store = createTemporaryObject(storeComponent, testCase);
        const page = createTemporaryObject(appComponent, testCase, {store: store, app: "Mail"});
        compare(page.title, "Mail");
        const style = named(page.contentItem, "Alert style for Mail");
        compare(style.value, "banners");
        style.picked("none");
        compare(NotificationPrefs.styleFor(store.value("notifications.appStyles"), "Mail"), "none");
        const previews = named(page.contentItem, "Show previews for Mail");
        compare(previews.value, "default");
        previews.picked("unlocked");
        compare(NotificationPrefs.valueFor(store.value("notifications.appPreviews"), "Mail"), "unlocked");
    }

    function test_focusAndDoNotDisturb() {
        const store = createTemporaryObject(storeComponent, testCase);
        const focus = createTemporaryObject(focusComponent, testCase, {store: store});
        const row = find(focus.contentItem, i => i.text === "Do Not Disturb" && i.chevron === true);
        verify(row);
        compare(row.subtitle, "");
        let opened = "";
        focus.open.connect(id => opened = id);
        mouseClick(row);
        compare(opened, "dnd");
        const dnd = createTemporaryObject(dndComponent, testCase, {store: store});
        const toggle = named(dnd.contentItem, "Do Not Disturb");
        verify(toggle);
        toggle.toggled(true);
        compare(last(store), {"notifications.dnd": true});
        compare(row.subtitle, "On");
    }
}
