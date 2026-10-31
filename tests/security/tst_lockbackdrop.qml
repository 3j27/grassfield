import QtQuick
import QtTest

// ADR-0040 step 4a (ID-7, ID-2, ID-15; ADR-0016 section 6, W8): the lock's backdrop and data, ready before they are needed.
// The modules need Quickshell, so their contract is read from the sources (the pure parts, WallpaperConfig.lockBackdropOf and
// withShown, run in tests/unit/tst_wallpaper.qml). Invariants for the security review:
//   - the lock decodes only the helper's own picture, checked again by absolute path and argument vector, never a shell, and
//     no video decoder enters the module;
//   - the lock surface asks for exactly what was decoded before, with the same options (the pixmap cache key);
//   - what a surface shows is taken once (backdrop, name, picture); the clock is refreshed on resume;
//   - engaging the lock reads none of it.
TestCase {
    name: "LockBackdrop"

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        // Comments out: a rule must hold in the code, not in a sentence about it.
        return xhr.responseText.split("\n").map(l => l.replace(/^\s*\/\/.*$/, "")).join("\n");
    }

    function block(text, start) {
        const i = text.indexOf(start);
        verify(i >= 0, start);
        let depth = 0;
        for (let j = text.indexOf("{", i); j < text.length; j++) {
            if (text[j] === "{")
                depth++;
            else if (text[j] === "}" && --depth === 0)
                return text.substring(i, j + 1);
        }
        fail("unbalanced " + start);
        return "";
    }

    function test_theStillIsCheckedBeforeItIsDecoded() {
        const s = source("shell/security/lock/LockStill.qml");
        // Absolute paths, an argument vector, `--` before the path; nothing else is run.
        verify(s.indexOf('root.run("real", ["/usr/bin/realpath", "-e", "--", w.file]);') >= 0);
        verify(s.indexOf('root.run("stat", ["/usr/bin/stat", "--printf", "%F|%s", "--", real]);') >= 0);
        compare((s.match(/root\.run\(/g) || []).length, 2);
        verify(!/"(sh|bash)"|execDetached|Quickshell\.exec/.test(s), "no shell");
        // The real path must still be a plain cache name of one of the two folders, and the file regular and bounded.
        verify(/WallpaperConfig\.lockBackdropOf\(\{shown: \{o: \{kind: "picture", file: real\}\}\}, "o", WallpaperState\.preparedDir, WallpaperState\.videoDir\)\.file !== real/.test(s));
        verify(/match\(\/\^regular file\\\|\(\\d\+\)\$\/\)/.test(s));
        verify(/parseInt\(m\[1\]\) > Tokens\.wallpaperLockStillMaxBytes/.test(s));
        // The decode is only ever of the checked real path.
        compare((s.match(/image\.source = /g) || []).length, 2);
        verify(s.indexOf('image.source = "file://" + root.pending;') >= 0 && s.indexOf('image.source = "";') >= 0);
        // An answer of a superseded request is dropped.
        verify(/function realChecked\(text: string, gen: int\): void \{\s*if \(gen !== root\.generation\)\s*return;/.test(s));
        verify(/function statChecked\(text: string, gen: int\): void \{\s*if \(gen !== root\.generation\)\s*return;/.test(s));
        // A check that never answers gives the artwork.
        verify(/interval: Tokens\.wallpaperToolTimeoutMs/.test(s));
    }

    function test_theLockAsksForWhatWasDecoded() {
        const still = block(source("shell/security/lock/LockStill.qml"), "Image {");
        const viewText = source("shell/security/lock/LockView.qml");
        const view = block(viewText, "Image {\n            id: still");
        for (const b of [still, view]) {
            verify(/cache: true/.test(b), b);
            verify(/fillMode: Image\.Stretch/.test(b), b);
            verify(!/sourceSize/.test(b), "no sourceSize: the cache key must not depend on the window's scale");
        }
        verify(/source: root\.backdrop !== null && root\.backdrop\.kind === "picture" \? root\.backdrop\.still : ""/.test(view));
        // The account picture: the same options as Lock.qml's preload, and only once it is decoded.
        const lock = source("shell/security/lock/Lock.qml");
        const preload = block(lock, "Image {\n        id: avatarPreload");
        const picture = block(viewText, "Image {\n                id: picture");
        for (const b of [preload, picture]) {
            verify(/cache: true/.test(b) && /fillMode: Image\.PreserveAspectCrop/.test(b) && !/sourceSize/.test(b), b);
        }
        verify(/source: VisualFixtures\.active \? "" : root\.frozenAvatar/.test(picture));
        verify(/readonly property string avatarReady: avatarPreload\.status === Image\.Ready \? String\(avatarPreload\.source\) : ""/.test(lock));
        verify(/avatarSource: root\.avatarReady/.test(lock));
        // No video decoder in the security modules (ADR-0016 section 6).
        for (const f of ["shell/security/lock/Lock.qml", "shell/security/lock/LockView.qml", "shell/security/lock/LockStill.qml"])
            verify(!/QtMultimedia|MediaPlayer|VideoOutput/.test(source(f)), f);
    }

    function test_whatTheLockShowsIsTakenOnce() {
        const v = source("shell/security/lock/LockView.qml");
        verify(/function adopt\(b: var\): void \{\s*if \(root\.backdrop === null && b !== null && b !== undefined\)\s*root\.backdrop = b;\s*\}/.test(v));
        compare((v.match(/root\.backdrop = /g) || []).length, 1, "adopt() is the only writer");
        verify(/root\.frozenName = root\.userName;/.test(v) && /root\.frozenAvatar = root\.avatarSource;/.test(v));
        verify(/readonly property string shownName: VisualFixtures\.active \? VisualFixtures\.user : frozenName/.test(v));
        // Bounded: nothing decided in time gives the artwork.
        verify(/interval: Tokens\.wallpaperFirstShowTimeoutMs\s*running: root\.backdrop === null/.test(v));
        // Sharp: no blur left on the lock (IQ-W4 A).
        verify(!/blurEnabled|blurMax/.test(v));
        // The clock on resume.
        verify(/onResumesChanged: clock\.refresh\(\)/.test(v));
        const inhibitor = source("shell/security/idle/SleepInhibitor.qml");
        verify(/function afterResume\(\): void \{[\s\S]*?Lock\.resumed\(\);[\s\S]*?\n    \}/.test(inhibitor));
        // The surface's own colour is the ground (ID-2, ID-15).
        verify(/color: Ground\.of\(surface\.screen \? surface\.screen\.name : ""\)/.test(source("shell/security/lock/Lock.qml")));
    }

    function test_engagingTheLockReadsNoneOfIt() {
        const lock = source("shell/security/lock/Lock.qml");
        for (const fn of ["function lock(reason: string): string {", "function engage(): void {", "function release(): void {", "function restore(intent: bool, when: string): void {"]) {
            const b = block(lock, fn);
            verify(!/backdrop|stills|avatarPreload|avatarReady|resumes/.test(b), fn);
        }
        // The backdrops only feed the view.
        compare((lock.match(/root\.backdropOf\(/g) || []).length, 1);
    }
}
