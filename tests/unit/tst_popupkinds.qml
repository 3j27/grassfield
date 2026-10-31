import QtQuick
import QtTest
import "../../shell/services/PopupKinds.js" as PopupKinds

// The popup kinds Popups.open accepts (shell/services/PopupKinds.js): exactly the kinds the Overlay draws, read from its
// Loader's switch the way tests/unit/tst_barbandwiring.qml reads the sources, and Popups.open asks for one. A kind the Overlay
// does not draw would map an empty overlay that takes the keyboard (the retired "about", review of ce69dc6); the refusal
// itself, on the real Popups, is in tests/security/lock_surfaces/shell.qml.
TestCase {
    name: "PopupKinds"

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        return xhr.responseText.replace(/\/\/.*$/gm, "");
    }

    function test_unknownKindsAreRefused() {
        verify(!PopupKinds.known("about"));
        verify(!PopupKinds.known(""));
        verify(!PopupKinds.known("Forcequit"));
        verify(!PopupKinds.known(undefined));
        verify(PopupKinds.known("forcequit"));
        verify(PopupKinds.known("appabout"));
    }

    function test_theListIsTheOverlays() {
        const overlay = source("shell/overlay/Overlay.qml");
        const start = overlay.indexOf("sourceComponent: {");
        verify(start >= 0, "the Overlay's Loader switch");
        const end = overlay.indexOf("return null;", start);
        verify(end > start);
        const drawn = [];
        const pattern = /case "([A-Za-z]+)":/g;
        const body = overlay.slice(start, end);
        for (let m = pattern.exec(body); m !== null; m = pattern.exec(body))
            drawn.push(m[1]);
        drawn.sort();
        compare(drawn, PopupKinds.kinds.slice().sort());
    }

    // ADR-0040 IQ-B1 B (the review of 52b2bec): a notice shows its subject's symbol, the information symbol when the caller
    // gives none; a missing symbol through a string-typed parameter arrives as "undefined" and drew an empty frame.
    function test_aNoticeWithoutASymbolShowsInfo() {
        compare(PopupKinds.noticeSymbol("moon"), "moon");
        compare(PopupKinds.noticeSymbol(undefined), "info");
        compare(PopupKinds.noticeSymbol("undefined"), "info");
        compare(PopupKinds.noticeSymbol(""), "info");
        compare(PopupKinds.noticeSymbol(null), "info");
        const popups = source("shell/services/Popups.qml");
        verify(/function notice\(title: string, message: string, symbol\): void \{\s*openCentered\("notice", \{title: title, message: message, symbol: PopupKinds\.noticeSymbol\(symbol\)\}\);/.test(popups),
               "Popups.notice passes its untyped symbol through PopupKinds.noticeSymbol");
    }

    function test_openAsksForAKnownKind() {
        const popups = source("shell/services/Popups.qml");
        verify(popups.indexOf("if (!PopupKinds.known(popupKind)) {") > popups.indexOf("function open(popupKind"), "Popups.open checks the kind");
    }
}
