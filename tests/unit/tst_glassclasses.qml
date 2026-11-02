import QtQuick
import QtTest
import Grassfield.Ui

// Glass classes for every surface (ADR-0039 step 22; audit §3.17, ADR-0024 section 2): the Overview's band and the widget
// gallery on the clear class (0.15), the widgets on the near-opaque one (0.92), every other text surface on the menus' class;
// a tail fills with its body's glass as drawn, a close capsule with no blur under it follows Reduce Transparency and Increase
// Contrast; Material's inner rim is stronger toward the top left, and Increase Contrast raises its dark appearance's edge.
TestCase {
    id: tc

    name: "GlassClasses"
    width: 300
    height: 200
    visible: true
    when: windowShown

    Rectangle {
        id: scene
        width: 300
        height: 200
        color: Appearance.colors.windowBackground

        Material {
            id: glass
            x: 40
            y: 40
            width: 200
            height: 100
            radius: 20
            shadowEnabled: false
            borderEnabled: false
        }
    }

    Tooltip {
        id: tip
        text: "Finder"
        tail: true
    }

    property bool wasDark: false

    function initTestCase() {
        tc.wasDark = Appearance.dark;
    }

    function cleanup() {
        Appearance.dark = tc.wasDark;
        Appearance.increaseContrast = false;
        Appearance.reduceTransparency = false;
        Appearance.transparency = Tokens.materialDefaultTransparency;
        Appearance.backdrops = {};
    }

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        return xhr.responseText;
    }

    function test_theNewClasses() {
        compare(Tokens.glassGallery, 0.15);
        compare(Tokens.glassWidgets, 0.92);
        compare(Appearance.glassTargets.gallery, Tokens.glassGallery);
        compare(Appearance.glassTargets.widgets, Tokens.glassWidgets);
        // Over an unknown backdrop the clear class keeps its text legible as every class does (the worst case); the widgets'
        // target is above that floor, so they draw it.
        for (const dark of [false, true]) {
            Appearance.dark = dark;
            compare(Appearance.glassAlphaOver("gallery", Tokens.materialDefaultTransparency, null), Appearance.glassAlphaOver("controls", Tokens.materialDefaultTransparency, null));
            compare(Appearance.glassAlphaOver("widgets", Tokens.materialDefaultTransparency, null), Tokens.glassWidgets);
        }
        // Over a known mid-grey bare desktop the gallery is clearer than the one tint of before (0.85).
        verify(Appearance.glassAlphaOver("gallery", Tokens.materialDefaultTransparency, {lumMin: 0.2, lumMax: 0.2}) < Appearance.tintAlpha(Tokens.materialDefaultTransparency));
    }

    // Every surface that step 22 names declares its class; the shell's are read as source (Quickshell is not loaded here).
    function test_everySurfaceHasAClass_data() {
        return [
            {tag: "Overview", path: "shell/overview/OverviewWindow.qml", classes: ["gallery", "menu"]},
            {tag: "widget gallery", path: "shell/widgets/WidgetGallery.qml", classes: ["gallery"]},
            {tag: "widgets", path: "shell/widgets/WidgetHost.qml", classes: ["widgets"]},
            {tag: "switcher", path: "shell/switcher/SwitcherWindow.qml", classes: ["menu"]},
            {tag: "Stages badges", path: "shell/stages/Stages.qml", classes: ["controls", "controls"]},
            {tag: "About This Wallpaper", path: "shell/desktop/AttributionCard.qml", classes: ["menu"]},
            {tag: "tooltip", path: "ui/Grassfield/Ui/Tooltip.qml", classes: ["menu"]},
            {tag: "sheet", path: "ui/Grassfield/Ui/Sheet.qml", classes: ["menu"]},
            {tag: "Preview's Info", path: "apps/preview/qml/Viewer.qml", classes: ["menu"]}
        ];
    }

    function test_everySurfaceHasAClass(data) {
        const text = source(data.path);
        const all = text.match(/\bMaterial \{/g) ?? [];
        const classes = [];
        const re = /\bMaterial \{[^}]*?glassClass: "(\w+)"/g;
        let m;
        while ((m = re.exec(text)) !== null)
            classes.push(m[1]);
        compare(classes.length, all.length, "every Material in " + data.path + " has a class");
        compare(classes, data.classes);
    }

    function tailPath(item) {
        const stack = [item];
        while (stack.length > 0) {
            const it = stack.shift();
            if (String(it).indexOf("QQuickShape") === 0)
                return it.data[0]; // the first: the bottom tail
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    function materialOf(item) {
        const stack = [item];
        while (stack.length > 0) {
            const it = stack.shift();
            if (it.glassClass !== undefined && it.fillColor !== undefined)
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    function test_aTailFillsWithItsBodysGlass() {
        const path = tailPath(tip);
        const body = materialOf(tip);
        verify(path !== null && body !== null);
        compare(body.glassClass, "menu");
        verify(Qt.colorEqual(path.fillColor, body.fillColor), "at rest");
        Appearance.increaseContrast = true;
        verify(body.tintAlpha >= Tokens.glassContrastFrost);
        verify(Qt.colorEqual(path.fillColor, body.fillColor), "frosted by Increase Contrast with its body");
        Appearance.increaseContrast = false;
        Appearance.reduceTransparency = true;
        compare(body.tintAlpha, 1);
        verify(Qt.colorEqual(path.fillColor, body.fillColor), "opaque under Reduce Transparency with its body");
    }

    Component {
        id: menuComponent
        PopupMenu {
            model: [{id: "a", text: "Open"}]
        }
    }

    function test_aMenuShowsItsGlassToItsTail() {
        const menu = createTemporaryObject(menuComponent, tc);
        verify(menu !== null);
        const body = materialOf(menu);
        verify(Qt.colorEqual(menu.glassFill, body.fillColor));
        Appearance.increaseContrast = true;
        verify(Qt.colorEqual(menu.glassFill, body.fillColor));
        compare(Qt.color(menu.glassFill).a >= Tokens.glassContrastFrost - 0.005, true);
    }

    function test_aCloseCapsuleFollowsTheSettings() {
        const a = Tokens.notificationCloseTintOpacity;
        compare(Appearance.fixedGlassAlpha(a), a);
        Appearance.increaseContrast = true;
        compare(Appearance.fixedGlassAlpha(a), Math.max(a, Tokens.glassContrastFrost));
        compare(Appearance.fixedGlassAlpha(0.5), Tokens.glassContrastFrost, "a clearer piece is frosted");
        Appearance.increaseContrast = false;
        Appearance.reduceTransparency = true;
        compare(Appearance.fixedGlassAlpha(a), 1, "opaque under Reduce Transparency");
        Appearance.reduceTransparency = false;
        Appearance.transparency = 0;
        compare(Appearance.fixedGlassAlpha(a), 1, "opaque with the slider at opaque");
        for (const path of ["shell/notifications/Banner.qml", "shell/notifications/NotificationCenter.qml", "shell/notifications/NotificationList.qml"]) {
            const text = source(path);
            verify(text.indexOf("Tokens.notificationCloseTintOpacity)") < 0 || text.indexOf("fixedGlassAlpha(Tokens.notificationCloseTintOpacity)") >= 0, path);
            compare(text.split("Appearance.withAlpha(Appearance.colors.materialTint, Tokens.notificationCloseTintOpacity)").length, 1, path + ": no fixed tint left");
        }
    }

    // The inner rim at the start and the end of a straight edge (one device pixel inside the shape at 1x).
    function test_theRimIsStrongerTowardTheTopLeft() {
        Appearance.reduceTransparency = true; // an opaque tint: the rim is read against a flat colour
        Appearance.dark = true;
        wait(50);
        const img = grabImage(scene);
        const lum = (c) => 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
        const at = (x, y) => lum(img.pixel(glass.x + x, glass.y + y));
        const r = glass.radius;
        const top0 = at(r + 2, 1), top1 = at(glass.width - r - 2, 1);
        const left0 = at(1, r + 2), left1 = at(1, glass.height - r - 2);
        const bottom = at(glass.width / 2, glass.height - 2), right = at(glass.width - 2, glass.height / 2);
        verify(top0 > top1, "the top edge fades from the left: " + top0 + " " + top1);
        verify(left0 > left1, "the left edge fades from the top: " + left0 + " " + left1);
        verify(Math.abs(top1 - bottom) < 0.02 && Math.abs(left1 - right) < 0.02, "its far ends are the half rim of the bottom and right");
        // Round the corners: the brightest pixel where the rim crosses the diagonal, top left against bottom right.
        const d = Math.round(r - (r - 1.5) / Math.SQRT2);
        let tl = 0, br = 0;
        for (let i = -1; i <= 1; i++) {
            for (let j = -1; j <= 1; j++) {
                tl = Math.max(tl, at(d + i, d + j));
                br = Math.max(br, at(glass.width - 1 - d + i, glass.height - 1 - d + j));
            }
        }
        verify(tl > br, "the top-left corner stronger than the bottom-right one: " + tl + " " + br);
    }

    function test_increaseContrastRaisesTheDarkEdge() {
        Appearance.dark = true;
        compare(glass.borderOpacity, Tokens.materialEdgeOpacityDark);
        const rest = glass.borderOpacity;
        Appearance.increaseContrast = true;
        compare(Tokens.materialEdgeOpacityDark, 0.96);
        verify(glass.borderOpacity > rest, "raised: " + rest + " to " + glass.borderOpacity);
        Appearance.dark = false;
        compare(glass.borderOpacity, Tokens.materialBorderOpacity);
        compare(Tokens.materialBorderOpacity, 0.5);
    }
}
