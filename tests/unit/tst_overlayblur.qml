import QtQuick
import QtTest
import Grassfield.Ui

// The Overlay's blur region has the corner its dialog draws (ADR-0039 step 4, G2): Force Quit and an app's About are sheets
// (radius.sheet 26), a confirmation and a notice are alerts (radius.alert 24); the region once asked radius.alert for all four,
// so a sheet's blur was 2 pt squarer than its glass. The Overlay needs Quickshell, so its region is read from the source, the
// way tests/unit/tst_popupkinds.qml reads its Loader; the dialog itself (Grassfield.Ui only) is built and measured.
TestCase {
    name: "OverlayBlur"

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        return xhr.responseText.replace(/\/\/.*$/gm, "");
    }

    // The body of the blur region's radius binding in the Overlay.
    function blurRadiusBody() {
        const overlay = source("shell/overlay/Overlay.qml");
        const region = overlay.indexOf("id: blurRegion");
        verify(region >= 0, "the Overlay's blur region");
        const start = overlay.indexOf("radius: {", region);
        verify(start > region);
        const end = overlay.indexOf("\n            }", start);
        verify(end > start);
        return overlay.slice(start, end);
    }

    function test_theBlurTakesTheDialogsOwnCorner() {
        const body = blurRadiusBody();
        verify(/holder\.item as Dialog/.test(body), "the region reads the loaded dialog");
        verify(/\.cornerRadius/.test(body), "and takes its corner");
        verify(body.indexOf("radiusAlert") < 0, "no corner named for the dialogs in the Overlay: " + body);
        verify(body.indexOf("radiusSheet") < 0);
    }

    // Every dialog kind the Overlay loads is a Dialog, so the region's cast applies to each.
    function test_everyDialogKindIsADialog_data() {
        return [
            {tag: "forcequit", file: "ForceQuitPanel.qml", sheet: true},
            {tag: "appabout", file: "AppAboutPanel.qml", sheet: true},
            {tag: "confirm", file: "ConfirmDialog.qml", sheet: false},
            {tag: "notice", file: "NoticeDialog.qml", sheet: false}
        ];
    }

    function test_everyDialogKindIsADialog(data) {
        const text = source("shell/overlay/" + data.file);
        verify(/^Dialog \{$/m.test(text), data.file + " is rooted in Dialog");
        compare(/^\s*sheet: true$/m.test(text), data.sheet, data.file + (data.sheet ? " is a sheet" : " is an alert"));
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
