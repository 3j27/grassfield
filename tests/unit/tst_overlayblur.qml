import QtQuick
import QtTest
import Grassfield.Ui
import "../../shell/services/PopupKinds.js" as PopupKinds

// The Overlay's blur region has the corner its popup draws (ADR-0039 step 4, G2): Force Quit and an app's About are sheets
// (radius.sheet, 16 since step 10), a confirmation and a notice are alerts (radius.alert, 26 since step 10); the region once
// asked radius.alert for all four, so a sheet's blur did not follow its glass. The rule is PopupKinds.blurCorner, run here; its list of dialog kinds is
// held to what the Overlay builds (every kind of its Loader, the root type of the component it loads), so a new kind built on
// Dialog cannot fall back to a menu's corner unnoticed. The Overlay needs Quickshell: that it hands the loaded Dialog's corner
// to the rule is read from its source. The Dialog itself (Grassfield.Ui only) is built and measured.
TestCase {
    name: "OverlayBlur"

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        return xhr.responseText.replace(/\/\/.*$/gm, "");
    }

    function exists(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        return xhr.responseText.length > 0;
    }

    // {kind: the type the Overlay loads for it}, from the Loader's switch and the Components it names.
    function overlayKinds() {
        const overlay = source("shell/overlay/Overlay.qml");
        const start = overlay.indexOf("sourceComponent: {");
        const end = overlay.indexOf("return null;", start);
        verify(start >= 0 && end > start, "the Overlay's Loader switch");
        const body = overlay.slice(start, end);
        const kinds = {};
        let pending = [];
        for (const line of body.split("\n")) {
            const c = /case "([A-Za-z]+)":/.exec(line);
            if (c)
                pending.push(c[1]);
            const r = /return ([A-Za-z]+);/.exec(line);
            if (r) {
                const component = new RegExp("Component \\{\\s*id: " + r[1] + "\\s+([A-Z][A-Za-z]*) \\{").exec(overlay);
                verify(component !== null, "the Component " + r[1]);
                for (const k of pending)
                    kinds[k] = component[1];
                pending = [];
            }
        }
        return kinds;
    }

    // The root type of a shell QML type (its file in one of the shell's modules).
    function rootType(type) {
        for (const dir of ["overlay", "overlay/controlcenter", "menubar", "dock", "services", "platform"]) {
            const path = "shell/" + dir + "/" + type + ".qml";
            if (exists(path)) {
                const m = /^(?:[A-Za-z]+\.)?([A-Z][A-Za-z]*) \{$/m.exec(source(path));
                verify(m !== null, path + " has a root object");
                return m[1];
            }
        }
        fail("no file for " + type);
        return "";
    }

    function test_theDialogKindsAreTheOverlaysDialogs() {
        const kinds = overlayKinds();
        compare(Object.keys(kinds).sort(), PopupKinds.kinds.slice().sort(), "every kind is built by the Overlay");
        const built = Object.keys(kinds).filter(k => rootType(kinds[k]) === "Dialog").sort();
        compare(built, PopupKinds.dialogs.slice().sort(), "PopupKinds.dialogs are exactly the kinds built on Dialog");
    }

    function test_theBlurTakesTheDialogsCorner_data() {
        return [
            {tag: "a sheet", corner: Tokens.radiusSheet},
            {tag: "an alert", corner: Tokens.radiusAlert}
        ];
    }

    function test_theBlurTakesTheDialogsCorner(data) {
        for (const kind of PopupKinds.dialogs)
            compare(PopupKinds.blurCorner(kind, data.corner, Tokens), data.corner, kind + ", " + data.tag);
    }

    function test_theOtherKinds() {
        // A dialog not loaded yet, and the kinds that are no dialog.
        compare(PopupKinds.blurCorner("forcequit", undefined, Tokens), Tokens.radiusMenu);
        compare(PopupKinds.blurCorner("nowplaying", undefined, Tokens), Tokens.quicksettingsRadiusTile);
        for (const kind of PopupKinds.kinds.filter(k => PopupKinds.dialogs.indexOf(k) < 0 && k !== "nowplaying"))
            compare(PopupKinds.blurCorner(kind, Tokens.radiusSheet, Tokens), Tokens.radiusMenu, kind + " takes a menu's corner");
    }

    function test_theOverlayHandsTheRuleTheDialogsCorner() {
        const overlay = source("shell/overlay/Overlay.qml");
        const region = overlay.indexOf("id: blurRegion");
        verify(region >= 0);
        const line = overlay.slice(region, overlay.indexOf("\n", overlay.indexOf("radius:", region)));
        verify(line.indexOf("radius: PopupKinds.blurCorner(Popups.kind, (holder.item as Dialog)?.cornerRadius, Tokens)") >= 0, line);
    }

    // Each dialog kind's shape: Force Quit and an app's About are sheets, the others alerts.
    function test_everyDialogKindHasItsShape_data() {
        return [
            {tag: "forcequit", file: "ForceQuitPanel.qml", sheet: true},
            {tag: "appabout", file: "AppAboutPanel.qml", sheet: true},
            {tag: "confirm", file: "ConfirmDialog.qml", sheet: false},
            {tag: "notice", file: "NoticeDialog.qml", sheet: false}
        ];
    }

    function test_everyDialogKindHasItsShape(data) {
        compare(/^\s*sheet: true$/m.test(source("shell/overlay/" + data.file)), data.sheet,
                data.file + (data.sheet ? " is a sheet" : " is an alert"));
    }

    function test_aDialogDrawsTheCornerItStates_data() {
        return [
            {tag: "sheet", sheet: true, radius: Tokens.radiusSheet},
            {tag: "alert", sheet: false, radius: Tokens.radiusAlert}
        ];
    }

    function test_aDialogDrawsTheCornerItStates(data) {
        const component = Qt.createComponent(Qt.resolvedUrl("../../shell/overlay/Dialog.qml"));
        compare(component.status, Component.Ready, component.errorString());
        const dialog = createTemporaryObject(component, this, {sheet: data.sheet, title: "Title"});
        verify(dialog !== null);
        compare(dialog.cornerRadius, data.radius);
        compare(dialog.surface.radius, dialog.cornerRadius, "the glass is drawn with the corner the blur takes");
    }
}
