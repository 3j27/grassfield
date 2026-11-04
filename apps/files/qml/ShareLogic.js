.pragma library

// Files' Share menu (ADR-0045 OC-13, docs/specs/files.md FP-20): which selection can be sent with LocalSend and the argument
// vector that sends it, pure for the tests (tests/unit/tst_filesshare.qml). The send itself is FilesApp.sendWithLocalSend
// (C++), which runs nothing but this vector and checks it again: the same program and options, then paths that are absolute
// and exist on this computer.
//
// The invocation is Omarchy's own (bin/omarchy-menu-share of Omarchy v4.0.6, the Omarchy menu's Share > File and Folder):
// `systemd-run --user --quiet --collect localsend --headless send <paths...>`: LocalSend in a transient unit of the user's
// service manager (detached from Files, collected when it ends), opened on its send page with the items. Each path is one
// argument; no shell ever reads them. LocalSend's command line takes no `--` (Omarchy passes the paths directly, so does
// Files): a path that could be read as an option is impossible here, every path being absolute (it starts with "/").

const LOCALSEND_ARGV = ["systemd-run", "--user", "--quiet", "--collect", "localsend", "--headless", "send"];

// The local path of a file URL ("file:///home/u/a%20b.txt" -> "/home/u/a b.txt"); "" for anything else: another scheme
// (trash:/, smb:/, sftp:/, the Applications location grassfield-apps:/, a search's own URL), a file URL naming a host
// (file://server/share), a query or a fragment, a malformed escape, a NUL. Files' URLs are QUrl's (PrettyDecoded: "%",
// "#" and "?" of a name are escaped), so decoding the path gives the name back.
function localPath(url) {
    const s = String(url);
    if (!s.startsWith("file:///"))
        return "";
    const encoded = s.substring("file://".length);
    if (encoded.indexOf("?") >= 0 || encoded.indexOf("#") >= 0)
        return "";
    let path = "";
    try {
        path = decodeURIComponent(encoded);
    } catch (e) {
        return "";
    }
    if (path.indexOf("\u0000") >= 0 || !path.startsWith("/"))
        return "";
    // A folder's URL may end with "/" (the root aside): LocalSend gets the folder's own path.
    return path.length > 1 ? path.replace(/\/+$/, "") : path;
}

// The selection can be sent: at least one item, every one a local file or folder (localPath), outside the Trash and the
// Applications location (their items are not files of a folder: trash:/ and grassfield-apps:/ URLs, refused by localPath
// too; `where` says it for a model whose URLs could still look local). A network place (smb:, sftp:, ...) is refused.
function canSend(urls, where) {
    const list = urls || [];
    if (list.length === 0)
        return false;
    if (where && (where.isTrash === true || where.isApplications === true))
        return false;
    for (let i = 0; i < list.length; i++) {
        if (localPath(list[i]) === "")
            return false;
    }
    return true;
}

// The argument vector that sends `urls` with LocalSend, or null when one of them is not a local item (canSend). The same
// item twice is sent once (a selection never holds it twice; the C++ side keeps the order it gets).
function sendArgv(urls) {
    if (!canSend(urls, null))
        return null;
    const paths = [];
    for (let i = 0; i < urls.length; i++) {
        const p = localPath(urls[i]);
        if (paths.indexOf(p) < 0)
            paths.push(p);
    }
    return LOCALSEND_ARGV.concat(paths);
}

// The Share menu (the toolbar's Share button and the selection's Share submenu): LocalSend first, where macOS puts its
// nearby-device sharing. Shown only when LocalSend is installed (`installed`, FilesApp.localSendAvailable at the time the
// menu is built); enabled only for a selection canSend takes. Empty when there is nothing to share with.
function menuItems(installed, sendable, text) {
    if (!installed)
        return [];
    return [{id: "localsend", text: text, enabled: sendable === true}];
}
