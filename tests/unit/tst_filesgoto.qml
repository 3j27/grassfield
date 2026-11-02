pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/files/qml"

// Files' Go to Folder panel, Return (FP-76, review of PR #98): what is typed wins when it exists ("/" and "~/" open the root
// and the home folder themselves, not the first of their subfolders; an existing folder without a trailing slash opens as it
// is); a partial path completes to the first match; an arrow key's choice is kept; a missing path says so. The stand-in app
// answers like FilesApp.goToTarget and completeFolder over a small tree (the real ones are tested in tst_navlogic.cpp).
TestCase {
    id: tc

    name: "FilesGoToFolder"
    width: 600
    height: 400
    visible: true
    when: windowShown

    property var visited: []

    QtObject {
        id: fakeApp

        signal folderCompletions(string text, var matches)
        property var recentFolders: []

        // The folders that exist; "~" is /home/u.
        readonly property var folders: ["/", "/bin", "/usr", "/home", "/home/u", "/home/u/Desktop", "/home/u/Documents", "/home/u/Downloads"]

        function resolve(text: string): string {
            let t = text.replace(/^~/, "/home/u");
            if (t.length > 1)
                t = t.replace(/\/+$/, "");
            return t;
        }
        function goToTarget(text: string, base: url): var {
            const t = fakeApp.resolve(text);
            return {folder: fakeApp.folders.indexOf(t) >= 0 ? "file://" + t : "", select: ""};
        }
        function completeFolder(text: string, base: url): void {
            const slash = text.lastIndexOf("/");
            const dir = fakeApp.resolve(text.substring(0, slash + 1));
            const prefix = text.substring(slash + 1).toLowerCase();
            const matches = [];
            for (const f of fakeApp.folders) {
                const parent = f.substring(0, f.lastIndexOf("/")) || "/";
                const name = f.substring(f.lastIndexOf("/") + 1);
                if (f !== "/" && parent === dir && name.toLowerCase().startsWith(prefix))
                    matches.push({url: "file://" + f, parts: [], name: name});
            }
            fakeApp.folderCompletions(text, matches);
        }
        function completedText(text: string, base: url, match: string): string {
            return text.substring(0, text.lastIndexOf("/") + 1) + match + "/";
        }
    }

    QtObject {
        id: fakeTab

        property url url: "file:///home/u"
        property var folder: QtObject {
            function expect(target: url, select: bool): void {
            }
        }
        function navigate(target: url, record: bool): void {
            tc.visited.push(String(target));
        }
    }

    Item {
        id: host

        width: tc.width
        height: tc.height
    }

    Component {
        id: panelComponent

        GoToFolderPanel {
            app: fakeApp
            tab: fakeTab
        }
    }

    function openPanel(): var {
        tc.visited = [];
        const panel = createTemporaryObject(panelComponent, host);
        verify(panel !== null);
        panel.open();
        verify(panel.visible);
        return panel;
    }

    function typeText(text: string): void {
        for (const ch of text)
            keyClick(ch);
    }

    function test_rootOpensTheRootNotItsFirstFolder() {
        const panel = openPanel();
        tc.typeText("/");
        compare(panel.matches.length, 3, "the root lists its folders");
        keyClick(Qt.Key_Return);
        compare(tc.visited, ["file:///"]);
        verify(!panel.visible);
    }

    function test_homeOpensTheHomeNotDesktop() {
        const panel = openPanel();
        tc.typeText("~/");
        compare(panel.matches.length, 3);
        keyClick(Qt.Key_Return);
        compare(tc.visited, ["file:///home/u"]);
        verify(!panel.visible);
    }

    function test_existingFolderWithoutASlashOpensAsIs() {
        const panel = openPanel();
        tc.typeText("/home/u/Doc");
        keyClick(Qt.Key_Return);
        compare(tc.visited, ["file:///home/u/Documents"], "partial: the first match");
        const second = openPanel();
        tc.typeText("/home/u/Desktop");
        compare(second.matches.length, 1);
        keyClick(Qt.Key_Return);
        compare(tc.visited, ["file:///home/u/Desktop"]);
    }

    function test_aFolderThatIsAlsoAPrefixOpensAsTyped() {
        // "/us" is partial and completes; "/usr" exists and opens as typed.
        const panel = openPanel();
        tc.typeText("/us");
        keyClick(Qt.Key_Return);
        compare(tc.visited, ["file:///usr"], "partial: completes");
        const second = openPanel();
        tc.typeText("/usr");
        keyClick(Qt.Key_Return);
        compare(tc.visited, ["file:///usr"]);
        verify(second !== null);
    }

    function test_aPartialNameCompletesToTheFirstMatch() {
        const panel = openPanel();
        tc.typeText("~/Do");
        compare(panel.matches.length, 2);
        keyClick(Qt.Key_Return);
        compare(tc.visited, ["file:///home/u/Documents"]);
    }

    function test_anArrowKeyChoiceIsKeptEvenWhenThePathExists() {
        const panel = openPanel();
        tc.typeText("~/");
        keyClick(Qt.Key_Down);
        keyClick(Qt.Key_Return);
        compare(tc.visited, ["file:///home/u/Documents"], "the second row of the listing");
    }

    function test_aMissingPathSaysSoAndStaysOpen() {
        const panel = openPanel();
        tc.typeText("/nowhere/at/all");
        compare(panel.matches.length, 0);
        keyClick(Qt.Key_Return);
        compare(tc.visited, []);
        verify(panel.visible);
        verify(panel.errorText !== "");
    }
}
