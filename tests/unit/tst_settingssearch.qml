import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml" as SettingsQml

// Settings > Search as macOS 27 lays out its Spotlight pane (docs/audits/settings-parity-2026-10-26.md § Search): one switch
// per kind of result, each writing its search.show* key, and Delete Search History…, which only asks (Main confirms, then
// writes search.historyResetAt). The clipboard history's group (ADR-0034 step 3): Results from Clipboard, the time the history
// is available, Keep clipboard history after logging out (both inactive while the history is off), and Clear Clipboard
// History…, which only asks; clearClipboard writes the clear keys in one write. The store is a fake.
TestCase {
    id: testCase
    name: "SettingsSearch"
    width: 508
    height: 700
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
        id: pageComponent
        SettingsQml.SearchPage {
            width: 508
            height: 700
        }
    }

    function make() {
        const store = createTemporaryObject(storeComponent, testCase);
        const page = createTemporaryObject(pageComponent, testCase, {store: store});
        verify(page);
        return {store: store, page: page};
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

    function named(root, name) {
        return find(root, i => i.accessibleName === name);
    }

    function last(store) {
        return store.writes[store.writes.length - 1];
    }

    function test_resultSwitches_data() {
        return [
            {tag: "apps", name: "Applications", key: "search.showApps"},
            {tag: "calculator", name: "Calculator", key: "search.showCalculator"},
            {tag: "conversions", name: "Conversions", key: "search.showConversions"},
            {tag: "documents", name: "Documents", key: "search.showDocuments"},
            {tag: "recents", name: "Recent Documents", key: "search.showRecents"},
            {tag: "settings", name: "Settings", key: "search.showSettings"},
            {tag: "commands", name: "System Commands", key: "search.showCommands"}
        ];
    }

    function test_resultSwitches(data) {
        const t = make();
        const toggle = named(t.page.contentItem, "Show " + data.name + " in Search");
        verify(toggle, data.name);
        verify(toggle.checked, "on by default");
        toggle.toggled(false);
        const e = {};
        e[data.key] = false;
        compare(last(t.store), e);
        verify(!toggle.checked);
    }

    // The rows keep macOS's pitch: 42 from one separator to the next, the switches 14 under each.
    function test_rowPitch() {
        const t = make();
        const a = named(t.page.contentItem, "Show Applications in Search");
        const b = named(t.page.contentItem, "Show Calculator in Search");
        const ya = a.mapToItem(t.page.contentItem, 0, 0).y;
        const yb = b.mapToItem(t.page.contentItem, 0, 0).y;
        compare(yb - ya, Tokens.settingsResultRowHeight);
    }

    function test_deleteHistory() {
        const t = make();
        let asked = 0;
        t.page.historyDeleteRequested.connect(() => asked++);
        const button = find(t.page.contentItem, i => i.text === "Delete Search History…" && i.clicked !== undefined);
        verify(button);
        const writes = t.store.writes.length;
        button.clicked();
        compare(asked, 1);
        // Only asks: nothing is forgotten before Main's confirmation.
        compare(t.store.writes.length, writes);
    }
    function test_clipboardSwitch() {
        const t = make();
        const toggle = named(t.page.contentItem, "Results from Clipboard");
        verify(toggle);
        verify(!toggle.checked, "off by default (CB-3)");
        const retention = named(t.page.contentItem, "Clipboard history is available in Search for");
        const keep = named(t.page.contentItem, "Keep clipboard history after logging out");
        verify(retention && keep);
        verify(!retention.enabled && !keep.enabled, "inactive while the history is off");
        toggle.toggled(true);
        compare(last(t.store), {"search.clipboard.enabled": true});
        verify(toggle.checked && retention.enabled && keep.enabled);
    }

    function test_clipboardRetention() {
        const t = make();
        t.store.set("search.clipboard.enabled", true);
        const retention = named(t.page.contentItem, "Clipboard history is available in Search for");
        compare(retention.value, "8h", "8 hours by default");
        compare(retention.model.map(c => c.id).join(" "), "30m 8h 7d");
        retention.picked("7d");
        compare(last(t.store), {"search.clipboard.retention": "7d"});
        compare(retention.value, "7d");
    }

    function test_clipboardKeepOnDisk() {
        const t = make();
        t.store.set("search.clipboard.enabled", true);
        const keep = named(t.page.contentItem, "Keep clipboard history after logging out");
        verify(!keep.checked, "off by default");
        keep.toggled(true);
        compare(last(t.store), {"search.clipboard.keepOnDisk": true});
    }

    function test_clearClipboardHistory() {
        const t = make();
        let asked = 0;
        t.page.clipboardClearRequested.connect(() => asked++);
        const button = find(t.page.contentItem, i => i.text === "Clear Clipboard History…" && i.clicked !== undefined);
        verify(button);
        verify(button.enabled, "available while the history is off: pinned items stay");
        const writes = t.store.writes.length;
        button.clicked();
        compare(asked, 1);
        compare(t.store.writes.length, writes, "only asks");
        // Confirmed: the unpinned items, in one write; with "Also delete pinned items", the pinned ones in the same write.
        t.page.clearClipboard(false);
        compare(Object.keys(last(t.store)).join(), "search.clipboard.clearedAt");
        verify(last(t.store)["search.clipboard.clearedAt"] > 0);
        t.page.clearClipboard(true);
        compare(Object.keys(last(t.store)).sort().join(), "search.clipboard.clearedAt,search.clipboard.pinnedClearedAt");
        compare(last(t.store)["search.clipboard.clearedAt"], last(t.store)["search.clipboard.pinnedClearedAt"]);
    }
}
