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
