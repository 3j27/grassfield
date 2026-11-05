import QtQuick
import QtTest
import "../../apps/files/qml/ShareLogic.js" as ShareLogic

// Files' Share menu (apps/files/qml/ShareLogic.js; ADR-0045 OC-13, docs/specs/files.md FP-20): which selections LocalSend
// takes (local files and folders only: no Trash, Applications, network or search location), the paths decoded from Files'
// URLs, and the argument vector, Omarchy's own invocation (omarchy-menu-share) with one argument per item. The menus and the
// send through the stand-in FilesApp are tests/unit/tst_filesbrowser.qml (test_shareSendsWithLocalSend); FilesApp's check of
// the vector is C++ (FilesApp::sendWithLocalSend).
TestCase {
    name: "FilesShare"

    readonly property var prefix: ["systemd-run", "--user", "--quiet", "--collect", "localsend", "--headless", "send"]

    function test_localPathDecodesFileUrls() {
        compare(ShareLogic.localPath("file:///home/u/notes.txt"), "/home/u/notes.txt");
        compare(ShareLogic.localPath("file:///home/u/a%20b%20c.txt"), "/home/u/a b c.txt", "spaces");
        compare(ShareLogic.localPath("file:///home/u/%C3%A9t%C3%A9.png"), "/home/u/été.png", "UTF-8 escapes");
        compare(ShareLogic.localPath("file:///home/u/été.png"), "/home/u/été.png", "QUrl's pretty form");
        compare(ShareLogic.localPath("file:///home/u/100%25%20sure%23%3F.txt"), "/home/u/100% sure#?.txt", "%, # and ? of a name");
        compare(ShareLogic.localPath("file:///home/u/Folder/"), "/home/u/Folder", "a folder's trailing slash");
        compare(ShareLogic.localPath("file:///"), "/", "the root");
        compare(ShareLogic.localPath("file:///home/u/-rf"), "/home/u/-rf", "a name like an option stays a path: absolute");
    }

    function test_localPathRefusesWhatIsNotLocal() {
        const refused = ["trash:/notes.txt", "grassfield-apps:/firefox", "smb://server/share/a.txt", "sftp://u@host/home/u/a",
                         "grassfield-search:/?q=a", "recentlyused:/", "file://server/share/a.txt", "file:///home/u/a.txt?x=1",
                         "file:///home/u/a.txt#frag", "file:///home/u/%E0%A4%A", "file:///home/u/a%00b", "", "/home/u/a.txt",
                         "http://example.com/a.txt"];
        for (const u of refused)
            compare(ShareLogic.localPath(u), "", u);
    }

    function test_canSendLocalItemsOnly() {
        verify(ShareLogic.canSend(["file:///home/u/a.txt"], null), "a file");
        verify(ShareLogic.canSend(["file:///home/u/a.txt", "file:///home/u/Folder"], {isTrash: false, isApplications: false}), "a file and a folder");
        verify(!ShareLogic.canSend([], null), "nothing selected");
        verify(!ShareLogic.canSend(null, null), "no selection");
        verify(!ShareLogic.canSend(["file:///home/u/a.txt", "smb://server/share/b.txt"], null), "one item on a server");
        verify(!ShareLogic.canSend(["trash:/a.txt"], {isTrash: true, isApplications: false}), "the Trash");
        verify(!ShareLogic.canSend(["file:///home/u/a.txt"], {isTrash: true, isApplications: false}), "a Trash listing, whatever its URLs");
        verify(!ShareLogic.canSend(["grassfield-apps:/firefox"], {isTrash: false, isApplications: true}), "Applications");
    }

    function test_sendArgvIsOmarchysInvocation() {
        compare(ShareLogic.sendArgv(["file:///home/u/a%20b.txt"]), prefix.concat(["/home/u/a b.txt"]));
        compare(ShareLogic.sendArgv(["file:///home/u/a.txt", "file:///home/u/Folder/", "file:///home/u/a.txt"]),
                prefix.concat(["/home/u/a.txt", "/home/u/Folder"]), "one argument per item, each once, in order");
        compare(ShareLogic.sendArgv(["file:///home/u/a.txt", "trash:/b.txt"]), null, "not when one is not local");
        compare(ShareLogic.sendArgv([]), null, "not for nothing");
        const argv = ShareLogic.sendArgv(["file:///home/u/--help", "file:///home/u/;%20rm%20-rf%20~"]);
        compare(argv.slice(prefix.length), ["/home/u/--help", "/home/u/; rm -rf ~"], "names are arguments, never options or shell");
        for (const p of argv.slice(prefix.length))
            verify(p.startsWith("/"), p);
    }

    function test_menuItems() {
        compare(ShareLogic.menuItems(false, true, "Send with LocalSend…"), [], "nothing to share with");
        compare(ShareLogic.menuItems(true, true, "Send with LocalSend…"), [{id: "localsend", text: "Send with LocalSend…", enabled: true}]);
        compare(ShareLogic.menuItems(true, false, "Send with LocalSend…")[0].enabled, false, "dimmed for a selection LocalSend cannot take");
        // A development session (security review LOW 2): shown, dimmed, never sent (systemd-run --user would open LocalSend on
        // the owner's real desktop).
        compare(ShareLogic.menuItems(true, true, "Send with LocalSend…", true), [{id: "localsend", text: "Send with LocalSend…", enabled: false}]);
        compare(ShareLogic.menuItems(true, true, "Send with LocalSend…", false)[0].enabled, true);
        verify(ShareLogic.maySend(["file:///home/u/a.txt"], null, false));
        verify(!ShareLogic.maySend(["file:///home/u/a.txt"], null, true), "never in a development session");
        verify(!ShareLogic.maySend(["trash:/a.txt"], null, false));
    }
}
