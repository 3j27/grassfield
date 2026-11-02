import QtQuick
import QtTest
import Grassfield.Ui
import "store"

// The Store's finish (ADR-0039 step 24; audit §3.20): the shared search field (28, a clear button), the app button's hover and
// pressed states and the shared disabled opacity, the shared progress indicators and menu host (D4), an empty category that
// says so, the selection of a window that is not key, the hairline token and rings on keyboard focus only.
TestCase {
    id: testCase
    name: "StoreFinish"
    width: 800
    height: 600
    visible: true
    when: windowShown

    Component {
        id: fakeBackend
        FakeStoreBackend {}
    }

    Component {
        id: otherWindow
        Window {
            width: 60
            height: 60
            visible: true
        }
    }

    function make() {
        const backend = fakeBackend.createObject(testCase);
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/store/qml/Main.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const win = createTemporaryObject(comp, testCase, {backend: backend, globalMenu: false});
        verify(win);
        win.requestActivate();
        tryVerify(() => win.active, 2000, "the window is active");
        wait(50);
        tryVerify(() => win.page !== null);
        return {backend: backend, win: win};
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

    function near(a, b) {
        const ca = Qt.color(a), cb = Qt.color(b);
        return Math.abs(ca.r - cb.r) < 0.005 && Math.abs(ca.g - cb.g) < 0.005 && Math.abs(ca.b - cb.b) < 0.005 && Math.abs(ca.a - cb.a) < 0.005;
    }

    function test_theSearchFieldIsTheSharedOne() {
        const t = make();
        const field = t.win.searchField;
        compare(field.height, Tokens.toolbarSearchHeight, "the shared field's 28");
        verify(field.fieldRadius !== undefined, "the shared TextField");
        const clear = find(field, it => it.objectName === "clearButton");
        verify(clear !== null && !clear.visible);
        t.win.focusSearch();
        keyClick("p");
        compare(t.win.pageKind, "search");
        verify(clear.visible, "a clear button with text");
        mouseClick(clear);
        compare(field.text, "");
        compare(t.win.pageKind, "section", "clearing goes back, as Esc does");
    }

    function test_theSelectionIsLighterWhileNotKey() {
        const t = make();
        const sidebar = find(t.win.contentItem, it => it.selectionFill !== undefined);
        verify(sidebar !== null);
        verify(near(sidebar.selectionFill, Appearance.withAlpha(Appearance.colors.text, Tokens.storeSidebarSelectionOpacity)), "key: the measured neutral");
        const other = createTemporaryObject(otherWindow, null);
        other.requestActivate();
        tryVerify(() => !t.win.active, 2000);
        verify(near(sidebar.selectionFill, Appearance.withAlpha(Appearance.colors.hover, Appearance.inactiveSelectionOpacity)), "not key: the inactive selection");
        Appearance.heldKeyWindow = t.win;
        verify(near(sidebar.selectionFill, Appearance.withAlpha(Appearance.colors.text, Tokens.storeSidebarSelectionOpacity)), "held key by a shell menu: the key one");
        Appearance.heldKeyWindow = null;
        other.close();
    }

    function test_anAppButtonHasItsStates() {
        const t = make();
        t.win.openPage("app:org.example.Paint");
        tryVerify(() => t.win.pageKind === "app");
        wait(50);
        // One that can act and lies inside the window (the page scrolls past its bottom).
        const inView = it => {
            const p = it.mapToItem(null, 0, 0);
            return p.y >= 0 && p.y + it.height <= t.win.height && p.x >= 0 && p.x + it.width <= t.win.width;
        };
        const store = find(t.win.page, it => it.canAct === true && it.state_ !== undefined && it.visible && inView(it));
        verify(store !== null, "an app's button that can act");
        const button = find(store, it => it.down !== undefined && it.background !== undefined);
        const overlay = find(button.background, it => it !== button.background && it.radius !== undefined && it.color !== undefined);
        verify(overlay !== null && !overlay.visible, "at rest: the grey alone");
        mouseMove(button, button.width / 2, button.height / 2);
        tryVerify(() => overlay.visible, 1000, "hovered: the hover ink");
        verify(near(overlay.color, Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity)));
        mousePress(button, button.width / 2, button.height / 2);
        verify(near(overlay.color, Appearance.withAlpha(Appearance.colors.hover, Tokens.controlPressedOpacity)), "pressed: denser");
        mouseMove(t.win.contentItem, 1, 1);
        mouseRelease(t.win.contentItem, 1, 1);
    }

    function test_aDisabledButtonDimsAtTheSharedOpacity() {
        // A button in a window without a backend shows its app's state, disabled (StoreButton's own rule).
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/store/qml/StoreButton.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const b = createTemporaryObject(comp, testCase, {app: {id: "x", name: "X", installed: false, kind: "repo"}});
        verify(b !== null && !b.canAct);
        const label = find(b, it => it.textFormat !== undefined && it.text !== undefined && it.text !== "");
        verify(label !== null);
        fuzzyCompare(Qt.color(label.color).a, Tokens.materialDisabledOpacity, 0.005);
    }

    function test_theSharedIndicatorsAndMenuHost() {
        const ring = Qt.createQmlObject('import Grassfield.Ui; ProgressRing {}', testCase);
        compare(ring.implicitWidth, Tokens.controlProgressRingSize);
        ring.destroy();
        const spinner = Qt.createQmlObject('import Grassfield.Ui; Spinner {}', testCase);
        compare(spinner.implicitWidth, Tokens.controlSpinnerSize);
        spinner.destroy();
        const host = Qt.createQmlObject('import Grassfield.Ui; MenuPopup {}', testCase);
        verify(host.openAt !== undefined && host.focusBack !== undefined);
        host.destroy();
    }

    function test_anEmptyCategorySaysSo() {
        const comp = Qt.createComponent(Qt.resolvedUrl("../../apps/store/qml/CategoryPage.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        const page = createTemporaryObject(comp, testCase, {width: 600, height: 400, categoryTitle: "Games", apps: []});
        verify(page !== null);
        const note = find(page, it => it.text === "No apps in this category.");
        verify(note !== null && note.visible, "an empty category says so");
        page.apps = [{id: "a", name: "A", kind: "aur"}, {id: "b", name: "B", kind: "repo"}];
        page.kind = "flatpak";
        verify(find(page, it => it.text === "No apps from this source in this category." && it.visible) !== null, "none from the chosen source");
        page.kind = "";
        verify(find(page, it => (it.text || "").indexOf("No apps") === 0 && it.visible) === null, "apps shown: no note");
    }

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        return xhr.responseText;
    }

    function test_theRestInTheSource() {
        const lockup = source("apps/store/qml/AppLockup.qml");
        verify(lockup.indexOf("height: Tokens.appsBorderWidth") > 0 && lockup.indexOf("devicePixelRatio") < 0, "the separator is one point, through the token");
        for (const [path, id] of [["apps/store/qml/CardShelf.qml", "shelfFocus"], ["apps/store/qml/CategoriesPage.qml", "tileFocus"],
                                  ["apps/store/qml/HeroCarousel.qml", "heroFocus"], ["apps/store/qml/ProductPage.qml", "moreFocus"],
                                  ["apps/store/qml/Sidebar.qml", "accountFocus"], ["apps/store/qml/StoreButton.qml", "ringFocus"]]) {
            const text = source(path);
            verify(text.indexOf("id: " + id) > 0 && text.indexOf(id + ".active") > 0, path + ": its ring on keyboard focus only");
        }
        verify(source("apps/settings/qml/MoreButton.qml").indexOf("MenuPopup {") > 0, "Settings' (…) button on the shared host");
    }
}
