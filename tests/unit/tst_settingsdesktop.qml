import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml" as SettingsQml

// Settings > Desktop & Dock as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Desktop & Dock): Size and
// Magnification side by side at the measured places, Magnification as one slider from Off through Small to Large, the rows of
// the capture writing their keys, Show items as a check box, and the Screen Corners sheet. The store is a fake.
TestCase {
    id: testCase
    name: "SettingsDesktop"
    width: 508
    height: 1600
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
        SettingsQml.DesktopPage {
            width: 508
            height: 1600
        }
    }

    Component {
        id: sheetComponent
        SettingsQml.ScreenCornersSheet {
            anchors.fill: parent
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

    function test_slidersSideBySide() {
        const t = make();
        waitForRendering(t.page);
        const size = named(t.page.contentItem, "Size");
        const magnification = named(t.page.contentItem, "Magnification");
        verify(size && magnification);
        const group = size.parent.parent.parent;
        compare(group.height, Tokens.settingsDockSlidersHeight);
        compare(size.parent.x, Tokens.settingsRowInset);
        compare(size.width, Tokens.settingsDockSizeSliderWidth);
        compare(magnification.parent.x, Tokens.settingsDockMagnificationX);
        compare(magnification.width, 468 - Tokens.settingsDockMagnificationX - Tokens.settingsRowInset);
        compare(size.y + size.height / 2, Tokens.settingsDockSliderCenter);
        // Ticks at the knob's two extremes for Size; at Small and Large for Magnification.
        compare(size.dots, [0, 1]);
        compare(magnification.dots, [Tokens.settingsDockMagnificationSmallAt, 1]);
    }

    function test_sizeWritesWholePixels() {
        const t = make();
        const size = named(t.page.contentItem, "Size");
        compare(size.value, 48);
        size.moved(61.4);
        compare(last(t.store), {"dock.size": 61});
    }

    function test_magnificationOffSmallLarge() {
        const t = make();
        const m = named(t.page.contentItem, "Magnification");
        // Off by default: the knob at the start.
        compare(m.value, 0);
        m.moved(1);
        compare(last(t.store), {"dock.magnificationEnabled": true, "dock.magnification": 2.5});
        compare(m.value, 1);
        // Between Off and Small: the nearer of the two.
        m.moved(Tokens.settingsDockMagnificationSmallAt * 0.6);
        compare(last(t.store), {"dock.magnificationEnabled": true, "dock.magnification": Tokens.settingsDockMagnificationSmall});
        compare(m.value, Tokens.settingsDockMagnificationSmallAt);
        m.moved(Tokens.settingsDockMagnificationSmallAt * 0.4);
        compare(last(t.store), {"dock.magnificationEnabled": false});
        compare(m.value, 0);
        // A stored magnification is shown on the Small-Large stretch (the default 1.6 included).
        t.store.setMany({"dock.magnificationEnabled": true, "dock.magnification": 1.6});
        const small = Tokens.settingsDockMagnificationSmall;
        fuzzyCompare(m.value, Tokens.settingsDockMagnificationSmallAt + (1 - Tokens.settingsDockMagnificationSmallAt) * (1.6 - small) / (2.5 - small), 1e-9);
    }

    function test_dockRows() {
        const t = make();
        const position = named(t.page.contentItem, "Dock position on screen");
        verify(position.inline);
        position.picked("left");
        compare(last(t.store), {"dock.position": "left"});
        named(t.page.contentItem, "Minimized window animation").picked("shrink");
        compare(last(t.store), {"dock.minimizeEffect": "shrink"});
        named(t.page.contentItem, "Window title bar double-click action").picked("minimize");
        compare(last(t.store), {"windows.titlebarDoubleClick": "minimize"});
        const toggles = [["Minimize windows into application icon", "dock.minimizeIntoApp"], ["Automatically hide and show the Dock", "dock.autohide"], ["Animate opening applications", "dock.animateOpening"], ["Show indicators for open applications", "dock.showIndicators"], ["Show recent apps in Dock", "dock.showRecents"]];
        for (const [name, key] of toggles) {
            const toggle = named(t.page.contentItem, name);
            verify(toggle, name);
            toggle.toggled(!toggle.checked);
            compare(last(t.store)[key], t.store.value(key), name);
        }
    }

    // TL32: the tiling switches in their order, each writing its key, under the compositor extension's footnote; the
    // double-click action offers Fill first.
    function test_windowsRows() {
        const t = make();
        const rows = [["Drag windows to left or right edge of screen to tile", "windows.tilingEdges"], ["Drag windows to menu bar to fill screen", "windows.tilingMenuBar"], ["Hold Alt key while dragging windows to tile", "windows.tilingOptionDrag"], ["Tiled windows have margins", "windows.tilingMargins"], ["Show layouts when hovering over the green button", "windows.tilingLayouts"], ["Suggest windows to fill the rest of a layout", "windows.tilingSuggestions"], ["Bring tile groups forward together", "windows.tilingGroups"], ["Rebuild the compositor extension after Hyprland updates", "windows.rebuildExtension"]];
        let above = -1;
        for (const [name, key] of rows) {
            const toggle = named(t.page.contentItem, name);
            verify(toggle, name);
            const y = toggle.mapToItem(t.page.contentItem, 0, 0).y;
            verify(y > above, name + " comes after the row above it");
            above = y;
            compare(toggle.checked, SettingsContract.ALL_DEFAULTS[key], name);
            toggle.toggled(!toggle.checked);
            const e = {};
            e[key] = !SettingsContract.ALL_DEFAULTS[key];
            compare(last(t.store), e, name);
            compare(toggle.checked, !SettingsContract.ALL_DEFAULTS[key], name + " shows the stored value");
        }
        const group = find(t.page.contentItem, i => i.caption === "Windows" && i.footnote !== undefined);
        verify(group);
        compare(group.footnote, "Needs the Grassfield compositor extension.");
        const action = named(t.page.contentItem, "Window title bar double-click action");
        compare(action.model.map(m => m.id), ["fill", "zoom", "minimize", "none"]);
        action.picked("fill");
        compare(last(t.store), {"windows.titlebarDoubleClick": "fill"});
    }

    function test_showItemsOnDesktop() {
        const t = make();
        const box = named(t.page.contentItem, "Show items on the desktop");
        verify(box);
        compare(box.text, "On Desktop");
        verify(box.checked);
        mouseClick(box);
        compare(last(t.store), {"desktop.showIcons": false});
    }

    function test_screenCorners() {
        const t = make();
        const button = find(t.page.contentItem, i => i.text === "Screen Corners…" && i.clicked !== undefined);
        verify(button);
        let asked = 0;
        t.page.screenCornersRequested.connect(() => asked++);
        button.clicked();
        compare(asked, 1);
        const sheet = createTemporaryObject(sheetComponent, testCase, {store: t.store});
        sheet.open();
        const corners = ["Top left corner", "Top right corner", "Bottom left corner", "Bottom right corner"];
        const keys = ["topLeft", "topRight", "bottomLeft", "bottomRight"];
        for (let i = 0; i < corners.length; i++) {
            const box = named(sheet, corners[i]);
            verify(box, corners[i]);
            compare(box.model.map(m => m.id), ["none", "overview", "notifications", "apps", "lock"]);
            box.picked("overview");
            compare(last(t.store), {["hotCorners." + keys[i]]: "overview"});
        }
    }
}
