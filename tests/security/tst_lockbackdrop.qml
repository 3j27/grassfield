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
        // The two cache folders' own real paths with the file's (a cache behind a symbolic link), and the raw mode, which no
        // locale translates (review of cbd6ef05).
        verify(s.indexOf('root.run("real", ["/usr/bin/realpath", "-m", "--", WallpaperState.preparedDir, WallpaperState.videoDir, w.file]);') >= 0);
        verify(s.indexOf('root.run("stat", ["/usr/bin/stat", "--printf", "%f|%s", "--", real]);') >= 0);
        compare((s.match(/root\.run\(/g) || []).length, 2);
        verify(!/"(sh|bash)"|execDetached|Quickshell\.exec/.test(s), "no shell");
        // The real path must still be a plain cache name of one of the two folders, and the file regular and bounded.
        verify(/const real = WallpaperConfig\.lockStillReal\(text\);\s*if \(real === ""\) \{\s*root\.fail\(/.test(s));
        verify(/if \(!WallpaperConfig\.lockStillStatOk\(text, Tokens\.wallpaperLockStillMaxBytes\)\) \{\s*root\.fail\(/.test(s));
        // The decode is only ever of the checked real path.
        // Set to the checked path, cleared on a new request and on a failure (a late decode is not kept).
        compare((s.match(/image\.source = /g) || []).length, 3);
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
        // The account picture: the same options as LockStills.qml's preload, and only once it is decoded.
        const lock = source("shell/security/lock/Lock.qml");
        const holder = source("shell/security/lock/LockStills.qml");
        const preload = block(holder, "Image {\n        id: avatarPreload");
        const picture = block(viewText, "Image {\n                id: picture");
        for (const b of [preload, picture]) {
            verify(/cache: true/.test(b) && /fillMode: Image\.PreserveAspectCrop/.test(b) && !/sourceSize/.test(b), b);
        }
        verify(/source: VisualFixtures\.active \? "" : root\.frozenAvatar/.test(picture));
        verify(/readonly property string avatarReady: avatarPreload\.status === Image\.Ready \? String\(avatarPreload\.source\) : ""/.test(holder));
        verify(/readonly property string avatarReady: root\.stills \? root\.stills\.avatarReady : ""/.test(lock));
        verify(/avatarSource: root\.avatarReady/.test(lock));
        // No video decoder in the security modules (ADR-0016 section 6).
        for (const f of ["shell/security/lock/Lock.qml", "shell/security/lock/LockView.qml", "shell/security/lock/LockStill.qml", "shell/security/lock/LockStills.qml"])
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
        // The surface's own colour is the ground (ID-2, ID-15), taken once.
        const lockSrc = source("shell/security/lock/Lock.qml");
        verify(/function takeGround\(\): void \{\s*if \(surface\.groundTaken \|\| !surface\.screen\)\s*return;\s*surface\.groundTaken = true;\s*surface\.color = Ground\.of\(surface\.screen\.name\);/.test(lockSrc));
        verify(/onScreenChanged: surface\.takeGround\(\)/.test(lockSrc) && /Component\.onCompleted: surface\.takeGround\(\)/.test(lockSrc));
        // Focus first in the view (review of cbd6ef05).
        verify(/Component\.onCompleted: \{\s*focusField\(\);/.test(v));
    }

    // Review of cbd6ef05 (MAJOR 3): the display data is created at run time, last, never declared in the singleton that owns
    // WlSessionLock: a file of it that fails to load cannot keep the lock from existing.
    function test_theDisplayDataCannotBreakTheLock() {
        const lock = source("shell/security/lock/Lock.qml");
        verify(!/\bLockStills?\s*\{/.test(lock), "no LockStill or LockStills declared in Lock.qml");
        verify(!/\bVariants\s*\{/.test(lock) && !/\bImage\s*\{/.test(lock));
        verify(/Qt\.createComponent\(Qt\.resolvedUrl\("LockStills\.qml"\)\)/.test(lock));
        verify(/function prepareStills\(\): void \{\s*try \{/.test(lock), "every failure is caught and logged");
        verify(/strandedProbe\.start\(\);\s*\}\s*\/\/[^\n]*\n\s*prepareStills\(\);\s*\}/.test(source("shell/security/lock/Lock.qml").replace(/\r/g, "")) || /prepareStills\(\);\s*\}\s*$/m.test(lock), "last in Component.onCompleted");
    }

    // ADR-0040 step 4b (IQ-T2 A): the content fades in and out; the release follows the controller's timer (the machine's
    // "releasing", tst_lockmachine and tst_lockcontroller), never the view's animation; a lock request during it keeps the
    // lock; no input while releasing; the wallpaper does not fade.
    function test_theReleaseWaitsForTheFade() {
        const lock = source("shell/security/lock/Lock.qml");
        verify(/releaseMs: Appearance\.duration\(Tokens\.lockFadeOutMs\)/.test(lock));
        verify(/inputEnabled: controller\.pamAvailable && !controller\.releasing/.test(lock));
        verify(/function lock\(reason: string\): string \{\s*(\/\/[^\n]*\n\s*)*if \(controller\.interruptRelease\(\)\)/.test(lock), "a lock request interrupts a release first");
        verify(/readonly property bool holding: Machine\.isHolding\(controller\.lockState\) && sessionLock\.secure/.test(lock));
        // The lock is released only from the controller's unlockRequested (after the fade), as before.
        compare((lock.match(/root\.release\(\)/g) || []).length, 1);
        verify(/onUnlockRequested: root\.release\(\)/.test(lock));
        const v = source("shell/security/lock/LockView.qml");
        compare((v.match(/opacity: root\.contentOpacity/g) || []).length, 3, "the scrim, the date and clock, the account column");
        const at = v.indexOf("visible: root.backdrop !== null\n");
        verify(at > 0);
        const backdrop = block(v.substring(v.lastIndexOf("Item {", at)), "Item {");
        verify(/id: still/.test(backdrop) && /WallpaperArt \{/.test(backdrop), "the backdrop's block");
        verify(!/contentOpacity/.test(backdrop), "the wallpaper does not fade");
        verify(/duration: Appearance\.duration\(root\.releasing \? Tokens\.lockFadeOutMs : Tokens\.lockFadeInMs\)/.test(v));
        // The view knows nothing of the release: no signal, no call back into the lock.
        verify(!/signal\s+released|unlockRequested|controller\./.test(v));
    }

    function test_engagingTheLockReadsNoneOfIt() {
        const lock = source("shell/security/lock/Lock.qml");
        for (const fn of ["function lock(reason: string): string {", "function engage(): void {", "function release(): void {", "function restore(intent: bool, when: string): void {"]) {
            const b = block(lock, fn);
            verify(!/backdrop|stills|Stills|avatarPreload|avatarReady|resumes/.test(b), fn);
        }
        // The backdrops only feed the view.
        compare((lock.match(/root\.backdropOf\(/g) || []).length, 1);
    }
}
