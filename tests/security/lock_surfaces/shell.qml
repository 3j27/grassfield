pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.launchpad
import qs.notifications
import qs.overview
import qs.search
import qs.services

// GF-AUDIT-001 GF-116 (DT-08), on the REAL controllers (scripts/dev/test.sh: `qs -p tests/security/lock_surfaces`,
// offscreen, a dev session without the D-Bus server; the layer-shell windows are stubs): while the session is locked
// nothing but the lock screen opens.
//  - control: unlocked, every surface opens (so the refusals below are not a broken open path);
//  - lock: SessionState.locked (what shell.qml binds to Lock.locked) closes every open surface: Search (and drops its
//    query), Apps, the Notification Center, the Overview, any Popups kind (Control Center, menus, sheets);
//  - refusal: while locked, every way into each surface stays closed: Search show/toggle, Apps show/toggle, Notification
//    Center toggle and the widget gallery, Overview show/toggle, Popups open/toggle/openCentered/confirm/notice;
//  - unlock: the surfaces open again.
// The IPC functions, bindings, screen corners and gestures all end in these entry points (tests/security/lock_surfaces.sh
// checks that statically, with the Dock keyboard mode, window commands and the polkit sheet). Prints
// "lock-surfaces: PASS" or the failures.
ShellRoot {
    id: root

    property var failures: []
    property int checks: 0

    function check(name: string, ok: bool): void {
        checks++;
        if (!ok)
            failures.push(name);
    }

    Search {
        id: search
    }

    AppsController {
        id: apps
    }

    Overview {
        id: overview
        // shell.qml: locked: Lock.lockState !== "unlocked" (the same state SessionState.locked mirrors).
        locked: SessionState.locked
    }

    function openAll(): void {
        search.show("secret query");
        apps.show();
        Notifications.toggleCenter("");
        overview.show();
        Popups.open("controlcenter", "", 0, 0, "right", {});
    }

    function closeAll(): void {
        search.hide();
        apps.hide();
        if (Notifications.centerOpen)
            Notifications.closeCenter();
        overview.hide();
        Popups.close();
    }

    function anyOpen(): string {
        const open = [];
        if (search.open)
            open.push("search");
        if (apps.open)
            open.push("apps");
        if (Notifications.centerOpen)
            open.push("notification center");
        if (overview.open)
            open.push("overview");
        if (Popups.active)
            open.push("popup " + Popups.kind);
        return open.join(", ");
    }

    function run(): void {
        SessionState.locked = false;

        // Control: unlocked, each surface opens.
        search.show("");
        check("control: search opens unlocked", search.open);
        search.hide();
        apps.show();
        check("control: apps opens unlocked", apps.open);
        apps.hide();
        Notifications.toggleCenter("");
        check("control: notification center opens unlocked", Notifications.centerOpen);
        Notifications.closeCenter();
        overview.show();
        check("control: overview opens unlocked", overview.open);
        overview.hide();
        Popups.open("controlcenter", "", 0, 0, "right", {});
        check("control: control center opens unlocked", Popups.kind === "controlcenter");
        Popups.close();

        // Lock with everything open (Popups last: opening Search or Apps closes a popup, as on macOS).
        openAll();
        check("setup: everything open before the lock (" + anyOpen() + ")", search.open && apps.open && Notifications.centerOpen && overview.open && Popups.kind === "controlcenter");
        SessionState.locked = true;
        check("lock: search closes", !search.open);
        check("lock: search drops its query", search.query === "");
        check("lock: apps closes", !apps.open);
        check("lock: notification center closes", !Notifications.centerOpen);
        check("lock: overview starts closing (releases the keyboard first)", overview.stage !== "open");
        check("lock: popups close", !Popups.active);
    }

    // After the overview's keyboard release (Tokens.overviewReleaseBoundMs).
    function runLocked(): void {
        check("lock: overview closed", !overview.open);

        // Every entry point while locked.
        // Each entry point on its own (a toggle after a wrongly opened surface would close it again and hide the defect).
        search.show("x");
        check("locked: search.show stays closed", !search.open);
        search.toggle();
        check("locked: search.toggle stays closed", !search.open);
        apps.show();
        check("locked: apps.show stays closed", !apps.open);
        apps.toggle();
        check("locked: apps.toggle stays closed", !apps.open);
        Notifications.toggleCenter("");
        check("locked: Notifications.toggleCenter stays closed", !Notifications.centerOpen);
        Notifications.openWidgetGallery("");
        check("locked: the widget gallery stays closed", !Notifications.centerOpen);
        check("locked: the widget gallery is not queued for the next open", !Notifications.galleryWanted);
        overview.show();
        check("locked: overview.show stays closed", !overview.open);
        overview.toggle();
        check("locked: overview.toggle stays closed", !overview.open);
        const kinds = ["system", "app", "appfile", "appwindow", "appbridge", "tray", "volume", "network", "battery", "controlcenter", "dock", "dockstack", "about", "forcequit", "appabout", "notice", "confirm"];
        const opened = [];
        for (const k of kinds) {
            Popups.open(k, "", 0, 0, "left", {});
            if (Popups.active)
                opened.push("open " + k);
            Popups.toggle(k, "", 0, 0, "left", {});
            if (Popups.active)
                opened.push("toggle " + k);
            Popups.openCentered(k, {});
            if (Popups.active)
                opened.push("openCentered " + k);
            Popups.close();
        }
        Popups.confirm("t", "m", "OK", "logout", {}, true);
        if (Popups.active)
            opened.push("confirm");
        Popups.notice("t", "m");
        if (Popups.active)
            opened.push("notice");
        check("locked: no popup kind opens (" + opened.join(", ") + ")", opened.length === 0);
        check("locked: nothing is open at all (" + anyOpen() + ")", anyOpen() === "");

        // Unlock: back to normal.
        SessionState.locked = false;
        openAll();
        check("unlock: everything opens again (" + anyOpen() + ")", search.open && apps.open && Notifications.centerOpen && overview.open && Popups.kind === "controlcenter");
        closeAll();
    }

    Timer {
        interval: 300
        running: true
        onTriggered: {
            root.run();
            lockedStep.start();
        }
    }

    Timer {
        id: lockedStep
        interval: 1000
        onTriggered: {
            root.runLocked();
            if (root.failures.length === 0) {
                console.log("lock-surfaces: PASS (" + root.checks + " checks)");
                Qt.exit(0);
            } else {
                console.log("lock-surfaces: FAIL: " + root.failures.join("; "));
                Qt.exit(1);
            }
        }
    }
}
