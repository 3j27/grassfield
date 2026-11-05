pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml" as SettingsQml

// Settings > General > Language & Region: the Select Text in Images row (macOS: Live Text; ADR-0045 OC-2,
// docs/specs/settings.md), on by default, writing preview.textInImages. The store, the backend and the system are fakes (a
// dev session: Omarchy's language commands are never asked).
TestCase {
    id: testCase
    name: "SettingsLanguage"
    width: 508
    height: 900
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
            function set(key: string, v: var): bool {
                const e = {};
                e[key] = v;
                writes.push(e);
                values = Object.assign({}, values, e);
                return true;
            }
        }
    }

    QtObject {
        id: fakeBackend
        property bool omarchyLanguage: false
        property var pendingActions: ({})
        signal finished(string tag, bool ok, string output)
        function regionLocales(): var {
            return [];
        }
    }

    QtObject {
        id: fakeSystem
        property bool dev: true
        property bool suppressedNote: false
        property var errors: ({})
        function query(argv: var, tag: string): void {
        }
        function act(name: string, argv: var, tag: string): bool {
            return false;
        }
    }

    Component {
        id: pageComponent
        SettingsQml.LanguagePage {
            width: 508
            height: 900
            backend: fakeBackend
            system: fakeSystem
        }
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

    function test_selectTextInImages() {
        const store = createTemporaryObject(storeComponent, testCase);
        const page = createTemporaryObject(pageComponent, testCase, {store: store});
        verify(page);
        const row = find(page.contentItem, i => i.title === "Select Text in Images");
        verify(row, "the row");
        compare(row.subtitle, "Preview and Glance recognise the text and QR codes in images, so you can copy the text or open the link.", "what the row does, not its title again");
        const toggle = find(page.contentItem, i => i.accessibleName === "Select Text in Images" && i.checked !== undefined);
        verify(toggle, "its switch");
        verify(toggle.checked, "on by default, as on macOS");
        toggle.toggled(false);
        compare(store.writes[store.writes.length - 1], {"preview.textInImages": false});
        verify(!toggle.checked);
        toggle.toggled(true);
        compare(store.writes[store.writes.length - 1], {"preview.textInImages": true});
    }
}
