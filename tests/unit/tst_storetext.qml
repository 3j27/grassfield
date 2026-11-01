import QtQuick
import QtTest
import "../../apps/store/qml/Store.js" as Store
import "../../apps/store/qml/StoreNav.js" as Nav

// The Store's words (apps/store/qml/Store.js: the source badges, the button, the operations and their outcomes, the content
// rating, the languages, the filter's sources, Installed's groups, Updates' state line) and its Back / Forward history
// (StoreNav.js).
TestCase {
    name: "StoreText"

    function test_sourceLabel() {
        compare(Store.sourceLabel("repo", "extra"), "Arch Linux · extra");
        compare(Store.sourceLabel("repo", "omarchy"), "Omarchy");
        compare(Store.sourceLabel("setup", ""), "Omarchy setup");
        compare(Store.sourceLabel("webapp", ""), "Web app");
        compare(Store.sourceLabel("aur", ""), "AUR");
        compare(Store.sourceLabel("flatpak", ""), "Flathub");
        compare(Store.sourceLabel("foreign", ""), "Not from a repository");
        compare(Store.sourceLabel("other", ""), "");
    }

    // The AUR (step 3b2): why Get or Uninstall… is not offered, its own wording for an unchecked Omarchy, a result's line, its
    // Installed group, a refused install, the warning.
    function test_aurTexts() {
        compare(Store.getBlockText("aurOff", "aur"), "Turn on the AUR in the Store's settings to install from it.");
        compare(Store.getBlockText("aurProtected", "aur"), "The system, Omarchy or Grassfield uses this name, so the Store doesn't build it from the AUR.");
        compare(Store.getBlockText("listsMissing", "aur"), "Omarchy's package lists can't be read, so the Store installs nothing from the AUR.");
        compare(Store.getBlockText("repository", "aur"), "A repository has this package: the Store installs it from there, from its own page.");
        compare(Store.getBlockText("aurUnchecked", "aur"), "Installing from the AUR hasn't been checked with your version of Omarchy yet. The Store offers it again once its catalog has been.");
        compare(Store.getBlockText("omarchyChanged", "aur"), Store.getBlockText("aurUnchecked", "aur"));
        compare(Store.getBlockText("omarchyChanged", "setup"), "This setup hasn't been checked with your version of Omarchy yet. The Store offers it again once its catalog has been.");
        compare(Store.uninstallReasonText("aurOff", "aur"), "Turn on the AUR in the Store's settings to uninstall it from the Store.");
        compare(Store.aurLine({votes: 1, outOfDate: false}), "1 vote");
        compare(Store.aurLine({votes: 120, outOfDate: true}), "120 votes · Flagged out of date");
        compare(Store.aurLine({name: "x"}), "");
        compare(Store.groupTitle("aur"), "AUR");
        compare(Store.resultText({kind: "install", outcome: "refused"}), "The installation was refused: the system changed since the Store checked it. Try again from its page.");
        compare(Store.resultText({kind: "remove", outcome: "refused"}), "This app can't be uninstalled from the Store.");
        compare(Store.resultText({kind: "install", outcome: "omarchyChanged", source: "aur"}), Store.omarchyChangedText("aur"));
        verify(Store.aurWarning().startsWith("AUR packages are made by users and reviewed by no one"));
    }

    // Flathub (step 3c part 2): why Get or Uninstall… is not offered, what a Flatpak can reach in plain words (SR11, SD25),
    // its Installed group, a stopped install said nothing about (SD26).
    function test_flathubTexts() {
        compare(Store.getBlockText("flathubOff", "flatpak"), "Turn on Flathub in the Store's settings to install from it.");
        compare(Store.getBlockText("noFlatpak", "flatpak"), "Flathub needs the flatpak package.");
        compare(Store.uninstallReasonText("flathubOff", "flatpak"), "Turn on Flathub in the Store's settings to uninstall it from the Store.");
        compare(Store.accessWords(["network", "allFiles", "home", "folders", "devices", "input", "usb", "kvm", "audio", "x11", "sharedMemory",
                                   "printers", "ssh", "gpg", "smartCards", "bus", "systemBus", "bluetooth", "canbus", "devel", "multiarch", "login", "outside"]),
                ["The internet", "All your files", "Your home folder", "Some of your folders", "Devices such as cameras, USB drives and game controllers",
                 "Game controllers and other input devices", "USB devices", "Virtual machines, through KVM", "Your speakers and microphone",
                 "The X11 display, where it can see what other X11 apps show and what you type in them", "Memory your other programs share",
                 "Your printers", "Your SSH keys, through the SSH agent", "Your GnuPG keys, through the GnuPG agent", "Smart cards",
                 "Every service of your session", "Every service of the system", "Bluetooth", "CAN bus devices",
                 "Developer features that can trace programs", "32-bit programs", "Programs that start when you log in",
                 "Programs outside its sandbox"]);
        // Named services, flatpak's own words for a grant the Store does not know, the count past the list; a key this
        // window does not know is said as it is (PR #58: never less than the metadata grants).
        compare(Store.accessWords(["sessionService:org.freedesktop.secrets", "systemService:org.freedesktop.login1", "other:devices=tpm",
                                   "more:14", "unknown", "later:x"]),
                ["The session service “org.freedesktop.secrets”", "The system service “org.freedesktop.login1”",
                 "A permission the Store can't describe: devices=tpm", "14 more", "A permission the Store can't describe: unknown",
                 "A permission the Store can't describe: later:x"]);
        compare(Store.accessText(["network", "home"]), "The internet, Your home folder");
        compare(Store.accessText(["unknown"]), "A permission the Store can't describe: unknown");
        compare(Store.accessText([]), "Only its own window and files");
        compare(Store.accessText(undefined), "", "unread: nothing said rather than too little");
        compare(Store.accessText(null), "");
        compare(Store.groupTitle("flatpak"), "Flathub");
        compare(Store.resultText({kind: "install", outcome: "stopped"}), "", "stopped by the user: nothing to say");
        verify(!Store.canTryAgain({outcome: "stopped"}));
        compare(Store.resultText({kind: "install", outcome: "failed", source: "flatpak"}), "The installation failed.");
    }

    function test_symbols() {
        compare(Store.symbolIcon("discover"), "sparkle");
        compare(Store.symbolIcon("category-internet"), "globe");
        compare(Store.symbolIcon("unknown-symbol"), "apps", "an unknown symbol gets the generic glyph");
    }

    function test_button() {
        compare(Store.buttonState(null), "get");
        compare(Store.buttonState({installed: false, launcher: true}), "get");
        compare(Store.buttonState({installed: true, launcher: true}), "open");
        compare(Store.buttonState({installed: true, launcher: false}), "installed");
        compare(Store.buttonText("get"), "Get");
        compare(Store.buttonText("open"), "Open");
        compare(Store.buttonText("installed"), "Installed");
    }

    // Step 3: the button with the backend's actions and an operation, why Get or Uninstall… is not offered, what an operation
    // is doing, how it ended (SR13, SR18-SR22, SR30).
    function test_operations() {
        compare(Store.buttonState({installed: false}, {installed: true, launcher: true}, null), "open", "the backend's facts win");
        compare(Store.buttonState({installed: true, launcher: true}, null, {state: "waiting"}), "progress");
        compare(Store.getBlockText("dev"), "dev: not applied");
        compare(Store.getBlockText("offline"), "You're offline.");
        compare(Store.getBlockText(""), "");
        compare(Store.operationText({kind: "install", state: "waiting", blocked: false}), "Waiting");
        compare(Store.operationText({kind: "install", state: "waiting", blocked: true}), "Waiting for another installation or an update to finish");
        compare(Store.operationText({kind: "install", state: "authorizing"}), "Waiting for permission…");
        compare(Store.operationText({kind: "install", state: "running", done: 0, total: 3}), "Installing…");
        compare(Store.operationText({kind: "install", state: "running", done: 2, total: 3}), "Installing: 2 of 3");
        compare(Store.operationText({kind: "remove", state: "running", done: 1, total: 2}), "Uninstalling: 1 of 2");
        compare(Store.operationText({kind: "remove", state: "checking"}), "Finishing the uninstallation…");
        // Omarchy's terminal (b.2): opening it, then the recipe running there; pacman's count when its log has one.
        compare(Store.operationText({kind: "install", path: "terminal", state: "opening"}), "Opening Terminal…");
        compare(Store.operationText({kind: "install", path: "terminal", state: "running", done: 0, total: 3}), "Installing in Terminal…");
        compare(Store.operationText({kind: "remove", path: "terminal", state: "running", done: 0, total: 1}), "Uninstalling in Terminal…");
        compare(Store.operationText({kind: "install", path: "terminal", state: "running", done: 1, total: 3}), "Installing: 1 of 3");
        compare(Store.resultText({kind: "install", outcome: "terminalDidNotOpen"}), "The terminal did not open.");
        verify(Store.canTryAgain({outcome: "terminalDidNotOpen"}));
        compare(Store.resultText({kind: "install", outcome: "omarchyChanged"}),
                "This setup hasn't been checked with your version of Omarchy yet. The Store offers it again once its catalog has been.");
        verify(!Store.canTryAgain({outcome: "omarchyChanged"}), "trying again changes nothing until the catalog has");
        compare(Store.getBlockText("omarchyChanged"), Store.resultText({outcome: "omarchyChanged"}));
        compare(Store.uninstallReasonText("omarchyChanged"), Store.resultText({outcome: "omarchyChanged"}));
        compare(Store.resultText({kind: "install", outcome: "interrupted", present: 15, total: 110}),
                "The installation was interrupted: 15 of 110 packages were installed.");
        compare(Store.resultText({kind: "remove", outcome: "notFinished"}), "The uninstallation did not finish.");
        compare(Store.resultText({kind: "install", outcome: "cancelled"}), "", "a cancelled request says nothing");
        compare(Store.resultText({kind: "install", outcome: "unfinished"}), "Finish the system update first.");
        verify(Store.canTryAgain({outcome: "interrupted"}));
        verify(!Store.canTryAgain({outcome: "refused"}));
        compare(Store.uninstallReasonText("omarchy"), "Part of Omarchy");
        compare(Store.uninstallReasonText("grassfield"), "Part of Grassfield");
        compare(Store.uninstallReasonText("system"), "Part of the system");
        compare(Store.uninstallReasonText("dependency"), "Installed with another app");
        compare(Store.uninstallReasonText(""), "");
        compare(Store.uninstallReasonText("notInstalled"), "");
    }

    function test_rating() {
        compare(Store.ratingText(false, {}), "Not rated");
        compare(Store.ratingText(true, {}), "None");
        compare(Store.ratingText(true, {violence: 1, money: 2}), "Violence: mild · Purchases or gambling: moderate");
        compare(Store.ratingText(true, {social: 3, drugs: 9}), "Online interaction: intense", "a level out of range is left out");
    }

    function test_languages() {
        compare(Store.languagesText([]), "");
        compare(Store.languagesText(["Deutsch", "français"]), "Deutsch, français");
        compare(Store.languagesText(["a", "b", "c"]), "a, b, c");
        compare(Store.languagesText(["a", "b", "c", "d", "e"]), "a, b and 3 more");
        compare(Store.languagesText(["a", "b", "c", "d"]), "a, b and 2 more");
    }

    function test_kinds() {
        compare(Store.kindsIn([{kind: "webapp"}, {kind: "repo"}, {kind: "repo"}, {kind: "setup"}]), ["repo", "setup", "webapp"]);
        compare(Store.kindsIn([]), []);
        compare(Store.kindTitle("setup"), "Omarchy Setups");
        compare(Store.groupTitle("foreign"), "Not from a Repository");
    }

    function test_updatesStatus() {
        compare(Store.updatesStatus({state: "up-to-date", checkedAt: "9:12"}), "Your apps are up to date. Last checked 9:12.");
        compare(Store.updatesStatus({state: "failed", error: "offline"}), "Updates could not be checked: you're offline.");
        compare(Store.updatesStatus({state: "busy"}), "Update in progress");
        compare(Store.updatesStatus({state: "unknown"}), "Software Update has not checked for updates yet.");
        compare(Store.updatesStatus(null), "Software Update has not checked for updates yet.");
        // Step 4: what runs or is asked comes first.
        compare(Store.updatesStatus({state: "available", running: true}), "Update in progress");
        compare(Store.updatesStatus({state: "available", checking: true}), "Checking for updates…");
        compare(Store.updatesStatus({state: "up-to-date", unfinished: 3}), "The last system update did not finish.");
        compare(Store.updatesStatus({state: "up-to-date", checkedAt: "9:12", count: 1}), "Last checked 9:12.");
        compare(Store.updatesStatus({state: "unknown", askFailed: true}), "Software Update couldn't check for updates. Open it to check.");
    }

    // The system's button on Updates (SD32): Update All… opens Software Update; Software Update… when only it can act.
    function test_systemAction() {
        compare(Store.systemAction({state: "available", others: 3}), "update");
        compare(Store.systemAction({state: "up-to-date", others: 0, grassfield: {available: "1.0.1-1"}}), "update");
        compare(Store.systemAction({state: "up-to-date", others: 0, unfinished: 1}), "update");
        compare(Store.systemAction({state: "up-to-date", others: 0}), "");
        compare(Store.systemAction({state: "blocking"}), "software");
        compare(Store.systemAction({state: "not-set-up"}), "software");
        compare(Store.systemAction({state: "available", others: 3, running: true}), "");
        compare(Store.systemAction({state: "available", others: 3, checking: true}), "");
        compare(Store.systemAction(null), "");
    }

    function test_flatpakUpdates() {
        compare(Store.flatpakUpdatesLine({on: false}), "");
        compare(Store.flatpakUpdatesLine({on: true, state: "checking"}), "Checking Flathub for updates…");
        compare(Store.flatpakUpdatesLine({on: true, state: "failed"}), "Flathub's updates couldn't be checked. Check your connection to the internet, then try again.");
        compare(Store.flatpakUpdatesLine({on: true, state: "", apps: [], runtimes: 0}), "Your Flatpak apps are up to date.");
        compare(Store.flatpakUpdatesLine({on: true, state: "", apps: [], runtimes: 2}), "2 runtimes have an update.");
        compare(Store.flatpakUpdatesLine({on: true, state: "", apps: [{id: "a"}], runtimes: 2}), "");
        // The button: Update for an installed Flatpak with an update, never before Get.
        compare(Store.buttonState({}, {installed: true, launcher: true, update: ""}, null), "update");
        compare(Store.buttonState({}, {installed: true, launcher: true, update: "offline"}, null), "update");
        compare(Store.buttonState({}, {installed: true, launcher: true, update: "none"}, null), "open");
        compare(Store.buttonState({}, {installed: false, launcher: false, update: ""}, null), "get");
        compare(Store.buttonText("update"), "Update");
        // How an update ended: judged by a new check (S31d).
        compare(Store.resultText({kind: "update", outcome: "notFinished"}), "The update did not finish. Check your connection to the internet, then try again.");
        compare(Store.resultText({kind: "update", outcome: "interrupted", present: 1, total: 3}), "The update was interrupted: 1 of 3 were updated.");
        compare(Store.resultText({kind: "update", outcome: "failed"}), "The update failed.");
        compare(Store.resultText({kind: "update", outcome: ""}), "");
    }

    function test_host() {
        compare(Store.hostOf("https://www.gimp.org/about"), "www.gimp.org");
        compare(Store.hostOf("http://example.org"), "");
        compare(Store.hostOf(""), "");
    }

    // Back and forward keep each page's scroll; the same page is not visited twice; a typed query replaces in place.
    function test_navigation() {
        let s = Nav.start({page: "section", id: "discover"});
        verify(!Nav.canBack(s) && !Nav.canForward(s));
        s = Nav.visit(s, {page: "app", id: "a"}, 300);
        compare(s.back[0].scroll, 300);
        compare(s.current.scroll, 0);
        compare(Nav.visit(s, {page: "app", id: "a"}, 10), s, "the same page changes nothing");
        s = Nav.back(s, 55);
        compare(s.current.id, "discover");
        compare(s.current.scroll, 300);
        compare(s.forward[0].scroll, 55);
        s = Nav.forward(s, 300);
        compare(s.current.id, "a");
        compare(s.current.scroll, 55);
        s = Nav.visit(s, {page: "search", query: "p"}, 0);
        s = Nav.replace(s, {page: "search", query: "pa"});
        compare(s.back.length, 2);
        compare(s.current.query, "pa");
        compare(Nav.back(Nav.start({page: "x"})).current.page, "x", "nothing to go back to");
        verify(!Nav.same({page: "search", query: "a"}, {page: "search", query: "b"}));
    }
}
