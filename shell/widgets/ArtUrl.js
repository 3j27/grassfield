.pragma library

// Cover art URLs come from an MPRIS player (untrusted: a player can name any URL). Never handed to an Image as such
// (review of 423766f: a file: URL naming an SVG that references a FIFO, or the FIFO itself, stalled the image loader):
// a local file goes to ThemeIcons.fileSource and an https URL to ThemeIcons' fetch (ThemeIcons.artSource), both shown as
// a PNG the shell made. Any other URL (http, data:, ftp, ...) shows the placeholder.

// The absolute path a file:///path or file://localhost/path URL names (percent-decoded; no other host, no query or
// fragment, no control character), else "".
function localPath(url) {
    if (typeof url !== "string")
        return "";
    const text = url.trim();
    const m = /^file:\/\/(localhost)?(\/(?!\/)[^?#]*)$/i.exec(text);
    if (m === null || m[2].length < 2)
        return "";
    let path = "";
    try {
        path = decodeURIComponent(m[2]);
    } catch (e) {
        return "";
    }
    return path.length <= 4096 && !/[\u0000-\u001f\u007f]/.test(path) ? path : "";
}

// An https URL the helper may fetch, as given, else "": https://host[:port][/path], the host a name of letters, digits,
// "." and "-" (no user or password; never an IP literal in any notation: a host whose last label is a decimal or 0x
// number is one, as URL parsers read it; never localhost or *.localhost), the path of printable ASCII without spaces or
// backslashes, at most 2048 characters. services/image-copy.py checks the same, then resolves the name and refuses any
// address that is not public (review of dce68c2, minor 1).
function remoteUrl(url) {
    if (typeof url !== "string" || url.length > 2048)
        return "";
    const m = /^https:\/\/([A-Za-z0-9.-]{1,253})(:[0-9]{1,5})?(\/[!-\[\]-~]*)?$/.exec(url);
    if (m === null)
        return "";
    const host = m[1].toLowerCase().replace(/\.+$/, "");
    const last = host.split(".").pop();
    if (host === "" || /^([0-9]+|0x[0-9a-f]*)$/.test(last) || host === "localhost" || host.endsWith(".localhost"))
        return "";
    return url;
}
